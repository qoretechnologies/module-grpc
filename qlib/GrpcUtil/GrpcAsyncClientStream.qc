# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file GrpcAsyncClientStream.qc event-driven gRPC client stream

/*  GrpcAsyncClientStream.qc Copyright 2026 Qore Technologies, s.r.o.

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

public namespace Grpc {

#! Queue event ID for a decoded message received from the server
public const GRPC_ASYNC_EVENT_MESSAGE = "message";

#! Queue event ID for the initial metadata (response headers)
public const GRPC_ASYNC_EVENT_HEADERS = "headers";

#! Queue event ID for stream completion; the payload is a @ref Qore::Grpc::GrpcCallResult
public const GRPC_ASYNC_EVENT_COMPLETE = "complete";

#! Queue event ID for a transport-level stream error
public const GRPC_ASYNC_EVENT_ERROR = "error";

#! Options for @ref Grpc::GrpcAsyncClientStream "GrpcAsyncClientStream"
/** Either callbacks or a \c queue (or both) must be supplied; a stream with no
    sink discards everything the server sends.

    All callbacks are executed on an async I/O controller callback worker
    thread — never on the I/O thread itself, so protobuf decoding and user code
    stay off the I/O thread.  They may call back into the stream freely
    (@ref Grpc::GrpcAsyncClientStream::write() "write()",
    @ref Grpc::GrpcAsyncClientStream::cancel() "cancel()",
    @ref Grpc::GrpcAsyncClientStream::armTimer() "armTimer()"), which is what
    makes delivery-driven request/response patterns possible without a thread
    per stream.  They must not block for long, since the same worker drives
    message delivery for this stream.
*/
public hashdecl GrpcAsyncStreamOptions {
    #! Called with each decoded message received from the server
    *code<nothing(hash<auto>)> on_message;

    #! Called once with the initial metadata when the response headers arrive
    *code<nothing(hash<string, string>)> on_headers;

    #! Called once when the stream reaches a terminal state
    /** The argument is a @ref Qore::Grpc::GrpcCallResult "GrpcCallResult"; a
        non-@ref GRPC_STATUS_OK \c status_code reports a gRPC-level failure
        (including a locally-detected deadline or cancellation).
    */
    *code<nothing(hash<GrpcCallResult>)> on_complete;

    #! Called once if the stream fails at the transport level
    /** The argument is a hash with \c err and \c desc keys.  A transport
        failure is terminal and is reported instead of \c on_complete.
    */
    *code<nothing(hash<auto>)> on_failure;

    #! Queue receiving \c {"event": <id>, "data": <payload>} hashes
    /** A @ref nothing sentinel is pushed after the terminal event so a
        @ref Qore::Thread::Queue::get() "Queue::get()" loop terminates.

        @see
        - @ref GRPC_ASYNC_EVENT_MESSAGE
        - @ref GRPC_ASYNC_EVENT_HEADERS
        - @ref GRPC_ASYNC_EVENT_COMPLETE
        - @ref GRPC_ASYNC_EVENT_ERROR
    */
    *Queue queue;

    #! Call deadline in milliseconds; when it expires the stream is cancelled
    /** Reported as @ref GRPC_STATUS_DEADLINE_EXCEEDED.  Armed on the
        controller's timeout heap; not set by default.
    */
    *int deadline_ms;

    #! Inactivity bound in milliseconds
    /** If no message, metadata, or lifecycle event arrives within this window,
        the stream is cancelled and reported as @ref GRPC_STATUS_UNAVAILABLE.
        Not set by default: an idle gRPC stream is healthy, and the transport
        detects a dead peer on its own.
    */
    *int idle_timeout_ms;
}

