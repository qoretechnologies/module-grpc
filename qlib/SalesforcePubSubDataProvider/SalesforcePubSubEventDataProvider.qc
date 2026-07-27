# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubEventDataProvider.qc Salesforce Pub/Sub per-channel event provider

/*  SalesforcePubSubEventDataProvider.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Observable data provider for a single Salesforce Pub/Sub channel
/** Raises @ref EVENT_SALESFORCE_PUBSUB_EVENT for each event received on the channel and
    @ref EVENT_SALESFORCE_PUBSUB_ERROR if the subscription gives up.

    The subscription is opened by @ref observersReady() and by nothing earlier, so a provider that
    is merely introspected in a UI does not consume a Salesforce subscription slot.  Introspection
    still reports real field names, because the event type is derived from the channel's Avro
    schema, which is fetched with the unary \c GetTopic and \c GetSchema calls rather than by
    subscribing.

    Options are read from the data provider context in @ref observersReady() rather than passed to
    the constructor, because event providers are reached by path navigation.

    @par Example
    @code{.py}
AbstractDataProvider events = conn.getDataProvider().getChildProviderEx("pubsub")
    .getChildProviderEx("AccountChangeEvent");
cast<Observable>(events).registerObserver(my_observer);
cast<DelayedObservable>(events).observersReady();
    @endcode
*/
public class SalesforcePubSubEventDataProvider inherits
        SalesforceRestDataProvider::SalesforceRestDataProviderBase, DataProvider::DelayedObservable {
    public {
        #! Provider info
        const ProviderInfo = <DataProviderInfo>{
            "type": "SalesforcePubSubEventDataProvider",
            "desc": "Observable data provider for a single Salesforce Pub/Sub event channel",
            "supports_observable": True,
        };

        #! Provider summary info
        static hash<DataProviderSummaryInfo> ProviderSummaryInfo =
            cast<hash<DataProviderSummaryInfo>>(ProviderInfo{
                AbstractDataProvider::DataProviderSummaryInfoKeys
            });

        #! Subscription options read from the data provider context
        /** All types are optional, because an event provider is created by path navigation
            without constructor options.
        */
        const LocalOptions = {
            "topic_name": <DataProviderOptionInfo>{
                "display_name": "Topic Name",
                "short_desc": "The Pub/Sub topic name to subscribe to",
                "type": AbstractDataProviderTypeMap."*string",
                "desc": "The Pub/Sub topic name, overriding the one derived from this provider's "
                    "name.  Set this to subscribe to a **custom channel**, which "
                    "`describeGlobal` does not list; for example `/event/MyChannel__chn`",
                "example_value": "/data/AccountChangeEvent",
            },
            "replay_preset": <DataProviderOptionInfo>{
                "display_name": "Replay Preset",
                "short_desc": "Where in the event stream the subscription starts",
                "type": AbstractDataProviderTypeMap."*string",
                "desc": "Where the subscription starts: `LATEST` (the tip of the stream, the "
                    "default), `EARLIEST` (the oldest retained event), or `CUSTOM` (after the "
                    "event identified by `replay_id`).\n\n"
                    "Salesforce retains replay IDs for **72 hours**",
                "allowed_values": (
                    <AllowedValueInfo>{
                        "value": ReplayLatest,
                        "display_name": "Latest",
                        "desc": "Start at the tip of the stream; only events published after the "
                            "subscription starts are delivered",
                    },
                    <AllowedValueInfo>{
                        "value": ReplayEarliest,
                        "display_name": "Earliest",
                        "desc": "Start at the oldest event still retained in the stream",
                    },
                    <AllowedValueInfo>{
                        "value": ReplayCustom,
                        "display_name": "Custom",
                        "desc": "Start immediately after the event identified by `replay_id`",
                    },
                ),
                "default_value": ReplayLatest,
            },
            "replay_id": <DataProviderOptionInfo>{
                "display_name": "Replay ID",
                "short_desc": "The base64 replay ID to resume after",
                "type": AbstractDataProviderTypeMap."*string",
                "desc": "The base64-encoded replay ID to resume after, as reported in the "
                    "`event.replayId` field of a delivered event.  Implies the `CUSTOM` replay "
                    "preset",
            },
            "num_requested": <DataProviderOptionInfo>{
                "display_name": "Flow Control Window",
                "short_desc": "How many events the client keeps requested",
                "type": AbstractDataProviderTypeMap."*int",
                "desc": "How many events the client keeps requested from the server at a time; "
                    "between 1 and 100, which is the maximum the Pub/Sub API accepts in a single "
                    "`FetchRequest`",
                "default_value": DefaultNumRequested,
            },
        };
    }

    private {
        #! The channel name this provider was created for
        string channel_name;

        #! Pub/Sub client options
        *hash<auto> pubsub_options;

        #! The topic name resolved from the channel name or the \c channel option
        *string topic_name;

        #! The Pub/Sub client, created on first use
        *SalesforcePubSubClient pubsub;

        #! The active subscription
        *SalesforcePubSubSubscription subscription;

        #! The cached event type derived from the channel's Avro schema
        *AbstractDataProviderType payload_type;

        #! True once the channel's Avro schema has been looked up, successfully or not
        bool payload_type_resolved = False;

        #! State lock
        Mutex m();
    }

    #! Creates the object from a Salesforce connection
    /** @param conn the Salesforce REST connection
        @param channel_name the channel name; an event entity name or a topic name
        @param options Pub/Sub client options
    */
    constructor(SalesforceRestClient::SalesforceRestConnection conn, string channel_name,
            *hash<auto> options) : SalesforceRestDataProviderBase(conn) {
        self.channel_name = channel_name;
        pubsub_options = options;
    }

    #! Creates the object from a Salesforce REST client
    /** A provider created this way can report its event type but cannot open a subscription: the
        Pub/Sub call metadata requires an async REST client, which only the connection can supply.

        @param rest the Salesforce REST client
        @param channel_name the channel name; an event entity name or a topic name
        @param options Pub/Sub client options
    */
    constructor(SalesforceRestClient::SalesforceRestClient rest, string channel_name,
            *hash<auto> options) : SalesforceRestDataProviderBase(rest) {
        self.channel_name = channel_name;
        pubsub_options = options;
    }

    #! Stops the subscription and deletes the object
    destructor() {
        stopEvents();
    }

    #! Returns the data provider name
    string getName() {
        return channel_name;
    }

    #! Returns the data provider description
    *string getDesc() {
        return SalesforcePubSubEventDataProvider::getChannelDesc(channel_name);
    }

    #! Returns a description for the given channel name
    /** @param channel_name the channel name

        @return a human-readable description
    */
    static string getChannelDesc(string channel_name) {
        string kind = channel_name =~ /ChangeEvent$/
            ? "Change Data Capture"
            : (channel_name =~ /__e$/ ? "platform event" : "custom");
        return sprintf("Salesforce Pub/Sub %s channel `%s`; raises an event for each message "
            "received", kind, channel_name);
    }

    #! Returns the resolved Pub/Sub topic name for this provider
    /** @return the topic name

        @throw SALESFORCE-PUBSUB-CHANNEL-ERROR the channel name cannot be mapped to a topic name
    */
    string getTopicName() {
        AutoLock al(m);
        return topic_name ?? get_topic_name(channel_name);
    }

    #! Returns the active subscription, if any
    /** @return the subscription, or @ref nothing if @ref observersReady() has not been called or
        the subscription has been stopped
    */
    *SalesforcePubSubSubscription getSubscription() {
        AutoLock al(m);
        return subscription;
    }

    #! Called when all observers have been added; opens the Pub/Sub subscription
    /** Subscription options are read from the data provider context here, since an event provider
        is created by path navigation without constructor options.

        @throw SALESFORCE-PUBSUB-ERROR the subscription is already open, or the provider was not
        created from a connection
    */
    observersReady() {
        {
            AutoLock al(m);
            if (subscription) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("a subscription to channel %y is "
                    "already open", channel_name);
            }
        }

        *hash<auto> ctx = DataProvider::DataProviderDataContextHelper::getHash();
        *hash<auto> copts = checkOptions("SALESFORCE-PUBSUB-OPTION-ERROR", LocalOptions,
            ctx{keys LocalOptions});

        string topic = copts.topic_name.val() ? copts.topic_name : get_topic_name(channel_name);
        # hash<auto!> rather than hash<auto>: the latter narrows its value type from the callbacks
        # below, so adding a string or int option to it would be a runtime error
        hash<auto!> sub_opts = {
            "on_event": \eventReceived(),
            "on_failure": \subscriptionFailed(),
        };
        if (copts.replay_preset.val()) {
            sub_opts.replay_preset = copts.replay_preset;
        }
        if (copts.replay_id.val()) {
            sub_opts.replay_id = copts.replay_id;
        }
        if (exists copts.num_requested) {
            sub_opts.num_requested = copts.num_requested;
        }

        SalesforcePubSubSubscription subscr = getPubSubClient().subscribe(topic, sub_opts);
        {
            AutoLock al(m);
            topic_name = topic;
            subscription = subscr;
        }
        try {
            subscr.start();
        } catch (hash<ExceptionInfo> ex) {
            AutoLock al(m);
            remove subscription;
            rethrow;
        }
    }

    #! Called to stop event generation; closes the subscription
    stopEvents() {
        *SalesforcePubSubSubscription subscr;
        {
            AutoLock al(m);
            subscr = subscription;
            remove subscription;
        }
        if (subscr) {
            subscr.stop();
        }
    }

    #! Returns the Pub/Sub client, creating it on first use
    /** @return the Pub/Sub client

        @throw SALESFORCE-PUBSUB-ERROR the provider was not created from a connection, so no async
        REST client is available for the call metadata
    */
    SalesforcePubSubClient getPubSubClient() {
        AutoLock al(m);
        if (!pubsub) {
            if (!conn) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("cannot subscribe to Pub/Sub channel "
                    "%y: this provider was created from a Salesforce REST client rather than a "
                    "connection, and the Pub/Sub call metadata requires the connection's async "
                    "REST client", channel_name);
            }
            pubsub = new SalesforcePubSubClient(conn, pubsub_options);
        }
        return pubsub;
    }

    #! Returns data provider static info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return ProviderInfo;
    }

    #! This provider has no generic API call child
    /** The default implementation finds the inherited \c rest member and has the framework inject
        a \c "__call__" child; an event provider has no children and is not a REST endpoint.
    */
    private *object getRestClientForGenericCallImpl() {
        return NOTHING;
    }

    #! Returns the event types raised by this provider
    private hash<string, hash<DataProviderMessageInfo>> getEventTypesImpl() {
        return {
            EVENT_SALESFORCE_PUBSUB_EVENT: <DataProviderMessageInfo>{
                "desc": sprintf("An event received on Salesforce Pub/Sub channel `%s`",
                    channel_name),
                "type": getEventType(),
            },
            EVENT_SALESFORCE_PUBSUB_ERROR: <DataProviderMessageInfo>{
                "desc": "The subscription failed and could not be re-established",
                "type": SalesforcePubSubErrorType,
            },
        };
    }

    #! Returns example data for the given event
    /** @param event_id the event ID

        @return example data for the event
    */
    private auto getExampleEventDataImpl(string event_id) {
        switch (event_id) {
            case EVENT_SALESFORCE_PUBSUB_ERROR:
                return {
                    "err": "SALESFORCE-PUBSUB-GRPC-STATUS-16",
                    "desc": "the access token is no longer valid",
                };

            case EVENT_SALESFORCE_PUBSUB_EVENT: {
                # real API data first: when the org can be reached, the payload type comes from the
                # channel's own Avro schema and the generated example carries its real field names
                try {
                    if (exists resolvePayloadTypeIfAvailable()) {
                        return getEventType().getExampleValue();
                    }
                } catch (hash<ExceptionInfo> ex) {
                    # fall through to channel-specific example data
                }
                # otherwise fall back to data specific to this kind of channel, not a generic stub
                return {
                    "channel": getTopicNameSafe(),
                    "event": {
                        "replayId": "AAAAAAAAAAEAAA==",
                        "id": "f7a1b0c2-3d4e-4f56-8a90-1b2c3d4e5f60",
                        "schemaId": "IeSFsaGYFkarQ8sMLLQrpg",
                    },
                    "payload": SalesforcePubSubEventDataProvider::getExamplePayload(
                        channel_name),
                };
            }
        }
    }

    #! Returns the event data type, derived from the channel's Avro schema where possible
    /** The envelope is the static
        \c SalesforcePubSubEventDataType;
        only \c payload is channel-specific, and it is replaced here with a type derived from the
        channel's own Avro schema when the org can be reached, so a Qog bound to a specific channel
        shows its real field names.
    */
    private AbstractDataProviderType getEventType() {
        HashDataType rv(sprintf("SalesforcePubSubEvent_%s", channel_name =~ s/[^A-Za-z0-9_]/_/g));
        hash<string, AbstractDataField> fields = SalesforcePubSubEventType.getFields();
        rv.addField(fields.channel);
        rv.addField(fields.event);
        if (*AbstractDataProviderType payload = resolvePayloadTypeIfAvailable()) {
            rv.addField(new QoreDataField("payload", fields.payload.getDescription(), payload));
        } else {
            rv.addField(fields.payload);
        }
        return rv;
    }

    #! Returns the payload type only if it could be derived from the channel's Avro schema
    /** @return the payload type, or @ref nothing if the org could not be reached
    */
    private *AbstractDataProviderType resolvePayloadTypeIfAvailable() {
        resolvePayloadType();
        AutoLock al(m);
        return payload_type;
    }

    #! Returns the payload type from the channel's Avro schema, or an untyped hash
    /** The schema is fetched with the unary \c GetTopic and \c GetSchema calls; no subscription is
        opened, so introspecting the provider does not consume a subscription slot.
    */
    private AbstractDataProviderType resolvePayloadType() {
        {
            AutoLock al(m);
            if (payload_type_resolved) {
                return payload_type ?? AbstractDataProviderType::get(AutoHashType);
            }
        }

        *AbstractDataProviderType t;
        try {
            SalesforcePubSubClient pubsub_client = getPubSubClient();
            hash<auto> info = pubsub_client.getTopic(getTopicName());
            if (info.schema_id.val()) {
                t = AvroUtil::AvroTypeHelper::schemaToDataType(
                    pubsub_client.getSchema(info.schema_id));
            }
        } catch (hash<ExceptionInfo> ex) {
            # the org may be unreachable, the channel may not be describable by this user, or the
            # provider may have been created without a connection; an untyped payload is still
            # usable, so this must not make introspection fail
        }

        AutoLock al(m);
        payload_type = t;
        payload_type_resolved = True;
        return t ?? AbstractDataProviderType::get(AutoHashType);
    }

    #! Returns the topic name, or the channel name if it cannot be resolved
    private string getTopicNameSafe() {
        try {
            return getTopicName();
        } catch (hash<ExceptionInfo> ex) {
            return channel_name;
        }
    }

    #! Called by the subscription for each event received
    private eventReceived(hash<auto> event) {
        notifyObservers(EVENT_SALESFORCE_PUBSUB_EVENT, event);
    }

    #! Called by the subscription when it gives up
    private subscriptionFailed(hash<auto> error) {
        {
            AutoLock al(m);
            remove subscription;
        }
        notifyObservers(EVENT_SALESFORCE_PUBSUB_ERROR, {
            "err": error.err,
            "desc": error.desc,
        });
    }

    #! Returns channel-specific example payload data
    /** Used only when the org cannot be reached to fetch the channel's real Avro schema.

        @param channel_name the channel name

        @return example payload data
    */
    private static hash<auto> getExamplePayload(string channel_name) {
        if (channel_name =~ /ChangeEvent$/) {
            string entity = (channel_name =~ x/^(?:.*\/)?(.*)ChangeEvent$/)[0] ?? "Account";
            return {
                "ChangeEventHeader": {
                    "entityName": entity,
                    "recordIds": ("001xx000003DGb2AAG",),
                    "changeType": "UPDATE",
                    "changeOrigin": "com/salesforce/api/soap/64.0;client=SfdcInternalAPI/",
                    "transactionKey": "000d8dc9-1e2f-4a1b-8c3d-4e5f60718293",
                    "sequenceNumber": 1,
                    "commitTimestamp": 1753600000000,
                    "commitNumber": 11223344556677,
                    "commitUser": "005xx000001X7dLAAU",
                    "nulledFields": (),
                    "diffFields": (),
                    "changedFields": ("Name", "LastModifiedDate"),
                },
                "Name": "Acme Corporation",
                "LastModifiedDate": 1753600000000,
            };
        }
        return {
            "CreatedDate": 1753600000000,
            "CreatedById": "005xx000001X7dLAAU",
        };
    }
}

} # namespace SalesforcePubSubDataProvider
