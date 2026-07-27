# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubDefs.qc definitions for the Salesforce Pub/Sub data provider

/*  SalesforcePubSubDefs.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! The name of the Pub/Sub events container child of the Salesforce data provider
public const PubSubChildName = "pubsub";

#! The single global Salesforce Pub/Sub API endpoint
/** The endpoint is the same for production orgs and sandboxes; the org is identified by the
    @ref MetadataInstanceUrl and @ref MetadataTenantId call metadata headers, not by the host.
    Only the OAuth2 URLs are org-specific, and \c SalesforceRestClient already handles those.
*/
public const PubSubUrl = "https://api.pubsub.salesforce.com:7443";

#! The call metadata header carrying the Salesforce access token
public const MetadataAccessToken = "accesstoken";

#! The call metadata header carrying the org's instance URL
public const MetadataInstanceUrl = "instanceurl";

#! The call metadata header carrying the org ID (tenant ID)
public const MetadataTenantId = "tenantid";

#! Replay preset: start the subscription at the tip of the stream (the default)
public const ReplayLatest = "LATEST";

#! Replay preset: start the subscription at the earliest retained point in the stream
public const ReplayEarliest = "EARLIEST";

#! Replay preset: start the subscription after the replay ID given in \c replay_id
public const ReplayCustom = "CUSTOM";

#! All supported replay presets
public const ReplayPresets = (ReplayLatest, ReplayEarliest, ReplayCustom);

#! The maximum number of events a single \c FetchRequest may request
/** Enforced by the Pub/Sub API; a larger value is rejected.
*/
public const MaxNumRequested = 100;

#! Default flow-control window: the number of events the client keeps requested
public const DefaultNumRequested = 100;

#! Default flow-control low-water mark that triggers delivery-driven replenishment
public const DefaultLowWaterMark = 25;

#! Default deadline for the flow-control backstop, in milliseconds
/** The Pub/Sub API closes a subscription if the client does not send a \c FetchRequest within
    60 seconds of \c pending_num_requested reaching zero.  Replenishment is driven by delivery,
    so this deadline is a backstop; it is set well inside the 60 second bound.

    @see @ref SalesforcePubSubDataProvider::SalesforcePubSubSubscription "SalesforcePubSubSubscription"
*/
public const DefaultFlowControlBackstopMs = 45000;

#! Default inactivity bound for a subscription stream, in milliseconds
/** The server sends an empty \c FetchResponse as a keepalive within 270 seconds, so silence
    beyond that means the stream is dead even though the transport has not noticed.  The default
    adds a tolerance margin on top of the documented bound.
*/
public const DefaultIdleTimeoutMs = 300000;

#! Default initial delay before reconnecting a failed subscription, in milliseconds
public const DefaultReconnectDelayMs = 1000;

#! Default ceiling on the exponential reconnect backoff, in milliseconds
public const DefaultMaxReconnectDelayMs = 60000;

#! The gRPC error status returned when the stored replay ID can no longer be used
/** The only recovery is to restart the subscription from @ref ReplayLatest or
    @ref ReplayEarliest; the retention window for replay IDs is 72 hours.
*/
public const ReplayIdCorruptedError = "sfdc.platform.eventbus.grpc.subscription.fetch."
    "replayid.corrupted";

#! Event raised for each event received from a Pub/Sub channel
public const EVENT_SALESFORCE_PUBSUB_EVENT = "salesforce-pubsub-event";

#! Event raised when a subscription fails in a way it cannot recover from
public const EVENT_SALESFORCE_PUBSUB_ERROR = "salesforce-pubsub-error";

#! The topic name prefix for Change Data Capture channels
public const ChangeEventTopicPrefix = "/data/";

#! The topic name prefix for platform event channels
public const PlatformEventTopicPrefix = "/event/";

#! The sobject name suffix identifying a Change Data Capture channel
public const ChangeEventSuffix = "ChangeEvent";

#! The sobject name suffix identifying a custom platform event
public const PlatformEventSuffix = "__e";

#! Returns the Pub/Sub topic name for a Salesforce channel name
/** Accepts either a topic name that is already fully qualified (it starts with \c "/" and is
    returned unchanged) or an sobject name as returned by \c describeGlobal, which is mapped to
    its topic name: a Change Data Capture entity (\c "AccountChangeEvent") becomes
    <tt>"/data/AccountChangeEvent"</tt> and a platform event (\c "My_Event__e") becomes
    <tt>"/event/My_Event__e"</tt>.

    @param channel the channel name; either a topic name or an sobject name

    @return the Pub/Sub topic name

    @throw SALESFORCE-PUBSUB-CHANNEL-ERROR the channel name is not a topic name and is not a
    recognized event entity name

    @par Example:
    @code{.py}
string topic = SalesforcePubSubDataProvider::get_topic_name("AccountChangeEvent");
# -> "/data/AccountChangeEvent"
    @endcode
*/
public string sub get_topic_name(string channel) {
    if (channel =~ /^\//) {
        return channel;
    }
    if (channel =~ /ChangeEvent$/) {
        return ChangeEventTopicPrefix + channel;
    }
    if (channel =~ /__e$/) {
        return PlatformEventTopicPrefix + channel;
    }
    throw "SALESFORCE-PUBSUB-CHANNEL-ERROR", sprintf("channel %y is neither a topic name "
        "(starting with %y) nor an event entity name (ending in %y or %y); use the topic name "
        "for a custom channel", channel, "/", ChangeEventSuffix, PlatformEventSuffix);
}

#! Returns @ref True if the given sobject name identifies a subscribable Pub/Sub channel
/** @param name the sobject name as returned by \c describeGlobal

    @return @ref True if \a name ends in \c "ChangeEvent" or \c "__e"
*/
public bool sub is_pubsub_channel(string name) {
    return name =~ /ChangeEvent$/ || name =~ /__e$/;
}

} # namespace SalesforcePubSubDataProvider
