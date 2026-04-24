# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightStreamReader.qc Arrow Flight stream reader

/*  ArrowFlightStreamReader.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Reads Arrow record batches from a Flight DoGet stream
/** Wraps a @ref GrpcClientStream for reading FlightData messages and
    deserializing them as Arrow objects. The schema is auto-detected from
    the first FlightData message's \c data_header field.

    @par Example:
    @code{.py}
ArrowFlightStreamReader reader = flight_client.doGet({"ticket": binary("my-dataset")});
ArrowSchema schema = reader.schema();
while (*ArrowRecordBatch batch = reader.read()) {
    printf("Rows: %d\n", batch.numRows());
}
    @endcode
*/
public class ArrowFlightStreamReader {
    private {
        #! The underlying gRPC client stream
        GrpcClientStream m_stream;

        #! The Arrow schema (auto-detected from first FlightData)
        *ArrowSchema m_schema;

        #! Whether the schema has been read
        bool m_schema_read = False;

        #! Whether all data has been read
        bool m_done = False;

        #! Last app_metadata received
        *binary m_app_metadata;
    }

    #! Create a new Arrow Flight stream reader
    /** @param stream the gRPC client stream from a DoGet call
    */
    constructor(GrpcClientStream stream) {
        m_stream = stream;
    }

    #! Returns the Arrow schema for the stream
    /** Reads the first FlightData message if not already read to extract the schema.

        @return the Arrow schema

        @throw ARROW-FLIGHT-ERROR if no schema could be read from the stream
    */
    ArrowSchema schema() {
        if (!m_schema_read) {
            readSchemaMessage();
        }
        if (!m_schema) {
            throw "ARROW-FLIGHT-ERROR", "no schema available from Flight stream";
        }
        return m_schema;
    }

    #! Read the next ArrowRecordBatch from the stream
    /** Automatically reads the schema from the first message if not already done.

        @param timeout optional read timeout

        @return the next ArrowRecordBatch, or NOTHING when the stream has ended
    */
    *ArrowRecordBatch read(*timeout timeout) {
        if (m_done) {
            return NOTHING;
        }

        # Ensure schema is read first
        if (!m_schema_read) {
            readSchemaMessage();
        }

        while (True) {
            *hash<auto> flight_data = m_stream.read(timeout);
            if (!flight_data) {
                if (m_stream.readsDone()) {
                    m_done = True;
                }
                return NOTHING;
            }

            # Store app_metadata
            if (flight_data.app_metadata) {
                m_app_metadata = flight_data.app_metadata;
            }

            # Skip schema-only messages (no data_header)
            if (!flight_data.data_header) {
                continue;
            }

            # Skip messages with no data_body (schema-only)
            if (!flight_data.data_body || flight_data.data_body.empty()) {
                continue;
            }

            if (!m_schema) {
                throw "ARROW-FLIGHT-ERROR", "no schema available from Flight stream";
            }
            return ArrowFlightHelper::flightDataToBatch(m_schema, flight_data);
        }
    }

    #! Returns True if the stream has been fully consumed
    /** @return True if no more record batches will arrive
    */
    bool readsDone() {
        return m_done || m_stream.readsDone();
    }

    #! Cancel the stream
    cancel() {
        m_done = True;
        m_stream.cancel();
    }

    #! Returns the last app_metadata received with a FlightData message
    /** @return the last application metadata, or NOTHING if none was received
    */
    *binary appMetadata() {
        return m_app_metadata;
    }

    #! Get the final call result
    /** @return a @ref GrpcCallResult with status information
    */
    hash<GrpcCallResult> finish() {
        return m_stream.finish();
    }

    #! Read the schema from the first FlightData message
    private readSchemaMessage() {
        m_schema_read = True;
        *hash<auto> flight_data = m_stream.read(30s);
        if (!flight_data) {
            return;
        }

        if (flight_data.app_metadata) {
            m_app_metadata = flight_data.app_metadata;
        }

        if (flight_data.data_header) {
            m_schema = ArrowFlightHelper::flightDataToSchema(flight_data);
        }
    }
}

} # namespace Grpc
