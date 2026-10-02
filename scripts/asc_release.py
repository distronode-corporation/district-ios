#!/usr/bin/env python3
"""App Store Connect steps of the release lane: check a build number is unused, wait for a
build, submit it for review, and read whether a version is on sale.

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=/path/AuthKey_<id>.p8 \\
      python3 scripts/asc_release.py wait-valid --version 1.2 --build 4104
    ... python3 scripts/asc_release.py submit --version 1.2 --build 4104
    ... python3 scripts/asc_release.py highest-build --version 1.2
    ... python3 scripts/asc_release.py store-state --version 1.2    # read only
    python3 scripts/asc_release.py whats-new --version 1.2    # no credentials needed
    python3 scripts/asc_release.py release-body --version 1.2 --build 4102    # nor here

Used by scripts/release-preflight.sh (highest-build, before anything is built),
.github/workflows/release.yml (wait-valid after the upload), submit.yml (submit) and
scripts/github-release.sh (store-state and release-body).
Standard library only: the ES256 signature is made by the `openssl` binary and every HTTP
call goes through `curl`, so the script needs no pip install and no pinned dependency.

The .p8 is read by openssl from its path and never by this process; the bearer token
reaches curl on stdin (`-K -`), never on argv, which is world-readable through `ps`.

`submit` is written to be re-run after a partial failure: every step reads the current
state first and does only what is missing, and a version that is already waiting for or
in review is reported and left alone rather than submitted twice.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1"
BUNDLE_ID = "com.distronode.district"  # PRODUCT_BUNDLE_IDENTIFIER in project.yml
PLATFORM = "IOS"
WHATS_NEW_LIMIT = 4000  # App Store Connect's limit on the whatsNew field

# appStoreVersion states in which the version is with Apple or already out: submitting
# again is either refused or a double submission, so `submit` stops and says so.
ALREADY_SUBMITTED = {
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "PENDING_APPLE_RELEASE",
    "PENDING_DEVELOPER_RELEASE",
    "PROCESSING_FOR_APP_STORE",
    "PROCESSING_FOR_DISTRIBUTION",
    "READY_FOR_DISTRIBUTION",
    "READY_FOR_SALE",
    "ACCEPTED",
}
# reviewSubmission states that mean a submission is already with Apple.
SUBMISSION_IN_FLIGHT = {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}
# A version that is or was on sale. appVersionState reads READY_FOR_DISTRIBUTION from
# release onwards; the older appStoreState is kept as a second witness.
ON_SALE_VERSION_STATES = {"READY_FOR_DISTRIBUTION"}
ON_SALE_STORE_STATES = {"READY_FOR_SALE", "REPLACED_WITH_NEW_VERSION"}

APP_STORE_URL = "https://apps.apple.com/app/id6809297970"


def die(msg: str) -> None:
    print(f"FATAL - {msg}", file=sys.stderr)
    sys.exit(1)


# ── CHANGELOG ────────────────────────────────────────────────────────────────


def changelog_section(changelog: Path, version: str, markdown: bool = False) -> str:
    """The `## [version]` section of a Keep a Changelog file.

    A bullet wrapped over several lines becomes one line and runs of blank lines become
    one. As plain text (the default) headings lose their `#`; as Markdown they keep it.
    An empty or missing section is refused.
    """
    lines = changelog.read_text(encoding="utf-8").splitlines()
    heading = re.compile(r"^## \[" + re.escape(version) + r"\](\s|$)")
    start = next((i for i, line in enumerate(lines) if heading.match(line)), None)
    if start is None:
        die(f"{changelog} has no '## [{version}]' section; add the release notes before submitting.")
    body: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("## ") or re.match(r"^\[[^\]]+\]: ", line):
            break
        body.append(line)

    out: list[str] = []
    for raw in body:
        line = raw.rstrip()
        if not line:
            if out and out[-1] != "":
                out.append("")
            continue
        if line.startswith("#"):
            out.append(line if markdown else line.lstrip("#").strip())
        elif line.startswith("- ") or not out or out[-1] == "":
            out.append(line.strip())
        else:
            # A wrapped continuation of the previous line.
            out[-1] = out[-1] + " " + line.strip()
    text = "\n".join(out).strip()
    if not text:
        die(f"the '## [{version}]' section of {changelog} is empty; add the release notes before submitting.")
    return text


def whats_new(changelog: Path, version: str) -> str:
    """The release notes for App Store Connect: the version's CHANGELOG section as plain
    text, refused if it is longer than App Store Connect accepts. A submission with no
    release notes, or with notes cut off mid-sentence, is worse than none at all.
    """
    text = changelog_section(changelog, version)
    if len(text) > WHATS_NEW_LIMIT:
        die(f"the release notes for {version} are {len(text)} characters; App Store Connect accepts {WHATS_NEW_LIMIT}.")
    return text


def release_body(changelog: Path, version: str, build: str) -> str:
    """The body of a version's GitHub Release, in the shape of v1.2's: what it is the
    source of, where it is on the App Store, then its CHANGELOG section as Markdown."""
    return (
        f"District AI for iOS {version}, the source of the App Store release (build {build}).\n\n"
        f"On the App Store: {APP_STORE_URL}\n\n"
        f"{changelog_section(changelog, version, markdown=True)}\n"
    )


# ── Authentication ───────────────────────────────────────────────────────────


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_to_raw(der: bytes) -> bytes:
    """An ECDSA DER signature (SEQUENCE { INTEGER r, INTEGER s }) as JOSE's r || s."""

    def read_int(buf: bytes, pos: int) -> tuple[int, int]:
        if buf[pos] != 0x02:
            raise ValueError("not a DER INTEGER")
        length = buf[pos + 1]
        start = pos + 2
        return int.from_bytes(buf[start : start + length], "big"), start + length

    if der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    pos = 3 if der[1] & 0x80 else 2
    r, pos = read_int(der, pos)
    s, _ = read_int(der, pos)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


