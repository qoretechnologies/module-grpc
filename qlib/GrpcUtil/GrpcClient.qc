# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcClient.qc gRPC client for making RPC calls

/*  GrpcClient.qc Copyright 2026 Qore Technologies, s.r.o.

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

public namespace Grpc {

#! gRPC client for making unary and streaming RPC calls
/** Binds to a specific gRPC service and uses a @ref GrpcChannel for connection pooling.

    @par Example:
    @code{.py}
ProtobufSchema schema(test_dir, "service.proto");
GrpcChannel channel("https://localhost:50051");
GrpcClient client(channel, schema, "mypackage.MyService");

hash<GrpcCallResult> result = client.call("SayHello", {"name": "World"});
printf("Response: %y\n", result.body);
printf("Status: %d %s\n", result.status_code, result.status_message);
    @endcode

    @since GrpcUtil 1.0
*/
public class GrpcClient {
    private {
        #! The gRPC channel for connections
        GrpcChannel m_channel;
        #! The protobuf schema
        ProtobufSchema m_schema;
        #! The service name
        string m_service_name;
        #! Service info from schema
        hash<ProtobufServiceInfo> m_service_info;
        #! Method info indexed by method name
        hash<string, hash<ProtobufMethodInfo>> m_methods;
    }

    #! Create a new gRPC client bound to a service
    /** @param channel the gRPC channel for connections
        @param schema the protobuf schema containing the service definition
        @param service_name the fully-qualified service name (e.g., "mypackage.MyService")

        @throw GRPC-SERVICE-ERROR if the service is not found in the schema

        @since %GrpcUtil 1.0
    */
    constructor(GrpcChannel channel, ProtobufSchema schema, string service_name) {
        m_channel = channel;
        m_schema = schema;
        m_service_name = service_name;

        # Find the service in the schema
        list<auto> services = schema.services();
        bool found = False;
        for (int i = 0; i < services.size(); ++i) {
            if (services[i].name == service_name
                    || services[i].name == service_name.substr(service_name.rfind(".") + 1)) {
                m_service_info = services[i];
                found = True;
                break;
            }
        }
        if (!found) {
            throw "GRPC-SERVICE-ERROR",
                sprintf("service '%s' not found in schema; available: %y",
                    service_name, (map $1.name, services));
        }

        # Index methods by name
        for (int i = 0; i < m_service_info.methods.size(); ++i) {
            m_methods{m_service_info.methods[i].name} = m_service_info.methods[i];
        }
    }

    #! Make a synchronous unary gRPC call
    /** @param method the method name (e.g., "SayHello")
        @param request the request data as a Qore hash
        @param opts optional call options (timeout, metadata, compression)

        @return a @ref GrpcCallResult with the response body, status, and metadata

        @throw GRPC-METHOD-ERROR if the method is not found
        @throw GRPC-ERROR if the call fails at the transport level

        @since %GrpcUtil 1.0
    */
    hash<GrpcCallResult> call(string method, hash<auto> request, *hash<GrpcCallOptions> opts) {
        hash<ProtobufMethodInfo> method_info = getMethodInfo(method);

        # Encode request
        binary encoded = m_schema.encode(method_info.input_type, request);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Build headers
        hash<string, string> headers = GrpcHelper::buildRequestHeaders(method_info.full_path,
            opts);

        # Send request
        HttpClientIo::HttpClientStreamHandle stream = m_channel.acquireStream();
        hash<auto> response;
        try {
            response = stream.request("POST", method_info.full_path, headers, framed);
        } catch (hash<ExceptionInfo> ex) {
            throw "GRPC-ERROR", sprintf("gRPC call to %s failed: %s: %s",
                method_info.full_path, ex.err, ex.desc);
        }

        return parseResponse(response, method_info.output_type);
    }

    #! Start a server-streaming call
    /** Sends a single request and returns a stream for reading multiple responses.

        @param method the method name
        @param request the request data
        @param opts optional call options

        @return a @ref GrpcClientStream for reading responses

        @throw GRPC-METHOD-ERROR if the method is not found
        @throw GRPC-ERROR if starting the stream fails

        @since %GrpcUtil 1.0
    */
    GrpcClientStream serverStream(string method, hash<auto> request,
            *hash<GrpcCallOptions> opts) {
        hash<ProtobufMethodInfo> method_info = getMethodInfo(method);

        # Encode and frame the request
        binary encoded = m_schema.encode(method_info.input_type, request);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Build headers
        hash<string, string> headers = GrpcHelper::buildRequestHeaders(
            method_info.full_path, opts);

        # Start streaming with body_streaming=True to keep the request body open
        HttpClientIo::HttpClientStreamHandle stream = m_channel.acquireStream();
        ensureStreamReady(stream);
        stream.startStreaming("POST", method_info.full_path, headers, True);

        # Send request with END_STREAM (client sends one message)
        stream.sendData(framed, True);

        return new GrpcClientStream(stream, m_schema,
            method_info.output_type, method_info.input_type, True);
    }

