#!/usr/bin/env bash
#
# Harness for archive-imac.sh, driven against stub uname/git/xcodegen/xcodebuild/plutil/sentry-cli.
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
  grep -E '^(ASC_|ALLOW_|SENTRY_|BUILD_DIR$|BUILD_NUMBER_OFFSET$|UPLOAD$|STUB_|DISTRICT_FRENCH$)'); do
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

  # A dirty tree, the branch, the commit count and HEAD's sha are all this script asks git.
  # Anything else is a bug in the script, so the stub says so loudly rather than
  # answering plausibly.
  cat >"$STUB_DIR/git" <<'STUB'
#!/bin/sh
echo "git $*" >> "$CALLS_FILE"
case "$1" in
  status)   [ -n "${STUB_GIT_DIRTY:-}" ] && echo " M project.yml"; exit 0 ;;
  branch)   echo "${STUB_GIT_BRANCH:-main}"; exit 0 ;;
  rev-list) echo "${STUB_GIT_COUNT:-4211}"; exit 0 ;;
  rev-parse) [ "$2" = HEAD ] && echo "${STUB_GIT_SHA:-0123456789abcdef0123456789abcdef01234567}" && exit 0 ;;
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
  #
  # ⚠️ NO WATCH APP UNLESS ASKED: today's archive. STUB_ARCHIVE_WATCH=1 adds the
  # layout the Apple Watch companion ships as, DistrictAI.app/Watch/DistrictAIWatch.app
  # with DistrictAIWatch.app/PlugIns/DistrictAIWatchComplications.appex, each with its
  # own Info.plist (carrying the iOS app's versions unless overridden), main executable
  # and localizations. STUB_ARCHIVE_IOS_APPEX=1 adds an extension to the iOS app's own
  # PlugIns/, and STUB_ARCHIVE_EXTRA_APP a second top-level .app.
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
# The localizations a bundle would hold: $2 is a space-separated list of paths inside
# bundle $1. A path ending in .strings is a table, written with its folder
# (fr-CA.lproj/Localizable.strings); anything else is a folder (fr.lproj,
# Frameworks/Vendor.framework/fr.lproj).
make_lproj() {
  for lproj in $2; do
    case "$lproj" in
      *.strings)
        mkdir -p "$1/${lproj%/*}"
        : >"$1/$lproj"
        ;;
      *) mkdir -p "$1/$lproj" ;;
    esac
  done
}
# A nested bundle: $1 its folder, $2 its executable's name (empty: no
# CFBundleExecutable key), $3 short version, $4 build, $5 non-empty for the seam.
make_nested() {
  mkdir -p "$1"
  {
    echo "CFBundleIdentifier=com.distronode.district.${1##*/}"
    [ -n "$2" ] && echo "CFBundleExecutable=$2"
    echo "CFBundleShortVersionString=$3"
    echo "CFBundleVersion=$4"
  } >"$1/Info.plist"
  name="${2:-${1##*/}}"
  name="${name%.*}"
  if [ -n "$5" ]; then
    printf 'stub nested binary\nDISTRICT_UITEST_SESSION\n' >"$1/$name"
  else
    printf 'stub nested binary\n' >"$1/$name"
  fi
}
if [ "$PHASE" = archive ]; then
  archive=""
  build=""
  while [ $# -gt 0 ]; do
    [ "$1" = "-archivePath" ] && archive="$2"
    case "$1" in CURRENT_PROJECT_VERSION=*) build="${1#*=}" ;; esac
    shift
  done
  short="${STUB_SHORT_VERSION:-3.0.2}"
  app="$archive/Products/Applications/DistrictAI.app"
  mkdir -p "$app" "$archive/dSYMs"
  # The bundle's Info.plist, as the stub plutil reads it: key=value lines. The build
  # number is the one the archive was handed, as project.yml makes it on a real one.
  if [ -z "${STUB_ARCHIVE_NO_PLIST:-}" ]; then
    {
      echo "CFBundleIdentifier=com.distronode.district"
      echo "CFBundleExecutable=DistrictAI"
      echo "CFBundleShortVersionString=$short"
      echo "CFBundleVersion=$build"
    } >"$app/Info.plist"
  fi
  if [ -n "${STUB_ARCHIVE_NO_BINARY:-}" ]; then
    : # an archive with no app binary, for the seam check's own precondition
  elif [ -n "${STUB_ARCHIVE_SEAM:-}" ]; then
    printf 'stub release binary\nDISTRICT_UITEST_SESSION\n' >"$app/DistrictAI"
  else
    printf 'stub release binary\n' >"$app/DistrictAI"
  fi
  make_lproj "$app" "${STUB_ARCHIVE_LPROJ:-}"
  if [ -n "${STUB_ARCHIVE_WATCH:-}" ]; then
    watch="$app/Watch/DistrictAIWatch.app"
    make_nested "$watch" DistrictAIWatch \
      "${STUB_WATCH_SHORT_VERSION:-$short}" "${STUB_WATCH_BUILD:-$build}" "${STUB_WATCH_SEAM:-}"
    make_lproj "$watch" "${STUB_WATCH_LPROJ:-}"
    appex="$watch/PlugIns/DistrictAIWatchComplications.appex"
    appex_exe=DistrictAIWatchComplications
    [ -n "${STUB_APPEX_NO_EXECUTABLE:-}" ] && appex_exe=""
    make_nested "$appex" "$appex_exe" \
      "${STUB_APPEX_SHORT_VERSION:-$short}" "${STUB_APPEX_BUILD:-$build}" "${STUB_APPEX_SEAM:-}"
    make_lproj "$appex" "${STUB_APPEX_LPROJ:-}"
  fi
  if [ -n "${STUB_ARCHIVE_IOS_APPEX:-}" ]; then
    make_nested "$app/PlugIns/DistrictAIWidgets.appex" DistrictAIWidgets \
      "$short" "${STUB_IOS_APPEX_BUILD:-$build}" ""
  fi
  if [ -n "${STUB_ARCHIVE_EXTRA_APP:-}" ]; then
    mkdir -p "$archive/Products/Applications/$STUB_ARCHIVE_EXTRA_APP"
  fi
