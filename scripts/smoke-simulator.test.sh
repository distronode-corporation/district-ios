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
# went: the environment of the test runner, never argv (which xcodebuild echoes into the
# log this script tees, and `ps` shows).
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
STUB
cat >"$TMPROOT/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
echo "xcrun $*" >>"$STUB_LOG"
STUB
cat >"$TMPROOT/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
echo "xcodebuild $*" >>"$STUB_LOG"
echo "xcodebuild-env email=${TEST_RUNNER_DISTRICT_SMOKE_EMAIL:-} password=${TEST_RUNNER_DISTRICT_SMOKE_PASSWORD:-} plan=${TEST_RUNNER_DISTRICT_SMOKE_PLAN:-}" >>"$STUB_LOG"
exit "${STUB_XCODEBUILD_EXIT:-0}"
STUB
chmod +x "$TMPROOT/bin/"*

run() {
  : >"$LOG"
  OUT="$(cd "$REPO" && env PATH="$TMPROOT/bin:$PATH" STUB_LOG="$LOG" \
    SMOKE_DERIVED_DATA="$TMPROOT/dd" "$@" bash scripts/smoke-simulator.sh --device "iPhone 17 Pro" 2>&1)"
  RC=$?
  CALLS="$(cat "$LOG")"
}

echo "== a run with credentials =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD=s3cret-value DISTRICT_SMOKE_PLAN="Voice Pro"
[ "$RC" -eq 0 ] && ok "exits 0 when xcodebuild does" || fail "exit $RC: $OUT"
BUILD="$(grep '^xcodebuild test ' <<<"$CALLS")"
[[ "$BUILD" == *"CODE_SIGN_IDENTITY=-"* ]] && ok "the build is ad-hoc signed" || fail "no CODE_SIGN_IDENTITY=-: $BUILD"
[[ "$BUILD" == *"CODE_SIGNING_ALLOWED=YES"* ]] && ok "signing is allowed" || fail "signing not allowed: $BUILD"
[[ "$BUILD" != *"CODE_SIGNING_ALLOWED=NO"* ]] && ok "never CODE_SIGNING_ALLOWED=NO" || fail "unsigned build: $BUILD"
[[ "$BUILD" != *"DEVELOPMENT_TEAM"* ]] && ok "names no team" || fail "a team on the command line: $BUILD"
[[ "$BUILD" == *"name=iPhone 17 Pro"* ]] && ok "runs on the device asked for" || fail "wrong destination: $BUILD"
[[ "$CALLS" != *"s3cret-value"*"CODE_SIGN"* && "$BUILD" != *"s3cret-value"* ]] &&
  ok "the password is not in xcodebuild's argv" || fail "password in argv: $BUILD"
grep -q '^xcodebuild-env email=qa@example.invalid password=s3cret-value plan=Voice Pro$' <<<"$CALLS" &&
  ok "credentials and plan reach the runner's environment" || fail "runner env: $CALLS"
UNINSTALL_LINE="$(grep -n '^xcrun simctl uninstall iPhone 17 Pro com.distronode.district$' <<<"$CALLS" | cut -d: -f1)"
BUILD_LINE="$(grep -n '^xcodebuild test ' <<<"$CALLS" | cut -d: -f1)"
[ -n "$UNINSTALL_LINE" ] && [ -n "$BUILD_LINE" ] && [ "$UNINSTALL_LINE" -lt "$BUILD_LINE" ] &&
  ok "the app is uninstalled before the run" || fail "no uninstall before xcodebuild: $CALLS"
[ ! -e "$TMPROOT/dd" ] && ok "derived data is removed afterwards" || fail "derived data left behind"

echo "== a failing run =="
run DISTRICT_SMOKE_EMAIL=qa@example.invalid DISTRICT_SMOKE_PASSWORD=x STUB_XCODEBUILD_EXIT=65
[ "$RC" -eq 65 ] && ok "passes xcodebuild's failure through" || fail "exit $RC, expected 65"

echo "== no credentials =="
run
[[ "$OUT" == *"PROVEN NOTHING"* ]] && ok "says a credential-less run proves nothing" || fail "no warning: $OUT"
grep -q '^xcodebuild-env email= password= plan=Studio$' <<<"$CALLS" && ok "the plan defaults to Studio" ||
  fail "default plan: $CALLS"

echo
echo "smoke-simulator.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
