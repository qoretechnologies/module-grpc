RPM packages
============

Copyright 2026 Qore Technologies, s.r.o.

``qore-grpc-module.spec`` builds the native Arrow bindings and four compiled
Qore modules with the packaged Qore 3 SDK and the distribution's shared Arrow
library. Runtime packages include compiler metadata, source fallback, provider
translations and license notices. API references and examples are in the
separate ``qore-grpc-module-doc`` package; standard RPM debug packages retain
native and Qore source information.

Build in a disposable distribution environment with the declared dependencies::

    rpmbuild -ba qore-grpc-module.spec

The source archive must be named ``qore-grpc-module-1.0.0.tar.xz`` and contain
this recipe and ``rpm/licenses``. Qore's RPM macros preserve AOT metadata across
stripping and install the matching Qore debug sources. The build uses Release
mode, the distribution's compiler flags, strict documentation checks and
``SOURCE_DATE_EPOCH`` from the changelog.

Tests run with debugging enabled and networking restricted to loopback.
Python gRPC, its protocol compiler and PyArrow Flight are mandatory test
fixtures. Checks cover all 13 Qore suites, generated documentation, AOT helper
behavior and complete provider translations. Live Salesforce account tests and
optional grpcurl comparisons remain separate integration checks.

As of 2026-10-02, Fedora 44 and Enterprise Linux 10 candidate RPMs pass builds,
installed runtime and SDK suites (1,768 assertions per installation), compiled
consumer execution without the SDK, and AOT/debug-source verification. The
only grpc_tools diagnostic accepted is the explicitly approved distribution
``pkg_resources`` deprecation; the package does not filter warnings. LLVM's
``.debug_names`` section is retained with the established Qore RPM debug policy.
Leap 16 qualification needs packaged PyArrow Flight and grpcio-tools fixtures.
Native ARM, upgrades, removal and repository publication remain separate gates.
Source hashes and detailed evidence are maintained in the qore-packaging repo.
