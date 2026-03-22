# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcStreamEventDataProvider.qc Observable data provider for gRPC streaming methods

/*  GrpcStreamEventDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Contains all public definitions in the GrpcDataProvider module
public namespace GrpcDataProvider {

#! Observable data provider for gRPC streaming methods
/** Provides event-based access to gRPC server-streaming and bidirectional-streaming
    methods via the DataProvider observer pattern.

    For server-streaming methods, this provider supports only observable events
    (receive-only). For bidirectional-streaming methods, it also supports sending
    messages via the DataProvider message API.

    Events raised:
    - @ref EVENT_GRPC_STREAM_MESSAGE -- a message received from the server stream
    - @ref EVENT_GRPC_STREAM_COMPLETE -- the stream completed successfully
    - @ref EVENT_GRPC_STREAM_ERROR -- an error occurred on the stream

    Messages supported (bidi only):
    - @ref MESSAGE_GRPC_STREAM_SEND -- send a message to the server

    @par Server-streaming usage
    @code{.py}
GrpcStreamEventDataProvider event_prov = method_prov.getChildProvider("events");
event_prov.setObserverRequest({"name": "World", "id": 1});
event_prov.registerObserver(my_observer);
event_prov.observersReady();
    @endcode

    @par Bidirectional-streaming usage
    @code{.py}
GrpcStreamEventDataProvider event_prov = method_prov.getChildProvider("events");
event_prov.registerObserver(my_observer);
event_prov.observersReady();
event_prov.sendMessage(MESSAGE_GRPC_STREAM_SEND, {"name": "hello"});
event_prov.stopEvents();
    @endcode

    @since GrpcDataProvider 1.0
*/
public class GrpcStreamEventDataProvider inherits AbstractDataProvider, DelayedObservable {
    private {
        #! The gRPC channel
        GrpcChannel channel;

        #! The protobuf schema
        ProtobufSchema schema;

        #! The service info
        hash<ProtobufServiceInfo> service_info;

        #! The method info
        hash<ProtobufMethodInfo> method_info;

        #! Default options for calls
        *hash<auto> default_opts;

        #! Request data for the stream (server-streaming only)
        *hash<auto> observer_request;

        #! The active gRPC client stream (shared between send and receive paths)
        *GrpcClientStream stream;

        #! Flag: stream loop started
        bool started = False;

        #! Flag: stop requested
        bool stopping = False;

        #! Flag: stream is active (False after stream completes or errors)
        bool active = True;

        #! Mutex for state synchronization
        Mutex m();

        #! Condition variable for state changes (stream ready, active flag)
        Condition cond();
    }

    #! Creates the stream event data provider
    /** @param channel the gRPC channel
        @param schema the protobuf schema
        @param service_info the service info
        @param method_info the method info (must be server-streaming or bidi-streaming)
        @param default_opts default options for calls
    */
    constructor(GrpcChannel channel, ProtobufSchema schema,
            hash<ProtobufServiceInfo> service_info, hash<ProtobufMethodInfo> method_info,
            *hash<auto> default_opts) {
        self.channel = channel;
        self.schema = schema;
        self.service_info = service_info;
        self.method_info = method_info;
        self.default_opts = default_opts;
    }

    #! Returns the data provider name
    string getName() {
        return "events";
    }

    #! Returns the data provider description
    *string getDesc() {
        if (method_info.client_streaming) {
            return sprintf("Observable event provider for gRPC bidirectional-streaming method `%s.%s`",
                service_info.name, method_info.name);
        }
        return sprintf("Observable event provider for gRPC server-streaming method `%s.%s`",
            service_info.name, method_info.name);
    }

    #! Sets the request data for the stream
    /** @param req the request data to send when starting the stream

        @note Only meaningful for server-streaming methods; for bidi methods, messages are
        sent via sendMessage() after the stream is opened
    */
    setObserverRequest(*hash<auto> req) {
        observer_request = req;
    }

    #! Called when all observers are registered; starts the stream
    observersReady() {
        {
            AutoLock al(m);
            if (started) {
                throw "GRPC-OBSERVABLE-ERROR", "observersReady() has already been called";
            }
            started = True;
        }
        background streamLoop();
    }

