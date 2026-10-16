#!/usr/bin/env python3
"""Tests of scripts/asc_dev_cert.py: the release run creates one Apple Development
certificate, records its id first, and revokes exactly that id, never listing or matching.

    python3 scripts/asc_dev_cert_test.py
"""

from __future__ import annotations

import base64
import contextlib
import io
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_dev_cert  # noqa: E402

CONTENT = base64.b64encode(b"\x30\x82 not really DER").decode("ascii")


class Recorder:
    """Records every request and answers from a table; a GET of anything is a failure,
    because neither command has any reason to read, let alone list, certificates."""

    def __init__(self, answers: dict[tuple[str, str], tuple[int, dict]]) -> None:
        self.answers = answers
        self.calls: list[tuple[str, str, dict | None]] = []

    def call(self, method: str, path: str, body: dict | None = None, ok=(200, 201, 204)) -> tuple[int, dict]:
        self.calls.append((method, path, body))
        code, answer = self.answers[(method, path)]
        if code not in ok:
            asc_dev_cert.die(f"{method} {path} answered {code}")
        return code, answer

    def get(self, path: str) -> dict:
        raise AssertionError(f"unexpected GET {path}")


def quietly(fn, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            result = fn(*args)
        except SystemExit as exit_:
            out.write(f"\nEXIT {exit_.code}")
            result = None
    return result, out.getvalue()


class CreateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.dir)

    def test_creates_one_development_certificate_and_records_its_id(self) -> None:
        client = Recorder({("POST", "/certificates"): (201, {"data": {"id": "ABC123XYZ9", "attributes": {"certificateContent": CONTENT}}})})
        cert_id, out = quietly(asc_dev_cert.create, client, self.dir, "-----BEGIN CERTIFICATE REQUEST-----\n")
        self.assertEqual(cert_id, "ABC123XYZ9", out)
        self.assertEqual(len(client.calls), 1)
        method, path, body = client.calls[0]
        self.assertEqual((method, path), ("POST", "/certificates"))
        self.assertEqual(body["data"]["attributes"]["certificateType"], "DEVELOPMENT")
        self.assertEqual((self.dir / "cert.id").read_text(), "ABC123XYZ9\n")
        self.assertEqual((self.dir / "cert.cer").read_bytes(), base64.b64decode(CONTENT))
        self.assertEqual((self.dir / "cert.id").stat().st_mode & 0o777, 0o600)

    def test_the_id_is_recorded_even_when_the_content_is_missing(self) -> None:
        client = Recorder({("POST", "/certificates"): (201, {"data": {"id": "ABC123XYZ9", "attributes": {}}})})
        _, out = quietly(asc_dev_cert.create, client, self.dir, "csr")
        self.assertIn("EXIT 1", out)
        self.assertEqual((self.dir / "cert.id").read_text(), "ABC123XYZ9\n")

    def test_an_answer_without_a_usable_id_records_nothing(self) -> None:
        for answer in ({"data": {"attributes": {}}}, {"data": {"id": "../profiles/X"}}, {}):
            client = Recorder({("POST", "/certificates"): (201, answer)})
            _, out = quietly(asc_dev_cert.create, client, self.dir, "csr")
            self.assertIn("EXIT 1", out)
            self.assertFalse((self.dir / "cert.id").exists())

    def test_a_real_key_and_csr_are_made_and_the_key_is_private(self) -> None:
        if shutil.which("openssl") is None:
            self.skipTest("no openssl")
        csr = asc_dev_cert.make_key_and_csr(self.dir)
        self.assertTrue(csr.startswith("-----BEGIN CERTIFICATE REQUEST-----"))
        self.assertEqual((self.dir / "key.pem").stat().st_mode & 0o777, 0o600)


class RevokeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.dir)

    def test_revokes_exactly_the_recorded_id_and_nothing_else(self) -> None:
        (self.dir / "cert.id").write_text("ABC123XYZ9\n")
        client = Recorder({("DELETE", "/certificates/ABC123XYZ9"): (204, {})})
        revoked, out = quietly(asc_dev_cert.revoke, client, self.dir)
        self.assertTrue(revoked, out)
        self.assertEqual([(m, p) for m, p, _ in client.calls], [("DELETE", "/certificates/ABC123XYZ9")])
        self.assertIn("certificate ABC123XYZ9: revoked", out)

    def test_already_gone_is_the_goal(self) -> None:
        (self.dir / "cert.id").write_text("ABC123XYZ9\n")
        client = Recorder({("DELETE", "/certificates/ABC123XYZ9"): (404, {})})
        revoked, out = quietly(asc_dev_cert.revoke, client, self.dir)
        self.assertTrue(revoked, out)
        self.assertIn("already gone", out)

    def test_no_recorded_id_sends_nothing(self) -> None:
        client = Recorder({})
        revoked, out = quietly(asc_dev_cert.revoke, client, self.dir)
        self.assertFalse(revoked)
        self.assertEqual(client.calls, [])
        self.assertIn("nothing to revoke", out)

    def test_a_malformed_id_is_never_put_in_a_path(self) -> None:
        for bad in ("../profiles/X", "", "ABC 123", "ABC123?filter=all"):
            (self.dir / "cert.id").write_text(bad + "\n")
            client = Recorder({})
            _, out = quietly(asc_dev_cert.revoke, client, self.dir)
            self.assertEqual(client.calls, [], bad)
            if bad:
                self.assertIn("EXIT 1", out)


class SourceTests(unittest.TestCase):
    """⛔ The script never lists or searches certificates: the only paths it names are the
    create and the delete by id."""

    def test_no_listing_or_name_match_in_the_source(self) -> None:
        source = Path(asc_dev_cert.__file__).read_text(encoding="utf-8")
        code = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("client.get(", code)
        self.assertNotIn("filter[", code)
        self.assertNotIn('"GET"', code)
        paths = sorted(set(re.findall(r'f?"/certificates[^"]*"', code)))
        self.assertEqual(paths, ['"/certificates"', 'f"/certificates/{cert_id}"'])


if __name__ == "__main__":
    unittest.main(verbosity=2)
