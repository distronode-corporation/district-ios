#!/usr/bin/env bash
#
# Harness for smoke-simulator.sh, driven against stub xcodegen/xcodebuild/xcrun.
#
#   bash scripts/smoke-simulator.test.sh
#
# ⛔ WHAT THIS HOLDS: the smoke build is AD-HOC SIGNED and starts from a FRESH INSTALL.
# `CODE_SIGNING_ALLOWED=NO` gave an app without a keychain, which opened on "We could not
# read your saved session" and failed every run at "the login page never rendered"
# (3.0.3 gate, 2026-10-23). A signed build keeps its session between runs, so without the
# uninstall the next run opens signed in and fails at "the sign-in screen never rendered".
#
# ⚠️ ASSERTS ON WHAT XCODEBUILD AND XCRUN WERE CALLED WITH, and on where the password
# went: osascript's stdin, typed into the simulator once the suite asks, and NOWHERE ELSE. Not argv
# (xcodebuild echoes it into the log this script tees, and `ps` shows it), not the
# runner's environment (XCUITest's `typeText` logged it from there), not any child's.
# ⛔ AND ON THE LEAK GUARD: a copy of the password in the log, the raw result bundle or an
# xcresulttool export (in its JSON-escaped spelling too) fails the run and deletes the
# artefact, the guard never prints it, and a bundle it cannot read fails a green run.
#
# ⚠️ NO `set -e`: every command whose status matters is read explicitly.
set -uo pipefail

for _leaked in $(env 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' |
  grep -E '^(DISTRICT_SMOKE_|TEST_RUNNER_|SMOKE_|STUB_|NEWRELIC_)'); do
  unset "$_leaked"
done

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

fail() {
  FAIL=$((FAIL + 1))
  echo "  x $1"
}
ok() {
  PASS=$((PASS + 1))
  echo "  ok $1"
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/smoke-sim-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# A repository-shaped directory holding only the script, so the run writes nothing into
# the real tree (build/smoke, DerivedData).
REPO="$TMPROOT/repo"
mkdir -p "$REPO/scripts" "$TMPROOT/bin"
cp "$HERE/smoke-simulator.sh" "$REPO/scripts/smoke-simulator.sh"
LOG="$TMPROOT/calls.log"
: >"$LOG"

cat >"$TMPROOT/bin/xcodegen" <<'STUB'
#!/usr/bin/env bash
echo "xcodegen $*" >>"$STUB_LOG"
echo "xcodegen-env bare=${DISTRICT_SMOKE_PASSWORD:-}" >>"$STUB_LOG"
STUB
# xcrun: `xcresulttool` answers like Xcode 16+, or fails every read under STUB_XCRESULT_FAIL,
# and fails the attachments export under STUB_ATTACH_FAIL.
cat >"$TMPROOT/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
echo "xcrun $*" >>"$STUB_LOG"
out_path() {
  while [ $# -gt 0 ]; do [ "$1" = "--output-path" ] && { echo "$2"; return; }; shift; done
}
case "$1 $2" in
  "xcresulttool get")
    [ -z "${STUB_XCRESULT_FAIL:-}" ] || exit 64
    case "$3 $4" in
      "test-results tests") printf '{ "testNodes" : [ { "nodeIdentifier" : "SmokeUITests/test_IOS_SMOKE_01()" } ] }\n' ;;
      "test-results activities") printf '{ "title" : "%s" }\n' "${STUB_ACTIVITY_TITLE:-Tap \"Paste\" MenuItem}" ;;
      *) echo "t = 0.00s Start Test" ;;
    esac ;;
  "xcresulttool export")
    [ "$3" = "attachments" ] || [ -z "${STUB_XCRESULT_FAIL:-}" ] || exit 64
    [ "$3" != "attachments" ] || [ -z "${STUB_ATTACH_FAIL:-}" ] || exit 64
    mkdir -p "$(out_path "$@")" ;;
