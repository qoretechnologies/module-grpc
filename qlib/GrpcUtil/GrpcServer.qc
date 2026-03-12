# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcServer.qc gRPC server implementation

/*  GrpcServer.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! gRPC server supporting unary RPC calls
/** Implements a gRPC server on top of Qore's HTTP/2 infrastructure using
    direct Socket operations for full trailer support.

    @par Example:
    @code{.py}
ProtobufSchema schema(proto_dir, "service.proto");
GrpcServer server(schema);
server.registerHandler("MyService", "SayHello", sub(hash<auto> request, hash<string, string> metadata) {
    return {"message": "Hello, " + request.name, "status": 0};
});
int port = server.addInsecurePort("localhost:0");
server.start();
# ... server is running ...
server.shutdown();
    @endcode

    @par Example (with reflection enabled):
    @code{.py}
ProtobufSchema schema(proto_dir, "service.proto");
GrpcServer server(schema, <GrpcServerOptions>{"enable_reflection": True});
server.registerHandler("MyService", "SayHello",
    hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
        return {"message": "Hello, " + request.name};
    });
server.addInsecurePort("localhost:50051");
server.start();
# Clients can now discover services via grpcurl or GrpcReflectionClient
    @endcode

    @since GrpcUtil 1.0
*/
public class GrpcServer {
    private {
        #! Protobuf schema
        ProtobufSchema m_schema;

        #! Server options
        *hash<GrpcServerOptions> m_opts;

        #! Registered handlers: key = "service/method", value = code callback
        hash<string, code> m_handlers;

        #! Method info cache: key = "service/method"
        hash<string, hash<GrpcMethodInfo>> m_method_info;

        #! Service info from schema
        hash<string, hash<GrpcServiceInfo>> m_services;

        #! Listener sockets
        list<Socket> m_listeners;

        #! SSL certificate and key for secure ports
        list<hash<auto>> m_ssl_configs;

        #! Whether the server is running
        bool m_running = False;

        #! Shutdown flag
        bool m_shutdown = False;

        #! Counter for active connections
        Counter m_active_connections(0);

        #! Counter for active accept threads
        Counter m_accept_threads(0);

        #! Active client sockets (for shutdown)
        list<Socket> m_client_sockets = ();

        #! Mutex for state
        Mutex m_mutex();

        #! Reflection service instance (kept alive for handler closures)
        *GrpcReflectionService m_reflection;
    }

    #! Create a gRPC server
    /** @param schema the protobuf schema containing service definitions
        @param opts optional server options

        @since %GrpcUtil 1.0
    */
    constructor(ProtobufSchema schema, *hash<GrpcServerOptions> opts) {
        m_opts = opts;

        # If reflection is enabled, wrap the schema with the reflection service
        if (opts.enable_reflection) {
            GrpcReflectionService reflection(schema);
            m_schema = reflection.getCombinedSchema();
            m_reflection = reflection;
        } else {
            m_schema = schema;
        }

        # Index services from schema
        list<hash<GrpcServiceInfo>> services = m_schema.services();
        for (int i = 0; i < services.size(); ++i) {
            m_services{services[i].name} = services[i];
            for (int j = 0; j < services[i].methods.size(); ++j) {
                hash<GrpcMethodInfo> method = services[i].methods[j];
                m_method_info{services[i].name + "/" + method.name} = method;
            }
        }

        # Register deferred reflection handlers now that services are indexed
        if (m_reflection) {
            m_reflection.registerHandlers(self);
        }
    }

    #! Register a handler for a service method
    /** @param service the service name (e.g., "MyService")
        @param method the method name (e.g., "SayHello")
        @param handler the handler callback

        For unary calls, the handler signature is:
        @code{.py}
hash<auto> sub(hash<auto> request, hash<string, string> metadata) {}
        @endcode

        @throw GRPC-HANDLER-ERROR if the service/method is not found in the schema

        @since %GrpcUtil 1.0
    */
    registerHandler(string service, string method, code handler) {
        string key = service + "/" + method;
        if (!m_method_info{key}) {
            throw "GRPC-HANDLER-ERROR",
                sprintf("method '%s/%s' not found in schema", service, method);
        }
        m_handlers{key} = handler;
    }

