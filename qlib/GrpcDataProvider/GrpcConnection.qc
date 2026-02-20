# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcConnection.qc GrpcConnection class for gRPC connections

/*  GrpcConnection.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Contains all public definitions in the GrpcDataProvider module
public namespace GrpcDataProvider {

#! Connection class for gRPC services
/** Supports \c grpc:// (plaintext h2c) and \c grpcs:// (TLS) URL schemes.
    The URL is automatically converted to the appropriate \c http:// or \c https://
    scheme for the underlying HTTP/2 transport.

    @since GrpcDataProvider 1.0
*/
public class GrpcConnection inherits ConnectionProvider::AbstractConnectionWithInfo {
    public {
        #! Connection scheme info
        const ConnectionScheme = <ConnectionSchemeInfo>{
            "display_name": "gRPC Connection",
            "short_desc": "A connection to a gRPC server",
            "desc": "A connection to a gRPC server supporting protobuf serialization "
                "and all four RPC patterns (unary, server streaming, client streaming, "
                "and bidirectional streaming)",
            "cls": Class::forName("GrpcDataProvider::GrpcConnection"),
            "schemes": {
                "grpc": True,
                "grpcs": True,
            },
            "base_scheme_map": {
                "grpc": "http",
                "grpcs": "https",
            },
            "options": {
                "proto_path": <ConnectionOptionInfo>{
                    "display_name": "Proto File Path",
                    "short_desc": "Path to directory containing .proto files",
                    "type": "string",
                    "desc": "Filesystem path to the directory containing `.proto` files",
                },
                "proto_file": <ConnectionOptionInfo>{
                    "display_name": "Proto File Name",
                    "short_desc": "Name of the .proto file to load",
                    "type": "string",
                    "desc": "The `.proto` file name within the `proto_path` directory",
                },
                "proto_content": <ConnectionOptionInfo>{
                    "display_name": "Proto Content",
                    "short_desc": "Inline .proto definition as a string",
                    "type": "string",
                    "desc": "Inline protobuf schema definition as a string; use this "
                        "when the schema is not available as a file",
                },
                "use_reflection": <ConnectionOptionInfo>{
                    "display_name": "Use Reflection",
                    "short_desc": "Use gRPC server reflection for schema discovery",
                    "type": "bool",
                    "desc": "If `True`, the gRPC server reflection protocol will be used "
                        "to discover available services and their schemas dynamically",
                    "default_value": False,
                },
                "timeout_ms": <ConnectionOptionInfo>{
                    "display_name": "Timeout",
                    "short_desc": "Default call timeout in milliseconds",
                    "type": "int",
                    "desc": "The default timeout for gRPC calls in milliseconds",
                    "default_value": 30000,
                },
            },
        };
    }

    #! Creates the GrpcConnection object
    /** @param name the connection name
        @param description connection description
        @param url the connection URL (grpc:// or grpcs://)
        @param attributes optional connection attributes
        @param options connection options
    */
    constructor(string name, string description, string url, hash<auto> attributes = {},
            hash<auto> options = {})
            : AbstractConnectionWithInfo(name, description, url, attributes, options) {
    }

    #! Creates the GrpcConnection object from a config hash
    /** @param config connection configuration hash
        @param attr optional connection attributes
    */
    constructor(hash<auto> config, *hash<auto> attr) : AbstractConnectionWithInfo(config, attr) {
    }

    #! Returns a GrpcDataProvider for this connection
    /** @return a GrpcDataProvider configured with this connection's URL and options
    */
    DataProvider::AbstractDataProvider getDataProvider() {
        # Convert grpc:// -> http:// and grpcs:// -> https://
        string http_url = getHttpUrl();

        hash<auto!> opts({
            "url": http_url,
        });
        if (self.opts.proto_path) {
            opts.proto_path = self.opts.proto_path;
        }
        if (self.opts.proto_file) {
            opts.proto_file = self.opts.proto_file;
        }
        if (self.opts.proto_content) {
            opts.proto_content = self.opts.proto_content;
        }
        if (self.opts.use_reflection) {
            opts.use_reflection = self.opts.use_reflection;
        }
        if (self.opts.timeout_ms) {
            opts.timeout_ms = self.opts.timeout_ms;
        }
        return new GrpcDataProvider(opts);
    }

    #! Returns \c "grpc"
    string getType() {
        return "grpc";
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
        return new GrpcChannel(getHttpUrl());
    }

    #! Returns a ping hash for the connection
    private hash<PingInfo> pingImpl() {
        hash<PingInfo> rv;
        date start = now_us();
        try {
            GrpcChannel channel(getHttpUrl());
            on_exit channel.shutdown();
            # Acquiring a stream validates the HTTP/2 connection
            auto stream = channel.acquireStream();
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

    #! Converts grpc:// to http:// and grpcs:// to https://
    private string getHttpUrl() {
        string http_url = url;
        if (http_url =~ /^grpcs:/) {
            http_url = regex_subst(http_url, "^grpcs:", "https:");
        } else if (http_url =~ /^grpc:/) {
            http_url = regex_subst(http_url, "^grpc:", "http:");
        }
        return http_url;
    }
}

} # namespace GrpcDataProvider
