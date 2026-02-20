/* -*- mode: c++; indent-tabs-mode: nil -*- */
/** @file QoreProtobufSchema.cpp QoreProtobufSchema implementation */
/*
    Qore grpc module

    Copyright (C) 2026 Qore Technologies, s.r.o.

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

#include "grpc-module.h"
#include "QoreProtobufSchema.h"
#include "ProtobufHelper.h"

#include <google/protobuf/io/zero_copy_stream_impl_lite.h>
#include <google/protobuf/util/json_util.h>

// ErrorCollector implementation
#ifdef GRPC_PROTOBUF_V26_PLUS
void QoreProtobufSchema::ErrorCollector::RecordError(absl::string_view filename, int line,
        int column, absl::string_view message) {
    errors.push_back(std::string(filename) + ":" + std::to_string(line + 1) + ":" +
        std::to_string(column + 1) + ": " + std::string(message));
}

void QoreProtobufSchema::ErrorCollector::RecordWarning(absl::string_view filename, int line,
        int column, absl::string_view message) {
    // Ignore warnings
}
#else
void QoreProtobufSchema::ErrorCollector::AddError(const std::string& filename, int line,
        int column, const std::string& message) {
    errors.push_back(filename + ":" + std::to_string(line + 1) + ":" +
        std::to_string(column + 1) + ": " + message);
}

void QoreProtobufSchema::ErrorCollector::AddWarning(const std::string& filename, int line,
        int column, const std::string& message) {
    // Ignore warnings
}
#endif

std::string QoreProtobufSchema::ErrorCollector::getErrors() const {
    std::string result;
    for (const auto& err : errors) {
        if (!result.empty()) {
            result += "\n";
        }
        result += err;
    }
    return result;
}

// StringSourceTree implementation
void QoreProtobufSchema::StringSourceTree::addFile(const std::string& filename,
        const std::string& content) {
    files[filename] = content;
}

#ifdef GRPC_PROTOBUF_V26_PLUS
google::protobuf::io::ZeroCopyInputStream* QoreProtobufSchema::StringSourceTree::Open(
        absl::string_view filename) {
    std::string fname(filename);
    auto it = files.find(fname);
    if (it == files.end()) {
        last_error = "file not found: " + fname;
        return nullptr;
    }
    return new google::protobuf::io::ArrayInputStream(it->second.data(), it->second.size());
}
#else
google::protobuf::io::ZeroCopyInputStream* QoreProtobufSchema::StringSourceTree::Open(
        const std::string& filename) {
    auto it = files.find(filename);
    if (it == files.end()) {
        last_error = "file not found: " + filename;
        return nullptr;
    }
    return new google::protobuf::io::ArrayInputStream(it->second.data(), it->second.size());
}
#endif

std::string QoreProtobufSchema::StringSourceTree::GetLastErrorMessage() {
    return last_error;
}

// QoreProtobufSchema constructors
QoreProtobufSchema::QoreProtobufSchema(const char* path, const char* proto_file,
        ExceptionSink* xsink) {
    // Check sandbox filesystem restrictions before accessing disk
    QoreSandboxManagerHelper smh;
    if (smh) {
        if (!smh->checkFilesystemAccess(path, QSEC_READ, xsink)) {
            return;
        }
        if (smh->checkIOInterrupt(xsink, "loading .proto file")) {
            return;
        }
    }

    error_collector = std::make_unique<ErrorCollector>();
    disk_source_tree = std::make_unique<google::protobuf::compiler::DiskSourceTree>();
    disk_source_tree->MapPath("", path);

    importer = std::make_unique<google::protobuf::compiler::Importer>(
        disk_source_tree.get(), error_collector.get());

    file_desc = importer->Import(proto_file);
    if (!file_desc) {
        xsink->raiseException("PROTOBUF-SCHEMA-ERROR", "failed to load proto file '%s': %s",
            proto_file, error_collector->getErrors().c_str());
        return;
    }

    factory = std::make_unique<google::protobuf::DynamicMessageFactory>(importer->pool());
}

QoreProtobufSchema::QoreProtobufSchema(const QoreString& proto_content, const char* filename,
        ExceptionSink* xsink) {
    error_collector = std::make_unique<ErrorCollector>();
    string_source_tree = std::make_unique<StringSourceTree>();

    const char* fname = filename && filename[0] ? filename : "input.proto";
    string_source_tree->addFile(fname, std::string(proto_content.c_str(), proto_content.size()));

    importer = std::make_unique<google::protobuf::compiler::Importer>(
        string_source_tree.get(), error_collector.get());

    file_desc = importer->Import(fname);
    if (!file_desc) {
        xsink->raiseException("PROTOBUF-SCHEMA-ERROR", "failed to parse proto content: %s",
            error_collector->getErrors().c_str());
        return;
    }

    factory = std::make_unique<google::protobuf::DynamicMessageFactory>(importer->pool());
}

QoreProtobufSchema::~QoreProtobufSchema() {
}

const google::protobuf::Descriptor* QoreProtobufSchema::findMessageDescriptor(const char* type,
        ExceptionSink* xsink) const {
    assert(file_desc);
    const google::protobuf::Descriptor* desc = importer->pool()->FindMessageTypeByName(type);
    if (!desc) {
        // Try prepending the package name
        std::string pkg = file_desc->package();
        if (!pkg.empty()) {
            desc = importer->pool()->FindMessageTypeByName(pkg + "." + type);
        }
    }
    if (!desc) {
        xsink->raiseException("PROTOBUF-TYPE-ERROR", "message type '%s' not found in schema", type);
    }
    return desc;
}

const google::protobuf::Message* QoreProtobufSchema::getPrototype(
        const google::protobuf::Descriptor* desc, ExceptionSink* xsink) const {
    assert(factory);
    const google::protobuf::Message* proto = factory->GetPrototype(desc);
    if (!proto) {
        xsink->raiseException("PROTOBUF-ERROR", "failed to create prototype for message type '%s'",
            desc->full_name().c_str());
    }
    return proto;
}

QoreListNode* QoreProtobufSchema::getServices(ExceptionSink* xsink) const {
    assert(file_desc);
    ReferenceHolder<QoreListNode> list(new QoreListNode(hashdeclGrpcServiceInfo->getTypeInfo()), xsink);

    for (int i = 0; i < file_desc->service_count(); ++i) {
        const google::protobuf::ServiceDescriptor* svc = file_desc->service(i);
        ReferenceHolder<QoreHashNode> svc_hash(new QoreHashNode(hashdeclGrpcServiceInfo, xsink), xsink);

        svc_hash->setKeyValue("name", new QoreStringNode(svc->name()), xsink);

        ReferenceHolder<QoreListNode> methods(
            new QoreListNode(hashdeclGrpcMethodInfo->getTypeInfo()), xsink);
        for (int j = 0; j < svc->method_count(); ++j) {
            const google::protobuf::MethodDescriptor* method = svc->method(j);
            ReferenceHolder<QoreHashNode> method_hash(
                new QoreHashNode(hashdeclGrpcMethodInfo, xsink), xsink);

            method_hash->setKeyValue("name", new QoreStringNode(method->name()), xsink);
            method_hash->setKeyValue("full_path",
                new QoreStringNode(std::string("/") + svc->full_name() + "/" + method->name()),
                xsink);
            method_hash->setKeyValue("input_type",
                new QoreStringNode(method->input_type()->full_name()), xsink);
            method_hash->setKeyValue("output_type",
                new QoreStringNode(method->output_type()->full_name()), xsink);
            method_hash->setKeyValue("client_streaming", method->client_streaming(), xsink);
            method_hash->setKeyValue("server_streaming", method->server_streaming(), xsink);

            methods->push(method_hash.release(), xsink);
        }

        svc_hash->setKeyValue("methods", methods.release(), xsink);
        list->push(svc_hash.release(), xsink);
    }

    return list.release();
}

QoreListNode* QoreProtobufSchema::getMessageTypes(ExceptionSink* xsink) const {
    assert(file_desc);
    ReferenceHolder<QoreListNode> list(new QoreListNode(stringTypeInfo), xsink);

    for (int i = 0; i < file_desc->message_type_count(); ++i) {
        list->push(new QoreStringNode(file_desc->message_type(i)->full_name()), xsink);
    }

    return list.release();
}

QoreHashNode* QoreProtobufSchema::getDefaultMessage(const char* type, ExceptionSink* xsink) const {
    const google::protobuf::Descriptor* desc = findMessageDescriptor(type, xsink);
    if (!desc) {
        return nullptr;
    }

    const google::protobuf::Message* proto = getPrototype(desc, xsink);
    if (!proto) {
        return nullptr;
    }

    std::unique_ptr<google::protobuf::Message> msg(proto->New());
    return ProtobufHelper::messageToHash(*msg, xsink);
}

BinaryNode* QoreProtobufSchema::encode(const char* type, const QoreHashNode* data,
        ExceptionSink* xsink) const {
    const google::protobuf::Descriptor* desc = findMessageDescriptor(type, xsink);
    if (!desc) {
        return nullptr;
    }

    const google::protobuf::Message* proto = getPrototype(desc, xsink);
    if (!proto) {
        return nullptr;
    }

    std::unique_ptr<google::protobuf::Message> msg(proto->New());
    if (!ProtobufHelper::hashToMessage(data, msg.get(), xsink)) {
        return nullptr;
    }

    std::string serialized;
    if (!msg->SerializeToString(&serialized)) {
        xsink->raiseException("PROTOBUF-ENCODE-ERROR", "failed to serialize message of type '%s'",
            type);
        return nullptr;
    }

    SimpleRefHolder<BinaryNode> bin(new BinaryNode);
    bin->append(serialized.data(), serialized.size());
    return bin.release();
}

QoreHashNode* QoreProtobufSchema::decode(const char* type, const BinaryNode* data,
        ExceptionSink* xsink) const {
    const google::protobuf::Descriptor* desc = findMessageDescriptor(type, xsink);
    if (!desc) {
        return nullptr;
    }

    const google::protobuf::Message* proto = getPrototype(desc, xsink);
    if (!proto) {
        return nullptr;
    }

    std::unique_ptr<google::protobuf::Message> msg(proto->New());
    if (!msg->ParseFromArray(data->getPtr(), data->size())) {
        xsink->raiseException("PROTOBUF-DECODE-ERROR",
            "failed to parse binary data as message type '%s'", type);
        return nullptr;
    }

    return ProtobufHelper::messageToHash(*msg, xsink);
}

QoreStringNode* QoreProtobufSchema::toJson(const char* type, const QoreHashNode* data,
        ExceptionSink* xsink) const {
    const google::protobuf::Descriptor* desc = findMessageDescriptor(type, xsink);
    if (!desc) {
        return nullptr;
    }

    const google::protobuf::Message* proto = getPrototype(desc, xsink);
    if (!proto) {
        return nullptr;
    }

    std::unique_ptr<google::protobuf::Message> msg(proto->New());
    if (!ProtobufHelper::hashToMessage(data, msg.get(), xsink)) {
        return nullptr;
    }

    std::string json;
    google::protobuf::util::JsonPrintOptions opts;
    opts.add_whitespace = false;
#ifdef GRPC_PROTOBUF_V26_PLUS
    opts.always_print_fields_with_no_presence = true;
#else
    opts.always_print_primitive_fields = true;
#endif

    auto status = google::protobuf::util::MessageToJsonString(*msg, &json, opts);
    if (!status.ok()) {
        xsink->raiseException("PROTOBUF-JSON-ERROR", "failed to convert message to JSON: %s",
            status.ToString().c_str());
        return nullptr;
    }

    return new QoreStringNode(json);
}

QoreHashNode* QoreProtobufSchema::fromJson(const char* type, const QoreString& json,
        ExceptionSink* xsink) const {
    const google::protobuf::Descriptor* desc = findMessageDescriptor(type, xsink);
    if (!desc) {
        return nullptr;
    }

    const google::protobuf::Message* proto = getPrototype(desc, xsink);
    if (!proto) {
        return nullptr;
    }

    std::unique_ptr<google::protobuf::Message> msg(proto->New());

    google::protobuf::util::JsonParseOptions opts;
    opts.ignore_unknown_fields = false;

    auto status = google::protobuf::util::JsonStringToMessage(
        std::string(json.c_str(), json.size()), msg.get(), opts);
    if (!status.ok()) {
        xsink->raiseException("PROTOBUF-JSON-ERROR", "failed to parse JSON as message type '%s': %s",
            type, status.ToString().c_str());
        return nullptr;
    }

    return ProtobufHelper::messageToHash(*msg, xsink);
}
