# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcServerAsync.qc Async-only gRPC server built on HttpServerAsyncIo

/*  GrpcServerAsync.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Async-only gRPC server built on HttpServerAsyncIo
/** Preserves @ref GrpcServer's public API (constructor, @ref registerHandler,
    @ref addInsecurePort, @ref addSecurePort, @ref start, @ref wait,
    @ref shutdown, @ref isRunning) but calls no sync HTTP/2 socket methods and
    acquires no socket-wrapper lock on the handler thread.

    Listener management and per-request dispatch run on @ref HttpServerAsyncIo's
    async I/O controller; response writes go through @ref AsyncSocketIo::AsyncHttp2ServerStream
    which routes headers / DATA / trailers through the @c *Async Socket methods
    introduced with @ref AsyncHttp2ServerStream "AsyncHttp2ServerStream".

    Scope of this first-landing: unary dispatch only.  Server-streaming,
    client-streaming, and bidi paths will follow once the unary canary is
    green against the @c module-grpc test suite; see
    @c qore/design/grpc-server-async-migration.md.

    @since GrpcUtil 1.0
*/
public class GrpcServerAsync inherits HttpServerAsyncIo::HttpAsyncTarget {
    private {
        #! Protobuf schema
        ProtobufSchema m_schema;

        #! Server options
        *hash<GrpcServerOptions> m_opts;

        #! Registered handlers: key = "service/method", value = code callback
        hash<string, code> m_handlers;

        #! Method info cache: key = "service/method"
        hash<string, hash<ProtobufMethodInfo>> m_method_info;

        #! Service info from schema
        hash<string, hash<ProtobufServiceInfo>> m_services;

        #! Listener sockets, each wrapped in an HttpListener on start()
        list<Socket> m_listeners;

        #! SSL config keyed by listener port
        list<hash<auto>> m_ssl_configs;

        #! Running state flag
        bool m_running = False;

        #! State lock
        Mutex m_mutex();

        #! Async I/O controller driving all listeners
        *HttpServerAsyncIo::HttpAsyncSocketIoController m_ctl;

        #! Counter used by @ref wait() for deterministic shutdown wakeup
        /** Incremented to 1 in start(), decremented to 0 in shutdown() */
        Counter m_lifecycle(0);
    }

    #! Create an async gRPC server
    /** @param schema the protobuf schema containing service definitions
        @param opts optional server options (same shape as @ref GrpcServer)

        @since %GrpcUtil 1.0
    */
    constructor(ProtobufSchema schema, *hash<GrpcServerOptions> opts) {
        m_opts = opts;

        if (opts.enable_reflection) {
            # GrpcReflectionService::registerHandlers(GrpcServer) is typed to
            # the sync GrpcServer class.  Reflection integration for
            # GrpcServerAsync requires either a shared base class or a
            # refactored registerHandlers that accepts both — out of scope
            # for the initial scaffold.
            throw "GRPC-SERVER-ERROR", "enable_reflection is not yet supported "
                "in GrpcServerAsync; use GrpcServer for reflection services";
        }
        m_schema = schema;

        list<auto> services = m_schema.services();
        for (int i = 0; i < services.size(); ++i) {
            m_services{services[i].name} = services[i];
            for (int j = 0; j < services[i].methods.size(); ++j) {
                hash<ProtobufMethodInfo> method = services[i].methods[j];
                m_method_info{services[i].name + "/" + method.name} = method;
            }
        }
    }

    #! Returns the protobuf schema used by this server
    ProtobufSchema getSchema() {
        return m_schema;
    }

    #! Register a handler for a service method (same contract as @ref GrpcServer)
    registerHandler(string service, string method, code handler) {
        string key = service + "/" + method;
        if (!m_method_info{key}) {
            throw "GRPC-HANDLER-ERROR",
                sprintf("method '%s/%s' not found in schema", service, method);
        }
        m_handlers{key} = handler;
    }

    #! Add an insecure (plaintext h2c) listener
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
    start() {
        AutoLock al(m_mutex);
        if (m_running) {
            throw "GRPC-SERVER-ERROR", "server is already running";
        }
        AsyncSocketIo::AsyncSocketIoController ctrl
            = AsyncSocketIo::getGlobalAsyncIoController();
        m_ctl = new HttpServerAsyncIo::HttpAsyncSocketIoController(ctrl);
        m_ctl.start();

        for (int i = 0; i < m_listeners.size(); ++i) {
            Socket listener = m_listeners[i];
            int port = listener.getPort();
            *hash<auto> ssl_cfg = getSslConfig(port);
            m_ctl.addListener(listener, self, exists ssl_cfg,
                ssl_cfg.ssl.server_cert, ssl_cfg.ssl.server_key);
        }

        m_lifecycle.inc();
        m_running = True;
    }

