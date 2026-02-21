# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcMethodDataProvider.qc Method-level data provider for gRPC method calls

/*  GrpcMethodDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Method-level data provider for making gRPC calls
/** Represents a single RPC method in a gRPC service. Supports all four RPC patterns:
    - **Unary**: single request, single response
    - **Server streaming**: single request, multiple responses (returned as list)
    - **Client streaming**: multiple requests (sent from `messages` list), single response
    - **Bidirectional streaming**: multiple requests, multiple responses

    @since GrpcDataProvider 1.0
*/
public class GrpcMethodDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info for unary methods
        const ProviderInfo = <DataProviderInfo>{
            "type": "GrpcMethodDataProvider",
            "supports_request": True,
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

        #! Cached request type
        *AbstractDataProviderType request_type;

        #! Cached response type
        *AbstractDataProviderType response_type;
    }

    #! Creates the method data provider
    /** @param channel the gRPC channel
        @param schema the protobuf schema
        @param service_info the service info
        @param method_info the method info
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
        return method_info.name;
    }

    #! Returns the data provider description
    *string getDesc() {
        string pattern;
        if (!method_info.client_streaming && !method_info.server_streaming) {
            pattern = "unary";
        } else if (method_info.server_streaming && !method_info.client_streaming) {
            pattern = "server-streaming";
        } else if (method_info.client_streaming && !method_info.server_streaming) {
            pattern = "client-streaming";
        } else {
            pattern = "bidirectional-streaming";
        }
        return sprintf("gRPC %s method `%s.%s` (%s -> %s)", pattern,
            service_info.name, method_info.name,
            method_info.input_type, method_info.output_type);
    }

    #! Returns the request type for this method
    private *AbstractDataProviderType getRequestTypeImpl() {
        if (!request_type) {
            AbstractDataProviderType inner_type = GrpcTypeHelper::messageToDataType(schema,
                method_info.input_type);

            if (method_info.client_streaming) {
                # Client-streaming and bidi: request wraps messages in a list
                HashDataType wrapper(method_info.name + ": request");
                wrapper.addField(new QoreDataField("messages", "List of messages to send",
                    new SoftListDataType("messages", inner_type)));
                request_type = wrapper;
            } else {
                request_type = inner_type;
            }
        }
        return request_type;
    }

    #! Returns the response type for this method
    private *AbstractDataProviderType getResponseTypeImpl() {
        if (!response_type) {
            AbstractDataProviderType inner_type = GrpcTypeHelper::messageToDataType(schema,
                method_info.output_type);

            if (method_info.server_streaming) {
                # Server-streaming and bidi: response is a list of messages
                response_type = new SoftListDataType(method_info.name + ": response",
                    inner_type);
            } else {
                response_type = inner_type;
            }
        }
        return response_type;
    }

    #! Makes the gRPC call
    /** Dispatches to the appropriate streaming pattern based on the method definition.

        @param req the request data
        @param request_options additional request options

        @return the response data
    */
    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        GrpcClient client(channel, schema, service_info.name);

        # Build call options
        *hash<GrpcCallOptions> call_opts;
        if (default_opts.timeout_ms) {
            call_opts = <GrpcCallOptions>{
                "timeout_ms": default_opts.timeout_ms,
            };
        }

        if (!method_info.client_streaming && !method_info.server_streaming) {
            # Unary
            return doUnaryCall(client, req, call_opts);
        } else if (method_info.server_streaming && !method_info.client_streaming) {
            # Server streaming
            return doServerStreamingCall(client, req, call_opts);
        } else if (method_info.client_streaming && !method_info.server_streaming) {
            # Client streaming
            return doClientStreamingCall(client, req, call_opts);
        } else {
            # Bidirectional
            return doBidiStreamingCall(client, req, call_opts);
        }
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        hash<DataProviderInfo> info = ProviderInfo;
        if (method_info.server_streaming) {
            info.supports_children = True;
            info.children_can_support_observers = True;
            if (method_info.client_streaming) {
                info.children_can_support_messages = True;
            }
        }
        return info;
    }

    #! Returns child provider names
    /** Server-streaming and bidi-streaming methods expose an "events" child provider
        for observable support
    */
    private *list<string> getChildProviderNamesImpl() {
        if (method_info.server_streaming) {
            return ("events",);
        }
    }

    #! Returns a child provider by name
    private *AbstractDataProvider getChildProviderImpl(string name) {
        if (name == "events" && method_info.server_streaming) {
            return new GrpcStreamEventDataProvider(channel, schema, service_info,
                method_info, default_opts);
        }
    }

    #! Makes a unary call
    private hash<auto> doUnaryCall(GrpcClient client, auto req,
            *hash<GrpcCallOptions> call_opts) {
        hash<GrpcCallResult> result = client.call(method_info.name, req, call_opts);
        if (result.status_code != GRPC_STATUS_OK) {
            throw "GRPC-ERROR", result.status_message, {
                "status_code": result.status_code,
            };
        }
        return result.body;
    }

    #! Makes a server-streaming call and returns all responses as a list
    private list<hash<auto>> doServerStreamingCall(GrpcClient client, auto req,
            *hash<GrpcCallOptions> call_opts) {
        GrpcClientStream stream = client.serverStream(method_info.name, req, call_opts);
        list<hash<auto>> results = ();
        while (*hash<auto> msg = stream.read()) {
            results += msg;
        }
        hash<GrpcCallResult> result = stream.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "GRPC-ERROR", result.status_message, {
                "status_code": result.status_code,
            };
        }
        return results;
    }

    #! Makes a client-streaming call
    private hash<auto> doClientStreamingCall(GrpcClient client, auto req,
            *hash<GrpcCallOptions> call_opts) {
        GrpcClientStream stream = client.clientStream(method_info.name, call_opts);
        if (req.messages) {
            map stream.write($1), req.messages;
        }
        stream.writesDone();
        hash<GrpcCallResult> result = stream.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "GRPC-ERROR", result.status_message, {
                "status_code": result.status_code,
            };
        }
        return result.body;
    }

    #! Makes a bidirectional-streaming call
    private list<hash<auto>> doBidiStreamingCall(GrpcClient client, auto req,
            *hash<GrpcCallOptions> call_opts) {
        GrpcClientStream stream = client.bidiStream(method_info.name, call_opts);
        # Send all messages
        if (req.messages) {
            map stream.write($1), req.messages;
        }
        stream.writesDone();
        # Read all responses
        list<hash<auto>> results = ();
        while (*hash<auto> msg = stream.read()) {
            results += msg;
        }
        hash<GrpcCallResult> result = stream.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "GRPC-ERROR", result.status_message, {
                "status_code": result.status_code,
            };
        }
        return results;
    }
}

} # namespace GrpcDataProvider