fi
exit 0
STUB

  # Answers `plutil -extract <key> raw -o - <file>` from the stub Info.plist above, and
  # nothing else: any other shape is a bug in the script, so it fails loudly.
  cat >"$STUB_DIR/plutil" <<'STUB'
#!/bin/sh
echo "plutil $*" >> "$CALLS_FILE"
if [ "$#" != 6 ] || [ "$1" != -extract ] || [ "$3" != raw ] || [ "$4" != -o ] || [ "$5" != - ]; then
  echo "stub plutil: unhandled invocation: $*" >&2
  exit 2
fi
[ -f "$6" ] || { echo "stub plutil: no file $6" >&2; exit 1; }
# Shell builtins only: the stub PATH has no sed.
while IFS='=' read -r key value; do
  [ "$key" = "$2" ] && { echo "$value"; exit 0; }
done <"$6"
echo "stub plutil: no key $2" >&2
exit 1
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
if [ "$1 $2" = "releases ${STUB_SENTRYCLI_FAIL_RELEASES:-none}" ]; then
  echo "stub sentry-cli: releases $2 failed" >&2
  exit 1
fi
STUB

  chmod +x "$STUB_DIR"/uname "$STUB_DIR"/git "$STUB_DIR"/plutil \
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

# ── 13b. French stays out until it is switched on ────────────────────────────
# ⛔ SEEN TO FIRE, AND SEEN TO STAND ASIDE. An English release with a French table is
# refused and deleted; the same bundle with DISTRICT_FRENCH on goes through only when
# fr-CA.lproj holds both tables; any other French .lproj at the app's top level (any
# spelling, any case) is refused either way; a dependency's own French inside
# Frameworks/ is not the app's and is left alone.
FR_CA_TABLES="fr-CA.lproj/Localizable.strings fr-CA.lproj/InfoPlist.strings"
echo "13b. refuses fr-CA.lproj while French is off, requires it while on, and refuses any other French"
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr-CA.lproj"
assert_nonzero "$RC" "fr-CA.lproj without DISTRICT_FRENCH fails the script"
assert_contains "$OUT" "holds fr-CA.lproj, but DISTRICT_FRENCH is not set" "the message names the table and the switch"
assert_contains "$OUT" "has been DELETED" "the message says the archive is gone"
if [ -e "$STUB_DIR/out/DistrictAI.xcarchive" ]; then
  fail "the archive is deleted"
else
  ok "the archive is deleted"
