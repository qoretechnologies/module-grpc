# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightDefs.qc Arrow Flight data provider constants

/*  ArrowFlightDefs.qc Copyright 2026 Qore Technologies, s.r.o.

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

public namespace ArrowFlightDataProvider {
    #! Event ID for a record batch received from a Flight stream
    public const EVENT_FLIGHT_RECORD_BATCH = "flight-record-batch";

    #! Event ID for Flight stream completion
    public const EVENT_FLIGHT_COMPLETE = "flight-complete";

    #! Event ID for a Flight stream error
    public const EVENT_FLIGHT_ERROR = "flight-error";

    #! Message ID for sending a record batch on a Flight stream
    public const MESSAGE_FLIGHT_SEND_BATCH = "flight-send-batch";

    #! Error data type for Flight events
    public const FlightStreamErrorDataType = new HashDataType("FlightStreamError", {
        "err": {
            "type": AbstractDataProviderType::get(StringType),
            "desc": "The error code",
        },
        "desc": {
            "type": AbstractDataProviderType::get(StringType),
            "desc": "The error description",
        },
    });

    #! Complete data type for Flight events
    public const FlightStreamCompleteDataType = new HashDataType("FlightStreamComplete");
}
