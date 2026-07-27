# Qore grpc Module

## Introduction

The `grpc` module provides gRPC client/server and protobuf support for Qore, including:

- Dynamic protobuf schema loading from `.proto` files (no code generation needed)
- Binary protobuf encoding/decoding via `ProtobufSchema`
- gRPC client with all four call patterns (unary, server streaming, client streaming, bidirectional)
- gRPC server with handler registration and async I/O
- TLS/SSL support on client and server
- Custom metadata passing (request, initial response, trailing)
- Timeout/deadline enforcement
- Connection pooling via `HttpClientConnectionManager`
- Built-in gRPC server reflection (`GrpcReflectionService`) for client service discovery

## Architecture

The module has two layers:

- **Binary module (`grpc.so`)**: C++ QPP wrapping `libprotobuf` for schema loading and message encoding/decoding. Only dependency is `libprotobuf` (no libgrpc++).
- **Qore module (`GrpcUtil`)**: Pure Qore implementing the gRPC protocol natively on Qore's HTTP/2 stack.

Three data provider modules are built on top of it:

| Module | What |
|---|---|
| `GrpcDataProvider` | any gRPC service as a data provider, with reflection-based discovery |
| `ArrowFlightDataProvider` | Apache Arrow Flight columnar data exchange |
| `SalesforcePubSubDataProvider` | Salesforce Pub/Sub API event source (gRPC + Avro) |

`SalesforcePubSubDataProvider` attaches itself to the Salesforce data provider in the Qore library
as its `pubsub` child, so an existing `sfrest` connection gains platform event, Change Data Capture
and custom channel event sources with no new connection type. See
[`design/salesforce-pubsub.md`](design/salesforce-pubsub.md).

## Requirements

- Qore 2.0+ (with HTTP/2 trailer support)
- CMake 3.5+
- C++17 compiler
- `libprotobuf` (protobuf development libraries)
  - Ubuntu/Debian: `libprotobuf-dev`
  - Alpine: `protobuf-dev`
  - Fedora: `protobuf-devel`

## Building

```bash
mkdir build && cd build
cmake ..
make
make install
```

## Quick Start

### Unary Call

```qore
#!/usr/bin/env qore

%modern
%requires grpc
%requires GrpcUtil

ProtobufSchema schema("./proto/", "service.proto");
GrpcChannel channel("http://localhost:50051");
GrpcClient client(channel, schema, "MyService");

hash<GrpcCallResult> result = client.call("SayHello", {"name": "World"});
printf("Response: %y\n", result.body);
printf("Status: %d %s\n", result.status_code, result.status_message);

channel.shutdown();
```

### Server

```qore
ProtobufSchema schema("./proto/", "service.proto");
GrpcServer server(schema);

server.registerHandler("MyService", "SayHello",
    hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
        return {"message": "Hello, " + request.name, "status": 0};
    });

int port = server.addInsecurePort("localhost:0");
server.start();
server.wait();
```

### Server Streaming

```qore
# Client
GrpcClientStream stream = client.serverStream("ListItems", {"category": "books"});
while (*hash<auto> item = stream.read(5s)) {
    printf("Item: %y\n", item);
}
hash<GrpcCallResult> result = stream.finish();

# Server handler
server.registerHandler("MyService", "ListItems",
    sub(hash<auto> request, GrpcServerStream stream, hash<string, string> metadata) {
        for (int i = 0; i < 10; ++i) {
            stream.write({"name": sprintf("item-%d", i)});
        }
    });
```

### Client Streaming

```qore
# Client
GrpcClientStream stream = client.clientStream("Upload");
stream.write({"chunk": "data1"});
stream.write({"chunk": "data2"});
hash<GrpcCallResult> result = stream.finish();

# Server handler
server.registerHandler("MyService", "Upload",
    hash<auto> sub(GrpcServerStream stream, hash<string, string> metadata) {
        int count = 0;
        while (*hash<auto> msg = stream.read()) {
            ++count;
        }
        return {"total": count};
    });
```

### Bidirectional Streaming

The server handler processes messages incrementally -- no pre-buffering of the
client stream. Both sides can interleave reads and writes for interactive
communication:

```qore
# Client - interactive request/response
GrpcClientStream stream = client.bidiStream("Chat");
stream.write({"text": "Hello"});
*hash<auto> reply = stream.read(5s);   # response arrives before next send
printf("Reply: %s\n", reply.text);

stream.write({"text": "World"});
reply = stream.read(5s);
printf("Reply: %s\n", reply.text);

stream.writesDone();
hash<GrpcCallResult> result = stream.finish();

# Server handler - echo each message immediately
server.registerHandler("MyService", "Chat",
    sub(GrpcServerStream stream, hash<string, string> metadata) {
        while (*hash<auto> msg = stream.read()) {
            stream.write({"text": "Echo: " + msg.text});
        }
    });
```

### TLS

```qore
# Server with TLS
string cert = ReadOnlyFile::readTextFile("server.crt");
string key = ReadOnlyFile::readTextFile("server.key");
int port = server.addSecurePort("localhost:0", <GrpcSslOptions>{
    "server_cert": cert,
    "server_key": key,
});

# Client with HTTPS
GrpcChannel channel("https://localhost:50051");
```

