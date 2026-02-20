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
/** Wraps @ref Http2ClientIo::Http2ClientConnectionManager for HTTP/2 connection
    pooling and multiplexing.

    @par Example:
    @code{.py}
GrpcChannel channel("https://localhost:50051");
GrpcClient client(channel, schema, "MyService");
    @endcode

    @since Grpc 1.0
*/
public class GrpcChannel {
    private {
        #! Target URL (e.g., "https://localhost:50051")
        string m_target;
        #! Connection manager
        Http2ClientIo::Http2ClientConnectionManager m_mgr;
        #! Async I/O controller for driving HTTP/2 connections
        AsyncSocketIo::AsyncSocketIoController m_controller(False);
    }

    #! Create a new gRPC channel to the given target
    /** @param target the target URL (e.g., \c "https://localhost:50051" or \c "http://localhost:50051")
        @param opts optional channel options

        @since %Grpc 1.0
    */
    constructor(string target, *hash<GrpcChannelOptions> opts) {
        m_target = target;

        hash<Http2ClientIo::Http2ClientConnectionManagerOptions> mgr_opts();

        # Configure TLS
        if (target =~ /^https:/) {
            if (opts.ssl) {
                # When root_certs is provided, use strict verification
                if (opts.ssl.root_certs) {
                    mgr_opts.ssl_verify_mode = SSL_VERIFY_PEER;
                } else {
                    # No root certs provided — accept all certs for development/testing
                    mgr_opts.accept_all_certs = True;
                }
            } else {
                # No SSL options — accept all certs by default for convenience
                mgr_opts.accept_all_certs = True;
            }
        }

        m_mgr = new Http2ClientIo::Http2ClientConnectionManager(mgr_opts);

        # Set up controller mode for async I/O (required for streaming)
        m_mgr.setController(m_controller);
        m_controller.start();
    }

    #! Shut down the channel and stop the I/O controller
    /** Stops the async I/O controller. Should be called when the channel is
        no longer needed.

        @since %Grpc 1.0
    */
    shutdown() {
        m_controller.stop();
    }

    #! Destructor — ensures the I/O controller is stopped on object destruction
    /** @since %Grpc 1.0
    */
    destructor() {
        m_controller.stop();
    }

    #! Get the target URL
    /** @return the target URL

        @since %Grpc 1.0
    */
    string target() {
        return m_target;
    }

    #! Acquire an HTTP/2 stream handle for a request
    /** @return a new stream handle from the connection pool

        @since %Grpc 1.0
    */
    Http2ClientIo::Http2ClientStreamHandle acquireStream() {
        return m_mgr.acquireStream(m_target);
    }

    #! Get the underlying connection manager
    /** @return the @ref Http2ClientIo::Http2ClientConnectionManager "Http2ClientConnectionManager"
        used by this channel

        @since %Grpc 1.0
    */
    Http2ClientIo::Http2ClientConnectionManager getConnectionManager() {
        return m_mgr;
    }
}

} # namespace Grpc
