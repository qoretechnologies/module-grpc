# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcServiceDataProvider.qc Service-level data provider for gRPC services

/*  GrpcServiceDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Service-level data provider that contains method child providers
/** Each gRPC service in a protobuf schema is represented by one instance of this class.
    Its children are the individual RPC methods defined in the service.
*/
public class GrpcServiceDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "GrpcServiceDataProvider",
            "supports_children": True,
            "children_can_support_apis": True,
            "children_can_support_observers": True,
        };
    }

    private {
        #! The gRPC channel
        GrpcChannel channel;

        #! The protobuf schema
        ProtobufSchema schema;

        #! The service info
        hash<ProtobufServiceInfo> service_info;

        #! Method map: method name -> GrpcMethodInfo
        hash<string, hash<ProtobufMethodInfo>> method_map;

        #! Default options for calls
        *hash<auto> default_opts;
    }

    #! Creates the service data provider
    /** @param channel the gRPC channel
        @param schema the protobuf schema
        @param service_info the service info from the schema
        @param default_opts default options for calls
    */
    constructor(GrpcChannel channel, ProtobufSchema schema,
            hash<ProtobufServiceInfo> service_info, *hash<auto> default_opts) {
        self.channel = channel;
        self.schema = schema;
        self.service_info = service_info;
        self.default_opts = default_opts;

        # Index methods by name
        map (method_map{$1.name} = $1), service_info.methods;
    }

    #! Returns the data provider name
    string getName() {
        return service_info.name;
    }

    #! Returns the data provider description
    *string getDesc() {
        return sprintf("gRPC service `%s` with %d method(s)", service_info.name,
            service_info.methods.size());
    }

    #! Returns child provider names (method names)
    private *list<string> getChildProviderNamesImpl() {
        return keys method_map;
    }

    #! Returns a child provider by name
    private *AbstractDataProvider getChildProviderImpl(string name) {
        *hash<ProtobufMethodInfo> minfo = method_map{name};
        if (!minfo) {
            return NOTHING;
        }
        return new GrpcMethodDataProvider(channel, schema, service_info, minfo, default_opts);
    }

    #! Returns static provider info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}

} # namespace GrpcDataProvider
