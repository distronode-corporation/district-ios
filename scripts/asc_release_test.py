#!/usr/bin/env python3
"""Tests for asc_release.py that need no network and no Apple account.

    python3 scripts/asc_release_test.py
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
