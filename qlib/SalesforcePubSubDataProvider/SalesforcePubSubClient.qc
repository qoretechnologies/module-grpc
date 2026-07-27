# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubClient.qc Salesforce Pub/Sub API client

/*  SalesforcePubSubClient.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Salesforce Pub/Sub API client
/** A concrete service client over \c GrpcClient for the \c eventbus.v1
    \c PubSub service, adding the three things the raw gRPC client cannot supply: the Salesforce
    call metadata, an Avro schema cache keyed by schema ID, and subscriptions
    (@ref SalesforcePubSubDataProvider::SalesforcePubSubSubscription "SalesforcePubSubSubscription").

    Authentication is by call metadata rather than an \c Authorization header:
    @ref MetadataAccessToken, @ref MetadataInstanceUrl and @ref MetadataTenantId, all derived
    from a Salesforce REST client so that there is no second connection type and no
    re-implemented OAuth2 flow.

    The metadata is rebuilt for every call, so a token refreshed on the REST client is picked up
    by the next call or subscription without any further coordination.

    @par Example:
    @code{.py}
SalesforcePubSubClient client(conn);
AvroSchema schema = client.getSchema(client.getTopic("/data/AccountChangeEvent").schema_id);
printf("%s\n", schema.getJson());
    @endcode

    @note All I/O runs on the async socket I/O controller: subscriptions are driven by
    \c GrpcAsyncClientStream and the REST client used for the
    call metadata is \c SalesforceRestClientIo.

    @section salesforcepubsubclient_options Client Options

    | Option | Type | Default | Description |
    |--|--|--|--|
    | \c url | \c string | @ref PubSubUrl | the Pub/Sub endpoint; the default is the single global host, so this is normally only set to point at a test server |
    | \c call_timeout_ms | \c int | \c 30000 | timeout for the unary \c GetTopic and \c GetSchema calls |
    | \c schema_cache_size | \c int | \c 256 | maximum number of Avro schemas held in the schema cache |
    | \c channel_options | \c hash | - | \c GrpcChannelOptions for the channel; TLS peer verification is required by default for an \c https endpoint |
*/
public class SalesforcePubSubClient {
    public {
        #! Default timeout for unary calls, in milliseconds
        const DefaultCallTimeoutMs = 30000;

        #! Default maximum number of Avro schemas held in the schema cache
        /** Schema IDs are stable for a given channel version, so the cache is bounded only to
            keep a process that subscribes to many channels over a long lifetime from growing
            without limit.
        */
        const DefaultSchemaCacheSize = 256;
    }

    private {
        #! The Salesforce connection, if the client was created from one
        *SalesforceRestClient::SalesforceRestConnection sfconn;

        #! The async Salesforce REST client supplying the call metadata
        *SalesforceRestClient::SalesforceRestClientIo sfrest;

        #! Explicit call metadata, when supplied instead of a REST client
        *hash<string, string> static_metadata;

        #! The gRPC channel to the Pub/Sub endpoint
        GrpcChannel channel;

        #! The gRPC client bound to the \c eventbus.v1.PubSub service
        GrpcClient client;

        #! The Pub/Sub endpoint URL in use
        string url;

        #! Timeout for unary calls, in milliseconds
        int call_timeout_ms = DefaultCallTimeoutMs;

        #! Maximum number of schemas held in @ref schema_cache
        int schema_cache_size = DefaultSchemaCacheSize;

        #! Avro schemas by schema ID
        hash<string, AvroSchema> schema_cache;

        #! Schema IDs in insertion order, for eviction
        list<string> schema_order();

        #! Lock protecting the schema cache
        Mutex schema_lock();

        #! Lock protecting the REST client and metadata state
        Mutex auth_lock();
    }

    #! Creates the client from a Salesforce connection
    /** The async REST client is acquired from the connection on first use, so constructing this
        object performs no I/O and no login.

        @param conn the Salesforce REST connection identifying the org
        @param opts client options; see @ref salesforcepubsubclient_options
    */
    constructor(SalesforceRestClient::SalesforceRestConnection conn, *hash<auto> opts) {
        sfconn = conn;
        init(opts);
    }

    #! Creates the client from an async Salesforce REST client
    /** @param rest the async Salesforce REST client supplying the call metadata; it must be
        logged in, or able to log in, so that the access token, instance URL and org ID are
        available
        @param opts client options; see @ref salesforcepubsubclient_options
    */
    constructor(SalesforceRestClient::SalesforceRestClientIo rest, *hash<auto> opts) {
        sfrest = rest;
        init(opts);
    }

