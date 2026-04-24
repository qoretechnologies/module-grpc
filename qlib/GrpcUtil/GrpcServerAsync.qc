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

        #! Reflection service instance (kept alive for handler closures)
        /** Set when @c opts.enable_reflection is True at construction — the
            reflection service builds a combined schema (user schema + the
            ServerReflection protobuf definitions) and registers a handler
            for \c ServerReflection/ServerReflectionInfo on this server.
        */
        *GrpcReflectionService m_reflection;

        #! Counter used by @ref wait() for deterministic shutdown wakeup
        /** Incremented to 1 in start(), decremented to 0 in shutdown() */
        Counter m_lifecycle(0);
    }

    #! Create an async gRPC server
    /** @param schema the protobuf schema containing service definitions
        @param opts optional server options (same shape as @ref GrpcServer)
    */
    constructor(ProtobufSchema schema, *hash<GrpcServerOptions> opts) {
        m_opts = opts;

        if (opts.enable_reflection) {
            GrpcReflectionService reflection(schema);
            m_schema = reflection.getCombinedSchema();
            m_reflection = reflection;
        } else {
            m_schema = schema;
        }

        list<auto> services = m_schema.services();
        for (int i = 0; i < services.size(); ++i) {
            m_services{services[i].name} = services[i];
            for (int j = 0; j < services[i].methods.size(); ++j) {
                hash<ProtobufMethodInfo> method = services[i].methods[j];
                m_method_info{services[i].name + "/" + method.name} = method;
            }
        }

        if (m_reflection) {
            m_reflection.registerHandlers(self);
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
    /** The cert/key are passed to @ref HttpServerAsyncIo::HttpAsyncSocketIoController::addListener
        at start() time rather than installed on the Socket here — the async
        controller performs the TLS handshake per accepted connection via its
        HttpAcceptPollOperation, which needs the cert/key at accept time.
    */
    int addSecurePort(string addr, hash<GrpcSslOptions> ssl) {
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
            bool ssl = exists ssl_cfg;
            # gRPC is HTTP/2 only — pin the version so the listener does not
            # fall back to HTTP/1.x.  Plaintext (h2c) for insecure ports,
            # TLS + ALPN-negotiated h2 for secure ports.
            string http_version = ssl
                ? HttpServerAsyncIo::HttpVersionMode::Http20
                : HttpServerAsyncIo::HttpVersionMode::H2c;
            # HttpAsyncSocketIoController::addListener expects SSLCertificate /
            # SSLPrivateKey objects (the HttpServer.qm caller contract), not
            # raw PEM strings.  Build them here from the PEM the user gave us
            # in the GrpcSslOptions.
            *SSLCertificate cert;
            *SSLPrivateKey key;
            if (ssl) {
                if (ssl_cfg.ssl.server_cert) {
                    cert = new SSLCertificate(ssl_cfg.ssl.server_cert);
                }
                if (ssl_cfg.ssl.server_key) {
                    key = new SSLPrivateKey(ssl_cfg.ssl.server_key);
                }
            }
            m_ctl.addListener(listener, self, ssl, cert, key, http_version);
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

        # Extract io_wake early — every outgoing write below requires it to
        # ensure prompt I/O-thread flushes of the pending frames.
        *code<nothing()> io_wake = info.header_info.io_wake;

        # Route: /<full_service>/<method>
        string path = info.hdr."path" ?? info.hdr.":path" ?? "";
        *hash<auto> route = resolveRoute(path);
        if (!route) {
            sendGrpcError(sock, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("invalid gRPC path: %y", path), io_wake);
            return grpcResponseInfo();
        }
        string handler_key = route.handler_key;
        hash<ProtobufMethodInfo> method_info = route.method_info;
        *code handler = m_handlers{handler_key};
        if (!handler) {
            sendGrpcError(sock, stream_id, GRPC_STATUS_UNIMPLEMENTED,
                sprintf("method not found: %s", handler_key), io_wake);
            return grpcResponseInfo();
        }

        *code<nothing(Queue)> register_body_queue = info.header_info.register_body_queue;

        if (method_info.server_streaming && method_info.client_streaming) {
            # Bidi: live+async mode — handler runs immediately, reads from an
            # inbound Queue fed by the I/O thread, writes via *Async methods.
            # No pre-drain of the request body — that would block the
            # interactive read-write-read-write pattern.
            handleBidiStreamLive(sock, stream_id, handler, method_info,
                metadata, deadline, io_wake, register_body_queue,
                info.header_info.body);
        } else if (method_info.server_streaming) {
            binary body_data = extractBody(info);
            handleServerStream(sock, stream_id, handler, method_info, metadata,
                body_data, deadline, io_wake);
        } else if (method_info.client_streaming) {
            # Client-streaming also benefits from live mode — handler can
            # process messages as they arrive rather than waiting for
            # END_STREAM — but the contract is a single response after the
            # handler returns, so writes don't need to interleave with reads.
            handleClientStreamLive(sock, stream_id, handler, method_info,
                metadata, deadline, io_wake, register_body_queue,
                info.header_info.body);
        } else {
            binary body_data = extractBody(info);
            handleUnary(sock, stream_id, handler, method_info, metadata,
                body_data, deadline, io_wake);
        }
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

    #! Collect the request body from HttpConnectionInfo
    /** Three cases:
        - HEADERS had END_STREAM (no body) → return empty
        - HttpServerAsyncIo pre-buffered the body (non-streaming dispatch) →
          return @c header_info.body as-is
        - Streaming dispatch (gRPC's typical shape: END_STREAM on DATA) →
          register a Qore Queue via @c header_info.register_body_queue,
          consume DATA payloads from it until the I/O thread pushes the
          @c NOTHING end-of-stream sentinel.  All I/O runs on the I/O thread;
          the handler only @c Queue::get(timeout)s.
    */
    private binary extractBody(hash<HttpConnectionInfo> info) {
        *auto body = info.header_info.body;
        if (exists body && body) {
            return body.typeCode() == NT_BINARY ? body : binary(body);
        }
        if (info.header_info.headers_end_stream) {
            return binary();
        }

        # Streaming body dispatch: drive it through the inbound Queue so no
        # handler-thread socket reads happen.  register_body_queue drains any
        # already-buffered DATA frames into the Queue and wakes the I/O
        # thread to pull more.
        *code<nothing(Queue)> register_body_queue = info.header_info.register_body_queue;
        if (!register_body_queue) {
            # Should not happen for body_streaming dispatches, but be defensive
            throw "GRPC-SERVER-ERROR",
                "body_streaming dispatch missing register_body_queue closure "
                "(HttpServerAsyncIo >= 1.0 required)";
        }
        Queue body_queue(-1);
        register_body_queue(body_queue);

        binary out = binary();
        while (True) {
            auto v = body_queue.get(30s);
            if (!(v instanceof binary)) {
                # NOTHING sentinel → END_STREAM observed by I/O thread
                break;
            }
            out += v;
        }
        return out;
    }

    #! Build a Queue for stream inbound data (server-streaming doesn't use it,
    #! but AsyncHttp2ServerStream's constructor requires one).  A max=-1 Queue
    #! is safe because nothing will ever be pushed to it — the server-streaming
    #! dispatch consumes the request body out-of-band.
    private Queue makeServerStreamingInboundPlaceholder() {
        return new Queue(-1);
    }

    #! Drive the server-streaming dispatch: decode single request →
    #! create GrpcServerStream(async-mode) → handler writes N messages →
    #! send final trailers (with grpc-status + handler's trailing metadata).
    private handleServerStream(Socket client, int stream_id, code handler,
            hash<ProtobufMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline, *code<nothing()> io_wake) {
        hash<auto> request_body();
        if (body_data.size() >= 5) {
            hash<auto> unframed = GrpcHelper::unframeMessage(body_data);
            request_body = m_schema.decode(method_info.input_type, unframed.data);
        }

        # Build the async stream handle and hand it to GrpcServerStream's
        # async-mode constructor so handlers using stream.write() route
        # through the *Async Socket methods.  io_wake (provided by
        # HttpServerAsyncIo in header_info) is required for the I/O thread
        # to flush pending DATA/HEADERS promptly — without it, frames sit in
        # the nghttp2 outbound buffer until the next scheduled controller tick.
        AsyncSocketIo::AsyncHttp2ServerStream async_stream(
            client, stream_id, makeServerStreamingInboundPlaceholder(), io_wake);
        GrpcServerStream stream(async_stream, m_schema,
            method_info.input_type, method_info.output_type, metadata);

        int status_code = GRPC_STATUS_OK;
        string status_message = "OK";

        try {
            handler(request_body, stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            status_code = exceptionToStatusCode(ex.err);
            status_message = sprintf("%s: %s", ex.err, ex.desc);
        }

        # Deadline check after handler returns
        if (status_code == GRPC_STATUS_OK && deadline && now_us() > deadline) {
            status_code = GRPC_STATUS_DEADLINE_EXCEEDED;
            status_message = "deadline exceeded";
        }

        # Ensure HEADERS went out even for an empty stream (trailers require
        # initial HEADERS on the wire per gRPC).  Then send trailers with the
        # status + any trailing metadata the handler accumulated.
        stream.ensureHeadersSent();
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(status_code);
        trailers."grpc-message" = status_message;
        client.sendHttp2Trailers(stream_id, trailers);
        if (io_wake) {
            io_wake();
        }
    }

    #! Build the inbound Queue for live-mode client-streaming / bidi
    /** If HttpServerAsyncIo provided a register_body_queue closure (standard
        body_streaming dispatch), register our Queue with it so the I/O thread
        streams DATA frames to us.  If the body was pre-buffered (headers had
        END_STREAM, or the I/O thread pre-accumulated), push the body and a
        NOTHING sentinel so the live reader sees the full input immediately.
    */
    private Queue buildInboundQueue(*code<nothing(Queue)> register_body_queue,
            *auto prebuffered_body) {
        Queue q(-1);
        if (register_body_queue) {
            register_body_queue(q);
            return q;
        }
        # Fallback: no register_body_queue (e.g. headers_end_stream=True path).
        # Push whatever body we have and a sentinel so read() returns NOTHING
        # after the final frame.
        if (exists prebuffered_body && prebuffered_body) {
            q.push(prebuffered_body.typeCode() == NT_BINARY
                ? prebuffered_body : binary(prebuffered_body));
        }
        q.push(NOTHING);
        return q;
    }

    #! Drive client-streaming in live mode: handler runs immediately, reads
    #! inbound messages from the Queue as they arrive, returns a single
    #! response → encode → send headers + DATA + trailers.
    /** Handler signature: \c hash<auto> sub(GrpcServerStream stream,
        hash<string, string> metadata)
    */
    private handleClientStreamLive(Socket client, int stream_id, code handler,
            hash<ProtobufMethodInfo> method_info, hash<string, string> metadata,
            *date deadline, *code<nothing()> io_wake,
            *code<nothing(Queue)> register_body_queue, *auto prebuffered_body) {
        Queue inbound = buildInboundQueue(register_body_queue, prebuffered_body);
        AsyncSocketIo::AsyncHttp2ServerStream async_stream(
            client, stream_id, inbound, io_wake);
        GrpcServerStream stream(async_stream, inbound, m_schema,
            method_info.input_type, method_info.output_type, metadata);

        hash<auto> response_body;
        try {
            response_body = handler(stream, metadata);
        } catch (hash<ExceptionInfo> ex) {
            sendGrpcError(client, stream_id, exceptionToStatusCode(ex.err),
                sprintf("%s: %s", ex.err, ex.desc), io_wake);
            return;
        }

        if (deadline && now_us() > deadline) {
            sendGrpcError(client, stream_id, GRPC_STATUS_DEADLINE_EXCEEDED,
                "deadline exceeded", io_wake);
            return;
        }

        binary encoded = m_schema.encode(method_info.output_type, response_body);
        binary framed = GrpcHelper::frameMessage(encoded);
        hash<string, string> trailers = stream.getTrailingMetadata();
        trailers."grpc-status" = string(GRPC_STATUS_OK);
        trailers."grpc-message" = "OK";

        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2StreamData(stream_id, framed, False);
        client.sendHttp2Trailers(stream_id, trailers);
        if (io_wake) {
            io_wake();
        }
    }

    #! Drive bidirectional-streaming in live mode — true gRPC bidi
    /** Handler runs immediately.  Its @c stream.read() pulls binary DATA
        chunks from the inbound Queue as they arrive (the I/O thread pushes
        one @ref binary per HTTP/2 DATA frame) and parses gRPC frames
        incrementally; its @c stream.write() enqueues responses via the
        @c *Async Socket methods and wakes the I/O thread to flush.  Reads
        and writes interleave freely — the classic echo / streaming
        request-response pattern works.

        Handler signature: \c sub(GrpcServerStream stream,
        hash<string, string> metadata)
    */
    private handleBidiStreamLive(Socket client, int stream_id, code handler,
            hash<ProtobufMethodInfo> method_info, hash<string, string> metadata,
            *date deadline, *code<nothing()> io_wake,
            *code<nothing(Queue)> register_body_queue, *auto prebuffered_body) {
        Queue inbound = buildInboundQueue(register_body_queue, prebuffered_body);
        AsyncSocketIo::AsyncHttp2ServerStream async_stream(
            client, stream_id, inbound, io_wake);
        GrpcServerStream stream(async_stream, inbound, m_schema,
            method_info.input_type, method_info.output_type, metadata);

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
        if (io_wake) {
            io_wake();
        }
    }

    #! Drive the unary dispatch: decode → handler → encode → send via AsyncHttp2ServerStream
    private handleUnary(Socket client, int stream_id, code handler,
            hash<ProtobufMethodInfo> method_info, hash<string, string> metadata,
            binary body_data, *date deadline, *code<nothing()> io_wake) {
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
                sprintf("%s: %s", ex.err, ex.desc), io_wake);
            return;
        }

        if (deadline && now_us() > deadline) {
            sendGrpcError(client, stream_id, GRPC_STATUS_DEADLINE_EXCEEDED,
                "deadline exceeded", io_wake);
            return;
        }

        binary encoded = m_schema.encode(method_info.output_type, response_body);
        binary framed = GrpcHelper::frameMessage(encoded);

        # Writes go through the new async C++ methods — no priv->m acquisition
        # on this handler thread.  io_wake signals the I/O thread to flush
        # the pending DATA and trailer frames; without the final wake the
        # response can sit in nghttp2's outbound buffer until the next tick.
        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2StreamData(stream_id, framed, False);
        client.sendHttp2Trailers(stream_id, {
            "grpc-status": string(GRPC_STATUS_OK),
            "grpc-message": "OK",
        });
        if (io_wake) {
            io_wake();
        }
    }

    #! Trailers-only error response for gRPC failures
    private sendGrpcError(Socket client, int stream_id, int status_code,
            string message, *code<nothing()> io_wake) {
        client.submitHttp2StreamingResponseHeaders(stream_id, 200,
            {"content-type": "application/grpc+proto"});
        client.sendHttp2Trailers(stream_id, {
            "grpc-status": string(status_code),
            "grpc-message": message,
        });
        if (io_wake) {
            io_wake();
        }
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
