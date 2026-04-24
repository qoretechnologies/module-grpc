# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file FlightProto.qc Arrow Flight protocol definition and cached schema

/*  FlightProto.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Provides the Arrow Flight protocol definition and a cached ProtobufSchema
/** The Arrow Flight protocol is a gRPC-based protocol for high-performance
    columnar data exchange defined by Apache Arrow. This class embeds the
    \c flight.proto definition and provides a cached @ref ProtobufSchema
    for use by Flight clients and servers.

    @par Example:
    @code{.py}
ProtobufSchema schema = FlightProto::get();
GrpcClient client(channel, schema, "FlightService");
    @endcode
*/
public class FlightProto {
    public {
        #! The Arrow Flight protocol definition (proto3)
        /** Based on the Apache Arrow Flight protocol specification.

            @note \c PollInfo uses simplified types (double for progress,
            int64 for expiration_time) instead of google.protobuf.Duration
            and google.protobuf.Timestamp to avoid well-known type import
            dependencies.
        */
        const FlightProtoDefinition = "
syntax = \"proto3\";

package arrow.flight.protocol;

service FlightService {
  rpc Handshake(stream HandshakeRequest) returns (stream HandshakeResponse) {}
  rpc ListFlights(Criteria) returns (stream FlightInfo) {}
  rpc GetFlightInfo(FlightDescriptor) returns (FlightInfo) {}
  rpc PollFlightInfo(FlightDescriptor) returns (PollInfo) {}
  rpc GetSchema(FlightDescriptor) returns (SchemaResult) {}
  rpc DoGet(Ticket) returns (stream FlightData) {}
  rpc DoPut(stream FlightData) returns (stream PutResult) {}
  rpc DoExchange(stream FlightData) returns (stream FlightData) {}
  rpc DoAction(Action) returns (stream Result) {}
  rpc ListActions(Empty) returns (stream ActionType) {}
}

message HandshakeRequest {
  uint64 protocol_version = 1;
  bytes payload = 2;
}

message HandshakeResponse {
  uint64 protocol_version = 1;
  bytes payload = 2;
}

message BasicAuth {
  string username = 1;
  string password = 2;
}

message Empty {}

message ActionType {
  string type = 1;
  string description = 2;
}

message Criteria {
  bytes expression = 1;
}

message Action {
  string type = 1;
  bytes body = 2;
}

message Result {
  bytes body = 1;
}

message SchemaResult {
  bytes schema = 1;
}

message FlightDescriptor {
  enum DescriptorType {
    UNKNOWN = 0;
    PATH = 1;
    CMD = 2;
  }
  DescriptorType type = 1;
  bytes cmd = 2;
  repeated string path = 3;
}

message FlightInfo {
  bytes schema = 1;
  FlightDescriptor flight_descriptor = 2;
  repeated FlightEndpoint endpoint = 3;
  int64 total_records = 4;
  int64 total_bytes = 5;
  bool ordered = 6;
  bytes app_metadata = 7;
}

message PollInfo {
  FlightInfo info = 1;
  FlightDescriptor flight_descriptor = 2;
  double progress = 3;
  int64 expiration_time = 4;
}

message FlightEndpoint {
  Ticket ticket = 1;
  repeated Location location = 2;
  int64 expiration_time = 3;
  bytes app_metadata = 4;
}

message Location {
  string uri = 1;
}

message Ticket {
  bytes ticket = 1;
}

message FlightData {
  FlightDescriptor flight_descriptor = 1;
  bytes data_header = 2;
  bytes app_metadata = 3;
  bytes data_body = 1000;
}

message PutResult {
  bytes app_metadata = 1;
}
";

        #! FlightDescriptor type constants
        const FLIGHT_DESCRIPTOR_UNKNOWN = 0;
        #! Path-based flight descriptor
        const FLIGHT_DESCRIPTOR_PATH = 1;
        #! Command-based flight descriptor
        const FLIGHT_DESCRIPTOR_CMD = 2;
    }

    private {
        #! Cached schema instance
        static ProtobufSchema m_schema;
        #! Mutex for thread-safe lazy initialization
        static Mutex m_mutex();
    }

    #! Returns the cached Flight protocol ProtobufSchema
    /** Creates the schema on first call and caches it for subsequent use.
        Thread-safe.

        @return the @ref ProtobufSchema for the Arrow Flight protocol
    */
    static ProtobufSchema get() {
        if (m_schema) {
            return m_schema;
        }
        AutoLock al(m_mutex);
        if (!m_schema) {
            m_schema = new ProtobufSchema(FlightProtoDefinition);
        }
        return m_schema;
    }
}

} # namespace Grpc
