# Salesforce Pub/Sub API event source

Status: **proposed**, not started.

Delivered as **two parallel tracks in separate repositories**, converging at activation:

- **Track 1 — qore repo**: the `%try-child-module` parse directive, which lets a base module declare
  optional child modules that the loader attaches once the base is fully published. Not specific to
  this provider; see § *Extending a base module from another repository*.
- **Track 2 — this repo**: the Avro codec, the Pub/Sub client and the event data providers.

Neither track blocks the other until the final step. See § *Work breakdown*.

References — this design follows them and does not restate their rules:

- `~/src/qore/git/qore/design/data-provider-development-guide.md` (§ *Event Providers*, § *Common Pitfalls*)
- `~/src/qore/git/qore/design/data-provider-checklist.md` (§ 9 *Event/Observable Providers*, § *App Icon Convention*)
- `~/src/qore/git/qore/design/qore-module-structure.md`

## Why

Qorus solutions that react to Salesforce changes depend on `BBM_SalesforceStreamBase`, a
building-block class speaking the Salesforce **CometD / Bayeux** streaming API over HTTP
long-polling. It is the last thing tying the Qorus demos repository to the `building-blocks`
submodule, and CometD is the transport Salesforce is steering integrations away from in favour of the
**Pub/Sub API** (gRPC + Avro).

There is no Bayeux implementation anywhere in the Qore module ecosystem, so replacing the building
block means either writing one or moving to Pub/Sub. Pub/Sub is the better target: this module
already provides the transport.

## What already exists

**The consuming side is complete — no Qorus change is required.**
`Classes/LocalQorusService.qc` in the Qorus repository already binds a data provider `DPAT_EVENT`
action to an FSM and drives the delayed-start handshake a streaming connection needs:

```qore
ServiceEventObserver observer(self, prov, event_source_name, {
    action.action_val: {"type": "fsm", "value": fsm_info.name, "fsmid": fsmid},
});
DataProvider::Observable observable = cast<DataProvider::Observable>(prov);
observable.registerObserver(observer);
if (observable instanceof DataProvider::DelayedObservable) {
    init_observers = True;          // -> observersReady() once all observers are attached
}
```

An event data provider published from this module therefore becomes a Qorus service event source that
triggers a Qog, with nothing further to build on the Qorus side.

The producing side is most of the way there:

| Piece | Where | Note |
|---|---|---|
| Dynamic `.proto` loading, protobuf encode/decode | `grpc.so` (`src/`, C++ over `libprotobuf`) | no code generation |
| gRPC client, all four call patterns incl. bidirectional | `qlib/GrpcUtil` — `GrpcClient::call()`, `serverStream()`, `clientStream()` | pure Qore over Qore's HTTP/2 stack |
| A concrete service client layered on `GrpcClient` | `qlib/ArrowFlightDataProvider` — `ArrowFlightClient` | template for the Salesforce client |
| A `DelayedObservable` event provider over a gRPC stream | `qlib/GrpcDataProvider/GrpcStreamEventDataProvider.qc` | **template for this work** |

`GrpcStreamEventDataProvider` already has the required shape — `observersReady()` starts the stream,
`setObserverRequest()` supplies the opening request, `sendMessage()` writes to a bidirectional
stream, and `notifyObservers()` emits `EVENT_GRPC_STREAM_MESSAGE` / `_ERROR` / `_COMPLETE`. Salesforce
`Subscribe` is a bidirectional stream where the client sends `FetchRequest` messages for flow control
and receives `FetchResponse` batches, which maps onto that without inventing anything.

## The gap: Avro

Pub/Sub payloads are **Avro binary datum** encoded against a writer schema fetched at runtime by
schema ID through the API's own `GetSchema` RPC. Decoding needs raw datum decode against a
runtime-supplied schema, plus schema resolution and caching by ID.

The only Avro support in the ecosystem is `qlib/AvroDataProvider` in **module-jni**: Java-backed
(Apache Avro Java library), exposing `avroread` and `avrowrite`. It is container-file oriented, so it
cannot decode a bare datum against a supplied schema, and it would put a JVM in the hot path of a
long-lived subscription. It is the wrong tool here.

### Where generic Avro support should live

The open architectural decision; settle it before implementation starts.

**Recommendation: implement the Avro codec in this module's binary layer, published as its own
directory module under `qlib/Avro/` so it can be loaded without gRPC.**

