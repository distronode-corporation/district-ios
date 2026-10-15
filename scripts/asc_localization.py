#!/usr/bin/env python3
"""Adds a language's App Store listing in App Store Connect: the version's localization
(description, keywords, promotional text, What's New) and the app info's (name,
subtitle).

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=/path/AuthKey_<id>.p8 \\
      python3 scripts/asc_localization.py --version 3.0.0 --locale fr-CA --dry-run

The texts are `store-listing/<locale>.json` (the reviewed store copy, verbatim) and
`release-notes/<locale>/<version>.txt` (What's New, the file asc_release.py submits).

⛔ `--dry-run` READS AND NEVER WRITES. It looks up the app, the version record, the
editable app info and their localizations, then prints every write it would send, method,
path and body, and stops. Without it the same writes are sent, in that order.

⚠️ THE SUBTITLE FOLLOWS THE LIVE ENGLISH ONE. The listing's English subtitle was set
through the API on 2026-09-12 and a later draft may or may not have replaced it, so the
French is chosen by reading en-US: `subtitle` translates "Your whole business line",
`subtitleForLegacyEnglish` translates "AI receptionist for your line", and any other
English stops the run rather than guessing.

⚠️ EVERY LIMIT IS CHECKED BEFORE THE FIRST WRITE: name and subtitle 30 characters,
promotional text 170, description and What's New 4000, keywords 100 BYTES.

Standard library only, on asc_release.py's client (the same ES256 token through openssl
and curl, the bearer never on argv). It reads no review detail, so the demo account's
password is never fetched.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_release  # noqa: E402
from asc_release import PLATFORM, die  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
LIMITS = {
    "name": (30, "chars"),
    "subtitle": (30, "chars"),
    "promotionalText": (170, "chars"),
    "description": (4000, "chars"),
    "whatsNew": (4000, "chars"),
    "keywords": (100, "bytes"),
}
# App info states in which a localization can be added or edited. ⚠️ A WHITELIST: the app
# record is shared with the Mac, so an app info can be in review for the other platform,
# and that one is not editable either.
EDITABLE_APP_INFO = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"}


def load_texts(locale: str, version: str, root: Path = ROOT) -> dict:
    listing = json.loads((root / "store-listing" / f"{locale}.json").read_text(encoding="utf-8"))
    notes = root / "release-notes" / locale / f"{version}.txt"
    if not notes.is_file():
        die(f"no What's New for {locale} {version}: {notes} is missing.")
    listing["texts"]["whatsNew"] = notes.read_text(encoding="utf-8").strip()
    return listing


def check_limits(fields: dict) -> None:
    for field, value in fields.items():
        limit, unit = LIMITS[field]
        size = len(value.encode("utf-8")) if unit == "bytes" else len(value)
        if size > limit:
            die(f"{field} is {size} {unit}; App Store Connect accepts {limit}.")


def subtitle_for(listing: dict, english_subtitle: str | None) -> str:
    english = listing["englishSubtitles"]
    for key, text in english.items():
        if text == english_subtitle:
            return listing["texts"][key]
    die(f"the live en-US subtitle is {english_subtitle!r}, which neither French subtitle translates.")
    return ""  # unreachable: die exits


NEW_VERSION = "{new-version}"


def version_writes(client, app: str, version: str, locale: str, fields: dict) -> tuple[list, list[str]]:
    """The version record (created when missing, as asc_release.py submit would) and this
    locale's version localization."""
    notes: list[str] = []
    versions = client.get(
        f"/apps/{app}/appStoreVersions?filter[versionString]={version}&filter[platform]={PLATFORM}"
        "&fields[appStoreVersions]=versionString,appStoreState,appVersionState"
    )["data"]
    if not versions:
        notes.append(f"version {version}: no record yet; it is created first, as asc_release.py submit would")
        create = ("POST", "/appStoreVersions", {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": PLATFORM, "versionString": version},
            "relationships": {"app": {"data": {"type": "apps", "id": app}}},
        }})
        return [create, localization_post(NEW_VERSION, locale, fields)], notes
    record = versions[0]
    state = record["attributes"].get("appVersionState") or record["attributes"].get("appStoreState")
    notes.append(f"version {version}: record {record['id']}, state {state}")
    locs = client.get(f"/appStoreVersions/{record['id']}/appStoreVersionLocalizations")["data"]
    notes.append("version localizations: " + ", ".join(sorted(l["attributes"]["locale"] for l in locs)))
    mine = [l for l in locs if l["attributes"]["locale"] == locale]
    if mine:
        return [("PATCH", f"/appStoreVersionLocalizations/{mine[0]['id']}", {"data": {
            "type": "appStoreVersionLocalizations", "id": mine[0]["id"], "attributes": fields}})], notes
    return [localization_post(record["id"], locale, fields)], notes


