# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubEnableCdcDataProvider.qc Change Data Capture enablement request provider

/*  SalesforcePubSubEnableCdcDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Contains all public definitions in the SalesforcePubSubDataProvider module
public namespace SalesforcePubSubDataProvider {

#! Enables Change Data Capture for a Salesforce object, as an explicit action
/** Change Data Capture must be switched on per entity before a subscription delivers anything,
    and a subscription to an entity that was never enabled succeeds and then stays silent.  This
    provider makes enabling an explicit, auditable step that a flow can perform once, rather than
    something a subscription does to the org behind the user's back.

    @par Example
    @code{.py}
AbstractDataProvider p = conn.getDataProvider().getChildProviderEx("enable-change-data-capture");
hash<auto> h = p.doRequest({"entity": "CaseChangeEvent"});
printf("enabled: %y (already: %y)\n", h.entity, h.already_enabled);
    @endcode

    @since %SalesforcePubSubDataProvider 1.0
*/
public class SalesforcePubSubEnableCdcDataProvider inherits
        SalesforceRestDataProvider::SalesforceRestDataProviderBase {
    public {
        #! The child name under the Salesforce data provider
        const ProviderName = "enable-change-data-capture";

        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "name": ProviderName,
            "type": "SalesforcePubSubEnableCdcDataProvider",
            "desc": "Enables Salesforce Change Data Capture for an object, so that its change "
                "events can be subscribed to",
            "supports_request": True,
            "supports_children": False,
            "children_can_support_apis": False,
            "children_can_support_records": False,
            "children_can_support_observers": False,
        };

        #! Provider summary info
        static hash<DataProviderSummaryInfo> ProviderSummaryInfo =
            cast<hash<DataProviderSummaryInfo>>(ProviderInfo{
                AbstractDataProvider::DataProviderSummaryInfoKeys
            });
    }

    #! Creates the object from a Salesforce connection
    constructor(SalesforceRestClient::SalesforceRestConnection conn)
            : SalesforceRestDataProviderBase(conn) {
    }

    #! Creates the object from an async Salesforce REST client
    constructor(SalesforceRestClient::SalesforceRestClientIo rest)
            : SalesforceRestDataProviderBase(rest) {
    }

    #! Returns the data provider name
    string getName() {
        return ProviderName;
    }

    #! Returns the data provider description
    *string getDesc() {
        return "Enables Salesforce **Change Data Capture** for an object, so that its change "
            "events can be subscribed to through the Pub/Sub API";
    }

    #! Enables Change Data Capture for the requested entity
    private auto doRequestImpl(auto req, *hash<auto> request_options) {
        return SalesforcePubSubCdc::enable(getApiRest(), req.entity);
    }

    private *DataProvider::AbstractDataProviderType getRequestTypeImpl() {
        return SalesforceEnableCdcRequestType;
    }

    private *DataProvider::AbstractDataProviderType getResponseTypeImpl() {
        return SalesforceEnableCdcResponseType;
    }

    #! This provider is not itself a REST endpoint
    private *object getRestClientForGenericCallImpl() {
        return NOTHING;
    }

    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }
}
}