    #! Add an insecure (plaintext h2c) listener
    /** @param addr the address to bind (e.g., "localhost:50051" or "localhost:0")
        @return the port number bound

        @throw GRPC-BIND-ERROR if the address cannot be bound

        @since %GrpcUtil 1.0
    */
    int addInsecurePort(string addr) {
        Socket sock();
        try {
            sock.bind(addr);
            sock.listen();
        } catch (hash<ExceptionInfo> ex) {
            throw "GRPC-BIND-ERROR", sprintf("failed to bind '%s': %s: %s",
                addr, ex.err, ex.desc);
        }
        int port = sock.getPort();
        m_listeners += sock;
        return port;
    }

    #! Add a secure (TLS) listener
    /** @param addr the address to bind
        @param ssl SSL/TLS options with certificate and key
        @return the port number bound

        @throw GRPC-BIND-ERROR if the address cannot be bound

        @since %GrpcUtil 1.0
    */
    int addSecurePort(string addr, hash<GrpcSslOptions> ssl) {
        Socket sock();
        if (ssl.server_cert) {
            SSLCertificate cert(ssl.server_cert);
            sock.setCertificate(cert);
        }
        if (ssl.server_key) {
            SSLPrivateKey key(ssl.server_key);
            sock.setPrivateKey(key);
        }
        try {
            sock.bind(addr);
            sock.listen();
        } catch (hash<ExceptionInfo> ex) {
            throw "GRPC-BIND-ERROR", sprintf("failed to bind '%s': %s: %s",
                addr, ex.err, ex.desc);
        }
        int port = sock.getPort();
        m_listeners += sock;
        m_ssl_configs += {"port": port, "ssl": ssl};
        return port;
    }

    #! Start the server (non-blocking)
    /** Starts accept threads for each listener. Returns immediately.

        @throw GRPC-SERVER-ERROR if the server is already running

        @since %GrpcUtil 1.0
    */
    start() {
        AutoLock al(m_mutex);
        if (m_running) {
            throw "GRPC-SERVER-ERROR", "server is already running";
        }
        m_running = True;
        m_shutdown = False;

        # Start accept loop for each listener
        for (int i = 0; i < m_listeners.size(); ++i) {
            Socket listener = m_listeners[i];
            bool ssl = isSecurePort(listener.getPort());
            m_accept_threads.inc();
            background acceptLoop(listener, ssl);
        }
    }

    #! Block until the server shuts down
    /** Blocks the calling thread until all accept threads and active connections have
        completed. Typically called after start() in the main thread.

        @since %GrpcUtil 1.0
    */
    wait() {
        m_accept_threads.waitForZero();
        m_active_connections.waitForZero();
    }

    #! Shut down the server gracefully
    /** Closes all listeners and active connections, then waits for in-progress
        requests to complete.

        @param timeout_ms optional timeout in milliseconds for graceful shutdown;
        if not provided, waits indefinitely for connections to drain

        @since %GrpcUtil 1.0
    */
    shutdown(*int timeout_ms) {
        {
            AutoLock al(m_mutex);
            m_shutdown = True;
        }
        # Close listeners to unblock accept()
        for (int i = 0; i < m_listeners.size(); ++i) {
            m_listeners[i].close();
        }
        # Close active client sockets to unblock connectionLoop()
        {
            AutoLock al(m_mutex);
            for (int i = 0; i < m_client_sockets.size(); ++i) {
                try {
                    m_client_sockets[i].close();
                } catch () {
                    # Ignore errors closing client sockets
                }
            }
        }
        if (timeout_ms) {
            m_active_connections.waitForZero(milliseconds(timeout_ms));
        } else {
            m_active_connections.waitForZero();
        }
        m_accept_threads.waitForZero();
        {
            AutoLock al(m_mutex);
            m_running = False;
            m_client_sockets = ();
        }
    }

    #! Check if the server is running
    /** @return True if the server has been started and has not yet been shut down

        @since %GrpcUtil 1.0
    */
    bool isRunning() {
        return m_running;
    }