namespace Priv {

#! Poll operation that drives @ref Grpc::GrpcAsyncClientStream from the controller
/** Waits on the stream's @ref Qore::EventNotifier "EventNotifier", which the
    I/O thread signals whenever it pushes transport data, an error, or the
    end-of-stream marker.  Deadlines are expressed as \c poll_timeout_ms on the
    returned @ref Qore::SocketPollInfo "SocketPollInfo" so the controller's
    timeout heap — not a polling loop — wakes the operation when a deadline
    comes due.
*/
class GrpcStreamPollOperation inherits Qore::AbstractPollOperation<auto> {
    private {
        #! The notifier signaled by the I/O thread
        EventNotifier notifier;

        #! Drains available events; returns True when the stream is finished
        code<bool()> drain;

        #! Returns the ms until the next armed deadline, or NOTHING if none
        code<*int()> next_timeout;

        #! Called exactly once when the operation reaches a terminal state
        code<nothing()> done;

        #! True once the operation has completed
        bool complete = False;
    }

    #! Creates the poll operation
    constructor(EventNotifier notifier, code<bool()> drain, code<*int()> next_timeout,
            code<nothing()> done) {
        self.notifier = notifier;
        self.drain = drain;
        self.next_timeout = next_timeout;
        self.done = done;
    }

    #! Goal label for this operation
    string getGoal() {
        return "grpc-stream-events";
    }

    #! Current state label
    string getState() {
        return complete ? "complete" : "waiting";
    }

    #! Returns True once the stream has finished
    bool goalReached() {
        return complete;
    }

    #! Drains available events and re-arms the notifier wait and any deadline
    *hash<SocketPollInfo> continuePoll() {
        if (complete) {
            return NOTHING;
        }

        try {
            notifier.acknowledge();
            if (drain()) {
                complete = True;
                done();
                return NOTHING;
            }
        } catch (hash<ExceptionInfo> ex) {
            complete = True;
            done();
            rethrow;
        }

        hash<SocketPollInfo> rv = <SocketPollInfo>{
            "socket": notifier,
            "events": SOCK_POLLIN,
        };
        *int to = next_timeout();
        if (exists to) {
            # poll_timeout_ms == 0 means "no timeout", so clamp to 1ms; a
            # deadline that has already passed is handled by the next drain
            rv.poll_timeout_ms = to > 0 ? to : 1;
        }
        return rv;
    }

    #! Called when the controller aborts the operation
    abort() {
        if (!complete) {
            complete = True;
            done();
        }
    }

    #! Called when the controller completes the operation
    onComplete(hash<SocketPollResultInfo> result) {
        if (!complete) {
            complete = True;
            done();
        }
    }
}

} # namespace Priv

#! Event-driven gRPC client stream driven by the async socket I/O controller
/** This is the asynchronous counterpart to
    @ref Grpc::GrpcClientStream "GrpcClientStream".  Where the synchronous class
    parks a caller thread in a blocking read, this class installs an
    @ref Qore::EventNotifier "EventNotifier" on the HTTP/2 stream handle and
    submits a poll operation to the
    @ref AsyncSocketIo::AsyncSocketIoController "AsyncSocketIoController".  The
    I/O thread signals the notifier as transport data arrives; the controller
    then dispatches the drain to a callback worker, where gRPC deframing,
    protobuf decoding, and user callbacks run.  No user code runs on the I/O
    thread, and no thread is parked on a read.

    Long-lived subscriptions therefore cost no thread while idle, and every
    deadline — the call deadline, an inactivity bound, and any
    application-level timer — is armed on the controller's timeout heap instead
    of being approximated with timed reads.

    @note Connection-level liveness is not this class's concern: an open stream
    keeps its HTTP/2 connection out of the connection manager's idle-close path
    (the H2 poll operation resets its idle deadline whenever the connection has
    active streams), and a dead peer is detected by the transport.  The
    \c idle_timeout_ms option is therefore off by default and exists only for
    protocols that define an application-level inactivity contract.

    @par Example: server streaming with callbacks
    @code{.py}
GrpcAsyncClientStream stream = client.serverStreamAsync("ListItems",
    {"category": "books"}, NOTHING, <GrpcAsyncStreamOptions>{
        "on_message": sub (hash<auto> msg) { printf("item: %y\n", msg); },
        "on_complete": sub (hash<GrpcCallResult> result) {
            printf("done: %d %s\n", result.status_code, result.status_message);
        },
    });
stream.waitForDone(30s);
    @endcode

    @par Example: bidirectional streaming with delivery-driven replenishment
    @code{.py}
# a credit-based subscription: the server stops sending when the credit window
# is exhausted, so the client must replenish it -- driven by delivery and by a
# controller-armed timer, never by a poll tick
sub replenish(GrpcAsyncClientStream s) {
    s.write({"num_requested": 100});
    # re-arm so the window is refreshed even if nothing arrives
    s.armTimer("replenish", 55s, \replenish());
}

GrpcAsyncClientStream stream;
stream = client.bidiStreamAsync("Subscribe", NOTHING, <GrpcAsyncStreamOptions>{
    "on_message": sub (hash<auto> msg) {
        handleEvent(msg);
        if (msg.pending_num_requested < 10) {
            # a write from a delivery callback goes out on the same worker
            stream.write({"num_requested": 100});
        }
    },
});
stream.write({"num_requested": 100});
stream.armTimer("replenish", 55s, \replenish());
    @endcode

    @see @ref Grpc::GrpcClientStream "GrpcClientStream" for the blocking facade
*/
public class GrpcAsyncClientStream {
    public {
        #! Default bound on how long the read side may drain after @ref finishWrites()
        const DefaultDrainTimeout = 30s;
    }

