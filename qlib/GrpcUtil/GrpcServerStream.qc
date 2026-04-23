# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcServerStream.qc gRPC server-side stream handle

/*  GrpcServerStream.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Server-side gRPC stream handle for streaming RPC patterns
/** Provides gRPC-framed message reading and writing on the server side.
    Used for server-streaming, client-streaming, and bidirectional-streaming
    handler implementations.

    For client-streaming, the request body is pre-parsed into a list of
    decoded messages that are returned one at a time via read().

    For server-streaming, write() encodes and sends gRPC-framed messages.

    @par Example (server-streaming handler):
    @code{.py}
server.registerHandler("MyService", "ServerStream",
    sub(hash<auto> request, GrpcServerStream stream, hash<string, string> metadata) {
        for (int i = 0; i < 5; ++i) {
            stream.write({"message": sprintf("msg %d", i), "status": i});
        }
    });
    @endcode

    @par Example (client-streaming handler):
    @code{.py}
server.registerHandler("MyService", "ClientStream",
    hash<auto> sub(GrpcServerStream stream, hash<string, string> metadata) {
        list<string> names;
        while (*hash<auto> msg = stream.read()) {
            names += msg.name;
        }
        return {"message": names.join(", "), "status": 0};
    });
    @endcode

    @since GrpcUtil 1.0
*/
public class GrpcServerStream {
    private {
        #! The underlying Socket
        Socket m_socket;
        #! The HTTP/2 stream ID
        int m_stream_id;
        #! Protobuf schema for encoding/decoding
        ProtobufSchema m_schema;
        #! Message type for encoding outgoing messages
        string m_output_type;
        #! Message type for decoding incoming messages
        string m_input_type;
        #! Client metadata from the request
        hash<string, string> m_metadata;
        #! Pre-parsed messages for client-streaming (buffered mode)
        list<hash<auto>> m_messages = ();
        #! Current read position in pre-parsed messages
        int m_read_pos = 0;
        #! Whether initial metadata (response headers) have been sent
        bool m_headers_sent = False;
        #! Custom trailing metadata set by the handler
        hash<string, string> m_trailing_metadata();
        #! Live mode: read from socket incrementally (vs pre-parsed buffer)
        bool m_live = False;
        #! Read buffer for accumulating partial gRPC frames (live mode)
        binary m_read_buf = binary();

        #! Async-mode write handle used by @ref GrpcServerAsync
        /** When set, @ref write() / @ref ensureHeadersSent() / @ref sendInitialMetadata()
            route through this handle's @c *Async Socket methods (no handler-thread
            @c priv->m holds) instead of the sync @c Socket::sendHttp2StreamData /
            @c submitHttp2StreamingResponseHeaders path.  Set only by the
            async-mode constructor; @c m_socket is also populated (for legacy
            @ref read() / @ref readsDone() callers in client-streaming scenarios)
            but is NOT used for writes in this mode.

            @since %GrpcUtil 1.0
        */
        *AsyncSocketIo::AsyncHttp2ServerStream m_async_stream;
    }

    #! Constructor for proxy/remote stream implementations
    /** Subclasses override @ref read() and @ref write() to relay stream data
        over a transport layer (e.g., ZeroMQ) instead of reading/writing from
        an HTTP/2 socket directly.
    */
    private constructor() {
        m_live = True;
    }

    #! Create a server stream (buffered mode)
    /** @param socket the client Socket
        @param stream_id the HTTP/2 stream ID
        @param schema the protobuf schema
        @param input_type the message type for incoming (client) messages
        @param output_type the message type for outgoing (server) messages
        @param metadata the client's request metadata
        @param messages pre-parsed list of client messages (for client-streaming/bidi)

        @since %GrpcUtil 1.0
    */
    constructor(Socket socket, int stream_id, ProtobufSchema schema,
            string input_type, string output_type,
            hash<string, string> metadata, list<hash<auto>> messages = ()) {
        m_socket = socket;
        m_stream_id = stream_id;
        m_schema = schema;
        m_input_type = input_type;
        m_output_type = output_type;
        m_metadata = metadata;
        m_messages = messages;
    }

    #! Create a server stream (live mode for incremental reading)
    /** @param socket the client Socket
        @param stream_id the HTTP/2 stream ID
        @param schema the protobuf schema
        @param input_type the message type for incoming (client) messages
        @param output_type the message type for outgoing (server) messages
        @param metadata the client's request metadata
        @param live if True, read from the HTTP/2 stream incrementally

        @since %GrpcUtil 1.0
    */
    constructor(Socket socket, int stream_id, ProtobufSchema schema,
            string input_type, string output_type,
            hash<string, string> metadata, bool live) {
        m_socket = socket;
        m_stream_id = stream_id;
        m_schema = schema;
        m_input_type = input_type;
        m_output_type = output_type;
        m_metadata = metadata;
        m_live = live;
    }

