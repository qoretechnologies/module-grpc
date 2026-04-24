# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcReflectionClient.qc gRPC server reflection protocol client

/*  GrpcReflectionClient.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! gRPC server reflection protocol client
/** Implements the gRPC Server Reflection protocol
    (\c grpc.reflection.v1.ServerReflection) for dynamically discovering
    services and their schemas from a running gRPC server.
*/
public class GrpcReflectionClient {
    #! The embedded reflection proto definition
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
        #! The gRPC channel
        GrpcChannel channel;

        #! Schema for the reflection service
        ProtobufSchema reflection_schema;
    }

    #! Creates a reflection client
    /** @param channel the gRPC channel to the server
    */
    constructor(GrpcChannel channel) {
        self.channel = channel;
        reflection_schema = new ProtobufSchema(ReflectionProto);
    }

    #! Lists all services available on the server
    /** @return a list of fully-qualified service names

        @throw GRPC-REFLECTION-ERROR if the server does not support reflection
    */
    list<string> listServices() {
        GrpcClient client(channel, reflection_schema, "ServerReflection");
        GrpcClientStream stream = client.bidiStream("ServerReflectionInfo");

        # Send list_services request
        stream.write({
            "list_services": "",
        });
        stream.writesDone();

        # Read response
        *hash<auto> response = stream.read();
        if (!response) {
            throw "GRPC-REFLECTION-ERROR", "no response from reflection service";
        }
        stream.finish();

        if (response.list_services_response.service) {
            return map $1.name, response.list_services_response.service;
        }

        if (response.error_response.error_message) {
            throw "GRPC-REFLECTION-ERROR",
                sprintf("reflection error %d: %s", response.error_response.error_code,
                    response.error_response.error_message);
        }

        throw "GRPC-REFLECTION-ERROR", "unexpected response from reflection service";
    }

    #! Gets serialized FileDescriptorProto data for a service
    /** @param service_name the fully-qualified service name
        @return a list of binary data, each containing a serialized FileDescriptorProto

        @throw GRPC-REFLECTION-ERROR if the descriptors cannot be retrieved
    */
    list<binary> getFileDescriptorsForService(string service_name) {
        GrpcClient client(channel, reflection_schema, "ServerReflection");
        GrpcClientStream stream = client.bidiStream("ServerReflectionInfo");

        # Request file containing the service symbol
        stream.write({
            "file_containing_symbol": service_name,
        });
        stream.writesDone();

        *hash<auto> response = stream.read();
        if (!response) {
            throw "GRPC-REFLECTION-ERROR", "no response from reflection service";
        }
        stream.finish();

        if (response.file_descriptor_response.file_descriptor_proto) {
            return response.file_descriptor_response.file_descriptor_proto;
        }

        if (response.error_response.error_message) {
            throw "GRPC-REFLECTION-ERROR",
                sprintf("reflection error for '%s': %d: %s", service_name,
                    response.error_response.error_code,
                    response.error_response.error_message);
        }

        throw "GRPC-REFLECTION-ERROR",
            sprintf("unexpected response for service '%s'", service_name);
    }

    #! Discovers all services and builds a ProtobufSchema
    /** Uses server reflection to:
        1. List all services
        2. Fetch FileDescriptorProto data for each service
        3. Build a ProtobufSchema from the collected descriptors

        @return a ProtobufSchema containing all discovered services

        @throw GRPC-REFLECTION-ERROR if discovery fails
    */
    ProtobufSchema discoverSchema() {
        # Step 1: List all services
        list<string> services = listServices();

        if (!services) {
            throw "GRPC-REFLECTION-ERROR", "no services found via reflection";
        }

        # Step 2: Get file descriptors for each service
        hash<string, bool> seen;
        list<binary> all_descriptors = ();

        for (int i = 0; i < services.size(); ++i) {
            if (services[i] =~ /grpc\.reflection/) {
                continue;
            }

            list<binary> fds = getFileDescriptorsForService(services[i]);
            for (int j = 0; j < fds.size(); ++j) {
                string key = fds[j].toHex();
                if (!seen{key}) {
                    seen{key} = True;
                    all_descriptors += fds[j];
                }
            }
        }

        if (!all_descriptors) {
            throw "GRPC-REFLECTION-ERROR", "no file descriptors found via reflection";
        }

        return new ProtobufSchema(all_descriptors);
    }
}

} # namespace GrpcDataProvider
