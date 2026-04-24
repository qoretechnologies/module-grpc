# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcServer.qc gRPC server — alias for GrpcServerAsync

/*  GrpcServer.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! gRPC server supporting unary and streaming RPC calls
/** As of the %GrpcUtil async migration, @ref GrpcServer is a thin alias for
    @ref GrpcServerAsync — the async-only implementation built on top of
    @ref HttpServerAsyncIo.  All request dispatch runs through
    @ref AsyncSocketIo::AsyncHttp2ServerStream "AsyncHttp2ServerStream" and
    the @c *Async Socket methods; no handler thread holds the socket wrapper
    lock while performing HTTP/2 I/O.  See @c qore/design/grpc-server-async-migration.md
    for the full migration history.

    The legacy sync connection-loop implementation has been removed from this
    class; user-facing behavior is unchanged.

    @par Example:
    @code{.py}
ProtobufSchema schema(proto_dir, "service.proto");
GrpcServer server(schema);
server.registerHandler("MyService", "SayHello", sub(hash<auto> request, hash<string, string> metadata) {
    return {"message": "Hello, " + request.name, "status": 0};
});
int port = server.addInsecurePort("localhost:0");
server.start();
# ... server is running ...
server.shutdown();
    @endcode

    @par Example (with reflection enabled):
    @code{.py}
ProtobufSchema schema(proto_dir, "service.proto");
GrpcServer server(schema, <GrpcServerOptions>{"enable_reflection": True});
server.registerHandler("MyService", "SayHello",
    hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
        return {"message": "Hello, " + request.name};
    });
server.addInsecurePort("localhost:50051");
server.start();
# Clients can now discover services via grpcurl or GrpcReflectionClient
    @endcode

    @par Example (server-streaming):
    @code{.py}
server.registerHandler("MyService", "Feed",
    sub(hash<auto> request, GrpcServerStream stream, hash<string, string> metadata) {
        for (int i = 0; i < 5; ++i) {
            stream.write({"message": sprintf("msg %d", i), "status": i});
        }
    });
    @endcode

    @par Example (bidirectional streaming — interactive):
    @code{.py}
server.registerHandler("MyService", "Chat",
    sub(GrpcServerStream stream, hash<string, string> metadata) {
        while (*hash<auto> msg = stream.read(60s)) {
            stream.write({"message": "Echo: " + msg.text, "status": 0});
        }
    });
    @endcode
*/
public class GrpcServer inherits GrpcServerAsync {
    #! Create a gRPC server
    /** @param schema the protobuf schema containing service definitions
        @param opts optional server options
    */
    constructor(ProtobufSchema schema, *hash<GrpcServerOptions> opts)
            : GrpcServerAsync(schema, opts) {
    }
}

} # namespace Grpc