    private {
        #! The HTTP/2 stream handle
        HttpClientIo::HttpClientStreamHandle m_stream;

        #! The notifier signaled by the I/O thread when transport data arrives
        EventNotifier m_notifier;

        #! The protobuf schema
        ProtobufSchema m_schema;

        #! Message type for decoding received messages
        string m_read_type;

        #! Message type for encoding sent messages
        string m_write_type;

        #! Delivery sinks and deadline configuration
        hash<GrpcAsyncStreamOptions> m_opts;

        #! Incremental gRPC deframer fed by the transport chunks
        /** Touched only from the drain, which the controller runs on one
            worker at a time for this operation, so it needs no lock.
        */
        GrpcFrameBuffer m_buf();

        #! State lock
        Mutex m();

        #! Signals state changes (delivery thread exit, terminal state)
        Condition cond();

        #! True once the poll operation has been submitted
        bool m_started = False;

        #! True while the poll operation is registered with the controller
        bool m_poll_active = False;

        #! True until the terminal event has been delivered
        bool m_active = True;

        #! True once END_STREAM has been received from the server
        bool m_reads_done = False;

        #! True once the client write side has been half-closed
        bool m_writes_done = False;

        #! True once cancel() has been requested
        bool m_cancel_requested = False;

        #! True once the initial metadata has been delivered
        bool m_headers_delivered = False;

        #! TID of the thread currently running delivery, if any
        *int m_tid;

        #! Controller key for the poll operation
        *string m_poll_key;

        #! The terminal result, once known
        *hash<GrpcCallResult> m_result;

        #! The terminal transport error, if the stream failed at that level
        *hash<auto> m_error;

        #! Absolute call deadline in epoch microseconds; 0 if disabled
        int m_deadline_us = 0;

        #! Inactivity bound in microseconds; 0 if disabled
        int m_idle_timeout_us = 0;

        #! Absolute inactivity deadline in epoch microseconds; 0 if disabled
        int m_idle_deadline_us = 0;

        #! Absolute post-writes-done drain deadline in epoch microseconds; 0 if disabled
        int m_drain_deadline_us = 0;

        #! Application timers: name -> {"deadline_us": int, "callback": code}
        hash<string, hash<auto>> m_timers();
    }

    #! Creates an event-driven client stream over an open HTTP/2 stream
    /** @param stream the HTTP/2 stream handle, already started in streaming
        mode with \a notifier installed
        @param notifier the notifier the I/O thread signals for this stream
        @param schema the protobuf schema
        @param read_type message type for decoding received messages
        @param write_type message type for encoding sent messages
        @param opts delivery sinks and deadlines
        @param writes_done if True, the write side is already half-closed
        (server-streaming)

        @note The stream is inert until @ref start() is called.

        @see
        - @ref Grpc::GrpcClient::serverStreamAsync()
        - @ref Grpc::GrpcClient::clientStreamAsync()
        - @ref Grpc::GrpcClient::bidiStreamAsync()
    */
    constructor(HttpClientIo::HttpClientStreamHandle stream, EventNotifier notifier,
            ProtobufSchema schema, string read_type, string write_type,
            *hash<GrpcAsyncStreamOptions> opts, bool writes_done = False) {
        m_stream = stream;
        m_notifier = notifier;
        m_schema = schema;
        m_read_type = read_type;
        m_write_type = write_type;
        m_opts = opts ?? <GrpcAsyncStreamOptions>{};
        m_writes_done = writes_done;

        if (m_opts.deadline_ms) {
            m_deadline_us = clock_getmicros() + m_opts.deadline_ms * 1000;
        }
        if (m_opts.idle_timeout_ms) {
            m_idle_timeout_us = m_opts.idle_timeout_ms * 1000;
            m_idle_deadline_us = clock_getmicros() + m_idle_timeout_us;
        }
    }

