# Qore grpc Module

## Introduction

The `grpc` module provides gRPC client/server and protobuf support for Qore, including:

- Dynamic protobuf schema loading from `.proto` files (no code generation needed)
- Binary protobuf encoding/decoding via `ProtobufSchema`
- gRPC client with all four call patterns (unary, server streaming, client streaming, bidirectional)
- gRPC server with async I/O
- Built natively on Qore's HTTP/2 infrastructure (no libgrpc++ dependency)
- Connection pooling via `Http2ClientConnectionManager`

## Architecture

The module has two layers:

- **Binary module (`grpc.so`)**: C++ QPP wrapping `libprotobuf` for schema loading and message encoding/decoding
- **Qore module (`Grpc`)**: Pure Qore implementing the gRPC protocol on top of Qore's HTTP/2 stack

## Requirements

- Qore 2.0+ (with HTTP/2 trailer support)
- CMake 3.5+
- C++17 compiler
- `libprotobuf` (protobuf development libraries)
- No libgrpc++ dependency

## Building

```bash
mkdir build
cd build
cmake ..
make
make install
```

## Quick Start

```qore
#!/usr/bin/env qore

%modern
%requires grpc
%requires Grpc

# Load a .proto schema
ProtobufSchema schema("./", "service.proto");

# Create a channel and client
GrpcChannel channel("localhost:50051");
GrpcClient client(channel, schema, "MyService");

# Make a unary call
hash<GrpcCallResult> result = client.call("MyMethod", {"name": "world"});
printf("Response: %y\n", result.body);
printf("Status: %d %s\n", result.status_code, result.status_message);
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Copyright

Copyright 2026 Qore Technologies, s.r.o.