    #! Create a server stream backed by an async HTTP/2 stream handle
    /** Used by @ref GrpcServerAsync for server-streaming dispatch (pre-parsed
        request body, async-only response writes via the @c *Async Socket
        methods).  The @a messages argument is typically a single-element list
        for server-streaming (one request, many responses) or the full decoded
        client-stream buffer for client-streaming / bidi.

        Writes (@ref write(), @ref ensureHeadersSent(), @ref sendInitialMetadata())
        all route through @a async_stream; no handler-thread @c priv->m hold on
        HTTP/2 operations.

        @param async_stream the @ref AsyncSocketIo::AsyncHttp2ServerStream
        "AsyncHttp2ServerStream" handle driving response I/O
        @param schema the protobuf schema
        @param input_type the message type for incoming (client) messages
        @param output_type the message type for outgoing (server) messages
        @param metadata the client's request metadata
        @param messages pre-parsed list of client messages

        @since %GrpcUtil 1.0
    */
    constructor(AsyncSocketIo::AsyncHttp2ServerStream async_stream,
            ProtobufSchema schema, string input_type, string output_type,
            hash<string, string> metadata, list<hash<auto>> messages = ()) {
        m_async_stream = async_stream;
        # Populate socket/stream_id so read()/readsDone() have context if the
        # handler calls them in client-streaming (buffered) mode; writes go
        # through m_async_stream regardless.
        m_socket = async_stream.getSocket();
        m_stream_id = async_stream.getStreamId();
        m_schema = schema;
        m_input_type = input_type;
        m_output_type = output_type;
        m_metadata = metadata;
        m_messages = messages;
    }

