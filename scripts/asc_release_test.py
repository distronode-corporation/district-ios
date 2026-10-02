#!/usr/bin/env python3
"""Tests for asc_release.py that need no network and no Apple account.

    python3 scripts/asc_release_test.py
"""

from __future__ import annotations

import base64
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_release  # noqa: E402

CHANGELOG = """# Changelog

## [Unreleased]

### Added

- Something not released yet.

## [1.3] - 2026-10-01

### Added

- A feature whose description is
  wrapped over two lines.
- A second one.

### Fixed

- A fix.

## [1.2] - 2026-09-26

### Changed

- Older.

## [1.1] - 2026-09-25

[Unreleased]: https://example.invalid/compare/v1.3...HEAD
[1.3]: https://example.invalid/releases/tag/v1.3
"""


def _unb64url(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _raw_to_der(raw: bytes) -> bytes:
    def integer(value: bytes) -> bytes:
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value

    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class WhatsNewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "CHANGELOG.md"
        self.path.write_text(CHANGELOG, encoding="utf-8")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def test_section_as_plain_text(self) -> None:
        self.assertEqual(
            asc_release.whats_new(self.path, "1.3"),
            "Added\n\n- A feature whose description is wrapped over two lines.\n- A second one.\n\nFixed\n\n- A fix.",
        )

    def test_stops_at_the_next_version(self) -> None:
        self.assertEqual(asc_release.whats_new(self.path, "1.2"), "Changed\n\n- Older.")

    def test_empty_section_is_refused(self) -> None:
        # The 1.1 section runs straight into the link definitions.
        with self.assertRaises(SystemExit):
            asc_release.whats_new(self.path, "1.1")

    def test_missing_section_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            asc_release.whats_new(self.path, "9.9")

    def test_too_long_is_refused(self) -> None:
        self.path.write_text("## [2.0] - 2026-10-01\n\n- " + "x" * 4001 + "\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            asc_release.whats_new(self.path, "2.0")


class SignatureTests(unittest.TestCase):
    def test_der_to_raw_pads_both_halves(self) -> None:
        r = (1).to_bytes(32, "big")
        s = (0x80 << 248).to_bytes(32, "big")  # high bit set: DER adds a zero byte
        self.assertEqual(asc_release._der_to_raw(_raw_to_der(r + s)), r + s)

    def test_token_is_a_verifiable_es256_jwt(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp) / "AuthKey_TEST.p8"
            pub = Path(tmp) / "pub.pem"
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
                check=True,
                capture_output=True,
            )
            subprocess.run(["openssl", "pkey", "-in", str(key), "-pubout", "-out", str(pub)], check=True)
            env = {"ASC_KEY_ID": "TESTKEYID", "ASC_ISSUER_ID": "issuer-uuid", "ASC_KEY_PATH": str(key)}
            old = {k: os.environ.get(k) for k in env}
            os.environ.update(env)
            try:
                token = asc_release.Client().token()
            finally:
                for k, v in old.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v
            header, payload, signature = token.split(".")
            self.assertEqual(json.loads(_unb64url(header)), {"alg": "ES256", "kid": "TESTKEYID", "typ": "JWT"})
            claims = json.loads(_unb64url(payload))
            self.assertEqual(claims["iss"], "issuer-uuid")
            self.assertEqual(claims["aud"], "appstoreconnect-v1")
            self.assertLessEqual(claims["exp"] - claims["iat"], 1200)
            raw = _unb64url(signature)
            self.assertEqual(len(raw), 64)
            sig = Path(tmp) / "sig.der"
            sig.write_bytes(_raw_to_der(raw))
            verify = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(sig)],
                input=f"{header}.{payload}".encode(),
                capture_output=True,
            )
            self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)


class FakeClient:
    """Answers GETs from a table of path prefixes and records every write. A path no
    entry matches fails the test, so a request the code did not use to make shows up."""

    def __init__(self, gets: dict[str, dict]) -> None:
        self.gets = gets
        self.calls: list[tuple[str, str]] = []

    def get(self, path: str) -> dict:
        self.calls.append(("GET", path))
        for prefix, answer in self.gets.items():
            if path.startswith(prefix):
                return answer
        raise AssertionError(f"unexpected GET {path}")

    def call(self, method: str, path: str, body: dict | None = None, ok=(200, 201, 204)) -> tuple[int, dict]:
        self.calls.append((method, path))
        if method == "POST" and path == "/reviewSubmissions":
            return 201, {"data": {"id": "new-sub", "attributes": {"state": "READY_FOR_REVIEW"}}}
        if method == "PATCH" and path.startswith("/reviewSubmissions/"):
            return 200, {"data": {"attributes": {"state": "WAITING_FOR_REVIEW"}}}
        return 200, {}

    def writes(self) -> list[tuple[str, str]]:
        return [c for c in self.calls if c[0] != "GET"]