fi
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES" DISTRICT_FRENCH=YES
assert_zero "$RC" "fr-CA.lproj with both tables and DISTRICT_FRENCH=YES is accepted"
assert_contains "$OUT" "French ok - DISTRICT_FRENCH is on, and fr-CA.lproj holds both tables" "the guard says French is on and present"
assert_contains "$(calls)" "-exportArchive" "a complete French build is exported"

# French on, but French did not arrive: the 3.0 cut's own failure.
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj" DISTRICT_FRENCH=YES
assert_nonzero "$RC" "DISTRICT_FRENCH=YES with no fr-CA.lproj fails the script"
assert_contains "$OUT" "DISTRICT_FRENCH is on, but the archived app has no fr-CA.lproj/Localizable.strings fr-CA.lproj/InfoPlist.strings." "the message names both missing tables"
assert_contains "$OUT" "has been DELETED" "the archive without French is deleted"
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported without the French"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr-CA.lproj" DISTRICT_FRENCH=YES
assert_nonzero "$RC" "an empty fr-CA.lproj with French on fails the script"
assert_contains "$OUT" "has no fr-CA.lproj/Localizable.strings fr-CA.lproj/InfoPlist.strings." "the message names both tables of the empty folder"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr-CA.lproj/Localizable.strings" DISTRICT_FRENCH=YES
assert_nonzero "$RC" "fr-CA.lproj without InfoPlist.strings fails with French on"
assert_contains "$OUT" "has no fr-CA.lproj/InfoPlist.strings." "the message names the one missing table"
assert_not_contains "$OUT" "has no fr-CA.lproj/Localizable.strings" "the table that is there is not named"
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported with half the French"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES fr.lproj" DISTRICT_FRENCH=YES
assert_nonzero "$RC" "fr.lproj fails the script even with French on"
assert_contains "$OUT" "holds fr.lproj" "the message names fr.lproj"
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported with fr.lproj"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES fr-FR.lproj" DISTRICT_FRENCH=YES
assert_nonzero "$RC" "fr-FR.lproj beside a complete fr-CA.lproj fails with French on"
assert_contains "$OUT" "holds fr-FR.lproj, which is never shipped" "the message names fr-FR.lproj"

# The same table under another spelling: AppL10n's "fr" prefix would switch it on.
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr-ca.lproj/Localizable.strings fr-ca.lproj/InfoPlist.strings" DISTRICT_FRENCH=YES
assert_nonzero "$RC" "fr-ca.lproj (lower case) is not fr-CA.lproj, even with French on"
assert_contains "$OUT" "holds fr-ca.lproj, which is never shipped" "the message names the misspelt folder"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr.lproj"
assert_nonzero "$RC" "fr.lproj fails the script with French off"
assert_contains "$OUT" "holds fr.lproj, which is never shipped" "the message names fr.lproj"
assert_contains "$OUT" "has been DELETED" "the archive with fr.lproj is deleted"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr_CA.lproj"
assert_nonzero "$RC" "fr_CA.lproj (underscore) fails the script with French off"
assert_contains "$OUT" "holds fr_CA.lproj" "the message names fr_CA.lproj"
assert_not_contains "$(calls)" "-exportArchive" "nothing is exported with fr_CA.lproj"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj FR.lproj"
assert_nonzero "$RC" "FR.lproj (upper case) fails the script with French off"
assert_contains "$OUT" "holds FR.lproj" "the match ignores case"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj fr.lproj fr_CA.lproj"
assert_nonzero "$RC" "two stray French folders fail the script"
assert_contains "$OUT" " fr.lproj" "the message names fr.lproj"
assert_contains "$OUT" " fr_CA.lproj" "the message names fr_CA.lproj too"

# ⚠️ NOT THE APP'S FRENCH. A framework's own tables live under Frameworks/ and do not
# change what AppL10n reads; the guard stays at the app's top level.
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj Frameworks/Vendor.framework/fr.lproj Frameworks/Vendor.framework/fr-CA.lproj"
assert_zero "$RC" "a framework's own French with French off is accepted"
assert_contains "$OUT" "French ok - no French localization" "the framework's French is not the app's"

# Names that merely contain "fr" elsewhere are not French.
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj af.lproj Base.lproj"
assert_zero "$RC" "af.lproj and Base.lproj are not French"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj"
assert_zero "$RC" "an English-only bundle is accepted"
assert_contains "$OUT" "French ok - no French localization" "the guard reports an English-only bundle"

