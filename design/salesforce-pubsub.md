# Salesforce Pub/Sub API event source

Status: **implemented** — `qlib/SalesforcePubSubDataProvider/`, tests in `test/salesforce-pubsub.qtest`.

Tracked as [qore#5365](https://github.com/qoretechnologies/qore/issues/5365).

This document records the decisions taken while building it and the reasons for them. It does not
restate the rules in `data-provider-development-guide.md` § *Event Providers*,
`data-provider-checklist.md` § 9 or `async-socket-io.md`; the implementation follows those.

## Why

Qorus solutions that react to Salesforce changes depended on `BBM_SalesforceStreamBase`, a
building-block class speaking the Salesforce **CometD / Bayeux** streaming API over HTTP
long-polling. It was the last thing tying the Qorus demos repository to the `building-blocks`
submodule, and CometD is the transport Salesforce is steering integrations away from in favour of
the **Pub/Sub API** (gRPC + Avro).

There is no Bayeux implementation anywhere in the Qore module ecosystem, so replacing the building
block meant either writing one or moving to Pub/Sub. Pub/Sub is the better target because this
module already provides the transport.

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

Nothing new was added to `GrpcUtil` beyond a TLS option (below): `GrpcUtil` is the generic gRPC
transport and has no business knowing about Salesforce.

## Decisions

### The Avro decode happens in Qore, not in C++ through `QoreAvroApi`

`module-grpc` is a binary module and *could* consume `QoreAvroApi` (qore#5371), but it is not used
here.

The read loop is in Qore by construction: events arrive in the `GrpcAsyncClientStream` delivery
sinks, which are Qore closures running on an async I/O controller callback worker. Decoding there
means `AvroSchema::decode()` — one call on an object the schema cache already holds. A C++ decode
path would have to be reached *from* that Qore callback anyway, so it would add a layer without
removing one.

The C++ API's advantage — decode on the hot path while handing the same schema to `AvroUtil` for
the DataProvider type without parsing it twice — is already had here for free: `AvroSchema` is a
Qore object, the cache holds it, and `AvroTypeHelper::schemaToDataType()` takes the same object.

qore#5371 is justified by the versioned C++ API mechanism and the JSON relocation regardless; this
provider is simply not one of its consumers.

### Actions attach to the Salesforce app; no `registerApp()`, no logo

The events are Salesforce events. Registering `SalesforcePubSub` as its own application would split
one integration across two entries in the UI, with a second Salesforce logo. So the module
registers **no app** and instead registers its `DPAT_EVENT` action against
`SalesforceRestDataProvider::AppName`.

This is the extender convention already established by `QorusOpenAiServices`,
`QorusDiscordServices`, `QorusGoogleServices` and `QorusSlackServices`, which all pass
`"app": <Base>DataProvider::AppName`. The dependency direction stays right — the extender knows the
base, the base knows nothing about extenders — while activation is inverted by
`%try-child-module` so the extension is not silently absent.

This is a deliberate departure from the issue's task list, which said "`registerApp()` with a
square logo".

### One action with a `{channel}` path variable, not one action per channel

Channels are org-specific, so a static action per channel is impossible. The action is registered
once at `/pubsub/{channel}`, and the subscription options (`replay_preset`, `replay_id`,
`num_requested`, `topic_name`) are action options read from the data provider context in
`observersReady()`.

Note that `/pubsub` is a **dynamic** child of `SalesforceRestDataProvider` — it is in
`dynamic_children`, not in `ChildMap` — so the checklist's "every action path must resolve through
the root's `ChildMap`" does not literally apply. It resolves at runtime through
`getChildProviderImpl()`, which handles dynamic children whenever the provider was built from a
connection, which is the only case the action catalog uses.

### Channel enumeration uses the blocking REST client; token refresh uses the async one

The Pub/Sub API has no list-topics RPC, so `getChildProviderNamesImpl()` comes from `describeGlobal`
on the REST side.

That call needs the client retargeted at the org's **instance URL** and the negotiated API version.
`RestClientIo` exposes neither: it has no `setURL()` (noted at `RestClient.qm:5134`) and
`processApis()` / `setVerifyApi()` / `getApis()` are methods of the blocking class only. Making
enumeration async therefore means changing `RestClientIo`, a released module, to gain nothing —
`getChildProviderNamesImpl()` is a synchronous DataProvider API and its caller is blocked by the
framework contract either way. So enumeration uses the parent provider's already-working blocking
`SalesforceRestClient`.

Token refresh is different and does use the async client, and needs no retargeting at all:
`getNewToken()` and `startOAuth2PollRefreshToken()` POST to `oauth2_token_url` /
`oauth2_alt_token_url`, not to the client's base URL. `SalesforceRestClientIo` captures
`instance_url` on every token acquisition (qore `52911582c`), so a refresh that moves the org to
another instance is followed without losing the replay position. That is exactly what that
prerequisite exists for.

Note also that `RestClientIo` has no `setURL()` **by design** — the target URL is immutable and
`copyWithUrl()` is the sanctioned retargeting API. Taking the blocking client for enumeration
therefore also avoids the open `RestClientIo::copyWithUrl()` hazard: it ends in
`return new RestClientIo(opts, mgr)`, a hardcoded class, so copying a `SalesforceRestClientIo`
would yield a plain `RestClientIo` and silently lose the `gotOAuth2LoginInfo()` override — and with
it the org identity on the next refresh.

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
server.

This silent coercion is a footgun in the `protobuf` module generally, not specific to this provider;
it is worth an issue of its own.

### The event envelope mirrors the CometD envelope

```
{
    "channel":  "/data/AccountChangeEvent",
    "event":    {"replayId": <base64 string>, "id": <string>, "schemaId": <string>},
    "payload":  {<decoded Avro record>},
}
```

The CometD streaming API delivers `{"event": {"replayId": ...}, "payload": {...}}`, and mappers
written against it — including the Qorus `crm-to-erp` demo's, which reads
`payload.ChangeEventHeader.recordIds` and `event.replayId` — port with no change of shape. The one
unavoidable difference is that the Pub/Sub replay ID is opaque `bytes` rather than a monotonic
integer, so `event.replayId` is a base64 string and must be treated as an opaque token.

### The vendored proto is a file, not a string constant

`pubsub_api.proto` is vendored verbatim from `forcedotcom/pub-sub-api` under **CC0-1.0** and loaded
from disk with `get_script_dir()`. This is the first `.proto` resource in either tree, so the
`*.proto` resource globs added to `cmake/QoreMacros.cmake` in qore `4f3b67d80` were untested; a
staged install (`DESTDIR=<tmp> cmake --install build`) confirms the file lands both next to the AOT
`.qmod` in `lib64/qore-modules/SalesforcePubSubDataProvider/` and next to the source `.qm` in
`share/qore-modules/SalesforcePubSubDataProvider/`, so `get_script_dir()` finds it either way.

Embedding it as a string constant would have repeated the `FlightProto.qc` workaround this change
exists to stop.

## A TLS gap in `GrpcChannel`, fixed here

`GrpcChannel` set `accept_all_certs` for any `https` target unless `opts.ssl.root_certs` was set —
and it never passed `root_certs` to the connection manager, so that option only ever acted as a flag
that turned on verification against the system CA store. Talking to `api.pubsub.salesforce.com` over
that channel would have accepted any certificate.

`GrpcSslOptions` therefore gained `verify_mode`, honoured by `GrpcChannel` and set to
`SSL_VERIFY_PEER` by `SalesforcePubSubClient` for any `https` endpoint. The permissive default is
unchanged for existing callers, which is what a local test server needs.

That `root_certs` is accepted but never installed remains a separate `GrpcChannel` defect and is not
addressed here.

## Not implemented

- **`Publish` / `PublishStream`** — this is an event *source*; the providers are `DPAT_EVENT` only.
  `GetTopic` is implemented because it yields a channel's schema ID without opening a subscription,
  which is what gives an introspected provider real field names.
- **`ManagedSubscribe`** — an open beta API whose replay position is committed server-side. It is a
  different state machine and the client-managed replay position is what this replaces.

## Testing

`test/salesforce-pubsub.qtest` — the CI loop globs `test/*.qtest` at the top level only, so a suite
in a subdirectory would not run.

Everything runs against a local gRPC server built on this module's own `GrpcServer`, serving
`eventbus.v1` from the vendored proto, with Avro payloads produced by the builtin `avro` module —
encode-ours / decode-theirs, the same cross-check the avro suites use. Each `Subscribe` connection
consumes a script of steps (`send`, `expect_request`, `throw`, `park`), which is deterministic
because the client only ever writes a `FetchRequest` in response to something: the opening request,
a replenishment triggered by a reported credit level, or the backstop deadline.

Covered: the vendored proto and its resource file; channel-name mapping; the three metadata headers
on the wire; the schema cache including its bound and a failed lookup; the Avro round trip including
a `["null", T]` branch; the opening request's topic and replay position and their absence from later
ones; every replay preset's wire value; a keepalive read as liveness with no event raised and the
stream still open; delivery-driven replenishment topping up by the deficit; the backstop firing under
manual flow control; replay resume after a mid-stream failure; recovery from a corrupt replay ID;
token refresh on `UNAUTHENTICATED` and its absence on other failures; the idle bound detecting a
dead stream; reconnection disabled and the attempt limit; `stop()` idempotence; option validation;
channel enumeration and the summary info; the event types and example data; and the action
registration.

**Nothing has been exercised against a live Salesforce org** — the `salesforce` connection on the
development machine has an expired OAuth token. Specifically unverified against a real org: that
`describeGlobal` lists exactly the subscribable channels for every org shape, the real
`ChangeEventHeader` field set, and the actual behaviour of a Salesforce-side replay-ID expiry.

The REST round trip behind channel enumeration is substituted in the test (the `describeGlobal`
response is scripted); everything below it — the channel filter, the child names, the summary info
and the child providers — is the real implementation.
