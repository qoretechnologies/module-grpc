# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcReflectionService.qc gRPC server reflection service implementation

/*  GrpcReflectionService.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Main Grpc namespace
public namespace Grpc {

#! Implements the gRPC Server Reflection service (grpc.reflection.v1)
/** Enables gRPC clients to discover services exposed by a @ref GrpcServer
    without needing local \c .proto files. This is the standard gRPC server
    reflection protocol used by tools such as \c grpcurl and \c grpc_cli.

    @note For most use cases, the simplest way to enable reflection is via the
    \c enable_reflection server option:
    @code{.py}
GrpcServer server(schema, <GrpcServerOptions>{"enable_reflection": True});
    @endcode

    Use this class directly when you need more control over the reflection
    service setup, for example to use the combined schema elsewhere.

    @par Manual Usage
    @code{.py}
%modern
%requires grpc
%requires GrpcUtil

ProtobufSchema schema("./proto/", "service.proto");
GrpcReflectionService reflection(schema);

# Use the combined schema (user + reflection) for the server
GrpcServer server(reflection.getCombinedSchema());

# Register your service handlers
server.registerHandler("MyService", "MyMethod",
    hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
        return {"result": "ok"};
    });

# Register the reflection service handlers
reflection.registerHandlers(server);

int port = server.addInsecurePort("localhost:0");
server.start();
server.wait();
    @endcode

    Clients can then discover and call services via reflection:
    @code{.sh}
# Using grpcurl
grpcurl -plaintext localhost:50051 list
grpcurl -plaintext localhost:50051 describe mypackage.MyService
    @endcode

    Or programmatically using @ref GrpcDataProvider::GrpcReflectionClient "GrpcReflectionClient":
    @code{.py}
GrpcChannel channel("http://localhost:50051");
GrpcReflectionClient rc(channel);
list<string> services = rc.listServices();
ProtobufSchema discovered = rc.discoverSchema();
    @endcode

    @since GrpcUtil 1.0
*/
public class GrpcReflectionService {
    #! The embedded reflection proto definition (grpc.reflection.v1)
    public const ReflectionProto = "syntax = \"proto3\";\n"
        "package grpc.reflection.v1;\n"
        "\n"
        "service ServerReflection {\n"
        "  rpc ServerReflectionInfo (stream ServerReflectionRequest)\n"
        "      returns (stream ServerReflectionResponse);\n"
        "}\n"
        "\n"
        "message ServerReflectionRequest {\n"
        "  string host = 1;\n"
        "  oneof message_request {\n"
        "    string file_by_filename = 3;\n"
        "    string file_containing_symbol = 4;\n"
        "    string file_containing_extension = 5;\n"
        "    string all_extension_numbers_of_type = 6;\n"
        "    string list_services = 7;\n"
        "  }\n"
        "}\n"
        "\n"
        "message ServerReflectionResponse {\n"
        "  string valid_host = 1;\n"
        "  ServerReflectionRequest original_request = 2;\n"
        "  oneof message_response {\n"
        "    FileDescriptorResponse file_descriptor_response = 4;\n"
        "    ExtensionNumberResponse all_extension_numbers_response = 5;\n"
        "    ListServiceResponse list_services_response = 6;\n"
        "    ErrorResponse error_response = 7;\n"
        "  }\n"
        "}\n"
        "\n"
        "message FileDescriptorResponse {\n"
        "  repeated bytes file_descriptor_proto = 1;\n"
        "}\n"
        "\n"
        "message ExtensionNumberResponse {\n"
        "  string base_type_name = 1;\n"
        "  repeated int32 extension_number = 2;\n"
        "}\n"
        "\n"
        "message ListServiceResponse {\n"
        "  repeated ServiceResponse service = 1;\n"
        "}\n"
        "\n"
        "message ServiceResponse {\n"
        "  string name = 1;\n"
        "}\n"
        "\n"
        "message ErrorResponse {\n"
        "  int32 error_code = 1;\n"
        "  string error_message = 2;\n"
        "}\n";

    private {
        #! The user's original schema (for descriptor lookups)
        ProtobufSchema m_user_schema;

        #! The reflection protocol schema
        ProtobufSchema m_reflection_schema;

        #! Combined schema (user + reflection)
        ProtobufSchema m_combined_schema;

        #! Cached list of fully-qualified service names from the user schema
        list<string> m_service_names;
    }

    #! Creates a GrpcReflectionService for the given user schema
    /** Builds a combined schema that includes both the user's services and
        the reflection service itself.

        @param user_schema the user's protobuf schema containing service definitions

        @since %GrpcUtil 1.0
    */
    constructor(ProtobufSchema user_schema) {
        m_user_schema = user_schema;
        m_reflection_schema = new ProtobufSchema(ReflectionProto);

        # Build combined schema from serialized descriptors
        list<binary> user_fds = user_schema.serializeFileDescriptors();
        list<binary> reflection_fds = m_reflection_schema.serializeFileDescriptors();
        m_combined_schema = new ProtobufSchema(user_fds + reflection_fds);

        # Cache the fully-qualified service names
        m_service_names = ();
        list<auto> services = user_schema.services();
        for (int i = 0; i < services.size(); ++i) {
            if (services[i].methods.size() > 0) {
                # Extract fully-qualified name from the first method's full_path
                # full_path is "/package.Service/Method"
                string fp = services[i].methods[0].full_path;
                list<string> parts = fp.split("/");
                m_service_names += parts[1];
            } else {
                m_service_names += services[i].name;
            }
        }
    }

