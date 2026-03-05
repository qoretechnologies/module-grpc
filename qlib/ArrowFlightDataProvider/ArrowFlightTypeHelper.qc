# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightTypeHelper.qc Arrow schema to DataProvider type mapping

/*  ArrowFlightTypeHelper.qc Copyright 2026 Qore Technologies, s.r.o.

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

public namespace ArrowFlightDataProvider {

#! Maps Arrow schema fields to DataProvider types
/** @since ArrowFlightDataProvider 1.0
*/
public class ArrowFlightTypeHelper {
    #! Convert an ArrowSchema to a DataProvider HashDataType
    /** @param schema the Arrow schema
        @param name the type name
        @return a HashDataType representing the schema's fields
    */
    static AbstractDataProviderType schemaToDataType(ArrowSchema schema, string name) {
        HashDataType type(name);
        hash<auto> info = schema.info();
        for (int i = 0; i < info.fields.size(); ++i) {
            hash<auto> field = info.fields[i];
            AbstractDataProviderType field_type = arrowTypeToDataType(field.type);
            type.addField(new QoreDataField(field.name,
                sprintf("Arrow field: %s", field.type), field_type));
        }
        return type;
    }

    #! Convert an Arrow type string to a DataProvider type
    /** @param arrow_type the Arrow type string (e.g., "int64", "utf8", "float64")
        @return the corresponding DataProvider type
    */
    static AbstractDataProviderType arrowTypeToDataType(string arrow_type) {
        # Strip any parameters like "timestamp[us, tz=UTC]" or "decimal128(18, 4)"
        string base_type = arrow_type;
        int bracket = base_type.find("[");
        if (bracket >= 0) {
            base_type = base_type.substr(0, bracket);
        }
        int paren = base_type.find("(");
        if (paren >= 0) {
            base_type = base_type.substr(0, paren);
        }

        switch (base_type) {
            case "int8":
            case "int16":
            case "int32":
            case "int64":
            case "uint8":
            case "uint16":
            case "uint32":
            case "uint64":
                return AbstractDataProviderType::get(IntType);

            case "float16":
            case "float32":
            case "float64":
                return AbstractDataProviderType::get(FloatType);

            case "decimal128":
            case "decimal256":
                return AbstractDataProviderType::get(NumberType);

            case "utf8":
            case "large_utf8":
            case "string":
                return AbstractDataProviderType::get(StringType);

            case "binary":
            case "large_binary":
            case "fixed_size_binary":
                return AbstractDataProviderType::get(BinaryType);

            case "bool":
                return AbstractDataProviderType::get(SoftBoolType);

            case "date32":
            case "date64":
            case "timestamp":
            case "time32":
            case "time64":
            case "duration":
                return AbstractDataProviderType::get(DateType);

            case "null":
                return AbstractDataProviderType::get(NothingType);

            case "list":
            case "large_list":
            case "fixed_size_list":
                return AbstractDataProviderType::get(SoftListType);

            case "struct":
            case "map":
                return AbstractDataProviderType::get(AutoHashType);

            default:
                return AbstractDataProviderType::get(AutoType);
        }
    }
}

} # namespace ArrowFlightDataProvider
