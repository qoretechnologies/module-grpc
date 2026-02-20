# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcTypeHelper.qc Protobuf-to-DataProvider type mapping

/*  GrpcTypeHelper.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Static helper for converting protobuf message schemas to DataProvider types
public class GrpcTypeHelper {
    #! Converts a protobuf message type to a DataProvider HashDataType
    /** @param schema the protobuf schema
        @param type the fully-qualified message type name
        @param visited set of already-visited types (for cycle detection in recursive messages)

        @return a HashDataType describing the message structure
    */
    static AbstractDataProviderType messageToDataType(ProtobufSchema schema, string type,
            *hash<string, bool> visited) {
        # Cycle detection for recursive message types
        if (visited{type}) {
            return AbstractDataProviderType::get(AutoHashType);
        }
        visited{type} = True;

        hash<auto> msg_schema = schema.messageSchema(type);
        HashDataType dt(msg_schema.name);

        map dt.addField(GrpcTypeHelper::fieldToDataField(schema, $1.key, $1.value, visited)),
            msg_schema.fields.pairIterator();

        return dt;
    }

    #! Converts a single protobuf field to a QoreDataField
    /** @param schema the protobuf schema
        @param name the field name
        @param field_info the field info hash from messageSchema()
        @param visited set of already-visited types for cycle detection

        @return a QoreDataField for the field
    */
    static QoreDataField fieldToDataField(ProtobufSchema schema, string name,
            hash<auto> field_info, *hash<string, bool> visited) {
        AbstractDataProviderType field_type = GrpcTypeHelper::fieldInfoToType(schema, field_info,
            visited);

        # Wrap repeated fields in a list type
        if (field_info.label == "repeated" && field_info.type != "map") {
            field_type = new SoftListDataType(name, field_type);
        }

        return new QoreDataField(name, sprintf("protobuf %s field", field_info.type), field_type);
    }

    #! Maps a protobuf field info hash to a DataProvider type
    /** @param schema the protobuf schema
        @param field_info the field info hash from messageSchema()
        @param visited set of already-visited types for cycle detection

        @return the DataProvider type for the field
    */
    static AbstractDataProviderType fieldInfoToType(ProtobufSchema schema,
            hash<auto> field_info, *hash<string, bool> visited) {
        switch (field_info.type) {
            case "double":
            case "float":
                return AbstractDataProviderType::get(SoftFloatType);

            case "int32":
            case "sint32":
            case "sfixed32":
            case "int64":
            case "sint64":
            case "sfixed64":
            case "uint32":
            case "fixed32":
            case "uint64":
            case "fixed64":
                return AbstractDataProviderType::get(SoftIntType);

            case "bool":
                return AbstractDataProviderType::get(SoftBoolType);

            case "string":
                return AbstractDataProviderType::get(StringType);

            case "bytes":
                return AbstractDataProviderType::get(DataType);

            case "enum": {
                # Use SoftIntType with allowed_values from the enum
                AbstractDataProviderType etype = AbstractDataProviderType::get(SoftIntType);
                if (field_info.enum_values) {
                    list<auto> allowed = map <AllowedValueInfo>{
                        "value": $1.value,
                        "display_name": $1.key,
                    }, field_info.enum_values.pairIterator();
                    etype = etype.getOrNothingType();
                    # NOTE: allowed_values would need to be set differently if the
                    # DataProvider API supports it; for now we return the base int type
                }
                return etype;
            }

            case "message": {
                if (!field_info.message_type) {
                    return AbstractDataProviderType::get(AutoHashType);
                }
                return GrpcTypeHelper::messageToDataType(schema, field_info.message_type,
                    visited);
            }

            case "map": {
                HashDataType map_type(field_info.key_type + "_" + field_info.value_type
                    + "_map");
                # Set the default value type for all keys
                AbstractDataProviderType value_type;
                if (field_info.value_message_type) {
                    value_type = GrpcTypeHelper::messageToDataType(schema,
                        field_info.value_message_type, visited);
                } else {
                    value_type = GrpcTypeHelper::scalarToType(field_info.value_type);
                }
                map_type.setDefaultOtherFieldType(value_type);
                return map_type;
            }

            default:
                return AbstractDataProviderType::get(AutoType);
        }
    }

    #! Maps a scalar protobuf type name to a DataProvider type
    /** @param type_name the protobuf type name (e.g., "string", "int32")
        @return the DataProvider type
    */
    static AbstractDataProviderType scalarToType(string type_name) {
        switch (type_name) {
            case "double":
            case "float":
                return AbstractDataProviderType::get(SoftFloatType);

            case "int32":
            case "sint32":
            case "sfixed32":
            case "int64":
            case "sint64":
            case "sfixed64":
            case "uint32":
            case "fixed32":
            case "uint64":
            case "fixed64":
                return AbstractDataProviderType::get(SoftIntType);

            case "bool":
                return AbstractDataProviderType::get(SoftBoolType);

            case "string":
                return AbstractDataProviderType::get(StringType);

            case "bytes":
                return AbstractDataProviderType::get(DataType);

            case "enum":
                return AbstractDataProviderType::get(SoftIntType);

            default:
                return AbstractDataProviderType::get(AutoType);
        }
    }
}

} # namespace GrpcDataProvider
