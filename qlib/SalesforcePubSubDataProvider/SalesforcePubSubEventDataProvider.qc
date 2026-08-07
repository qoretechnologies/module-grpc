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
        /** A Change Data Capture channel exposes one child per change type preset
            (@ref ChangeTypeChildMap), so that an action can express "new record" through the
            provider path rather than by presetting an option.
        */
        const ProviderInfo = <DataProviderInfo>{
            "type": "SalesforcePubSubEventDataProvider",
            "desc": "Observable data provider for a single Salesforce Pub/Sub event channel",
            "supports_observable": True,
            "supports_children": True,
            "children_can_support_observers": True,
            "children_can_support_apis": False,
            "children_can_support_records": False,
        };

        #! Provider info for a change type preset child, which has no children of its own
        const PresetProviderInfo = cast<hash<DataProviderInfo>>(ProviderInfo + {
            "desc": "Observable data provider for one change type on a Salesforce Change Data "
                "Capture channel",
            "supports_children": False,
            "children_can_support_observers": False,
        });

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
            "change_type": <DataProviderOptionInfo>{
                "display_name": "Change Types",
                "short_desc": "Which Change Data Capture change types to deliver",
                "type": new DataProvider::SoftListDataType(
                    AbstractDataProviderTypeMap."string", True),
                "desc": "Restricts delivery to the given **Change Data Capture** change types; "
                    "leave empty to receive every change on the channel.\n\n"
                    "A **gap event** reports a change that Salesforce could not deliver in full. "
                    "Gap types satisfy the type they stand in for, so selecting `CREATE` also "
                    "delivers `GAP_CREATE` rather than dropping the create silently. "
                    "`GAP_OVERFLOW` is always delivered, whatever the filter, because it reports "
                    "that an unknown number of changes were lost.\n\n"
                    "This option applies to Change Data Capture channels only; platform events "
                    "carry no `ChangeEventHeader` and setting it on a platform event channel is "
                    "an error.",
                "element_allowed_values": (
                    <AllowedValueInfo>{
                        "value": ChangeTypeCreate,
                        "display_name": "Create",
                        "desc": "A record was created",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeUpdate,
                        "display_name": "Update",
                        "desc": "A record was updated",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeDelete,
                        "display_name": "Delete",
                        "desc": "A record was deleted",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeUndelete,
                        "display_name": "Undelete",
                        "desc": "A record was restored from the recycle bin",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeGapCreate,
                        "display_name": "Gap: Create",
                        "desc": "A record was created, but the change could not be delivered; "
                            "implied by `CREATE`",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeGapUpdate,
                        "display_name": "Gap: Update",
                        "desc": "A record was updated, but the change could not be delivered; "
                            "implied by `UPDATE`",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeGapDelete,
                        "display_name": "Gap: Delete",
                        "desc": "A record was deleted, but the change could not be delivered; "
                            "implied by `DELETE`",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeGapUndelete,
                        "display_name": "Gap: Undelete",
                        "desc": "A record was restored, but the change could not be delivered; "
                            "implied by `UNDELETE`",
                    },
                    <AllowedValueInfo>{
                        "value": ChangeTypeGapOverflow,
                        "display_name": "Gap: Overflow",
                        "desc": "An unknown number of changes were lost; always delivered",
                    },
                ),
                "example_value": (ChangeTypeCreate,),
                "preselected": True,
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
            "enable_cdc": <DataProviderOptionInfo>{
                "display_name": "Enable Change Data Capture",
                "short_desc": "Switch Change Data Capture on for the object if it is not already",
                "type": AbstractDataProviderTypeMap."*bool",
                "desc": "If `True`, and the org reports that this **Change Data Capture** channel "
                    "cannot be subscribed to because the object was never selected, switch it on "
                    "and continue, rather than failing.\n\n"
                    "This exists because a subscription to an object that is not enabled succeeds "
                    "and then delivers nothing, which is indistinguishable from an idle org. The "
                    "default is `False`: subscribing to events should not quietly change org "
                    "configuration.\n\n"
                    "**This changes org configuration.** It starts a 72-hour retention stream for "
                    "the object, and the number of objects an org may select depends on its "
                    "edition and add-ons. The connection's user needs permission to modify "
                    "metadata. For a one-time, auditable step, use the "
                    "`enable-change-data-capture` action instead.",
                "default_value": False,
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

        #! The Change Data Capture change types to deliver, or @ref nothing for all of them
        /** Set by @ref observersReady() before the subscription is started, so it is in place
            before any event can be delivered.
        */
        *softlist<string> change_types;

        #! The change type preset name if this provider is a preset child of a channel provider
        /** A key of @ref ChangeTypeChildMap; when set, the change type filter comes from the
            provider path and the \c change_type option may not be given.

            @note Set by the constructor and never modified afterwards, so unlike
            @ref change_types it is read without holding @ref m.
        */
        *string preset_name;

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

    #! Creates the object from an async Salesforce REST client
    /** @param rest the async Salesforce REST client
        @param channel_name the channel name; an event entity name or a topic name
        @param options Pub/Sub client options
    */
    constructor(SalesforceRestClient::SalesforceRestClientIo rest, string channel_name,
            *hash<auto> options) : SalesforceRestDataProviderBase(rest) {
        self.channel_name = channel_name;
        pubsub_options = options;
    }

    #! Creates a change type preset child from a Salesforce connection
    /** @param conn the Salesforce REST connection
        @param channel_name the channel name; an event entity name or a topic name
        @param options Pub/Sub client options
        @param preset the change type preset name; a key of @ref ChangeTypeChildMap
    */
    constructor(SalesforceRestClient::SalesforceRestConnection conn, string channel_name,
            *hash<auto> options, string preset) : SalesforceRestDataProviderBase(conn) {
        self.channel_name = channel_name;
        pubsub_options = options;
        preset_name = preset;
    }

    #! Creates a change type preset child from an async Salesforce REST client
    /** @param rest the async Salesforce REST client
        @param channel_name the channel name; an event entity name or a topic name
        @param options Pub/Sub client options
        @param preset the change type preset name; a key of @ref ChangeTypeChildMap
    */
    constructor(SalesforceRestClient::SalesforceRestClientIo rest, string channel_name,
            *hash<auto> options, string preset) : SalesforceRestDataProviderBase(rest) {
        self.channel_name = channel_name;
        pubsub_options = options;
        preset_name = preset;
    }

    #! Stops the subscription and deletes the object
    destructor() {
        stopEvents();
    }

    #! Returns the data provider name
    string getName() {
        return preset_name ?? channel_name;
    }

    #! Returns the data provider description
    *string getDesc() {
        if (preset_name.val()) {
            return sprintf("Salesforce Pub/Sub channel `%s` restricted to `%s` changes; the "
                "matching gap change type is delivered with it", channel_name,
                ChangeTypeChildMap{preset_name});
        }
        return SalesforcePubSubEventDataProvider::getChannelDesc(channel_name);
    }

    #! Returns the change type preset names available on this channel
    /** Only a Change Data Capture channel has them, and only a channel provider that is not
        already a preset child.
    */
    private *list<string> getChildProviderNamesImpl() {
        if (preset_name.val() || is_platform_event_channel(channel_name)) {
            return;
        }
        return keys ChangeTypeChildMap;
    }

    #! Returns the given change type preset child, or @ref nothing if the name is unknown
    /** @param name the change type preset name; a key of @ref ChangeTypeChildMap

        @return a provider for this channel restricted to that change type
    */
    private *AbstractDataProvider getChildProviderImpl(string name) {
        if (preset_name.val() || !ChangeTypeChildMap.hasKey(name)
            || is_platform_event_channel(channel_name)) {
            return;
        }
        if (conn) {
            return new SalesforcePubSubEventDataProvider(conn, channel_name, pubsub_options, name);
        }
        return new SalesforcePubSubEventDataProvider(rest, channel_name, pubsub_options, name);
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

        # the change type filter comes from the provider path for a preset child, so an explicit
        # option would be either redundant or a contradiction; reject it rather than silently
        # picking one
        *softlist<string> want;
        if (preset_name.val()) {
            if (copts.change_type) {
                throw "SALESFORCE-PUBSUB-OPTION-ERROR", sprintf("the \"change_type\" option "
                    "cannot be set on the %y child of channel %y, which already selects %y; "
                    "subscribe to the channel itself to filter explicitly", preset_name,
                    channel_name, ChangeTypeChildMap{preset_name});
            }
            want = (ChangeTypeChildMap{preset_name},);
        } else {
            want = copts.change_type;
        }

        # a change type filter on a platform event channel would drop every event, since platform
        # events carry no ChangeEventHeader; that is always a configuration error, so reject it
        # here rather than delivering silence
        if (want && is_platform_event_channel(topic)) {
            throw "SALESFORCE-PUBSUB-OPTION-ERROR", sprintf("the \"change_type\" option was set "
                "to %y for topic %y, but that is a platform event channel; platform events carry "
                "no \"ChangeEventHeader\", so no event could ever match.  Remove the "
                "\"change_type\" option to subscribe to this channel", want, topic);
        }

        checkCanSubscribe(topic, copts.enable_cdc ?? False);

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
            change_types = want;
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
    /** A provider created from a REST client can subscribe just as one created from a connection
        can: the provider's own client is a \c SalesforceRestClientIo, which carries the access
        token and the org's instance URL -- the whole of the Pub/Sub call metadata.  This used to
        throw for the REST-client case, because the provider then held a *blocking*
        \c SalesforceRestClient that could supply neither.

        @return the Pub/Sub client
    */
    SalesforcePubSubClient getPubSubClient() {
        AutoLock al(m);
        if (!pubsub) {
            pubsub = conn
                ? new SalesforcePubSubClient(conn, pubsub_options)
                : new SalesforcePubSubClient(
                    cast<SalesforceRestClient::SalesforceRestClientIo>(rest), pubsub_options);
        }
        return pubsub;
    }

    #! Returns data provider static info
    private hash<DataProviderInfo> getStaticInfoImpl() {
        return preset_name.val() ? PresetProviderInfo : ProviderInfo;
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

    #! Verifies that the org allows this subscription before one is opened
    /** A subscription to a Change Data Capture channel whose entity has not been selected in
        <b>Setup -> Change Data Capture</b> succeeds and then delivers nothing, which is the worst
        failure mode available: it is indistinguishable from an idle org.  The Pub/Sub API reports
        this authoritatively through \c TopicInfo.can_subscribe, so it is checked before
        subscribing and reported as an error naming the entity and where to enable it.

        The check is a diagnostic aid rather than a gate: if \c GetTopic cannot be performed at
        all, this returns and lets the subscription itself report the real failure.

        @param topic the resolved topic name
        @param enable_cdc if @ref True and the topic is a Change Data Capture channel whose entity
        was never selected, select it and continue instead of failing

        @throw SALESFORCE-PUBSUB-SUBSCRIBE-ERROR the org reports that this topic cannot be
        subscribed to
    */
    private checkCanSubscribe(string topic, bool enable_cdc = False) {
        if (canSubscribe(topic)) {
            return;
        }

        *string entity = get_change_event_entity(topic);
        if (entity && enable_cdc) {
            # the caller asked for this explicitly; enabling is never done without being asked
            hash<auto> h = SalesforcePubSubCdc::enable(getApiRest(), entity);
            info("Change Data Capture enabled for %y (%s)", entity,
                h.already_enabled ? "was already enabled" : "newly enabled");
            if (canSubscribe(topic)) {
                return;
            }
            # the selection is made but the org has not yet published the channel; say so
            # precisely rather than opening a subscription that would deliver nothing
            throw "SALESFORCE-PUBSUB-SUBSCRIBE-ERROR", sprintf("Change Data Capture was enabled "
                "for %y, but the org does not report topic %y as subscribable yet; retry the "
                "subscription", entity, topic);
        }

        string hint;
        if (entity) {
            hint = sprintf("; enable Change Data Capture for %y -- either with the "
                "\"enable-change-data-capture\" action, or by setting the \"enable_cdc\" option "
                "on this subscription, or by hand in Setup -> Integrations -> Change Data "
                "Capture -- and check that the connection's user has the \"View All Data\" or "
                "\"View All Records\" permission for it", entity);
        } else {
            hint = "; check that the channel exists and that the connection's user is permitted "
                "to subscribe to it";
        }
        throw "SALESFORCE-PUBSUB-SUBSCRIBE-ERROR", sprintf("the org reports that topic %y cannot "
            "be subscribed to%s", topic, hint);
    }

    #! Returns @ref True if the org reports the topic as subscribable
    /** Two different answers mean "no", and only one of them was obvious.  \c TopicInfo carries a
        \c can_subscribe flag, but a Change Data Capture entity that was never selected does not
        produce \c can_subscribe = @ref False -- it produces no \c TopicInfo at all: \c GetTopic
        fails with \c GRPC_STATUS_NOT_FOUND and the message "The topic information for org ... and
        topic ... not found".  Verified against a live org: an unselected entity and a nonexistent
        object are indistinguishable here, and both are \c NOT_FOUND.

        Every other \c GetTopic failure -- transport, TLS, authentication -- is not evidence about
        the channel, so it is swallowed and the subscription is left to report the real cause.

        @param topic the resolved topic name

        @return @ref True if the topic may be subscribed to, or if the org could not be asked
    */
    private bool canSubscribe(string topic) {
        try {
            hash<auto> info = getPubSubClient().getTopic(topic);
            return !exists info.can_subscribe || info.can_subscribe;
        } catch (hash<ExceptionInfo> ex) {
            return ex.arg.status_code != GRPC_STATUS_NOT_FOUND;
        }
    }

    #! Called by the subscription for each event received
    /** Events excluded by the \c change_type filter are not delivered to observers.  The
        subscription advances its replay position after this callback returns and does so
        unconditionally, so filtering here cannot cause a reconnect to re-deliver or skip events;
        that ordering is relied on and must be preserved.
    */
    private eventReceived(hash<auto> event) {
        *softlist<string> want;
        {
            AutoLock al(m);
            want = change_types;
        }
        if (want) {
            auto ct = event.payload.ChangeEventHeader.changeType;
            *string change_type = ct.typeCode() == NT_STRING ? ct : NOTHING;
            if (!change_type_matches(want, change_type)) {
                return;
            }
        }
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
