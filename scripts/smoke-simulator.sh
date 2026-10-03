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
#   DISTRICT_SMOKE_PLAN                              expected tier, default Studio
# With the first two unset every case in the suite calls `XCTSkip`, the run is green,
# and this script says so, a skip and a pass are not the same claim.
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

# ⛔ THE PROJECT IS GENERATED, NOT COMMITTED. `.gitignore` ignores `*.xcodeproj/` and
# `project.yml` is the source of truth, so a run against a stale or absent project is the
# default state of a fresh clone.
echo "== generating DistrictAI.xcodeproj from project.yml =="
xcodegen generate --spec project.yml

if [ -n "${DISTRICT_SMOKE_EMAIL:-}" ] && [ -n "${DISTRICT_SMOKE_PASSWORD:-}" ]; then
  echo "== credentials present: the smoke journey will run =="
else
  echo "== DISTRICT_SMOKE_EMAIL / DISTRICT_SMOKE_PASSWORD unset =="
  echo "== every case will XCTSkip; the run will be GREEN and will have PROVEN NOTHING =="
fi

set +e
TEST_RUNNER_DISTRICT_SMOKE_EMAIL="${DISTRICT_SMOKE_EMAIL:-}" \
TEST_RUNNER_DISTRICT_SMOKE_PASSWORD="${DISTRICT_SMOKE_PASSWORD:-}" \
TEST_RUNNER_DISTRICT_SMOKE_CONTACT="${DISTRICT_SMOKE_CONTACT:-}" \
TEST_RUNNER_DISTRICT_SMOKE_PLAN="${DISTRICT_SMOKE_PLAN:-Studio}" \
xcodebuild test \
  -project DistrictAI.xcodeproj \
  -scheme DistrictAI \
  -only-testing:DistrictSmokeUITests \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$RESULT" \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$OUT/xcodebuild-smoke.log"
STATUS=${PIPESTATUS[0]}
set -e

# ── Attachments ─────────────────────────────────────────────────────────────────
# ⚠️ THE SCREENSHOTS ARE INSIDE THE RESULT BUNDLE AND ARE NOT FILES UNTIL EXPORTED.
# `.xcresult` is an opaque directory; a CI artifact of it is openable only in Xcode, so
# the attachments are exported next to it for anyone reading the job from a browser.
if [ -d "$RESULT" ]; then
  echo "== exporting attachments =="
  mkdir -p "$OUT/attachments"
  # ⛔ `--legacy` IS REQUIRED ON XCODE 16+. `xcresulttool export attachments` without it
  # errors with "this command is deprecated"; Apple moved the non-legacy surface to a
  # different verb set and the old one still works only behind that flag. Tolerated
  # rather than fatal: the run's verdict is xcodebuild's, not the exporter's.
  xcrun xcresulttool export attachments \
    --path "$RESULT" \
    --output-path "$OUT/attachments" \
    --legacy 2>/dev/null \
    || echo "WARNING: attachment export failed; the .xcresult still holds them"
  find "$OUT/attachments" -type f 2>/dev/null | sort || true
fi

echo "== xcodebuild exited $STATUS; result bundle at $RESULT =="

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