    #! Start a client-streaming call
    /** Returns a stream for writing multiple request messages.

        @param method the method name
        @param opts optional call options

        @return a @ref GrpcClientStream for writing requests

        @throw GRPC-METHOD-ERROR if the method is not found
        @throw GRPC-ERROR if starting the stream fails

        @since %GrpcUtil 1.0
    */
    GrpcClientStream clientStream(string method, *hash<GrpcCallOptions> opts) {
        hash<ProtobufMethodInfo> method_info = getMethodInfo(method);

        # Build headers
        hash<string, string> headers = GrpcHelper::buildRequestHeaders(
            method_info.full_path, opts);

        # Start streaming with body_streaming=True to keep the request body open
        HttpClientIo::HttpClientStreamHandle stream = m_channel.acquireStream();
        ensureStreamReady(stream);
        stream.startStreaming("POST", method_info.full_path, headers, True);

        return new GrpcClientStream(stream, m_schema,
            method_info.output_type, method_info.input_type);
    }

    #! Start a bidirectional streaming call
    /** Returns a stream for both reading and writing messages.

        @param method the method name
        @param opts optional call options

        @return a @ref GrpcClientStream for reading and writing

        @throw GRPC-METHOD-ERROR if the method is not found
        @throw GRPC-ERROR if starting the stream fails

        @since %GrpcUtil 1.0
    */
    GrpcClientStream bidiStream(string method, *hash<GrpcCallOptions> opts) {
        # bidi uses same setup as client streaming
        return clientStream(method, opts);
    }

    #! Get service info
    /** @return the @ref GrpcServiceInfo for the bound service

        @since %GrpcUtil 1.0
    */
    hash<ProtobufServiceInfo> getServiceInfo() {
        return m_service_info;
    }

    #! Get the schema
    /** @return the protobuf schema

        @since %GrpcUtil 1.0
    */
    ProtobufSchema getSchema() {
        return m_schema;
    }

    #! Ensure the HTTP/2 connection is ready for streaming
    /** startStreaming() does not wait for connection readiness like request() does.
        This method waits for the connection handshake to complete.

        @param stream the stream handle whose connection to wait on
        @param timeout_ms the timeout for connection establishment
    */
    private ensureStreamReady(HttpClientIo::HttpClientStreamHandle stream,
            timeout timeout_ms = 30s) {
        HttpClientIo::HttpClientConnection conn = stream.getConnection();
        if (!conn.isReady() && !conn.waitForReady(timeout_ms)) {
            throw "GRPC-ERROR", "HTTP/2 connection establishment timed out";
        }
    }

    private hash<ProtobufMethodInfo> getMethodInfo(string method) {
        *hash<ProtobufMethodInfo> info = m_methods{method};
        if (!info) {
            throw "GRPC-METHOD-ERROR",
                sprintf("method '%s' not found in service '%s'; available: %y",
                    method, m_service_name, keys m_methods);
        }
        return info;
    }

    private hash<GrpcCallResult> parseResponse(hash<auto> response, string output_type) {
        # Extract status from trailers
        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";
        hash<string, string> trailing_metadata();
        hash<string, string> initial_metadata();

        # Parse initial metadata from response headers
        if (response.headers) {
            map initial_metadata{$1.key} = $1.value.toString(),
                response.headers.pairIterator(),
                $1.key !~ /^:/;
        }

        # Parse trailers
        if (response.trailers) {
            if (exists response.trailers."grpc-status") {
                status_code = int(response.trailers."grpc-status");
            }
            if (exists response.trailers."grpc-message") {
                status_message = response.trailers."grpc-message";
            }
            map trailing_metadata{$1.key} = $1.value.toString(),
                response.trailers.pairIterator(),
                $1.key != "grpc-status" && $1.key != "grpc-message";
        }

        # Decode response body (if present and status is OK)
        hash<auto> body();
        if (response.body && status_code == GRPC_STATUS_OK) {
            binary response_data;
            if (response.body.typeCode() == NT_BINARY) {
                response_data = response.body;
            } else {
                response_data = binary(response.body);
            }
            if (response_data.size() >= 5) {
                hash<auto> unframed = GrpcHelper::unframeMessage(response_data);
                body = m_schema.decode(output_type, unframed.data);
            }
        }

        return <GrpcCallResult>{
            "body": body,
            "status_code": status_code,
            "status_message": status_message,
            "trailing_metadata": trailing_metadata,
            "initial_metadata": initial_metadata,
        };
    }
}

} # namespace Grpc
