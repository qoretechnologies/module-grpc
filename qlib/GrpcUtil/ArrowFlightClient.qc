# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightClient.qc High-level Arrow Flight client

/*  ArrowFlightClient.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! High-level Arrow Flight client wrapping GrpcClient with typed Flight methods
/** Provides a convenient API for interacting with Arrow Flight servers,
    automatically handling FlightData serialization and deserialization.

    @par Example:
    @code{.py}
GrpcChannel channel("http://localhost:8815");
ArrowFlightClient flight(channel);

# List available datasets
list<hash<auto>> flights = flight.listFlights();
for (int i = 0; i < flights.size(); ++i) {
    printf("Dataset: %y\n", flights[i].flight_descriptor);
}

# Read data
hash<auto> ticket = {"ticket": binary("my-dataset")};
ArrowFlightStreamReader reader = flight.doGet(ticket);
ArrowSchema schema = reader.schema();
while (*ArrowRecordBatch batch = reader.read()) {
    printf("Got %d rows\n", batch.numRows());
}
    @endcode
*/
public class ArrowFlightClient {
    private {
        #! The underlying gRPC client
        GrpcClient m_client;

        #! The gRPC channel
        GrpcChannel m_channel;
    }

    #! Create a new Arrow Flight client
    /** @param channel the gRPC channel for connections
    */
    constructor(GrpcChannel channel) {
        m_channel = channel;
        m_client = new GrpcClient(channel, FlightProto::get(),
            "arrow.flight.protocol.FlightService");
    }

    #! List available flights (datasets) on the server
    /** @param criteria optional criteria for filtering flights
        @param opts optional call options

        @return a list of FlightInfo hashes
    */
    list<hash<auto>> listFlights(*hash<auto> criteria, *hash<GrpcCallOptions> opts) {
        hash<auto> request = criteria ?? {"expression": binary()};
        GrpcClientStream stream = m_client.serverStream("ListFlights", request, opts);
        list<hash<auto>> flights = ();
        while (*hash<auto> info = stream.read(30s)) {
            flights += info;
        }
        checkFinish(stream, "ListFlights");
        return flights;
    }

    #! Get flight info for a specific dataset
    /** @param descriptor the FlightDescriptor identifying the dataset
        @param opts optional call options

        @return a FlightInfo hash
    */
    hash<auto> getFlightInfo(hash<auto> descriptor, *hash<GrpcCallOptions> opts) {
        hash<GrpcCallResult> result = m_client.call("GetFlightInfo", descriptor, opts);
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR", sprintf("GetFlightInfo failed: %s (status %d)",
                result.status_message, result.status_code);
        }
        return result.body;
    }

    #! Poll for updated flight info
    /** @param descriptor the FlightDescriptor identifying the dataset
        @param opts optional call options

        @return a PollInfo hash
    */
    hash<auto> pollFlightInfo(hash<auto> descriptor, *hash<GrpcCallOptions> opts) {
        hash<GrpcCallResult> result = m_client.call("PollFlightInfo", descriptor, opts);
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR", sprintf("PollFlightInfo failed: %s (status %d)",
                result.status_message, result.status_code);
        }
        return result.body;
    }

    #! Get the schema for a dataset
    /** @param descriptor the FlightDescriptor identifying the dataset
        @param opts optional call options

        @return the ArrowSchema deserialized from the SchemaResult
    */
    ArrowSchema getSchema(hash<auto> descriptor, *hash<GrpcCallOptions> opts) {
        hash<GrpcCallResult> result = m_client.call("GetSchema", descriptor, opts);
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR", sprintf("GetSchema failed: %s (status %d)",
                result.status_message, result.status_code);
        }
        if (!result.body.schema) {
            throw "ARROW-FLIGHT-ERROR", "GetSchema response has no schema field";
        }
        return ArrowIpc::readSchema(result.body.schema);
    }

    #! List available actions on the server
    /** @param opts optional call options

        @return a list of ActionType hashes with \c type and \c description fields
    */
    list<hash<auto>> listActions(*hash<GrpcCallOptions> opts) {
        GrpcClientStream stream = m_client.serverStream("ListActions", {}, opts);
        list<hash<auto>> actions = ();
        while (*hash<auto> action_type = stream.read(30s)) {
            actions += action_type;
        }
        checkFinish(stream, "ListActions");
        return actions;
    }

    #! Read data from a dataset via DoGet
    /** Returns a stream reader for consuming Arrow record batches.

        @param ticket the Ticket identifying the data to retrieve
        @param opts optional call options

        @return an ArrowFlightStreamReader for reading record batches
    */
    ArrowFlightStreamReader doGet(hash<auto> ticket, *hash<GrpcCallOptions> opts) {
        GrpcClientStream stream = m_client.serverStream("DoGet", ticket, opts);
        return new ArrowFlightStreamReader(stream);
    }

    #! Write data to a dataset via DoPut
    /** Returns a stream writer for sending Arrow record batches.

        @param descriptor the FlightDescriptor identifying the destination dataset
        @param schema the Arrow schema for the data being written
        @param opts optional call options

        @return an ArrowFlightStreamWriter for writing record batches
    */
    ArrowFlightStreamWriter doPut(hash<auto> descriptor, ArrowSchema schema,
            *hash<GrpcCallOptions> opts) {
        GrpcClientStream stream = m_client.clientStream("DoPut", opts);
        return new ArrowFlightStreamWriter(stream, schema, descriptor);
    }

    #! Start a bidirectional data exchange via DoExchange
    /** Returns an exchange stream for both reading and writing Arrow data.

        @param descriptor the FlightDescriptor for the exchange
        @param write_schema optional Arrow schema for outgoing data
        @param opts optional call options

        @return an ArrowFlightExchangeStream for bidirectional data exchange
    */
    ArrowFlightExchangeStream doExchange(hash<auto> descriptor,
            *ArrowSchema write_schema, *hash<GrpcCallOptions> opts) {
        GrpcClientStream stream = m_client.bidiStream("DoExchange", opts);
        return new ArrowFlightExchangeStream(stream, write_schema, descriptor);
    }

    #! Execute an action on the server
    /** @param action the Action hash with \c type and optional \c body fields
        @param opts optional call options

        @return a list of Result hashes
    */
    list<hash<auto>> doAction(hash<auto> action, *hash<GrpcCallOptions> opts) {
        GrpcClientStream stream = m_client.serverStream("DoAction", action, opts);
        list<hash<auto>> results = ();
        while (*hash<auto> result = stream.read(30s)) {
            results += result;
        }
        checkFinish(stream, "DoAction");
        return results;
    }

    #! Get the underlying GrpcClient
    /** @return the GrpcClient used by this Flight client
    */
    GrpcClient getGrpcClient() {
        return m_client;
    }

    #! Get the gRPC channel
    /** @return the GrpcChannel used by this Flight client
    */
    GrpcChannel getChannel() {
        return m_channel;
    }

    #! Finishes a streaming call and throws on error
    private checkFinish(GrpcClientStream stream, string rpc_name) {
        hash<GrpcCallResult> result = stream.finish();
        if (result.status_code != GRPC_STATUS_OK) {
            throw "ARROW-FLIGHT-ERROR", sprintf("%s failed: %s (status %d)",
                rpc_name, result.status_message, result.status_code);
        }
    }
}

} # namespace Grpc
