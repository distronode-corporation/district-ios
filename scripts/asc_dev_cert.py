#!/usr/bin/env python3
"""The release run's own Apple Development certificate: created at the start of the run,
revoked at the end of it, by the id App Store Connect returned when it was created.

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=... \\
      python3 scripts/asc_dev_cert.py create --dir "$RUNNER_TEMP/devcert"
    ... python3 scripts/asc_dev_cert.py revoke --dir "$RUNNER_TEMP/devcert"

⛔ WHY. `xcodebuild archive -allowProvisioningUpdates` signs the archive with an Apple
Development identity, and on a fresh GitHub runner it has none, so Xcode minted a new
Apple Development certificate on the team for every release run and nothing ever revoked
it. The run now creates that certificate itself, hands the identity to Xcode in a keychain
of its own (release.yml), and revokes it in a step that runs whatever happened.

⛔ ONLY THIS RUN'S CERTIFICATE, AND ONLY BY ITS ID. `create` writes the id App Store Connect
answered to `<dir>/cert.id` before it does anything else, and `revoke` deletes exactly
`/certificates/<that id>`. Nothing here lists certificates, matches one by name, or touches
any other certificate or profile: a team's other certificates are people's, and a wrong
match would revoke somebody's signing identity.

Files under --dir (created mode 0700, files 0600): cert.id, key.pem (the private key,
never printed), cert.cer (DER, as App Store Connect returns it). The caller removes the
directory. Standard library only, on asc_release.py's client.
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_release  # noqa: E402
from asc_release import die  # noqa: E402

CERTIFICATE_TYPE = "DEVELOPMENT"  # "Apple Development", the identity an archive signs with
ID_FILE = "cert.id"
KEY_FILE = "key.pem"
CERT_FILE = "cert.cer"
# App Store Connect resource ids are alphanumeric; anything else is never put in a path.
ID_PATTERN = re.compile(r"[A-Za-z0-9]{1,64}")


def make_key_and_csr(directory: Path) -> str:
    """A fresh RSA 2048 key (App Store Connect accepts no other) and its CSR, in PEM."""
    key = directory / KEY_FILE
    subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"], check=True, capture_output=True)
    os.chmod(key, 0o600)
    csr = subprocess.run(
        ["openssl", "req", "-new", "-key", str(key), "-subj", "/CN=District AI release run/O=Distronode"],
        check=True,
        capture_output=True,
    ).stdout.decode("ascii")
    return csr


def create(client, directory: Path, csr_pem: str) -> str:
    """Create the certificate and record its id. Returns the id."""
    _, answer = client.call(
        "POST",
        "/certificates",
        {"data": {"type": "certificates", "attributes": {"certificateType": CERTIFICATE_TYPE, "csrContent": csr_pem}}},
    )
    cert_id = (answer.get("data") or {}).get("id", "")
    if not ID_PATTERN.fullmatch(cert_id):
        die("App Store Connect created a certificate but answered no usable id; revoke it in the portal by hand.")
    # ⛔ THE ID FIRST, before anything else can fail, so the revoke step always finds it.
    id_file = directory / ID_FILE
    id_file.write_text(cert_id + "\n", encoding="ascii")
    os.chmod(id_file, 0o600)
    content = (answer["data"].get("attributes") or {}).get("certificateContent") or ""
    try:
        der = base64.b64decode(content, validate=True)
    except ValueError:
        der = b""
    if not der:
        die(f"certificate {cert_id} came back without its content; the revoke step still removes it.")
    cert = directory / CERT_FILE
    cert.write_bytes(der)
    os.chmod(cert, 0o600)
    return cert_id


def recorded_id(directory: Path) -> str | None:
    """The id `create` recorded, or None when it recorded none (nothing was created)."""
    id_file = directory / ID_FILE
    if not id_file.is_file():
        return None
    cert_id = id_file.read_text(encoding="ascii").strip()
    if not ID_PATTERN.fullmatch(cert_id):
        die(f"{id_file} does not hold a certificate id; nothing was revoked.")
    return cert_id


def revoke(client, directory: Path) -> bool:
    """Revoke the certificate `create` recorded. False when there is none to revoke."""
    cert_id = recorded_id(directory)
    if cert_id is None:
        print("no certificate was created in this run; nothing to revoke")
        return False
    # 404: already gone (revoked by hand, or a re-run of this step), which is the goal.
    code, _ = client.call("DELETE", f"/certificates/{cert_id}", ok=(200, 204, 404))
    print(f"certificate {cert_id}: {'already gone' if code == 404 else 'revoked'}")
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("create", "revoke"))
    parser.add_argument("--dir", required=True, help="where cert.id, key.pem and cert.cer live")
    args = parser.parse_args()
    directory = Path(args.dir)
    client = asc_release.Client()
    if args.command == "create":
        old_umask = os.umask(0o077)
        try:
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            if (directory / ID_FILE).exists():
                die(f"{directory / ID_FILE} exists: this run already created a certificate.")
            cert_id = create(client, directory, make_key_and_csr(directory))
        finally:
            os.umask(old_umask)
        print(f"created Apple Development certificate {cert_id} for this run")
    else:
        revoke(client, directory)


if __name__ == "__main__":
    main()
