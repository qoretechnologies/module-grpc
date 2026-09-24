# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightConnection.qc ArrowFlightConnection class for Flight connections

/*  ArrowFlightConnection.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Contains all public definitions in the ArrowFlightDataProvider module
public namespace ArrowFlightDataProvider {

#! Connection class for Arrow Flight services
/** Supports \c flight:// (plaintext h2c) and \c flights:// (TLS) URL schemes.
    The URL is automatically converted to the appropriate \c http:// or \c https://
    scheme for the underlying HTTP/2 transport.
*/
public class ArrowFlightConnection inherits ConnectionProvider::AbstractConnectionWithInfo {
    public {
        #! Connection scheme info
        const ConnectionScheme = <ConnectionSchemeInfo>{
            "display_name": "Arrow Flight Connection",
            "short_desc": "A connection to an Arrow Flight server",
            "desc": "A connection to an Arrow Flight server for high-performance columnar "
                "data exchange using Apache Arrow IPC format",
            "cls": Class::forName("ArrowFlightDataProvider::ArrowFlightConnection"),
            "schemes": {
                "flight": True,
                "flights": True,
            },
            "base_scheme_map": {
                "flight": "http",
                "flights": "https",
            },
            "options": {
                "max_message_size": <ConnectionOptionInfo>{
                    "display_name": "Max Message Size",
                    "short_desc": "The maximum size of a response message received",
                    "type": "int",
                    "desc": "The maximum size in bytes of one response message received from the server; `0` (the "
                        "default) means no limit.\n\n"
                        "A larger message ends the call with the `RESOURCE_EXHAUSTED` status, so a huge message cannot "
                        "exhaust memory; this limit also applies to streaming calls.",
                },
                "max_response_body_size": <ConnectionOptionInfo>{
                    "display_name": "Max Response Body Size",
                    "short_desc": "The maximum size of a unary response body received into memory",
                    "type": "int",
                    "desc": "The maximum size in bytes of the response body of a unary call, which is received into "
                        "memory completely before it is decoded; `0` (the default) means no limit.\n\n"
                        "A larger response ends the call with the `RESOURCE_EXHAUSTED` status.  The response of a "
                        "streaming call is received one message at a time and is limited by `max_message_size` instead.",
                },
                "timeout_ms": <ConnectionOptionInfo>{
                    "display_name": "Timeout",
                    "short_desc": "Default call timeout in milliseconds",
                    "type": "int",
                    "desc": "The default timeout for Arrow Flight calls in milliseconds",
                    "default_value": 30000,
                },
            },
        };
    }

    #! Creates the ArrowFlightConnection object
    /** @param name the connection name
        @param description connection description
        @param url the connection URL (flight:// or flights://)
        @param attributes optional connection attributes
        @param options connection options
    */
    constructor(string name, string description, string url, hash<auto> attributes = {},
            hash<auto> options = {})
            : AbstractConnectionWithInfo(name, description, url, attributes, options) {
    }

    #! Creates the ArrowFlightConnection object from a config hash
    /** @param config connection configuration hash
        @param attr optional connection attributes
    */
    constructor(hash<auto> config, *hash<auto> attr) : AbstractConnectionWithInfo(config, attr) {
    }

    #! Returns an ArrowFlightDataProvider for this connection
    /** @return an ArrowFlightDataProvider configured with this connection's URL and options
    */
    DataProvider::AbstractDataProvider getDataProvider() {
        string http_url = getHttpUrl();

        hash<auto!> provider_opts({
            "url": http_url,
        });
        if (self.opts.timeout_ms) {
            provider_opts.timeout_ms = self.opts.timeout_ms;
        }
        provider_opts += getChannelOptions();
        return new ArrowFlightDataProvider(provider_opts);
    }

    #! Returns \c "flight"
    string getType() {
        return "flight";
    }

    #! Returns the ConnectionSchemeInfo for this connection
    private hash<ConnectionSchemeInfo> getConnectionSchemeInfoImpl() {
        return ConnectionScheme;
    }

    #! Returns the underlying connection object
    /** @param connect if True, the connection should be established
        @param rtopts runtime options

        @return a GrpcChannel object for this connection
    */
    private GrpcChannel getImpl(bool connect = True, *hash<auto> rtopts) {
        return new GrpcChannel(getHttpUrl(), getChannelOptions());
    }

    #! Returns a ping hash for the connection
    private hash<PingInfo> pingImpl() {
        hash<PingInfo> rv;
        date start = now_us();
        try {
            GrpcChannel ch(getHttpUrl(), getChannelOptions());
            on_exit ch.shutdown();
            auto stream = ch.acquireStream();
            rv.ok = True;
            rv.time = now_us() - start;
            rv.info = "OK";
        } catch (hash<ExceptionInfo> ex) {
            rv.ok = False;
            rv.time = now_us() - start;
            rv.info = sprintf("%s: %s", ex.err, ex.desc);
        }
        return rv;
    }

    #! Returns the channel options for the size limits set in the connection options
    private hash<GrpcChannelOptions> getChannelOptions() {
        hash<GrpcChannelOptions> rv();
        if (self.opts.max_message_size) {
            rv.max_message_size = self.opts.max_message_size;
        }
        if (self.opts.max_response_body_size) {
            rv.max_response_body_size = self.opts.max_response_body_size;
        }
        return rv;
    }

    #! Converts flight:// to http:// and flights:// to https://
    private string getHttpUrl() {
        string http_url = url;
        if (http_url =~ /^flights:/) {
            http_url = regex_subst(http_url, "^flights:", "https:");
        } else if (http_url =~ /^flight:/) {
            http_url = regex_subst(http_url, "^flight:", "http:");
        }
        return http_url;
    }
}

} # namespace ArrowFlightDataProvider
