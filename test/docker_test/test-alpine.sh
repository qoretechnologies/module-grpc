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

echo "export QORE_UID=1000" >> ${ENV_FILE}
echo "export QORE_GID=1000" >> ${ENV_FILE}

. ${ENV_FILE}

export MAKE_JOBS=4

# install interop test dependencies
pip3 install --break-system-packages grpcio grpcio-tools 2>/dev/null \
    || pip3 install grpcio grpcio-tools || true
# pyarrow: only install from binary wheel (no source build on Alpine/musl);
# interop tests gracefully skip if pyarrow is unavailable
pip3 install --break-system-packages --only-binary :all: pyarrow 2>/dev/null \
    || pip3 install --only-binary :all: pyarrow || true

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

# Verify that source-owned provider presentation catalogs match this checkout.
${MODULE_SRC_DIR}/test/docker_test/check-i18n.sh

# add Qore user and group
if ! grep -q "^qore:x:${QORE_GID}" /etc/group; then
    addgroup -g ${QORE_GID} qore
fi
if ! grep -q "^qore:x:${QORE_UID}" /etc/passwd; then
    adduser -u ${QORE_UID} -D -G qore -h /home/qore -s /bin/bash qore
fi

# own everything by the qore user
chown -R qore:qore ${MODULE_SRC_DIR}

# run the tests
export QORE_MODULE_DIR=${MODULE_SRC_DIR}/qlib:${QORE_MODULE_DIR}
cd ${MODULE_SRC_DIR}
for test in test/*.qtest; do
    gosu qore:qore qore --enable-debug $test -vv
done
