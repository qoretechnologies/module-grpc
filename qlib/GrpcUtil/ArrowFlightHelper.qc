# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightHelper.qc Static helpers for FlightData / Arrow object conversion

/*  ArrowFlightHelper.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Static helper class for converting between FlightData messages and Arrow objects
/** Provides utility methods for:
    - Converting FlightData messages to ArrowSchema and ArrowRecordBatch objects
    - Converting Arrow objects to FlightData messages for transmission
    - Building FlightDescriptor hashes

    @par Example:
    @code{.py}
# Convert an ArrowSchema to a FlightData message
hash<auto> flight_data = ArrowFlightHelper::schemaToFlightData(schema);

# Convert FlightData back to an ArrowSchema
ArrowSchema schema = ArrowFlightHelper::flightDataToSchema(flight_data);
    @endcode
*/
public class ArrowFlightHelper {
    #! Convert a FlightData message to an ArrowSchema
    /** Deserializes the IPC schema from the \c data_header field of a FlightData
        message.

        @param flight_data the FlightData message hash with a \c data_header field
        containing an IPC-serialized Arrow schema

        @return the deserialized ArrowSchema

        @throw ARROW-FLIGHT-ERROR if the FlightData message has no data_header
    */
    static ArrowSchema flightDataToSchema(hash<auto> flight_data) {
        if (!flight_data.data_header) {
            throw "ARROW-FLIGHT-ERROR", "FlightData message has no data_header for schema";
        }
        return ArrowIpc::readSchemaPayload(flight_data.data_header);
    }

    #! Convert a FlightData message to an ArrowRecordBatch
    /** Deserializes a record batch from the \c data_header and \c data_body fields
        of a FlightData message using the provided schema.

        @param schema the Arrow schema for the record batch
        @param flight_data the FlightData message hash with \c data_header and
        \c data_body fields

        @return the deserialized ArrowRecordBatch

        @throw ARROW-FLIGHT-ERROR if the FlightData message has no data_header
    */
    static ArrowRecordBatch flightDataToBatch(ArrowSchema schema, hash<auto> flight_data) {
        if (!flight_data.data_header) {
            throw "ARROW-FLIGHT-ERROR",
                "FlightData message has no data_header for record batch";
        }
        binary data_body = flight_data.data_body ?? binary();
        return ArrowIpc::readRecordBatch(schema, flight_data.data_header, data_body);
    }

    #! Convert a FlightData message to a ColumnarResult
    /** Deserializes a record batch and converts it to a \c ColumnarResult.

        @param schema the Arrow schema for the record batch
        @param flight_data the FlightData message hash with \c data_header and
        \c data_body fields

        @return a \c Qore::SQL::ColumnarResult object

        @throw ARROW-COLUMNAR-ERROR if the grpc module was built without qore
        \c ColumnarResult v2 support
        @throw ARROW-FLIGHT-ERROR if the FlightData message is invalid
    */
    static auto flightDataToColumnarResult(ArrowSchema schema, hash<auto> flight_data) {
        return ArrowFlightHelper::flightDataToBatch(schema, flight_data).toColumnarResult();
    }

    #! Convert an ArrowSchema to a FlightData message
    /** Serializes an ArrowSchema as a FlightData message suitable for sending
        as the first message in a DoGet, DoPut, or DoExchange stream.

        @param schema the Arrow schema to serialize
        @param descriptor optional FlightDescriptor to include in the message

        @return a FlightData message hash
    */
    static hash<auto> schemaToFlightData(ArrowSchema schema, *hash<auto> descriptor) {
        hash<auto> flight_data({
            "data_header": ArrowIpc::writeSchemaPayload(schema),
            "data_body": binary(),
        });
        if (descriptor) {
            flight_data.flight_descriptor = descriptor;
        }
        return flight_data;
    }

    #! Converts supported columnar data to an ArrowRecordBatch
    /** Accepts an existing \c ArrowRecordBatch, a \c ColumnarResult, a DataFrame-like
        object exposing \c toColumnarResult(), a hash of columns, or a list of row
        hashes. Hash and list inputs require \a schema.

        @param data the input data
        @param schema optional Arrow schema used for hash/list inputs

        @return an ArrowRecordBatch

        @throw ARROW-FLIGHT-ERROR if the value cannot be converted
    */
    static ArrowRecordBatch toRecordBatch(auto data, *ArrowSchema schema) {
        if (data.typeCode() == NT_OBJECT) {
            string cls = data.className();
            if (cls == "ArrowRecordBatch") {
                return data;
            }
            if (cls == "ColumnarResult") {
                return new ArrowRecordBatch(data);
            }

            try {
                return new ArrowRecordBatch(data.toColumnarResult());
            } catch (hash<ExceptionInfo> ex) {
                if (ex.err != "INVALID-METHOD" && ex.err != "METHOD-DOES-NOT-EXIST"
                        && ex.err != "NO-METHOD") {
                    rethrow;
                }
            }
        }

        if (data.typeCode() == NT_HASH) {
            if (!schema) {
                throw "ARROW-FLIGHT-ERROR",
                    "hash column input requires an ArrowSchema";
            }
            hash<auto> columns = data;
            return new ArrowRecordBatch(schema, columns);
        }

        if (data.typeCode() == NT_LIST) {
            if (!schema) {
                throw "ARROW-FLIGHT-ERROR",
                    "row-list input requires an ArrowSchema";
            }
            list<hash<auto>> rows = data;
            return new ArrowRecordBatch(schema, rows);
        }

        throw "ARROW-FLIGHT-ERROR", sprintf(
            "cannot convert value of type '%s' to ArrowRecordBatch", data.fullType());
    }

    #! Convert columnar data to a FlightData message
    /** Serializes an ArrowRecordBatch-compatible value as a FlightData message for streaming.

        @param batch the record batch, ColumnarResult, DataFrame, hash-of-lists, or row-list to serialize
        @param app_metadata optional application-specific metadata
        @param schema optional schema for hash/list input

        @return a FlightData message hash
    */
    static hash<auto> batchToFlightData(auto batch, *binary app_metadata, *ArrowSchema schema) {
        ArrowRecordBatch record_batch = ArrowFlightHelper::toRecordBatch(batch, schema);
        hash<auto> ipc = ArrowIpc::writeRecordBatch(record_batch);
        hash<auto> flight_data({
            "data_header": ipc.data_header,
            "data_body": ipc.data_body,
        });
        if (app_metadata) {
            flight_data.app_metadata = app_metadata;
        }
        return flight_data;
    }

    #! Build a path-based FlightDescriptor
    /** @param path the dataset path (first element used as dataset name)

        @return a FlightDescriptor hash with type PATH
    */
    static hash<auto> pathDescriptor(string path) {
        return {
            "type": FlightProto::FLIGHT_DESCRIPTOR_PATH,
            "path": (path,),
        };
    }

    #! Build a path-based FlightDescriptor with multiple path elements
    /** @param path_elements list of path elements

        @return a FlightDescriptor hash with type PATH
    */
    static hash<auto> pathDescriptor(list<string> path_elements) {
        return {
            "type": FlightProto::FLIGHT_DESCRIPTOR_PATH,
            "path": path_elements,
        };
    }

    #! Build a command-based FlightDescriptor
    /** @param cmd the command string (sent as bytes)

        @return a FlightDescriptor hash with type CMD
    */
    static hash<auto> cmdDescriptor(string cmd) {
        return {
            "type": FlightProto::FLIGHT_DESCRIPTOR_CMD,
            "cmd": binary(cmd),
        };
    }
}

} # namespace Grpc