    #! Copying is not supported
    private copy() {
        throw "COPY-ERROR", "GrpcAsyncClientStream objects cannot be copied";
    }

    #! Submits the poll operation to the async I/O controller
    /** After this call the stream is driven entirely by the controller: the I/O
        thread signals the notifier as data arrives and the drain runs on a
        callback worker.

        @throw GRPC-STREAM-ERROR if the stream has already been started
    */
    start() {
        {
            AutoLock al(m);
            if (m_started) {
                throw "GRPC-STREAM-ERROR", "the stream has already been started";
            }
            m_started = True;
            m_poll_active = True;
            m_poll_key = sprintf("Grpc::GrpcAsyncClientStream:%s", self.uniqueHash());
        }

        try {
            AsyncSocketIo::AsyncSocketIoController controller =
                AsyncSocketIo::getGlobalAsyncIoController();
            Priv::GrpcStreamPollOperation poll_op(m_notifier, \drainEvents(),
                \nextTimeoutMs(), \pollDone());
            controller.submit(<SocketPollOperationInfo>{
                "sock": m_notifier,
                "spop": poll_op,
                "owner": self.uniqueHash(),
                "key": m_poll_key,
                "has_on_complete": True,
                # gRPC streams are long-lived; deadlines are armed per poll
                # cycle via poll_timeout_ms instead of the controller's
                # absolute operation timeout (-1s == no timeout)
                "to": -1s,
            }, True);
        } catch (hash<ExceptionInfo> ex) {
            {
                AutoLock al(m);
                m_poll_active = False;
                cond.broadcast();
            }
            cancelTransport();
            deliverError({"err": ex.err, "desc": ex.desc});
            rethrow;
        }

        # the server can push data before the poll operation is installed; kick
        # the notifier once so anything already queued is drained immediately
        m_notifier.notify();
    }

    #! Encodes and sends a message to the server
    /** @param message the message to send

        @note The stream can reach its terminal state between the state check
        and the send, in which case the underlying transport error is raised
        instead of \c GRPC-STREAM-ERROR; treat any exception here as "the
        message was not sent".

        @throw GRPC-STREAM-ERROR if the stream is no longer active or the write
        side has been closed
    */
    write(hash<auto> message) {
        {
            AutoLock al(m);
            if (!m_active) {
                throw "GRPC-STREAM-ERROR", "the stream is no longer active";
            }
            if (m_writes_done) {
                throw "GRPC-STREAM-ERROR", "the write side of the stream is closed";
            }
        }
        binary encoded = m_schema.encode(m_write_type, message);
        m_stream.sendData(GrpcHelper::frameMessage(encoded), False);
    }

    #! Half-closes the write side of the stream
    /** Safe to call multiple times; subsequent calls are no-ops.
    */
    writesDone() {
        {
            AutoLock al(m);
            if (m_writes_done) {
                return;
            }
            m_writes_done = True;
        }
        m_stream.sendData(binary(), True);
    }

    #! Half-closes the write side and bounds how long the read side may drain
    /** After the client is done sending, a well-behaved server closes its side
        of the stream and the terminal event is delivered from that event.  This
        method additionally arms a drain deadline on the controller so a server
        that never closes cannot keep the stream open indefinitely; when the
        deadline expires the stream is cancelled and reported as
        @ref GRPC_STATUS_DEADLINE_EXCEEDED.

        @param drain_timeout how long the read side may keep draining; use
        \c 0 for no bound
    */
    finishWrites(timeout drain_timeout = DefaultDrainTimeout) {
        writesDone();
        {
            AutoLock al(m);
            if (!m_active || m_reads_done) {
                return;
            }
            m_drain_deadline_us = drain_timeout
                ? clock_getmicros() + drain_timeout * 1000
                : 0;
        }
        m_notifier.notify();
    }

