#!/usr/bin/env bash
set -euo pipefail

# Run the UI-test suite, on the paired iPhone by default or on a simulator with
# `--sim`.
#
# ⛔ THE SESSION IS READ FROM A FILE ON DISK, NEVER FROM argv AND NEVER FROM A
# CHAT. `UITEST_SESSION_FILE` names a JSON file holding the five
# `/api/auth/native/token` keys plus `deviceId`. An argument would reach `ps`, the
# shell history and any process listing on the machine; a chat message would reach a
# transcript. The token is a live session for a review account and is revoked by
# the operator afterwards.
#
# ⛔ ONE MINT, ONE RUN. Refresh rotation is single-use: replaying the same pair is
# read as theft server-side and revokes the whole family, so a second run needs a
# second mint. `UITestApp` launches the app exactly once for the same reason.
#
# ⛔ THE FIRST DEVICE RUN REGISTERS THE PHONE ON TEAM R935BA6767, deliberately:
# `-allowProvisioningDeviceRegistration` is what does it. Run it only with the
# account holder's authorisation. That is an outward-facing effect on the Apple
# Developer account; a simulator run (`--sim`) has none, takes no signing flags at
# all, and is the default in CI.

cd "$(dirname "$0")/.."

MODE="device"
[ "${1:-}" = "--sim" ] && MODE="sim"

xcodegen generate --spec project.yml

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="$HOME/district-test-runs/$RUN_ID"
mkdir -p "$RESULT_DIR"
DERIVED="${UITEST_DERIVED_DATA:-$HOME/district-uitest-dd}"

# ⛔ THE PACKAGE CHECKOUTS ARE SHARED, NOT RE-CLONED PER DERIVED-DATA DIRECTORY.
# A fresh `-derivedDataPath` re-resolves every SwiftPM dependency from the network,
# and on a slow or flaky link that is fatal rather than slow: a run fails with
# "Failed to clone webrtc-xcframework" having tested nothing. Pointing every run at
# one checkout directory means resolution happens once and survives a DerivedData
# purge.
#
# ⚠️ IT IS SEEDED FROM THE REPO'S OWN DerivedData WHEN THAT IS THE ONLY RESOLVED
# COPY, which is the normal state after a build. Copying beats re-cloning.
SPM_DIR="${UITEST_SPM_DIR:-$HOME/district-spm}"
if [ ! -d "$SPM_DIR" ] && [ -d "DerivedData/SourcePackages" ]; then
  mkdir -p "$SPM_DIR"
  cp -R DerivedData/SourcePackages/. "$SPM_DIR/"
fi

COMMON=(
  test
  -project DistrictAI.xcodeproj
  -scheme DistrictAI
  -derivedDataPath "$DERIVED"
  -only-testing:DistrictAIUITests
  -clonedSourcePackagesDirPath "$SPM_DIR"
)

if [ "$MODE" = "sim" ]; then
  # ⚠️ THE DESTINATION IS DISCOVERED, NOT NAMED. A hardcoded device ties this to
  # whatever runtimes the machine happens to ship; the same discovery runs in CI.
  UDID="$(xcrun simctl list -j devices available | python3 -c '
import json,sys
d = json.load(sys.stdin)["devices"]
for key in sorted([k for k in d if "SimRuntime.iOS-" in k], reverse=True):
    for dev in d[key]:
        if dev.get("isAvailable") and "SimDeviceType.iPhone-" in dev.get("deviceTypeIdentifier", ""):
            print(dev["udid"]); raise SystemExit
raise SystemExit("no available iPhone simulator")')"
  echo "destination udid - $UDID"
  xcodebuild "${COMMON[@]}" \
    -destination "id=$UDID" \
    -resultBundlePath "$RESULT_DIR/sim.xcresult" \
    CODE_SIGNING_ALLOWED=NO
  exit $?
fi

# ── Device ───────────────────────────────────────────────────────────────────
: "${UITEST_SESSION_FILE:?set UITEST_SESSION_FILE to the minted session JSON}"
[ -r "$UITEST_SESSION_FILE" ] || { echo "FATAL - cannot read $UITEST_SESSION_FILE" >&2; exit 1; }
: "${ASC_ISSUER_ID:=$(cat "$HOME/private_keys/asc_issuer_id")}"
: "${ASC_KEY_ID:=$(cat "$HOME/private_keys/asc_key_id")}"

UDID="$(xcrun devicectl list devices --json-output - 2>/dev/null | python3 -c '
import json,sys
for d in json.load(sys.stdin).get("result", {}).get("devices", []):
    props = d.get("hardwareProperties", {})
    if d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(props.get("udid", "")); raise SystemExit
raise SystemExit("no available device")')"
[ -n "$UDID" ] || { echo "FATAL - no paired device is available" >&2; exit 1; }
echo "destination udid - $UDID"

# ⛔ THE RUN IS REFUSED AGAINST A RELEASE PRODUCT. The seam these tests depend on
# is `#if DEBUG`, so a Release build cannot be driven by them — and a run that
# quietly "passed" against a binary with no seam would be the worst outcome
# available: green, and testing nothing.
CONFIG="$(xcodebuild -project DistrictAI.xcodeproj -scheme DistrictAI -showBuildSettings 2>/dev/null \
  | awk '/ CONFIGURATION = /{print $3; exit}')"
if [ "$CONFIG" = "Release" ]; then
  echo "FATAL - the scheme's test action resolves to Release; the UI-test seam does not exist there." >&2
  exit 1
fi

xcodebuild "${COMMON[@]}" \
  -destination "id=$UDID" \
  -resultBundlePath "$RESULT_DIR/device.xcresult" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -authenticationKeyPath "$HOME/private_keys/AuthKey_${ASC_KEY_ID}.p8" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM=R935BA6767 \
  CODE_SIGN_STYLE=Automatic \
  TEST_RUNNER_DISTRICT_UITEST_SESSION="$(cat "$UITEST_SESSION_FILE")"
