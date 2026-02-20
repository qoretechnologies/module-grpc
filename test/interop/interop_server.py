#!/usr/bin/env python3
"""
Python gRPC server implementing test.TestService for interop testing.

This server implements the same service as test.proto to validate the Qore
gRPC client against a known-good (official Google) gRPC implementation.

Usage:
    python3 interop_server.py <port>

The server prints "READY <port>" to stdout when ready to accept connections.
"""
# Copyright (c) 2026 Qore Technologies, s.r.o.

import sys
import os
from concurrent import futures

import grpc

# Generated proto stubs must be on sys.path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_pb2
import test_pb2_grpc


class TestServiceServicer(test_pb2_grpc.TestServiceServicer):
    """Implements all four RPC patterns for interop testing."""

    def UnaryCall(self, request, context):
        """Echo back 'Hello, <name>' with status 0."""
        return test_pb2.SimpleResponse(
            message="Hello, " + request.name,
            status=0,
        )

    def ServerStream(self, request, context):
        """Stream back 3 messages."""
        for i in range(3):
            yield test_pb2.SimpleResponse(
                message="msg %d for %s" % (i, request.name),
                status=i,
            )

    def ClientStream(self, request_iterator, context):
        """Aggregate client messages and return combined response."""
        names = []
        for request in request_iterator:
            names.append(request.name)
        return test_pb2.SimpleResponse(
            message=", ".join(names),
            status=len(names),
        )

    def BidiStream(self, request_iterator, context):
        """Echo each message back with 'echo: ' prefix."""
        for request in request_iterator:
            yield test_pb2.SimpleResponse(
                message="echo: " + request.name,
                status=request.id,
            )


def serve(port):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    test_pb2_grpc.add_TestServiceServicer_to_server(TestServiceServicer(), server)
    actual_port = server.add_insecure_port("localhost:%d" % port)
    server.start()
    # Signal readiness to parent process
    print("READY %d" % actual_port, flush=True)
    server.wait_for_termination()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    serve(port)
