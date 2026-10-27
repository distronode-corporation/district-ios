#!/usr/bin/env bash
# Run the mobile smoke suite on a simulator. THIS RUNS ON A MAC: it needs Xcode,
# which has no Linux equivalent.
#
# Usage, from the repository root:
#   scripts/smoke-simulator.sh [--device "iPhone 16"] [--keep-derived]
#
# Credentials come from the environment and are never written to disk:
#   DISTRICT_SMOKE_EMAIL / DISTRICT_SMOKE_PASSWORD   the app-store demo account
#   DISTRICT_SMOKE_CONTACT                           a seeded contact's display name
#   DISTRICT_SMOKE_PLAN                              expected plan name, default Studio (the
#                                                    review demo account); the QA fixture
#                                                    appreview@ is on "Voice Pro"
# With the first two unset every case in the suite calls `XCTSkip`, the run is green,
# and this script says so, a skip and a pass are not the same claim.
#
# ⛔ THE PASSWORD NEVER REACHES THE TEST PROCESS, AND NO CHILD OF THIS SCRIPT INHERITS IT.
# XCUITest's `typeText` writes `Type '<text>' into "Password"` into the run log, the console
# log and the result bundle, which is how the QA fixture's password was logged on the iMac.
# So the script copies it into a shell variable, unsets the exported one (xcodebuild imports
# its environment as build settings, and a run-script phase can print those), writes it to
# the simulator's pasteboard with `simctl pbcopy` FROM STDIN (printf is a builtin, so it is
# in no argv and on no disk), and tells the runner only that it did
# (`DISTRICT_SMOKE_PASSWORD_ON_PASTEBOARD=1`). The suite pastes it from the field's edit
# menu. The simulator's pasteboard is cleared when this script exits, on every path, and the
# Mac's too when Simulator.app's pasteboard sync carried the password there.
# ⛔ AND THE RUN IS CHECKED FOR IT AFTERWARDS: the log, the result bundle (raw, and its
# exported activities, console log and diagnostics) and the attachments are searched for the
# password, without printing it. A copy fails the run (exit 3) and deletes the artefacts that
# held it; a result bundle or attachments that cannot be read back fail a green run (exit 4),
# because a check that could not look is not a check that passed.
#
# ⛔ AD-HOC SIGNED (`CODE_SIGN_IDENTITY=-`), NEVER `CODE_SIGNING_ALLOWED=NO`. An unsigned
# simulator build has no keychain entitlement, so `KeychainTokenStore` throws on its first
# read and the app opens on "We could not read your saved session" with no way into the
# browser sign-in: every run failed at "the login page never rendered" (3.0.3 gate,
# 2026-10-23). Ad-hoc signing needs no team or certificate. No `DEVELOPMENT_TEAM` either:
# project.yml's rule against one holds here too.
#
# ⛔ `TEST_RUNNER_`-PREFIXED, AND IN xcodebuild's ENVIRONMENT, NEVER ON ITS COMMAND LINE.
# xcodebuild injects a variable into the UI-test RUNNER process only when the name
# carries that prefix, and strips it before the test reads it. Passing a bare name sets
# it on xcodebuild's own environment, where the runner never sees it, and the suite then
# skips every case while the operator is looking at a shell that clearly has the
# variable set. A `NAME=value` ARGUMENT would also reach the runner, but xcodebuild
# echoes every command-line setting under "Build settings from command line", which
# would write the password into the log this script tees, and argv is visible to `ps`.
set -euo pipefail

# Not exported: from here on only this shell holds the password.
SMOKE_PASSWORD="${DISTRICT_SMOKE_PASSWORD:-}"
unset DISTRICT_SMOKE_PASSWORD

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DEVICE="${SMOKE_SIM_DEVICE:-iPhone 16}"
KEEP_DERIVED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --keep-derived) KEEP_DERIVED=1; shift ;;
    *) echo "FATAL: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || { echo "FATAL: xcodebuild not found (run this on a macOS host with Xcode)" >&2; exit 1; }
command -v xcodegen >/dev/null 2>&1 || { echo "FATAL: xcodegen not found (brew install xcodegen)" >&2; exit 1; }

OUT="$ROOT/build/smoke"
RESULT="$OUT/smoke.xcresult"
DERIVED="${SMOKE_DERIVED_DATA:-$ROOT/DerivedData}"
mkdir -p "$OUT"