class Client:
    def __init__(self) -> None:
        self.key_id = os.environ.get("ASC_KEY_ID", "")
        self.issuer = os.environ.get("ASC_ISSUER_ID", "")
        self.key_path = os.environ.get("ASC_KEY_PATH", "")
        for name, value in (("ASC_KEY_ID", self.key_id), ("ASC_ISSUER_ID", self.issuer), ("ASC_KEY_PATH", self.key_path)):
            if not value:
                die(f"{name} is unset. ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH are all required.")
        if not Path(self.key_path).is_file():
            die(f"no App Store Connect key at {self.key_path}.")
        self._token = ""
        self._minted = 0.0

    def token(self) -> str:
        # Apple accepts at most 20 minutes; a fresh one every 10 keeps a long wait valid.
        if self._token and time.time() - self._minted < 600:
            return self._token
        now = int(time.time())
        header = _b64url(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
        claims = {"iss": self.issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
        payload = _b64url(json.dumps(claims).encode())
        signing_input = f"{header}.{payload}".encode()
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key_path],
            input=signing_input,
            capture_output=True,
            check=True,
        ).stdout
        self._token = f"{header}.{payload}.{_b64url(_der_to_raw(der))}"
        self._minted = time.time()
        return self._token

    def call(self, method: str, path: str, body: dict | None = None, ok=(200, 201, 204)) -> tuple[int, dict]:
        url = path if path.startswith("https://") else API + path
        config = f'header = "Authorization: Bearer {self.token()}"\n'
        cmd = ["curl", "-sS", "-g", "-X", method, "-K", "-", "-w", "\n%{http_code}", "--max-time", "120"]
        body_file = None
        if body is not None:
            body_file = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump(body, body_file)
            body_file.close()
            cmd += ["-H", "Content-Type: application/json", "--data-binary", f"@{body_file.name}"]
        cmd.append(url)
        try:
            result = subprocess.run(cmd, input=config.encode(), capture_output=True, check=False)
        finally:
            if body_file is not None:
                os.unlink(body_file.name)
        if result.returncode != 0:
            die(f"{method} {path}: curl exited {result.returncode}: {result.stderr.decode(errors='replace').strip()}")
        text, _, code_text = result.stdout.decode(errors="replace").rpartition("\n")
        code = int(code_text)
        # The status first: an error from a proxy or a load balancer (a 502 or 503 during
        # a release) is an HTML page, and parsing it would end in a traceback that hides
        # the code.
        if code not in ok:
            try:
                data = json.loads(text) if text.strip() else {}
            except ValueError:
                data = {}
            errors = data.get("errors", []) if isinstance(data, dict) else []
            details = "; ".join(f"{e.get('code')}: {e.get('detail') or e.get('title')}" for e in errors)
            die(f"{method} {path} answered {code}: {details or ' '.join(text.split())[:500]}")
        return code, json.loads(text) if text.strip() else {}

    def get(self, path: str) -> dict:
        return self.call("GET", path)[1]


# ── Lookups ──────────────────────────────────────────────────────────────────


def app_id(client: Client) -> str:
    apps = client.get(f"/apps?filter[bundleId]={BUNDLE_ID}&fields[apps]=bundleId")["data"]
    match = [a for a in apps if a["attributes"]["bundleId"] == BUNDLE_ID]
    if len(match) != 1:
        die(f"expected one App Store Connect app for {BUNDLE_ID}, found {len(match)}.")
    return match[0]["id"]