### Metadata and Timeouts

```qore
# Send metadata and set timeout
hash<GrpcCallOptions> opts = <GrpcCallOptions>{
    "timeout_ms": 5000,
    "metadata": {"x-request-id": "abc-123"},
};
hash<GrpcCallResult> result = client.call("Method", request, opts);

# Server receives metadata in handler
server.registerHandler("Service", "Method",
    hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
        string req_id = metadata."x-request-id";
        return {"id": req_id};
    });

# Streaming handlers can set trailing metadata
server.registerHandler("Service", "Stream",
    sub(hash<auto> request, GrpcServerStream stream, hash<string, string> metadata) {
        stream.setTrailingMetadata({"x-count": "5"});
        # ... write messages ...
    });
```

### Server Reflection

Enable clients to discover services without local `.proto` files using the standard
gRPC server reflection protocol (`grpc.reflection.v1`). This works with tools like
`grpcurl` and `grpc_cli` as well as programmatic clients.

#### Server Setup

Just pass `enable_reflection: True` in the server options:

```qore
%modern
%requires grpc
%requires GrpcUtil

ProtobufSchema schema("./proto/", "service.proto");
GrpcServer server(schema, <GrpcServerOptions>{"enable_reflection": True});

server.registerHandler("MyService", "MyMethod",
    hash<auto> sub(hash<auto> request, hash<string, string> metadata) {
        return {"result": "ok"};
    });

server.addInsecurePort("localhost:50051");
server.start();
server.wait();
```

#### Client Discovery with grpcurl

```bash
# List all services exposed by the server
grpcurl -plaintext localhost:50051 list

# Describe a specific service
grpcurl -plaintext localhost:50051 describe mypackage.MyService

# Make a call without needing the .proto file
grpcurl -plaintext -d '{"name": "World"}' localhost:50051 mypackage.MyService/MyMethod
```

#### Programmatic Discovery

```qore
%modern
%requires grpc
%requires GrpcUtil

GrpcChannel channel("http://localhost:50051");

# Discover services and schema via reflection
GrpcReflectionClient rc(channel);
list<string> services = rc.listServices();
printf("Available services: %y\n", services);

# Build a schema from the server's descriptors and make calls
ProtobufSchema discovered = rc.discoverSchema();
GrpcClient client(channel, discovered, "MyService");
hash<GrpcCallResult> result = client.call("MyMethod", {"name": "World"});
printf("Response: %y\n", result.body);

channel.shutdown();
```

#### Data Provider with Reflection

The `GrpcDataProvider` module can use reflection for zero-configuration service access:

```qore
%modern
%requires GrpcDataProvider

GrpcDataProvider provider({
    "url": "http://localhost:50051",
    "use_reflection": True,
});

# Services are discovered automatically
auto result = provider.getChildProvider("MyService")
    .getChildProvider("MyMethod")
    .doRequest({"name": "World"});
```

Or from the command line:

```bash
qdp 'grpc{url=http://localhost:50051,use_reflection=true}/MyService/MyMethod' dor name=World
```

### Standalone Protobuf

```qore
%requires grpc

ProtobufSchema schema("./proto/", "messages.proto");
binary data = schema.encode("MyMessage", {"field": "value"});
hash<auto> msg = schema.decode("MyMessage", data);

# JSON conversion
string json = schema.toJson("MyMessage", {"field": "value"});
hash<auto> parsed = schema.fromJson("MyMessage", json);
```

## Data Provider Integration

The `GrpcDataProvider` module integrates gRPC with Qore's data provider framework, enabling
`qdp` CLI access and Qorus workflow integration.

### Unary Call via `qdp`

```bash
# Using a proto file
qdp 'grpc{url=http://localhost:50051,proto_path=./proto,proto_file=service.proto}/MyService/SayHello' dor name=World

# Using server reflection (no proto files needed)
qdp 'grpc{url=http://localhost:50051,use_reflection=true}/MyService/SayHello' dor name=World
```

### Observable Server Streaming

Server-streaming methods expose an `events` child provider for event-driven consumption:

```bash
qdp 'grpc{url=http://localhost:50051,use_reflection=true}/PriceService/WatchPrices/events' listen
```

### Interactive Bidirectional Streaming

Bidirectional-streaming methods also expose an `events` child that supports both
receiving events and sending messages, enabling interactive use with `qdp ix`:

```bash
qdp 'grpc{url=http://localhost:50051,use_reflection=true}/ChatService/Chat/events' ix
```

Programmatic usage:

```qore
%modern
%requires GrpcDataProvider

GrpcDataProvider provider({
    "url": "http://localhost:50051",
    "use_reflection": True,
});

# Navigate to the events child of a bidi method
AbstractDataProvider events = provider.getChildProvider("ChatService")
    .getChildProvider("Chat")
    .getChildProvider("events");

# Register observer and start the stream
events.registerObserver(my_observer);
events.observersReady();

# Send messages
events.sendMessage(MESSAGE_GRPC_STREAM_SEND, {"text": "hello"});
events.sendMessage(MESSAGE_GRPC_STREAM_SEND, {"text": "world"});

# Signal writes done (server will finish and close the stream)
events.stopEvents();
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Copyright

Copyright 2026 Qore Technologies, s.r.o.
