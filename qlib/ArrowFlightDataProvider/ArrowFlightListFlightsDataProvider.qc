# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightListFlightsDataProvider.qc List available Arrow Flight datasets

/*  ArrowFlightListFlightsDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Contains all public definitions in the ArrowFlightDataProvider module
public namespace ArrowFlightDataProvider {

#! Data provider for listing available Arrow Flight datasets via ListFlights
/** @since ArrowFlightDataProvider 1.0
*/
public class ArrowFlightListFlightsDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightListFlightsDataProvider",
            "supports_request": True,
        };

        #! Response type: list of FlightInfo hashes
        static FlightInfoListResponseDataType ResponseType();

        #! Request type: empty hash
        static HashDataType RequestType("ArrowFlightListFlightsRequest");
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;
    }

    constructor(ArrowFlightClient flight_client) {
        self.flight_client = flight_client;
    }

    string getName() {
        return "list-flights";
    }

    *string getDesc() {
        return "List available Arrow Flight datasets via the ListFlights RPC";
    }

    private *AbstractDataProviderType getRequestTypeImpl() {
        return RequestType;
    }

    private *AbstractDataProviderType getResponseTypeImpl() {
        return new SoftListDataType("FlightInfoList", ResponseType);
    }

    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        return flight_client.listFlights();
    }

    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}

#! Response data type for FlightInfo
public class FlightInfoListResponseDataType inherits HashDataType {
    public {
        const Fields = {
            "flight_descriptor": {
                "display_name": "Flight Descriptor",
                "type": AbstractDataProviderType::get(AutoHashOrNothingType),
                "desc": "The flight descriptor identifying the dataset",
            },
            "schema": {
                "display_name": "Schema",
                "type": AbstractDataProviderType::get(SoftBinaryOrNothingType),
                "desc": "The IPC-serialized Arrow schema for the dataset",
            },
            "total_records": {
                "display_name": "Total Records",
                "type": AbstractDataProviderType::get(SoftIntOrNothingType),
                "desc": "The total number of records in the dataset (-1 if unknown)",
            },
            "total_bytes": {
                "display_name": "Total Bytes",
                "type": AbstractDataProviderType::get(SoftIntOrNothingType),
                "desc": "The total size in bytes (-1 if unknown)",
            },
        };
    }

    constructor() : HashDataType("FlightInfo") {
        addQoreFields(Fields);
    }
}

} # namespace ArrowFlightDataProvider
