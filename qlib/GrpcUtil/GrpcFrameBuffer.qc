# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcFrameBuffer.qc incremental gRPC message deframer

/*  GrpcFrameBuffer.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Incremental deframer for the gRPC length-prefixed message framing
/** HTTP/2 DATA frames do not align with gRPC message boundaries: one transport
    chunk may carry a partial message, several messages, or both.  This class
    accumulates transport bytes and hands back complete gRPC message payloads as
    soon as they are available.

    The framing is the standard gRPC wire format handled by
    @ref Grpc::GrpcHelper "GrpcHelper":
    - 1 byte: compressed flag
    - 4 bytes: big-endian payload length
    - N bytes: payload

    @par Example:
    @code{.py}
GrpcFrameBuffer fb();
fb.add(chunk);
while (*binary payload = fb.takeFrame()) {
    hash<auto> msg = schema.decode(type, payload);
}
    @endcode

    @note This class is not thread-safe; callers must serialize access.
*/
public class GrpcFrameBuffer {
    private {
        #! Accumulated transport bytes
        binary buf = binary();

        #! Number of leading bytes in \c buf already consumed by @ref takeFrame()
        /** Frames are consumed by advancing this offset rather than by
            rewriting \c buf, so draining a chunk that carries many messages
            costs one pass over the bytes instead of one copy of the remainder
            per message.  The consumed prefix is dropped in @ref add(), which
            runs once per transport chunk rather than once per message.
        */
        int consumed = 0;
    }

    #! Appends transport data to the buffer
    /** @param d the transport chunk; strings are converted to their binary
        representation
    */
    add(data d) {
        # drop the already-consumed prefix before growing the buffer
        if (consumed) {
            buf = consumed < buf.size() ? buf.substr(consumed) : binary();
            consumed = 0;
        }
        if (d.typeCode() == NT_BINARY) {
            buf += d;
        } else {
            buf += binary(d);
        }
    }

    #! Removes and returns the next complete gRPC message payload
    /** @return the message payload without the 5-byte gRPC frame header, or
        @ref nothing if the buffer does not yet hold a complete frame

        @throw GRPC-FRAMING-ERROR if the frame declares a negative length
    */
    *binary takeFrame() {
        if (size() < 5) {
            return NOTHING;
        }
        int len = frameLength();
        if (len < 0) {
            throw "GRPC-FRAMING-ERROR",
                sprintf("gRPC frame declares an invalid length: %d", len);
        }
        if (size() < 5 + len) {
            return NOTHING;
        }
        binary payload = buf.substr(consumed + 5, len);
        consumed += 5 + len;
        if (consumed == buf.size()) {
            buf = binary();
            consumed = 0;
        }
        return payload;
    }

    #! Returns True if a complete frame is available
    /** @return True if @ref takeFrame() would return a payload
    */
    bool hasFrame() {
        return size() >= 5 && size() >= 5 + frameLength();
    }

    #! Returns the number of unconsumed bytes in the buffer
    /** @return the number of buffered bytes; non-zero after the last complete
        frame means a truncated frame was received
    */
    int size() {
        return buf.size() - consumed;
    }

    #! Returns True if the buffer holds no unconsumed bytes
    /** @return True if the buffer is empty
    */
    bool empty() {
        return !size();
    }

    #! Discards all buffered bytes
    clear() {
        buf = binary();
        consumed = 0;
    }

    #! Returns the payload length declared by the frame at the read offset
    /** @note the caller must ensure at least 5 unconsumed bytes are available
    */
    private int frameLength() {
        return (buf[consumed + 1] << 24) | (buf[consumed + 2] << 16)
            | (buf[consumed + 3] << 8) | buf[consumed + 4];
    }
}

} # namespace Grpc
