# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightDoActionDataProvider.qc Execute a custom Arrow Flight action

/*  ArrowFlightDoActionDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Data provider for executing custom Arrow Flight actions via DoAction
/** @since ArrowFlightDataProvider 1.0
*/
public class ArrowFlightDoActionDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightDoActionDataProvider",
            "supports_request": True,
        };

        #! Request type
        static DoActionRequestDataType RequestType();

        #! Response type
        static DoActionResponseDataType ResponseType();
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;
    }

    constructor(ArrowFlightClient flight_client) {
        self.flight_client = flight_client;
    }

    string getName() {
        return "do-action";
    }

    *string getDesc() {
        return "Execute a custom action on the Arrow Flight server via the DoAction RPC";
    }

    private *AbstractDataProviderType getRequestTypeImpl() {
        return RequestType;
    }

    private *AbstractDataProviderType getResponseTypeImpl() {
        return new SoftListDataType("DoActionResultList", ResponseType);
    }

    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        return flight_client.doAction({
            "type": req.action_type,
            "body": req.body ?? binary(),
        });
    }

    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}

#! Request data type for DoAction
public class DoActionRequestDataType inherits HashDataType {
    public {
        const Fields = {
            "action_type": {
                "display_name": "Action Type",
                "short_desc": "The action type to execute",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "The action type string identifying the server-side action to execute",
                "required": True,
                "example_value": "health_check",
            },
            "body": {
                "display_name": "Body",
                "short_desc": "Optional binary body for the action",
                "type": AbstractDataProviderType::get(SoftBinaryOrNothingType),
                "desc": "Optional binary payload to send with the action request",
            },
        };
    }

    constructor() : HashDataType("DoActionRequest") {
        addQoreFields(Fields);
    }
}

#! Response data type for DoAction results
public class DoActionResponseDataType inherits HashDataType {
    public {
        const Fields = {
            "body": {
                "display_name": "Body",
                "short_desc": "Binary result body from the action",
                "type": AbstractDataProviderType::get(SoftBinaryOrNothingType),
                "desc": "The binary result body from the action",
            },
        };
    }

    constructor() : HashDataType("DoActionResult") {
        addQoreFields(Fields);
    }
}

} # namespace ArrowFlightDataProvider
