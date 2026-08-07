# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubSubscription.qc Salesforce Pub/Sub subscription state machine

/*  SalesforcePubSubSubscription.qc Copyright 2026 Qore Technologies, s.r.o.

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

namespace Priv {

#! One-shot delay armed on the async I/O controller's timeout heap
/** The controller has no standalone timer API, but an operation that waits on an
    \c EventNotifier and returns a \c poll_timeout_ms is woken by the
    timeout heap when the deadline comes due.  Nothing ever signals the notifier except
    @ref cancel(), so the operation costs no thread while it waits and cancellation is immediate
    rather than "wait for the deadline and then notice".

    This is what lets a reconnect backoff be a real deadline instead of a sleeping thread.
*/
class SalesforcePubSubDelay inherits Qore::AbstractPollOperation<auto> {
    private {
        #! The notifier the operation waits on; signaled only to cancel
        EventNotifier notifier;

        #! Absolute deadline in epoch microseconds
        int deadline_us;

        #! Called on a callback worker when the deadline comes due
        code<nothing()> callback;

        #! State lock
        Mutex m();

        #! True once the operation has reached a terminal state
        bool complete = False;

        #! True once cancellation has been requested
        bool cancelled = False;
    }

    #! Creates the delay
    /** @param notifier the notifier to wait on; must not be signaled by anything else
        @param delay how long from now the deadline comes due
        @param callback called once when the deadline comes due, unless cancelled first
    */
    constructor(EventNotifier notifier, timeout delay, code<nothing()> callback) {
        self.notifier = notifier;
        deadline_us = clock_getmicros() + delay * 1000;
        self.callback = callback;
    }

    #! Goal label for this operation
    string getGoal() {
        return "salesforce-pubsub-delay";
    }

    #! Current state label
    string getState() {
        return complete ? "complete" : "waiting";
    }

    #! Returns True once the delay has fired or been cancelled
    bool goalReached() {
        AutoLock al(m);
        return complete;
    }

    #! Requests cancellation and wakes the operation immediately
    cancel() {
        {
            AutoLock al(m);
            if (complete) {
                return;
            }
            cancelled = True;
        }
        notifier.notify();
    }

    #! Re-arms the notifier wait, or fires the callback once the deadline has come due
    *hash<SocketPollInfo> continuePoll() {
        {
            AutoLock al(m);
            if (complete) {
                return NOTHING;
            }
            notifier.acknowledge();
            if (cancelled) {
                complete = True;
                return NOTHING;
            }
        }

        int remaining_us = deadline_us - clock_getmicros();
        if (remaining_us <= 0) {
            {
                AutoLock al(m);
                if (complete) {
                    return NOTHING;
                }
                complete = True;
            }
            callback();
            return NOTHING;
        }

        return <SocketPollInfo>{
            "socket": notifier,
            "events": SOCK_POLLIN,
            "poll_timeout_ms": (remaining_us + 999) / 1000,
        };
    }

    #! Called when the controller aborts the operation
    abort() {
        AutoLock al(m);
        complete = True;
    }

    #! Called when the controller completes the operation
    onComplete(hash<SocketPollResultInfo> result) {
        AutoLock al(m);
        complete = True;
    }
}

} # namespace Priv