    private bool isSecurePort(int port) {
        for (int i = 0; i < m_ssl_configs.size(); ++i) {
            if (m_ssl_configs[i].port == port) {
                return True;
            }
        }
        return False;
    }

    #! Drive a poll operation to completion
    private drivePoll(AbstractPollOperation op, int max_iterations = 5000) {
        int i = 0;
        while (!op.goalReached() && !m_shutdown && i < max_iterations) {
            *hash<SocketPollInfo> info = op.continuePoll();
            if (!info) {
                break;
            }
            Socket::poll((info,), 100ms);
            ++i;
        }
    }

    #! Accept loop for a listener socket
    private acceptLoop(Socket listener, bool ssl) {
        on_exit m_accept_threads.dec();

        while (!m_shutdown) {
            *Socket client;
            try {
                client = listener.accept(100ms);
            } catch (hash<ExceptionInfo> ex) {
                if (m_shutdown) {
                    break;
                }
                if (ex.err == "SOCKET-TIMEOUT" || ex.err == "SOCKET-NOT-OPEN") {
                    continue;
                }
                @debug {
                    printf("GrpcServer::acceptLoop(): unexpected error accepting "
                        "connection: %s: %s\n", ex.err, ex.desc);
                }
                continue;
            }
            if (!client) {
                continue;
            }

            m_active_connections.inc();
            background connectionLoop(client, ssl);
        }
    }

    #! Handle a single connection
    private connectionLoop(Socket client, bool ssl) {
        on_exit m_active_connections.dec();
        on_exit removeClientSocket(client);
        addClientSocket(client);

        try {
            client.setNoDelay(True);
            if (ssl) {
                client.setAlpnProtocols(("h2",));
                client.upgradeServerToSSL();
            }

            # HTTP/2 connection preface + settings exchange happens during first request read
            while (!m_shutdown) {
                # Read HTTP/2 request headers (headers_only mode for streaming support)
                AbstractPollOperation read_op = client.startPollReadHttp2Request(
                    {"headers_only": True});
                drivePoll(read_op);
                if (!read_op.goalReached()) {
                    break;
                }

                hash<auto> request = read_op.getOutput();
                int stream_id = request.stream_id;

                # Check if this was a headers-only dispatch (stream still in map)
                bool headers_only = request.hdr ?? False;

                if (headers_only) {
                    # Headers-only dispatch: determine method type and handle accordingly
                    string handler_key;
                    *hash<GrpcMethodInfo> method_info = lookupMethodFromPath(
                        request.path, \handler_key);

                    if (method_info && method_info.client_streaming) {
                        # Client-streaming or bidi: dispatch live
                        handleRequestLive(client, request, method_info, handler_key);
                    } else {
                        # Unary / server-streaming: read remaining body, then dispatch
                        binary body_data = readStreamBody(client, stream_id);
                        request.body = body_data;
                        handleRequest(client, request);
                    }

                    # Clean up dispatched stream from HTTP/2 session
                    client.cleanupHttp2Stream(stream_id);
                } else {
                    # Full request already received (H2S_REQUEST_READY)
                    handleRequest(client, request);
                }
            }
        } catch (hash<ExceptionInfo> ex) {
            if (!m_shutdown && ex.err != "SOCKET-CLOSED" && ex.err != "SOCKET-NOT-OPEN") {
                @debug {
                    printf("GrpcServer::connectionLoop(): unexpected error: %s: %s\n",
                        ex.err, ex.desc);
                }
            }
        }
    }

    private addClientSocket(Socket sock) {
        AutoLock al(m_mutex);
        m_client_sockets += sock;
    }

    private removeClientSocket(Socket sock) {
        AutoLock al(m_mutex);
        # Remove sock from the list by rebuilding without it
        int idx = -1;
        for (int i = 0; i < m_client_sockets.size(); ++i) {
            if (m_client_sockets[i] == sock) {
                idx = i;
                break;
            }
        }
        if (idx >= 0) {
            splice m_client_sockets, idx, 1;
        }
    }

