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
Release: 5%{?dist}
Summary: Qore bindings for gRPC, Arrow Flight and Salesforce Pub/Sub
License: MIT AND Apache-2.0 AND CC0-1.0
URL: https://github.com/qoretechnologies/module-grpc
# Reproducible archive from the pinned Git revision in source-manifest.json.
Source0: https://api.opensuse.org/public/source/home:davidnichols:qore:testing/%{name}/%{name}-%{version}.tar.xz
BuildRequires: cmake >= 3.21
BuildRequires: make
BuildRequires: gcc-c++
BuildRequires: pkgconfig(arrow)
BuildRequires: qore-devel >= 3.0.0~
BuildRequires: qore-rpm-macros >= 3.0.0~
%{?qore_enable_aot_post}
%if %{with tests}
BuildRequires: python3 >= 3.11
%if 0%{?suse_version}
# OBS's SUSE Python packages expose unversioned package-name aliases, but
# do not necessarily generate Fedora's python3dist capability namespace.
BuildRequires: python3-grpcio
BuildRequires: python3-grpcio-tools
BuildRequires: python3-pyarrow
%else
BuildRequires: python3dist(grpcio)
BuildRequires: python3dist(grpcio-tools)
BuildRequires: python3dist(pyarrow)
%endif
BuildRequires: qore-process-module
BuildRequires: qore-misc-tools >= 3.0.0~
%endif
%if %{with docs}
BuildRequires: doxygen
%endif
%if 0%{?suse_version}
BuildRequires: util-linux
%else
BuildRequires: util-linux-core
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
install -d %{buildroot}%{_licensedir}/%{name}
install -m644 LICENSE COPYING.MIT debian/copyright rpm/licenses/*.txt %{buildroot}%{_licensedir}/%{name}/
hardlink -t -O %{buildroot}%{_licensedir}/%{name} %{buildroot}%{_datadir}/qore/metadata
%if %{with docs}
install -d %{buildroot}%{_docdir}/%{name}-doc
cp -a build/docs %{buildroot}%{_docdir}/%{name}-doc/
install -d %{buildroot}%{_docdir}/%{name}-doc/examples/interop
cp -a test/*.qtest test/*.proto test/certs %{buildroot}%{_docdir}/%{name}-doc/examples/
cp -a test/pyarrow_flight_client.py test/pyarrow_flight_server.py %{buildroot}%{_docdir}/%{name}-doc/examples/
cp -a test/interop/interop_server.py %{buildroot}%{_docdir}/%{name}-doc/examples/interop/
# Installed examples resolve the distribution interpreters independently of PATH.
sed -i '1s|^#!/usr/bin/env qore$|#!/usr/bin/qore|' %{buildroot}%{_docdir}/%{name}-doc/examples/*.qtest
sed -i '1s|^#!/usr/bin/env python3$|#!/usr/bin/python3|' \
  %{buildroot}%{_docdir}/%{name}-doc/examples/*.py \
  %{buildroot}%{_docdir}/%{name}-doc/examples/interop/*.py
install -d %{buildroot}%{_licensedir}/%{name}-doc
install -m644 LICENSE COPYING.MIT debian/copyright rpm/licenses/*.txt %{buildroot}%{_licensedir}/%{name}-doc/
hardlink -t -O %{buildroot}%{_docdir}/%{name}-doc %{buildroot}%{_licensedir}/%{name}-doc
%endif
%check
%if %{with tests}
. %{_rpmconfigdir}/qore/module-env.sh
python3 -B -W error test/test-rpm-dependencies.py -v
python3 -B -W error test/test-rpm-layout.py --root %{buildroot} \
  --license-dir %{_licensedir} --data-dir %{_datadir} %{?with_docs:--doc-dir %{_docdir}} -v
python3 -B -W error test/test_uninstall.py -v
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
%license %{_licensedir}/%{name}
%doc README*
%{_libdir}/qore-modules/*
%{_datadir}/qore-modules/*
%{_datadir}/qore/metadata/*
%{_datadir}/qore/i18n/*
%{_datadir}/qore/i18n/.qore-catalog-manifests/%{name}.manifest
%if %{with docs}
%files doc
%license %{_licensedir}/%{name}-doc
%doc %{_docdir}/%{name}-doc/
%endif
%changelog
* Thu Oct 08 2026 David Nichols <david@qore.org> - 1.0.0-5
- Fix Salesforce Pub/Sub credit accounting during callbacks and concurrent replenishment.
- Install runnable protocol examples with distribution interpreter paths and no version-control files.
- Deduplicate identical licenses and metadata while preserving every installed path.
- Use a capitalized package summary and verify the staged package layout.
- Identify the generated source archive's OBS download location.

* Thu Oct 08 2026 David Nichols <david@qore.org> - 1.0.0-4
- Isolate simulated distribution macros in dependency tests under layered OBS configuration.
- Check all distribution branches with tests enabled and disabled under inherited macros.

* Thu Oct 08 2026 David Nichols <david@qore.org> - 1.0.0-3
- Provide source-uninstall support and test staged, repeated and invalid manifests.
- Declare the tested CMake policy range for normalized installation paths.

* Thu Oct 08 2026 David Nichols <david@qore.org> - 1.0.0-2
- Resolve the Python interoperability fixtures through openSUSE's package aliases.
- Retain Fedora and Enterprise Linux Python distribution capabilities.

* Fri Oct 02 2026 David Nichols <david@qore.org> - 1.0.0-1
- Build with the packaged Qore SDK and system Arrow library.
- Include AOT modules, metadata, translations, API references and protocol licenses.
- Require offline gRPC and Arrow Flight interoperability fixtures during checks.
