# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcStreamEventDataProvider.qc Observable data provider for gRPC server streams

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

#! Observable data provider for gRPC server-streaming methods
/** Provides event-based access to gRPC server streams via the DataProvider observer pattern.

    Events raised:
    - @ref EVENT_GRPC_STREAM_MESSAGE -- a message received from the server stream
    - @ref EVENT_GRPC_STREAM_COMPLETE -- the stream completed successfully
    - @ref EVENT_GRPC_STREAM_ERROR -- an error occurred on the stream

    @par Usage
    @code{.py}
GrpcStreamEventDataProvider event_prov = method_prov.getChildProvider("events");
event_prov.setObserverRequest({"name": "World", "id": 1});
event_prov.registerObserver(my_observer);
event_prov.observersReady();
    @endcode

    @since GrpcDataProvider 1.0
*/
public class GrpcStreamEventDataProvider inherits AbstractDataProvider, DelayedObservable {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "GrpcStreamEventDataProvider",
            "supports_observable": True,
        };
    }

    private {
        #! The gRPC channel
        GrpcChannel channel;

        #! The protobuf schema
        ProtobufSchema schema;

        #! The service info
        hash<GrpcServiceInfo> service_info;

        #! The method info
        hash<GrpcMethodInfo> method_info;

        #! Default options for calls
        *hash<auto> default_opts;

        #! Request data for the stream
        *hash<auto> observer_request;

        #! Flag: stream loop started
        bool started = False;

        #! Flag: stop requested
        bool stopping = False;

        #! Mutex for state synchronization
        Mutex m();
    }

    #! Creates the stream event data provider
    /** @param channel the gRPC channel
        @param schema the protobuf schema
        @param service_info the service info
        @param method_info the method info (must be server-streaming, not client-streaming)
        @param default_opts default options for calls
    */
    constructor(GrpcChannel channel, ProtobufSchema schema,
            hash<GrpcServiceInfo> service_info, hash<GrpcMethodInfo> method_info,
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
        return sprintf("Observable event provider for gRPC server-streaming method `%s.%s`",
            service_info.name, method_info.name);
    }

    #! Sets the request data for the stream
    /** @param req the request data to send when starting the stream
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
    stopEvents() {
        AutoLock al(m);
        stopping = True;
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
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

    #! Background thread that reads the server stream and notifies observers
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

            GrpcClientStream stream = client.serverStream(method_info.name,
                observer_request ?? {}, call_opts);

            while (*hash<auto> msg = stream.read(5s)) {
                {
                    AutoLock al(m);
                    if (stopping) {
                        break;
                    }
                }
                notifyObservers(EVENT_GRPC_STREAM_MESSAGE, msg);
            }

            # Check if we stopped voluntarily
            {
                AutoLock al(m);
                if (stopping) {
                    return;
                }
            }

            hash<GrpcCallResult> result = stream.finish();
            if (result.status_code != GRPC_STATUS_OK) {
                notifyObservers(EVENT_GRPC_STREAM_ERROR, {
                    "err": sprintf("GRPC_STATUS_%d", result.status_code),
                    "desc": result.status_message,
                });
            } else {
                notifyObservers(EVENT_GRPC_STREAM_COMPLETE, {});
            }
        } catch (hash<ExceptionInfo> ex) {
            notifyObservers(EVENT_GRPC_STREAM_ERROR, {
                "err": ex.err,
                "desc": ex.desc,
            });
        }
    }
}

} # namespace GrpcDataProvider
