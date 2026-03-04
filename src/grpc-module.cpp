/* -*- mode: c++; indent-tabs-mode: nil -*- */
/** @file grpc-module.cpp grpc module implementation */
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
#include "QC_ProtobufSchema.h"

#ifdef HAVE_ARROW
#include "QC_ArrowSchema.h"
#include "QC_ArrowRecordBatch.h"
#include "QC_ArrowIpc.h"
#endif

#include <google/protobuf/stubs/common.h>

static void grpc_module_init(QoreModuleInitContext& ctx, ExceptionSink& xsink);
static void grpc_module_ns_init(QoreNamespace* rns, QoreNamespace* qns, ExceptionSink& xsink);
static void grpc_module_delete();

extern "C" DLLEXPORT void grpc_qore_module_desc(QoreModuleInfo& mod_info) {
    mod_info.name = "grpc";
    mod_info.version = "1.0.0";
    mod_info.desc = "Qore gRPC/protobuf module";
    mod_info.author = "Qore Technologies, s.r.o.";
    mod_info.url = "https://github.com/qoretechnologies/module-grpc";
    mod_info.api_major = QORE_MODULE_API_MAJOR;
    mod_info.api_minor = QORE_MODULE_API_MINOR;
    mod_info.init = grpc_module_init;
    mod_info.ns_init = grpc_module_ns_init;
    mod_info.del = grpc_module_delete;
    mod_info.license = QL_MIT;
    mod_info.license_str = "MIT";
}

// Global hashdecl pointers
const TypedHashDecl* hashdeclGrpcCallOptions = nullptr;
const TypedHashDecl* hashdeclGrpcCallResult = nullptr;
const TypedHashDecl* hashdeclGrpcSslOptions = nullptr;
const TypedHashDecl* hashdeclGrpcChannelOptions = nullptr;
const TypedHashDecl* hashdeclGrpcServerOptions = nullptr;
const TypedHashDecl* hashdeclGrpcServiceInfo = nullptr;
const TypedHashDecl* hashdeclGrpcMethodInfo = nullptr;

#ifdef HAVE_ARROW
const TypedHashDecl* hashdeclArrowFieldInfo = nullptr;
const TypedHashDecl* hashdeclArrowSchemaInfo = nullptr;
const TypedHashDecl* hashdeclArrowIpcData = nullptr;
#endif

QoreNamespace GrpcNs("Qore::Grpc");

static void grpc_module_init(QoreModuleInitContext& ctx, ExceptionSink& xsink) {
    // Initialize hashdecls (defined in QPP files for documentation)
    hashdeclGrpcMethodInfo = init_hashdecl_GrpcMethodInfo(GrpcNs);
    hashdeclGrpcServiceInfo = init_hashdecl_GrpcServiceInfo(GrpcNs);
    hashdeclGrpcCallOptions = init_hashdecl_GrpcCallOptions(GrpcNs);
    hashdeclGrpcCallResult = init_hashdecl_GrpcCallResult(GrpcNs);
    hashdeclGrpcSslOptions = init_hashdecl_GrpcSslOptions(GrpcNs);
    hashdeclGrpcChannelOptions = init_hashdecl_GrpcChannelOptions(GrpcNs);
    hashdeclGrpcServerOptions = init_hashdecl_GrpcServerOptions(GrpcNs);

    // Initialize ProtobufSchema class
    GrpcNs.addSystemClass(initProtobufSchemaClass(GrpcNs));

#ifdef HAVE_ARROW
    // Initialize Arrow hashdecls
    hashdeclArrowFieldInfo = init_hashdecl_ArrowFieldInfo(GrpcNs);
    hashdeclArrowSchemaInfo = init_hashdecl_ArrowSchemaInfo(GrpcNs);
    hashdeclArrowIpcData = init_hashdecl_ArrowIpcData(GrpcNs);

    // Initialize Arrow classes
    GrpcNs.addSystemClass(initArrowSchemaClass(GrpcNs));
    GrpcNs.addSystemClass(initArrowRecordBatchClass(GrpcNs));
    GrpcNs.addSystemClass(initArrowIpcClass(GrpcNs));
#endif
}

static void grpc_module_ns_init(QoreNamespace* rns, QoreNamespace* qns, ExceptionSink& xsink) {
    qns->addNamespace(GrpcNs.copy());
}

static void grpc_module_delete() {
    // Cleanup: shut down protobuf library
    google::protobuf::ShutdownProtobufLibrary();
}
