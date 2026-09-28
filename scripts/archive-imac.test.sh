#!/usr/bin/env bash
#
# Harness for archive-imac.sh, driven against stub uname/git/xcodegen/xcodebuild/sentry-cli.
#
#   bash scripts/archive-imac.test.sh
#
# ⛔ THIS IS THE ONLY PLACE THE RELEASE LANE CAN BE TESTED. archive-imac.sh runs
# xcodebuild on a Mac against a real Apple account, so the alternative to this
# file is a change first exercised by an upload to App Store Connect: the real
# thing has no rehearsal.
#
# ⚠️ ASSERTS ON WHAT XCODEBUILD WAS CALLED WITH, not only on exit codes. A script
# that archives the wrong configuration, uploads when it was told not to, or
# quietly signs with the wrong team also exits 0.
#
# ⚠️ NO `set -e`. Half of these cases assert a NON-ZERO exit, and a harness that
# aborts on the first one cannot test a refusal. `set -uo pipefail` gives the
# other two protections; every command whose status matters is read explicitly.
set -uo pipefail

# ── ⛔ HERMETIC, OR THIS FILE TESTS ITS ENVIRONMENT INSTEAD ───────────────────
# `${VAR:-default}` in the script under test substitutes only when a variable is
# unset or empty, so an ambient ASC_KEY_ID, BUILD_DIR or UPLOAD would silently
# become the fixture. Failures would be the lucky half: a leaked ALLOW_DIRTY
# would make the dirty-tree REFUSAL case take the override branch and still
# pass, proving the opposite of what it says.
#
# Cleared by PREFIX (the variable names here will grow), then re-asserted by
# NAME so a newly added one is caught rather than assumed covered.
#
# ⚠️ `SENTRY_` IS THE PREFIX MOST LIKELY TO BE AMBIENT: an operator who has
# just run a real archive has SENTRY_AUTH_TOKEN exported in that shell, and it
# would make the "token unset" case take the upload branch and still pass.
for _leaked in $(env 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' |
  grep -E '^(ASC_|ALLOW_|SENTRY_|BUILD_DIR$|BUILD_NUMBER_OFFSET$|UPLOAD$|STUB_)'); do
  unset "$_leaked"
done

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/archive-imac.sh"
IOS_DIR="$(cd "$HERE/.." && pwd)"
PASS=0
FAIL=0

fail() {
  FAIL=$((FAIL + 1))
  echo "  x $1"
}
ok() {
  PASS=$((PASS + 1))
  echo "  . $1"
}

assert_contains() {
  case "$1" in *"$2"*) ok "$3" ;; *) fail "$3 - expected to find: $2" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) fail "$3 - should NOT contain: $2" ;; *) ok "$3" ;; esac
}
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 - expected '$2', got '$1'"; fi
}
assert_zero() {
  if [ "$1" = "0" ]; then ok "$2"; else fail "$2 - expected exit 0, got $1"; fi
}
assert_nonzero() {
  if [ "$1" != "0" ]; then ok "$2"; else fail "$2 - expected a non-zero exit, got 0"; fi
}

for _name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH \
  ALLOW_DIRTY ALLOW_BRANCH BUILD_DIR BUILD_NUMBER_OFFSET UPLOAD \
  SENTRY_DSN SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_URL; do
  if [ -n "${!_name:-}" ]; then
    fail "environment guard: $_name is still set after the prefix sweep; widen the pattern above"
  fi
done

# What every case's key file holds. ⛔ Obviously not key material, and the point
# of the marker is that it must never appear in the script's output or in any
# recorded argv: the script is handed a PATH to the key and nothing else.
FAKE_KEY_MARKER="STUBFAKEKEYMATERIALNOTAREALKEY"

# ⛔ A SECOND, DIFFERENT FIXTURE, SO THE INTERESTING ASSERTIONS STAY FALSIFIABLE.
# The DSN MUST reach xcodebuild's argv (a build setting is argv) while the .p8
# must NEVER reach it, so the two values have to be distinguishable in the same
# call log.
# ⚠️ Obviously not a real DSN: project 0 on o0.
FAKE_DSN="https://stubdsnpublickey@o0.ingest.de.sentry.io/0"

# The same idea for the Sentry org token: obviously not a credential, and its
# whole job is to be absent from stdout and from every recorded argv.
FAKE_SENTRY_TOKEN="STUBFAKESENTRYTOKENNOTAREALTOKEN"
STUB_SENTRY_ORG="stub-org-eu"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