    #! Returns the combined schema (user + reflection) for use with GrpcServer
    /** The GrpcServer must be constructed with this combined schema so that it
        knows about the \c ServerReflection service and its methods.

        @return the combined ProtobufSchema

        @since %GrpcUtil 1.0
    */
    ProtobufSchema getCombinedSchema() {
        return m_combined_schema;
    }

    #! Registers the reflection service handler on a GrpcServer
    /** Must be called after the server is constructed with getCombinedSchema().

        @param server the GrpcServer to register the reflection handler on

        @since %GrpcUtil 1.0
    */
    registerHandlers(GrpcServerAsync server) {
        # Typed to GrpcServerAsync because that's the canonical server class;
        # GrpcServer inherits from it (Phase 4 alias swap) so a GrpcServer
        # instance also satisfies this signature.
        server.registerHandler("ServerReflection", "ServerReflectionInfo",
            sub(GrpcServerStream stream, hash<string, string> metadata) {
                handleReflectionInfo(stream);
            });
    }

    #! Handles the bidirectional ServerReflectionInfo stream
    private handleReflectionInfo(GrpcServerStream stream) {
        while (*hash<auto> req = stream.read()) {
            try {
                hash<auto> response = processRequest(req);
                stream.write(response);
            } catch (hash<ExceptionInfo> ex) {
                # Send an error response for unexpected failures rather than
                # aborting the entire stream
                try {
                    stream.write(makeErrorResponse(GRPC_STATUS_INTERNAL,
                        sprintf("%s: %s", ex.err, ex.desc)));
                } catch () {
                    # If we can't even write an error, the stream is broken
                    break;
                }
            }
        }
    }

    #! Processes a single reflection request and returns the response
    private hash<auto> processRequest(hash<auto> req) {
        # Proto3 oneof: all fields have default values (empty string for strings).
        # Check fields with non-empty values first; list_services is checked last
        # because it's the only request that sends an empty string as its value.
        if (req.file_containing_symbol.val()) {
            return handleFileContainingSymbol(req.file_containing_symbol);
        }
        if (req.file_by_filename.val()) {
            return handleFileByFilename(req.file_by_filename);
        }
        if (req.file_containing_extension.val()) {
            return makeErrorResponse(GRPC_STATUS_UNIMPLEMENTED,
                "extensions are not supported in proto3");
        }
        if (req.all_extension_numbers_of_type.val()) {
            return {
                "all_extension_numbers_response": {
                    "base_type_name": req.all_extension_numbers_of_type,
                    "extension_number": (),
                },
            };
        }
        if (req.list_services.type() == "string") {
            # list_services sends empty string ""; check last since all oneof
            # fields default to "" in proto3
            return handleListServices();
        }
        return makeErrorResponse(GRPC_STATUS_INVALID_ARGUMENT,
            "unknown reflection request type");
    }

    #! Handles a list_services request
    private hash<auto> handleListServices() {
        list<hash<auto>> svc_list = ();
        for (int i = 0; i < m_service_names.size(); ++i) {
            svc_list += {"name": m_service_names[i]};
        }
        # Include the reflection service itself per the spec
        svc_list += {"name": "grpc.reflection.v1.ServerReflection"};
        return {
            "list_services_response": {
                "service": svc_list,
            },
        };
    }

    #! Handles a file_containing_symbol request
    private hash<auto> handleFileContainingSymbol(string symbol) {
        # Try user schema first
        try {
            list<binary> fds = m_user_schema.serializeFileDescriptorForSymbol(symbol);
            return {
                "file_descriptor_response": {
                    "file_descriptor_proto": fds,
                },
            };
        } catch (hash<ExceptionInfo> ex) {
            # Only fall through on "not found"; rethrow real errors
            if (ex.err != "PROTOBUF-SYMBOL-NOT-FOUND") {
                rethrow;
            }
        }

        # Try reflection schema
        try {
            list<binary> fds = m_reflection_schema.serializeFileDescriptorForSymbol(symbol);
            return {
                "file_descriptor_response": {
                    "file_descriptor_proto": fds,
                },
            };
        } catch (hash<ExceptionInfo> ex) {
            if (ex.err != "PROTOBUF-SYMBOL-NOT-FOUND") {
                rethrow;
            }
            return makeErrorResponse(GRPC_STATUS_NOT_FOUND,
                sprintf("symbol not found: %s", symbol));
        }
    }

    #! Handles a file_by_filename request
    private hash<auto> handleFileByFilename(string filename) {
        # Try user schema first
        try {
            list<binary> fds = m_user_schema.serializeFileDescriptorByName(filename);
            return {
                "file_descriptor_response": {
                    "file_descriptor_proto": fds,
                },
            };
        } catch (hash<ExceptionInfo> ex) {
            # Only fall through on "not found"; rethrow real errors
            if (ex.err != "PROTOBUF-FILE-NOT-FOUND") {
                rethrow;
            }
        }

        # Try reflection schema
        try {
            list<binary> fds = m_reflection_schema.serializeFileDescriptorByName(filename);
            return {
                "file_descriptor_response": {
                    "file_descriptor_proto": fds,
                },
            };
        } catch (hash<ExceptionInfo> ex) {
            if (ex.err != "PROTOBUF-FILE-NOT-FOUND") {
                rethrow;
            }
            return makeErrorResponse(GRPC_STATUS_NOT_FOUND,
                sprintf("file not found: %s", filename));
        }
    }

    #! Creates a reflection error response
    private static hash<auto> makeErrorResponse(int code, string message) {
        return {
            "error_response": {
                "error_code": code,
                "error_message": message,
            },
        };
    }
}

} # namespace Grpc
