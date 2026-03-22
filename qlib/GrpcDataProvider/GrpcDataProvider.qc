# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcDataProvider.qc Root data provider for gRPC services

/*  GrpcDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! The main app name for action catalog registration
public const AppName = "gRPC";

#! Root data provider for gRPC services
/** Provides hierarchical access to gRPC services and methods via the data provider API.

    The provider hierarchy is:
    - GrpcDataProvider (root -- schema + connection)
      - \<service_name\> (GrpcServiceDataProvider)
        - \<method_name\> (GrpcMethodDataProvider -- supports doRequest)

    @par Example
    @code{.py}
GrpcDataProvider provider({
    "url": "http://localhost:50051",
    "proto_path": "./proto",
    "proto_file": "service.proto",
});
auto result = provider.getChildProvider("MyService").getChildProvider("MyMethod").doRequest({"name": "World"});
    @endcode

    @since GrpcDataProvider 1.0
*/
public class GrpcDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "GrpcDataProvider",
            "supports_children": True,
            "constructor_options": ConstructorOptions,
            "children_can_support_apis": True,
            "children_can_support_observers": True,
        };

        #! Constructor options
        const ConstructorOptions = {
            "url": <DataProviderOptionInfo>{
                "display_name": "URL",
                "short_desc": "The gRPC server URL",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "The URL of the gRPC server (e.g., `http://localhost:50051` "
                    "or `https://api.example.com:443`)",
            },
            "proto_path": <DataProviderOptionInfo>{
                "display_name": "Proto Path",
                "short_desc": "Path to directory containing .proto files",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "Filesystem path to the directory containing `.proto` files",
            },
            "proto_file": <DataProviderOptionInfo>{
                "display_name": "Proto File",
                "short_desc": "Name of the .proto file to load",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "The `.proto` file name within the `proto_path` directory",
            },
            "proto_content": <DataProviderOptionInfo>{
                "display_name": "Proto Content",
                "short_desc": "Inline .proto definition as a string",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "Inline protobuf schema definition as a string",
            },
            "use_reflection": <DataProviderOptionInfo>{
                "display_name": "Use Reflection",
                "short_desc": "Use gRPC server reflection for schema discovery",
                "type": AbstractDataProviderType::get(SoftBoolType),
                "desc": "If `True`, uses the gRPC server reflection protocol to "
                    "discover available services and their schemas",
                "default_value": False,
            },
            "timeout_ms": <DataProviderOptionInfo>{
                "display_name": "Timeout",
                "short_desc": "Default call timeout in milliseconds",
                "type": AbstractDataProviderType::get(SoftIntType),
                "desc": "The default timeout for gRPC calls in milliseconds",
                "default_value": 30000,
            },
            "grpcchannel": <DataProviderOptionInfo>{
                "display_name": "gRPC Channel",
                "short_desc": "A pre-built GrpcChannel object",
                "type": AbstractDataProviderType::get(new Type("GrpcChannel"), NOTHING, {
                    DTT_ClientOnly: True,
                }),
                "desc": "A pre-built `GrpcChannel` object for connection pooling",
            },
            "schema": <DataProviderOptionInfo>{
                "display_name": "Schema",
                "short_desc": "A pre-built ProtobufSchema object",
                "type": AbstractDataProviderType::get(new Type("ProtobufSchema"), NOTHING, {
                    DTT_ClientOnly: True,
                }),
                "desc": "A pre-built `ProtobufSchema` object",
            },
        };
    }

    private {
        #! The gRPC channel
        GrpcChannel channel;

        #! The protobuf schema
        ProtobufSchema proto_schema;

        #! Default options for calls
        *hash<auto> default_opts;

        #! Service map: service name -> GrpcServiceInfo
        hash<string, hash<ProtobufServiceInfo>> service_map;

        #! Display name
        string display_name = "gRPC";
    }

    #! Creates the root gRPC data provider from constructor options
    /** @param options constructor options hash

        @throw CONSTRUCTOR-ERROR missing or invalid options
    */
    constructor(*hash<auto> options) {
        *hash<auto> copts = checkOptions("CONSTRUCTOR-ERROR", ConstructorOptions, options);

        # Build schema
        if (copts.schema) {
            proto_schema = copts.schema;
        } else if (copts.proto_path && copts.proto_file) {
            proto_schema = new ProtobufSchema(copts.proto_path, copts.proto_file);
        } else if (copts.proto_content) {
            proto_schema = new ProtobufSchema(copts.proto_content);
        } else if (!copts.use_reflection) {
            throw "CONSTRUCTOR-ERROR", "one of 'proto_path'+'proto_file', 'proto_content', "
                "'schema', or 'use_reflection' must be provided";
        }

        # Build channel
        if (copts.grpcchannel) {
            channel = copts.grpcchannel;
        } else if (copts.url) {
            channel = new GrpcChannel(copts.url);
        }

        # Handle reflection
        if (copts.use_reflection && !proto_schema) {
            if (!channel) {
                throw "CONSTRUCTOR-ERROR", "'url' or 'grpcchannel' is required when "
                    "'use_reflection' is True";
            }
            GrpcReflectionClient reflection_client(channel);
            proto_schema = reflection_client.discoverSchema();
        }

        # Store default options
        if (copts.timeout_ms) {
            default_opts.timeout_ms = copts.timeout_ms;
        }

        # Cache service metadata
        if (proto_schema) {
            setupServiceMap();
            if (copts.url) {
                display_name = sprintf("gRPC %s", copts.url);
            }
        }
    }

    #! Creates the root gRPC data provider from a schema and channel
    /** @param schema the protobuf schema
        @param channel the gRPC channel
        @param default_opts default call options
    */
    constructor(ProtobufSchema schema, GrpcChannel channel, *hash<auto> default_opts) {
        self.proto_schema = schema;
        self.channel = channel;
        self.default_opts = default_opts;
        setupServiceMap();
        display_name = sprintf("gRPC %s", channel.target());
    }

    #! Returns the data provider name
    string getName() {
        return display_name;
    }

    #! Returns the data provider description
    *string getDesc() {
        return sprintf("gRPC data provider with %d service(s)", service_map.size());
    }

    #! Returns child provider names (service names)
    private *list<string> getChildProviderNamesImpl() {
        return keys service_map;
    }

    #! Returns a child provider by name (service provider)
    private *AbstractDataProvider getChildProviderImpl(string name) {
        *hash<ProtobufServiceInfo> sinfo = service_map{name};
        if (!sinfo) {
            return NOTHING;
        }
        return new GrpcServiceDataProvider(channel, proto_schema, sinfo, default_opts);
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }

    #! Returns the schema object
    private object getSchemaObjectImpl() {
        return proto_schema;
    }

    #! Populates the service map from the schema
    private setupServiceMap() {
        list<auto> services = proto_schema.services();
        map (service_map{$1.name} = $1), services;
    }
}

} # namespace GrpcDataProvider