CASE_N=0
STUB_DIR=""
REAL_BIN=""
# ⛔ A DIRECTORY OF ITS OWN, DELIBERATELY OFF THE DEFAULT PATH. sentry-cli being
# ABSENT is the normal state of a release host and the default every case
# should see; only the cases that test the upload put this directory on PATH.
# Dropping the stub into $STUB_DIR would make "sentry-cli is missing" untestable.
SENTRYCLI_DIR=""
CALLS=""
RUN_HOME=""
RUN_PATH=""
RUN_SCRIPT=""
KEY_FILE=""
OUT=""
RC=0

KEY_ID="STUBKEYID9Z"
ISSUER="11111111-2222-3333-4444-555555555555"

# Builds a throwaway world: stub tools that record their argv, a HOME of its own
# so ~/private_keys is never the real one, and symlinks to the handful of real
# binaries the script needs.
#
# ⛔ THE PATH HOLDS NOTHING ELSE. Not /usr/bin, not /bin: a real xcodebuild,
# xcodegen or sentry-cli on the host would otherwise be found by any case whose
# stub failed to shadow it, and the case that asserts sentry-cli is MISSING
# would find the real one and take the upload branch.
#
# ⚠️ `strings` AND `grep` ARE REAL, NOT STUBBED, because together they ARE the
# seam guard: a stub would make the IOS-SEC-01 check pass by construction.
# Without them on this PATH every archive case dies at that guard with
# `command not found`.
#
# ⚠️ THE KEY IS PLACED BY DEFAULT, because the script refuses to run without one
# and a release host always has it. The case that tests its absence removes it.
new_case() {
  CASE_N=$((CASE_N + 1))
  STUB_DIR="$TMPROOT/case$CASE_N"
  REAL_BIN="$STUB_DIR/realbin"
  SENTRYCLI_DIR="$STUB_DIR/sentrycli"
  RUN_HOME="$STUB_DIR/home"
  CALLS="$STUB_DIR/calls.log"
  RUN_SCRIPT="$SCRIPT"
  KEY_FILE="$RUN_HOME/private_keys/AuthKey_$KEY_ID.p8"
  mkdir -p "$STUB_DIR" "$REAL_BIN" "$SENTRYCLI_DIR" "$RUN_HOME/private_keys"
  : >"$CALLS"

  local real real_path
  for real in dirname mkdir chmod rm strings grep; do
    real_path="$(command -v "$real" || true)"
    if [ -z "$real_path" ]; then
      fail "harness: '$real' is not on PATH, and the script under test needs it"
      continue
    fi
    ln -s "$real_path" "$REAL_BIN/$real"
  done

  {
    echo "-----BEGIN PRIVATE KEY-----" # gitleaks:allow
    echo "$FAKE_KEY_MARKER"
    echo "-----END PRIVATE KEY-----"
  } >"$KEY_FILE"
  chmod 600 "$KEY_FILE"

  cat >"$STUB_DIR/uname" <<'STUB'
#!/bin/sh
echo "uname $*" >> "$CALLS_FILE"
echo "${STUB_UNAME:-Darwin}"
STUB

  # A dirty tree, the branch and the commit count are all this script asks git.
  # Anything else is a bug in the script, so the stub says so loudly rather than
  # answering plausibly.
  cat >"$STUB_DIR/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$CALLS_FILE"
case "$1" in
  status)   [ -n "${STUB_GIT_DIRTY:-}" ] && echo " M project.yml"; exit 0 ;;
  branch)   echo "${STUB_GIT_BRANCH:-main}"; exit 0 ;;
  rev-list) echo "${STUB_GIT_COUNT:-4211}"; exit 0 ;;
esac
echo "stub git: unhandled invocation: $*" >&2
exit 2
STUB

  # Logs the working directory too: -project and -exportOptionsPlist are passed
  # relative, so the script being at the repository root is load-bearing and
  # otherwise untested.
  cat >"$STUB_DIR/xcodegen" <<'STUB'
#!/bin/sh
echo "xcodegen $*" >> "$CALLS_FILE"
echo "cwd $PWD" >> "$CALLS_FILE"
STUB

  # ⛔ A SUCCESSFUL ARCHIVE LEAVES AN APP BINARY, because the seam guard reads it.
  # The stand-in is clean by default and carries the seam's literal when
  # STUB_ARCHIVE_SEAM is set, so both verdicts of the guard are exercised
  # against the real `strings` and `grep`.
  cat >"$STUB_DIR/xcodebuild" <<'STUB'