def _submit_gets(submissions: list[dict], items: dict[str, dict]) -> dict[str, dict]:
    """GET answers for a submit of 1.3 (4110) whose record, notes and build are all in
    place already, so the only open question is the review submission."""
    gets = {
        "/apps?": {"data": [{"id": "app1", "attributes": {"bundleId": asc_release.BUNDLE_ID}}]},
        "/builds?": {"data": [{"id": "build1", "attributes": {"processingState": "VALID"}}]},
        "/apps/app1/appStoreVersions?": {
            "data": [{"id": "v13", "attributes": {"versionString": "1.3", "appVersionState": "READY_FOR_REVIEW"}}]
        },
        "/appStoreVersions/v13/appStoreVersionLocalizations": {
            "data": [{"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "notes"}}]
        },
        "/appStoreVersions/v13/relationships/build": {"data": {"id": "build1"}},
        "/reviewSubmissions?": {"data": submissions},
    }
    for sub_id, page in items.items():
        gets[f"/reviewSubmissions/{sub_id}/items"] = page
    return gets


def _items(*versions: tuple[str, str]) -> dict:
    return {
        "data": [{"relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}} for vid, _ in versions],
        "included": [{"type": "appStoreVersions", "id": vid, "attributes": {"versionString": vs}} for vid, vs in versions],
    }


class SubmitTests(unittest.TestCase):
    def submit(self, client: FakeClient) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                asc_release.submit(client, "1.3", "4110", "notes", 60)
            except SystemExit as exit_:
                out.write(f"\nEXIT {exit_.code}")
        return out.getvalue()

    def test_in_flight_submission_of_this_version_is_left_alone(self) -> None:
        client = FakeClient(
            _submit_gets(
                [{"id": "sub1", "attributes": {"state": "WAITING_FOR_REVIEW"}}],
                {"sub1": _items(("v13", "1.3"))},
            )
        )
        out = self.submit(client)
        self.assertIn("sub1 is already WAITING_FOR_REVIEW. Nothing was submitted.", out)
        self.assertNotIn("EXIT", out)
        self.assertEqual(client.writes(), [])

    def test_in_flight_submission_of_another_version_is_refused(self) -> None:
        client = FakeClient(
            _submit_gets(
                [{"id": "sub1", "attributes": {"state": "UNRESOLVED_ISSUES"}}],
                {"sub1": _items(("v12", "1.2.1"))},
            )
        )
        out = self.submit(client)
        self.assertIn("EXIT 1", out)
        self.assertIn("sub1 is UNRESOLVED_ISSUES with 1.2.1, not 1.3", out)
        self.assertEqual(client.writes(), [])

    def test_open_draft_gets_the_version_and_is_submitted(self) -> None:
        client = FakeClient(
            _submit_gets([{"id": "draft1", "attributes": {"state": "READY_FOR_REVIEW"}}], {"draft1": _items()})
        )
        out = self.submit(client)
        self.assertIn("SUBMITTED - 1.3 (4110)", out)
        self.assertEqual(
            client.writes(), [("POST", "/reviewSubmissionItems"), ("PATCH", "/reviewSubmissions/draft1")]
        )


class HighestBuildTests(unittest.TestCase):
    def test_highest_number_numerically(self) -> None:
        builds = {"data": [{"attributes": {"version": v}} for v in ("4110", "999", "4123", "4104")]}
        client = FakeClient({"/builds?": builds})
        self.assertEqual(asc_release.highest_build(client, "app1", "1.3"), 4123)
        self.assertIn("filter[preReleaseVersion.version]=1.3", client.calls[0][1])

    def test_no_build_is_zero(self) -> None:
        self.assertEqual(asc_release.highest_build(FakeClient({"/builds?": {"data": []}}), "app1", "1.3"), 0)


class CallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        key = Path(self.dir.name) / "AuthKey_TEST.p8"
        key.write_text("unused", encoding="utf-8")
        env = {"ASC_KEY_ID": "TESTKEYID", "ASC_ISSUER_ID": "issuer-uuid", "ASC_KEY_PATH": str(key)}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.client = asc_release.Client()
        self.client.token = lambda: "token"  # type: ignore[method-assign]

    def tearDown(self) -> None:
        self.dir.cleanup()

    def answer(self, body: str, code: int) -> str:
        done = subprocess.CompletedProcess([], 0, stdout=f"{body}\n{code}".encode(), stderr=b"")
        err = io.StringIO()
        with mock.patch.object(asc_release.subprocess, "run", return_value=done), contextlib.redirect_stderr(err):
            try:
                self.result = self.client.call("GET", "/apps")
            except SystemExit as exit_:
                err.write(f"\nEXIT {exit_.code}")
        return err.getvalue()

    def test_html_error_page_names_the_code_and_the_body(self) -> None:
        out = self.answer("<html>\n  <body>502 Bad Gateway</body>\n</html>", 502)
        self.assertIn("EXIT 1", out)
        self.assertIn("GET /apps answered 502: <html> <body>502 Bad Gateway</body> </html>", out)

    def test_json_error_names_apple_detail(self) -> None:
        out = self.answer(json.dumps({"errors": [{"code": "NOT_AUTHORIZED", "detail": "bad token"}]}), 401)
        self.assertIn("answered 401: NOT_AUTHORIZED: bad token", out)

    def test_success_is_parsed(self) -> None:
        self.assertEqual(self.answer(json.dumps({"data": []}), 200), "")
        self.assertEqual(self.result, (200, {"data": []}))


if __name__ == "__main__":
    unittest.main(verbosity=2)