    #! Cancels the stream
    /** Sends \c RST_STREAM and completes the poll operation; the terminal event
        is delivered with @ref GRPC_STATUS_CANCELLED.  This is an asynchronous
        cancel: it never blocks and is safe to call from a delivery callback.

        Safe to call multiple times; subsequent calls are no-ops.
    */
    cancel() {
        bool deliver_inline;
        {
            AutoLock al(m);
            if (m_cancel_requested || !m_active) {
                return;
            }
            m_cancel_requested = True;
            # with no poll operation running there is nothing to wake, so the
            # terminal event must be delivered from this thread
            deliver_inline = !m_poll_active;
        }
        cancelTransport();
        if (deliver_inline) {
            deliverResult(makeResult(GRPC_STATUS_CANCELLED, "stream cancelled by client"));
        } else {
            m_notifier.notify();
        }
    }

    #! Arms a one-shot application timer on the controller's timeout heap
    /** The callback runs on the same callback worker that delivers messages,
        after any messages available at that moment have been delivered.
        Arming a timer with the name of an existing timer replaces it.

        @param name the timer name, used to replace or cancel it
        @param delay how long from now the timer fires
        @param callback called with this stream when the timer fires

        @note The callback receives the stream as its argument so that it does
        not have to capture it; capturing the stream in the closure creates a
        reference cycle that keeps the stream alive after it completes.

        @throw GRPC-STREAM-ERROR if the stream is no longer active
    */
    armTimer(string name, timeout delay, code<nothing(GrpcAsyncClientStream)> callback) {
        {
            AutoLock al(m);
            if (!m_active) {
                throw "GRPC-STREAM-ERROR", "the stream is no longer active";
            }
            m_timers{name} = {
                "deadline_us": clock_getmicros() + delay * 1000,
                "callback": callback,
            };
        }
        # wake the poll operation so it re-arms poll_timeout_ms for this deadline
        m_notifier.notify();
    }

    #! Cancels an application timer armed with @ref armTimer()
    /** @param name the timer name

        @return True if the timer existed and was cancelled
    */
    bool cancelTimer(string name) {
        AutoLock al(m);
        if (!m_timers.hasKey(name)) {
            return False;
        }
        remove m_timers{name};
        return True;
    }

    #! Sets or clears the inactivity bound
    /** @param idle_timeout the maximum time without any traffic on the stream;
        use \c 0 to disable inactivity detection
    */
    setIdleTimeout(timeout idle_timeout) {
        {
            AutoLock al(m);
            m_idle_timeout_us = idle_timeout * 1000;
            m_idle_deadline_us = m_idle_timeout_us
                ? clock_getmicros() + m_idle_timeout_us
                : 0;
        }
        m_notifier.notify();
    }

    #! Returns True while the stream can still deliver events
    /** @return True until the terminal event has been delivered
    */
    bool isActive() {
        AutoLock al(m);
        return m_active;
    }

    #! Returns True once END_STREAM has been received from the server
    /** @return True if the server has closed its side of the stream
    */
    bool readsDone() {
        AutoLock al(m);
        return m_reads_done;
    }

    #! Returns the terminal result, if the stream has finished
    /** @return the @ref Qore::Grpc::GrpcCallResult "GrpcCallResult" delivered to
        \c on_complete, or @ref nothing if the stream is still active or failed
        at the transport level

        @note \c body is always empty; messages are delivered as they arrive
        rather than accumulated

        @see getError()
    */
    *hash<GrpcCallResult> getResult() {
        AutoLock al(m);
        return m_result;
    }

    #! Returns the terminal transport error, if the stream failed at that level
    /** @return a hash with \c err and \c desc keys, or @ref nothing if the
        stream is still active or finished with a gRPC status

        @see getResult()
    */
    *hash<auto> getError() {
        AutoLock al(m);
        return m_error;
    }

