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

# Find protobuf - try config mode first (required for protobuf v5+), fall back to module mode
# On macOS with MacPorts, protobuf is installed under /opt/local/libexec/protobufN-cpp/
if(APPLE)
    file(GLOB _macports_protobuf_dirs "/opt/local/libexec/protobuf*-cpp")
    if(_macports_protobuf_dirs)
        # Use the last (highest version) match
        list(SORT _macports_protobuf_dirs)
        list(GET _macports_protobuf_dirs -1 _macports_protobuf_dir)
        list(APPEND CMAKE_PREFIX_PATH "${_macports_protobuf_dir}")
        message(STATUS "Auto-detected MacPorts protobuf: ${_macports_protobuf_dir}")
    endif()
endif()

find_package(Protobuf CONFIG QUIET)
if(NOT Protobuf_FOUND)
    find_package(Protobuf REQUIRED)
endif()

# Config mode provides imported targets but not the legacy variables; set them for uniform usage
if(TARGET protobuf::libprotobuf AND NOT Protobuf_LIBRARIES)
    set(Protobuf_LIBRARIES protobuf::libprotobuf)
    get_target_property(Protobuf_INCLUDE_DIRS protobuf::libprotobuf INTERFACE_INCLUDE_DIRECTORIES)
endif()

message(STATUS "Found Protobuf: ${Protobuf_VERSION}")
message(STATUS "Protobuf include dirs: ${Protobuf_INCLUDE_DIRS}")
message(STATUS "Protobuf libraries: ${Protobuf_LIBRARIES}")

# Check for C++17
include(CheckCXXCompilerFlag)
CHECK_CXX_COMPILER_FLAG("-std=c++17" COMPILER_SUPPORTS_CXX17)
if(COMPILER_SUPPORTS_CXX17)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17")
else()
    message(FATAL_ERROR "The compiler ${CMAKE_CXX_COMPILER} has no C++17 support. Please use a different C++ compiler.")
endif()

set(QPP_SRC
    src/QC_ProtobufSchema.qpp
)

set(CPP_SRC
    src/grpc-module.cpp
    src/QoreProtobufSchema.cpp
    src/ProtobufHelper.cpp
)

qore_wrap_qpp_value(QPP_SOURCES METALIST QPP_META_SRC ${QPP_SRC})

foreach (it ${QPP_SOURCES})
    GET_FILENAME_COMPONENT(_outfile ${it} NAME_WE)
    set(QPP_DOX ${QPP_DOX} ${CMAKE_CURRENT_BINARY_DIR}/${_outfile}.dox.h)
endforeach()

set(module_name "grpc")

set(QMOD
    qlib/Grpc
    qlib/GrpcDataProvider
)

set(QORE_DOX_TMPL_SRC
    docs/mainpage.dox.tmpl
)

add_library(${module_name} MODULE ${CPP_SRC} ${QPP_SOURCES})

include_directories(${CMAKE_SOURCE_DIR}/src)
include_directories(${CMAKE_CURRENT_BINARY_DIR})
include_directories(${Protobuf_INCLUDE_DIRS})
target_include_directories(${module_name} PRIVATE $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}>)

add_custom_target(QORE_INC_FILES DEPENDS ${QORE_INC_SRC})
add_dependencies(${module_name} QORE_INC_FILES)

target_link_libraries(${module_name} ${Protobuf_LIBRARIES} ${QORE_LIBRARY})

set(MODULE_DOX_INPUT ${CMAKE_CURRENT_BINARY_DIR}/mainpage.dox ${QPP_DOX})
string(REPLACE ";" " " MODULE_DOX_INPUT "${MODULE_DOX_INPUT}")

if (DEFINED ENV{DOXYGEN_EXECUTABLE})
    set(DOXYGEN_EXECUTABLE $ENV{DOXYGEN_EXECUTABLE})
endif()

set(MODULE_DOX_INPUT ${CMAKE_BINARY_DIR})
qore_external_binary_module(${module_name} ${PROJECT_VERSION})

qore_dist(${PROJECT_VERSION})

qore_user_modules("${QMOD}")
qore_external_user_module("qlib/Grpc" "")
qore_external_user_module("qlib/GrpcDataProvider" "")

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
    # TAGFILES. User module docs (docs-Grpc, docs-GrpcDataProvider) are then built using
    # grpc.tag, generating their own tag files. The final pass (docs-module-final) rebuilds
    # the binary module docs with user module tag files in TAGFILES, enabling @ref
    # cross-references from the mainpage into user module symbols.

    # Suppress unresolved cross-reference warnings in the initial pass
    file(APPEND ${CMAKE_BINARY_DIR}/Doxyfile
        "\n# Suppress warnings for initial pass (no user module TAGFILES available)\nWARN_IF_DOC_ERROR = NO\n")

    # Create final-pass Doxyfile from the binary module's Doxyfile with user module tag files
    file(COPY_FILE ${CMAKE_BINARY_DIR}/Doxyfile ${CMAKE_BINARY_DIR}/Doxyfile.final)
    file(APPEND ${CMAKE_BINARY_DIR}/Doxyfile.final
        "\n# Final pass: enable user module cross-references and re-enable doc error warnings\n"
        "TAGFILES = ${CMAKE_BINARY_DIR}/Grpc.tag=../Grpc/html "
        "${CMAKE_BINARY_DIR}/GrpcDataProvider.tag=../GrpcDataProvider/html\n"
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
    add_dependencies(docs-module-final docs-Grpc docs-GrpcDataProvider)
    add_dependencies(docs docs-module-final)
endif()