    #! Block until the server shuts down
    /** Waits on the lifecycle Counter — no polling.  shutdown() drops the
        counter to zero and any waiters wake deterministically.
    */
    wait() {
        m_lifecycle.waitForZero();
    }

    #! Shut down the server
    shutdown(*int timeout_ms) {
        {
            AutoLock al(m_mutex);
            if (!m_running) {
                return;
            }
            m_running = False;
        }
        if (exists m_ctl) {
            m_ctl.stop();
        }
        for (int i = 0; i < m_listeners.size(); ++i) {
            try { m_listeners[i].close(); } catch () {}
        }
        m_lifecycle.dec();
    }

    #! Check if the server is running
    bool isRunning() {
        return m_running;
    }

    # =========================================================================
    # HttpAsyncTarget callbacks
    # =========================================================================

    #! Called by the async I/O controller when an HTTP/2 request is ready
    hash<HttpRequestResultInfo> onHttpRequest(hash<HttpConnectionInfo> info) {
        # Must be HTTP/2 — gRPC requires it.  If a client somehow sent HTTP/1
        # to a gRPC listener, refuse with a plain 505 so the I/O thread doesn't
        # get stuck waiting for h2op plumbing.
        if (!info.header_info.http2) {
            return <HttpRequestResultInfo>{
                "code": 505,
                "status_message": "HTTP Version Not Supported",
                "hdr": {"content-type": "text/plain"},
                "body": "gRPC requires HTTP/2",
                "close": True,
            };
        }

        int stream_id = info.header_info.stream_id;
        Socket sock = info.sock;

        # Extract gRPC metadata + deadline from the H2 HEADERS
        hash<string, string> metadata = extractMetadata(info.hdr);
        *date deadline = parseDeadline(\metadata);

        # Route: /<full_service>/<method>
        string path = info.hdr."path" ?? info.hdr.":path" ?? "";
        *hash<auto> route = resolveRoute(path);
        if (!route) {
            sendGrpcError(sock, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("invalid gRPC path: %y", path));
            return grpcResponseInfo();
        }
        string handler_key = route.handler_key;
        hash<ProtobufMethodInfo> method_info = route.method_info;
        *code handler = m_handlers{handler_key};
        if (!handler) {
            sendGrpcError(sock, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("method not found: %s", handler_key));
            return grpcResponseInfo();
        }

        # Unary body is already collected by the I/O thread and attached to hdr
        # (or absent if the client didn't send one).  Streaming dispatches are
        # not yet implemented in this scaffold; reject them explicitly so they
        # don't silently mis-dispatch as unary.
        if (method_info.server_streaming || method_info.client_streaming) {
            sendGrpcError(sock, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                "streaming RPC paths not yet implemented in GrpcServerAsync; "
                "use GrpcServer or wait for the next landing");
            return grpcResponseInfo();
        }

        binary body_data = extractBody(info);
        handleUnary(sock, stream_id, handler, method_info, metadata,
            body_data, deadline);
        return grpcResponseInfo();
    }

    #! Idle timeout — just close the socket, no pool reuse for gRPC connections
    onIdleTimeout(Socket sock, *HttpServer::HttpListenerInterface listener, hash<auto> cx) {
        try { sock.close(); } catch () {}
    }

    #! I/O error — log and close
    onError(Socket sock, hash<ExceptionInfo> ex,
            *HttpServer::HttpListenerInterface listener, *hash<auto> cx) {
        try { sock.close(); } catch () {}
    }

    #! SSE disconnect — not applicable to gRPC
    onSseDisconnect(Socket sock, *HttpServer::HttpListenerInterface listener, hash<auto> cx) {
    }

    #! WebSocket frame — not applicable to gRPC
    onWebSocketFrame(Socket sock, hash<WebSocketFrameInfo> frame,
            *HttpServer::HttpListenerInterface listener, hash<auto> cx) {
    }

    #! WebSocket close — not applicable to gRPC
    onWebSocketClose(Socket sock, int code, string reason,
            *HttpServer::HttpListenerInterface listener, hash<auto> cx) {
    }

    # =========================================================================
    # Internal helpers
    # =========================================================================

    #! Default HttpRequestResultInfo for a gRPC response already sent via
    #! AsyncHttp2ServerStream (or via sendGrpcError).  The controller must not
    #! try to synthesize any further response on our behalf.
    private hash<HttpRequestResultInfo> grpcResponseInfo() {
        return <HttpRequestResultInfo>{
            "dedicated": True,
            "close": False,
            "return_to_idle": True,
        };
    }

    #! Look up the SSL config for a listener port (or NOTHING if insecure)
    private *hash<auto> getSslConfig(int port) {
        for (int i = 0; i < m_ssl_configs.size(); ++i) {
            if (m_ssl_configs[i].port == port) {
                return m_ssl_configs[i];
            }
        }
        return NOTHING;
    }

