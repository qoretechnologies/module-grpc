# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file ArrowFlightListActionsDataProvider.qc List available Arrow Flight server actions

/*  ArrowFlightListActionsDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Data provider for listing available server actions via ListActions
/** @since ArrowFlightDataProvider 1.0
*/
public class ArrowFlightListActionsDataProvider inherits AbstractDataProvider {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "ArrowFlightListActionsDataProvider",
            "supports_request": True,
        };

        #! Response type
        static ActionTypeResponseDataType ResponseType();

        #! Request type: empty hash
        static HashDataType RequestType("ArrowFlightListActionsRequest");
    }

    private {
        #! The Arrow Flight client
        ArrowFlightClient flight_client;
    }

    constructor(ArrowFlightClient flight_client) {
        self.flight_client = flight_client;
    }

    string getName() {
        return "list-actions";
    }

    *string getDesc() {
        return "List available custom actions on the Arrow Flight server via the "
            "ListActions RPC";
    }

    private *AbstractDataProviderType getRequestTypeImpl() {
        return RequestType;
    }

    private *AbstractDataProviderType getResponseTypeImpl() {
        return new SoftListDataType("ActionTypeList", ResponseType);
    }

    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        return flight_client.listActions();
    }

    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}

#! Response data type for ActionType entries
public class ActionTypeResponseDataType inherits HashDataType {
    public {
        const Fields = {
            "type": {
                "display_name": "Action Type",
                "type": AbstractDataProviderType::get(StringType),
                "desc": "The action type identifier string",
            },
            "description": {
                "display_name": "Description",
                "type": AbstractDataProviderType::get(StringOrNothingType),
                "desc": "Human-readable description of the action",
            },
        };
    }

    constructor() : HashDataType("ActionType") {
        addQoreFields(Fields);
    }
}

} # namespace ArrowFlightDataProvider