Reasoning:

- This module is already the de-facto wire-format module: it hosts protobuf (C++ over `libprotobuf`)
  and Arrow IPC (`QC_ArrowIpc`, `QC_ArrowSchema`, `QC_ArrowRecordBatch`). Avro is the same kind of
  thing and the C++ QPP plus pure-Qore-wrapper pattern is established here.
- The near-term consumer is Salesforce Pub/Sub, which lives here anyway. A separate repository up
  front means a new CI pipeline, GitLab mirror, packaging and release cadence for one caller.
- A separate **directory module** (`qlib/Avro/Avro.qm` per `qore-module-structure.md` § *Directory
  Modules*, registered with its own `qore_external_user_module("qlib/Avro" "")`) means consumers get
  Avro without pulling in gRPC, and the codec can be extracted to `module-avro` later without
  breaking anyone's `%requires`.

The cost, stated plainly: Avro has nothing to do with gRPC and the repository name will misdescribe
its contents. If Avro is judged a first-class format deserving its own home, a standalone
`module-avro` is cleaner and nothing else in this design changes — only the codec's location.

Rejected alternatives: a pure-Qore decoder (feasible — varint/zigzag with block framing — but slower
and schema resolution is fiddly), and extending module-jni's provider (JVM in a streaming path,
file-oriented).

## Design

### Layering

```
qlib/SalesforcePubSubDataProvider/     events container + per-event providers (DPAT_EVENT)
        |
SalesforcePubSubClient                 Subscribe/GetSchema/GetTopic/Publish, replay + schema cache
        |
GrpcClient  (qlib/GrpcUtil)            bidirectional streaming over HTTP/2
        |
ProtobufSchema (grpc.so)               pubsub_api.proto loaded at runtime
qlib/Avro                              decodes FetchResponse event payloads
```

### Provider structure

Per the dev guide's § *Event Providers*, this is an **events container with child event providers**,
not a single ad-hoc provider:

- **`SalesforcePubSubEventsDataProvider`** — the container.
  `ProviderInfo` carries `"supports_children": True` and `"children_can_support_observers": True`;
  `getChildProviderNamesImpl()` returns the subscribable channels; `getChildProviderImpl()`
  constructs the child **without passing options**.

- **`SalesforcePubSubEventDataProvider`** — one per channel,
  `inherits SalesforcePubSubDataProviderBase, DelayedObservable`, `ProviderInfo` carrying
  `"supports_observable": True`.

The conventions that bind, and that are easy to get wrong here:

- **Options must be optional types** (`*string`, never `string`) and are read from context inside
  `observersReady()` via `DataProviderDataContextHelper::getHash()` — event providers are reached by
  path navigation without constructor options.
- **`observersReady()` opens the subscription**, nothing earlier. A provider merely introspected in
  the UI must not consume a Salesforce subscription slot.
- **`getEventTypesImpl()`** returns `hash<string, hash<DataProviderMessageInfo>>`, each entry with
  `desc` and `type`. The record type is derived from the channel's Avro schema so a Qog shows real
  field names.
- **`getExampleEventDataImpl()` must be implemented**, not inherited: try real API data first inside
  try/catch, then fall back to fake data with resource-specific fields — not a generic
  `{id, created_time}` stub.
- **No hardcoded OAuth2 or endpoint URLs.** The dev guide names Salesforce explicitly under *Common
  Pitfalls*: regional and sandbox orgs differ, so URLs are built from a domain/instance option.
  Hardcoding `login.salesforce.com` breaks every sandbox and non-US org.
- **App icon**: a square SVG stored as a separate file in the module directory, loaded at module level
  with `File::readTextFile(get_script_dir() + "/…")` and declared `public const` for `registerApp()`.
  `qore/qlib/SalesforceRestDataProvider/salesforce-logo.svg` exists; check it is square before reuse.

### Client

`SalesforcePubSubClient`, modelled on `ArrowFlightClient`:

- `subscribe(channel, replay_options)` → a `GrpcClientStream`, sending `FetchRequest` messages for
  flow control and yielding decoded events.
- `getSchema(schema_id)` with an in-process cache — schema IDs repeat constantly and every miss is a
  round trip.
- `getTopic(channel)`, and `publish()` for completeness.
- **Replay handling**: track the last replay ID per subscription so a reconnect resumes rather than
  restarts. This is what `BBM_SalesforceStreamBase` provides and the main thing a replacement must
  not lose.
