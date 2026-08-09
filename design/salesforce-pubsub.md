# Salesforce Pub/Sub API event source

`qlib/SalesforcePubSubDataProvider/`, tests in `test/salesforce-pubsub.qtest`.

The implementation follows `data-provider-development-guide.md` § *Event Providers*,
`data-provider-checklist.md` § 9 and `async-socket-io.md`; this document does not restate them.

## Layering

```
qlib/SalesforcePubSubDataProvider/
  SalesforcePubSubEventsDataProvider   events container; channels from describeGlobal
  SalesforcePubSubEventDataProvider    one per channel; DelayedObservable, DPAT_EVENT
  SalesforcePubSubSubscription         flow control, keepalive, replay, reconnect, token refresh
  SalesforcePubSubClient               call metadata, GetSchema + Avro schema cache, GetTopic
  SalesforcePubSubProto                the vendored pubsub_api.proto as a cached ProtobufSchema
        |
GrpcAsyncClientStream (qlib/GrpcUtil)  bidirectional streaming on the async I/O controller
protobuf (builtin)                     pubsub_api.proto loaded at runtime
avro (builtin) + AvroUtil              event payload decode and the DataProvider type mapping
SalesforceRestClient (Qore library)    OAuth2, the org identity, describeGlobal
```

`GrpcUtil` is the generic gRPC transport and knows nothing about Salesforce. Everything
Salesforce-specific — the call metadata, the vendored proto, the Avro payload mapping and the
provider tree — is in this module.

## Decisions

### The Avro decode happens in Qore

The read loop is in Qore by construction: events arrive in the `GrpcAsyncClientStream` delivery
sinks, which are Qore closures running on an async I/O controller callback worker. Decoding there is
`AvroSchema::decode()` — one call on an object the schema cache already holds. A C++ decode path
would have to be reached *from* that Qore callback anyway, so it would add a layer without removing
one, and it would gain nothing on the schema side either: `AvroSchema` is a Qore object, the cache
holds it, and `AvroTypeHelper::schemaToDataType()` takes that same object, so a channel's schema is
never parsed twice.

### Actions attach to the Salesforce app; no `registerApp()`, no logo

The events are Salesforce events. Registering `SalesforcePubSub` as its own application would split
one integration across two entries in the UI, with a second Salesforce logo. So the module registers
**no app** and instead registers its `DPAT_EVENT` action against
`SalesforceRestDataProvider::AppName`.

This is the extender convention established by `QorusOpenAiServices`, `QorusDiscordServices`,
`QorusGoogleServices` and `QorusSlackServices`, which all pass `"app": <Base>DataProvider::AppName`.
The dependency direction stays right — the extender knows the base, the base knows nothing about
extenders — while activation is inverted by `%try-child-module` so the extension is not silently
absent.

That inversion has a standing cost: a child that is *present but unloadable* fails its parent, so a
build of this module that does not match the installed `SalesforceRestDataProvider` does not merely
lose the `pubsub` child — it makes `SalesforceRestDataProvider` unloadable for every consumer,
Pub/Sub or not. This module tracks the base's API and has to be deployed with it.

### One action with a `{channel}` path variable, not one action per channel

Channels are org-specific, so a static action per channel is impossible. The action is registered
once at `/pubsub/{channel}`, and the subscription options (`replay_preset`, `replay_id`,
`num_requested`, `topic_name`) are action options read from the data provider context in
`observersReady()`.

`/pubsub` is a **dynamic** child of `SalesforceRestDataProvider` — it is in `dynamic_children`, not
in `ChildMap` — so the action path resolves at runtime through `getChildProviderImpl()`, which
serves dynamic children whenever the provider was built from a connection. That is the only case the
action catalog uses.

### Everything is async, channel enumeration included

The Pub/Sub API has no list-topics RPC, so `getChildProviderNamesImpl()` comes from `describeGlobal`
on the REST side. That call has to be made against the org's **instance URL** at the negotiated API
version rather than against the org host, which is what the provider's own client targets — issuing
`sobjects` against that client would address the org's web UI.

`SalesforceRestClientIo::getApiClient()` does that retargeting, negotiating the version from
`GET /services/data` and caching the result, and `SalesforceRestDataProviderBase::doRestCommand()`
runs every call on it. So enumeration is one `GET sobjects` on the async socket I/O controller: it
still blocks its *caller*, as the synchronous `getChildProviderNamesImpl()` contract requires, but it
occupies no thread for the duration of the request. Nothing in the module is blocking.

The consequence worth stating is that a provider built from a REST client rather than a connection
can subscribe. The Pub/Sub call metadata is an access token and an instance URL; a
`SalesforceRestClientIo` carries both, so `getPubSubClient()` falls back to the `rest` member and
throws only when the provider has neither a connection nor a client.