    #! Called to stop event generation
    /** For bidi streams, signals writes-done so the server knows no more messages
        will be sent. The read loop will exit when the server closes its side.
    */
    stopEvents() {
        AutoLock al(m);
        stopping = True;
        # Wake up any threads waiting in waitForReady() so they see the stop
        cond.broadcast();
        if (stream && method_info.client_streaming) {
            stream.writesDone();
        }
    }

    #! Returns True if the stream is still active
    /** @return True if events may still be generated, False after the stream has completed
        or errored
    */
    bool isActive() {
        AutoLock al(m);
        return active;
    }

    #! Blocks until the bidi stream is connected and ready for sendMessage()
    /** @param timeout maximum time to wait
        @return True if the stream is ready, False on timeout

        @note Only meaningful for bidi-streaming methods; for server-streaming methods,
        the stream is ready as soon as observersReady() is called

        @since GrpcDataProvider 1.0
    */
    bool waitForReady(timeout timeout = 10s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout);
        while (!stream && active && !stopping) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return exists stream;
    }

    #! Blocks until the stream is no longer active
    /** @param timeout maximum time to wait
        @return True if the stream became inactive, False on timeout

        @since GrpcDataProvider 1.0
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
    /** Dynamically sets \c supports_messages based on whether the method is bidi-streaming
    */
    private hash<DataProviderInfo> getStaticInfoImpl() {
        hash<DataProviderInfo> info = <DataProviderInfo>{
            "type": "GrpcStreamEventDataProvider",
            "supports_observable": True,
        };
        if (method_info.client_streaming) {
            info.supports_messages = MSG_Async;
        }
        return info;
    }

    #! Sends a message to the gRPC server on the bidirectional stream
    /** @param message_id the message ID (must be @ref MESSAGE_GRPC_STREAM_SEND)
        @param msg the message data
        @param send_message_options optional send options (unused)

        @throw GRPC-STREAM-ERROR if the stream is not active or has been stopped
    */
    private sendMessageImpl(string message_id, auto msg, *hash<auto> send_message_options) {
        if (message_id != MESSAGE_GRPC_STREAM_SEND) {
            throw "GRPC-STREAM-ERROR", sprintf("unsupported message ID %y; expected %y",
                message_id, MESSAGE_GRPC_STREAM_SEND);
        }
        if (!method_info.client_streaming) {
            throw "GRPC-STREAM-ERROR", "sendMessage() is only supported on bidirectional "
                "streaming methods";
        }
        AutoLock al(m);
        if (!stream || stopping) {
            throw "GRPC-STREAM-ERROR", "stream is not active";
        }
        stream.write(msg);
    }

    #! Returns the message types supported by this provider
    /** For bidi-streaming methods, returns the @ref MESSAGE_GRPC_STREAM_SEND message type
        with the method's input type
    */
    private hash<string, hash<DataProviderMessageInfo>> getMessageTypesImpl() {
        if (!method_info.client_streaming) {
            # Server-streaming only: no send capability
            return {};
        }
        return {
            MESSAGE_GRPC_STREAM_SEND: <DataProviderMessageInfo>{
                "desc": "Send a message to the gRPC server on the bidirectional stream",
                "type": GrpcTypeHelper::messageToDataType(schema, method_info.input_type),
            },
        };
    }

    #! Returns example event data for the given event
    /** @param event_id the event ID

        @return example data for the event
    */
    private auto getExampleEventDataImpl(string event_id) {
        switch (event_id) {
            case EVENT_GRPC_STREAM_COMPLETE:
                return {};

            case EVENT_GRPC_STREAM_ERROR:
                return {
                    "err": "GRPC_STATUS_13",
                    "desc": "Internal server error",
                };

            case EVENT_GRPC_STREAM_MESSAGE: {
                *AbstractDataProviderType t = getEventTypesImpl(){event_id}.type;
                return t ? t.getExampleValue() : {};
            }
        }
    }

    #! Returns the event types supported by this provider
    private hash<string, hash<DataProviderMessageInfo>> getEventTypesImpl() {
        return {
            EVENT_GRPC_STREAM_MESSAGE: <DataProviderMessageInfo>{
                "desc": "A message received from the gRPC server stream",
                "type": GrpcTypeHelper::messageToDataType(schema, method_info.output_type),
            },
            EVENT_GRPC_STREAM_COMPLETE: <DataProviderMessageInfo>{
                "desc": "The gRPC server stream completed successfully",
                "type": GrpcStreamCompleteDataType,
            },
            EVENT_GRPC_STREAM_ERROR: <DataProviderMessageInfo>{
                "desc": "An error occurred on the gRPC server stream",
                "type": GrpcStreamErrorDataType,
            },
        };
    }

    #! Background thread that reads the stream and notifies observers
    /** Handles both server-streaming and bidi-streaming patterns:
        - Server-streaming: opens stream with request data, reads until server closes
          or stopEvents() is called
        - Bidi-streaming: opens stream without request, stores stream pointer for
          sendMessage(), reads until server closes (even after stopEvents() signals
          writesDone, continues reading server responses)

        Uses a 5-second read timeout to allow periodic checking of the \c stopping flag.
        For server-streaming, a stop request breaks the loop immediately.
        For bidi-streaming, a stop request only signals writesDone(); the loop continues
        reading until the server closes its side (\c readsDone()).
    */
    private streamLoop() {
        try {
            GrpcClient client(channel, schema, service_info.name);

            # Build call options
            *hash<GrpcCallOptions> call_opts;
            if (default_opts.timeout_ms) {
                call_opts = <GrpcCallOptions>{
                    "timeout_ms": default_opts.timeout_ms,
                };
            }

            GrpcClientStream local_stream;
            if (method_info.client_streaming) {
                # Bidi-streaming: open stream, writes stay open for sendMessage()
                local_stream = client.bidiStream(method_info.name, call_opts);
                {
                    AutoLock al(m);
                    stream = local_stream;
                    cond.broadcast();
                    # If stopEvents() was called before stream creation, immediately
                    # half-close writes so the server sees end-of-client-input
                    if (stopping) {
                        local_stream.writesDone();
                    }
                }
            } else {
                # Server-streaming: send request and half-close writes
                local_stream = client.serverStream(method_info.name,
                    observer_request ?? {}, call_opts);
            }

            # Drain deadline: after stopEvents() is called on a bidi stream, we continue
            # reading server responses for up to 30s before giving up
            *date drain_deadline;

            while (True) {
                *hash<auto> msg = local_stream.read(5s);
                if (msg) {
                    {
                        AutoLock al(m);
                        if (stopping && !method_info.client_streaming) {
                            # Server-streaming: stop immediately
                            break;
                        }
                    }
                    notifyObservers(EVENT_GRPC_STREAM_MESSAGE, msg);
                } else if (local_stream.readsDone()) {
                    # Stream ended (server closed its side)
                    break;
                } else {
                    # Read timeout -- check if we should stop
                    AutoLock al(m);
                    if (stopping) {
                        if (!method_info.client_streaming) {
                            # Server-streaming: stop immediately
                            break;
                        }
                        # Bidi: enforce drain timeout to prevent indefinite hang
                        if (!drain_deadline) {
                            drain_deadline = now_us() + 30s;
                        } else if (now_us() > drain_deadline) {
                            break;
                        }
                    }
                }
            }

            # Check if we stopped voluntarily for server-streaming
            {
                AutoLock al(m);
                if (stopping && !method_info.client_streaming) {
                    active = False;
                    stream = NOTHING;
                    cond.broadcast();
                    return;
                }
            }

            hash<GrpcCallResult> result = local_stream.finish();
            {
                AutoLock al(m);
                active = False;
                stream = NOTHING;
                cond.broadcast();
            }
            if (result.status_code != GRPC_STATUS_OK) {
                notifyObservers(EVENT_GRPC_STREAM_ERROR, {
                    "err": sprintf("GRPC_STATUS_%d", result.status_code),
                    "desc": result.status_message,
                });
            } else {
                notifyObservers(EVENT_GRPC_STREAM_COMPLETE, {});
            }
        } catch (hash<ExceptionInfo> ex) {
            {
                AutoLock al(m);
                active = False;
                stream = NOTHING;
                cond.broadcast();
            }
            notifyObservers(EVENT_GRPC_STREAM_ERROR, {
                "err": ex.err,
                "desc": ex.desc,
            });
        }
    }
}

} # namespace GrpcDataProvider