- Reconnect with backoff on stream error, resuming from the stored replay ID; emit a distinct event
  type on unrecoverable failure so a solution can alert on it.

### Extending a base module from another repository

This provider extends `SalesforceRestDataProvider`, which lives in the **qore** repository, from the
**module-grpc** repository. The two release independently, so how the extension attaches is a design
decision in its own right — and the mechanism today is only half formal.

**What the framework provides.** `AbstractDataProvider::registerChild(string name, code generator)`
exists as a static, but its default implementation throws `UNSUPPORTED-ERROR` with the instruction to
override it. It is a convention hook, not a mechanism: **27 modules under `qore/qlib` already
override it**, each carrying its own child-map bookkeeping, and each free to choose its own
duplicate-handling policy — Aftership throws on a repeat registration, Salesforce silently
overwrites. That duplication is itself an argument for formalising the pattern.

**Good news for this design:** `SalesforceRestDataProvider` already implements it
(`SalesforceRestDataProvider.qc:89`, storing into `dynamic_children`) and already declares
`"children_can_support_observers": True`. **No change to the qore repository is needed to attach the
event providers.**

**The Qorus precedent — push.** `QorusOpenAiServices`, `QorusDiscordServices`, `QorusGoogleServices`
and `QorusSlackServices` extend open base modules with proprietary functionality. The pattern is:

```qore
%requires(reexport) OpenAiDataProvider

module QorusOpenAiServices {
    init = sub () {
        OpenAiDataProvider::registerChild("eval-bool", Class::forName("OpenAiEvalBoolDataProvider"));
        DataProviderActionCatalog::registerAction(<DataProviderActionInfo>{
            "app": OpenAiDataProvider::AppName,   # attaches to the BASE app, not a new one
            "path": "/eval-bool",
            ...
        });
    }
}
```

The extender depends on the base; the base knows nothing about extenders. That direction is right and
should be preserved — it is what lets a proprietary module extend an open one.

**The gap — activation.** Push registration only happens if something loads the extender. Nothing
does unless a solution names it explicitly, so extension actions are silently absent rather than
diagnosably missing. The fix is to invert *activation* while keeping the dependency direction: let
the base pull the extender in. The question is *when* it can do so, because the extender's first act
is to call back into the base.

Three mechanisms were tested with a minimal base/extender module pair. Only the third works.

| Mechanism | Result |
|---|---|
| `%try-module Ext` in the base | **fails** — parse time, far too early |
| `load_module("Ext")` in the base's `init` closure | **fails** — `PARSE-EXCEPTION: cannot find any namespace or class 'TestBase' in 'TestBase::trace'` |
| `load_module("Ext")` lazily on first use, after the base has finished loading | **works** |

The middle result is the important one and is not obvious: a module's own `init` closure is still too
early. The base's public classes are not published to a module loaded from within that closure, so
the extender fails to *parse* — `%requires(reexport) TestBase` resolves, but `TestBase::anything`
does not. The failure surfaces inside the base's `init`, where a `try`/`catch` intended to make the
extension optional will swallow it, and the extension silently disappears.

Reproduce with two modules — base:

```qore
module TestBase {
    init = sub () {
        try {
            load_module("TestExt");          # too early: TestExt cannot parse
        } catch (hash<ExceptionInfo> ex) {
            TestBase::trace += sprintf("%s: %s", ex.err, ex.desc);
        }
    };
}
public class TestBase {
    public { static hash<string, code> children; }
    static registerChild(string name, code generator) { children{name} = generator; }
}
```

and extender:

```qore
%requires(reexport) TestBase
module TestExt {
    init = sub () { TestBase::registerChild("from-ext", sub (string name) {}); };
}
```

Two mechanisms follow. **`%try-child-module` (Option B) is the chosen solution and is being built in
parallel in the qore repository** — see § *Work breakdown*, Track 1. Option A is documented as the
fallback that works with an unmodified Qore, so this provider is never blocked on the directive
landing.

**Option A — lazy activation (fallback; works today, no Qore change).** The base loads its extenders on first
use, guarded once-only, from a point at which it is fully loaded:

