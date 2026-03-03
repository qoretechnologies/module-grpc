# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcDefs.qc GrpcDataProvider constants and definitions

/*  GrpcDefs.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Contains all public definitions in the GrpcDataProvider module
public namespace GrpcDataProvider {
    #! MIME type for SVG images
    public const MimeTypeSvg = "image/svg+xml";

    #! Event ID: a message received from a gRPC server stream
    public const EVENT_GRPC_STREAM_MESSAGE = "grpc-stream-message";

    #! Event ID: a gRPC server stream completed successfully
    public const EVENT_GRPC_STREAM_COMPLETE = "grpc-stream-complete";

    #! Event ID: a gRPC server stream error occurred
    public const EVENT_GRPC_STREAM_ERROR = "grpc-stream-error";

    #! Message ID: send a message on a bidirectional gRPC stream
    public const MESSAGE_GRPC_STREAM_SEND = "grpc-stream-send";

    #! Data type for stream error events
    public const GrpcStreamErrorDataType = new HashDataType("GrpcStreamError", {
        "err": {
            "type": AbstractDataProviderType::get(StringType),
            "desc": "The error code or gRPC status code",
        },
        "desc": {
            "type": AbstractDataProviderType::get(StringType),
            "desc": "The error description or gRPC status message",
        },
    });

    #! Data type for stream complete events
    public const GrpcStreamCompleteDataType = new HashDataType("GrpcStreamComplete");
}