# ── 13c. The Apple Watch companion and every other nested bundle ─────────────
# ⛔ THE GUARDS ABOVE, OVER EVERY BUNDLE IN THE ARCHIVE. The watch app ships inside
# the iOS app (DistrictAI.app/Watch/DistrictAIWatch.app) with its complications in
# its own PlugIns/; each is a binary, a set of localizations and a version of its
# own. Each refusal is seen to fire, to name the bundle and to delete the archive;
# the archive without a watch app is seen to pass exactly as before.
WATCH_REL="DistrictAI.app/Watch/DistrictAIWatch.app"
APPEX_REL="$WATCH_REL/PlugIns/DistrictAIWatchComplications.appex"
# Asserts a refusal: non-zero, the reason printed, the archive deleted, nothing exported.
assert_discarded() {
  assert_nonzero "$RC" "$1: fails the script"
  assert_contains "$OUT" "$2" "$1: the message names the reason"
  assert_contains "$OUT" "has been DELETED" "$1: the message says the archive is gone"
  if [ -e "$STUB_DIR/out/DistrictAI.xcarchive" ]; then
    fail "$1: the archive is deleted"
  else
    ok "$1: the archive is deleted"
  fi
  assert_not_contains "$(calls)" "-exportArchive" "$1: nothing is exported"
}
echo "13c. a watch app and its complications are held to the seam, French, version and layout guards"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_GIT_COUNT=777 STUB_ARCHIVE_WATCH=1 DISTRICT_FRENCH=YES \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES" STUB_WATCH_LPROJ="en.lproj $FR_CA_TABLES" \
  STUB_APPEX_LPROJ="en.lproj $FR_CA_TABLES Frameworks/Vendor.framework/fr.lproj"
assert_zero "$RC" "13c watch: a watch app with complications and French in every bundle is accepted"
assert_contains "$OUT" "IOS-SEC-01 ok - no UI-test seam in the archived binary (3 executables checked)" \
  "13c watch: the seam guard read the app, the watch app and the complications"
assert_contains "$(calls)" "plutil -extract CFBundleExecutable raw -o - $STUB_DIR/out/DistrictAI.xcarchive/Products/Applications/$APPEX_REL/Info.plist" \
  "13c watch: a nested executable is found by its own CFBundleExecutable"
assert_contains "$OUT" "Versions ok - 2 nested bundles carry the app's 3.0.2 (4878)" \
  "13c watch: both nested bundles carry the app's versions"
assert_contains "$OUT" "French ok - DISTRICT_FRENCH is on, and fr-CA.lproj holds both tables in the app and its 2 nested bundles" \
  "13c watch: French is complete in every bundle (a framework's own French is not the bundle's)"
assert_contains "$(calls)" "-exportArchive" "13c watch: it is exported"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 STUB_ARCHIVE_IOS_APPEX=1 \
  STUB_ARCHIVE_LPROJ="en.lproj" STUB_WATCH_LPROJ="en.lproj" STUB_APPEX_LPROJ="en.lproj"
assert_zero "$RC" "13c watch, English: an English-only watch app, complications and iOS extension are accepted"
assert_contains "$OUT" "Versions ok - 3 nested bundles" "13c watch, English: the iOS app's own PlugIns/ is walked too"
assert_contains "$OUT" "French ok - no French localization in the archived app or its 3 nested bundles" \
  "13c watch, English: the guard reports every bundle English-only"

# ⛔ TODAY'S ARCHIVE, UNCHANGED: no nested bundle, so nothing nested is read or compared.
new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_LPROJ="en.lproj"
assert_zero "$RC" "13c no watch: an archive with no watch app is accepted"
assert_contains "$OUT" "IOS-SEC-01 ok - no UI-test seam in the archived binary (1 executables checked)" \
  "13c no watch: the app's own binary is the one checked"
assert_not_contains "$OUT" "Versions ok" "13c no watch: there is nothing nested to compare"
assert_not_contains "$(calls)" "plutil" "13c no watch: no Info.plist is read for the guards"
assert_contains "$OUT" "French ok - no French localization in the archived app or its 0 nested bundles" \
  "13c no watch: the French guard runs as before"
assert_contains "$(calls)" "-exportArchive" "13c no watch: it is exported"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 STUB_WATCH_SEAM=1
assert_discarded "13c seam in the watch binary" \
  "UI-test seam is present in the archived binary: $WATCH_REL/DistrictAIWatch (1 hits)."