```qore
public class SalesforceRestDataProvider inherits ... {
    public {
        const ExtensionModules = ("SalesforcePubSubDataProvider",);
        static bool extensions_loaded = False;
    }

    static ensureExtensions() {
        if (extensions_loaded) {
            return;
        }
        extensions_loaded = True;
        foreach string mod in (ExtensionModules) {
            try {
                load_module(mod);
            } catch (hash<ExceptionInfo> ex) {
                # extension not installed; log rather than swallow silently
            }
        }
    }

    private *list<string> getChildProviderNamesImpl() {
        ensureExtensions();
        ...
    }
}
```

Its limitation is real: activation is tied to something calling a provider method. Anything that reads
`DataProviderActionCatalog` without first touching the provider — enumerating an app's actions in the
UI, for instance — will not see the extension's actions. It also puts a check on a hot path and needs
the same boilerplate in every extensible base.

**Option B — a `%try-child-module` parse directive (chosen; Track 1, built in parallel).** The parent
declares its optional children, and the module loader loads and initialises each present child
**automatically, after the parent is fully loaded and published** — strictly after the parent's `init`
has run, which the test above shows is the necessary ordering:

```qore
# in SalesforceRestDataProvider.qm
%try-child-module SalesforcePubSubDataProvider
```

Semantics, following the `%try-module` mental model but inverting the relationship:

- **child absent** → no error, no diagnostic; the parent works exactly as before;
- **child present** → loaded and initialised after the parent is published, at which point its
  `registerChild()` / `registerAction()` calls resolve normally;
- **child present but broken** → an error, surfaced. This is the distinction Option A cannot make:
  a `try`/`catch` around `load_module()` cannot tell "not installed" from "installed and failing to
  parse", so a real bug in an extension disappears silently. Splitting the directive from the failure
  path fixes that by construction.

This removes the hot-path check, activates extensions whether or not a provider method is ever called,
and reads declaratively at the top of the parent. Points still to settle in the implementation:

- **ordering** — declaration order for multiple children, and children that themselves declare
  children;
- **cycles** — two modules naming each other as children must be detected rather than recursing;
- **sandboxing** — `load_module()` carries the `MODULES` functional domain, so the directive must
  define its behaviour under `PO_NO_MODULES`; Qorus parses interface code with restricted parse
  options, and a parent that cannot load children there should degrade predictably;
- **visibility** — whether the loaded set is introspectable, so a missing action can be diagnosed by
  asking which children attached rather than by guesswork.

This is work in the **qore** repository, tracked as Track 1 in § *Work breakdown* and scheduled
alongside the provider rather than after it. It turns extension from a per-module convention into a
supported language-level pattern, and would let `QorusOpenAiServices`, `QorusDiscordServices`,
`QorusGoogleServices` and `QorusSlackServices` drop their explicit-load requirement as well — so its
value is not limited to this provider, which is the reason for doing it now rather than deferring it.

**Worth formalising, beyond activation.** `%try-child-module` fixes *when* extensions load. Three
further gaps in the current convention are independent of it and remain open: the per-module
duplicate/conflict policy noted above; the absence of any way to ask which modules extend a given
app, which makes a missing action hard to diagnose; and the fact that child registration and action
registration are two unconnected steps, with nothing checking that an action's `path` resolves to a
registered child. This provider is a reasonable first consumer to design those against.

### Authentication

Salesforce Pub/Sub authenticates with metadata headers carrying an access token, instance URL and
tenant ID rather than a normal `Authorization` header. `qore/qlib/SalesforceRestClient.qm` already
performs the OAuth2 flow and holds the access token and instance URL, so the client should accept a
`SalesforceRestClient` (or its connection) and derive the metadata from it — no second connection
type, no re-implemented authentication, and the existing `salesforce` connection gains event actions.

Design for token expiry: a long-lived subscription must refresh the token and re-establish the stream
without losing its replay position.

## Work breakdown

Two tracks run **in parallel**, in separate repositories, and are independent until they converge at
activation.

### Track 1 — qore repo: `%try-child-module`

| # | Item | Depends on |
|---|---|---|
| Q1 | `%try-child-module` parse directive: parse, record the declaration, defer the load | — |
| Q2 | Loader support: load and initialise declared children after the parent is fully published | Q1 |
| Q3 | Failure policy — absent child silent, present-but-broken child raises | Q2 |
| Q4 | Ordering, cycle detection, `PO_NO_MODULES` behaviour, introspection of what attached | Q2 |
| Q5 | Tests, `doxygen/lang/245_parse_directives.dox.tmpl` entry, release notes | Q1–Q4 |