    #! Creates the client from explicit call metadata
    /** For callers that already hold a Salesforce session token and org identity and do not
        want this object to manage authentication.  No token refresh is possible in this mode:
        when the token expires, subscriptions fail and the caller must supply a new client.

        @param metadata the call metadata; must contain @ref MetadataAccessToken,
        @ref MetadataInstanceUrl and @ref MetadataTenantId
        @param opts client options; see @ref salesforcepubsubclient_options

        @throw SALESFORCE-PUBSUB-ERROR a required metadata key is missing
    */
    constructor(hash<string, string> metadata, *hash<auto> opts) {
        foreach string key in ((MetadataAccessToken, MetadataInstanceUrl, MetadataTenantId)) {
            if (!metadata{key}.val()) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("metadata key %y is missing or empty; "
                    "required keys: %y", key, (MetadataAccessToken, MetadataInstanceUrl,
                        MetadataTenantId));
            }
        }
        static_metadata = metadata;
        init(opts);
    }

    #! Copying is not supported
    private copy() {
        throw "COPY-ERROR", "SalesforcePubSubClient objects cannot be copied";
    }

    #! Returns the Pub/Sub endpoint URL in use
    /** @return the endpoint URL
    */
    string getUrl() {
        return url;
    }

    #! Returns the underlying gRPC client
    /** @return the \c GrpcClient bound to the \c eventbus.v1.PubSub service
    */
    GrpcClient getGrpcClient() {
        return client;
    }

    #! Returns information about a topic
    /** The Pub/Sub API has no list-topics RPC; \c GetTopic answers only for a topic that can
        already be named.  It is useful for confirming that a channel exists and can be
        subscribed to, and for obtaining its current schema ID without opening a subscription.

        @param topic_name the topic name, for example \c "/data/AccountChangeEvent"

        @return the \c TopicInfo hash with \c topic_name, \c tenant_guid, \c can_publish,
        \c can_subscribe, \c schema_id and \c rpc_id keys

        @throw SALESFORCE-PUBSUB-ERROR the call failed
    */
    hash<auto> getTopic(string topic_name) {
        return unaryCall("GetTopic", {"topic_name": topic_name});
    }

    #! Returns the Avro schema for the given schema ID
    /** Schema IDs repeat constantly on a subscription — every event carries one — so the cache
        is not an optimization; without it a subscription would issue a round trip per event.

        @param schema_id the schema fingerprint carried by each event

        @return the parsed Avro schema

        @throw SALESFORCE-PUBSUB-ERROR the call failed or the returned schema could not be parsed
    */
    AvroSchema getSchema(string schema_id) {
        {
            AutoLock al(schema_lock);
            if (*AvroSchema cached = schema_cache{schema_id}) {
                return cached;
            }
        }

        # the call is made outside the lock: a schema fetch is a network round trip and must not
        # block other channels' cache lookups.  A concurrent fetch of the same ID is possible and
        # harmless; the first result to be stored wins.
        hash<auto> info = unaryCall("GetSchema", {"schema_id": schema_id});
        if (!info.schema_json.val()) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("GetSchema for schema ID %y returned no "
                "schema JSON", schema_id);
        }
        AvroSchema schema;
        try {
            schema = new AvroSchema(info.schema_json);
        } catch (hash<ExceptionInfo> ex) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("the Avro schema returned for schema ID "
                "%y cannot be parsed: %s: %s", schema_id, ex.err, ex.desc);
        }

        AutoLock al(schema_lock);
        if (!schema_cache.hasKey(schema_id)) {
            schema_cache{schema_id} = schema;
            schema_order += schema_id;
            while (schema_order.size() > schema_cache_size) {
                remove schema_cache{shift schema_order};
            }
        }
        return schema_cache{schema_id};
    }

    #! Returns the number of Avro schemas currently cached
    /** @return the cache size
    */
    int getSchemaCacheSize() {
        AutoLock al(schema_lock);
        return schema_cache.size();
    }

    #! Starts a subscription to a Pub/Sub channel
    /** The subscription is inert until
        @ref SalesforcePubSubDataProvider::SalesforcePubSubSubscription::start() "start()" is
        called, so a caller can install its sinks first.

        @param topic_name the topic name, for example \c "/data/AccountChangeEvent"
        @param opts subscription options; see
        @ref SalesforcePubSubDataProvider::SalesforcePubSubSubscription "SalesforcePubSubSubscription"

        @return the subscription
    */
    SalesforcePubSubSubscription subscribe(string topic_name, *hash<auto> opts) {
        return new SalesforcePubSubSubscription(self, topic_name, opts);
    }

    #! Returns the Salesforce call metadata for a Pub/Sub call
    /** The metadata is rebuilt on every call so that a refreshed token is picked up
        immediately.  When the client was created from a connection or an async REST client and
        the token is inside its refresh window, it is refreshed first.

        @return the call metadata

        @throw SALESFORCE-PUBSUB-ERROR the org identity is not available; the REST client has
        not logged in
    */
    hash<string, string> getCallMetadata() {
        if (static_metadata) {
            return static_metadata;
        }
        SalesforceRestClient::SalesforceRestClientIo rest = getRestClient();
        if (rest.tokenRequiresRefresh()) {
            refreshToken();
        }
        return buildMetadata(rest);
    }

    #! Acquires a new access token from the Salesforce REST client
    /** Called when a subscription fails with \c GRPC_STATUS_UNAUTHENTICATED, and before a
        call when the token is inside its refresh window.  The async REST client captures
        \c instance_url on every token acquisition, so an org that has been moved to another
        instance is followed.

        @return @ref True if a new token was acquired

        @note Returns @ref False rather than throwing when the REST client's minimum token
        refresh interval has not elapsed: the caller is a reconnect path that must proceed with
        the token it has rather than abandon the subscription.
    */
    bool refreshToken() {
        if (static_metadata) {
            return False;
        }
        SalesforceRestClient::SalesforceRestClientIo rest = getRestClient();
        AutoLock al(auth_lock);
        try {
            rest.getNewToken();
            return True;
        } catch (hash<ExceptionInfo> ex) {
            if (ex.err == "OAUTH2-ERROR") {
                return False;
            }
            rethrow;
        }
    }

    #! Returns the async Salesforce REST client, acquiring it from the connection on first use
    /** @return the async REST client

        @throw SALESFORCE-PUBSUB-ERROR the client was created from explicit metadata and has no
        REST client
    */
    SalesforceRestClient::SalesforceRestClientIo getRestClient() {
        AutoLock al(auth_lock);
        if (!sfrest) {
            if (!sfconn) {
                throw "SALESFORCE-PUBSUB-ERROR", "this client was created from explicit call "
                    "metadata and has no Salesforce REST client";
            }
            sfrest = cast<SalesforceRestClient::SalesforceRestClientIo>(sfconn.getAsync());
        }
        return sfrest;
    }

    #! Applies constructor options and creates the gRPC channel and client
    private init(*hash<auto> opts) {
        url = opts.url ?? PubSubUrl;
        if (exists opts.call_timeout_ms) {
            call_timeout_ms = opts.call_timeout_ms;
        }
        if (exists opts.schema_cache_size) {
            if (opts.schema_cache_size < 1) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("option \"schema_cache_size\" must be "
                    "positive; got %y", opts.schema_cache_size);
            }
            schema_cache_size = opts.schema_cache_size;
        }

        hash<GrpcChannelOptions> chopts = opts.channel_options ?? <GrpcChannelOptions>{};
        if (url =~ /^https:/ && !exists chopts.ssl.verify_mode) {
            # the Pub/Sub endpoint is a public Salesforce host; its certificate must be verified
            # against the system CA store.  GrpcChannel accepts all certificates by default,
            # which is appropriate for a local test server but not for a production org
            chopts.ssl.verify_mode = SSL_VERIFY_PEER;
        }
        channel = new GrpcChannel(url, chopts);
        client = new GrpcClient(channel, SalesforcePubSubProto::get(),
            SalesforcePubSubProto::ServiceName);
    }

    #! Builds the call metadata from a REST client
    private static hash<string, string> buildMetadata(
            SalesforceRestClient::SalesforceRestClientIo rest) {
        *string token = rest.getToken();
        *string instance_url = rest.getInstanceUrl();
        *string org_id = rest.getOrgId();
        if (!token.val() || !instance_url.val() || !org_id.val()) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("the Salesforce org identity is "
                "incomplete; the REST client must be logged in before a Pub/Sub call "
                "(access token: %y, instance URL: %y, org ID: %y)", exists token,
                instance_url, org_id);
        }
        return {
            MetadataAccessToken: token,
            MetadataInstanceUrl: instance_url,
            MetadataTenantId: org_id,
        };
    }

    #! Returns the call options for a call, including the current metadata
    hash<GrpcCallOptions> getCallOptions(*int timeout_ms) {
        return <GrpcCallOptions>{
            "timeout_ms": timeout_ms ?? call_timeout_ms,
            "metadata": getCallMetadata(),
        };
    }

    #! Makes a unary call and returns the response body, throwing on a non-OK status
    private hash<auto> unaryCall(string method, hash<auto> request) {
        hash<GrpcCallResult> result = client.call(method, request, getCallOptions());
        if (result.status_code != GRPC_STATUS_OK) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("%s failed with gRPC status %d: %s",
                method, result.status_code, result.status_message);
        }
        return result.body;
    }
}

} # namespace SalesforcePubSubDataProvider
