# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubCdc.qc Change Data Capture enablement through the Tooling API

/*  SalesforcePubSubCdc.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Change Data Capture entity selection, through the Tooling API
/** A subscription to a Change Data Capture channel whose entity has not been selected succeeds
    and then delivers nothing, which is the worst failure mode available: it is indistinguishable
    from an idle org.  Salesforce exposes the selection as \c PlatformEventChannelMember in the
    <b>Tooling API</b>, and it is both readable and writable, so the remedy does not have to be a
    Setup walkthrough -- it can be one action, or one option.

    Enablement is never performed implicitly.  Subscribing to events should not quietly mutate org
    configuration, and enabling Change Data Capture is not free of side effects: it starts a
    72-hour retention stream for that entity.

    @since %SalesforcePubSubDataProvider 1.0
*/
public class SalesforcePubSubCdc {
    public {
        #! The Tooling API sobject holding the Change Data Capture entity selection
        const ChannelMemberSobject = "PlatformEventChannelMember";

        #! The standard Change Data Capture event channel
        /** A query of \c PlatformEventChannel returns the *custom* channels only; the standard
            channel every Change Data Capture entity belongs to is named here and is not listed.
        */
        const StandardEventChannel = "ChangeEvents";

        #! The \c DeveloperName prefix that Setup itself uses for standard-channel members
        const DeveloperNamePrefix = "CM_ChangeEvents_";
    }

    #! Returns the \c DeveloperName that Setup uses for the given change event entity
    /** @param entity the change event entity, for example \c "AccountChangeEvent"

        @return the developer name, for example \c "CM_ChangeEvents_Account"
    */
    static string getDeveloperName(string entity) {
        # Setup names the member after the object, not after the event
        string object_name = (entity =~ x/^(.*)ChangeEvent$/)[0] ?? entity;
        return DeveloperNamePrefix + object_name;
    }

    #! Returns the Change Data Capture entities currently selected on the standard channel
    /** @param api a REST client rooted at the org's versioned API base

        @return the \c PlatformEventChannelMember rows, or @ref nothing if none are selected
    */
    static *list<hash<auto>> listEnabledEntities(RestClientIo::RestClientIo api) {
        hash<auto> resp = api.restGet("tooling/query/?q="
            + encode_url("SELECT Id, DeveloperName, EventChannel, SelectedEntity FROM "
                + ChannelMemberSobject, True));
        return resp.body.records;
    }

    #! Returns @ref True if Change Data Capture is already enabled for the given entity
    /** @param api a REST client rooted at the org's versioned API base
        @param entity the change event entity, for example \c "AccountChangeEvent"

        @return @ref True if the entity is already selected
    */
    static bool isEnabled(RestClientIo::RestClientIo api, string entity) {
        return exists (select SalesforcePubSubCdc::listEnabledEntities(api) ?? (),
            $1.SelectedEntity == entity)[0];
    }

    #! Enables Change Data Capture for the given entity on the standard channel
    /** Idempotent: an entity that is already selected is reported as such rather than as an
        error, so an action or an \c enable_cdc retry can be run twice without failing.

        @param api a REST client rooted at the org's versioned API base
        @param entity the change event entity, for example \c "AccountChangeEvent"

        @return a hash with \c entity, \c developer_name, \c event_channel, \c id and
        \c already_enabled keys

        @throw SALESFORCE-CDC-ENTITY-ERROR the entity name is not a valid change event
        @throw SALESFORCE-CDC-PERMISSION-ERROR the connection's user may not modify metadata
        @throw SALESFORCE-CDC-ERROR the org refused the change for another reason; the org's own
        message is carried through, because the number of entities the standard channel accepts
        depends on the org's edition and add-ons and must not be guessed at here
    */
    static hash<auto> enable(RestClientIo::RestClientIo api, string entity) {
        string developer_name = SalesforcePubSubCdc::getDeveloperName(entity);

        try {
            hash<auto> resp = api.restPost("tooling/sobjects/" + ChannelMemberSobject, {
                "FullName": developer_name,
                "Metadata": {
                    "eventChannel": StandardEventChannel,
                    "selectedEntity": entity,
                },
            });
            return {
                "entity": entity,
                "developer_name": developer_name,
                "event_channel": StandardEventChannel,
                "id": resp.body.id,
                "already_enabled": False,
            };
        } catch (hash<ExceptionInfo> ex) {
            return SalesforcePubSubCdc::handleEnableError(ex, api, entity, developer_name);
        }
    }

    #! Maps a Tooling API failure onto an actionable error, or onto an already-enabled result
    /** @param ex the original exception
        @param api a REST client rooted at the org's versioned API base
        @param entity the change event entity
        @param developer_name the \c DeveloperName that was attempted

        @return the already-enabled result if the failure was a duplicate member; otherwise this
        method throws
    */
    private static hash<auto> handleEnableError(hash<ExceptionInfo> ex,
            RestClientIo::RestClientIo api, string entity, string developer_name) {
        auto body = ex.arg.body;
        *hash<auto> err = body.typeCode() == NT_LIST ? body[0] : body;
        *string code = err.errorCode;
        *string message = err.message;

        switch (code) {
            case "DUPLICATE_DEVELOPER_NAME": {
                # the member already exists, so the entity is already selected: report success
                # rather than an error, so that enabling twice is not a failure
                *hash<auto> existing = (select SalesforcePubSubCdc::listEnabledEntities(api) ?? (),
                    $1.DeveloperName == developer_name)[0];
                return {
                    "entity": entity,
                    "developer_name": developer_name,
                    "event_channel": StandardEventChannel,
                    "id": existing.Id,
                    "already_enabled": True,
                };
            }

            case "INVALID_INPUT":
            case "FIELD_INTEGRITY_EXCEPTION":
                throw "SALESFORCE-CDC-ENTITY-ERROR", sprintf("Change Data Capture cannot be "
                    "enabled for %y: the org does not recognize it as a change event.  A change "
                    "event is named after the object it reports on, with a \"ChangeEvent\" "
                    "suffix, for example \"AccountChangeEvent\" for \"Account\"; a custom object "
                    "uses \"__ChangeEvent\", for example \"MyObject__ChangeEvent\".  The org "
                    "reported: %s", entity, message ?? ex.desc);
        }

        if (ex.arg.status_code == 403 || (code ?? "") =~ /INSUFFICIENT|ACCESS|PERMISSION/) {
            throw "SALESFORCE-CDC-PERMISSION-ERROR", sprintf("Change Data Capture could not be "
                "enabled for %y because the connection's user is not permitted to modify org "
                "metadata; the \"Customize Application\" and \"Modify Metadata Through Metadata "
                "API Functions\" permissions are what this requires.  The org reported: %s",
                entity, message ?? ex.desc);
        }

        # everything else, including the limit on how many entities the standard channel accepts:
        # that limit depends on the org's edition and add-ons, so the org's own message is the
        # authority and is carried through verbatim rather than being interpreted here
        throw "SALESFORCE-CDC-ERROR", sprintf("Change Data Capture could not be enabled for %y. "
            "The org reported: %s%s", entity, message ?? ex.desc,
            code.val() ? sprintf(" (code: %s)", code) : "");
    }
}
}
