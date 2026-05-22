# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightExchangeStream.qc Arrow Flight bidirectional exchange stream

/*  ArrowFlightExchangeStream.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Bidirectional Arrow Flight exchange stream combining reader and writer
/** Wraps a @ref GrpcClientStream for the DoExchange RPC, providing both
    reading and writing of Arrow data. If a write schema is provided, the
    initial FlightData with the schema is sent in the constructor.

    @par Example:
    @code{.py}
hash<auto> descriptor = ArrowFlightHelper::pathDescriptor("transform");
ArrowFlightExchangeStream exchange = flight_client.doExchange(descriptor, write_schema);

# Send data
exchange.write(input_batch);
exchange.writesDone();

# Read results
ArrowSchema result_schema = exchange.readSchema();
while (*ArrowRecordBatch batch = exchange.read()) {
    printf("Result rows: %d\n", batch.numRows());
}
    @endcode
*/
public class ArrowFlightExchangeStream {
    private {
        #! The underlying gRPC client stream
        GrpcClientStream m_stream;

        #! The read schema (auto-detected from first incoming FlightData)
        *ArrowSchema m_read_schema;

        #! The write schema for outgoing hash/list data
        *ArrowSchema m_write_schema;

        #! Whether the read schema has been detected
        bool m_read_schema_detected = False;

        #! Whether all reads are done
        bool m_done = False;

        #! Last app_metadata received
        *binary m_app_metadata;
    }

    #! Create a new Arrow Flight exchange stream
    /** @param stream the gRPC client stream from a DoExchange call
        @param write_schema optional Arrow schema for outgoing data; if provided,
        an initial FlightData message with the schema is sent
        @param descriptor optional FlightDescriptor to include in the first message
    */
    constructor(GrpcClientStream stream, *ArrowSchema write_schema,
            *hash<auto> descriptor) {
        m_stream = stream;
        m_write_schema = write_schema;

        # Send initial FlightData with schema if provided
        if (write_schema) {
            hash<auto> initial = ArrowFlightHelper::schemaToFlightData(write_schema,
                descriptor);
            m_stream.write(initial);
        } else if (descriptor) {
            # Send descriptor-only FlightData
            m_stream.write({
                "flight_descriptor": descriptor,
                "data_header": binary(),
                "data_body": binary(),
            });
        }
    }

    #! Returns the schema for incoming data
    /** Reads the first incoming FlightData message if not already read to extract
        the schema.

        @return the Arrow schema for incoming data

        @throw ARROW-FLIGHT-ERROR if no schema could be read
    */
    ArrowSchema readSchema() {
        if (!m_read_schema_detected) {
            readSchemaMessage();
        }
        if (!m_read_schema) {
            throw "ARROW-FLIGHT-ERROR", "no read schema available from exchange stream";
        }
        return m_read_schema;
    }

    #! Read the next ArrowRecordBatch from the stream
    /** @param timeout optional read timeout

        @return the next ArrowRecordBatch, or NOTHING when the stream has ended
    */
    *ArrowRecordBatch read(*timeout timeout) {
        if (m_done) {
            return NOTHING;
        }

        if (!m_read_schema_detected) {
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

            if (flight_data.app_metadata) {
                m_app_metadata = flight_data.app_metadata;
            }

            # Skip schema-only messages
            if (!flight_data.data_header || !flight_data.data_body
                    || flight_data.data_body.empty()) {
                continue;
            }

            if (!m_read_schema) {
                throw "ARROW-FLIGHT-ERROR", "no schema available from exchange stream";
            }
            return ArrowFlightHelper::flightDataToBatch(m_read_schema, flight_data);
        }
    }

    #! Read the next record batch as a ColumnarResult
    /** @param timeout optional read timeout

        @return the next \c ColumnarResult, or \c NOTHING when the stream has ended

        @throw ARROW-COLUMNAR-ERROR if the grpc module was built without qore
        \c ColumnarResult v2 support
    */
    auto readColumnarResult(*timeout timeout) {
        *ArrowRecordBatch batch = read(timeout);
        return batch ? batch.toColumnarResult() : NOTHING;
    }

    #! Returns True if the read side of the stream has ended
    /** @return True if no more record batches will arrive
    */
    bool readsDone() {
        return m_done || m_stream.readsDone();
    }

    #! Write columnar data to the stream
    /** @param batch an ArrowRecordBatch, ColumnarResult, DataFrame, hash-of-lists, or row-list to write
        @param app_metadata optional application-specific metadata
    */
    write(auto batch, *binary app_metadata) {
        hash<auto> flight_data = ArrowFlightHelper::batchToFlightData(batch, app_metadata,
            m_write_schema);
        m_stream.write(flight_data);
    }

    #! Signal that no more batches will be written
    writesDone() {
        m_stream.writesDone();
    }

    #! Cancel the stream
    cancel() {
        m_done = True;
        m_stream.cancel();
    }

    #! Returns the last app_metadata received
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

    #! Read the schema from the first incoming FlightData message
    private readSchemaMessage() {
        m_read_schema_detected = True;
        *hash<auto> flight_data = m_stream.read(30s);
        if (!flight_data) {
            return;
        }

        if (flight_data.app_metadata) {
            m_app_metadata = flight_data.app_metadata;
        }

        if (flight_data.data_header) {
            m_read_schema = ArrowFlightHelper::flightDataToSchema(flight_data);
        }
    }
}

} # namespace Grpc