### Track 2 — this repo: the Pub/Sub event source

| # | Item | Depends on |
|---|---|---|
| 1 | Avro schema parsing + binary datum decode, tests against known vectors | — |
| 2 | Avro encode (needed only for `publish()`) | 1 |
| 3 | Avro → `AbstractDataProviderType` mapping (as `GrpcTypeHelper` does for protobuf) | 1 |
| 4 | `pubsub_api.proto` vendored, loaded via `ProtobufSchema` | — |
| 5 | `SalesforcePubSubClient`: auth metadata, `GetSchema` + cache, `Subscribe` with flow control | 1, 4 |
| 6 | Replay-ID tracking and resume-on-reconnect | 5 |
| 7 | Events container + event providers, `DPAT_EVENT` registration, `registerApp()` with square logo | 3, 5 |
| 8 | `qore_external_user_module()` entries, docs targets, `@section …intro` mainpage sections | 7 |

### Convergence

| # | Item | Depends on |
|---|---|---|
| C1 | Add `%try-child-module SalesforcePubSubDataProvider` to `SalesforceRestDataProvider.qm` (qore repo) | Q3, 7 |
| C2 | Port the Qorus `crm-to-erp` demo off `BBM_SalesforceStreamBase` | C1 |

Nothing in Track 2 blocks on Track 1: items 1–8 build and test with the provider loaded explicitly.
Only C1 needs the directive. If Track 1 slips, C1 can ship against the lazy-activation fallback
(§ *Extending a base module* Option A) and be switched to the directive afterwards without touching
the provider — the registration side is identical either way.

Items 1–3 are the bulk of Track 2, are independent of Salesforce, and are the part that moves if Avro
gets its own repository.

Module registration follows `qore-module-structure.md`: directory modules, the `.qm` inside its own
directory, one `qore_external_user_module("qlib/<Name>" "Deps")` call per module — which handles
installation and the `docs-<Name>` target — and a `@section <lowercasemodname>intro` heading opening
each mainpage (`avrointro`, `salesforcepubsubdataproviderintro`).

## Verify before implementing

My knowledge of the Salesforce API surface may be stale; check these against current Salesforce
documentation rather than taking them from this document:

- the Pub/Sub endpoint host and port, and whether TLS needs anything beyond `GrpcClient` defaults;
- the canonical source and licence of `pubsub_api.proto`, and whether vendoring is acceptable or it
  should be fetched at build time;
- the exact metadata header names for access token, instance URL and tenant ID;
- replay semantics, including the retention window and the meaning of each replay preset;
- flow control — how many events a `FetchRequest` should request and how the server signals more are
  pending;
- whether Change Data Capture, Platform Events and PushTopic-equivalent channels all arrive through
  the same `Subscribe` RPC or need distinct handling.

Not verified locally: this machine's `salesforce` connection has an expired OAuth token, so no part
of this design has been exercised against a live org.

## Testing

Per `qore-module-structure.md` § *Tests*:

- **Avro codec** — unit tests with fixed schema/datum vectors covering records, unions (notably
  `["null", T]`), enums, arrays, maps, `bytes`, `string`, `long`/`int`, `boolean`, `double`/`float`
  and logical types for dates, timestamps and decimals; plus negative tests for truncated input,
  unknown union branches and schema mismatch. No network required.
- **Client** — against a local gRPC server built with this module's own server support, serving a stub
  `pubsub.PubSub` implementation from the vendored proto. Keeps the bulk of the suite offline and
  deterministic, matching the existing gRPC tests.
- **Live org** — one test skipped gracefully when credentials are absent, following the `%try-module`
  graceful-skip convention.
- **Integration** — the Qorus `crm-to-erp` demo is the end-to-end consumer.

Work through `data-provider-checklist.md` § 9 before calling the provider done.

## What this unblocks

`BBM_SalesforceStreamBase` is the only building-block class with no Qorus-native equivalent. The other
eleven still used by the Qorus demos (`BBM_CreateOrder`, `BBM_DataProviderRequest`,
`BBM_DataProviderSearch`, `BBM_GenericMapper`, `BBM_GetArray`, `BBM_GetData`, `BBM_InternalIterator`,
`BBM_OutputData`, `BBM_AutoMapper`) map onto data provider requests, Qog states and mappers — the same
substitutions already made in the `erp` and `telco-om` demos. Delivering this removes the last blocker
to retiring the submodule.
