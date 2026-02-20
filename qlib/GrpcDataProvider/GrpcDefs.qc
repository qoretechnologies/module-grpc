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
    #! gRPC logo in SVG format for the action catalog
    public const GrpcLogo = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 512 512\">"
        "<path fill=\"#244c5a\" d=\"M256 48C141.1 48 48 141.1 48 256s93.1 208 208 208 208-93.1 "
        "208-208S370.9 48 256 48zm115.7 327.7c-31.1 31.1-72.4 48.3-116.3 48.3-43.9 "
        "0-85.2-17.2-116.3-48.3C108 344.6 90.8 303.3 90.8 259.4c0-43.9 17.2-85.2 "
        "48.3-116.3 31.1-31.1 72.4-48.3 116.3-48.3s85.2 17.2 116.3 48.3c31.1 31.1 "
        "48.3 72.4 48.3 116.3-.1 43.9-17.2 85.2-48.3 116.3z\"/>"
        "<path fill=\"#244c5a\" d=\"M256 120c-75 0-136 61-136 136s61 136 136 136 136-61 "
        "136-136-61-136-136-136zm0 240c-57.3 0-104-46.7-104-104S198.7 152 256 152s104 "
        "46.7 104 104-46.7 104-104 104z\"/></svg>";

    #! MIME type for SVG images
    public const MimeTypeSvg = "image/svg+xml";

    #! Event ID: a message received from a gRPC server stream
    public const EVENT_GRPC_STREAM_MESSAGE = "grpc-stream-message";

    #! Event ID: a gRPC server stream completed successfully
    public const EVENT_GRPC_STREAM_COMPLETE = "grpc-stream-complete";

    #! Event ID: a gRPC server stream error occurred
    public const EVENT_GRPC_STREAM_ERROR = "grpc-stream-error";

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