esac
STUB
cat >"$TMPROOT/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
echo "xcodebuild $*" >>"$STUB_LOG"
echo "xcodebuild-env email=${TEST_RUNNER_DISTRICT_SMOKE_EMAIL:-} byscript=${TEST_RUNNER_DISTRICT_SMOKE_PASSWORD_BY_SCRIPT:-} password=${TEST_RUNNER_DISTRICT_SMOKE_PASSWORD:-} bare=${DISTRICT_SMOKE_PASSWORD:-} plan=${TEST_RUNNER_DISTRICT_SMOKE_PLAN:-}" >>"$STUB_LOG"
while [ $# -gt 0 ]; do [ "$1" = "-resultBundlePath" ] && BUNDLE="$2"; shift; done
mkdir -p "$BUNDLE/Data"
printf '%s\n' "${STUB_BUNDLE_TEXT:-opaque}" >"$BUNDLE/Data/data.0"
[ -z "${STUB_XCODEBUILD_STDOUT:-}" ] || printf '%s\n' "$STUB_XCODEBUILD_STDOUT"
# The suite's step asking for the password, then the wait for it, as the real suite waits.
if [ "${TEST_RUNNER_DISTRICT_SMOKE_PASSWORD_BY_SCRIPT:-}" = 1 ] && [ -z "${STUB_NO_MARKER:-}" ]; then
  echo "    t =     9.10s SMOKE-TYPE-PASSWORD-NOW"
  for _ in $(seq 1 40); do [ -e "$STUB_TYPED" ] && break; sleep 0.25; done
  sleep 0.5
fi
exit "${STUB_XCODEBUILD_EXIT:-0}"
STUB
# osascript: argv and the window it was told to raise are recorded; stdin (what it types)
# goes to $STUB_TYPED; it fails under STUB_OSA_FAIL, as it does without Accessibility.
cat >"$TMPROOT/bin/osascript" <<'STUB'
#!/usr/bin/env bash
echo "osascript $* window=${SMOKE_SIM_WINDOW:-}" | tr '\n' ' ' >>"$STUB_LOG"
echo >>"$STUB_LOG"
cat >"$STUB_TYPED.part"
mv "$STUB_TYPED.part" "$STUB_TYPED"
[ -z "${STUB_OSA_FAIL:-}" ] || { echo "execution error: osascript is not allowed to send keystrokes. (1002)" >&2; exit 1; }
STUB
chmod +x "$TMPROOT/bin/"*

TYPED="$TMPROOT/typed"
SMOKE="$REPO/build/smoke"

# run NAME=value...: the script, with the stubs first on PATH.
run() {
  : >"$LOG"
  rm -rf "$TYPED" "$SMOKE"
  OUT="$(cd "$REPO" && env PATH="$TMPROOT/bin:$PATH" STUB_LOG="$LOG" STUB_TYPED="$TYPED" \
    SMOKE_TYPE_TIMEOUT=20 SMOKE_DERIVED_DATA="$TMPROOT/dd" "$@" bash scripts/smoke-simulator.sh --device "iPhone 17 Pro" 2>&1)"
  RC=$?
  CALLS="$(cat "$LOG")"
  # Only the guard's own lines: what the script itself says about the password.
  GUARD="$(grep -E '^(FATAL|WARNING|==|  )' <<<"$OUT")"
}

# line_of PATTERN: the first line of the call log matching PATTERN, or empty.
line_of() {
  grep -n -m1 -E "$1" <<<"$CALLS" | cut -d: -f1
}

SECRET=s3cret-value

echo "== a run with credentials =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" \
  DISTRICT_SMOKE_PLAN="Voice Pro"
[ "$RC" -eq 0 ] && ok "exits 0 when xcodebuild does" || fail "exit $RC: $OUT"
BUILD="$(grep '^xcodebuild test ' <<<"$CALLS")"
[[ "$BUILD" == *"CODE_SIGN_IDENTITY=-"* ]] && ok "the build is ad-hoc signed" || fail "no CODE_SIGN_IDENTITY=-: $BUILD"
[[ "$BUILD" == *"CODE_SIGNING_ALLOWED=YES"* ]] && ok "signing is allowed" || fail "signing not allowed: $BUILD"
[[ "$BUILD" != *"CODE_SIGNING_ALLOWED=NO"* ]] && ok "never CODE_SIGNING_ALLOWED=NO" || fail "unsigned build: $BUILD"
[[ "$BUILD" != *"DEVELOPMENT_TEAM"* ]] && ok "names no team" || fail "a team on the command line: $BUILD"
[[ "$BUILD" == *"name=iPhone 17 Pro"* ]] && ok "runs on the device asked for" || fail "wrong destination: $BUILD"
[[ "$BUILD" == *"-parallel-testing-enabled NO"* ]] && ok "runs on the device itself, not a clone" ||
  fail "parallel testing not off: $BUILD"
[[ "$CALLS" != *"$SECRET"* ]] && ok "the password is in no argv and no child's environment" ||
  fail "password reached a child: $CALLS"
grep -q '^xcodebuild-env email=qa@example.invalid byscript=1 password= bare= plan=Voice Pro$' <<<"$CALLS" &&
  ok "the runner gets the email, the plan and a typing flag, never the password" || fail "runner env: $CALLS"
grep -q '^xcodegen-env bare=$' <<<"$CALLS" && ok "xcodegen does not inherit the password" || fail "xcodegen env: $CALLS"
[ "$(cat "$TYPED" 2>/dev/null)" = "$SECRET" ] && ok "the password reaches osascript by stdin" ||
  fail "osascript was not given the password"
UNINSTALL_LINE="$(line_of '^xcrun simctl uninstall iPhone 17 Pro com.distronode.district$')"
BUILD_LINE="$(line_of '^xcodebuild test ')"
TYPE_LINE="$(line_of '^osascript -l JavaScript ')"
[ -n "$UNINSTALL_LINE" ] && [ -n "$BUILD_LINE" ] && [ "$UNINSTALL_LINE" -lt "$BUILD_LINE" ] &&
  ok "the app is uninstalled before the run" || fail "no uninstall before xcodebuild: $CALLS"
BOOTED_LINE="$(line_of '^xcrun simctl bootstatus iPhone 17 Pro -b$')"
[ -n "$BOOTED_LINE" ] && [ "$BOOTED_LINE" -lt "$BUILD_LINE" ] && ok "the boot is awaited before the run" ||
  fail "no bootstatus -b before xcodebuild: $CALLS"
[ -n "$TYPE_LINE" ] && [ "$TYPE_LINE" -gt "$BUILD_LINE" ] && ok "the password is typed only once the suite asks" ||
  fail "typed before the suite asked: $CALLS"
[ "$(grep -c '^osascript ' <<<"$CALLS")" -eq 1 ] && ok "and typed exactly once" || fail "osascript calls: $CALLS"
[[ "$(grep '^osascript ' <<<"$CALLS")" == *"window=iPhone 17 Pro"* ]] && ok "into the named device's window" ||
  fail "window not named: $CALLS"
[[ "$GUARD" == *"password typed into the iPhone 17 Pro password field (not shown)"* ]] && ok "says it typed" ||
  fail "no typed line: $GUARD"
[[ "$OUT" != *"$SECRET"* ]] && ok "the run's output never shows the password" || fail "password printed: $OUT"
[[ "$OUT" == *"no copy of the password"* ]] && ok "the artefacts are searched and found clean" ||
  fail "no clean verdict: $OUT"
grep -q '^xcrun xcresulttool get test-results activities .*--test-id SmokeUITests/test_IOS_SMOKE_01()$' <<<"$CALLS" &&
  ok "each test's activities are read back" || fail "activities not read: $CALLS"
[ ! -e "$SMOKE/leak-scan" ] && ok "the readable exports are removed afterwards" || fail "leak-scan left behind"
[ ! -e "$TMPROOT/dd" ] && ok "derived data is removed afterwards" || fail "derived data left behind"

echo "== an earlier run's attachments =="
mkdir -p "$SMOKE/attachments" && : >"$SMOKE/attachments/stale-from-another-run.png"
OUT="$(cd "$REPO" && env PATH="$TMPROOT/bin:$PATH" STUB_LOG="$LOG" STUB_TYPED="$TYPED" \
  SMOKE_DERIVED_DATA="$TMPROOT/dd" \
  bash scripts/smoke-simulator.sh --device "iPhone 17 Pro" 2>&1)"
[ ! -e "$SMOKE/attachments/stale-from-another-run.png" ] && ok "an earlier run's attachments are cleared first" ||
  fail "stale attachment kept: $OUT"

echo "== the password in xcodebuild's output =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" \
  STUB_XCODEBUILD_STDOUT="t = 3.10s Type '$SECRET' into \"Password\" SecureTextField"
[ "$RC" -eq 3 ] && ok "a copy in the log fails a green run (exit 3)" || fail "exit $RC: $OUT"
[[ "$GUARD" == *"appears in build/smoke/xcodebuild-smoke.log"* ]] && ok "names the log" || fail "log not named: $GUARD"
[[ "$GUARD" != *"$SECRET"* ]] && ok "the guard's own lines never show the password" || fail "guard printed it: $GUARD"
[ ! -e "$SMOKE/xcodebuild-smoke.log" ] && ok "the log holding it is deleted" || fail "log kept"
[ -d "$SMOKE/smoke.xcresult" ] && ok "a clean result bundle is kept" || fail "clean bundle deleted"

echo "== the password, JSON-escaped, in the result bundle's activities =="
QUOTED='pa/ss"word-123'
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$QUOTED" \
  STUB_ACTIVITY_TITLE="Type 'pa\\/ss\\\"word-123' into \\\"Password\\\""
[ "$RC" -eq 3 ] && ok "an escaped copy in an export fails the run" || fail "exit $RC: $OUT"
[[ "$GUARD" == *"appears in build/smoke/leak-scan"* ]] && ok "names the export" || fail "export not named: $GUARD"
[ ! -e "$SMOKE/smoke.xcresult" ] && ok "the result bundle it came from is deleted" || fail "bundle kept"
[[ "$OUT" != *"word-123"* ]] && ok "no spelling of the password is printed" || fail "printed: $OUT"

echo "== the password in the raw result bundle =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_BUNDLE_TEXT="x${SECRET}x"
[ "$RC" -eq 3 ] && ok "a copy in the bundle fails the run" || fail "exit $RC: $OUT"
[ ! -e "$SMOKE/smoke.xcresult" ] && ok "the bundle is deleted" || fail "bundle kept"

echo "== a result bundle that cannot be read back =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_XCRESULT_FAIL=1
[ "$RC" -eq 4 ] && ok "a green run whose bundle was not searched fails (exit 4)" || fail "exit $RC: $OUT"
[[ "$GUARD" == *"was not searched"* ]] && ok "says the bundle was not searched" || fail "no message: $GUARD"
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_XCRESULT_FAIL=1 \
  STUB_XCODEBUILD_EXIT=65
[ "$RC" -eq 65 ] && ok "and keeps xcodebuild's own failure when there is one" || fail "exit $RC, expected 65"

echo "== a failing run =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD=x STUB_XCODEBUILD_EXIT=65
[ "$RC" -eq 65 ] && ok "passes xcodebuild's failure through" || fail "exit $RC, expected 65"
[[ "$GUARD" == *"shorter than 8 characters"* ]] && ok "says a short password is not searched for" ||
  fail "no short-password warning: $GUARD"

echo "== System Events refuses the keystrokes =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_OSA_FAIL=1 STUB_XCODEBUILD_EXIT=65
[ "$RC" -eq 65 ] && ok "the suite's own failure is the run's" || fail "exit $RC, expected 65"
[[ "$GUARD" == *"System Events could not type into iPhone 17 Pro: grant Accessibility"* ]] && ok "says what to grant" ||
  fail "no FATAL: $GUARD"
[[ "$OUT" != *"$SECRET"* ]] && ok "and never shows the password" || fail "printed: $OUT"

echo "== a suite that never asks =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_NO_MARKER=1 STUB_XCODEBUILD_EXIT=65
[ -z "$(line_of '^osascript ')" ] && ok "nothing is typed without the suite's step" || fail "typed anyway: $CALLS"
[ "$RC" -eq 65 ] && ok "and the watcher does not hold the run open" || fail "exit $RC, expected 65"

echo "== attachments that cannot be exported =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_ATTACH_FAIL=1
[ "$RC" -eq 4 ] && ok "a green run whose attachments were not searched fails (exit 4)" || fail "exit $RC: $OUT"
[[ "$GUARD" == *"attachments could not be exported, so they were not searched"* ]] && ok "says so" ||
  fail "no message: $GUARD"
[[ "$OUT" != *"no copy of the password"* ]] && ok "and gives no all-clear" || fail "all-clear printed: $OUT"
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD="$SECRET" STUB_ATTACH_FAIL=1 STUB_XCODEBUILD_EXIT=65
[ "$RC" -eq 65 ] && ok "a failing run keeps xcodebuild's exit" || fail "exit $RC, expected 65"
[[ "$OUT" != *"no copy of the password"* ]] && ok "and gives no all-clear either" || fail "all-clear printed: $OUT"

echo "== no credentials =="
run
[[ "$OUT" == *"PROVEN NOTHING"* ]] && ok "says a credential-less run proves nothing" || fail "no warning: $OUT"
grep -q '^xcodebuild-env email= byscript= password= bare= plan=Studio$' <<<"$CALLS" &&
  ok "the plan defaults to Studio and no typing is promised" || fail "default env: $CALLS"
[ -z "$(line_of '^osascript ')" ] && ok "nothing is typed" || fail "osascript without a password"

echo
echo "smoke-simulator.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
