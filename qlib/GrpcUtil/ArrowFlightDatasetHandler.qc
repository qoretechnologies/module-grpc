# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightDatasetHandler.qc Abstract base class for Flight dataset handlers

/*  ArrowFlightDatasetHandler.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Abstract base class for implementing Arrow Flight dataset handlers
/** Subclass this to expose a dataset via an @ref ArrowFlightServer. At
    minimum, implement getSchema(), getFlightInfo(), and doGet().

    @par Example:
    @code{.py}
class SalesDataHandler inherits ArrowFlightDatasetHandler {
    ArrowSchema getSchema() {
        return new ArrowSchema((
            {"name": "id", "type": "int64"},
            {"name": "product", "type": "utf8"},
            {"name": "amount", "type": "float64"},
        ));
    }

    hash<auto> getFlightInfo(hash<auto> descriptor) {
        return {
            "schema": ArrowIpc::writeSchema(getSchema()),
            "flight_descriptor": descriptor,
            "total_records": 100,
            "total_bytes": -1,
        };
    }

    nothing doGet(hash<auto> ticket, GrpcServerStream stream) {
        ArrowSchema schema = getSchema();
        # Send schema as first FlightData
        stream.write(ArrowFlightHelper::schemaToFlightData(schema));
        # Send data batches
        ArrowRecordBatch batch(schema, (
            {"id": 1, "product": "Widget", "amount": 9.99},
            {"id": 2, "product": "Gadget", "amount": 24.99},
        ));
        stream.write(ArrowFlightHelper::batchToFlightData(batch));
    }
}
    @endcode

    @since GrpcUtil 1.0
*/
public class ArrowFlightDatasetHandler {
    #! Returns the Arrow schema for this dataset
    /** @return the ArrowSchema describing the dataset's columns

        @since %GrpcUtil 1.0
    */
    abstract ArrowSchema getSchema();

    #! Returns flight info for this dataset
    /** @param descriptor the FlightDescriptor from the client's request

        @return a FlightInfo hash with schema, endpoints, and metadata

        @since %GrpcUtil 1.0
    */
    abstract hash<auto> getFlightInfo(hash<auto> descriptor);

    #! Serves data for a DoGet request
    /** Writes FlightData messages to the server stream. The first message
        should contain the serialized schema (use
        @ref ArrowFlightHelper::schemaToFlightData()), followed by messages
        containing record batches (use
        @ref ArrowFlightHelper::batchToFlightData()).

        @param ticket the Ticket from the client's request
        @param stream the server stream to write FlightData messages to

        @since %GrpcUtil 1.0
    */
    abstract nothing doGet(hash<auto> ticket, GrpcServerStream stream);

    #! Handles a DoPut request (optional)
    /** Default implementation throws UNIMPLEMENTED.

        @param descriptor the FlightDescriptor from the first FlightData
        @param stream the server stream for reading incoming FlightData messages

        @return a PutResult hash

        @since %GrpcUtil 1.0
    */
    hash<auto> doPut(hash<auto> descriptor, GrpcServerStream stream) {
        throw "GRPC-UNIMPLEMENTED", "DoPut not implemented for this dataset";
    }

    #! Handles a DoExchange request (optional)
    /** Default implementation throws UNIMPLEMENTED.

        @param descriptor the FlightDescriptor from the first FlightData
        @param stream the server stream for bidirectional FlightData exchange

        @since %GrpcUtil 1.0
    */
    nothing doExchange(hash<auto> descriptor, GrpcServerStream stream) {
        throw "GRPC-UNIMPLEMENTED", "DoExchange not implemented for this dataset";
    }
}

} # namespace Grpc