assert_not_contains "$OUT" "IOS-SEC-01 ok" "13c seam in the watch binary: no success is reported"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 STUB_APPEX_SEAM=1
assert_discarded "13c seam in the complications binary" \
  "UI-test seam is present in the archived binary: $APPEX_REL/DistrictAIWatchComplications (1 hits)."
assert_not_contains "$OUT" "DistrictAIWatch (1 hits)" "13c seam in the complications binary: the clean watch binary is not named"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 STUB_APPEX_NO_EXECUTABLE=1
assert_discarded "13c no CFBundleExecutable" \
  "$APPEX_REL has no readable CFBundleExecutable, so the seam check cannot find its binary."
assert_not_contains "$OUT" "IOS-SEC-01 ok" "13c no CFBundleExecutable: no vacuous pass"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 DISTRICT_FRENCH=YES \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES" STUB_APPEX_LPROJ="en.lproj $FR_CA_TABLES" \
  STUB_WATCH_LPROJ="en.lproj fr-CA.lproj/Localizable.strings"
assert_discarded "13c French gap in the watch app" \
  "DISTRICT_FRENCH is on, but the archived $WATCH_REL has no fr-CA.lproj/InfoPlist.strings."

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 DISTRICT_FRENCH=YES \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES" STUB_WATCH_LPROJ="en.lproj $FR_CA_TABLES" \
  STUB_APPEX_LPROJ="en.lproj"
assert_discarded "13c French missing from the complications" \
  "DISTRICT_FRENCH is on, but the archived $APPEX_REL has no fr-CA.lproj/Localizable.strings fr-CA.lproj/InfoPlist.strings."

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 STUB_ARCHIVE_LPROJ="en.lproj" STUB_WATCH_LPROJ="en.lproj $FR_CA_TABLES"
assert_discarded "13c French in the watch app with French off" \
  "the archived $WATCH_REL holds fr-CA.lproj, but DISTRICT_FRENCH is not set, so French is off."

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 DISTRICT_FRENCH=YES \
  STUB_ARCHIVE_LPROJ="en.lproj $FR_CA_TABLES" STUB_WATCH_LPROJ="en.lproj $FR_CA_TABLES" \
  STUB_APPEX_LPROJ="en.lproj $FR_CA_TABLES fr.lproj"
assert_discarded "13c fr.lproj in the complications" \
  "the archived $APPEX_REL holds fr.lproj, which is never shipped"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_GIT_COUNT=777 STUB_ARCHIVE_WATCH=1 STUB_WATCH_SHORT_VERSION=3.0.1
assert_discarded "13c watch short version mismatch" \
  "must carry the archived app's version 3.0.2 (4878), but $WATCH_REL is '3.0.1' (4878);"
assert_not_contains "$OUT" "but $APPEX_REL" "13c watch short version mismatch: the matching complications are not named"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_GIT_COUNT=777 STUB_ARCHIVE_WATCH=1 STUB_WATCH_BUILD=1
assert_discarded "13c watch build number mismatch" "$WATCH_REL is '3.0.2' (1);"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_GIT_COUNT=777 STUB_ARCHIVE_WATCH=1 STUB_APPEX_BUILD=1
assert_discarded "13c complications build number mismatch" "$APPEX_REL is '3.0.2' (1);"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_GIT_COUNT=777 STUB_ARCHIVE_WATCH=1 STUB_APPEX_SHORT_VERSION=3.1.0
assert_discarded "13c complications short version mismatch" "$APPEX_REL is '3.1.0' (4878);"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_GIT_COUNT=777 STUB_ARCHIVE_IOS_APPEX=1 STUB_IOS_APPEX_BUILD=1
assert_discarded "13c iOS extension build number mismatch" "DistrictAI.app/PlugIns/DistrictAIWidgets.appex is '3.0.2' (1);"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_WATCH=1 STUB_ARCHIVE_NO_PLIST=1
assert_discarded "13c no app Info.plist beside a watch app" \
  "the archived app's Info.plist has no readable CFBundleShortVersionString or CFBundleVersion"

new_case
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  STUB_ARCHIVE_EXTRA_APP=DistrictAIWatch.app
assert_discarded "13c an extra .app in Products/Applications" \
  "Products/Applications holds DistrictAIWatch.app besides DistrictAI.app"

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
# Source bundles beside the dSYMs, so an issue shows its source lines.
EXPECTED_SENTRY="$EXPECTED_SENTRY --include-sources"
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
assert_not_contains "$(calls)" "sentry-cli releases" "no release is created after a failed upload"