#! A Salesforce Pub/Sub subscription to a single channel
/** Wraps the \c Subscribe bidirectional stream and owns everything a long-lived subscription has
    to get right and that the CometD building block it replaces already provided: the replay
    position, flow control, keepalive interpretation, token refresh and reconnection.

    @par Flow control
    \c FetchRequest.num_requested grants the server credit to deliver events, capped at
    @ref MaxNumRequested per request and accumulated server-side.  Each \c FetchResponse reports
    the credit remaining as \c pending_num_requested.  Once that reaches zero the server closes
    the stream unless a new \c FetchRequest arrives within 60 seconds.

    Replenishment here is **driven by delivery**: the request goes out from the response handler
    as soon as the reported credit falls to @ref low_water_mark, not when a timer notices.  The
    60 second window is a backstop armed on the controller's timeout heap only while the client
    believes it has no credit left, so a healthy subscription arms no timer at all.

    @par Keepalive
    An empty \c FetchResponse is not end-of-stream: it is the server's periodic liveness signal,
    sent within 270 seconds, and it carries an updated \c latest_replay_id.  Silence beyond that
    bound means the stream is dead even though the transport has not noticed, which is what
    \c idle_timeout_ms detects.

    @par Replay
    \c replay_preset and \c replay_id are consumed only from the first \c FetchRequest of a
    stream, so changing position means a new \c Subscribe call.  Every consumed event's replay ID
    is recorded, so a reconnect resumes after the last event actually delivered to observers
    rather than restarting.  Replay IDs are retained by Salesforce for 72 hours; an expired or
    corrupt ID is reported as @ref ReplayIdCorruptedError, whose only recovery is to fall back to
    the configured starting preset.

    @par Example
    @code{.py}
SalesforcePubSubSubscription subscr = client.subscribe("/data/AccountChangeEvent", {
    "on_event": sub (hash<auto> event) { printf("%y\n", event); },
});
subscr.start();
on_exit subscr.stop();
    @endcode

    @section salesforcepubsubsubscription_options Subscription Options

    |!Option|!Type|!Default|!Description
    |\c on_event|\c code|-|called with each delivered event
    |\c on_keepalive|\c code|-|called with each empty \c FetchResponse
    |\c on_failure|\c code|-|called once when the subscription gives up
    |\c replay_preset|\c string|@ref ReplayLatest|starting position
    |\c replay_id|\c string|-|base64 replay ID for @ref ReplayCustom
    |\c num_requested|\c int|@ref DefaultNumRequested|flow-control window
    |\c low_water_mark|\c int|@ref DefaultLowWaterMark|credit level triggering replenishment
    |\c auto_replenish|\c bool|@ref True|replenish credit automatically on delivery
    |\c flow_control_backstop_ms|\c int|@ref DefaultFlowControlBackstopMs|backstop deadline
    |\c idle_timeout_ms|\c int|@ref DefaultIdleTimeoutMs|inactivity bound
    |\c reconnect|\c bool|@ref True|reconnect after a stream failure
    |\c reconnect_delay_ms|\c int|@ref DefaultReconnectDelayMs|initial backoff
    |\c max_reconnect_delay_ms|\c int|@ref DefaultMaxReconnectDelayMs|backoff ceiling
    |\c max_reconnect_attempts|\c int|\c 0|consecutive failures tolerated; \c 0 = unlimited
*/
public class SalesforcePubSubSubscription {
    private {
        #! The Pub/Sub client
        SalesforcePubSubClient client;

        #! The topic name being subscribed to
        string topic_name;

        #! Called with each delivered event
        *code<nothing(hash<auto>)> on_event;

        #! Called with each empty \c FetchResponse
        *code<nothing(hash<auto>)> on_keepalive;

        #! Called once when the subscription gives up
        *code<nothing(hash<auto>)> on_failure;

        #! The starting replay preset configured by the caller
        string replay_preset = ReplayLatest;

        #! The starting replay ID configured by the caller, as base64
        *string start_replay_id;

        #! The flow-control window: the credit the client keeps granted
        int num_requested = DefaultNumRequested;

        #! The credit level at or below which replenishment is triggered
        int low_water_mark = DefaultLowWaterMark;

        #! If True, credit is replenished automatically as events are delivered
        bool auto_replenish = True;

        #! The flow-control backstop deadline in milliseconds
        int flow_control_backstop_ms = DefaultFlowControlBackstopMs;

        #! The stream inactivity bound in milliseconds
        int idle_timeout_ms = DefaultIdleTimeoutMs;

        #! If True, a failed stream is re-established
        bool reconnect = True;

        #! The initial reconnect backoff in milliseconds
        int reconnect_delay_ms = DefaultReconnectDelayMs;

        #! The reconnect backoff ceiling in milliseconds
        int max_reconnect_delay_ms = DefaultMaxReconnectDelayMs;

        #! Consecutive reconnect failures tolerated; 0 means unlimited
        int max_reconnect_attempts = 0;

        #! State lock
        Mutex m();

        #! Signals state changes
        Condition cond();

        #! The current stream, while one is open
        *GrpcAsyncClientStream stream;

        #! The replay ID of the last event delivered to observers
        *binary last_replay_id;

        #! The client's view of the credit the server still holds
        int outstanding = 0;

        #! True once @ref start() has been called
        bool started = False;

        #! True once @ref stop() has been called
        bool stopping = False;

        #! True while a stream is open and has not reached a terminal state
        bool connected = False;

        #! True once the subscription has given up
        bool finished = False;

        #! Consecutive reconnect failures
        int reconnect_attempts = 0;

        #! True while the flow-control backstop is armed
        bool backstop_armed = False;

        #! True once the current stream has delivered a response
        /** A stream that opens and then fails without ever answering is not a working
            subscription, so the reconnect attempt counter is cleared by the first response rather
            than by a successful connect: otherwise a server that accepts the stream and then
            immediately drops it resets the counter on every attempt and reconnects forever.
        */
        bool stream_healthy = False;

        #! The pending reconnect delay, if any
        *Priv::SalesforcePubSubDelay reconnect_delay;

        #! The notifier owned by the pending reconnect delay
        *EventNotifier reconnect_notifier;

        #! True if the next connection attempt must refresh the access token first
        bool refresh_token_on_reconnect = False;

        #! Number of events delivered to observers
        int event_count = 0;

        #! Number of empty (keepalive) responses received
        int keepalive_count = 0;

        #! Number of \c FetchRequest messages sent
        int fetch_request_count = 0;

        #! Number of times the stream has been re-established
        int reconnect_count = 0;

        #! Number of times the flow-control backstop has fired
        int backstop_count = 0;

        #! The last error seen, whether recovered from or not
        *hash<auto> last_error;
    }

