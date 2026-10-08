RPM interoperability fixtures
============================

Copyright 2026 Qore Technologies, s.r.o.

The RPM test suite requires Python 3.11 or newer, gRPC's Python runtime and
compiler, PyArrow with Flight support, and the Qore process module. These are
build-time test fixtures; they do not add Python dependencies to the shipped
Qore module.

On openSUSE, the spec resolves the Python fixtures through the packages'
``python3-grpcio``, ``python3-grpcio-tools`` and ``python3-pyarrow`` aliases.
Leap's native OBS packages do not always provide the ``python3dist(...)``
capabilities used by Fedora and Enterprise Linux. The latter platforms retain
their distribution-capability requirements. Leap's aliases select the default
Python 3 interpreter, including its versioned Python 3.13 packages.

Run ``python3 -B -W error test/test-rpm-dependencies.py -v`` to exercise the
actual RPM parser for all three distribution branches and the disabled-test
configuration. The same regression runs during the RPM's normal checks.
All gRPC and Arrow Flight interoperability suites remain enabled.
