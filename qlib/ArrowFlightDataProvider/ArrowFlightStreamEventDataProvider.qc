# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightStreamEventDataProvider.qc Observable data provider for Arrow Flight streams

/*  ArrowFlightStreamEventDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

    Permission is hereby granted, free of charge, to any person obtaining a
    copy of this software and associated documentation files (the "Software"),
    to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense,
    and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
    FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
    DEALINGS IN THE SOFTWARE.
*/

#! Contains all public definitions in the ArrowFlightDataProvider module
public namespace ArrowFlightDataProvider {

#! Observable data provider for Arrow Flight streaming operations
/** Provides event-based access to Arrow Flight DoGet and DoExchange streams
    via the DataProvider observer pattern.

    For DoGet, this provider supports only observable events (receive-only).
    For DoExchange, it also supports sending batches via the DataProvider message API.

    Events raised:
    - @ref EVENT_FLIGHT_RECORD_BATCH -- rows from a received record batch
    - @ref EVENT_FLIGHT_COMPLETE -- the stream completed successfully
    - @ref EVENT_FLIGHT_ERROR -- an error occurred on the stream

    Messages supported (DoExchange only):
    - @ref MESSAGE_FLIGHT_SEND_BATCH -- send rows as a record batch

    @par DoGet usage
    @code{.py}
ArrowFlightStreamEventDataProvider events = method_prov.getChildProvider("events");
events.setObserverRequest({"ticket": binary("my-dataset")});
events.registerObserver(my_observer);
events.observersReady();
    @endcode

    @par DoExchange usage
    @code{.py}
ArrowFlightStreamEventDataProvider events = method_prov.getChildProvider("events");
events.registerObserver(my_observer);
events.observersReady();
events.sendMessage(MESSAGE_FLIGHT_SEND_BATCH, {"rows": my_rows});
events.stopEvents();
    @endcode
*/
public class ArrowFlightStreamEventDataProvider inherits AbstractDataProvider, DelayedObservable {
    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;

        #! The dataset name
        string dataset_name;

        #! The FlightInfo for this dataset
        hash<auto> flight_info;

        #! The method type: "get" or "exchange"
        string method_type;

        #! Default options for calls
        *hash<auto> default_opts;

        #! Request data for the stream (DoGet only: ticket info)
        *hash<auto> observer_request;

        #! The active exchange stream (DoExchange only, shared between send and receive)
        *ArrowFlightExchangeStream exchange_stream;

        #! Cached ArrowSchema for sendMessage (avoids repeated deserialization)
        *ArrowSchema cached_schema;

        #! Flag: stream loop started
        bool started = False;

        #! Flag: stop requested
        bool stopping = False;

        #! Flag: stream is active
        bool active = True;

        #! Mutex for state synchronization
        Mutex m();

        #! Condition variable for state changes
        Condition cond();
    }

    #! Creates the stream event data provider
    /** @param flight_client the Arrow Flight client
        @param dataset_name the dataset name
        @param flight_info the FlightInfo hash
        @param method_type the operation type: "get" or "exchange"
        @param default_opts default options for calls
    */
    constructor(ArrowFlightClient flight_client, string dataset_name,
            hash<auto> flight_info, string method_type, *hash<auto> default_opts) {
        self.flight_client = flight_client;
        self.dataset_name = dataset_name;
        self.flight_info = flight_info;
        self.method_type = method_type;
        self.default_opts = default_opts;
    }

    #! Returns the data provider name
    string getName() {
        return "events";
    }

    #! Returns the data provider description
    *string getDesc() {
        if (method_type == "exchange") {
            return sprintf("Observable event provider for Arrow Flight DoExchange on '%s'",
                dataset_name);
        }
        return sprintf("Observable event provider for Arrow Flight DoGet on '%s'",
            dataset_name);
    }

    #! Sets the request data for the stream
    /** @param req the request data; for DoGet, may contain a \c ticket field

        @note Only meaningful for DoGet; for DoExchange, data is sent via sendMessage()
    */
    setObserverRequest(*hash<auto> req) {
        observer_request = req;
    }

    #! Called when all observers are registered; starts the stream
    observersReady() {
        {
            AutoLock al(m);
            if (started) {
                throw "ARROW-FLIGHT-OBSERVABLE-ERROR",
                    "observersReady() has already been called";
            }
            started = True;
        }
        background streamLoop();
    }

    #! Called to stop event generation
    /** For DoExchange streams, signals writes-done so the server knows no more batches
        will be sent. The read loop will exit when the server closes its side.
    */
    stopEvents() {
        AutoLock al(m);
        stopping = True;
        cond.broadcast();
        if (exchange_stream) {
            exchange_stream.writesDone();
        }
    }

