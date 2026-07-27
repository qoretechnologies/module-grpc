# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubDataTypes.qc Salesforce Pub/Sub event data types

/*  SalesforcePubSubDataTypes.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! The metadata carried alongside every Pub/Sub event
public class SalesforcePubSubEventMetaDataType inherits DataProvider::HashDataType {
    private {
        #! Field definitions
        const Fields = {
            "replayId": {
                "display_name": "Replay ID",
                "short_desc": "The base64-encoded replay ID of this event",
                "type": AbstractDataProviderTypeMap."string",
                "desc": "The base64-encoded replay ID of this event.  Store it to resume the "
                    "subscription immediately after this event; Salesforce retains replay IDs for "
                    "**72 hours**.\n\n"
                    "The Pub/Sub API's replay ID is opaque binary rather than the monotonic integer "
                    "the older CometD streaming API used, so treat it as a token and do not compare "
                    "or order it",
                "example_value": "AAAAAAAAAAEAAA==",
            },
            "id": {
                "display_name": "Event ID",
                "short_desc": "The event ID assigned by the publisher or by Salesforce",
                "type": AbstractDataProviderTypeMap."string",
                "desc": "The event ID; either supplied by the publishing application or generated "
                    "by Salesforce",
                "example_value": "f7a1b0c2-3d4e-4f56-8a90-1b2c3d4e5f60",
            },
            "schemaId": {
                "display_name": "Schema ID",
                "short_desc": "The Avro schema fingerprint the payload was encoded with",
                "type": AbstractDataProviderTypeMap."string",
                "desc": "The fingerprint of the Avro schema the `payload` was encoded with.  It "
                    "changes when the channel's schema changes, which is how a subscriber knows to "
                    "fetch a new schema",
                "example_value": "IeSFsaGYFkarQ8sMLLQrpg",
            },
        };
    }

    #! Creates the type
    constructor() : HashDataType("SalesforcePubSubEventMeta") {
        addQoreFields(Fields);
    }
}

#! A Salesforce Pub/Sub event as delivered to observers
/** The envelope mirrors the one the Salesforce streaming APIs use, so that mappers written against
    the older CometD streaming API port without a change of shape.

    \c payload is untyped here because it is channel-specific: the per-channel event provider
    derives a fully-described payload type from the channel's own Avro schema in
    @ref SalesforcePubSubDataProvider::SalesforcePubSubEventDataProvider::getEventTypesImpl()
    "getEventTypesImpl()", so a Qog bound to a specific channel shows its real field names.
*/
public class SalesforcePubSubEventDataType inherits DataProvider::HashDataType {
    private {
        #! Field definitions
        const Fields = {
            "channel": {
                "display_name": "Channel",
                "short_desc": "The Pub/Sub topic name the event arrived on",
                "type": AbstractDataProviderTypeMap."string",
                "desc": "The Pub/Sub topic name the event arrived on, for example "
                    "`/data/AccountChangeEvent` for a Change Data Capture channel or "
                    "`/event/Order_Shipped__e` for a platform event",
                "example_value": "/data/AccountChangeEvent",
            },
            "event": {
                "display_name": "Event Metadata",
                "short_desc": "The replay ID, event ID and schema ID of this event",
                "type": new SalesforcePubSubEventMetaDataType(),
                "desc": "Metadata about the event itself, as opposed to its `payload`: the replay "
                    "ID to resume from, the event ID and the Avro schema fingerprint",
            },
            "payload": {
                "display_name": "Payload",
                "short_desc": "The decoded event payload",
                "type": AbstractDataProviderTypeMap."hash",
                "desc": "The decoded event payload.\n\n"
                    "The fields are those of the channel's own Avro schema.  A Change Data Capture "
                    "event carries a `ChangeEventHeader` describing the change plus the changed "
                    "fields of the record; a platform event carries the fields declared on the "
                    "event definition.\n\n"
                    "A provider navigated to a **specific channel** reports this with the "
                    "channel's real field names rather than as an untyped hash",
            },
        };
    }

    #! Creates the type
    constructor() : HashDataType("SalesforcePubSubEvent") {
        addQoreFields(Fields);
    }
}

#! Reported when a subscription fails and cannot be re-established
public class SalesforcePubSubErrorDataType inherits DataProvider::HashDataType {
    private {
        #! Field definitions
        const Fields = {
            "err": {
                "display_name": "Error Code",
                "short_desc": "The error code",
                "type": AbstractDataProviderTypeMap."string",
                "desc": "The error code; a gRPC status failure is reported as "
                    "`SALESFORCE-PUBSUB-GRPC-STATUS-<code>`",
                "example_value": "SALESFORCE-PUBSUB-GRPC-STATUS-16",
            },
            "desc": {
                "display_name": "Description",
                "short_desc": "The error description",
                "type": AbstractDataProviderTypeMap."string",
                "desc": "A human-readable description of why the subscription could not be "
                    "re-established",
                "example_value": "the access token is no longer valid",
            },
        };
    }

    #! Creates the type
    constructor() : HashDataType("SalesforcePubSubError") {
        addQoreFields(Fields);
    }
}

#! Pub/Sub event envelope type singleton
public const SalesforcePubSubEventType = new SalesforcePubSubEventDataType();

#! Pub/Sub subscription failure type singleton
public const SalesforcePubSubErrorType = new SalesforcePubSubErrorDataType();
}