    #! Look up method info from request path
    /** @param path the gRPC request path (e.g., "/package.Service/Method")
        @return the method info, or NOTHING if not found
    */
    private *hash<GrpcMethodInfo> lookupMethodFromPath(string path, reference<string> handler_key) {
        *list<string> parts = path.split("/");
        if (!parts || parts.size() < 3) {
            return NOTHING;
        }
        string full_service = parts[1];
        string method_name = parts[2];
        string service_name = full_service;
        int dot_pos = full_service.rfind(".");
        if (dot_pos >= 0) {
            service_name = full_service.substr(dot_pos + 1);
        }
        handler_key = service_name + "/" + method_name;
        return m_method_info{handler_key};
    }

    #! Read remaining body data from an HTTP/2 stream (for non-streaming methods)
    /** After headers-only dispatch, reads all remaining body data until END_STREAM.
        @param client the client socket
        @param stream_id the HTTP/2 stream ID
        @return the accumulated body data
    */
    private binary readStreamBody(Socket client, int stream_id) {
        binary body = binary();
        while (True) {
            *binary chunk = client.readHttp2StreamDataBlock(stream_id, 5s);
            if (chunk) {
                body += chunk;
            } else if (client.isHttp2StreamComplete(stream_id)) {
                break;
            }
        }
        return body;
    }

