#!/usr/bin/env python3
# Copyright (C) 2026 Qore Technologies, s.r.o.
# SPDX-License-Identifier: MIT
"""Check the actual RPM parser's distribution-specific fixture requirements."""
from pathlib import Path
import subprocess
import unittest


SPEC = Path(__file__).resolve().parents[1] / 'qore-grpc-module.spec'
PACKAGES = {'python3-grpcio', 'python3-grpcio-tools', 'python3-pyarrow'}
CAPABILITIES = {'python3dist(grpcio)', 'python3dist(grpcio-tools)', 'python3dist(pyarrow)'}


def requirements(family: str, tests: bool = True, *, inherited_macros: tuple[str, ...] = ()) -> set[str]:
    command = ['rpmspec', '-q', '--buildrequires']
    for definition in inherited_macros:
        command += ['--define', definition]
    # RPM macros form a stack: --undefine exposes an earlier definition.
    # OBS may supply the same distribution macro in several inherited layers.
    # Explicit zero values isolate the numeric conditionals in this spec.
    for name in ('suse_version', 'fedora', 'rhel'):
        command += ['--define', name + ' 0']
    command += ['--define', {'suse': 'suse_version 1600', 'fedora': 'fedora 44', 'el': 'rhel 10'}[family]]
    command += ['--define', 'dist ' + {'suse': '.lp160', 'fedora': '.fc44', 'el': '.el10'}[family]]
    if not tests:
        command += ['--without', 'tests']
    result = subprocess.run(command + [str(SPEC)], check=True, capture_output=True, text=True)
    if result.stderr:
        raise AssertionError(result.stderr)
    return set(result.stdout.splitlines())


class RpmFixtureDependencies(unittest.TestCase):
    def test_inherited_distribution_layers_do_not_change_requirements(self):
        for family in ('suse', 'fedora', 'el'):
            for tests in (True, False):
                expected = requirements(family, tests)
                for depth in (1, 2, 4):
                    with self.subTest(family=family, tests=tests, depth=depth):
                        inherited = ('suse_version 1600', 'fedora 44', 'rhel 10') * depth
                        self.assertEqual(expected, requirements(family, tests, inherited_macros=inherited))

    def test_suse_uses_available_package_aliases(self):
        actual = requirements('suse')
        self.assertTrue(PACKAGES <= actual, actual)
        self.assertFalse(CAPABILITIES & actual, actual)
        self.assertIn('python3 >= 3.11', actual)
        self.assertIn('qore-process-module', actual)

    def test_fedora_and_el_keep_python_distribution_capabilities(self):
        for family in ('fedora', 'el'):
            with self.subTest(family=family):
                actual = requirements(family)
                self.assertTrue(CAPABILITIES <= actual, actual)
                self.assertFalse(PACKAGES & actual, actual)
                self.assertIn('python3 >= 3.11', actual)
                self.assertIn('qore-process-module', actual)

    def test_disabling_tests_removes_only_test_requirements(self):
        for family in ('suse', 'fedora', 'el'):
            with self.subTest(family=family):
                actual = requirements(family, tests=False)
                self.assertFalse((PACKAGES | CAPABILITIES | {'python3 >= 3.11', 'qore-process-module',
                                                           'qore-misc-tools >= 3.0.0~'}) & actual, actual)
                self.assertIn('pkgconfig(arrow)', actual)
                self.assertIn('qore-devel >= 3.0.0~', actual)
                self.assertIn('qore-rpm-macros >= 3.0.0~', actual)


if __name__ == '__main__':
    unittest.main()