def find_build(client: Client, app: str, version: str, build: str) -> dict | None:
    query = (
        f"/builds?filter[app]={app}&filter[version]={build}"
        f"&filter[preReleaseVersion.version]={version}&filter[preReleaseVersion.platform]={PLATFORM}"
        "&fields[builds]=version,processingState,expired,uploadedDate"
    )
    data = client.get(query)["data"]
    return data[0] if data else None


def highest_build(client: Client, app: str, version: str) -> int:
    """The highest build number already uploaded for this version, or 0 if there is none.

    App Store Connect refuses a build number at or below one it already has, so a run
    whose number is not above this one would spend its whole archive to be turned away.
    Expired builds are included: their numbers stay taken.
    """
    query = (
        f"/builds?filter[app]={app}&filter[preReleaseVersion.version]={version}"
        f"&filter[preReleaseVersion.platform]={PLATFORM}&sort=-uploadedDate&limit=200&fields[builds]=version"
    )
    numbers = [int(b["attributes"]["version"]) for b in client.get(query)["data"] if b["attributes"]["version"].isdigit()]
    return max(numbers, default=0)


def wait_valid(client: Client, app: str, version: str, build: str, timeout: int) -> dict:
    """Polls until the build exists and is VALID. A build Apple marks INVALID or FAILED
    fails at once; one that never appears fails at the timeout, naming both numbers."""
    deadline = time.time() + timeout
    last = None
    while True:
        found = find_build(client, app, version, build)
        state = found["attributes"]["processingState"] if found else "not visible yet"
        if state != last:
            print(f"build {version} ({build}): {state}", flush=True)
            last = state
        if state == "VALID":
            return found
        if state in ("INVALID", "FAILED"):
            die(f"App Store Connect marked build {version} ({build}) {state}; Apple emails the reason to the account holder.")
        if time.time() > deadline:
            die(f"build {version} ({build}) was not VALID after {timeout}s (last state: {state}).")
        time.sleep(30)


def store_state(client: Client, app: str, version: str) -> tuple[str, str, bool]:
    """Where a version stands on the App Store, read only: its state ("NONE" when App
    Store Connect has no record for it), the build number attached to it ("" when none
    is), and whether it is or was on sale."""
    versions = client.get(
        f"/apps/{app}/appStoreVersions?filter[versionString]={version}&filter[platform]={PLATFORM}"
        "&fields[appStoreVersions]=versionString,appStoreState,appVersionState"
    )["data"]
    if not versions:
        return "NONE", "", False
    record = versions[0]
    version_state = record["attributes"].get("appVersionState") or ""
    store = record["attributes"].get("appStoreState") or ""
    attached = client.get(f"/appStoreVersions/{record['id']}/build?fields[builds]=version").get("data")
    build = attached["attributes"]["version"] if attached else ""
    on_sale = version_state in ON_SALE_VERSION_STATES or store in ON_SALE_STORE_STATES
    return version_state or store, build, on_sale


# ── Submission ───────────────────────────────────────────────────────────────


def submission_versions(client: Client, submission: str) -> dict[str, str]:
    """The appStoreVersions a review submission carries, as {id: versionString}. The
    string is "?" when the included record does not name it."""
    page = client.get(
        f"/reviewSubmissions/{submission}/items?include=appStoreVersion&fields[appStoreVersions]=versionString"
    )
    names = {
        inc["id"]: inc.get("attributes", {}).get("versionString", "?")
        for inc in page.get("included", [])
        if inc.get("type") == "appStoreVersions"
    }
    ids = [(i.get("relationships", {}).get("appStoreVersion", {}).get("data") or {}).get("id") for i in page["data"]]
    return {vid: names.get(vid, "?") for vid in ids if vid}


