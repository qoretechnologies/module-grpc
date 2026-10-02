# Copyright (C) 2026 Qore Technologies, s.r.o.
# SPDX-License-Identifier: MIT
%global source_date_epoch_from_changelog 1
%global use_source_date_epoch_as_buildtime 1
%if v"%{rpmversion}" >= v"4.20"
%global build_mtime_policy clamp_to_source_date_epoch
%else
%global clamp_mtime_to_source_date_epoch 1
%endif
%bcond_without tests
%bcond_without docs
# Retain LLVM debug information; dwz cannot process all AOT DWARF forms.
%global _find_debuginfo_dwz_opts %{nil}
Name: qore-grpc-module
Version: 1.0.0
Release: 1%{?dist}
Summary: gRPC, Arrow Flight and Salesforce Pub/Sub for Qore
License: MIT AND Apache-2.0 AND CC0-1.0
URL: https://github.com/qoretechnologies/module-grpc
Source0: %{name}-%{version}.tar.xz
BuildRequires: cmake >= 3.21
BuildRequires: make
BuildRequires: gcc-c++
BuildRequires: pkgconfig(arrow)
BuildRequires: qore-devel >= 3.0.0~
BuildRequires: qore-rpm-macros >= 3.0.0~
%{?qore_enable_aot_post}
%if %{with tests}
BuildRequires: python3 >= 3.11
BuildRequires: python3dist(grpcio)
BuildRequires: python3dist(grpcio-tools)
BuildRequires: python3dist(pyarrow)
BuildRequires: qore-process-module
BuildRequires: qore-misc-tools >= 3.0.0~
%endif
%if %{with docs}
BuildRequires: doxygen
%if 0%{?suse_version}
BuildRequires: util-linux
%else
BuildRequires: util-linux-core
%endif
%endif

%description
Native Arrow IPC, schema and record-batch bindings, plus compiled Qore modules
for gRPC, Arrow Flight and Salesforce Pub/Sub. Includes compiler metadata,
provider resources and translations. Uses the distribution's shared Arrow library.

%if %{with docs}
%package doc
Summary: Qore gRPC and Arrow Flight API documentation and examples
BuildArch: noarch
%description doc
HTML API references for the native module and its four Qore modules, with
interoperability fixtures. The included TLS identities are public test data.
%endif

%prep
%autosetup
%build
%{?set_build_flags}
. %{_rpmconfigdir}/qore/module-env.sh
qore_set_source_prefix_maps "%{qore_debug_source_dir}"
cmake -S . -B build -G 'Unix Makefiles' \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS_RELEASE=-DNDEBUG \
  -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_SKIP_RPATH=ON -DCMAKE_IGNORE_PREFIX_PATH=/usr/local \
  -DQore_DIR=%{_libdir}/cmake/Qore -DQORE_EXECUTABLE=/usr/bin/qore \
  -DQORE_QPP_EXECUTABLE=/usr/bin/qpp -DQORE_QCC_EXECUTABLE=/usr/bin/qcc \
  -DQORE_BUILD_AOT_MODULES=ON -DQORE_AOT_LINK_SOURCE_MODULES=OFF \
  -DQORE_GRPC_STRICT_DOCS=ON \
  -DQORE_AOT_MODULE_OPT_LEVEL=3 -DQORE_GENERATE_JAVA_BINDINGS=OFF \
  -DQORE_QM_METADATA_ENV:STRING="QORE_MODULE_DIR=$QORE_MODULE_DIR:$PWD/qlib;QORE_MODULE_DIR_ONLY=1;QORE_INCLUDE_DIR=;LD_LIBRARY_PATH=" \
  -DCMAKE_DISABLE_FIND_PACKAGE_Doxygen=%{!?with_docs:ON}%{?with_docs:OFF}
cmake --build build -- %{?_smp_mflags}
%if %{with docs}
cmake --build build --target docs -- %{?_smp_mflags}
%endif
%install
DESTDIR=%{buildroot} cmake --install build
%qore_install_aot_sources qlib
chmod 755 %{buildroot}%{_libdir}/qore-modules/grpc-api-*.qmod
%if %{with docs}
install -d %{buildroot}%{_docdir}/%{name}-doc
cp -a build/docs %{buildroot}%{_docdir}/%{name}-doc/
cp -a test %{buildroot}%{_docdir}/%{name}-doc/examples
hardlink -t -O %{buildroot}%{_docdir}/%{name}-doc
%endif
%check
%if %{with tests}
. %{_rpmconfigdir}/qore/module-env.sh
python3 -B -W error debian/tests/test_aot_metadata.py
%if %{with docs}
python3 -B -W error test/test-doc-index.py --build-dir build -v
%endif
python3 -c 'import grpc, grpc_tools.protoc, pyarrow.flight'
qore -b --enable-debug -l process -e 'printf("process fixture available\n");'
mkdir -p build/package-tests
cp -a test build/package-tests/
export QORE_GRPC_TEST_MODULE_DIR="$PWD/build"
export QORE_GRPC_TEST_QMOD_DIR="$PWD/build/qlib-qmod"
(
  cd build/package-tests
  python3 -m grpc_tools.protoc -Itest --python_out=test/interop \
    --grpc_python_out=test/interop test/test.proto
  PYTHONPATH=test/interop python3 -c 'import test_pb2, test_pb2_grpc'
  for suite in test/*.qtest; do
    timeout 600 /usr/bin/qore -b --enable-debug \
      -l "$QORE_GRPC_TEST_MODULE_DIR/grpc-api-$(/usr/bin/qore --latest-module-api).qmod" \
      -l "$QORE_GRPC_TEST_QMOD_DIR/GrpcUtil/GrpcUtil.qmod" \
      -l "$QORE_GRPC_TEST_QMOD_DIR/GrpcDataProvider/GrpcDataProvider.qmod" \
      -l "$QORE_GRPC_TEST_QMOD_DIR/ArrowFlightDataProvider/ArrowFlightDataProvider.qmod" \
      -l "$QORE_GRPC_TEST_QMOD_DIR/SalesforcePubSubDataProvider/SalesforcePubSubDataProvider.qmod" \
      "$suite" -v
  done
)
qore-data-provider-i18n --no-color --check-source-tree --require-standard-locales \
  --require-complete-locales --output "$PWD/qlib"
%endif
%files
%license LICENSE COPYING.MIT debian/copyright rpm/licenses/*.txt
%doc README*
%{_libdir}/qore-modules/*
%{_datadir}/qore-modules/*
%{_datadir}/qore/metadata/*
%{_datadir}/qore/i18n/*
%{_datadir}/qore/i18n/.qore-catalog-manifests/%{name}.manifest
%if %{with docs}
%files doc
%license LICENSE COPYING.MIT debian/copyright rpm/licenses/*.txt
%doc %{_docdir}/%{name}-doc/
%endif
%changelog
* Fri Oct 02 2026 David Nichols <david@qore.org> - 1.0.0-1
- Build with the packaged Qore SDK and system Arrow library.
- Include AOT modules, metadata, translations, API references and protocol licenses.
- Require offline gRPC and Arrow Flight interoperability fixtures during checks.
