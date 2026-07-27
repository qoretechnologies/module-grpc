# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcChannel.qc gRPC channel (connection pool wrapper)

/*  GrpcChannel.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Represents a gRPC channel (connection pool) to a remote server
/** Wraps @ref HttpClientIo::HttpClientConnectionManager for HTTP/2 connection
    pooling and multiplexing.

    @par Example:
    @code{.py}
GrpcChannel channel("https://localhost:50051");
GrpcClient client(channel, schema, "MyService");
    @endcode
*/
public class GrpcChannel {
    private {
        #! Target URL (e.g., "https://localhost:50051")
        string m_target;
        #! Connection manager
        HttpClientIo::HttpClientConnectionManager m_mgr;
    }

    #! Create a new gRPC channel to the given target
    /** @param target the target URL (e.g., \c "https://localhost:50051" or \c "http://localhost:50051")
        @param opts optional channel options

        @note For a \c https target with no TLS verification configuration, all certificates are
        accepted, including self-signed ones; this is convenient for a local test server but must
        not be used against a production service.  Set
        \c opts.ssl.verify_mode to
        \c SSL_VERIFY_PEER to require verification against the system CA store.
    */
    constructor(string target, *hash<GrpcChannelOptions> opts) {
        m_target = target;

        hash<HttpClientIo::HttpClientConnectionManagerOptions> mgr_opts({
            # gRPC requires HTTP/2; disable QUIC/HTTP/3 auto-negotiation
            "protocol": "h2",
        });

        # Configure TLS
        if (target =~ /^https:/) {
            if (exists opts.ssl.verify_mode) {
                # An explicit verification mode wins; SSL_VERIFY_NONE means "accept anything"
                if (opts.ssl.verify_mode == SSL_VERIFY_NONE) {
                    mgr_opts.accept_all_certs = True;
                } else {
                    mgr_opts.ssl_verify_mode = opts.ssl.verify_mode;
                }
            } else if (opts.ssl.root_certs) {
                # When root_certs is provided, use strict verification
                mgr_opts.ssl_verify_mode = SSL_VERIFY_PEER;
            } else {
                # No verification configuration — accept all certs for development/testing
                mgr_opts.accept_all_certs = True;
            }
        }

        m_mgr = new HttpClientIo::HttpClientConnectionManager(mgr_opts);
    }

    #! Shut down the channel and close all connections
    /** Should be called when the channel is no longer needed.
    */
    shutdown() {
        m_mgr.closeAll();
    }

    #! Get the target URL
    /** @return the target URL
    */
    string target() {
        return m_target;
    }

    #! Acquire an HTTP/2 stream handle for a request
    /** @return a new stream handle from the connection pool
    */
    HttpClientIo::HttpClientStreamHandle acquireStream() {
        return m_mgr.acquireStream(m_target);
    }

    #! Get the underlying connection manager
    /** @return the @ref HttpClientIo::HttpClientConnectionManager "HttpClientConnectionManager"
        used by this channel
    */
    HttpClientIo::HttpClientConnectionManager getConnectionManager() {
        return m_mgr;
    }
}

} # namespace Grpc