def submit(client: Client, version: str, build: str, notes: str, timeout: int) -> None:
    app = app_id(client)
    built = wait_valid(client, app, version, build, timeout)

    # 1. The version record: reuse the one for this version string, or create it.
    versions = client.get(
        f"/apps/{app}/appStoreVersions?filter[versionString]={version}&filter[platform]={PLATFORM}"
        "&fields[appStoreVersions]=versionString,appStoreState,appVersionState"
    )["data"]
    if versions:
        record = versions[0]
        state = record["attributes"].get("appVersionState") or record["attributes"].get("appStoreState")
        print(f"version {version}: record {record['id']} exists, state {state}")
        if state in ALREADY_SUBMITTED:
            print(f"version {version} is already {state}. Nothing was submitted.")
            return
    else:
        _, created = client.call(
            "POST",
            "/appStoreVersions",
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {"platform": PLATFORM, "versionString": version},
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )
        record = created["data"]
        print(f"version {version}: created record {record['id']}")
    version_id = record["id"]

    # 2. Release notes on every localization the record has.
    localizations = client.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    if not localizations:
        die(f"version {version} has no localizations to carry the release notes.")
    for loc in localizations:
        if loc["attributes"].get("whatsNew") == notes:
            print(f"whatsNew ({loc['attributes']['locale']}): already set")
            continue
        client.call(
            "PATCH",
            f"/appStoreVersionLocalizations/{loc['id']}",
            {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {"whatsNew": notes}}},
        )
        print(f"whatsNew ({loc['attributes']['locale']}): set")

    # 3. The build. A build attaches only to the record whose version string equals its
    # CFBundleShortVersionString, which the lookup above already guarantees.
    attached = client.get(f"/appStoreVersions/{version_id}/relationships/build").get("data")
    if attached and attached["id"] == built["id"]:
        print(f"build {build}: already attached")
    else:
        client.call(
            "PATCH",
            f"/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": built["id"]}},
        )
        print(f"build {build}: attached")

    # 4. The review submission: refuse to add a second one while one is with Apple, reuse
    # an open draft, otherwise create one.
    submissions = client.get(
        f"/reviewSubmissions?filter[app]={app}&filter[platform]={PLATFORM}"
        "&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES&fields[reviewSubmissions]=state"
    )["data"]
    for sub in submissions:
        state = sub["attributes"]["state"]
        if state not in SUBMISSION_IN_FLIGHT:
            continue
        # Apple holds one submission per platform at a time. It is this run's only if it
        # carries this version; one for another version blocks this one, and reporting
        # success would leave this version out of review with a green run.
        carried = submission_versions(client, sub["id"])
        if version_id in carried:
            print(f"review submission {sub['id']} is already {state}. Nothing was submitted.")
            return
        blocking = ", ".join(sorted(carried.values())) or "no version"
        die(
            f"review submission {sub['id']} is {state} with {blocking}, not {version}. App Store Connect "
            "takes one submission at a time; resolve or withdraw that one first. Nothing was submitted."
        )
    draft = next((s for s in submissions if s["attributes"]["state"] == "READY_FOR_REVIEW"), None)
    if draft is None:
        _, created = client.call(
            "POST",
            "/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": PLATFORM},
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )
        draft = created["data"]
        print(f"review submission {draft['id']}: created")
    else:
        print(f"review submission {draft['id']}: reusing the open draft")

    if version_id in submission_versions(client, draft["id"]):
        print(f"version {version}: already an item of the submission")
    else:
        client.call(
            "POST",
            "/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": draft["id"]}},
                        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                    },
                }
            },
        )
        print(f"version {version}: added to the submission")

    _, done = client.call(
        "PATCH",
        f"/reviewSubmissions/{draft['id']}",
        {"data": {"type": "reviewSubmissions", "id": draft["id"], "attributes": {"submitted": True}}},
    )
    print(f"SUBMITTED - {version} ({build}) for App Review; submission {draft['id']} is {done['data']['attributes'].get('state')}.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("wait-valid", "submit", "whats-new", "highest-build", "store-state", "release-body"):
        p = sub.add_parser(name)
        p.add_argument("--version", required=True, help="the marketing version, e.g. 1.2")
        if name in ("wait-valid", "submit", "release-body"):
            p.add_argument("--build", required=True, help="the build number (CFBundleVersion)")
        if name in ("wait-valid", "submit"):
            p.add_argument("--timeout", type=int, default=3600, help="seconds to wait for VALID")
        p.add_argument("--changelog", default=str(Path(__file__).resolve().parent.parent / "CHANGELOG.md"))
    args = parser.parse_args()

    if args.command == "whats-new":
        print(whats_new(Path(args.changelog), args.version))
        return
    if args.command in ("highest-build", "store-state"):
        if not re.fullmatch(r"\d+(\.\d+){1,2}", args.version):
            die(f"version '{args.version}' is malformed.")
        client = Client()
        if args.command == "highest-build":
            print(highest_build(client, app_id(client), args.version))
        else:
            state, build, on_sale = store_state(client, app_id(client), args.version)
            print(f"state={state}\nbuild={build}\non_sale={'yes' if on_sale else 'no'}")
        return
    if not re.fullmatch(r"\d+(\.\d+){1,2}", args.version) or not args.build.isdigit():
        die(f"version '{args.version}' or build '{args.build}' is malformed.")
    if args.command == "release-body":
        sys.stdout.write(release_body(Path(args.changelog), args.version, args.build))
        return
    client = Client()
    if args.command == "wait-valid":
        found = wait_valid(client, app_id(client), args.version, args.build, args.timeout)
        print(f"VALID - build {args.version} ({args.build}), id {found['id']}")
    else:
        # The notes are read BEFORE anything is changed in App Store Connect, so a missing
        # CHANGELOG section stops the run with nothing half done.
        submit(client, args.version, args.build, whats_new(Path(args.changelog), args.version), args.timeout)


if __name__ == "__main__":
    main()
