cmake_minimum_required(VERSION 3.5.0)

project(qore-grpc-module)

set(VERSION_MAJOR 1)
set(VERSION_MINOR 0)
set(VERSION_PATCH 0)

set(PROJECT_VERSION "${VERSION_MAJOR}.${VERSION_MINOR}.${VERSION_PATCH}")

if (${CMAKE_VERSION} VERSION_GREATER_EQUAL "3.12.0")
    cmake_policy(SET CMP0074 NEW)

    if (${CMAKE_VERSION} VERSION_GREATER_EQUAL "3.18.0")
        cmake_policy(SET CMP0053 NEW)
    endif()
endif()

cmake_policy(SET CMP0042 NEW)

if (UNIX AND NOT APPLE)
    set(LINUX TRUE)
endif()

find_package(Qore 2.0 REQUIRED)
include(CheckCXXSourceCompiles)

if(DEFINED QORE_HAVE_COLUMNAR_RESULT_V2)
    set(QORE_GRPC_HAVE_COLUMNAR_RESULT_V2 ${QORE_HAVE_COLUMNAR_RESULT_V2})
else()
    set(_save_CMAKE_REQUIRED_INCLUDES "${CMAKE_REQUIRED_INCLUDES}")
    set(_save_CMAKE_REQUIRED_LIBRARIES "${CMAKE_REQUIRED_LIBRARIES}")
    set(CMAKE_REQUIRED_INCLUDES ${QORE_INCLUDE_DIRS})
    set(CMAKE_REQUIRED_LIBRARIES ${QORE_LIBRARY})
    check_cxx_source_compiles("
#include <qore/Qore.h>

#ifndef QORE_HAVE_COLUMNAR_RESULT_V2
#error missing QORE_HAVE_COLUMNAR_RESULT_V2
#endif

#include <qore/QoreColumnarResult.h>

int main() {
    (void)&QoreColumnarResult::getSchemaV2;
    return 0;
}
" QORE_GRPC_HAVE_COLUMNAR_RESULT_V2)
    set(CMAKE_REQUIRED_INCLUDES "${_save_CMAKE_REQUIRED_INCLUDES}")
    set(CMAKE_REQUIRED_LIBRARIES "${_save_CMAKE_REQUIRED_LIBRARIES}")
endif()

if(QORE_GRPC_HAVE_COLUMNAR_RESULT_V2)
    add_definitions(-DQORE_GRPC_HAVE_COLUMNAR_RESULT_V2=1)
endif()
message(STATUS "Qore ColumnarResult v2 API support: ${QORE_GRPC_HAVE_COLUMNAR_RESULT_V2}")

if(DEFINED QORE_HAVE_EXTERNAL_BUFFER_STORAGE)
    set(QORE_GRPC_HAVE_EXTERNAL_BUFFER_STORAGE ${QORE_HAVE_EXTERNAL_BUFFER_STORAGE})
elseif(QORE_GRPC_HAVE_COLUMNAR_RESULT_V2)
    set(_save_CMAKE_REQUIRED_INCLUDES "${CMAKE_REQUIRED_INCLUDES}")
    set(_save_CMAKE_REQUIRED_LIBRARIES "${CMAKE_REQUIRED_LIBRARIES}")
    set(CMAKE_REQUIRED_INCLUDES ${QORE_INCLUDE_DIRS})
    set(CMAKE_REQUIRED_LIBRARIES ${QORE_LIBRARY})
    check_cxx_source_compiles("
#include <qore/Qore.h>

#ifndef QORE_HAVE_EXTERNAL_BUFFER_STORAGE
#error missing QORE_HAVE_EXTERNAL_BUFFER_STORAGE
#endif

#include <qore/QoreBufferNode.h>

int main() {
    const QoreBufferNode* b = nullptr;
    (void)b->getRawValidityData();
    (void)b->hasExternalStorage();
    return 0;
}
" QORE_GRPC_HAVE_EXTERNAL_BUFFER_STORAGE)
    set(CMAKE_REQUIRED_INCLUDES "${_save_CMAKE_REQUIRED_INCLUDES}")
    set(CMAKE_REQUIRED_LIBRARIES "${_save_CMAKE_REQUIRED_LIBRARIES}")
endif()

if(QORE_GRPC_HAVE_EXTERNAL_BUFFER_STORAGE)
    add_definitions(-DQORE_GRPC_HAVE_EXTERNAL_BUFFER_STORAGE=1)
endif()
message(STATUS "Qore external buffer storage API support: ${QORE_GRPC_HAVE_EXTERNAL_BUFFER_STORAGE}")

if(DEFINED QORE_HAVE_ARROW_C_DATA_INTEROP)
    set(QORE_GRPC_HAVE_ARROW_C_DATA_INTEROP ${QORE_HAVE_ARROW_C_DATA_INTEROP})
elseif(QORE_GRPC_HAVE_COLUMNAR_RESULT_V2)
    set(_save_CMAKE_REQUIRED_INCLUDES "${CMAKE_REQUIRED_INCLUDES}")
    set(_save_CMAKE_REQUIRED_LIBRARIES "${CMAKE_REQUIRED_LIBRARIES}")
    set(CMAKE_REQUIRED_INCLUDES ${QORE_INCLUDE_DIRS})
    set(CMAKE_REQUIRED_LIBRARIES ${QORE_LIBRARY})
    check_cxx_source_compiles("
#include <qore/Qore.h>

#ifndef QORE_HAVE_ARROW_C_DATA_INTEROP
#error missing QORE_HAVE_ARROW_C_DATA_INTEROP
#endif

#include <qore/QoreColumnarResult.h>

int main() {
    (void)&qore_columnar_result_export_arrow_c_data;
    (void)&qore_columnar_result_import_arrow_c_data;
    (void)&qore_arrow_schema_release;
    (void)&qore_arrow_array_release;
    return 0;
}
" QORE_GRPC_HAVE_ARROW_C_DATA_INTEROP)
    set(CMAKE_REQUIRED_INCLUDES "${_save_CMAKE_REQUIRED_INCLUDES}")
    set(CMAKE_REQUIRED_LIBRARIES "${_save_CMAKE_REQUIRED_LIBRARIES}")
endif()

if(QORE_GRPC_HAVE_ARROW_C_DATA_INTEROP)
    add_definitions(-DQORE_GRPC_HAVE_ARROW_C_DATA_INTEROP=1)
endif()
message(STATUS "Qore Arrow C Data interop API support: ${QORE_GRPC_HAVE_ARROW_C_DATA_INTEROP}")

if(DEFINED QORE_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS)
    set(QORE_GRPC_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS ${QORE_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS})
elseif(QORE_GRPC_HAVE_ARROW_C_DATA_INTEROP)
    set(_save_CMAKE_REQUIRED_INCLUDES "${CMAKE_REQUIRED_INCLUDES}")
    set(_save_CMAKE_REQUIRED_LIBRARIES "${CMAKE_REQUIRED_LIBRARIES}")
    set(CMAKE_REQUIRED_INCLUDES ${QORE_INCLUDE_DIRS})
    set(CMAKE_REQUIRED_LIBRARIES ${QORE_LIBRARY})
    check_cxx_source_compiles("
#include <qore/Qore.h>

#ifndef QORE_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS
#error missing QORE_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS
#endif

int main() {
    return 0;
}
" QORE_GRPC_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS)
    set(CMAKE_REQUIRED_INCLUDES "${_save_CMAKE_REQUIRED_INCLUDES}")
    set(CMAKE_REQUIRED_LIBRARIES "${_save_CMAKE_REQUIRED_LIBRARIES}")
endif()

if(QORE_GRPC_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS)
    add_definitions(-DQORE_GRPC_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS=1)
endif()
message(STATUS "Qore Arrow C Data temporal buffer support: ${QORE_GRPC_HAVE_ARROW_C_DATA_TEMPORAL_BUFFERS}")

# Check for C++17
include(CheckCXXCompilerFlag)
CHECK_CXX_COMPILER_FLAG("-std=c++17" COMPILER_SUPPORTS_CXX17)
if(COMPILER_SUPPORTS_CXX17)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17")
else()
    message(FATAL_ERROR "The compiler ${CMAKE_CXX_COMPILER} has no C++17 support. Please use a different C++ compiler.")
endif()

# gRPC types QPP (hashdecls, constants — no ProtobufSchema, which is in the built-in protobuf module)
set(QPP_SRC
    src/qc_grpc_types.qpp
)

set(CPP_SRC
    src/grpc-module.cpp
)

# Apache Arrow is required for Arrow Flight support (IPC, schema, record batches)
find_package(Arrow CONFIG REQUIRED)
message(STATUS "Found Apache Arrow: ${ARROW_FULL_SO_VERSION}")
message(STATUS "Arrow include dirs: ${ARROW_INCLUDE_DIR}")

list(APPEND QPP_SRC
    src/QC_ArrowSchema.qpp
    src/QC_ArrowRecordBatch.qpp
    src/QC_ArrowIpc.qpp
)
list(APPEND CPP_SRC
    src/QoreArrowHelper.cpp
)

qore_wrap_qpp_value(QPP_SOURCES METALIST QPP_META_SRC ${QPP_SRC})

foreach (it ${QPP_SOURCES})
    GET_FILENAME_COMPONENT(_outfile ${it} NAME_WE)
    set(QPP_DOX ${QPP_DOX} ${CMAKE_CURRENT_BINARY_DIR}/${_outfile}.dox.h)
endforeach()

set(module_name "grpc")

set(QMOD
    qlib/GrpcUtil
    qlib/GrpcDataProvider
    qlib/ArrowFlightDataProvider
    qlib/SalesforcePubSubDataProvider
)

set(QORE_DOX_TMPL_SRC
    docs/mainpage.dox.tmpl
)

add_library(${module_name} MODULE ${CPP_SRC} ${QPP_SOURCES})

include_directories(${CMAKE_SOURCE_DIR}/src)
include_directories(${CMAKE_CURRENT_BINARY_DIR})
target_include_directories(${module_name} PRIVATE $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}>)

add_custom_target(QORE_INC_FILES DEPENDS ${QORE_INC_SRC})
add_dependencies(${module_name} QORE_INC_FILES)

target_link_libraries(${module_name} ${QORE_LIBRARY} Arrow::arrow_shared)
# Link Arrow IPC target if split into a separate library (some Arrow builds)
if(TARGET Arrow::arrow_ipc_shared)
    target_link_libraries(${module_name} Arrow::arrow_ipc_shared)
elseif(TARGET Arrow::arrow_ipc)
    target_link_libraries(${module_name} Arrow::arrow_ipc)
endif()

set(MODULE_DOX_INPUT ${CMAKE_CURRENT_BINARY_DIR}/mainpage.dox ${QPP_DOX})
string(REPLACE ";" " " MODULE_DOX_INPUT "${MODULE_DOX_INPUT}")

if (DEFINED ENV{DOXYGEN_EXECUTABLE})
    set(DOXYGEN_EXECUTABLE $ENV{DOXYGEN_EXECUTABLE})
endif()

set(MODULE_DOX_INPUT ${CMAKE_BINARY_DIR})
qore_external_binary_module(${module_name} ${PROJECT_VERSION})

qore_dist(${PROJECT_VERSION})

qore_user_modules("${QMOD}")
qore_external_user_module("qlib/GrpcUtil" "")
qore_external_user_module("qlib/GrpcDataProvider" "")
qore_external_user_module("qlib/ArrowFlightDataProvider" "")
qore_external_user_module("qlib/SalesforcePubSubDataProvider" "")

# Reconcile the installed i18n catalog root against the fragments these modules
# currently own.  Installing catalogs is otherwise additive: a fragment installed by
# an earlier generation of these sources survives every later install, is still
# discovered, and makes catalog composition fail as soon as the current generation
# describes the same app differently.
#
# This must come after every call above that installs catalogs, both because those
# calls record the fragment set and because install() rules run in declaration order,
# which is what publishes the manifest after the fragments it describes.  Removals are
# scoped to this project, so fragments Qore and other products install into the same
# shared catalog root are untouched.  Guarded because the helper arrived in Qore 2.3.
if (COMMAND qore_finalize_catalog_install)
    qore_finalize_catalog_install()
endif()

# install qpp metadata files
if (COMMAND qore_install_qpp_metadata)
    qore_install_qpp_metadata(${module_name} ${QPP_META_SRC})
else()
    install(FILES ${QPP_META_SRC}
            DESTINATION ${CMAKE_INSTALL_DATADIR}/qore/metadata)
endif()

qore_config_info()

if (DOXYGEN_FOUND)
    qore_wrap_dox(QORE_DOX_SRC ${QORE_DOX_TMPL_SRC})
    add_custom_target(QORE_MOD_DOX_FILES DEPENDS ${QORE_DOX_SRC})
    add_dependencies(docs-module QORE_MOD_DOX_FILES)

    # Two-phase doc build: the initial pass (docs-module) generates grpc.tag with empty
    # TAGFILES. User module docs (docs-GrpcUtil, docs-GrpcDataProvider) are then built using
    # grpc.tag, generating their own tag files. The final pass (docs-module-final) rebuilds
    # the binary module docs with user module tag files in TAGFILES, enabling @ref
    # cross-references from the mainpage into user module symbols.

    # Suppress unresolved cross-reference warnings in the initial pass
    file(APPEND ${CMAKE_BINARY_DIR}/Doxyfile
        "\n# Suppress warnings for initial pass (no user module TAGFILES available)\nWARN_IF_DOC_ERROR = NO\n")

    # Create final-pass Doxyfile from the binary module's Doxyfile with user module tag files
    set(_tagfiles "${CMAKE_BINARY_DIR}/GrpcUtil.tag=../GrpcUtil/html "
        "${CMAKE_BINARY_DIR}/GrpcDataProvider.tag=../GrpcDataProvider/html")
    set(_doc_deps docs-GrpcUtil docs-GrpcDataProvider docs-ArrowFlightDataProvider
        docs-SalesforcePubSubDataProvider)
    string(APPEND _tagfiles
        " ${CMAKE_BINARY_DIR}/ArrowFlightDataProvider.tag=../ArrowFlightDataProvider/html"
        " ${CMAKE_BINARY_DIR}/SalesforcePubSubDataProvider.tag="
        "../SalesforcePubSubDataProvider/html")

    file(COPY_FILE ${CMAKE_BINARY_DIR}/Doxyfile ${CMAKE_BINARY_DIR}/Doxyfile.final)
    file(APPEND ${CMAKE_BINARY_DIR}/Doxyfile.final
        "\n# Final pass: enable user module cross-references and re-enable doc error warnings\n"
        "TAGFILES = ${_tagfiles}\n"
        "WARN_IF_DOC_ERROR = YES\n")

    add_custom_target(docs-module-final
        COMMAND ${DOXYGEN_EXECUTABLE} ${CMAKE_BINARY_DIR}/Doxyfile.final
        COMMAND ${QORE_DOCS_ENV} ${QORE_QDX_COMMAND} --post
            ${CMAKE_BINARY_DIR}/docs/${module_name}/html
            ${CMAKE_BINARY_DIR}/docs/${module_name}/html/search
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        COMMENT "Generating API documentation with Doxygen (final pass with user module cross-references)"
        VERBATIM
    )
    add_dependencies(docs-module-final ${_doc_deps})
    add_dependencies(docs docs-module-final)
endif()