    #! Blocks until the stream reaches a terminal state
    /** @param timeout_ms the maximum time to wait

        @return True if the stream finished, False on timeout

        @note When called from a delivery callback this returns immediately with
        the current state; a delivery thread cannot wait for itself
    */
    bool waitForDone(timeout timeout_ms = 30s) {
        AutoLock al(m);
        if (m_tid == gettid()) {
            return !m_active;
        }
        date deadline = now_us() + milliseconds(timeout_ms);
        while (m_active || m_poll_active) {
            int remaining_ms = (deadline - now_us()).durationMilliseconds();
            if (remaining_ms <= 0) {
                return False;
            }
            cond.wait(m, remaining_ms);
        }
        return True;
    }

    #! Drains everything the I/O thread has made available and re-checks deadlines
    /** Runs on an async I/O controller callback worker.

        @return True when the stream has reached a terminal state and the poll
        operation must complete
    */
    private bool drainEvents() {
        {
            AutoLock al(m);
            m_tid = gettid();
        }
        on_exit {
            if (self) {
                AutoLock al(m);
                remove m_tid;
                cond.broadcast();
            }
        }
        try {
            return drainEventsIntern();
        } catch (hash<ExceptionInfo> ex) {
            # a decode failure or an exception thrown by a user callback is
            # terminal; report it through the error sink and end the stream
            cancelTransport();
            deliverError({"err": ex.err, "desc": ex.desc});
            return True;
        }
    }

    #! Drain implementation; see @ref drainEvents()
    private bool drainEventsIntern() {
        # a cancel requested from another thread wakes us through the notifier
        if (checkCancelled()) {
            return True;
        }

        while (True) {
            auto item;
            try {
                # 0ms selects the non-blocking drain: NOTHING means the I/O
                # thread has nothing queued right now
                item = m_stream.readData(0ms);
            } catch (hash<ExceptionInfo> ex) {
                if (ex.err == "HTTPCLIENT-STREAM-CLOSED") {
                    return deliverStreamClosed();
                }
                deliverError({"err": ex.err, "desc": ex.desc});
                return True;
            }
            if (!exists item) {
                break;
            }
            touchIdleDeadline();

            if (item.typeCode() == NT_HASH) {
                if (item.error) {
                    deliverError(makeErrorInfo(item.error));
                    return True;
                }
                if (item.end_stream) {
                    {
                        AutoLock al(m);
                        m_reads_done = True;
                    }
                    deliverBufferedMessages();
                    deliverResult(makeTrailerResult());
                    return True;
                }
                # response metadata (status_code + headers) or another hash the
                # transport surfaces mid-stream
                deliverHeaders(item);
                continue;
            }

            m_buf.add(item);
            deliverBufferedMessages();
            if (checkCancelled()) {
                return True;
            }
        }

        # nothing more is queued: fire anything that has come due
        if (fireTimers()) {
            return True;
        }
        return checkDeadlines();
    }

    #! Returns the ms until the earliest armed deadline, or NOTHING if none
    /** Runs on an async I/O controller callback worker; the value is returned
        to the controller as \c poll_timeout_ms so the timeout heap — not a
        polling loop — wakes the operation when the deadline comes due.
    */
    private *int nextTimeoutMs() {
        AutoLock al(m);
        int best = 0;
        best = earlier(best, m_deadline_us);
        best = earlier(best, m_idle_deadline_us);
        best = earlier(best, m_drain_deadline_us);
        foreach hash<auto> i in (m_timers.pairIterator()) {
            best = earlier(best, i.value.deadline_us);
        }
        if (!best) {
            return NOTHING;
        }
        int remaining_us = best - clock_getmicros();
        return remaining_us > 0 ? (remaining_us + 999) / 1000 : 1;
    }

    #! Returns the earlier of two absolute deadlines, treating 0 as "unset"
    private static int earlier(int current, int candidate) {
        if (!candidate) {
            return current;
        }
        return (!current || candidate < current) ? candidate : current;
    }

