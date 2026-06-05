# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightStreamWriter.qc Arrow Flight stream writer

/*  ArrowFlightStreamWriter.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Writes Arrow record batches to a Flight DoPut stream
/** Wraps a @ref GrpcClientStream for writing FlightData messages. The
    constructor sends the initial FlightData message with the schema and
    optional flight descriptor.

    @par Example:
    @code{.py}
hash<auto> descriptor = ArrowFlightHelper::pathDescriptor("my-dataset");
ArrowFlightStreamWriter writer = flight_client.doPut(descriptor, schema);
writer.write(batch1);
writer.write(batch2);
hash<auto> result = writer.finish();
    @endcode
*/
public class ArrowFlightStreamWriter {
    private {
        #! The underlying gRPC client stream
        GrpcClientStream m_stream;

        #! The Arrow schema
        ArrowSchema m_schema;
    }

    #! Create a new Arrow Flight stream writer
    /** Sends the initial FlightData message containing the serialized schema
        and optional flight descriptor.

        @param stream the gRPC client stream from a DoPut call
        @param schema the Arrow schema for the data being written
        @param descriptor optional FlightDescriptor to include in the first message
    */
    constructor(GrpcClientStream stream, ArrowSchema schema, *hash<auto> descriptor) {
        m_stream = stream;
        m_schema = schema;

        # Send initial FlightData with schema
        hash<auto> initial = ArrowFlightHelper::schemaToFlightData(schema, descriptor);
        m_stream.write(initial);
    }

    #! Write columnar data to the stream
    /** Serializes the batch as a FlightData message and sends it.

        @param batch an ArrowRecordBatch, ColumnarResult, DataFrame, hash-of-lists, or row-list to write
        @param app_metadata optional application-specific metadata
    */
    write(auto batch, *binary app_metadata) {
        hash<auto> flight_data = ArrowFlightHelper::batchToFlightData(batch, app_metadata, m_schema);
        m_stream.write(flight_data);
    }

    #! Signal that no more batches will be written
    writesDone() {
        m_stream.writesDone();
    }

    #! Cancel the stream
    /** Aborts the DoPut stream, signalling cancellation to the server.
    */
    cancel() {
        m_stream.cancel();
    }

    #! Finish the stream and return the result
    /** Automatically calls writesDone() if not already called.

        @return a @ref GrpcCallResult with status information and PutResult
    */
    hash<GrpcCallResult> finish() {
        return m_stream.finish();
    }
}

} # namespace Grpc