Token refresh needs no retargeting at all: `getNewToken()` and `startOAuth2PollRefreshToken()` POST
to `oauth2_token_url` / `oauth2_alt_token_url`, not to the client's base URL. `SalesforceRestClientIo`
captures `instance_url` on every token acquisition (qore `52911582c`) and discards the cached API
client when the org moves, so a refresh that relocates the org is followed without losing the replay
position.

### The reconnect runs on a transient thread; nothing else does

Every I/O path is on the async socket I/O controller. There is no thread parked on a read and no
timed-read polling. Two consequences worth stating:

- **Reconnect backoff** is a real deadline. The controller has no standalone timer API, so
  `Priv::SalesforcePubSubDelay` is a poll operation that waits on an `EventNotifier` nothing ever
  signals and returns `poll_timeout_ms`; the controller's timeout heap wakes it when the deadline
  comes due, and `cancel()` signals the notifier so a `stop()` is immediate rather than "wait for
  the deadline and then notice".
- **Opening a stream blocks**, bounded: `GrpcClient::bidiStreamAsync()` waits for the HTTP/2
  handshake, and an expired token adds an OAuth2 round trip. For the initial `start()` that runs on
  the caller's thread, which is correct. For a reconnect the trigger is a callback worker, so the
  work is handed to a transient `background` thread that exits as soon as the stream is open. That
  is a bounded setup thread, not a read loop, and it keeps a worker shared by other streams from
  being occupied by a handshake.

A schema cache miss also costs one synchronous `GetSchema` round trip on the delivery worker. The
channel's schema is pre-fetched in `start()` so the steady state is a cache hit; a miss then only
happens on the first event of a new schema version.

### Flow control: delivery-driven, with the backstop armed only at zero credit

`FetchRequest.num_requested` grants credit, capped at 100 per request and accumulated server-side;
each `FetchResponse` reports what remains as `pending_num_requested`. Once that reaches zero the
server closes the stream unless a new `FetchRequest` arrives within 60 seconds.

Replenishment happens in the response handler as soon as the reported credit falls to
`low_water_mark`. Two details make the 60-second window a genuine backstop rather than the
mechanism:

- **Credit is credited optimistically on write** and resynchronised from every server report. Without
  that, the client would still believe it had zero credit after topping up and would re-send every
  time the backstop fired — up to 270 seconds until the next keepalive resynchronised it, granting
  several hundred events of credit for nothing.
- **The backstop is armed only when a response reports zero credit**, and is cancelled by the next
  `FetchRequest`. A healthy subscription therefore arms no timer at all. It is reachable when the
  replenishing write fails, or when a consumer sets `auto_replenish` to `False` and drives credit
  itself, and in that case it sends a request even when the window needs no topping up — the
  obligation is to send one, not to add credit.

### The reconnect budget is reset by a response, not by a successful connect

`max_reconnect_attempts` counts consecutive failures. Resetting the counter when the stream *opens*
looks natural and is wrong: a server that accepts the stream and then immediately fails it resets
the counter on every attempt, and the subscription reconnects forever regardless of the limit. The
counter is reset by the first `FetchResponse` on a stream, which is the point at which the
subscription is demonstrably working.

### The replay position advances only after the consumer has seen the event

Each event's own `replay_id` becomes the stored position *after* `on_event` returns, so a consumer
callback that throws does not advance past the event it failed on. An empty batch adopts the
response's `latest_replay_id` instead, which is what lets a resubscribe skip ground already covered.

`replay_preset` and `replay_id` are consumed only from the first `FetchRequest` of a stream, so on a
reconnect the stored position takes precedence over the configured starting preset. An expired or
corrupt ID surfaces as `sfdc.platform.eventbus.grpc.subscription.fetch.replayid.corrupted`; the
stored ID is then dropped and the subscription restarts at the configured preset, falling back from
`CUSTOM` to `EARLIEST`, because retrying with the same ID would fail identically forever. Retention
is 72 hours.

### Enum values must be converted to their wire numbers before encoding

The protobuf module accepts only integers for an enum field: given the enum's **name** it silently
encodes `0` rather than raising an error. For `ReplayPreset` that turns `CUSTOM` into `LATEST` and
loses the replay resume with no diagnostic at all. `SalesforcePubSubProto::getReplayPresetValue()`
resolves each preset from the vendored schema's own `enumValues()`, so the mapping stays correct if
upstream renumbers the enum, and `test/salesforce-pubsub.qtest` asserts the value that reaches the
server. The coercion is a property of the `protobuf` module generally, not of this provider.

### The event envelope mirrors the CometD envelope