# ⛔ THE RESULT BUNDLE MUST NOT EXIST. xcodebuild REFUSES to overwrite one and fails with
# "the file couldn't be saved because it already exists", which reads like a build error
# rather than a stale artefact from the previous run.
rm -rf "$RESULT"
# ⚠️ AND NO EARLIER RUN'S ATTACHMENTS: left in place, one device's screenshots sat beside the
# next device's run, so the leak scan and the file list mixed two runs (iMac, PR #91 smoke).
rm -rf "$OUT/attachments"

# ⛔ THE PROJECT IS GENERATED, NOT COMMITTED. `.gitignore` ignores `*.xcodeproj/` and
# `project.yml` is the source of truth, so a run against a stale or absent project is the
# default state of a fresh clone.
echo "== generating DistrictAI.xcodeproj from project.yml =="
xcodegen generate --spec project.yml

CREDENTIALS=0
if [ -n "${DISTRICT_SMOKE_EMAIL:-}" ] && [ -n "$SMOKE_PASSWORD" ]; then
  CREDENTIALS=1
  echo "== credentials present: the smoke journey will run =="
else
  echo "== DISTRICT_SMOKE_EMAIL / DISTRICT_SMOKE_PASSWORD unset =="
  echo "== every case will XCTSkip; the run will be GREEN and will have PROVEN NOTHING =="
fi

# ⛔ A FRESH INSTALL, OR THE JOURNEY STARTS SIGNED IN. A signed build keeps the last run's
# session in the simulator's keychain, so the next launch skips the sign-in screen the
# journey begins with. The website session in the browser's cookie jar may survive this;
# the journey takes the consent screen directly when it does.
echo "== removing any previous install from $DEVICE =="
# ⚠️ BOOTED IS NOT READY. `simctl boot` returns while the device is still starting, and a
# `simctl pbcopy` sent then times out (NSPOSIXErrorDomain 60) on an erased device every time.
# `bootstatus -b` boots it if needed and returns once the boot has completed.
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" com.distronode.district >/dev/null 2>&1 || true

# ── The password, by pasteboard ─────────────────────────────────────────────────
# ⚠️ SEEDED FROM HERE, NOT FROM THE TEST: a `UIPasteboard` write from the UI-test runner fails
# on iOS 14.5 and later (`PBErrorDomain` 11, "the pasteboard name ... is not valid").
# simctl_pbcopy TEXT: write TEXT to the simulator's pasteboard (from stdin), retried.
# ⚠️ `simctl pbcopy` TIMES OUT INTERMITTENTLY (NSPOSIXErrorDomain 60) EVEN ON A BOOTED DEVICE:
# every try with Simulator.app closed and 3 of 12 with it open (iMac, PR #90 smoke). So it is
# retried, and Simulator.app is opened (in the background) after the third failure.
# SMOKE_PBCOPY_BACKOFF is the pause between tries, in seconds.
simctl_pbcopy() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if printf '%s' "$1" | xcrun simctl pbcopy "$DEVICE"; then
      return 0
    fi
    echo "WARNING: simctl pbcopy try $attempt of 6 failed" >&2
    if [ "$attempt" -eq 3 ] && command -v open >/dev/null 2>&1; then
      open -g -a Simulator >/dev/null 2>&1 || true
    fi
    [ "$attempt" -eq 6 ] || sleep "${SMOKE_PBCOPY_BACKOFF:-5}"
  done
  return 1
}
clear_pasteboards() {
  simctl_pbcopy '' 2>/dev/null ||
    echo "WARNING: could not clear the $DEVICE pasteboard; it may still hold the password (erase the simulator)" >&2
  # Simulator.app, while open, syncs the simulator's pasteboard to the Mac's. Cleared only
  # when it holds exactly the password, so an operator's own clipboard is left alone.
  if command -v pbpaste >/dev/null 2>&1 && [ "$(pbpaste 2>/dev/null)" = "$SMOKE_PASSWORD" ]; then
    printf '' | pbcopy
  fi
}
ON_PASTEBOARD=""
if [ "$CREDENTIALS" -eq 1 ]; then
  trap clear_pasteboards EXIT
  simctl_pbcopy "$SMOKE_PASSWORD" ||
    { echo "FATAL: could not put the password on the $DEVICE pasteboard (xcrun simctl pbcopy)" >&2; exit 1; }
  ON_PASTEBOARD=1
  echo "== password on the $DEVICE pasteboard for the suite to paste; cleared on exit =="