def localization_post(version_id: str, locale: str, fields: dict) -> tuple[str, str, dict]:
    return ("POST", "/appStoreVersionLocalizations", {"data": {
        "type": "appStoreVersionLocalizations",
        "attributes": {"locale": locale, **fields},
        "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
    }})


def info_writes(client, app: str, locale: str, listing: dict) -> tuple[list, list[str], str | None]:
    """This locale's app info localization (name, subtitle), on the editable app info. The
    third value says why it cannot be written yet, or is None."""
    notes: list[str] = []
    infos = client.get(f"/apps/{app}/appInfos?fields[appInfos]=appStoreState,state")["data"]
    state = lambda i: i["attributes"].get("state") or i["attributes"].get("appStoreState")  # noqa: E731
    notes.append("app infos: " + ", ".join(f"{i['id']} {state(i)}" for i in infos))
    editable = [i for i in infos if state(i) in EDITABLE_APP_INFO]
    source = editable[0] if editable else (infos[0] if infos else None)
    if source is None:
        die("the app has no app info record.")
    info_locs = client.get(f"/appInfos/{source['id']}/appInfoLocalizations")["data"]
    english = next((l for l in info_locs if l["attributes"]["locale"] == "en-US"), None)
    english_subtitle = english["attributes"].get("subtitle") if english else None
    notes.append(f"en-US subtitle: {english_subtitle!r}")
    if english and english["attributes"].get("privacyPolicyUrl"):
        notes.append(f"en-US privacy policy URL: {english['attributes']['privacyPolicyUrl']} (not copied)")
    fields = {"name": listing["texts"]["name"], "subtitle": subtitle_for(listing, english_subtitle)}
    check_limits(fields)
    blocked = None if editable else (
        "no editable app info (none is PREPARE_FOR_SUBMISSION or rejected); the write below names "
        f"{source['id']} only to show its body"
    )
    mine = [l for l in info_locs if l["attributes"]["locale"] == locale]
    if mine:
        return [("PATCH", f"/appInfoLocalizations/{mine[0]['id']}", {"data": {
            "type": "appInfoLocalizations", "id": mine[0]["id"], "attributes": fields}})], notes, blocked
    return [("POST", "/appInfoLocalizations", {"data": {
        "type": "appInfoLocalizations",
        "attributes": {"locale": locale, **fields},
        "relationships": {"appInfo": {"data": {"type": "appInfos", "id": source["id"]}}},
    }})], notes, blocked


def show(writes: list, verb: str) -> None:
    for method, path, body in writes:
        print(f"{verb}: {method} {path}")
        print(json.dumps(body, ensure_ascii=False, indent=2))


def send(client, writes: list) -> None:
    """In order; the record a POST /appStoreVersions creates fills {new-version} after it."""
    created = None
    for method, path, body in writes:
        if created is not None:
            body = json.loads(json.dumps(body).replace(NEW_VERSION, created))
        print(f"send: {method} {path}")
        _, answer = client.call(method, path, body)
        if path == "/appStoreVersions":
            created = answer["data"]["id"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True)
    parser.add_argument("--locale", required=True)
    parser.add_argument("--dry-run", action="store_true", help="read, print every write, send none")
    args = parser.parse_args()
    listing = load_texts(args.locale, args.version)
    texts = listing["texts"]
    fields = {k: texts[k] for k in ("description", "keywords", "promotionalText", "whatsNew")}
    check_limits(fields)
    client = asc_release.Client()
    app = asc_release.app_id(client)
    print(f"read: app {app}")
    v_writes, v_notes = version_writes(client, app, args.version, args.locale, fields)
    i_writes, i_notes, blocked = info_writes(client, app, args.locale, listing)
    for line in v_notes + i_notes:
        print(f"read: {line}")
    if args.dry_run:
        show(v_writes, "would send")
        if blocked:
            print(f"after the version writes, app infos are read again; now: {blocked}")
        show(i_writes, "would send")
        print(f"dry run: {len(v_writes) + len(i_writes)} write(s) not sent")
        return
    send(client, v_writes)
    # ⚠️ READ AGAIN: a new version record can bring the editable app info with it.
    i_writes, i_notes, blocked = info_writes(client, app, args.locale, listing)
    if blocked:
        die(blocked)
    send(client, i_writes)


if __name__ == "__main__":
    main()