```
{
    "channel":  "/data/AccountChangeEvent",
    "event":    {"replayId": <base64 string>, "id": <string>, "schemaId": <string>},
    "payload":  {<decoded Avro record>},
}
```

The CometD streaming API delivers `{"event": {"replayId": ...}, "payload": {...}}`, so mappers
written against it — reading `payload.ChangeEventHeader.recordIds` and `event.replayId` — port with
no change of shape. The one unavoidable difference is that the Pub/Sub replay ID is opaque `bytes`
rather than a monotonic integer, so `event.replayId` is a base64 string and must be treated as an
opaque token.

### The changed-field bitmaps are decoded, not passed through

One difference would otherwise have broken every ported mapper silently.
`ChangeEventHeader.changedFields`, `nulledFields` and `diffFields` do not carry field *names* on the
Pub/Sub API the way they did on CometD: each entry is a big-endian hex integer over the channel's
Avro schema field order — bit N selects field N — so an `Account` update arrives as `"0x401002"`,
meaning `Name` (1), `AnnualRevenue` (12) and `LastModifiedDate` (22). A compound field adds an entry
of the form `"<parent index>-<child bitmap>"` indexing the nested record.

`SalesforcePubSubSubscription` decodes them to names before delivery, dotting the nested ones
(`BillingAddress.City`). The decode belongs there and nowhere else: it needs the channel's Avro
schema, which the delivery path already holds to decode the payload at all, so doing it once here
costs a bit scan and saves every consumer from fetching a schema to interpret a header. It is also
what makes the `updated-record` action's promise — that the fields which changed are known without
re-reading the record — true rather than aspirational.

An entry that cannot be decoded is passed through unchanged rather than dropped: a bit with no field
behind it means the bitmap and the schema disagree, and a consumer that sees `"0x40000"` can tell
something is wrong, where an empty list would assert that nothing changed.

### The vendored proto is a file, not a string constant

`pubsub_api.proto` is vendored verbatim from `forcedotcom/pub-sub-api` under **CC0-1.0** and loaded
from disk with `get_script_dir()`. The `*.proto` resource globs in `cmake/QoreMacros.cmake` install
it both next to the AOT `.qmod` in `lib64/qore-modules/SalesforcePubSubDataProvider/` and next to
the source `.qm` in `share/qore-modules/SalesforcePubSubDataProvider/`, so `get_script_dir()` finds
it whichever form is loaded.

### The Pub/Sub endpoint's certificate is verified

`GrpcSslOptions::verify_mode` is honoured by `GrpcChannel`, and `SalesforcePubSubClient` sets
`SSL_VERIFY_PEER` for any `https` endpoint, so `api.pubsub.salesforce.com` is verified against the
system CA store rather than accepted unconditionally. `GrpcChannel`'s permissive default is
unchanged, which is what a local test server needs.

## Not implemented

- **`Publish` / `PublishStream`** — this is an event *source*; the providers are `DPAT_EVENT` only.
  `GetTopic` is implemented because it yields a channel's schema ID without opening a subscription,
  which is what gives an introspected provider real field names.
- **`ManagedSubscribe`** — an open beta API whose replay position is committed server-side. It is a
  different state machine, and the client-managed replay position is what this replaces.

## Testing

`test/salesforce-pubsub.qtest` — the CI loop globs `test/*.qtest` at the top level only, so a suite
in a subdirectory would not run.

Everything runs against a local gRPC server built on this module's own `GrpcServer`, serving
`eventbus.v1` from the vendored proto, with Avro payloads produced by the builtin `avro` module —
encode-ours / decode-theirs, the same cross-check the avro suites use. Each `Subscribe` connection
consumes a script of steps (`send`, `expect_request`, `throw`, `park`), which is deterministic
because the client only ever writes a `FetchRequest` in response to something: the opening request,
a replenishment triggered by a reported credit level, or the backstop deadline.

The REST round trip behind channel enumeration is substituted (the `describeGlobal` response is
scripted); everything below it — the channel filter, the child names, the summary info and the child
providers — is the real implementation.

### The live mode

`-c`/`--connection` (default `salesforce`, also read from `SALESFORCE_CONNECTION`) runs the
`live ...` cases against a real org; without a reachable one they skip, so this is what CI runs and
the offline suite above stands alone. Naming a connection explicitly makes a load failure an error
rather than a skip, so a live run cannot silently degrade into an offline one.

The live cases exist for what a scripted server cannot establish: that the org answers `GetTopic`
and `GetSchema` for a real channel, that a real Avro schema parses and yields the entity's own field
names, and that a record written over REST comes back as a Change Data Capture event whose
Salesforce-issued replay ID resumes after it. They write one Account and delete it again on the way
out, and change no org configuration — a channel whose entity has not been selected in Setup is a
skip with instructions, never an implicit enable.

