#!/bin/bash

set -e
set -x

ENV_FILE=/tmp/env.sh

. ${ENV_FILE}

# setup MODULE_SRC_DIR env var
cwd=`pwd`
if [ -z "${MODULE_SRC_DIR}" ]; then
    if [ -e "$cwd/src/grpc-module.cpp" ]; then
        MODULE_SRC_DIR=$cwd
    else
        MODULE_SRC_DIR=$WORKDIR/module-grpc
    fi
fi
echo "export MODULE_SRC_DIR=${MODULE_SRC_DIR}" >> ${ENV_FILE}

echo "export QORE_UID=999" >> ${ENV_FILE}
echo "export QORE_GID=999" >> ${ENV_FILE}

. ${ENV_FILE}

export MAKE_JOBS=4

# The interop tests run against Python gRPC (test/grpc-interop.qtest, with server stubs that grpc_tools generates)
# and PyArrow Flight (test/arrow-flight-interop.qtest), which the qore-test-base image provides.  The tests skip their
# interop cases without them, so a job without them would pass without running those cases: it fails instead.  Each
# check runs in its own interpreter, as the tests do: on Alpine, one process cannot load both grpc and pyarrow.flight.
if ! python3 -c 'import grpc, grpc_tools.protoc; from google.protobuf import descriptor'; then
    echo "ERROR: Python gRPC (grpcio, grpcio-tools, protobuf) is missing from the image; test/grpc-interop.qtest" \
        "cannot run its Python interop cases" >&2
    exit 1
fi
if ! python3 -c 'import pyarrow.flight'; then
    echo "ERROR: PyArrow Flight (pyarrow.flight) is missing from the image; test/arrow-flight-interop.qtest cannot" \
        "run its interop cases" >&2
    exit 1
fi

# test/grpc-interop.qtest runs grpcurl, which the qore-test-base image provides, against the module's server, and
# skips those cases without it
if ! command -v grpcurl > /dev/null 2>&1; then
    echo "ERROR: grpcurl is missing from the image; test/grpc-interop.qtest cannot run its grpcurl cases" >&2
    exit 1
fi
grpcurl -version

# build module and install
echo && echo "-- building module --"
mkdir -p ${MODULE_SRC_DIR}/build
cd ${MODULE_SRC_DIR}/build
cmake .. -DCMAKE_BUILD_TYPE=debug -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}
make -j${MAKE_JOBS}
make install

# Verify that source-owned provider presentation catalogs match this checkout.
${MODULE_SRC_DIR}/test/docker_test/check-i18n.sh

# add Qore user and group
groupadd -o -g ${QORE_GID} qore
useradd -o -m -d /home/qore -u ${QORE_UID} -g ${QORE_GID} qore

# own everything by the qore user
chown -R qore:qore ${MODULE_SRC_DIR}

# run the tests
export QORE_MODULE_DIR=${MODULE_SRC_DIR}/qlib:${QORE_MODULE_DIR}
cd ${MODULE_SRC_DIR}
for test in test/*.qtest; do
    gosu qore:qore qore --enable-debug $test -vv
done
