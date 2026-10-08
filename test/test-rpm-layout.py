#!/usr/bin/env python3
# Copyright (C) 2026 Qore Technologies, s.r.o.
# SPDX-License-Identifier: MIT
"""Verify the actual staged RPM licenses, metadata and runnable examples."""
import argparse
from collections import defaultdict
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[1]
OPTIONS = None


def staged(path: Path) -> Path:
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Installed directories must be absolute paths without parent traversal')
    return OPTIONS.root / path.relative_to('/')


class RpmLayout(unittest.TestCase):
    def test_complete_licenses_and_deduplication(self):
        sources = [SOURCE / name for name in ('LICENSE', 'COPYING.MIT', 'debian/copyright')]
        sources += sorted((SOURCE / 'rpm/licenses').glob('*.txt'))
        packages = ['qore-grpc-module']
        if OPTIONS.doc_dir:
            packages.append('qore-grpc-module-doc')
        for package in packages:
            directory = staged(OPTIONS.license_dir) / package
            self.assertEqual({p.name for p in sources}, {p.name for p in directory.iterdir()})
            for source in sources:
                with self.subTest(package=package, license=source.name):
                    target = directory / source.name
                    self.assertEqual(source.read_bytes(), target.read_bytes())
                    self.assertEqual(target.stat().st_mode & 0o777, 0o644)
            self.assertEqual((directory / 'LICENSE').stat().st_ino,
                             (directory / 'COPYING.MIT').stat().st_ino)

    def test_metadata_preserves_names_and_deduplicates_identical_payloads(self):
        directory = staged(OPTIONS.data_dir) / 'qore/metadata/grpc'
        files = list(directory.glob('*.qm.meta.json'))
        self.assertEqual({p.name for p in files},
                         {name + '.qm.meta.json' for name in
                          ('GrpcUtil', 'GrpcDataProvider', 'ArrowFlightDataProvider', 'SalesforcePubSubDataProvider')})
        payloads = defaultdict(list)
        for path in files:
            payloads[path.read_bytes()].append(path)
        for paths in payloads.values():
            with self.subTest(files=[p.name for p in paths]):
                self.assertEqual(len({(p.stat().st_dev, p.stat().st_ino) for p in paths}), 1)

    def test_only_runtime_examples_with_distribution_interpreters(self):
        if OPTIONS.doc_dir is None:
            self.assertFalse((staged(OPTIONS.license_dir) / 'qore-grpc-module-doc').exists())
            return
        directory = staged(OPTIONS.doc_dir) / 'qore-grpc-module-doc/examples'
        sources = list((SOURCE / 'test').glob('*.qtest')) + list((SOURCE / 'test').glob('*.proto'))
        sources += [SOURCE / 'test' / name for name in
                    ('certs/server.crt', 'certs/server.key', 'interop/interop_server.py',
                     'pyarrow_flight_client.py', 'pyarrow_flight_server.py')]
        self.assertEqual(len(sources), 20)
        self.assertEqual({p.relative_to(SOURCE / 'test') for p in sources},
                         {p.relative_to(directory) for p in directory.rglob('*') if p.is_file()})
        for source in sources:
            target = directory / source.relative_to(SOURCE / 'test')
            original = source.read_bytes()
            expected = original
            if source.suffix in ('.qtest', '.py'):
                interpreter = b'qore' if source.suffix == '.qtest' else b'python3'
                prefix = b'#!/usr/bin/env ' + interpreter + b'\n'
                self.assertTrue(original.startswith(prefix), source)
                expected = b'#!/usr/bin/' + interpreter + b'\n' + original[len(prefix):]
                self.assertTrue(target.stat().st_mode & 0o111, target)
            with self.subTest(example=str(target)):
                self.assertEqual(expected, target.read_bytes())


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--license-dir', type=Path, required=True)
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--doc-dir', type=Path)
    OPTIONS, remaining = parser.parse_known_args()
    if not OPTIONS.root.is_dir():
        parser.error('The staged RPM root must exist')
    unittest.main(argv=[__file__, *remaining])
