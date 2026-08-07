# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubEventsDataProvider.qc Salesforce Pub/Sub events container provider

/*  SalesforcePubSubEventsDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! The Salesforce Pub/Sub events container data provider
/** Attaches to the Salesforce data provider as the \c "pubsub" child and exposes one child event
    provider per subscribable channel.

    @par Channel enumeration
    The Pub/Sub API has no list-topics RPC — \c GetTopic answers only for a topic the caller can
    already name — so the channel list comes from the REST side of the parent provider.
    \c describeGlobal lists Change Data Capture entities (\c "AccountChangeEvent") and platform
    events (\c "My_Event__e"), which is exactly the set of subscribable channels.  Children are
    therefore named by event entity name, and the Pub/Sub topic name is derived from it by
    @ref SalesforcePubSubDataProvider::get_topic_name() "get_topic_name()".

    A custom channel is not listed by \c describeGlobal; subscribe to one by passing its topic
    name as the \c channel option of a child provider.

    @note Enumeration and the Pub/Sub gRPC path are both entirely async: the parent provider holds
    a \c SalesforceRestClientIo rooted at the org's versioned REST API base (see
    \c SalesforceRestClientIo::getApiClient()), so no blocking client is involved anywhere.
*/
public class SalesforcePubSubEventsDataProvider inherits SalesforceRestDataProvider::SalesforceRestDataProviderBase {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "name": PubSubChildName,
            "type": "SalesforcePubSubEventsDataProvider",
            "desc": "Salesforce Pub/Sub API event channels; exposes one child event provider per "
                "platform event and Change Data Capture channel in the org",
            "supports_children": True,
            "children_can_support_apis": False,
            "children_can_support_records": False,
            "children_can_support_observers": True,
            "children_identical": True,
        };

        #! Provider summary info
        static hash<DataProviderSummaryInfo> ProviderSummaryInfo =
            cast<hash<DataProviderSummaryInfo>>(ProviderInfo{
                AbstractDataProvider::DataProviderSummaryInfoKeys
            });
    }

    private {
        #! Pub/Sub client options, passed to each child
        *hash<auto> pubsub_options;
    }

    #! Creates the object from a Salesforce connection
    /** @param conn the Salesforce REST connection
        @param options Pub/Sub client options; see
        @ref SalesforcePubSubDataProvider::SalesforcePubSubClient "SalesforcePubSubClient"
    */
    constructor(SalesforceRestClient::SalesforceRestConnection conn, *hash<auto> options)
            : SalesforceRestDataProviderBase(conn) {
        pubsub_options = options;
    }

    #! Creates the object from an async Salesforce REST client
    /** @param rest the async Salesforce REST client
        @param options Pub/Sub client options
    */
    constructor(SalesforceRestClient::SalesforceRestClientIo rest, *hash<auto> options)
            : SalesforceRestDataProviderBase(rest) {
        pubsub_options = options;
    }

    #! Returns the data provider name
    string getName() {
        return PubSubChildName;
    }

    #! Returns the data provider description
    *string getDesc() {
        return sprintf("Salesforce Pub/Sub API event channels for URL `%s`", rest.getURL());
    }

    #! Returns a list of child data provider names, if any
    /** @return the event entity names of every subscribable channel in the org
    */
    private *list<string> getChildProviderNamesImpl() {
        *list<string> rv = map $1.name, getChannelObjects(), is_pubsub_channel($1.name);
        return rv ? sort(rv) : NOTHING;
    }

    #! Return data provider summary info
    *list<hash<DataProviderSummaryInfo>> getChildProviderSummaryInfo() {
        *list<string> names = getChildProviderNamesImpl();
        if (!names) {
            return;
        }
        return map cast<hash<DataProviderSummaryInfo>>(
            SalesforcePubSubEventDataProvider::ProviderSummaryInfo + {
                "name": $1,
                "desc": SalesforcePubSubEventDataProvider::getChannelDesc($1),
            }), names;
    }

    #! Returns the given child provider or @ref nothing if the given child is unknown
    /** @return the given child provider or @ref nothing if the given child is unknown

        @note The child is created without constructor options; subscription options are read
        from the data provider context in
        @ref SalesforcePubSubDataProvider::SalesforcePubSubEventDataProvider::observersReady()
        "observersReady()".
    */
    private *AbstractDataProvider getChildProviderImpl(string name) {
        if (!is_pubsub_channel(name) && name !~ /^\//) {
            return;
        }
        if (conn) {
            return new SalesforcePubSubEventDataProvider(conn, name, pubsub_options);
        }
        return new SalesforcePubSubEventDataProvider(rest, name, pubsub_options);
    }

    #! Returns data provider static info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }

    #! This provider has no generic API call child
    /** The default implementation finds the inherited \c rest member and has the framework inject
        a \c "__call__" child and a \c make-api-call action.  That belongs on the Salesforce REST
        provider, which already offers it; here it would appear among the event channels, which are
        what this container exists to list.
    */
    private *object getRestClientForGenericCallImpl() {
        return NOTHING;
    }

    #! Returns the \c describeGlobal sobject list
    private *list<auto> getChannelObjects() {
        return rest.get("sobjects").body.sobjects;
    }
}

} # namespace SalesforcePubSubDataProvider