    #! Returns True if the stream is still active
    /** @return True if events may still be generated
    */
    bool isActive() {
        AutoLock al(m);
        return active;
    }

    #! Blocks until the exchange stream is connected and ready for sendMessage()
    /** @param timeout maximum time to wait
        @return True if the stream is ready, False on timeout

        @note Only meaningful for DoExchange
    */
    bool waitForReady(timeout timeout = 10s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout);
        while (!exchange_stream && active && !stopping) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return exists exchange_stream;
    }

    #! Blocks until the stream is no longer active
    /** @param timeout maximum time to wait
        @return True if the stream became inactive, False on timeout
    */
    bool waitForInactive(timeout timeout = 10s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout);
        while (active) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return True;
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        hash<DataProviderInfo> info = <DataProviderInfo>{
            "type": "ArrowFlightStreamEventDataProvider",
            "supports_observable": True,
        };
        if (method_type == "exchange") {
            info.supports_messages = MSG_Async;
        }
        return info;
    }

    #! Sends a row or columnar batch on the DoExchange stream
    /** @param message_id the message ID (must be @ref MESSAGE_FLIGHT_SEND_BATCH)
        @param msg the message data with a \c rows field containing row hashes, a hash-of-lists,
        a ColumnarResult, a DataFrame, or an ArrowRecordBatch
        @param send_message_options optional send options (unused)

        @throw ARROW-FLIGHT-STREAM-ERROR if the stream is not active or method is not exchange
    */
    private sendMessageImpl(string message_id, auto msg, *hash<auto> send_message_options) {
        if (message_id != MESSAGE_FLIGHT_SEND_BATCH) {
            throw "ARROW-FLIGHT-STREAM-ERROR",
                sprintf("unsupported message ID %y; expected %y",
                    message_id, MESSAGE_FLIGHT_SEND_BATCH);
        }
        if (method_type != "exchange") {
            throw "ARROW-FLIGHT-STREAM-ERROR",
                "sendMessage() is only supported on DoExchange streams";
        }
        # Build schema and batch outside lock to reduce lock contention
        ArrowSchema sch;
        {
            AutoLock al(m);
            if (!cached_schema) {
                cached_schema = new ArrowSchema(flight_info.schema);
            }
            sch = cached_schema;
        }
        ArrowRecordBatch batch = ArrowFlightHelper::toRecordBatch(msg.rows, sch);
        AutoLock al(m);
        if (!exchange_stream || stopping) {
            throw "ARROW-FLIGHT-STREAM-ERROR", "exchange stream is not active";
        }
        exchange_stream.write(batch);
    }

    #! Returns the message types supported by this provider
    private hash<string, hash<DataProviderMessageInfo>> getMessageTypesImpl() {
        if (method_type != "exchange") {
            return {};
        }
        HashDataType msg_type("FlightSendBatchMessage");
        msg_type.addField(new QoreDataField("rows",
            "Rows or a columnar batch to send as an Arrow record batch",
            AbstractDataProviderType::get(AutoType)));
        return {
            MESSAGE_FLIGHT_SEND_BATCH: <DataProviderMessageInfo>{
                "desc": "Send rows or a columnar batch as an Arrow record batch on the DoExchange stream",
                "type": msg_type,
            },
        };
    }

    #! Returns example event data for the given event
    /** @param event_id the event ID

        @return example data for the event
    */
    private auto getExampleEventDataImpl(string event_id) {
        switch (event_id) {
            case EVENT_FLIGHT_COMPLETE:
                return {};
            case EVENT_FLIGHT_ERROR:
                return {
                    "err": "ARROW-FLIGHT-ERROR",
                    "desc": "stream error",
                };
            case EVENT_FLIGHT_RECORD_BATCH: {
                *AbstractDataProviderType t = getEventTypesImpl(){event_id}.type;
                return t ? t.getExampleValue() : {};
            }
        }
    }

    #! Returns the event types supported by this provider
    private hash<string, hash<DataProviderMessageInfo>> getEventTypesImpl() {
        # Build the batch event type with rows field based on schema
        *AbstractDataProviderType row_type = getRowType();
        HashDataType batch_event_type("FlightBatchEvent");
        if (row_type) {
            batch_event_type.addField(new QoreDataField("rows",
                "Row data from the record batch",
                new SoftListDataType("rows", row_type)));
        } else {
            batch_event_type.addField(new QoreDataField("rows",
                "Row data from the record batch",
                AbstractDataProviderType::get(SoftListType)));
        }
        batch_event_type.addField(new QoreDataField("num_rows",
            "Number of rows in the batch",
            AbstractDataProviderType::get(IntType)));

        return {
            EVENT_FLIGHT_RECORD_BATCH: <DataProviderMessageInfo>{
                "desc": "A record batch received from the Arrow Flight stream",
                "type": batch_event_type,
            },
            EVENT_FLIGHT_COMPLETE: <DataProviderMessageInfo>{
                "desc": "The Arrow Flight stream completed successfully",
                "type": FlightStreamCompleteDataType,
            },
            EVENT_FLIGHT_ERROR: <DataProviderMessageInfo>{
                "desc": "An error occurred on the Arrow Flight stream",
                "type": FlightStreamErrorDataType,
            },
        };
    }

    #! Background thread that reads the stream and notifies observers
    private streamLoop() {
        try {
            if (method_type == "get") {
                doGetStreamLoop();
            } else {
                doExchangeStreamLoop();
            }
        } catch (hash<ExceptionInfo> ex) {
            {
                AutoLock al(m);
                active = False;
                exchange_stream = NOTHING;
                cond.broadcast();
            }
            notifyObservers(EVENT_FLIGHT_ERROR, {
                "err": ex.err,
                "desc": ex.desc,
            });
        }
    }

    #! DoGet stream loop
    private doGetStreamLoop() {
        hash<auto> ticket = {
            "ticket": observer_request.ticket ?? binary(dataset_name),
        };
        ArrowFlightStreamReader reader = flight_client.doGet(ticket);
        on_error reader.cancel();

        while (True) {
            {
                AutoLock al(m);
                if (stopping) {
                    break;
                }
            }

            *ArrowRecordBatch batch = reader.read(5s);
            if (batch) {
                notifyObservers(EVENT_FLIGHT_RECORD_BATCH, {
                    "rows": batch.toRows(),
                    "num_rows": batch.numRows(),
                });
            } else if (reader.readsDone()) {
                break;
            }
        }

        {
            AutoLock al(m);
            if (stopping) {
                reader.cancel();
                active = False;
                cond.broadcast();
                return;
            }
        }

        hash<GrpcCallResult> result = reader.finish();
        {
            AutoLock al(m);
            active = False;
            cond.broadcast();
        }
        if (result.status_code != GRPC_STATUS_OK) {
            notifyObservers(EVENT_FLIGHT_ERROR, {
                "err": sprintf("GRPC_STATUS_%d", result.status_code),
                "desc": result.status_message,
            });
        } else {
            notifyObservers(EVENT_FLIGHT_COMPLETE, {});
        }
    }

    #! DoExchange stream loop
    private doExchangeStreamLoop() {
        hash<auto> descriptor = ArrowFlightHelper::pathDescriptor(dataset_name);
        *ArrowSchema write_schema;
        if (flight_info.schema) {
            write_schema = new ArrowSchema(flight_info.schema);
        }
        ArrowFlightExchangeStream local_exchange = flight_client.doExchange(descriptor,
            write_schema);

        {
            AutoLock al(m);
            exchange_stream = local_exchange;
            cond.broadcast();
            # If stopEvents() was called before stream creation, half-close writes
            if (stopping) {
                local_exchange.writesDone();
            }
        }

        # Drain deadline: after stopEvents() on exchange, continue reading for up to 30s
        *date drain_deadline;

        while (True) {
            *ArrowRecordBatch batch = local_exchange.read(5s);
            if (batch) {
                notifyObservers(EVENT_FLIGHT_RECORD_BATCH, {
                    "rows": batch.toRows(),
                    "num_rows": batch.numRows(),
                });
            } else if (local_exchange.readsDone()) {
                break;
            } else {
                # Read timeout -- check if we should stop
                AutoLock al(m);
                if (stopping) {
                    if (!drain_deadline) {
                        drain_deadline = now_us() + 30s;
                    } else if (now_us() > drain_deadline) {
                        break;
                    }
                }
            }
        }

        hash<GrpcCallResult> result = local_exchange.finish();
        {
            AutoLock al(m);
            active = False;
            exchange_stream = NOTHING;
            cond.broadcast();
        }
        if (result.status_code != GRPC_STATUS_OK) {
            notifyObservers(EVENT_FLIGHT_ERROR, {
                "err": sprintf("GRPC_STATUS_%d", result.status_code),
                "desc": result.status_message,
            });
        } else {
            notifyObservers(EVENT_FLIGHT_COMPLETE, {});
        }
    }

    #! Returns the DataProvider row type based on the Arrow schema
    private *AbstractDataProviderType getRowType() {
        if (flight_info.schema) {
            try {
                ArrowSchema sch = new ArrowSchema(flight_info.schema);
                return ArrowFlightTypeHelper::schemaToDataType(sch,
                    dataset_name + "_row");
            } catch (hash<ExceptionInfo> ex) {
                # Fall through to return NOTHING
            }
        }
    }
}

} # namespace ArrowFlightDataProvider
