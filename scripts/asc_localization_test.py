#!/usr/bin/env python3
"""Tests for asc_localization.py that need no network and no Apple account.

    python3 scripts/asc_localization_test.py
"""

from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_localization as loc  # noqa: E402

LISTING = {
    "englishSubtitles": {"subtitle": "Your whole business line", "subtitleForLegacyEnglish": "AI receptionist for your line"},
    "texts": {
        "name": "District AI",
        "subtitle": "Toute votre ligne d'affaires",
        "subtitleForLegacyEnglish": "Votre réceptionniste IA",
        "description": "Description.",
        "keywords": "réceptionniste,appels",
        "promotionalText": "Promo.",
        "whatsNew": "Nouveau.",
    },
}
FIELDS = {k: LISTING["texts"][k] for k in ("description", "keywords", "promotionalText", "whatsNew")}


class FakeClient:
    """Answers GETs from a table by path prefix and records every call."""

    def __init__(self, answers: dict[str, dict]):
        self.answers = answers
        self.calls: list[tuple[str, str, dict | None]] = []

    def get(self, path: str) -> dict:
        for prefix, answer in self.answers.items():
            if path.startswith(prefix):
                return answer
        raise AssertionError(f"unexpected GET {path}")

    def call(self, method: str, path: str, body: dict | None = None):
        self.calls.append((method, path, body))
        return 201, {"data": {"id": "ver-new"}} if path == "/appStoreVersions" else {"data": {}}


def info_answers(state: str, subtitle: str, fr: bool = False) -> dict[str, dict]:
    locs = [{"id": "il-en", "attributes": {"locale": "en-US", "subtitle": subtitle}}]
    if fr:
        locs.append({"id": "il-fr", "attributes": {"locale": "fr-CA", "subtitle": "x"}})
    return {
        "/apps/app/appInfos": {"data": [{"id": "info-1", "attributes": {"state": state}}]},
        "/appInfos/info-1/appInfoLocalizations": {"data": locs},
    }


class VersionWrites(unittest.TestCase):
    def test_a_missing_version_is_created_then_localized(self):
        client = FakeClient({"/apps/app/appStoreVersions": {"data": []}})
        writes, notes = loc.version_writes(client, "app", "3.0.0", "fr-CA", FIELDS)
        self.assertEqual([(m, p) for m, p, _ in writes], [("POST", "/appStoreVersions"), ("POST", "/appStoreVersionLocalizations")])
        self.assertEqual(writes[1][2]["data"]["relationships"]["appStoreVersion"]["data"]["id"], loc.NEW_VERSION)
        self.assertEqual(writes[1][2]["data"]["attributes"]["locale"], "fr-CA")
        self.assertIn("no record yet", notes[0])

    def test_an_existing_french_localization_is_patched(self):
        client = FakeClient({
            "/apps/app/appStoreVersions": {"data": [{"id": "ver-1", "attributes": {"appVersionState": "PREPARE_FOR_SUBMISSION"}}]},
            "/appStoreVersions/ver-1/appStoreVersionLocalizations": {"data": [
                {"id": "vl-en", "attributes": {"locale": "en-US"}},
                {"id": "vl-fr", "attributes": {"locale": "fr-CA"}},
            ]},
        })
        writes, _ = loc.version_writes(client, "app", "3.0.0", "fr-CA", FIELDS)
        self.assertEqual([(m, p) for m, p, _ in writes], [("PATCH", "/appStoreVersionLocalizations/vl-fr")])
        self.assertEqual(writes[0][2]["data"]["attributes"], FIELDS)