    #! Extract gRPC application metadata from H2 request headers
    private hash<string, string> extractMetadata(hash<auto> hdr) {
        hash<string, string> m();
        map m{$1.key} = $1.value.toString(),
            hdr.pairIterator(),
            $1.key !~ /^:/ && $1.key != "content-type" && $1.key != "te";
        return m;
    }

    #! Parse grpc-timeout (in @a metadata); strip it and return an absolute deadline
    private *date parseDeadline(reference<hash<string, string>> metadata) {
        if (!metadata."grpc-timeout") {
            return NOTHING;
        }
        *int timeout_ms = GrpcHelper::parseTimeout(metadata."grpc-timeout");
        remove metadata."grpc-timeout";
        return timeout_ms ? now_us() + milliseconds(timeout_ms) : NOTHING;
    }

    #! Split /<full_service>/<method> and resolve to a handler+method_info pair
    private *hash<auto> resolveRoute(string path) {
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
        string handler_key = service_name + "/" + method_name;
        *hash<ProtobufMethodInfo> mi = m_method_info{handler_key};
        if (!mi) {
            return NOTHING;
        }
        return {"handler_key": handler_key, "method_info": mi};
    }

    #! Collect the request body from HttpConnectionInfo — unary path only
    private binary extractBody(hash<HttpConnectionInfo> info) {
        # The HttpServerAsyncIo controller collects the H2 DATA for non-
        # body-streaming dispatches into header_info.body
        # (HttpAsyncSocketIoController.qc line 3009 in the pre-change file).
        # body_streaming case is not yet handled — onHttpRequest rejects
        # streaming RPCs in this scaffold.
        *auto body = info.header_info.body;
        if (!exists body) {
            return binary();
        }
        return body.typeCode() == NT_BINARY ? body : binary(body);
    }

    #! Drive the unary dispatch: decode → handler → encode → send via AsyncHttp2ServerStream
    private handleUnary(Socket client, int stream_id, code handler,
            hash<ProtobufMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline) {
        hash<auto> request_body();
        if (body_data.size() >= 5) {
            hash<auto> unframed = GrpcHelper::unframeMessage(body_data);
            request_body = m_schema.decode(method_info.input_type, unframed.data);
        }

        hash<auto> response_body;
        try {
            response_body = handler(request_body, metadata);
        } catch (hash<ExceptionInfo> ex) {
            sendGrpcError(client, stream_id, exceptionToStatusCode(ex.err),
                sprintf("%s: %s", ex.err, ex.desc));
            return;
        }

        if (deadline && now_us() > deadline) {
            sendGrpcError(client, stream_id, GRPC_STATUS_DEADLINE_EXCEEDED,
                "deadline exceeded");
            return;
        }

        binary encoded = m_schema.encode(method_info.output_type, response_body);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Writes go through the new async C++ methods — no priv->m acquisition
        # on this handler thread.  The I/O thread flushes the pending DATA and
        # trailer frames asynchronously.
        client.submitHttp2StreamingResponseHeadersAsync(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2StreamDataAsync(stream_id, framed, False);
        client.sendHttp2TrailersAsync(stream_id, {
            "grpc-status": string(GRPC_STATUS_OK),
            "grpc-message": "OK",
        });
    }

    #! Trailers-only error response for gRPC failures
    private sendGrpcError(Socket client, int stream_id, int status_code, string message) {
        client.submitHttp2StreamingResponseHeadersAsync(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2TrailersAsync(stream_id, {
            "grpc-status": string(status_code),
            "grpc-message": message,
        });
    }

    #! Map a Qore exception err-string to a gRPC status code
    private int exceptionToStatusCode(string err) {
        switch (err) {
            case "GRPC-TIMEOUT":
            case "FUTURE-TIMEOUT":
                return GRPC_STATUS_DEADLINE_EXCEEDED;
            case "GRPC-CANCELLED":
                return GRPC_STATUS_CANCELLED;
            case "GRPC-NOT-FOUND":
                return GRPC_STATUS_NOT_FOUND;
            case "GRPC-INVALID-ARGUMENT":
                return GRPC_STATUS_INVALID_ARGUMENT;
            case "GRPC-UNAUTHENTICATED":
                return GRPC_STATUS_UNAUTHENTICATED;
            case "GRPC-PERMISSION-DENIED":
                return GRPC_STATUS_PERMISSION_DENIED;
            case "GRPC-UNIMPLEMENTED":
                return GRPC_STATUS_UNIMPLEMENTED;
            default:
                return GRPC_STATUS_INTERNAL;
        }
    }
}

} # namespace Grpc