fi

# ⚠️ `-parallel-testing-enabled NO`: a parallel run executes on CLONES of the device, and a
# clone has its own pasteboard, empty, so the paste would find nothing.
set +e
TEST_RUNNER_DISTRICT_SMOKE_EMAIL="${DISTRICT_SMOKE_EMAIL:-}" \
TEST_RUNNER_DISTRICT_SMOKE_PASSWORD_ON_PASTEBOARD="$ON_PASTEBOARD" \
TEST_RUNNER_DISTRICT_SMOKE_CONTACT="${DISTRICT_SMOKE_CONTACT:-}" \
TEST_RUNNER_DISTRICT_SMOKE_PLAN="${DISTRICT_SMOKE_PLAN:-Studio}" \
xcodebuild test \
  -project DistrictAI.xcodeproj \
  -scheme DistrictAI \
  -only-testing:DistrictSmokeUITests \
  -parallel-testing-enabled NO \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=YES \
  2>&1 | tee "$OUT/xcodebuild-smoke.log"
STATUS=${PIPESTATUS[0]}
set -e

# ── Attachments ─────────────────────────────────────────────────────────────────
# ⚠️ THE SCREENSHOTS ARE INSIDE THE RESULT BUNDLE AND ARE NOT FILES UNTIL EXPORTED.
# `.xcresult` is an opaque directory; a CI artifact of it is openable only in Xcode, so
# the attachments are exported next to it for anyone reading the job from a browser.
ATTACHMENTS_EXPORTED=1
if [ -d "$RESULT" ]; then
  echo "== exporting attachments =="
  mkdir -p "$OUT/attachments"
  # ⛔ `--legacy` IS REQUIRED ON XCODE 16+. `xcresulttool export attachments` without it
  # errors with "this command is deprecated"; Apple moved the non-legacy surface to a
  # different verb set and the old one still works only behind that flag. Tolerated
  # rather than fatal: the run's verdict is xcodebuild's, not the exporter's.
  # ⛔ A FAILED EXPORT IS REMEMBERED: the leak guard below must not call the attachments
  # clean when it could not search them (iPad Pro 13, PR #90 smoke: "export failed", then
  # "no copy of the password ... or the attachments").
  if ! xcrun xcresulttool export attachments \
    --path "$RESULT" \
    --output-path "$OUT/attachments" \
    --legacy 2>/dev/null; then
    ATTACHMENTS_EXPORTED=0
    echo "WARNING: attachment export failed; the .xcresult still holds them"
  fi
  find "$OUT/attachments" -type f 2>/dev/null | sort || true
fi

echo "== xcodebuild exited $STATUS; result bundle at $RESULT =="

# ── Password leak guard ─────────────────────────────────────────────────────────
# ⛔ THE PASSWORD IS NEVER IN AN ARGV OR ON STDOUT HERE. grep reads it as a pattern file
# through process substitution (a pipe from the printf builtin), and every line printed
# names a file, never a match. `-l` lists files; `-q` is not used so each source is named.
# ⚠️ THREE SPELLINGS: as typed, and as JSON writes it (xcresulttool escapes `\` and `"`, and
# may escape `/`), so an export cannot hide a copy behind its own quoting.
# ⚠️ AT LEAST 8 CHARACTERS: a shorter value matches by chance in a binary result bundle.
secret_patterns() {
  local json="${SMOKE_PASSWORD//\\/\\\\}"
  json="${json//\"/\\\"}"
  printf '%s\n' "$SMOKE_PASSWORD" "$json" "${json//\//\\/}"
}
files_with_secret() {
  grep -a -r -l -F -s -f <(secret_patterns) -- "$@" || true
}
if [ "$CREDENTIALS" -eq 1 ] && [ "${#SMOKE_PASSWORD}" -lt 8 ]; then
  echo "WARNING: the password is shorter than 8 characters; not searched for in the artefacts"
