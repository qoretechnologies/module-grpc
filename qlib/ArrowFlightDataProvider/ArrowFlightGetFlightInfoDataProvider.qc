# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightGetFlightInfoDataProvider.qc Get metadata for an Arrow Flight dataset

/*  ArrowFlightGetFlightInfoDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Data provider for getting Arrow Flight dataset metadata via GetFlightInfo
/** @since ArrowFlightDataProvider 1.0
*/
public class ArrowFlightGetFlightInfoDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightGetFlightInfoDataProvider",
            "supports_request": True,
        };

        #! Request type
        static GetFlightInfoRequestDataType RequestType();
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;
    }

    constructor(ArrowFlightClient flight_client) {
        self.flight_client = flight_client;
    }

    string getName() {
        return "get-flight-info";
    }

    *string getDesc() {
        return "Get metadata for an Arrow Flight dataset via the GetFlightInfo RPC";
    }

    private *AbstractDataProviderType getRequestTypeImpl() {
        return RequestType;
    }

    private *AbstractDataProviderType getResponseTypeImpl() {
        return new FlightInfoListResponseDataType();
    }

    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        hash<auto> descriptor = ArrowFlightHelper::pathDescriptor(req.dataset);
        return flight_client.getFlightInfo(descriptor);
    }

    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}

#! Request data type for GetFlightInfo
public class GetFlightInfoRequestDataType inherits HashDataType {
    public {
        const Fields = {
            "dataset": {
                "display_name": "Dataset",
                "short_desc": "The dataset name to get info for",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "The Arrow Flight dataset name as registered on the server",
                "required": True,
                "example_value": "my-dataset",
            },
        };
    }

    constructor() : HashDataType("GetFlightInfoRequest") {
        addQoreFields(Fields);
    }
}

} # namespace ArrowFlightDataProvider
