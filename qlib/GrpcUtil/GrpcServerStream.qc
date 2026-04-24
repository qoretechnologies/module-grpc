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
        #! Async-mode write handle (the only outbound transport)
        /** Set by both public constructors.  All writes — @ref write(),
            @ref ensureHeadersSent(), @ref sendInitialMetadata() — route
            through this handle's @c *Async Socket methods so handler threads
            never hold @c my_socket_priv::m for HTTP/2 operations.

            Optional only so that the private no-arg constructor can be used
            by proxy/remote subclasses that override @ref read() / @ref write()
            and never touch the HTTP/2 transport directly.

            @since %GrpcUtil 1.0
        */
        *AsyncSocketIo::AsyncHttp2ServerStream m_async_stream;
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
        #! Read buffer for accumulating partial gRPC frames (live+async mode)
        binary m_read_buf = binary();

        #! Inbound @ref Queue "Queue" for live+async mode (client-streaming / bidi)
        /** When set, @ref read() pulls binary DATA chunks from this Queue
            (populated by the HttpServerAsyncIo I/O thread via
            @c header_info.register_body_queue) and parses gRPC frames from the
            accumulated buffer.  A @c NOTHING sentinel on the Queue signals
            END_STREAM.

            @since %GrpcUtil 1.0
        */
        *Queue m_async_inbound_queue;

        #! True after END_STREAM has been observed on @ref m_async_inbound_queue
        bool m_async_reads_done = False;
    }

    #! Create a server stream backed by an async HTTP/2 stream handle
    /** Used by @ref GrpcServerAsync for server-streaming and unary dispatch
        (pre-parsed request body, async-only response writes via the @c *Async
        Socket methods).  The @a messages argument is typically a single-element
        list for server-streaming (one request, many responses) or the full
        decoded client-stream buffer for client-streaming / bidi when the body
        is drained before the handler runs.

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
        m_schema = schema;
        m_input_type = input_type;
        m_output_type = output_type;
        m_metadata = metadata;
        m_messages = messages;
    }

    #! Create a live+async server stream for interactive bidi / client-streaming
    /** Unlike the buffered-mode constructor above (which is handed a pre-parsed
        list of client messages and is suitable for request patterns where the
        full body has been drained before the handler runs), this constructor
        wires @ref read() to pull binary DATA chunks from @a inbound_queue in
        real time and parse gRPC frames incrementally — the handler can
        interleave reads and writes and observe each client message as it
        arrives on the wire.

        @a inbound_queue must be the Queue registered via
        @c HttpConnectionInfo.header_info.register_body_queue; the I/O thread
        pushes one @ref binary per DATA frame and a @c NOTHING sentinel at
        END_STREAM.

        @param async_stream the write-side handle
        @param inbound_queue the Queue populated by the I/O thread with inbound
        DATA payloads
        @param schema the protobuf schema
        @param input_type the message type for decoding incoming messages
        @param output_type the message type for encoding outgoing messages
        @param metadata the client's request metadata

        @since %GrpcUtil 1.0
    */
    constructor(AsyncSocketIo::AsyncHttp2ServerStream async_stream,
            Queue inbound_queue, ProtobufSchema schema,
            string input_type, string output_type,
            hash<string, string> metadata) {
        m_async_stream = async_stream;
        m_async_inbound_queue = inbound_queue;
        m_schema = schema;
        m_input_type = input_type;
        m_output_type = output_type;
        m_metadata = metadata;
    }

    #! Constructor for proxy/remote stream implementations
    /** Subclasses override @ref read() and @ref write() to relay stream data
        over a transport layer (e.g., ZeroMQ) instead of using the HTTP/2
        async stream directly.
    */
    private constructor() {
    }

    #! Read the next client message
    /** For client-streaming and bidirectional-streaming handlers.

        When the stream was constructed with a pre-parsed @c messages list,
        returns the messages one at a time.  When constructed with an
        @c inbound_queue, blocks until a complete gRPC frame arrives from the
        HTTP/2 stream, the stream completes (END_STREAM), or the timeout
        expires.

        @param timeout read timeout (default 30s); only used in live+async mode

        @return the next decoded message hash, or NOTHING when all messages
        have been read (buffered mode) or on timeout/end-of-stream (live+async
        mode)

        @since %GrpcUtil 1.0
    */
    *hash<auto> read(*timeout timeout) {
        if (!exists m_async_inbound_queue) {
            # Buffered mode: pre-parsed messages
            if (m_read_pos >= m_messages.size()) {
                return NOTHING;
            }
            return m_messages[m_read_pos++];
        }

        if (!timeout) {
            timeout = 30s;
        }
        date deadline = now_us() + milliseconds(timeout);

        # Live+async: pull binary DATA chunks from the Queue that the
        # HttpServerAsyncIo I/O thread populates, parse gRPC frames
        # incrementally.  A NOTHING sentinel on the Queue signals END_STREAM.
        while (True) {
            *hash<auto> msg = tryParseFrame();
            if (msg) {
                return msg;
            }
            if (m_async_reads_done) {
                # drained + sentinel already seen — nothing more coming
                return NOTHING;
            }
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return NOTHING;  # timeout waiting for next chunk
            }
            try {
                auto v = m_async_inbound_queue.get(milliseconds(remaining_ms));
                if (v instanceof binary) {
                    m_read_buf += v;
                } else {
                    # NOTHING sentinel → END_STREAM observed by I/O thread.
                    # Try one final parse for a complete frame that arrived
                    # in the same batch as END_STREAM.  If the buffer has
                    # partial data, it's unrecoverable (sender closed
                    # mid-frame); discard to prevent infinite loop.
                    m_async_reads_done = True;
                    *hash<auto> final_msg = tryParseFrame();
                    if (!final_msg && m_read_buf.size() > 0) {
                        m_read_buf = binary();
                    }
                    return final_msg;
                }
            } catch (hash<ExceptionInfo> ex) {
                if (ex.err == "QUEUE-TIMEOUT") {
                    return NOTHING;
                }
                rethrow;
            }
        }
    }

    #! Check if all client messages have been read
    /** @return True if all messages have been consumed

        In buffered mode, returns True when all pre-parsed messages have been
        returned by read().  In live+async mode, returns True when END_STREAM
        has been received and there is no more buffered data to parse.

        @since %GrpcUtil 1.0
    */
    bool readsDone() {
        if (!exists m_async_inbound_queue) {
            return m_read_pos >= m_messages.size();
        }
        # Live+async: done when I/O thread pushed the NOTHING sentinel
        # and the buffer has no complete frame left.
        if (!m_async_reads_done) {
            return False;
        }
        if (m_read_buf.size() < 5) {
            return True;
        }
        int len = (m_read_buf[1] << 24) | (m_read_buf[2] << 16)
            | (m_read_buf[3] << 8) | m_read_buf[4];
        return m_read_buf.size() < 5 + len;
    }

    #! Write a response message
    /** For server-streaming and bidirectional-streaming handlers.
        Encodes and sends a gRPC-framed protobuf message via the
        @ref AsyncSocketIo::AsyncHttp2ServerStream "AsyncHttp2ServerStream"
        handle.  The I/O thread flushes the DATA frame asynchronously — no
        handler-thread H2 session lock acquisition.

        @param message the message data as a Qore hash

        @since %GrpcUtil 1.0
    */
    write(hash<auto> message) {
        ensureHeadersSent();
        binary encoded = m_schema.encode(m_output_type, message);
        binary framed = GrpcHelper::frameMessage(encoded);
        m_async_stream.sendData(framed, False);
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
            m_async_stream.sendHeaders(200, headers);
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
            m_async_stream.sendHeaders(200,
                {"content-type": "application/grpc+proto"});
            m_headers_sent = True;
        }
    }
}

} # namespace Grpc