elif [ "$CREDENTIALS" -eq 1 ]; then
  echo "== searching this run's artefacts for the password =="
  SCAN="$OUT/leak-scan"
  rm -rf "$SCAN"
  mkdir -p "$SCAN"
  # ⚠️ THE BUNDLE'S OWN FILES ARE MOSTLY COMPRESSED, so the raw search below is not enough
  # on its own: these are the readable forms of what the run recorded. `activities` holds
  # every XCTest step title (where `typeText` wrote the text), `console` the runner's output,
  # `diagnostics` the runner's and the app's logs.
  READABLE=0
  if [ -d "$RESULT" ]; then
    if xcrun xcresulttool get test-results tests --path "$RESULT" >"$SCAN/tests.json" 2>/dev/null; then
      N=0
      while IFS= read -r TEST_ID; do
        N=$((N + 1))
        # A suite's or a bundle's identifier is refused here; only a test case's answers.
        if xcrun xcresulttool get test-results activities --path "$RESULT" --test-id "$TEST_ID" \
          >"$SCAN/activities-$N.json" 2>/dev/null; then
          READABLE=1
        fi
      done < <(sed -n 's/.*"nodeIdentifier" *: *"\([^"]*\)".*/\1/p' "$SCAN/tests.json" | sort -u)
    fi
    if xcrun xcresulttool get log --path "$RESULT" --type console >"$SCAN/console.log" 2>/dev/null; then
      READABLE=1
    fi
    xcrun xcresulttool get log --path "$RESULT" --type action >"$SCAN/action.log" 2>/dev/null || true
    if xcrun xcresulttool export diagnostics --path "$RESULT" --output-path "$SCAN/diagnostics" >/dev/null 2>&1; then
      READABLE=1
    fi
  fi
  LEAKED=0
  # ⚠️ `$DERIVED/Logs` TOO: Xcode keeps its own copy of the test logs there, which outlives
  # this run under --keep-derived.
  for SOURCE in "$OUT/xcodebuild-smoke.log" "$RESULT" "$OUT/attachments" "$SCAN" "$DERIVED/Logs"; do
    [ -e "$SOURCE" ] || continue
    HITS="$(files_with_secret "$SOURCE")"
    [ -n "$HITS" ] || continue
    LEAKED=1
    echo "FATAL: the smoke password appears in ${SOURCE#"$ROOT"/}:" >&2
    while IFS= read -r HIT; do echo "  ${HIT#"$ROOT"/}" >&2; done <<<"$HITS"
    # An export's copy came from the bundle, so the bundle is what goes.
    if [ "$SOURCE" = "$SCAN" ]; then rm -rf "$RESULT"; else rm -rf "$SOURCE"; fi
  done
  rm -rf "$SCAN"
  if [ "$LEAKED" -eq 1 ]; then
    echo "FATAL: those artefacts are deleted; this run's terminal output carried the same text" >&2
    STATUS=3
  elif [ ! -d "$RESULT" ]; then
    echo "== no result bundle; the log holds no copy of the password =="
  elif [ "$READABLE" -eq 0 ]; then
    echo "FATAL: xcresulttool exported nothing readable, so the result bundle was not searched" >&2
    [ "$STATUS" -ne 0 ] || STATUS=4
  elif [ "$ATTACHMENTS_EXPORTED" -eq 0 ]; then
    echo "FATAL: the attachments could not be exported, so they were not searched" >&2
    [ "$STATUS" -ne 0 ] || STATUS=4
  else
    echo "== no copy of the password in the log, the result bundle or the attachments =="
  fi
fi

# ── Canary gauge ────────────────────────────────────────────────────────────────
# Silent no-op without a licence key, so a local run publishes nothing.
if [ -n "${NEWRELIC_LICENSE_KEY:-}" ]; then
  RUN_ID="${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}"
  OK=0; [ "$STATUS" -eq 0 ] && OK=1
  # New Relic Metric API payload: a single-element array holding a `metrics` list,
  # each a gauge with a ms timestamp.
  printf '[{"metrics":[{"name":"distronode.canary.mobile.ok","type":"gauge","value":%d,"timestamp":%d,"attributes":{"platform":"ios","runId":"%s"}}]}]' \
    "$OK" "$(date -u +%s)000" "$RUN_ID" \
  | curl -sS -m 20 -X POST 'https://metric-api.eu.newrelic.com/metric/v1' \
      -H "Api-Key: $NEWRELIC_LICENSE_KEY" \
      -H 'Content-Type: application/json' \
      --data-binary @- >/dev/null 2>&1 \
    && echo "== canary gauge pushed (ok=$OK) ==" \
    || echo "WARNING: canary gauge push failed; not failing the run over it"
fi

[ "$KEEP_DERIVED" -eq 1 ] || rm -rf "$DERIVED"

exit "$STATUS"