    #! Handle a live streaming request (client-streaming or bidi)
    /** Dispatches the handler immediately with a live GrpcServerStream that reads
        from the HTTP/2 stream incrementally.

        @param client the client socket
        @param request the request headers (from headers-only poll)
        @param method_info the method info from schema
    */
    private handleRequestLive(Socket client, hash<auto> request,
            hash<GrpcMethodInfo> method_info, string handler_key) {
        int stream_id = request.stream_id;
        hash<string, string> metadata();
        if (request.headers) {
            map metadata{$1.key} = $1.value.toString(),
                request.headers.pairIterator(),
                $1.key !~ /^:/ && $1.key != "content-type" && $1.key != "te";
        }

        *date deadline;
        if (metadata."grpc-timeout") {
            *int timeout_ms = GrpcHelper::parseTimeout(metadata."grpc-timeout");
            if (timeout_ms) {
                deadline = now_us() + milliseconds(timeout_ms);
            }
            remove metadata."grpc-timeout";
        }

        *code handler = m_handlers{handler_key};
        if (!handler) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("method not found: %s", handler_key));
            return;
        }

        if (method_info.server_streaming && method_info.client_streaming) {
            handleBidiStreamLive(client, stream_id, handler, method_info, metadata, deadline);
        } else {
            handleClientStreamLive(client, stream_id, handler, method_info, metadata, deadline);
        }
    }

    #! Handle a live bidirectional-streaming RPC call
    /** Handler reads and writes messages incrementally via the live GrpcServerStream.
    */
    private handleBidiStreamLive(Socket client, int stream_id, code handler,
            hash<GrpcMethodInfo> method_info, hash<string, string> metadata,
            *date deadline) {
        # Create live server stream
        GrpcServerStream stream(client, stream_id, m_schema,
            method_info.input_type, method_info.output_type, metadata, True);

        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";

        try {
            handler(stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            status_code = exceptionToStatusCode(ex.err);
            status_message = sprintf("%s: %s", ex.err, ex.desc);
        }

        if (status_code == GRPC_STATUS_OK && deadline && now_us() > deadline) {
            status_code = GRPC_STATUS_DEADLINE_EXCEEDED;
            status_message = "deadline exceeded";
        }

        stream.ensureHeadersSent();
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(status_code);
        trailers."grpc-message" = status_message;
        client.sendHttp2Trailers(stream_id, trailers);

        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }

    #! Handle a live client-streaming RPC call
    /** Handler reads all messages incrementally via the live GrpcServerStream
        and returns a single response hash.
    */
    private handleClientStreamLive(Socket client, int stream_id, code handler,
            hash<GrpcMethodInfo> method_info, hash<string, string> metadata,
            *date deadline) {
        # Create live server stream
        GrpcServerStream stream(client, stream_id, m_schema,
            method_info.input_type, method_info.output_type, metadata, True);

        hash<auto> response_body;
        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";

        try {
            response_body = handler(stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            sendErrorResponse(client, stream_id, exceptionToStatusCode(ex.err),
                sprintf("%s: %s", ex.err, ex.desc));
            return;
        }

        # Check deadline after handler returns
        if (deadline && now_us() > deadline) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_DEADLINE_EXCEEDED,
                "deadline exceeded");
            return;
        }

        # Encode response
        binary encoded = m_schema.encode(method_info.output_type, response_body);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Send response with trailers, including custom trailing metadata
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(status_code);
        trailers."grpc-message" = status_message;

        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2StreamData(stream_id, framed, False);
        client.sendHttp2Trailers(stream_id, trailers);

        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }

    #! Handle a single gRPC request (buffered mode - for unary and server-streaming)
    private handleRequest(Socket client, hash<auto> request) {
        int stream_id = request.stream_id;
        string path = request.path ?? "";
        hash<string, string> metadata();

        # Extract metadata from headers
        if (request.headers) {
            map metadata{$1.key} = $1.value.toString(),
                request.headers.pairIterator(),
                $1.key !~ /^:/ && $1.key != "content-type" && $1.key != "te";
        }

        # Parse deadline from grpc-timeout header
        *date deadline;
        if (metadata."grpc-timeout") {
            *int timeout_ms = GrpcHelper::parseTimeout(metadata."grpc-timeout");
            if (timeout_ms) {
                deadline = now_us() + milliseconds(timeout_ms);
            }
            # Remove grpc-timeout from metadata passed to handler
            remove metadata."grpc-timeout";
        }

        # Parse gRPC method path: /package.Service/Method
        *list<string> parts = path.split("/");
        if (!parts || parts.size() < 3) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("invalid gRPC path: %y", path));
            return;
        }
        # parts[0] is empty (leading /), parts[1] is service, parts[2] is method
        string full_service = parts[1];
        string method_name = parts[2];

        # Extract short service name (after last dot)
        string service_name = full_service;
        int dot_pos = full_service.rfind(".");
        if (dot_pos >= 0) {
            service_name = full_service.substr(dot_pos + 1);
        }

        string handler_key = service_name + "/" + method_name;
        *code handler = m_handlers{handler_key};
        if (!handler) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("method not found: %s", handler_key));
            return;
        }

        *hash<GrpcMethodInfo> method_info = m_method_info{handler_key};
        if (!method_info) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_INTERNAL,
                sprintf("method info not found: %s", handler_key));
            return;
        }

        # Get body data
        binary body_data = binary();
        if (request.body) {
            if (request.body.typeCode() == NT_BINARY) {
                body_data = request.body;
            } else {
                body_data = binary(request.body);
            }
        }

        # Dispatch based on streaming type
        if (method_info.server_streaming && method_info.client_streaming) {
            # Bidirectional streaming
            handleBidiStream(client, stream_id, handler, method_info, metadata,
                body_data, deadline);
        } else if (method_info.server_streaming) {
            # Server streaming
            handleServerStream(client, stream_id, handler, method_info, metadata,
                body_data, deadline);
        } else if (method_info.client_streaming) {
            # Client streaming
            handleClientStream(client, stream_id, handler, method_info, metadata,
                body_data, deadline);
        } else {
            # Unary
            handleUnary(client, stream_id, handler, method_info, metadata,
                body_data, deadline);
        }
    }

    #! Handle a unary RPC call
    private handleUnary(Socket client, int stream_id, code handler,
            hash<GrpcMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline) {
        # Decode request body
        hash<auto> request_body();
        if (body_data.size() >= 5) {
            hash<auto> unframed = GrpcHelper::unframeMessage(body_data);
            request_body = m_schema.decode(method_info.input_type, unframed.data);
        }

        # Call handler
        hash<auto> response_body;
        try {
            response_body = handler(request_body, metadata);
        } catch (hash<ExceptionInfo> ex) {
            sendErrorResponse(client, stream_id, exceptionToStatusCode(ex.err),
                sprintf("%s: %s", ex.err, ex.desc));
            return;
        }

        # Check deadline after handler returns
        if (deadline && now_us() > deadline) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_DEADLINE_EXCEEDED,
                "deadline exceeded");
            return;
        }

        # Encode response
        binary encoded = m_schema.encode(method_info.output_type, response_body);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Send response with trailers
        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2StreamData(stream_id, framed, False);
        client.sendHttp2Trailers(stream_id, {
            "grpc-status": string(GRPC_STATUS_OK),
            "grpc-message": "OK",
        });

        # Flush
        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }

    #! Handle a server-streaming RPC call
    /** Handler signature: \c sub(hash<auto> request, GrpcServerStream stream,
        hash<string, string> metadata) {}
    */
    private handleServerStream(Socket client, int stream_id, code handler,
            hash<GrpcMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline) {
        # Decode single request
        hash<auto> request_body();
        if (body_data.size() >= 5) {
            hash<auto> unframed = GrpcHelper::unframeMessage(body_data);
            request_body = m_schema.decode(method_info.input_type, unframed.data);
        }

        # Create server stream for handler to write responses
        GrpcServerStream stream(client, stream_id, m_schema,
            method_info.input_type, method_info.output_type, metadata);

        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";

        try {
            handler(request_body, stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            status_code = exceptionToStatusCode(ex.err);
            status_message = sprintf("%s: %s", ex.err, ex.desc);
        }

        # Check deadline after handler returns
        if (status_code == GRPC_STATUS_OK && deadline && now_us() > deadline) {
            status_code = GRPC_STATUS_DEADLINE_EXCEEDED;
            status_message = "deadline exceeded";
        }

        # Ensure response headers are sent even if handler wrote nothing
        # (e.g., empty server stream). Trailers require initial HEADERS.
        stream.ensureHeadersSent();

        # Send trailers to complete the stream, including custom trailing metadata
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(status_code);
        trailers."grpc-message" = status_message;
        client.sendHttp2Trailers(stream_id, trailers);

        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }

    #! Handle a client-streaming RPC call
    /** Handler signature: \c hash<auto> sub(GrpcServerStream stream,
        hash<string, string> metadata) {}
    */
    private handleClientStream(Socket client, int stream_id, code handler,
            hash<GrpcMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline) {
        # Parse all client messages from the request body
        list<hash<auto>> messages = ();
        if (body_data.size() >= 5) {
            list<hash<auto>> frames = GrpcHelper::unframeMessages(body_data);
            for (int i = 0; i < frames.size(); ++i) {
                messages += m_schema.decode(method_info.input_type, frames[i].data);
            }
        }

        # Create server stream with pre-parsed messages
        GrpcServerStream stream(client, stream_id, m_schema,
            method_info.input_type, method_info.output_type, metadata, messages);

        hash<auto> response_body;
        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";

        try {
            response_body = handler(stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            sendErrorResponse(client, stream_id, exceptionToStatusCode(ex.err),
                sprintf("%s: %s", ex.err, ex.desc));
            return;
        }

        # Check deadline after handler returns
        if (deadline && now_us() > deadline) {
            sendErrorResponse(client, stream_id, GRPC_STATUS_DEADLINE_EXCEEDED,
                "deadline exceeded");
            return;
        }

        # Encode response
        binary encoded = m_schema.encode(method_info.output_type, response_body);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Send response with trailers, including custom trailing metadata
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(status_code);
        trailers."grpc-message" = status_message;

        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2StreamData(stream_id, framed, False);
        client.sendHttp2Trailers(stream_id, trailers);

        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }

    #! Handle a bidirectional-streaming RPC call
    /** Handler signature: \c sub(GrpcServerStream stream,
        hash<string, string> metadata) {}
    */
    private handleBidiStream(Socket client, int stream_id, code handler,
            hash<GrpcMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline) {
        # Parse all client messages from the request body
        list<hash<auto>> messages = ();
        if (body_data.size() >= 5) {
            list<hash<auto>> frames = GrpcHelper::unframeMessages(body_data);
            for (int i = 0; i < frames.size(); ++i) {
                messages += m_schema.decode(method_info.input_type, frames[i].data);
            }
        }

        # Create server stream with pre-parsed messages (for reading)
        # and direct socket access (for writing)
        GrpcServerStream stream(client, stream_id, m_schema,
            method_info.input_type, method_info.output_type, metadata, messages);

        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";

        try {
            handler(stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            status_code = exceptionToStatusCode(ex.err);
            status_message = sprintf("%s: %s", ex.err, ex.desc);
        }

        # Check deadline after handler returns
        if (status_code == GRPC_STATUS_OK && deadline && now_us() > deadline) {
            status_code = GRPC_STATUS_DEADLINE_EXCEEDED;
            status_message = "deadline exceeded";
        }

        # Ensure response headers are sent even if handler wrote nothing
        stream.ensureHeadersSent();

        # Send trailers to complete the stream, including custom trailing metadata
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(status_code);
        trailers."grpc-message" = status_message;
        client.sendHttp2Trailers(stream_id, trailers);

        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }

    #! Maps a Qore exception error string to a gRPC status code
    /** Known prefixes: \c "GRPC-NOT-FOUND", \c "GRPC-INVALID-ARGUMENT",
        \c "GRPC-UNIMPLEMENTED", \c "GRPC-PERMISSION-DENIED",
        \c "GRPC-UNAUTHENTICATED", \c "GRPC-ALREADY-EXISTS",
        \c "GRPC-RESOURCE-EXHAUSTED", \c "GRPC-FAILED-PRECONDITION",
        \c "GRPC-ABORTED", \c "GRPC-OUT-OF-RANGE", \c "GRPC-UNAVAILABLE",
        \c "GRPC-DATA-LOSS", \c "GRPC-CANCELLED",
        \c "GRPC-DEADLINE-EXCEEDED".

        All other exceptions map to @ref GRPC_STATUS_INTERNAL.
    */
    private static int exceptionToStatusCode(string err) {
        switch (err) {
            case /^GRPC-NOT-FOUND/:          return GRPC_STATUS_NOT_FOUND;
            case /^GRPC-INVALID-ARGUMENT/:   return GRPC_STATUS_INVALID_ARGUMENT;
            case /^GRPC-UNIMPLEMENTED/:      return GRPC_STATUS_UNIMPLEMENTED;
            case /^GRPC-PERMISSION-DENIED/:  return GRPC_STATUS_PERMISSION_DENIED;
            case /^GRPC-UNAUTHENTICATED/:    return GRPC_STATUS_UNAUTHENTICATED;
            case /^GRPC-ALREADY-EXISTS/:     return GRPC_STATUS_ALREADY_EXISTS;
            case /^GRPC-RESOURCE-EXHAUSTED/: return GRPC_STATUS_RESOURCE_EXHAUSTED;
            case /^GRPC-FAILED-PRECONDITION/:return GRPC_STATUS_FAILED_PRECONDITION;
            case /^GRPC-ABORTED/:            return GRPC_STATUS_ABORTED;
            case /^GRPC-OUT-OF-RANGE/:       return GRPC_STATUS_OUT_OF_RANGE;
            case /^GRPC-UNAVAILABLE/:        return GRPC_STATUS_UNAVAILABLE;
            case /^GRPC-DATA-LOSS/:          return GRPC_STATUS_DATA_LOSS;
            case /^GRPC-CANCELLED/:          return GRPC_STATUS_CANCELLED;
            case /^GRPC-DEADLINE-EXCEEDED/:  return GRPC_STATUS_DEADLINE_EXCEEDED;
            default:                         return GRPC_STATUS_INTERNAL;
        }
    }

    #! Send a gRPC error response (trailers-only)
    private sendErrorResponse(Socket client, int stream_id, int status_code,
            string message) {
        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2Trailers(stream_id, {
            "grpc-status": string(status_code),
            "grpc-message": message,
        });

        AbstractPollOperation flush_op = client.startPollHttp2Flush();
        drivePoll(flush_op);
    }
}

} # namespace Grpc
