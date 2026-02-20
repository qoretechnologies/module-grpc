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

# install protobuf development libraries
apt-get update -qq && apt-get install -y -qq libprotobuf-dev protobuf-compiler python3-pip curl

# install interop test dependencies
pip3 install --break-system-packages grpcio grpcio-tools 2>/dev/null \
    || pip3 install grpcio grpcio-tools || true

# install grpcurl for interop testing
GRPCURL_VERSION=1.9.3
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    GRPCURL_ARCH="linux_x86_64"
elif [ "$ARCH" = "aarch64" ]; then
    GRPCURL_ARCH="linux_arm64"
fi
if [ -n "$GRPCURL_ARCH" ]; then
    curl -sL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_${GRPCURL_ARCH}.tar.gz" \
        | tar xz -C /tmp grpcurl && chmod +x /tmp/grpcurl || true
fi

# build module and install
echo && echo "-- building module --"
mkdir -p ${MODULE_SRC_DIR}/build
cd ${MODULE_SRC_DIR}/build
cmake .. -DCMAKE_BUILD_TYPE=debug -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}
make -j${MAKE_JOBS}
make install

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
