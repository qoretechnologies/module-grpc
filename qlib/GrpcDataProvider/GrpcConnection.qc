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
*/
public class GrpcConnection inherits ConnectionProvider::AbstractConnectionWithInfo {
    #! Returns the functional domains of the connection's clients (qoretechnologies/qore#7095)
    /** The clients connect to a gRPC server and read the \c .proto files of the \c proto_path option.

        The connection declares \c FILESYSTEM because \c proto_path may read files, so code restricted from the file
        system cannot create a gRPC connection, even one that uses \c proto_content only.
    */
    private final int getConnectionDomainsImpl() {
        return DOM_NETWORK | DOM_FILESYSTEM;
    }

    public {
        #! Connection scheme info
        const ConnectionScheme = ConnectionProvider::connection_scheme_presentation("GrpcDataProvider",
            "GrpcConnection", "en", <ConnectionSchemeInfo>{
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
        });
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

        @throw PERMISSION-DENIED the calling code was lent the connection and is restricted from a functional domain
        of the connection, and the connection's URL or options are not the ones that its creator gave (see
        @ref grpcdplent)
    */
    DataProvider::AbstractDataProvider getDataProvider() {
        # the data provider is created from the connection's public members, which restricted code that was lent the
        # connection can change: for such code, it is created from a private copy with its creator's members, once
        # they were checked (module-grpc#16)
        return cast<GrpcConnection>(getLentDataProviderSource()).getDataProviderIntern();
    }

    #! Returns a GrpcDataProvider created from the members of this object
    private:internal GrpcDataProvider getDataProviderIntern() {
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
        opts += getChannelOptions();
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
        return new GrpcChannel(getHttpUrl(), getChannelOptions());
    }

    #! Pings the server: makes an HTTP/2 connection to it
    /** A stream is acquired on a new channel, and the ping waits until its connection is ready for requests or
        fails; an error is thrown, so that the ping reports it and marks the connection down

        @throw HTTPCLIENT-CONNECT-ERROR the connection to the server cannot be made
        @throw GRPC-PING-ERROR the connection was not ready within the timeout of the connection (\c timeout_ms)
    */
    private pingImpl() {
        # the channel is created by get(): for restricted code that was lent the connection, from a private copy
        # with its creator's members (module-grpc#17)
        GrpcChannel channel = get(False);
        on_exit channel.shutdown();
        # acquiring a stream starts the connection; a connection error is raised when it is waited for
        int timeout_ms = opts.timeout_ms ?? 30000;
        if (!channel.acquireStream().getConnectionView().waitForReady(timeout_ms)) {
            throw "GRPC-PING-ERROR", sprintf("the connection to %y was not ready within %d ms", channel.target(),
                timeout_ms);
        }
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