    #! Creates the subscription
    /** The subscription is inert until @ref start() is called.

        @param client the Pub/Sub client
        @param topic_name the topic name, for example \c "/data/AccountChangeEvent"
        @param opts subscription options; see @ref salesforcepubsubsubscription_options

        @throw SALESFORCE-PUBSUB-ERROR an option value is invalid
    */
    constructor(SalesforcePubSubClient client, string topic_name, *hash<auto> opts) {
        self.client = client;
        self.topic_name = topic_name;

        on_event = opts.on_event;
        on_keepalive = opts.on_keepalive;
        on_failure = opts.on_failure;

        if (opts.replay_preset.val()) {
            if (!ReplayPresets.contains(opts.replay_preset)) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("invalid \"replay_preset\" %y; expecting "
                    "one of %y", opts.replay_preset, ReplayPresets);
            }
            replay_preset = opts.replay_preset;
        }
        if (opts.replay_id.val()) {
            start_replay_id = opts.replay_id;
            # a replay ID is only meaningful with the CUSTOM preset; supplying one and leaving the
            # preset at its default would silently start at the tip instead
            if (replay_preset == ReplayLatest) {
                replay_preset = ReplayCustom;
            }
        }
        if (replay_preset == ReplayCustom && !start_replay_id.val()) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("replay preset %y requires a \"replay_id\"",
                ReplayCustom);
        }
        if (exists opts.num_requested) {
            if (opts.num_requested < 1 || opts.num_requested > MaxNumRequested) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("\"num_requested\" must be between 1 and "
                    "%d; got %y", MaxNumRequested, opts.num_requested);
            }
            num_requested = opts.num_requested;
        }
        if (exists opts.low_water_mark) {
            if (opts.low_water_mark < 0 || opts.low_water_mark >= num_requested) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("\"low_water_mark\" must be at least 0 "
                    "and less than \"num_requested\" (%d); got %y", num_requested,
                    opts.low_water_mark);
            }
            low_water_mark = opts.low_water_mark;
        } else if (low_water_mark >= num_requested) {
            # keep the default consistent with a small window
            low_water_mark = num_requested - 1;
        }
        if (exists opts.auto_replenish) {
            auto_replenish = opts.auto_replenish;
        }
        if (exists opts.flow_control_backstop_ms) {
            flow_control_backstop_ms = opts.flow_control_backstop_ms;
        }
        if (exists opts.idle_timeout_ms) {
            idle_timeout_ms = opts.idle_timeout_ms;
        }
        if (exists opts.reconnect) {
            reconnect = opts.reconnect;
        }
        if (exists opts.reconnect_delay_ms) {
            reconnect_delay_ms = opts.reconnect_delay_ms;
        }
        if (exists opts.max_reconnect_delay_ms) {
            max_reconnect_delay_ms = opts.max_reconnect_delay_ms;
        }
        if (exists opts.max_reconnect_attempts) {
            max_reconnect_attempts = opts.max_reconnect_attempts;
        }
    }

    #! Copying is not supported
    private copy() {
        throw "COPY-ERROR", "SalesforcePubSubSubscription objects cannot be copied";
    }

    #! Destroys the subscription, stopping it if it is still running
    destructor() {
        stop();
    }

    #! Opens the subscription stream
    /** The Avro schema for the channel is pre-fetched here so that the first event does not have
        to fetch it from the delivery path; a failure to pre-fetch is not fatal, since the schema
        will be fetched on demand.

        @throw SALESFORCE-PUBSUB-ERROR the subscription has already been started, or the stream
        could not be opened
    */
    start() {
        {
            AutoLock al(m);
            if (started) {
                throw "SALESFORCE-PUBSUB-ERROR", "the subscription has already been started";
            }
            started = True;
        }
        prefetchSchema();
        openStream();
    }

    #! Stops the subscription
    /** Cancels any open stream and any pending reconnect; no further events are delivered and no
        reconnect is attempted.  Safe to call multiple times and from a delivery callback.
    */
    stop() {
        *GrpcAsyncClientStream s;
        *Priv::SalesforcePubSubDelay delay;
        {
            AutoLock al(m);
            if (stopping) {
                return;
            }
            stopping = True;
            # the stream cancel is asynchronous, so the terminal event that would clear this can
            # still be in flight; a stopped subscription is not connected either way
            connected = False;
            s = stream;
            delay = reconnect_delay;
            remove reconnect_delay;
            remove reconnect_notifier;
            cond.broadcast();
        }
        if (delay) {
            delay.cancel();
        }
        if (s) {
            s.cancel();
        }
    }

    #! Returns True while the subscription can still deliver events
    /** @return True until the subscription has been stopped or has given up
    */
    bool isActive() {
        AutoLock al(m);
        return started && !stopping && !finished;
    }

    #! Returns True while a stream is open
    /** @return True if a stream is open and has not reached a terminal state
    */
    bool isConnected() {
        AutoLock al(m);
        return connected;
    }

    #! Returns the replay ID of the last event delivered, as base64
    /** Store this to resume a subscription across a restart: pass it back as the \c replay_id
        option with the @ref ReplayCustom preset.

        @return the last replay ID, or @ref nothing if no event has been delivered
    */
    *string getLastReplayId() {
        AutoLock al(m);
        return last_replay_id ? make_base64_string(last_replay_id) : NOTHING;
    }

    #! Returns the topic name
    /** @return the topic name
    */
    string getTopicName() {
        return topic_name;
    }

    #! Returns subscription counters and state
    /** @return a hash with the following keys:
        - \c active: @ref True while the subscription can still deliver events
        - \c connected: @ref True while a stream is open
        - \c events: number of events delivered to observers
        - \c keepalives: number of empty responses received
        - \c fetch_requests: number of \c FetchRequest messages sent
        - \c reconnects: number of times the stream has been re-established
        - \c backstops: number of times the flow-control backstop has fired
        - \c backstop_armed: @ref True while the backstop deadline is armed
        - \c outstanding: the client's view of the credit the server still holds
        - \c replay_id: the last delivered replay ID as base64, if any
        - \c last_error: the last error seen, if any
    */
    hash<auto> getStats() {
        AutoLock al(m);
        return {
            "active": started && !stopping && !finished,
            "connected": connected,
            "events": event_count,
            "keepalives": keepalive_count,
            "fetch_requests": fetch_request_count,
            "reconnects": reconnect_count,
            "backstops": backstop_count,
            "backstop_armed": backstop_armed,
            "outstanding": outstanding,
            "replay_id": last_replay_id ? make_base64_string(last_replay_id) : NOTHING,
            "last_error": last_error,
        };
    }

    #! Sends a \c FetchRequest granting the server more credit
    /** Called automatically from the delivery path unless \c auto_replenish is disabled, in
        which case the consumer is responsible for calling it — for example after committing
        delivered events somewhere durable.

        @param count the credit to grant; defaults to topping the window back up to
        \c num_requested

        @return @ref True if a request was sent

        @throw SALESFORCE-PUBSUB-ERROR \a count is out of range
    */
    bool replenish(*int count) {
        if (exists count && (count < 1 || count > MaxNumRequested)) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("the requested count must be between 1 and "
                "%d; got %y", MaxNumRequested, count);
        }
        int req;
        {
            AutoLock al(m);
            req = count ?? (num_requested - outstanding);
            if (req < 1) {
                return False;
            }
        }
        return sendFetchRequest(req);
    }

    #! Blocks until the subscription is connected
    /** @param timeout_ms the maximum time to wait

        @return True if a stream is open, False on timeout
    */
    bool waitForConnected(timeout timeout_ms = 30s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout_ms);
        while (!connected && !stopping && !finished) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return connected;
    }

    #! Blocks until at least the given number of events has been fully processed
    /** An event is counted after the consumer has seen it and the replay position has advanced
        past it, so this is the point at which @ref getLastReplayId() and @ref getStats() reflect
        it.  A consumer callback returns before that, so waiting on delivery alone is not enough to
        observe the resulting state.

        @param count the number of events to wait for
        @param timeout_ms the maximum time to wait

        @return True if at least \a count events have been processed, False on timeout
    */
    bool waitForEvents(int count, timeout timeout_ms = 30s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout_ms);
        while (event_count < count && !stopping && !finished) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return event_count >= count;
    }

    #! Blocks until at least the given number of keepalives has been received
    /** @param count the number of empty \c FetchResponse messages to wait for
        @param timeout_ms the maximum time to wait

        @return True if at least \a count keepalives have been received, False on timeout
    */
    bool waitForKeepalives(int count, timeout timeout_ms = 30s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout_ms);
        while (keepalive_count < count && !stopping && !finished) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return keepalive_count >= count;
    }

    #! Blocks until the subscription has stopped or given up
    /** @param timeout_ms the maximum time to wait

        @return True if the subscription is no longer active, False on timeout
    */
    bool waitForDone(timeout timeout_ms = 30s) {
        AutoLock al(m);
        date deadline = now_us() + milliseconds(timeout_ms);
        while (!stopping && !finished) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return True;
    }

    #! Pre-fetches the channel's Avro schema so the delivery path starts warm
    private prefetchSchema() {
        try {
            hash<auto> info = client.getTopic(topic_name);
            if (info.schema_id.val()) {
                client.getSchema(info.schema_id);
            }
        } catch (hash<ExceptionInfo> ex) {
            # not fatal: the schema is fetched on demand from the delivery path, and GetTopic can
            # legitimately fail for a channel the org exposes but this user cannot describe
        }
    }

    #! Opens a \c Subscribe stream and sends the opening \c FetchRequest
    /** Runs on the caller's thread for the initial connection and on a transient reconnect
        thread afterwards; both are bounded setup paths, not read loops.
    */
    private openStream() {
        {
            AutoLock al(m);
            if (stopping) {
                return;
            }
            outstanding = 0;
            backstop_armed = False;
            stream_healthy = False;
        }

        GrpcAsyncClientStream s = client.getGrpcClient().bidiStreamAsync("Subscribe",
            client.getCallOptions(0), <GrpcAsyncStreamOptions>{
                "on_message": \handleResponse(),
                "on_complete": \handleComplete(),
                "on_failure": \handleFailure(),
                # an idle Pub/Sub stream is *not* healthy: the server contracts to send an empty
                # FetchResponse within 270s, so silence past that bound is a dead stream
                "idle_timeout_ms": idle_timeout_ms,
            });

        bool cancel_now;
        {
            AutoLock al(m);
            stream = s;
            connected = True;
            cancel_now = stopping;
            cond.broadcast();
        }
        if (cancel_now) {
            s.cancel();
            return;
        }

        try {
            sendFetchRequest(num_requested, True);
        } catch (hash<ExceptionInfo> ex) {
            s.cancel();
            rethrow;
        }
    }

    #! Builds and sends a \c FetchRequest
    /** @param count the credit to grant
        @param opening if True, this is the first request of the stream and carries the topic
        name and the replay position

        @return True if the request was sent
    */
    private bool sendFetchRequest(int count, bool opening = False) {
        *GrpcAsyncClientStream s;
        # hash<auto!> rather than hash<auto>: the latter narrows its value type from the first
        # entry, so adding a string key to a hash whose first value is an int is a runtime error
        hash<auto!> req;
        {
            AutoLock al(m);
            if (stopping || !connected) {
                return False;
            }
            s = stream;
            req = {"num_requested": count};
            if (opening) {
                req.topic_name = topic_name;
                # replay_preset and replay_id are consumed only from the first FetchRequest of a
                # stream; on a reconnect the stored position takes precedence over the configured
                # starting preset so that no event is delivered twice and none is skipped
                if (last_replay_id) {
                    req.replay_preset = SalesforcePubSubProto::getReplayPresetValue(ReplayCustom);
                    req.replay_id = last_replay_id;
                } else {
                    req.replay_preset = SalesforcePubSubProto::getReplayPresetValue(replay_preset);
                    if (replay_preset == ReplayCustom) {
                        req.replay_id = parse_base64_string(start_replay_id);
                    }
                }
            }
        }
        if (!s) {
            return False;
        }
        s.write(req);
        {
            AutoLock al(m);
            ++fetch_request_count;
            # credit the request optimistically: the server accumulates num_requested, and every
            # response resynchronizes this with what the server actually holds.  Without this the
            # backstop would re-send until the next response arrived, which can be 270s away.
            outstanding += count;
            if (backstop_armed) {
                backstop_armed = False;
                if (s.cancelTimer("flow-control-backstop")) {
                    # the deadline is discharged by this request
                }
            }
        }
        return True;
    }

    #! Handles a \c FetchResponse; runs on an async I/O controller callback worker
    private handleResponse(hash<auto> resp) {
        {
            AutoLock al(m);
            if (!stream_healthy) {
                # the server has answered, so this stream is a working subscription and the
                # reconnect budget starts again from here
                stream_healthy = True;
                reconnect_attempts = 0;
            }
        }

        list<auto> events = resp.events ?? ();
        if (events) {
            foreach hash<auto> ev in (events) {
                deliverEvent(ev);
                {
                    AutoLock al(m);
                    if (stopping) {
                        return;
                    }
                }
            }
        } else {
            # an empty batch is the server's keepalive, never end-of-stream; it carries the bus's
            # latest replay ID, which lets a resubscribe skip ground already covered
            hash<auto> ka;
            {
                AutoLock al(m);
                ++keepalive_count;
                if (resp.latest_replay_id) {
                    last_replay_id = resp.latest_replay_id;
                }
                cond.broadcast();
                ka = {
                    "channel": topic_name,
                    "replayId": last_replay_id ? make_base64_string(last_replay_id) : NOTHING,
                };
            }
            if (on_keepalive) {
                on_keepalive(ka);
            }
        }

        applyFlowControl(resp.pending_num_requested ?? 0);
    }

    #! Decodes one event and notifies the consumer
    private deliverEvent(hash<auto> ev) {
        *hash<auto> pe = ev.event;
        if (!pe) {
            return;
        }
        # a schema cache miss costs one synchronous GetSchema round trip on this worker; schema IDs
        # repeat for every event on a channel, so this happens once per schema version
        AvroSchema schema = client.getSchema(pe.schema_id);
        auto payload = schema.decode(pe.payload);

        hash<auto> event = {
            "channel": topic_name,
            "event": {
                "replayId": ev.replay_id ? make_base64_string(ev.replay_id) : NOTHING,
                "id": pe.id,
                "schemaId": pe.schema_id,
            },
            "payload": payload,
        };

        if (on_event) {
            on_event(event);
        }

        # the replay position advances only after the consumer has seen the event, so a reconnect
        # cannot skip an event whose delivery failed
        AutoLock al(m);
        ++event_count;
        if (ev.replay_id) {
            last_replay_id = ev.replay_id;
        }
        cond.broadcast();
    }

    #! Replenishes flow-control credit and arms the backstop if credit has run out
    private applyFlowControl(int pending) {
        bool arm;
        bool top_up;
        *GrpcAsyncClientStream s;
        {
            AutoLock al(m);
            if (stopping || !connected) {
                return;
            }
            # the server's report is authoritative; it supersedes the optimistic accounting in
            # sendFetchRequest()
            outstanding = pending;
            s = stream;
            top_up = auto_replenish && outstanding <= low_water_mark
                && outstanding < num_requested;
            arm = !outstanding && !backstop_armed;
            if (arm) {
                backstop_armed = True;
            }
        }

        if (arm && s) {
            # the 60s obligation exists only while the server holds no credit, so this deadline is
            # armed only here and is discharged by the next FetchRequest
            try {
                s.armTimer("flow-control-backstop", milliseconds(flow_control_backstop_ms),
                    \flowControlBackstop());
            } catch (hash<ExceptionInfo> ex) {
                AutoLock al(m);
                backstop_armed = False;
            }
        }
        if (top_up) {
            replenish();
        }
    }

    #! Fires when the flow-control backstop deadline comes due
    /** Reached only if the client observed zero remaining credit and no \c FetchRequest went out
        afterwards — a write that failed, or a consumer driving flow control manually.  The
        obligation is to send a request, so one is sent even if the window needs no topping up.

        @param s the stream the deadline was armed on
    */
    private flowControlBackstop(GrpcAsyncClientStream s) {
        int req;
        {
            AutoLock al(m);
            backstop_armed = False;
            if (stopping || !connected) {
                return;
            }
            ++backstop_count;
            req = num_requested - outstanding;
            if (req < 1) {
                req = 1;
            }
        }
        try {
            sendFetchRequest(req);
        } catch (hash<ExceptionInfo> ex) {
            # the stream is failing; the terminal event handles reconnection
        }
    }

    #! Handles stream completion; runs on an async I/O controller callback worker
    private handleComplete(hash<GrpcCallResult> result) {
        if (result.status_code == GRPC_STATUS_OK) {
            # the server closed the stream cleanly; for a subscription that is still a loss of the
            # subscription, so it is treated as a recoverable failure
            handleTerminal({
                "err": "SALESFORCE-PUBSUB-STREAM-CLOSED",
                "desc": "the server closed the subscription stream",
                "status_code": result.status_code,
            }, result.trailing_metadata);
            return;
        }
        handleTerminal({
            "err": sprintf("SALESFORCE-PUBSUB-GRPC-STATUS-%d", result.status_code),
            "desc": result.status_message ?? "",
            "status_code": result.status_code,
        }, result.trailing_metadata);
    }

    #! Handles a transport-level stream failure; runs on a callback worker
    private handleFailure(hash<auto> error) {
        handleTerminal({
            "err": error.err ?? "SALESFORCE-PUBSUB-STREAM-ERROR",
            "desc": error.desc ?? sprintf("%y", error),
        });
    }

    #! Common terminal-event handling: classify the failure and reconnect or give up
    private handleTerminal(hash<auto> error, *hash<auto> trailers) {
        bool give_up;
        int delay_ms;
        {
            AutoLock al(m);
            connected = False;
            remove stream;
            backstop_armed = False;
            last_error = error;
            cond.broadcast();

            if (stopping || finished) {
                return;
            }

            if (isReplayIdCorrupted(error, trailers)) {
                # the stored position is unusable and the only recovery is the configured starting
                # preset; keeping the bad ID would make every reconnect fail the same way
                remove last_replay_id;
                if (replay_preset == ReplayCustom) {
                    replay_preset = ReplayEarliest;
                    remove start_replay_id;
                }
                error.desc = sprintf("%s (the stored replay ID is no longer valid; restarting the "
                    "subscription at %s)", error.desc, replay_preset);
                last_error = error;
            }

            if (error.status_code == GRPC_STATUS_UNAUTHENTICATED) {
                refresh_token_on_reconnect = True;
            }

            if (!reconnect) {
                give_up = True;
            } else {
                ++reconnect_attempts;
                if (max_reconnect_attempts && reconnect_attempts > max_reconnect_attempts) {
                    give_up = True;
                } else {
                    delay_ms = backoffMs(reconnect_attempts);
                }
            }
            if (give_up) {
                finished = True;
            }
        }

        if (give_up) {
            deliverError(error);
            return;
        }
        scheduleReconnect(delay_ms);
    }

    #! Returns True if the error reports that the stored replay ID can no longer be used
    private static bool isReplayIdCorrupted(hash<auto> error, *hash<auto> trailers) {
        if (error.desc.typeCode() == NT_STRING && error.desc.find(ReplayIdCorruptedError) != -1) {
            return True;
        }
        return exists trailers && sprintf("%y", trailers).find(ReplayIdCorruptedError) != -1;
    }

    #! Returns the reconnect backoff for the given consecutive failure count
    private int backoffMs(int attempt) {
        int ms = reconnect_delay_ms;
        for (int i = 1; i < attempt; ++i) {
            ms *= 2;
            if (ms >= max_reconnect_delay_ms) {
                return max_reconnect_delay_ms;
            }
        }
        return ms > max_reconnect_delay_ms ? max_reconnect_delay_ms : ms;
    }

    #! Arms the reconnect backoff on the controller's timeout heap
    private scheduleReconnect(int delay_ms) {
        EventNotifier notifier();
        Priv::SalesforcePubSubDelay delay(notifier, milliseconds(delay_ms), \reconnectNow());
        {
            AutoLock al(m);
            if (stopping || finished) {
                return;
            }
            reconnect_notifier = notifier;
            reconnect_delay = delay;
        }
        try {
            AsyncSocketIo::AsyncSocketIoController controller =
                AsyncSocketIo::getGlobalAsyncIoController();
            controller.submit(<SocketPollOperationInfo>{
                "sock": notifier,
                "spop": delay,
                "owner": self.uniqueHash(),
                "key": sprintf("SalesforcePubSubDataProvider::reconnect:%s:%d", self.uniqueHash(),
                    reconnect_attempts),
                "has_on_complete": True,
                # the delay is armed per poll cycle via poll_timeout_ms
                "to": -1s,
            }, True);
        } catch (hash<ExceptionInfo> ex) {
            hash<auto> err = {
                "err": ex.err,
                "desc": sprintf("cannot schedule a reconnect for Pub/Sub channel %y: %s",
                    topic_name, ex.desc),
            };
            {
                AutoLock al(m);
                finished = True;
                last_error = err;
                remove reconnect_delay;
                remove reconnect_notifier;
                cond.broadcast();
            }
            deliverError(err);
        }
    }

    #! Called on a callback worker when the reconnect backoff comes due
    private reconnectNow() {
        {
            AutoLock al(m);
            remove reconnect_delay;
            remove reconnect_notifier;
            if (stopping || finished) {
                return;
            }
        }
        # Opening a stream is a bounded but blocking sequence -- an HTTP/2 handshake and, when the
        # token has expired, an OAuth2 round trip -- so it runs on a transient thread rather than
        # occupying a callback worker that other streams share.  Nothing parks on a read here: the
        # thread exits as soon as the stream is open.
        background reconnectIntern();
    }

    #! Re-establishes the stream; runs on a transient thread
    private reconnectIntern() {
        bool refresh;
        {
            AutoLock al(m);
            if (stopping || finished) {
                return;
            }
            refresh = refresh_token_on_reconnect;
            refresh_token_on_reconnect = False;
        }
        try {
            if (refresh) {
                # a refresh also re-reads instance_url, so an org moved to another instance is
                # followed without losing the replay position
                client.refreshToken();
            }
            openStream();
            AutoLock al(m);
            ++reconnect_count;
            cond.broadcast();
        } catch (hash<ExceptionInfo> ex) {
            handleTerminal({
                "err": ex.err,
                "desc": sprintf("cannot re-establish the subscription to Pub/Sub channel %y: %s",
                    topic_name, ex.desc),
            });
        }
    }

    #! Delivers the terminal error to the consumer exactly once
    private deliverError(hash<auto> error) {
        *code<nothing(hash<auto>)> cb;
        {
            AutoLock al(m);
            cb = on_failure;
            # release the sinks: they close over the object that owns this subscription, which in
            # turn owns it
            remove on_failure;
            remove on_event;
            remove on_keepalive;
        }
        if (cb) {
            cb(error);
        }
    }
}

} # namespace SalesforcePubSubDataProvider