class InfoWrites(unittest.TestCase):
    def test_the_subtitle_follows_the_live_english_one(self):
        for english, french in (("Your whole business line", "Toute votre ligne d'affaires"),
                                ("AI receptionist for your line", "Votre réceptionniste IA")):
            client = FakeClient(info_answers("PREPARE_FOR_SUBMISSION", english))
            writes, _, blocked = loc.info_writes(client, "app", "fr-CA", LISTING)
            self.assertIsNone(blocked)
            self.assertEqual(writes[0][2]["data"]["attributes"]["subtitle"], french)

    def test_an_unknown_english_subtitle_stops_the_run(self):
        client = FakeClient(info_answers("PREPARE_FOR_SUBMISSION", "Something else"))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            loc.info_writes(client, "app", "fr-CA", LISTING)

    def test_an_app_info_in_review_or_live_is_not_editable(self):
        for state in ("IN_REVIEW", "READY_FOR_DISTRIBUTION"):
            client = FakeClient(info_answers(state, "Your whole business line"))
            _, _, blocked = loc.info_writes(client, "app", "fr-CA", LISTING)
            self.assertIsNotNone(blocked)

    def test_an_existing_french_app_info_localization_is_patched(self):
        client = FakeClient(info_answers("PREPARE_FOR_SUBMISSION", "Your whole business line", fr=True))
        writes, _, _ = loc.info_writes(client, "app", "fr-CA", LISTING)
        self.assertEqual((writes[0][0], writes[0][1]), ("PATCH", "/appInfoLocalizations/il-fr"))


class VersionFields(unittest.TestCase):
    URLS = {"supportUrl": "https://distronode.ca/fr/support", "marketingUrl": "https://distronode.ca/fr/district-ai"}

    def test_the_urls_join_the_texts(self):
        fields = loc.version_fields({**LISTING, "urls": self.URLS})
        self.assertEqual(fields, {**FIELDS, **self.URLS})

    def test_a_listing_without_a_support_url_stops_the_run(self):
        for urls in (None, {}, {"marketingUrl": self.URLS["marketingUrl"]}, {"supportUrl": ""}):
            listing = dict(LISTING) if urls is None else {**LISTING, "urls": urls}
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                loc.version_fields(listing)

    def test_a_url_that_is_not_https_or_not_a_url_field_stops_the_run(self):
        for urls in (
            {"supportUrl": "http://distronode.ca/fr/support"},
            {"supportUrl": "https://distronode.ca/fr/support\nx"},
            {"supportUrl": self.URLS["supportUrl"], "privacyPolicyUrl": "https://distronode.ca/fr/privacy"},
            {"supportUrl": self.URLS["supportUrl"], "marketingUrl": 7},
        ):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                loc.version_fields({**LISTING, "urls": urls})

    def test_the_committed_french_listing_has_its_urls(self):
        fields = loc.version_fields(loc.load_texts("fr-CA", "3.0.0"))
        self.assertEqual({k: fields[k] for k in self.URLS}, self.URLS)


class Sending(unittest.TestCase):
    def test_the_created_version_fills_the_placeholder(self):
        client = FakeClient({"/apps/app/appStoreVersions": {"data": []}})
        writes, _ = loc.version_writes(client, "app", "3.0.0", "fr-CA", FIELDS)
        with contextlib.redirect_stdout(io.StringIO()):
            loc.send(client, writes)
        relation = client.calls[1][2]["data"]["relationships"]["appStoreVersion"]["data"]["id"]
        self.assertEqual(relation, "ver-new")


class Limits(unittest.TestCase):
    def test_keywords_are_counted_in_bytes(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            loc.check_limits({"keywords": "é" * 51})
        loc.check_limits({"keywords": "é" * 50})

    def test_the_committed_french_listing_fits(self):
        listing = loc.load_texts("fr-CA", "3.0.0")
        texts = listing["texts"]
        loc.check_limits({k: texts[k] for k in ("description", "keywords", "promotionalText", "whatsNew", "name")})
        loc.check_limits({"subtitle": texts["subtitle"]})
        loc.check_limits({"subtitle": texts["subtitleForLegacyEnglish"]})


if __name__ == "__main__":
    unittest.main()
