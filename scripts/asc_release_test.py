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

ROOT = Path(__file__).resolve().parent.parent

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


class ReleaseBodyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "CHANGELOG.md"
        self.path.write_text(CHANGELOG, encoding="utf-8")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def test_shape_of_the_v1_2_release(self) -> None:
        self.assertEqual(
            asc_release.release_body(self.path, "1.3", "4109"),
            "District AI for iOS 1.3, the source of the App Store release (build 4109).\n\n"
            "On the App Store: https://apps.apple.com/app/id6809297970\n\n"
            "### Added\n\n- A feature whose description is wrapped over two lines.\n- A second one.\n\n"
            "### Fixed\n\n- A fix.\n",
        )

    def test_missing_section_is_refused(self) -> None:
        with self.assertRaises(SystemExit):
            asc_release.release_body(self.path, "9.9", "4109")

    def test_longer_than_whats_new_allows_is_still_a_body(self) -> None:
        # The App Store limit is on whatsNew; a GitHub Release has none worth enforcing.
        self.path.write_text("## [2.0] - 2026-10-01\n\n- " + "x" * 4001 + "\n", encoding="utf-8")
        self.assertIn("x" * 4001, asc_release.release_body(self.path, "2.0", "4200"))


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

    def __init__(self, gets: dict[str, dict], keep_patches: bool = True) -> None:
        self.gets = gets
        self.calls: list[tuple[str, str]] = []
        self.bodies: list[dict | None] = []
        self.keep_patches = keep_patches

    def get(self, path: str) -> dict:
        self.calls.append(("GET", path))
        self.bodies.append(None)
        for prefix, answer in self.gets.items():
            if path.startswith(prefix):
                return answer
        raise AssertionError(f"unexpected GET {path}")

    def call(self, method: str, path: str, body: dict | None = None, ok=(200, 201, 204)) -> tuple[int, dict]:
        self.calls.append((method, path))
        self.bodies.append(body)
        if method == "PATCH" and path.startswith("/appStoreVersionLocalizations/") and self.keep_patches:
            # App Store Connect keeps what it is sent, so the read-back sees it.
            loc_id = path.rsplit("/", 1)[1]
            for prefix, answer in self.gets.items():
                if prefix.endswith("/appStoreVersionLocalizations"):
                    for loc in answer["data"]:
                        if loc["id"] == loc_id:
                            loc["attributes"].update(body["data"]["attributes"])
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
            "data": [{"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "notes", **asc_release.LISTING_URLS["en"]}}]
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


def _state_gets(attributes: dict | None, build: str | None) -> dict[str, dict]:
    versions = [{"id": "v13", "attributes": {"versionString": "1.3", **attributes}}] if attributes is not None else []
    return {
        "/apps/app1/appStoreVersions?": {"data": versions},
        "/appStoreVersions/v13/build": {"data": {"id": "b", "attributes": {"version": build}} if build else None},
    }


class StoreStateTests(unittest.TestCase):
    def state(self, attributes: dict | None, build: str | None = "4109") -> tuple[tuple[str, str, bool], FakeClient]:
        client = FakeClient(_state_gets(attributes, build))
        return asc_release.store_state(client, "app1", "1.3"), client

    def test_on_sale(self) -> None:
        got, client = self.state({"appStoreState": "READY_FOR_SALE", "appVersionState": "READY_FOR_DISTRIBUTION"})
        self.assertEqual(got, ("READY_FOR_DISTRIBUTION", "4109", True))
        self.assertEqual(client.writes(), [])

    def test_replaced_by_a_newer_version_was_on_sale(self) -> None:
        got, _ = self.state({"appStoreState": "REPLACED_WITH_NEW_VERSION"})
        self.assertEqual(got, ("REPLACED_WITH_NEW_VERSION", "4109", True))

    def test_in_review_and_approved_but_held_are_not_on_sale(self) -> None:
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "REJECTED"):
            got, _ = self.state({"appStoreState": state, "appVersionState": state})
            self.assertEqual(got, (state, "4109", False), state)

    def test_no_record_and_no_build(self) -> None:
        self.assertEqual(self.state(None)[0], ("NONE", "", False))
        self.assertEqual(self.state({"appVersionState": "PREPARE_FOR_SUBMISSION"}, None)[0], ("PREPARE_FOR_SUBMISSION", "", False))


SHA = "2583a7942bae8e912df6dec5f7c9f3a401f4bd5c"
OTHER_SHA = "874c89702dbce021ac7741d84401516114ddaa0a"


def _asc_build(**attributes: object) -> dict:
    """The /builds answer for 3.2.0 (4186) as App Store Connect gave it on 2026-10-25."""
    base = {"version": "4186", "processingState": "VALID", "expired": False, "uploadedDate": "2026-10-25T04:00:27-07:00"}
    base.update(attributes)
    return {"data": [{"id": "build1", "attributes": base}]}


def _sentry_release(**fields: object) -> dict:
    """The Sentry release of the same build, trimmed to the fields that are read."""
    base: dict = {
        "version": "com.distronode.district@3.2.0+4186",
        "dateCreated": "2026-10-25T10:56:35.378557Z",
        "lastCommit": {"id": SHA, "repository": {"name": "distronode-corporation/district-ios"}},
        "projects": [{"slug": "district-ios"}],
    }
    base.update(fields)
    return base


class FakeSentry:
    def __init__(self, release: dict | None) -> None:
        self.answer = release
        self.names: list[str] = []

    def release(self, name: str) -> dict | None:
        self.names.append(name)
        return self.answer


class AlreadyUploadedTests(unittest.TestCase):
    def check(self, build: dict, release: dict | None, commit: str = SHA) -> tuple[str, FakeClient, FakeSentry]:
        client = FakeClient({"/builds?": build})
        sentry = FakeSentry(release)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                out.write(asc_release.already_uploaded(client, sentry, "app1", "3.2.0", "4186", commit))  # type: ignore[arg-type]
            except SystemExit as exit_:
                out.write(f"\nEXIT {exit_.code}")
        return out.getvalue(), client, sentry

    def test_the_v3_2_0_records_match(self) -> None:
        out, client, sentry = self.check(_asc_build(), _sentry_release())
        self.assertNotIn("EXIT", out)
        self.assertIn("MATCH - App Store Connect's 3.2.0 (4186) is VALID", out)
        self.assertIn(f"records commit {SHA}", out)
        self.assertEqual(sentry.names, ["com.distronode.district@3.2.0+4186"])
        self.assertIn("filter[version]=4186", client.calls[0][1])
        self.assertIn("filter[preReleaseVersion.version]=3.2.0", client.calls[0][1])
        self.assertEqual(client.writes(), [])

    def test_still_processing_is_accepted_for_wait_valid_to_wait_on(self) -> None:
        out, _, _ = self.check(_asc_build(processingState="PROCESSING"), _sentry_release())
        self.assertIn("is PROCESSING", out)
        self.assertNotIn("EXIT", out)

    def test_another_commit_is_refused(self) -> None:
        out, _, _ = self.check(_asc_build(), _sentry_release(), commit=OTHER_SHA)
        self.assertIn("EXIT 1", out)
        self.assertIn(f"records commit {SHA}, not this one, {OTHER_SHA}", out)

    def test_no_such_build_is_refused(self) -> None:
        out, _, sentry = self.check({"data": []}, _sentry_release())
        self.assertIn("EXIT 1", out)
        self.assertIn("but not 4186 itself", out)
        self.assertEqual(sentry.names, [])

    def test_a_different_build_number_in_the_answer_is_refused(self) -> None:
        out, _, _ = self.check(_asc_build(version="4185"), _sentry_release())
        self.assertIn("EXIT 1", out)

    def test_invalid_failed_and_unknown_states_are_refused(self) -> None:
        for state in ("INVALID", "FAILED", None, "SOMETHING_NEW"):
            out, _, sentry = self.check(_asc_build(processingState=state), _sentry_release())
            self.assertIn("EXIT 1", out, state)
            self.assertIn(f"it is {state}", out, state)
            self.assertEqual(sentry.names, [], state)

    def test_an_expired_build_is_refused(self) -> None:
        out, _, _ = self.check(_asc_build(expired=True), _sentry_release())
        self.assertIn("EXIT 1", out)
        self.assertIn("has expired", out)

    def test_no_sentry_release_is_refused_not_assumed(self) -> None:
        out, _, _ = self.check(_asc_build(), None)
        self.assertIn("EXIT 1", out)
        self.assertIn("nothing ties that build to a commit", out)

    def test_a_release_with_no_commit_is_refused(self) -> None:
        # What Sentry makes of a release it first heard of from an event: no commits.
        for last in (None, {}, "x"):
            out, _, _ = self.check(_asc_build(), _sentry_release(lastCommit=last))
            self.assertIn("EXIT 1", out, last)
            self.assertIn("records commit None", out, last)

    def test_another_repository_or_project_is_refused(self) -> None:
        out, _, _ = self.check(_asc_build(), _sentry_release(lastCommit={"id": SHA, "repository": {"name": "someone/fork"}}))
        self.assertIn("EXIT 1", out)
        self.assertIn("'someone/fork'", out)
        out, _, _ = self.check(_asc_build(), _sentry_release(projects=[{"slug": "district-android"}]))
        self.assertIn("EXIT 1", out)
        self.assertIn("not district-ios", out)

    def test_a_release_created_after_the_upload_is_refused(self) -> None:
        out, _, _ = self.check(_asc_build(), _sentry_release(dateCreated="2026-10-25T11:00:28Z"))
        self.assertIn("EXIT 1", out)
        self.assertIn("after App Store Connect's 3.2.0 (4186) was uploaded", out)
        # One second before the upload (11:00:27Z) is the order archive-imac.sh writes them in.
        out, _, _ = self.check(_asc_build(), _sentry_release(dateCreated="2026-10-25T11:00:26Z"))
        self.assertNotIn("EXIT", out)

    def test_unreadable_times_are_refused(self) -> None:
        cases = (
            (None, "2026-10-25T04:00:27-07:00"),
            ("2026-10-25T10:56:35Z", "yesterday"),
            ("2026-10-25T10:56:35", "2026-10-25T04:00:27-07:00"),  # no offset: not an instant
        )
        for created, uploaded in cases:
            out, _, _ = self.check(_asc_build(uploadedDate=uploaded), _sentry_release(dateCreated=created))
            self.assertIn("EXIT 1", out, (created, uploaded))
            self.assertIn("has no readable time", out, (created, uploaded))


class SentryTests(unittest.TestCase):
    def setUp(self) -> None:
        patcher = mock.patch.dict(os.environ, {"SENTRY_AUTH_TOKEN": "sntrys_secret", "SENTRY_ORG": "distronode-corporation-eu"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def answer(self, body: str, code: int, returncode: int = 0) -> tuple[object, str, mock.MagicMock]:
        done = subprocess.CompletedProcess([], returncode, stdout=f"{body}\n{code}".encode(), stderr=b"boom")
        err = io.StringIO()
        result: object = "not returned"
        with mock.patch.object(asc_release.subprocess, "run", return_value=done) as run, contextlib.redirect_stderr(err):
            try:
                result = asc_release.Sentry().release("com.distronode.district@3.2.0+4186")
            except SystemExit as exit_:
                err.write(f"\nEXIT {exit_.code}")
        return result, err.getvalue(), run

    def test_the_release_url_and_the_token_on_stdin_only(self) -> None:
        result, _, run = self.answer(json.dumps({"version": "x"}), 200)
        self.assertEqual(result, {"version": "x"})
        cmd = run.call_args.args[0]
        self.assertEqual(
            cmd[-1],
            "https://de.sentry.io/api/0/organizations/distronode-corporation-eu/releases/com.distronode.district%403.2.0%2B4186/",
        )
        self.assertNotIn("sntrys_secret", " ".join(cmd))
        self.assertIn(b"Authorization: Bearer sntrys_secret", run.call_args.kwargs["input"])
        self.assertNotIn("-X", cmd)  # a GET, curl's default

    def test_404_is_no_release(self) -> None:
        result, err, _ = self.answer(json.dumps({"detail": "The requested resource does not exist"}), 404)
        self.assertIsNone(result)
        self.assertEqual(err, "")

    def test_any_other_answer_stops_the_run(self) -> None:
        for body, code in (('{"detail": "Invalid token"}', 401), ("<html>502</html>", 502)):
            _, err, _ = self.answer(body, code)
            self.assertIn(f"answered {code}", err)
            self.assertIn("EXIT 1", err)
        _, err, _ = self.answer("[]", 200)
        self.assertIn("not a release", err)

    def test_a_curl_failure_stops_the_run(self) -> None:
        _, err, _ = self.answer("", 0, returncode=6)
        self.assertIn("curl exited 6", err)

    def test_missing_token_or_bad_org_is_refused_before_any_request(self) -> None:
        for env in ({"SENTRY_AUTH_TOKEN": ""}, {"SENTRY_ORG": "Org With Spaces"}, {"SENTRY_ORG": ""}):
            with mock.patch.dict(os.environ, env), mock.patch.object(asc_release.subprocess, "run") as run:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    asc_release.Sentry()
                run.assert_not_called()


class AlreadyUploadedCommandTests(unittest.TestCase):
    def test_a_short_or_odd_commit_is_refused_before_any_request(self) -> None:
        for commit in ("2583a79", SHA.upper(), SHA + "0", "HEAD"):
            argv = ["asc_release.py", "already-uploaded", "--version", "3.2.0", "--build", "4186", "--commit", commit]
            with mock.patch.object(sys, "argv", argv), mock.patch.object(asc_release, "Client") as client:
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    asc_release.main()
                client.assert_not_called()


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

    def test_associated_errors_are_named(self) -> None:
        body = {
            "errors": [
                {
                    "code": "STATE_ERROR.ENTITY_STATE_INVALID",
                    "detail": "This resource cannot be reviewed, please check associated errors to see why.",
                    "meta": {
                        "associatedErrors": {
                            "/v1/appStoreVersionLocalizations/loc-fr": [
                                {
                                    "code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED",
                                    "detail": "You must provide a value for the attribute 'supportUrl' with this request",
                                }
                            ]
                        }
                    },
                }
            ]
        }
        out = self.answer(json.dumps(body), 409)
        self.assertIn("EXIT 1", out)
        self.assertIn("answered 409: STATE_ERROR.ENTITY_STATE_INVALID: This resource cannot be reviewed", out)
        self.assertIn(
            "[associated: /v1/appStoreVersionLocalizations/loc-fr: ENTITY_ERROR.ATTRIBUTE.REQUIRED: "
            "You must provide a value for the attribute 'supportUrl' with this request]",
            out,
        )

    def test_success_is_parsed(self) -> None:
        self.assertEqual(self.answer(json.dumps({"data": []}), 200), "")
        self.assertEqual(self.result, (200, {"data": []}))


class ReleaseNotesTests(unittest.TestCase):
    """English from the CHANGELOG, every other language from release-notes/<locale>/."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        base = Path(self.dir.name)
        self.changelog = base / "CHANGELOG.md"
        self.changelog.write_text(CHANGELOG, encoding="utf-8")
        self.root = base / "release-notes"
        (self.root / "fr-CA").mkdir(parents=True)
        (self.root / "fr-CA" / "1.3.txt").write_text("Les notes en fran\u00e7ais.\n\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def notes(self, version: str = "1.3") -> asc_release.ReleaseNotes:
        return asc_release.ReleaseNotes(self.changelog, version, self.root)

    def refused(self, build) -> str:
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            build()
        return err.getvalue()

    def test_english_locales_take_the_changelog_section(self) -> None:
        notes = self.notes()
        for locale in ("en-US", "en-GB", "en-CA"):
            self.assertEqual(notes.for_locale(locale), asc_release.whats_new(self.changelog, "1.3"))

    def test_french_takes_its_file_trimmed(self) -> None:
        self.assertEqual(self.notes().for_locale("fr-CA"), "Les notes en fran\u00e7ais.")

    def test_another_french_locale_falls_back_to_french_not_english(self) -> None:
        self.assertEqual(self.notes().for_locale("fr-FR"), "Les notes en fran\u00e7ais.")

    def test_a_language_with_no_notes_is_refused_not_sent_in_english(self) -> None:
        notes = self.notes()
        message = self.refused(lambda: notes.for_locale("de-DE"))
        self.assertIn("de-DE", message)
        self.assertIn("English is never sent", message)

    def test_a_missing_file_for_the_version_is_refused_up_front(self) -> None:
        self.assertIn("1.2.txt is missing", self.refused(lambda: self.notes("1.2")))

    def test_an_empty_file_is_refused(self) -> None:
        (self.root / "fr-CA" / "1.3.txt").write_text("  \n", encoding="utf-8")
        self.assertIn("is empty", self.refused(self.notes))

    def test_a_file_longer_than_whats_new_allows_is_refused(self) -> None:
        (self.root / "fr-CA" / "1.3.txt").write_text("x" * (asc_release.WHATS_NEW_LIMIT + 1), encoding="utf-8")
        self.assertIn("App Store Connect accepts", self.refused(self.notes))

    def test_no_release_notes_directory_means_english_only(self) -> None:
        notes = asc_release.ReleaseNotes(self.changelog, "1.3", self.root / "absent")
        self.assertEqual(notes.translations, {})
        self.assertIn("English is never sent", self.refused(lambda: notes.for_locale("fr-CA")))

    def test_the_committed_files_are_well_formed(self) -> None:
        # Every committed language file is non-empty and within the limit, whatever version.
        root = asc_release.NOTES_ROOT
        files = sorted(root.glob("*/*.txt")) if root.is_dir() else []
        for path in files:
            text = path.read_text(encoding="utf-8").strip()
            self.assertTrue(text, path)
            self.assertLessEqual(len(text), asc_release.WHATS_NEW_LIMIT, path)
            self.assertNotIn("\u2014", text, f"{path}: no em dashes")


class SubmitPerLocaleTests(unittest.TestCase):
    """The submission writes each localization its own language, choosing all of them first."""

    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        base = Path(self.dir.name)
        changelog = base / "CHANGELOG.md"
        changelog.write_text(CHANGELOG, encoding="utf-8")
        (base / "release-notes" / "fr-CA").mkdir(parents=True)
        (base / "release-notes" / "fr-CA" / "1.3.txt").write_text("Notes fr", encoding="utf-8")
        self.notes = asc_release.ReleaseNotes(changelog, "1.3", base / "release-notes")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def run_submit(self, localizations: list[dict]) -> tuple[FakeClient, str]:
        gets = _submit_gets([{"id": "draft1", "attributes": {"state": "READY_FOR_REVIEW"}}], {"draft1": _items()})
        gets["/appStoreVersions/v13/appStoreVersionLocalizations"] = {"data": localizations}
        client = FakeClient(gets)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                asc_release.submit(client, "1.3", "4110", self.notes, 60)
            except SystemExit as exit_:
                out.write(f"\nEXIT {exit_.code}")
        return client, out.getvalue()

    def test_only_the_localization_whose_text_differs_is_written(self) -> None:
        english = self.notes.for_locale("en-US")
        client, out = self.run_submit(
            [
                {"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": english, **asc_release.LISTING_URLS["en"]}},
                {"id": "loc2", "attributes": {"locale": "fr-CA", "whatsNew": english, **asc_release.LISTING_URLS["fr"]}},
            ]
        )
        self.assertNotIn("EXIT", out)
        self.assertIn("whatsNew (en-US): already set", out)
        self.assertIn(("PATCH", "/appStoreVersionLocalizations/loc2"), client.writes())
        self.assertNotIn(("PATCH", "/appStoreVersionLocalizations/loc1"), client.writes())

    def test_a_language_with_no_notes_stops_before_any_localization_is_written(self) -> None:
        client, out = self.run_submit(
            [
                {"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "old"}},
                {"id": "loc3", "attributes": {"locale": "de-DE", "whatsNew": "old"}},
            ]
        )
        self.assertIn("EXIT 1", out)
        self.assertFalse([w for w in client.writes() if w[1].startswith("/appStoreVersionLocalizations/")])


class SubmitUrlTests(unittest.TestCase):
    """Every localization carries its language's supportUrl and marketingUrl before the build
    is attached, read back and checked (3.0.0 answered 409 for a localization without one)."""

    def run_submit(self, localizations: list[dict], keep_patches: bool = True) -> tuple[FakeClient, str]:
        gets = _submit_gets([{"id": "draft1", "attributes": {"state": "READY_FOR_REVIEW"}}], {"draft1": _items()})
        gets["/appStoreVersions/v13/appStoreVersionLocalizations"] = {"data": localizations}
        client = FakeClient(gets, keep_patches=keep_patches)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            try:
                asc_release.submit(client, "1.3", "4110", "notes", 60)
            except SystemExit as exit_:
                out.write(f"\nEXIT {exit_.code}")
        return client, out.getvalue()

    def test_missing_and_wrong_urls_are_set_per_language_and_the_rest_left_alone(self) -> None:
        client, out = self.run_submit(
            [
                {"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "notes", **asc_release.LISTING_URLS["en"]}},
                {"id": "loc2", "attributes": {"locale": "fr-CA", "whatsNew": "notes", "supportUrl": None,
                                              "marketingUrl": "https://www.distronode.com/district-ai"}},
            ]
        )
        self.assertNotIn("EXIT", out)
        patches = [(c, b) for c, b in zip(client.calls, client.bodies) if c[0] == "PATCH" and "Localizations" in c[1]]
        self.assertEqual([c for c, _ in patches], [("PATCH", "/appStoreVersionLocalizations/loc2")])
        self.assertEqual(patches[0][1]["data"]["attributes"], asc_release.LISTING_URLS["fr"])
        self.assertIn("supportUrl (fr-CA): None -> https://distronode.ca/fr/support", out)
        self.assertIn("supportUrl (en-US): already set", out)
        self.assertIn("localizations: release notes, supportUrl and marketingUrl checked", out)
        self.assertIn("SUBMITTED - 1.3 (4110)", out)

    def test_a_value_app_store_connect_did_not_keep_stops_before_the_build_is_attached(self) -> None:
        client, out = self.run_submit(
            [{"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "notes"}}], keep_patches=False
        )
        self.assertIn("EXIT 1", out)
        self.assertIn("after it was set; nothing was submitted", out)
        self.assertNotIn(("PATCH", "/appStoreVersions/v13/relationships/build"), client.writes())
        self.assertFalse([w for w in client.writes() if w[1].startswith("/reviewSubmission")])

    def test_a_language_with_no_urls_stops_before_any_write(self) -> None:
        client, out = self.run_submit(
            [
                {"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "old"}},
                {"id": "loc3", "attributes": {"locale": "de-DE", "whatsNew": "notes"}},
            ]
        )
        self.assertIn("EXIT 1", out)
        self.assertIn("de-DE localization and LISTING_URLS has no support and marketing URLs", out)
        self.assertEqual(client.writes(), [])

    def test_the_french_urls_are_the_store_listings(self) -> None:
        listing = json.loads((ROOT / "store-listing" / "fr-CA.json").read_text(encoding="utf-8"))
        self.assertEqual(listing["urls"], asc_release.LISTING_URLS["fr"])

    def test_every_url_is_https(self) -> None:
        for language, urls in asc_release.LISTING_URLS.items():
            self.assertEqual(set(urls), set(asc_release.URL_FIELDS), language)
            for value in urls.values():
                self.assertTrue(value.startswith("https://") and " " not in value, value)


class ReviewDetailTests(unittest.TestCase):
    """⛔ The review detail holds the demo account's password: no path to it is ever requested."""

    def test_every_spelling_of_the_review_detail_is_refused_before_a_request(self) -> None:
        for path in (
            "/appStoreVersions/v1/appStoreReviewDetail",
            "/appStoreReviewDetails/abc",
            "/appStoreVersions/v1?include=appStoreReviewDetail",
            "/appStoreReviewDetails/abc?fields[appStoreReviewDetails]=demoAccountPassword",
        ):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                with self.assertRaises(SystemExit):
                    asc_release.refuse_review_detail(path)
            self.assertIn("never reads the App Review detail", out.getvalue())

    def test_the_client_refuses_it_before_curl_runs(self) -> None:
        client = asc_release.Client.__new__(asc_release.Client)
        with mock.patch.object(asc_release.subprocess, "run") as run:
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    client.call("GET", "/appStoreReviewDetails/abc")
            run.assert_not_called()

    def test_an_ordinary_path_passes(self) -> None:
        asc_release.refuse_review_detail("/appStoreVersions/v13/appStoreVersionLocalizations")


if __name__ == "__main__":
    unittest.main(verbosity=2)