    #! Called by the poll operation when it reaches a terminal state
    private pollDone() {
        {
            AutoLock al(m);
            m_poll_active = False;
            remove m_poll_key;
            m_timers = {};
            cond.broadcast();
        }
        # the controller can complete or abort the operation without the drain
        # having delivered a terminal event (e.g. a controller shutdown)
        if (isActive()) {
            cancelTransport();
            deliverResult(makeResult(GRPC_STATUS_CANCELLED,
                "the stream poll operation was terminated"));
        }
    }

    #! Delivers the terminal event when cancel() has been requested
    /** @return True if the stream was cancelled and the poll operation must
        complete
    */
    private bool checkCancelled() {
        {
            AutoLock al(m);
            if (!m_cancel_requested) {
                return False;
            }
        }
        deliverResult(makeResult(GRPC_STATUS_CANCELLED, "stream cancelled by client"));
        return True;
    }

    #! Fires any application timers that have come due
    /** @return True if a timer callback ended the stream
    */
    private bool fireTimers() {
        list<code> due = ();
        {
            AutoLock al(m);
            int now_epoch_us = clock_getmicros();
            list<string> expired = map $1.key, m_timers.pairIterator(),
                $1.value.deadline_us <= now_epoch_us;
            foreach string name in (expired) {
                due += m_timers{name}.callback;
                remove m_timers{name};
            }
        }
        foreach code cb in (due) {
            cb(self);
            if (!isActive()) {
                return True;
            }
        }
        # a timer callback may have cancelled the stream or written to it
        return checkCancelled();
    }

    #! Checks the call deadline, the inactivity bound, and the drain deadline
    /** @return True if a deadline fired and the poll operation must complete
    */
    private bool checkDeadlines() {
        int status_code;
        string status_message;
        {
            AutoLock al(m);
            int now_epoch_us = clock_getmicros();
            if (m_deadline_us && now_epoch_us >= m_deadline_us) {
                status_code = GRPC_STATUS_DEADLINE_EXCEEDED;
                status_message = sprintf("the call deadline of %d ms expired",
                    m_opts.deadline_ms);
            } else if (m_drain_deadline_us && now_epoch_us >= m_drain_deadline_us) {
                status_code = GRPC_STATUS_DEADLINE_EXCEEDED;
                status_message = "the server did not close the stream within the "
                    "drain timeout after the client finished writing";
            } else if (m_idle_deadline_us && now_epoch_us >= m_idle_deadline_us) {
                status_code = GRPC_STATUS_UNAVAILABLE;
                status_message = sprintf("no traffic on the stream for %d ms",
                    m_idle_timeout_us / 1000);
            } else {
                return False;
            }
        }
        cancelTransport();
        deliverResult(makeResult(status_code, status_message));
        return True;
    }

    #! Resets the inactivity deadline after traffic on the stream
    private touchIdleDeadline() {
        AutoLock al(m);
        if (m_idle_timeout_us) {
            m_idle_deadline_us = clock_getmicros() + m_idle_timeout_us;
        }
    }

    #! Decodes and delivers every complete gRPC frame currently buffered
    private deliverBufferedMessages() {
        while (True) {
            *binary payload = m_buf.takeFrame();
            if (!exists payload) {
                return;
            }
            hash<auto> msg = m_schema.decode(m_read_type, payload);
            *code<nothing(hash<auto>)> cb;
            *Queue q;
            {
                AutoLock al(m);
                if (!m_active) {
                    return;
                }
                cb = m_opts.on_message;
                q = m_opts.queue;
            }
            if (cb) {
                cb(msg);
            }
            if (q) {
                q.push({"event": GRPC_ASYNC_EVENT_MESSAGE, "data": msg});
            }
        }
    }

    #! Delivers the initial metadata the first time response headers arrive
    private deliverHeaders(hash<auto> item) {
        if (!item.headers) {
            return;
        }
        hash<string, string> md();
        map md{$1.key} = $1.value.toString(), item.headers.pairIterator(),
            $1.key !~ /^:/;

        *code<nothing(hash<string, string>)> cb;
        *Queue q;
        {
            AutoLock al(m);
            if (m_headers_delivered || !m_active) {
                return;
            }
            m_headers_delivered = True;
            cb = m_opts.on_headers;
            q = m_opts.queue;
        }
        if (cb) {
            cb(md);
        }
        if (q) {
            q.push({"event": GRPC_ASYNC_EVENT_HEADERS, "data": md});
        }
    }

