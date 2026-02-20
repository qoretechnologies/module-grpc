# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcHelper.qc gRPC framing and header utilities

/*  GrpcHelper.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! gRPC framing and header utility class
/** Provides static methods for gRPC message framing, header construction,
    and timeout formatting.

    gRPC message framing format:
    - 1 byte: compressed flag (0 = uncompressed, 1 = compressed)
    - 4 bytes: big-endian message length
    - N bytes: message data

    @since Grpc 1.0
*/
public class GrpcHelper {
    #! Frame a binary message with the gRPC 5-byte header
    /** @param data the message payload
        @param compressed if True, set the compressed flag
        @return the framed message (5-byte header + payload)
    */
    static binary frameMessage(binary data, bool compressed = False) {
        int len = data.size();
        binary header = binary();
        # Compressed flag (1 byte)
        header += compressed ? <01> : <00>;
        # Length (4 bytes big-endian)
        header += <00000000>;
        header[1] = (len >> 24) & 0xFF;
        header[2] = (len >> 16) & 0xFF;
        header[3] = (len >> 8) & 0xFF;
        header[4] = len & 0xFF;
        return header + data;
    }

    #! Parse a gRPC-framed message
    /** @param data the framed message data (must be >= 5 bytes)
        @return a hash with \c compressed (bool) and \c data (binary) keys

        @throw GRPC-FRAMING-ERROR if the data is too short
    */
    static hash<auto> unframeMessage(binary data) {
        if (data.size() < 5) {
            throw "GRPC-FRAMING-ERROR", sprintf("gRPC frame too short: %d bytes (minimum 5)", data.size());
        }
        bool compressed = data[0] != 0;
        int len = (data[1] << 24) | (data[2] << 16) | (data[3] << 8) | data[4];
        if (data.size() < 5 + len) {
            throw "GRPC-FRAMING-ERROR", sprintf("gRPC frame declares %d bytes but only %d available",
                len, data.size() - 5);
        }
        return {
            "compressed": compressed,
            "data": data.substr(5, len),
        };
    }

    #! Format a timeout value for the grpc-timeout header
    /** @param timeout_ms timeout in milliseconds
        @return the formatted timeout string (e.g., "5000m" for 5000ms)
    */
    static string formatTimeout(int timeout_ms) {
        if (timeout_ms >= 100000000) {
            return sprintf("%dS", timeout_ms / 1000);
        }
        return sprintf("%dm", timeout_ms);
    }

    #! Parse a grpc-timeout header value
    /** @param value the timeout string (e.g., "5000m", "5S", "100u", "200n")
        @return the timeout in milliseconds, or NOTHING if the format is invalid
    */
    static *int parseTimeout(string value) {
        if (value.empty()) {
            return NOTHING;
        }
        string unit = value[-1];
        *string num_str = value.substr(0, value.size() - 1);
        if (!num_str.val()) {
            return NOTHING;
        }
        int num = int(num_str);
        switch (unit) {
            case "H": return num * 3600000;
            case "M": return num * 60000;
            case "S": return num * 1000;
            case "m": return num;
            case "u": return num / 1000;
            case "n": return num / 1000000;
            default: return NOTHING;
        }
    }

    #! Build standard gRPC request headers
    /** @param method_path the full gRPC method path (e.g., "/package.Service/Method")
        @param opts optional call options
        @return a hash of HTTP/2 headers for the request
    */
    static hash<string, string> buildRequestHeaders(string method_path,
            *hash<GrpcCallOptions> opts) {
        hash<string, string> headers = {
            "content-type": "application/grpc+proto",
            "te": "trailers",
        };

        if (opts.timeout_ms) {
            headers."grpc-timeout" = GrpcHelper::formatTimeout(opts.timeout_ms);
        }
        if (opts.compression) {
            headers."grpc-encoding" = opts.compression;
        }
        if (opts.metadata) {
            map headers{$1.key} = $1.value, opts.metadata.pairIterator();
        }

        return headers;
    }
}

} # namespace Grpc
