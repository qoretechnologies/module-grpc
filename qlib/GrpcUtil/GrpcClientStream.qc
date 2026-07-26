# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcClientStream.qc gRPC client stream for streaming RPC calls

/*  GrpcClientStream.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! gRPC client stream for streaming RPC calls
/** Wraps @ref HttpClientIo::HttpClientStreamHandle for gRPC streaming
    (server-streaming, client-streaming, and bidirectional).

    @par Server-streaming example:
    @code{.py}
GrpcClientStream stream = client.serverStream("ServerStream", {"name": "World"});
*hash<auto> msg;
while (msg = stream.read()) {
    printf("Received: %y\n", msg);
}
hash<GrpcCallResult> result = stream.finish();
    @endcode

    @par Client-streaming example:
    @code{.py}
GrpcClientStream stream = client.clientStream("ClientStream");
stream.write({"name": "msg1"});
stream.write({"name": "msg2"});
stream.writesDone();
hash<GrpcCallResult> result = stream.finish();
    @endcode
*/
public class GrpcClientStream {
    private {
        #! The HTTP/2 stream handle
        HttpClientIo::HttpClientStreamHandle m_stream;

        #! The protobuf schema
        ProtobufSchema m_schema;

        #! Message type for reading (response type)
        string m_read_type;

        #! Message type for writing (request type)
        string m_write_type;

        #! Whether reads are done (END_STREAM received)
        bool m_reads_done = False;

        #! Whether writesDone() has been called
        bool m_writes_done = False;

        #! Read buffer for accumulating partial gRPC frames
        GrpcFrameBuffer m_read_buf();

        #! Last response body decoded (for client-streaming finish())
        hash<auto> m_last_body;
    }

    #! Create a client stream
    /** @param stream the HTTP/2 stream handle (already in streaming mode)
        @param schema the protobuf schema
        @param read_type message type for decoding received messages
        @param write_type message type for encoding sent messages
        @param writes_done if True, writes are already complete (server-streaming)
    */
    constructor(HttpClientIo::HttpClientStreamHandle stream,
            ProtobufSchema schema, string read_type, string write_type,
            bool writes_done = False) {
        m_stream = stream;
        m_schema = schema;
        m_read_type = read_type;
        m_write_type = write_type;
        m_writes_done = writes_done;
    }

    #! Read the next message from the stream
    /** @param timeout optional read timeout
        @return a decoded message hash, or NOTHING if the stream has ended

        @throw GRPC-STREAM-ERROR if a stream error occurs
    */
    *hash<auto> read(*timeout timeout) {
        if (m_reads_done) {
            return NOTHING;
        }
        if (!timeout) {
            timeout = 30s;
        }

        while (True) {
            # Try to parse a complete gRPC frame from buffer
            *hash<auto> msg = tryParseFrame();
            if (msg) {
                m_last_body = msg;
                return msg;
            }

            # Need more data
            auto data = m_stream.readData(timeout);
            if (!exists data) {
                # Timeout
                return NOTHING;
            }
            if (data.typeCode() == NT_HASH) {
                if (data.end_stream) {
                    m_reads_done = True;
                    # Try to parse remaining buffer
                    *hash<auto> remaining = tryParseFrame();
                    if (remaining) {
                        m_last_body = remaining;
                    }
                    return remaining;
                }
                if (data.error) {
                    throw "GRPC-STREAM-ERROR", sprintf("stream error: %y", data.error);
                }
                # Headers-only or other metadata hash (e.g. the status_code +
                # headers event the H2 MultiplexPoll emits for non-CONNECT
                # streaming streams before the first body fragment).  Per the
                # HttpClientIo::Http2ClientStreamHandle::readData() contract
                # ("callers handle unknown hashes by skipping them"), skip and
                # keep reading for the actual gRPC DATA frames.
                continue;
            }

            # Append data to buffer
            m_read_buf.add(data);
        }
    }

    #! Write a message to the stream
    /** @param message the message to send

        @throw GRPC-STREAM-ERROR if the stream is not writable
    */
    write(hash<auto> message) {
        binary encoded = m_schema.encode(m_write_type, message);
        binary framed = GrpcHelper::frameMessage(encoded);
        m_stream.sendData(framed, False);
    }

    #! Signal that no more messages will be written
    /** Sends END_STREAM on the client side. Required before the server
        can send its response for client-streaming calls.

        Safe to call multiple times; subsequent calls are no-ops.
    */
    writesDone() {
        if (!m_writes_done) {
            m_writes_done = True;
            # sendData(empty, end_stream=True) is idempotent — if the stream
            # is already in a terminal state, it's a no-op at the HTTP/2 layer
            m_stream.sendData(binary(), True);
        }
    }

    #! Get the final call result (status from trailers)
    /** Automatically calls writesDone() if not already called.
        Reads any remaining messages and extracts the gRPC status.

        @return a @ref GrpcCallResult with response body and status info

        @see @ref Grpc::GrpcHelper::parseCallStatus() for the status sources
        covered (trailers, a Trailers-Only response, a non-gRPC HTTP failure)
    */
    hash<GrpcCallResult> finish() {
        # Auto-close writes if needed
        writesDone();

        # Drain remaining messages — catch errors so we can still return status
        *hash<ExceptionInfo> drain_error;
        try {
            while (!m_reads_done) {
                read();
            }
        } catch (hash<ExceptionInfo> ex) {
            m_reads_done = True;
            drain_error = ex;
        }

        hash<GrpcCallResult> result = GrpcHelper::parseCallStatus(m_stream.getResponse());
        result.body = m_last_body ?? {};
        # a drain failure only reports a status the server never sent itself
        if (drain_error && result.status_code == GRPC_STATUS_OK) {
            result.status_code = GRPC_STATUS_INTERNAL;
            result.status_message = sprintf("%s: %s", drain_error.err, drain_error.desc);
        }
        return result;
    }

    #! Returns True if the stream has received END_STREAM from the server
    /** @return True if reads are done and no more data will arrive
    */
    bool readsDone() {
        return m_reads_done;
    }

    #! Cancel the stream
    /** Sends RST_STREAM to abort the stream. Any unread messages are discarded.
    */
    cancel() {
        m_reads_done = True;
        m_stream.cancel();
    }

    #! Try to parse a complete gRPC frame from the read buffer
    private *hash<auto> tryParseFrame() {
        *binary msg_data = m_read_buf.takeFrame();
        if (!exists msg_data) {
            return NOTHING;
        }
        return m_schema.decode(m_read_type, msg_data);
    }
}

} # namespace Grpc
