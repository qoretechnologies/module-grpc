# -*- mode: qore; indent-tabs-mode: nil -*-
#! @file SalesforcePubSubProto.qc vendored Pub/Sub API protocol definition

/*  SalesforcePubSubProto.qc Copyright 2026 Qore Technologies, s.r.o.

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

#! Provides the Salesforce Pub/Sub API protocol definition as a cached \c ProtobufSchema
/** The protocol definition is the upstream
    <a href="https://github.com/forcedotcom/pub-sub-api/blob/main/pubsub_api.proto">pubsub_api.proto</a>
    from \c forcedotcom/pub-sub-api, vendored verbatim into this module directory under its
    CC0-1.0 licence and loaded from disk at runtime.

    It is a file rather than a string constant on purpose: a vendored \c .proto that can be
    diffed against upstream is the point, and directory modules install \c *.proto resources
    next to the module, so \c get_script_dir() finds it both in the
    build tree and after installation.

    @par Example:
    @code{.py}
ProtobufSchema schema = SalesforcePubSubProto::get();
GrpcClient client(channel, schema, "eventbus.v1.PubSub");
    @endcode
*/
public class SalesforcePubSubProto {
    public {
        #! The name of the vendored protocol definition file
        const ProtoFileName = "pubsub_api.proto";

        #! The fully-qualified name of the Pub/Sub service
        const ServiceName = "eventbus.v1.PubSub";

        #! The fully-qualified name of the replay preset enum
        const ReplayPresetEnum = "eventbus.v1.ReplayPreset";
    }

    private {
        #! The cached schema
        static *ProtobufSchema m_schema;

        #! The cached replay preset name -> wire value map
        static *hash<string, int> m_replay_presets;

        #! Lock protecting @ref m_schema and @ref m_replay_presets
        static Mutex m_lock();
    }

    #! Returns the cached Pub/Sub protocol schema, parsing the vendored file on first use
    /** @return the \c ProtobufSchema for the \c eventbus.v1 package

        @throw SALESFORCE-PUBSUB-ERROR if the vendored protocol definition cannot be loaded
    */
    static ProtobufSchema get() {
        AutoLock al(m_lock);
        if (!m_schema) {
            string dir = get_script_dir();
            try {
                m_schema = new ProtobufSchema(dir, ProtoFileName);
            } catch (hash<ExceptionInfo> ex) {
                throw "SALESFORCE-PUBSUB-ERROR", sprintf("cannot load the vendored Pub/Sub "
                    "protocol definition %y from %y: %s: %s", ProtoFileName, dir, ex.err,
                    ex.desc);
            }
        }
        return m_schema;
    }

    #! Returns the wire value of a \c ReplayPreset enum name
    /** The protobuf encoder accepts only integers for an enum field: given the enum's **name** it
        silently encodes \c 0 instead of raising an error, which for \c ReplayPreset would turn a
        \c CUSTOM replay position into \c LATEST and lose the replay resume without any diagnostic.
        Every preset therefore has to be resolved to its wire value before encoding, and it is
        resolved from the vendored schema rather than hardcoded so that it stays correct if
        upstream renumbers the enum.

        @param name the preset name; see @ref ReplayPresets

        @return the wire value of the preset

        @throw SALESFORCE-PUBSUB-ERROR the name is not a value of the \c ReplayPreset enum
    */
    static int getReplayPresetValue(string name) {
        # the schema is resolved before the lock is taken: get() takes the same non-reentrant lock
        ProtobufSchema schema = SalesforcePubSubProto::get();
        hash<string, int> presets;
        {
            AutoLock al(m_lock);
            if (!m_replay_presets) {
                m_replay_presets = schema.enumValues(ReplayPresetEnum);
            }
            presets = m_replay_presets;
        }
        if (!presets.hasKey(name)) {
            throw "SALESFORCE-PUBSUB-ERROR", sprintf("%y is not a value of the %y enum; expecting "
                "one of %y", name, ReplayPresetEnum, keys presets);
        }
        return presets{name};
    }
}

} # namespace SalesforcePubSubDataProvider