#!/bin/sh
echo "xcodebuild $*" >> "$CALLS_FILE"
case " $* " in
  *" -exportArchive "*) PHASE=export ;;
  *) PHASE=archive ;;
esac
if [ "${STUB_XCODEBUILD_FAIL:-}" = "$PHASE" ]; then
  echo "stub xcodebuild: $PHASE failed" >&2
  exit 65
fi
if [ "$PHASE" = archive ]; then
  archive=""
  while [ $# -gt 0 ]; do
    [ "$1" = "-archivePath" ] && archive="$2"
    shift
  done
  app="$archive/Products/Applications/DistrictAI.app"
  mkdir -p "$app" "$archive/dSYMs"
  if [ -n "${STUB_ARCHIVE_NO_BINARY:-}" ]; then
    : # an archive with no app binary, for the seam check's own precondition
  elif [ -n "${STUB_ARCHIVE_SEAM:-}" ]; then
    printf 'stub release binary\nDISTRICT_UITEST_SESSION\n' >"$app/DistrictAI"
  else
    printf 'stub release binary\n' >"$app/DistrictAI"
  fi
fi
exit 0
STUB

  # ⛔ RECORDS ITS ENVIRONMENT, NOT ONLY ITS ARGV, because the two facts that
  # matter about this call are both environmental: SENTRY_URL has to say
  # de.sentry.io (a US-pointed upload succeeds and does nothing) and the token
  # has to arrive through the environment rather than argv. The token's VALUE is
  # never written here — only whether one was present — so the log the harness
  # greps cannot itself become the leak it is testing for.
  cat >"$SENTRYCLI_DIR/sentry-cli" <<'STUB'
#!/bin/sh
echo "sentry-cli $*" >> "$CALLS_FILE"
echo "sentry-cli env SENTRY_URL=${SENTRY_URL:-unset}" >> "$CALLS_FILE"
if [ -n "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "sentry-cli env SENTRY_AUTH_TOKEN_PRESENT=yes" >> "$CALLS_FILE"
else
  echo "sentry-cli env SENTRY_AUTH_TOKEN_PRESENT=no" >> "$CALLS_FILE"
fi
if [ -n "${STUB_SENTRYCLI_FAIL:-}" ]; then
  echo "stub sentry-cli: upload failed" >&2
  exit 1
fi
STUB

  chmod +x "$STUB_DIR"/uname "$STUB_DIR"/git \
    "$STUB_DIR"/xcodegen "$STUB_DIR"/xcodebuild "$SENTRYCLI_DIR"/sentry-cli

  RUN_PATH="$STUB_DIR:$REAL_BIN"
}

# ⛔ ABSOLUTE, BECAUSE `env -i PATH=<stubs> bash …` LOOKS UP `bash` IN THE NEW
# PATH. The stub PATH holds no shell, so a bare `bash` there exits 127 before the
# script runs a line, and 127 is non-zero, so every refusal case PASSES while
# proving nothing: every assertion can go green against a script that never
# executed. The 127 check in `run_archive` below is the guard.
BASH_BIN="$(command -v bash)"

# Runs the script with a scrubbed environment. `env -i` rather than a subshell
# export list: it is the only way to be sure nothing the harness inherited
# reaches the script.
run_archive() {
  OUT="$(env -i \
    PATH="$RUN_PATH" \
    HOME="$RUN_HOME" \
    CALLS_FILE="$CALLS" \
    "$@" \
    "$BASH_BIN" "$RUN_SCRIPT" 2>&1)"
  RC=$?
  # 127 means the shell, the script or a tool it calls was never found. Nothing
  # below can be trusted after that, so say it once, loudly, per run.
  if [ "$RC" = "127" ]; then
    fail "case $CASE_N: exit 127 - something was never found (command not found): $OUT"
  fi
}

calls() { cat "$CALLS"; }
line_for() { grep -m1 -- "$1" "$CALLS" 2>/dev/null || true; }
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%A' "$1"; }
# How many lines of $1 contain $2.
line_count() { printf '%s\n' "$1" | grep -c -- "$2"; }

echo "archive-imac.sh"

# ── 1. Not a Mac ─────────────────────────────────────────────────────────────
echo "1. refuses on a non-Darwin host"
new_case
run_archive STUB_UNAME=Linux ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"
assert_nonzero "$RC" "exits non-zero on Linux"
assert_contains "$OUT" "Darwin" "the message names Darwin"
assert_contains "$OUT" "'Linux'" "the message names the host it actually found"
assert_not_contains "$(calls)" "xcodebuild" "nothing is built on the wrong host"
assert_not_contains "$(calls)" "git " "the tree is not even inspected on the wrong host"

# ── 2. Dirty working tree ────────────────────────────────────────────────────
echo "2. refuses a dirty working tree, and ALLOW_DIRTY=1 overrides"
new_case
run_archive STUB_GIT_DIRTY=1 ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"
assert_nonzero "$RC" "exits non-zero with uncommitted changes"
assert_contains "$OUT" "ALLOW_DIRTY=1" "the message names the override"
assert_not_contains "$(calls)" "xcodebuild" "no archive from a dirty tree"

new_case
run_archive STUB_GIT_DIRTY=1 ALLOW_DIRTY=1 ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" \
  BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "ALLOW_DIRTY=1 proceeds"
assert_contains "$(calls)" "xcodebuild archive " "ALLOW_DIRTY=1 reaches the archive"

# ── 3. Branch ────────────────────────────────────────────────────────────────
echo "3. refuses a branch other than main, and ALLOW_BRANCH=1 overrides"
new_case
run_archive STUB_GIT_BRANCH="feature/scratch" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"
assert_nonzero "$RC" "exits non-zero off main"
assert_contains "$OUT" "feature/scratch" "the message names the branch it found"
assert_contains "$OUT" "ALLOW_BRANCH=1" "the message names the override"
assert_not_contains "$(calls)" "xcodebuild" "no archive off main"

new_case
run_archive STUB_GIT_BRANCH="feature/scratch" ALLOW_BRANCH=1 ASC_KEY_ID="$KEY_ID" \
  ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "ALLOW_BRANCH=1 proceeds"
assert_contains "$(calls)" "xcodebuild archive " "ALLOW_BRANCH=1 reaches the archive"

# ── 4. The key file ──────────────────────────────────────────────────────────
echo "4. uses the .p8 at Apple's fixed path, and never prints it or passes its contents"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "a clean run succeeds"
assert_contains "$(line_for 'xcodebuild archive ')" "-authenticationKeyPath $KEY_FILE" \
  "the archive is handed ~/private_keys/AuthKey_<KEY_ID>.p8, Apple's fixed lookup path"
assert_contains "$OUT" "$KEY_FILE" "it names the key file it used"
# ⛔ The whole reason the marker exists. A key echoed into a terminal is a key in
# scrollback, in a screen share and in whatever captures this script's output.
assert_not_contains "$OUT" "$FAKE_KEY_MARKER" "the key contents never reach stdout or stderr"
assert_not_contains "$OUT" "BEGIN PRIVATE KEY" "not even the PEM header is echoed"
# ⛔ And never as an argument either: argv is world-readable through `ps`.
assert_not_contains "$(calls)" "$FAKE_KEY_MARKER" "the key contents are never passed as an argument"

echo "5. never rewrites a .p8 that is already there"
new_case
echo "PREEXISTINGSTUBKEY" >"$KEY_FILE"
chmod 600 "$KEY_FILE"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "an existing key is accepted"
assert_eq "$(cat "$KEY_FILE")" "PREEXISTINGSTUBKEY" "the existing key is left byte-identical"
assert_eq "$(file_mode "$KEY_FILE")" "600" "and its mode is left at 0600"

echo "6. fails with one instruction naming the path when the key is absent"
new_case
rm -f "$KEY_FILE"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_nonzero "$RC" "exits non-zero with no key"
assert_contains "$OUT" "$KEY_FILE" "the message names the exact path it looked at"
assert_contains "$OUT" "0600" "the message names the mode it expects"
assert_eq "$(line_count "$OUT" .)" "1" "the refusal is one line"
assert_not_contains "$(calls)" "xcodebuild" "nothing is built without a signing key"
# ⛔ A REFUSAL, NOT A REPAIR. Anything written here would be a key the operator
# did not put there, and the next run would find and use it.
if [ -e "$KEY_FILE" ]; then
  fail "nothing is created at the key path"
else
  ok "nothing is created at the key path"
fi

echo "7. refuses an unset ASC_KEY_ID or ASC_ISSUER_ID, naming the one that is missing"
# ⛔ BOTH ARE REQUIRED AND NEITHER HAS A DEFAULT. The key is pre-placed, so the
# only thing either run can be missing is the identifier the case leaves out.
new_case
run_archive ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_nonzero "$RC" "7a: an unset ASC_KEY_ID is fatal"
assert_contains "$OUT" "ASC_KEY_ID is unset" "7a: the message names ASC_KEY_ID"
assert_contains "$OUT" "Both ASC_KEY_ID and ASC_ISSUER_ID are required" "7a: it says both are needed"
assert_not_contains "$(calls)" "xcodebuild" "7a: nothing is built"
new_case
run_archive ASC_KEY_ID="$KEY_ID" BUILD_DIR="$STUB_DIR/out"
assert_nonzero "$RC" "7b: an unset ASC_ISSUER_ID is fatal"
assert_contains "$OUT" "ASC_ISSUER_ID is unset" "7b: the message names ASC_ISSUER_ID"
assert_contains "$OUT" "Both ASC_KEY_ID and ASC_ISSUER_ID are required" "7b: it says both are needed"
assert_not_contains "$(calls)" "xcodebuild" "7b: nothing is built"

# ── 7c/7d. ASC_KEY_PATH ──────────────────────────────────────────────────────
# ⛔ THE RELEASE WORKFLOW'S ROUTE. A CI runner writes the key under its own
# temporary directory, not under ~/private_keys, so the override has to reach
# BOTH xcodebuild calls, and a missing override file has to be refused by its own
# path rather than silently falling back to the home-directory default.
echo "7c. ASC_KEY_PATH moves the key, and both xcodebuild calls are handed it"
new_case
rm -f "$KEY_FILE"
ALT_KEY="$STUB_DIR/runner-temp/AuthKey_$KEY_ID.p8"
mkdir -p "$(dirname "$ALT_KEY")"
{
  echo "-----BEGIN PRIVATE KEY-----" # gitleaks:allow
  echo "$FAKE_KEY_MARKER"
  echo "-----END PRIVATE KEY-----"
} >"$ALT_KEY"
chmod 600 "$ALT_KEY"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" ASC_KEY_PATH="$ALT_KEY" \
  BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "7c: a key at ASC_KEY_PATH is accepted with none at the default path"
assert_contains "$(line_for 'xcodebuild archive ')" "-authenticationKeyPath $ALT_KEY " \
  "7c: the archive is handed the ASC_KEY_PATH key"
assert_contains "$(line_for 'xcodebuild -exportArchive ')" "-authenticationKeyPath $ALT_KEY " \
  "7c: the export is handed the ASC_KEY_PATH key"
assert_not_contains "$OUT" "$FAKE_KEY_MARKER" "7c: the key contents never reach stdout or stderr"
assert_not_contains "$(calls)" "$FAKE_KEY_MARKER" "7c: the key contents are never passed as an argument"

echo "7d. a missing ASC_KEY_PATH is refused by its own path, with no fallback"
new_case
# The default-path key IS present here, so a fallback would pass; it must not.
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" \
  ASC_KEY_PATH="$STUB_DIR/nowhere/AuthKey_$KEY_ID.p8" BUILD_DIR="$STUB_DIR/out"
assert_nonzero "$RC" "7d: exits non-zero when ASC_KEY_PATH names no file"
assert_contains "$OUT" "$STUB_DIR/nowhere/AuthKey_$KEY_ID.p8" "7d: the message names the override path"
assert_not_contains "$(calls)" "xcodebuild" "7d: nothing is built"

# ── 8. The archive command ───────────────────────────────────────────────────
# ⛔ EXACT, NOT `contains`. Every flag here is load-bearing and a missing one
# fails LATE: the wrong -configuration ships a Debug build, a missing
# -allowProvisioningUpdates fails only once cloud signing has to mint the
# certificate, and a lost CURRENT_PROJECT_VERSION uploads a build number App
# Store Connect has already seen.
echo "8. archives with exactly the expected argv"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" STUB_GIT_COUNT=777 \
  SENTRY_DSN="$FAKE_DSN" BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "the archive run succeeds"
EXPECTED_ARCHIVE="xcodebuild archive"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -project DistrictAI.xcodeproj"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -scheme DistrictAI"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -configuration Release"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -destination generic/platform=iOS"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -archivePath $STUB_DIR/out/DistrictAI.xcarchive"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -allowProvisioningUpdates"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -authenticationKeyPath $KEY_FILE"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -authenticationKeyID $KEY_ID"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE -authenticationKeyIssuerID $ISSUER"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE DEVELOPMENT_TEAM=R935BA6767"
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE CODE_SIGN_STYLE=Automatic"
# ⛔ THE COMMIT COUNT PLUS THE DEFAULT OFFSET OF 4101. The stub answers 777.
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE CURRENT_PROJECT_VERSION=4878"
# ⛔ PRESENT AND POPULATED, as on a release host that exports SENTRY_DSN. The
# EMPTY case is what disables Sentry entirely; case 16 holds it.
EXPECTED_ARCHIVE="$EXPECTED_ARCHIVE SENTRY_DSN=$FAKE_DSN"
assert_eq "$(line_for 'xcodebuild archive ')" "$EXPECTED_ARCHIVE" "the archive argv is exact"
assert_contains "$(calls)" "xcodegen generate --spec project.yml" "the project is generated first"
assert_contains "$(calls)" "cwd $IOS_DIR" "it runs from the repository root, which the relative paths need"
assert_contains "$(calls)" "git rev-list --count HEAD" "the build number comes from the commit count"
assert_contains "$OUT" "build number: 4878" "it prints the build number"
assert_contains "$OUT" "archive: $STUB_DIR/out/DistrictAI.xcarchive" "it prints the archive path"
assert_contains "$OUT" "IOS-SEC-01 ok" "the seam guard ran and passed a clean binary"

# ── 9. The export command ────────────────────────────────────────────────────
echo "9. exports with exactly the expected argv"
EXPECTED_EXPORT="xcodebuild -exportArchive"
EXPECTED_EXPORT="$EXPECTED_EXPORT -archivePath $STUB_DIR/out/DistrictAI.xcarchive"
EXPECTED_EXPORT="$EXPECTED_EXPORT -exportOptionsPlist ExportOptions.plist"
EXPECTED_EXPORT="$EXPECTED_EXPORT -exportPath $STUB_DIR/out/export"
EXPECTED_EXPORT="$EXPECTED_EXPORT -allowProvisioningUpdates"
EXPECTED_EXPORT="$EXPECTED_EXPORT -authenticationKeyPath $KEY_FILE"
EXPECTED_EXPORT="$EXPECTED_EXPORT -authenticationKeyID $KEY_ID"
EXPECTED_EXPORT="$EXPECTED_EXPORT -authenticationKeyIssuerID $ISSUER"
assert_eq "$(line_for 'xcodebuild -exportArchive ')" "$EXPECTED_EXPORT" "the export argv is exact"

# ── 10. The build number offset ──────────────────────────────────────────────
# ⚠️ THE OFFSET IS WHAT KEEPS A FRESH HISTORY ABOVE THE NUMBERS ALREADY UPLOADED,
# and a fork needs its own floor. The override has to reach the build setting,
# not only the printed line.
echo "10. BUILD_NUMBER_OFFSET replaces the default offset"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" STUB_GIT_COUNT=777 \
  BUILD_NUMBER_OFFSET=10 BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "a run with an offset succeeds"
assert_contains "$(line_for 'xcodebuild archive ')" "CURRENT_PROJECT_VERSION=787 " \
  "the build number is the count plus the override"
assert_contains "$OUT" "build number: 787" "it prints the overridden build number"

# ── 11. UPLOAD=0 ─────────────────────────────────────────────────────────────
echo "11. UPLOAD=0 stops after the archive"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" UPLOAD=0 BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "UPLOAD=0 still succeeds"
assert_contains "$(calls)" "xcodebuild archive " "UPLOAD=0 still archives"
assert_not_contains "$(calls)" "-exportArchive" "UPLOAD=0 uploads nothing"
assert_contains "$OUT" "Nothing was sent to App Store Connect" "it says nothing was uploaded"

# ── 12. Failure propagation ──────────────────────────────────────────────────
echo "12. a failing xcodebuild propagates non-zero"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_XCODEBUILD_FAIL=archive
assert_nonzero "$RC" "a failed archive fails the script"
assert_not_contains "$(calls)" "-exportArchive" "a failed archive is never exported"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_XCODEBUILD_FAIL=export
assert_nonzero "$RC" "a failed export fails the script"

# ── 13. IOS-SEC-01: the UI-test seam in a release binary ─────────────────────
# ⛔ THE GUARD HAS TO BE SEEN TO FIRE. Every other case proves it passes a clean
# binary, which a guard that never matches would do too.
echo "13. refuses, and deletes, an archive whose binary contains the UI-test seam"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_SEAM=1
assert_nonzero "$RC" "a binary carrying DISTRICT_UITEST fails the script"
assert_contains "$OUT" "UI-test seam is present" "the message names the seam"
assert_contains "$OUT" "has been DELETED" "the message says the archive is gone"
if [ -e "$STUB_DIR/out/DistrictAI.xcarchive" ]; then
  fail "the archive is deleted"
else
  ok "the archive is deleted"
fi
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported"
assert_not_contains "$OUT" "IOS-SEC-01 ok" "the guard does not also report success"

# ⛔ AND IT MUST NOT PASS VACUOUSLY. `strings` on a missing file fails and the
# count reads as 0, which looks exactly like a clean binary; an archive with no
# binary to inspect has to be refused, not reported as seam-free.
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_NO_BINARY=1
assert_nonzero "$RC" "an archive with no app binary fails the script"
assert_contains "$OUT" "no app binary at" "the message says what is missing"
assert_not_contains "$OUT" "IOS-SEC-01 ok" "the seam check does not report a clean binary"
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported without a binary"

# ── 14. The default build directory ──────────────────────────────────────────
# ⛔ RUN FROM A COPY OF THE SCRIPT IN A THROWAWAY TREE, because the default is
# relative to the script and the stub xcodebuild WRITES an app binary into the
# archive it is given. Run in place, a developer's own DerivedData/release
# archive would have its binary replaced by the stub's.
echo "14. BUILD_DIR defaults to DerivedData/release at the repository root"
new_case
mkdir -p "$STUB_DIR/tree/scripts"
cp "$SCRIPT" "$STUB_DIR/tree/scripts/archive-imac.sh"
RUN_SCRIPT="$STUB_DIR/tree/scripts/archive-imac.sh"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER"
assert_zero "$RC" "the default build directory works"
assert_contains "$(line_for 'xcodebuild archive ')" \
  "-archivePath $STUB_DIR/tree/DerivedData/release/DistrictAI.xcarchive" \
  "the default archive path is under DerivedData/, which .gitignore covers"

# ── 15. The Sentry DSN ───────────────────────────────────────────────────────
# ⛔ THE ONLY ROUTE A DSN HAS INTO THE BUNDLE. project.yml declares
# `SENTRY_DSN: ""` and maps it into Info.plist as DistrictSentryDSN; this
# command line is where a real one is substituted, at archive time and nowhere
# else. A DSN in a source file would ship in every Debug build besides.
echo "15. forwards SENTRY_DSN to the archive as a build setting, and never prints it"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_DSN="$FAKE_DSN"
assert_zero "$RC" "a run with a DSN succeeds"
assert_contains "$(line_for 'xcodebuild archive ')" "SENTRY_DSN=$FAKE_DSN" \
  "the DSN reaches the archive as a build setting"
assert_contains "$OUT" "Using SENTRY_DSN from the environment" "it says which DSN it used"
# ⛔ The value goes to xcodebuild and nowhere a log, a screen share or a
# scrollback can keep it.
assert_not_contains "$OUT" "$FAKE_DSN" "the DSN value never reaches stdout or stderr"
# ⛔ AND NOT THE OTHER WAY ROUND EITHER: the .p8 is not what landed in SENTRY_DSN.
assert_not_contains "$(line_for 'xcodebuild archive ')" "$FAKE_KEY_MARKER" \
  "the .p8 contents are not in the archive argv"

# ── 16. No DSN: Sentry disabled, build continues ─────────────────────────────
# ⛔ NOT FATAL, BY DECISION. A signed scratch build with no crash reporting is
# still worth having; the alternative to continuing is somebody commenting the
# check out. ⚠️ But the absence gets a SENTENCE, like both dSYM skips, because a
# build that reports nothing looks exactly like a build that has no crashes.
echo "16. continues with Sentry disabled when SENTRY_DSN is unset, and says so in one line"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "a missing DSN does not fail the archive"
assert_contains "$OUT" "SENTRY_DSN is unset" "it names the variable that was missing"
assert_contains "$OUT" "SENTRY IS DISABLED IN THIS BUILD" "it says Sentry is off in this build"
# ⛔ The notice must say NOTHING is reported, not that symbols are missing: a blank
# DSN returns before SentrySDK.start, so no handler is installed at all.
assert_contains "$OUT" "no crash or app hang is reported" "it says nothing is reported at all"
assert_eq "$(line_count "$OUT" 'SENTRY_DSN')" "1" "the notice is one line"
assert_contains "$(line_for 'xcodebuild archive ')" "CURRENT_PROJECT_VERSION=8312 SENTRY_DSN=" \
  "SENTRY_DSN is still passed, as the last element"
assert_not_contains "$(line_for 'xcodebuild archive ')" "SENTRY_DSN=http" \
  "and it is empty, which is what disables the SDK"

# ── 17. dSYM upload, skipped ─────────────────────────────────────────────────
# ⚠️ SKIPPED IS THE NORMAL CASE and it has to SAY so. An upload that quietly does
# not happen is discovered weeks later, by an unsymbolicated crash report.
echo "17. skips the dSYM upload when SENTRY_AUTH_TOKEN is unset, and says so"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out"
assert_zero "$RC" "no token is not an error"
assert_contains "$OUT" "SENTRY_AUTH_TOKEN is unset" "it names the variable that was missing"
assert_contains "$OUT" "skipped the dSYM upload" "it says the upload was skipped"
assert_not_contains "$(calls)" "sentry-cli" "nothing is uploaded without a token"

echo "18. skips the upload when the token is set but sentry-cli is missing"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG"
assert_zero "$RC" "a missing sentry-cli does not fail the archive"
assert_contains "$OUT" "sentry-cli is not on PATH" "it names what is missing"
assert_contains "$OUT" "brew install" "it says how to fix it"
# ⛔ The token is in the environment of this very run, so this is the assertion
# that proves the diagnostic does not echo what it was handed.
assert_not_contains "$OUT" "$FAKE_SENTRY_TOKEN" "the token is not printed on the skip path"

# ── 19. dSYM upload, performed ───────────────────────────────────────────────
echo "19. uploads dSYMs with exactly the expected argv, against the EU API host"
new_case
RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG"
assert_zero "$RC" "the upload run succeeds"
EXPECTED_SENTRY="sentry-cli debug-files upload"
EXPECTED_SENTRY="$EXPECTED_SENTRY --org $STUB_SENTRY_ORG"
EXPECTED_SENTRY="$EXPECTED_SENTRY --project district-ios"
EXPECTED_SENTRY="$EXPECTED_SENTRY $STUB_DIR/out/DistrictAI.xcarchive/dSYMs"
assert_eq "$(line_for 'sentry-cli debug-files ')" "$EXPECTED_SENTRY" "the sentry-cli argv is exact"
# ⛔ THE ASSERTION THIS CASE EXISTS FOR. sentry-cli defaults to the US control
# silo, where an EU org does not exist, and a mis-pointed upload SUCCEEDS while
# uploading nothing.
assert_contains "$(calls)" "sentry-cli env SENTRY_URL=https://de.sentry.io" \
  "SENTRY_URL points sentry-cli at the EU API host"
assert_contains "$(calls)" "sentry-cli env SENTRY_AUTH_TOKEN_PRESENT=yes" \
  "the token reaches sentry-cli through its environment"
# ⛔ And never on argv (world-readable through `ps`) or in the output.
assert_not_contains "$(calls)" "$FAKE_SENTRY_TOKEN" "the token is never passed as an argument"
assert_not_contains "$OUT" "$FAKE_SENTRY_TOKEN" "the token never reaches stdout or stderr"

echo "20. refuses when the token is set and SENTRY_ORG is not, and fails a failed upload"
new_case
RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN"
assert_nonzero "$RC" "exits non-zero with a token and no org"
assert_contains "$OUT" "SENTRY_ORG" "the message names SENTRY_ORG"
assert_not_contains "$(calls)" "sentry-cli debug-files" "no upload is attempted without an org"
assert_not_contains "$OUT" "$FAKE_SENTRY_TOKEN" "the refusal does not print the token"

new_case
RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG" \
  STUB_SENTRYCLI_FAIL=1
# ⚠️ LOUD RATHER THAN TOLERATED. An upload that was ATTEMPTED and failed is a
# different thing from one that was deliberately skipped: the archive would go to
# TestFlight with no symbols and nothing would say so.
assert_nonzero "$RC" "a failed upload fails the script"
assert_not_contains "$(calls)" "-exportArchive" "a failed upload is never exported past"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