    #! Read the next client message
    /** For client-streaming and bidirectional-streaming handlers.

        In buffered mode, returns pre-parsed messages one at a time.
        In live mode, blocks until a complete gRPC frame arrives from the HTTP/2
        stream, the stream completes (END_STREAM), or the timeout expires.

        @param timeout read timeout (default 30s); only used in live mode

        @return the next decoded message hash, or NOTHING when all messages have
        been read (buffered mode) or on timeout/end-of-stream (live mode)

        @since %GrpcUtil 1.0
    */
    *hash<auto> read(*timeout timeout) {
        if (!m_live) {
            # Buffered mode (unchanged)
            if (m_read_pos >= m_messages.size()) {
                return NOTHING;
            }
            return m_messages[m_read_pos++];
        }

        # Live mode: read from HTTP/2 stream incrementally
        if (!timeout) {
            timeout = 30s;
        }
        date deadline = now_us() + milliseconds(timeout);

        while (True) {
            # Try to parse a complete gRPC frame from buffer
            *hash<auto> msg = tryParseFrame();
            if (msg) {
                return msg;
            }

            # Check if stream is complete (END_STREAM received)
            if (m_socket.isHttp2StreamComplete(m_stream_id)) {
                # Drain any remaining data from the HTTP/2 stream buffer
                # (DATA may have arrived in the same batch as HEADERS + END_STREAM)
                try {
                    *binary remaining = m_socket.readHttp2StreamDataBlock(
                        m_stream_id, 0ms);
                    if (remaining) {
                        m_read_buf += remaining;
                    }
                } catch () {
                    # Ignore errors draining a completed stream
                }
                # Try to parse remaining buffered data; if the buffer contains an
                # incomplete frame after END_STREAM, discard it to prevent infinite
                # loops (the sender closed the stream mid-frame — data is unrecoverable)
                *hash<auto> result = tryParseFrame();
                if (!result && m_read_buf.size() > 0) {
                    m_read_buf = binary();
                }
                return result;
            }

            # Calculate remaining timeout
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return NOTHING;  # Timeout
            }

            # Blocking read from HTTP/2 stream
            try {
                *binary chunk = m_socket.readHttp2StreamDataBlock(m_stream_id,
                    milliseconds(remaining_ms));
                if (chunk) {
                    m_read_buf += chunk;
                }
            } catch (hash<ExceptionInfo> ex) {
                if (ex.err == "HTTP2-STREAM-TIMEOUT"
                        || ex.err == "HTTP2-STREAM-ERROR") {
                    return NOTHING;  # Timeout or stream not found
                }
                rethrow;
            }
        }
    }

    #! Check if all client messages have been read
    /** @return True if all messages have been consumed

        In buffered mode, returns True when all pre-parsed messages have been
        returned by read(). In live mode, returns True when END_STREAM has been
        received and there is no more buffered data to parse.

        @since %GrpcUtil 1.0
    */
    bool readsDone() {
        if (!m_live) {
            return m_read_pos >= m_messages.size();
        }
        if (!m_socket.isHttp2StreamComplete(m_stream_id)) {
            return False;
        }
        # Stream complete; check if there's a parseable frame remaining
        if (m_read_buf.size() < 5) {
            return True;
        }
        int len = (m_read_buf[1] << 24) | (m_read_buf[2] << 16)
            | (m_read_buf[3] << 8) | m_read_buf[4];
        # If buffer doesn't contain a complete frame, the data is
        # unrecoverable (sender closed mid-frame) — treat as done
        return m_read_buf.size() < 5 + len;
    }

    #! Write a response message
    /** For server-streaming and bidirectional-streaming handlers.
        Encodes and sends a gRPC-framed protobuf message.

        In live mode, the HTTP/2 session is flushed after each write to ensure
        immediate delivery to the client.

        @param message the message data as a Qore hash

        @since %GrpcUtil 1.0
    */
    write(hash<auto> message) {
        ensureHeadersSent();
        binary encoded = m_schema.encode(m_output_type, message);
        binary framed = GrpcHelper::frameMessage(encoded);
        if (exists m_async_stream) {
            # Async mode: enqueue via the AsyncHttp2ServerStream; the I/O
            # thread flushes the DATA frame asynchronously — no handler-thread
            # flushHttp2() call.
            m_async_stream.sendData(framed, False);
        } else {
            m_socket.sendHttp2StreamData(m_stream_id, framed, False);
            if (m_live) {
                m_socket.flushHttp2();
            }
        }
    }

    #! Try to parse a complete gRPC frame from the read buffer (live mode)
    private *hash<auto> tryParseFrame() {
        if (m_read_buf.size() < 5) {
            return NOTHING;
        }
        int len = (m_read_buf[1] << 24) | (m_read_buf[2] << 16)
            | (m_read_buf[3] << 8) | m_read_buf[4];
        if (m_read_buf.size() < 5 + len) {
            return NOTHING;
        }
        # Extract the message
        binary msg_data = m_read_buf.substr(5, len);
        # Remove consumed bytes from buffer
        if (m_read_buf.size() > 5 + len) {
            m_read_buf = m_read_buf.substr(5 + len);
        } else {
            m_read_buf = binary();
        }
        return m_schema.decode(m_input_type, msg_data);
    }

    #! Send initial response metadata (headers)
    /** @param metadata the metadata to send as initial response headers

        @note Must be called before the first write() call. If called after write(),
        the metadata is silently ignored since headers have already been sent.

        @since %GrpcUtil 1.0
    */
    sendInitialMetadata(hash<string, string> metadata) {
        if (!m_headers_sent) {
            hash<string, string> headers = {"content-type": "application/grpc+proto"};
            map headers{$1.key} = $1.value, metadata.pairIterator();
            if (exists m_async_stream) {
                m_async_stream.sendHeaders(200, headers);
            } else {
                m_socket.submitHttp2StreamingResponseHeaders(m_stream_id, 200, headers);
            }
            m_headers_sent = True;
        }
    }

    #! Set custom trailing metadata to send with the response
    /** These are merged with the standard grpc-status/grpc-message trailers
        when the response completes.

        @param metadata the trailing metadata key-value pairs

        @par Example:
        @code{.py}
stream.setTrailingMetadata({"x-server-timing": "dur=42"});
        @endcode

        @since %GrpcUtil 1.0
    */
    setTrailingMetadata(hash<string, string> metadata) {
        map m_trailing_metadata{$1.key} = $1.value, metadata.pairIterator();
    }

    #! Get the custom trailing metadata set by the handler
    /** @return the custom trailing metadata

        @since %GrpcUtil 1.0
    */
    hash<string, string> getTrailingMetadata() {
        return m_trailing_metadata;
    }

    #! Get the client's request metadata
    /** @return the metadata from the client's request headers

        @since %GrpcUtil 1.0
    */
    hash<string, string> clientMetadata() {
        return m_metadata;
    }

    #! Ensure response headers have been sent
    /** Called automatically by write(), but also called by the server
        before sending trailers in case the handler wrote nothing (e.g.,
        an empty server-stream).

        @since %GrpcUtil 1.0
    */
    ensureHeadersSent() {
        if (!m_headers_sent) {
            if (exists m_async_stream) {
                m_async_stream.sendHeaders(200,
                    {"content-type": "application/grpc+proto"});
            } else {
                m_socket.submitHttp2StreamingResponseHeaders(m_stream_id, 200,
                    {"content-type": "application/grpc+proto"});
            }
            m_headers_sent = True;
        }
    }
}

} # namespace Grpc
