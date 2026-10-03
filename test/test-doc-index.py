#!/usr/bin/env python3
# Copyright (C) 2026 Qore Technologies, s.r.o.
# SPDX-License-Identifier: MIT
"""Check generated gRPC API links, tables, and strict documentation failures."""
import argparse
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import tempfile
import unittest
from urllib.parse import urlsplit, unquote
import xml.etree.ElementTree as ET

BUILD = None


class Html(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.assets = []
        self.ids = set()
        self.tables = []
        self.table = None
        self.row = None
        self.cell = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag in ("img", "script") and "src" in attrs:
            self.assets.append(attrs["src"])
        if tag == "link" and "href" in attrs and any(
                rel in attrs.get("rel", "").split() for rel in ("stylesheet", "icon")):
            self.assets.append(attrs["href"])
        if tag == "table":
            self.table = []
        elif tag == "tr" and self.table is not None:
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.cell = ""

    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.cell is not None:
            self.row.append(self.cell.strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.table.append(self.row)
            self.row = None
        elif tag == "table" and self.table is not None:
            self.tables.append(self.table)
            self.table = None


def html(path):
    parser = Html()
    parser.feed(path.read_text())
    return parser


class GrpcDocumentationTest(unittest.TestCase):
    def test_public_api_indexes(self):
        expected = {
            "grpc": "Qore::Grpc::ArrowSchema",
            "GrpcUtil": "Grpc::GrpcClient",
            "GrpcDataProvider": "GrpcDataProvider::GrpcReflectionClient",
            "ArrowFlightDataProvider": "ArrowFlightDataProvider::ArrowFlightConnection",
            "SalesforcePubSubDataProvider": "SalesforcePubSubDataProvider::SalesforcePubSubClient",
        }
        for module, name in expected.items():
            with self.subTest(module=module):
                index = ET.parse(BUILD / (module + ".tag")).getroot()
                self.assertIn(name, {c.findtext("name") for c in index.findall("compound")})
                self.assertFalse(any(c.get("kind") == "file" and c.findtext("name", "").endswith(".cpp")
                                     for c in index.findall("compound")))

    def test_local_cross_module_links(self):
        count = 0
        for module in ("grpc", "GrpcUtil"):
            for page in (BUILD / "docs" / module / "html").glob("*.html"):
                for href in html(page).links:
                    if not href.startswith("../../"):
                        continue
                    link = urlsplit(href)
                    target = (page.parent / unquote(link.path)).resolve()
                    self.assertTrue(target.is_file(), (page.name, href))
                    if link.fragment:
                        self.assertIn(unquote(link.fragment), html(target).ids, (page.name, href))
                    count += 1
        self.assertGreater(count, 20)

    def test_external_api_links(self):
        pages = list((BUILD / "docs/GrpcUtil/html").glob("*.html"))
        links = {link for page in pages for link in html(page).links}
        for module in ("protobuf", "AsyncSocketIo", "HttpClientIo", "HttpServerAsyncIo"):
            with self.subTest(module=module):
                prefix = "https://docs.qore.org/current/modules/" + module + "/html/"
                self.assertTrue(any(link.startswith(prefix) and ".html" in link for link in links), prefix)

    def test_protobuf_table_shape(self):
        tables = html(BUILD / "docs/grpc/html/grpctypemappingguide.html").tables
        selected = [table for table in tables if table and table[0] == ["Protobuf Type", "Qore Type", "Notes"]]
        self.assertEqual(1, len(selected))
        self.assertGreater(len(selected[0]), 10)
        for row in selected[0]:
            self.assertEqual(3, len(row), row)
            self.assertTrue(all(row), row)

    def test_theme_and_footer_assets(self):
        pages = list((BUILD / "docs").glob("*/html/*.html"))
        self.assertTrue(pages)
        for page in pages:
            if page.name == "doxygen_crawl.html":
                continue
            with self.subTest(page=page):
                assets = html(page).assets
                for asset in ("dox_qore.css", "Qore-Q.ico", "qore-logo-55x151-white.png", "doxygen.svg"):
                    self.assertIn(asset, assets)
                for asset in assets:
                    url = urlsplit(asset)
                    if not url.scheme and not url.netloc:
                        self.assertTrue((page.parent / unquote(url.path)).is_file(), asset)

    def test_factory_option_tables(self):
        for module, rows in (("GrpcDataProvider", 9), ("ArrowFlightDataProvider", 5)):
            with self.subTest(module=module):
                tables = html(BUILD / "docs" / module / "html/index.html").tables
                selected = [table for table in tables
                            if table and table[0] == ["Option", "Type", "Description"]]
                self.assertEqual(1, len(selected))
                self.assertEqual(rows, len(selected[0]))
                for row in selected[0]:
                    self.assertEqual(3, len(row), row)
                    self.assertTrue(all(row), row)

    def test_strict_docs_reject_bad_reference(self):
        config = (BUILD / "Doxyfile.final").read_text()
        self.assertIn("WARN_AS_ERROR = FAIL_ON_WARNINGS", config)
        with tempfile.TemporaryDirectory(prefix="grpc-doc-negative-") as directory:
            root = Path(directory)
            source = root / "invalid.dox"
            source.write_text("/** @page invalid Invalid reference\n@ref grpc_missing_doc_symbol\n*/\n")
            probe = root / "Doxyfile"
            probe.write_text(config + f'\nINPUT = "{source}"\nOUTPUT_DIRECTORY = "{root / "output"}"\n'
                             'GENERATE_TAGFILE =\nTAGFILES =\n')
            result = subprocess.run(["doxygen", str(probe)], cwd=BUILD, capture_output=True,
                                    text=True, timeout=60)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("grpc_missing_doc_symbol", result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    args, tests = parser.parse_known_args()
    BUILD = args.build_dir.resolve()
    unittest.main(argv=[__file__, *tests])