# ── 21. The Sentry release and its commit ────────────────────────────────────
# ⛔ THE NAME IS THE SDK'S, READ FROM THE ARCHIVED APP. Bundle id, short version and
# the build number the archive was given (777 + 4101); one character off and Sentry
# holds a second release no event lands in.
echo "21. creates the release the app reports as, gives it HEAD's commit, and finalizes it"
new_case
RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG" \
  STUB_GIT_COUNT=777 STUB_SHORT_VERSION=3.1.0 STUB_GIT_SHA=feedfacefeedfacefeedfacefeedfacefeedface
assert_zero "$RC" "the release run succeeds"
RELEASE="com.distronode.district@3.1.0+4878"
assert_contains "$OUT" "Sentry release: $RELEASE (commit feedfacefeedfacefeedfacefeedfacefeedface)" \
  "it prints the release name and the commit"
assert_contains "$(line_for 'plutil ')" "$STUB_DIR/out/DistrictAI.xcarchive/Products/Applications/DistrictAI.app/Info.plist" \
  "the name is read from the archived app's Info.plist"
assert_eq "$(line_for 'sentry-cli releases new ')" \
  "sentry-cli releases new --org $STUB_SENTRY_ORG --project district-ios $RELEASE" \
  "releases new: the argv is exact"
assert_eq "$(line_for 'sentry-cli releases set-commits ')" \
  "sentry-cli releases set-commits --org $STUB_SENTRY_ORG $RELEASE --commit distronode-corporation/district-ios@feedfacefeedfacefeedfacefeedfacefeedface --ignore-missing" \
  "releases set-commits: the argv is exact"
assert_eq "$(line_for 'sentry-cli releases finalize ')" \
  "sentry-cli releases finalize --org $STUB_SENTRY_ORG $RELEASE" \
  "releases finalize: the argv is exact"
# ⛔ Every sentry-cli call, not only the first, goes to the EU host.
assert_eq "$(line_count "$(calls)" 'sentry-cli env SENTRY_URL=https://de.sentry.io')" "4" \
  "all four sentry-cli calls point at the EU API host"
assert_eq "$(line_count "$(calls)" 'sentry-cli env SENTRY_URL=')" "4" "and no call goes anywhere else"
assert_not_contains "$(calls)" "$FAKE_SENTRY_TOKEN" "the token is never passed as an argument"
assert_not_contains "$OUT" "::warning::" "a release that worked raises no warning"
assert_contains "$(calls)" "xcodebuild -exportArchive " "the export follows"

# ── 22. A failed release step is a warning, never a failed archive ───────────
echo "22. a failed release step warns and the archive still goes to the export"
for step in new set-commits finalize; do
  new_case
  RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
  run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
    SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG" \
    STUB_SENTRYCLI_FAIL_RELEASES="$step"
  assert_zero "$RC" "22 ($step): a failed release step does not fail the archive"
  assert_contains "$OUT" "::warning::the Sentry release" "22 ($step): it says so as a run warning"
  assert_contains "$(calls)" "xcodebuild -exportArchive " "22 ($step): the export still runs"
  assert_not_contains "$OUT" "$FAKE_SENTRY_TOKEN" "22 ($step): the warning does not print the token"
done
# The chain stops at the first failure: nothing is finalized after a refused new.
new_case
RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG" STUB_SENTRYCLI_FAIL_RELEASES=new
assert_not_contains "$(calls)" "sentry-cli releases finalize" "22: no finalize after a failed new"

echo "22b. an archive with no readable Info.plist warns and creates no release"
new_case
RUN_PATH="$STUB_DIR:$SENTRYCLI_DIR:$REAL_BIN"
run_archive ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER" BUILD_DIR="$STUB_DIR/out" \
  SENTRY_AUTH_TOKEN="$FAKE_SENTRY_TOKEN" SENTRY_ORG="$STUB_SENTRY_ORG" STUB_ARCHIVE_NO_PLIST=1
assert_zero "$RC" "22b: no Info.plist does not fail the archive"
assert_contains "$OUT" "::warning::the Sentry release" "22b: it warns"
assert_not_contains "$(calls)" "sentry-cli releases" "22b: no release under a guessed name"
assert_contains "$(calls)" "sentry-cli debug-files upload" "22b: the dSYMs were still uploaded"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