    #! Handles the transport reporting the stream closed without an end marker
    /** @return True; the poll operation always completes after this
    */
    private bool deliverStreamClosed() {
        {
            AutoLock al(m);
            m_reads_done = True;
        }
        *hash<auto> err = m_stream.getError();
        if (err) {
            deliverError(makeErrorInfo(err));
            return True;
        }
        deliverBufferedMessages();
        deliverResult(makeTrailerResult());
        return True;
    }

    #! Builds the terminal result from the response the server sent
    /** @see @ref Grpc::GrpcHelper::parseCallStatus() for the status sources
        covered (trailers, a Trailers-Only response, a non-gRPC HTTP failure)
    */
    private hash<GrpcCallResult> makeTrailerResult() {
        hash<GrpcCallResult> result = GrpcHelper::parseCallStatus(m_stream.getResponse());
        if (m_buf.size()) {
            # bytes left over after the last complete frame mean the server
            # closed the stream in the middle of a message
            result.status_code = GRPC_STATUS_DATA_LOSS;
            result.status_message = sprintf("the stream ended with an incomplete gRPC "
                "frame: %d trailing bytes", m_buf.size());
            m_buf.clear();
        }
        return result;
    }

    #! Builds a locally-generated result carrying the stream's initial metadata
    private hash<GrpcCallResult> makeResult(int status_code, string status_message) {
        hash<GrpcCallResult> result = GrpcHelper::parseCallStatus(m_stream.getResponse());
        result.status_code = status_code;
        result.status_message = status_message;
        return result;
    }

    #! Normalizes a transport error hash to \c err / \c desc keys
    private static hash<auto> makeErrorInfo(hash<auto> err) {
        return {
            "err": err.err ?? "GRPC-STREAM-ERROR",
            "desc": err.desc ?? sprintf("%y", err),
        };
    }

    #! Cancels the underlying HTTP/2 stream, ignoring terminal-state errors
    private cancelTransport() {
        try {
            m_stream.cancel();
        } catch (hash<ExceptionInfo> ex) {
            # the stream is already closed or cancelled
        }
    }

    #! Flips the stream to the inactive state exactly once
    /** @return True if this call performed the transition
    */
    private bool markInactive() {
        AutoLock al(m);
        if (!m_active) {
            return False;
        }
        m_active = False;
        cond.broadcast();
        return True;
    }

    #! Delivers the terminal completion event exactly once
    private deliverResult(hash<GrpcCallResult> result) {
        if (!markInactive()) {
            return;
        }
        *code<nothing(hash<GrpcCallResult>)> cb;
        *Queue q;
        {
            AutoLock al(m);
            m_result = result;
            cb = m_opts.on_complete;
            q = m_opts.queue;
            clearSinks();
        }
        if (cb) {
            cb(result);
        }
        if (q) {
            q.push({"event": GRPC_ASYNC_EVENT_COMPLETE, "data": result});
            q.push();
        }
    }

    #! Delivers the terminal transport-error event exactly once
    private deliverError(hash<auto> error) {
        if (!markInactive()) {
            return;
        }
        *code<nothing(hash<auto>)> cb;
        *Queue q;
        {
            AutoLock al(m);
            m_error = error;
            cb = m_opts.on_failure;
            q = m_opts.queue;
            clearSinks();
        }
        if (cb) {
            cb(error);
        }
        if (q) {
            q.push({"event": GRPC_ASYNC_EVENT_ERROR, "data": error});
            q.push();
        }
    }

    #! Releases the delivery sinks after the terminal event
    /** Callbacks routinely close over the object that owns this stream, which
        in turn owns the stream; dropping them here breaks that cycle as soon as
        the stream finishes.  Must be called with the state lock held.
    */
    private clearSinks() {
        remove m_opts.on_message;
        remove m_opts.on_headers;
        remove m_opts.on_complete;
        remove m_opts.on_failure;
        remove m_opts.queue;
    }
}

} # namespace Grpc
