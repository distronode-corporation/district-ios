#!/usr/bin/env bash
#
# Archive District AI and upload it to App Store Connect. Runs on a Mac with Xcode.
#
#   ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> scripts/archive-imac.sh
#
# ── Where it runs ────────────────────────────────────────────────────────────
# Releases are built by .github/workflows/release.yml, on a GitHub-hosted macOS
# runner, which calls this script: a protected `v*` tag (or a dispatch on main
# for a TestFlight-only build) is the only way in. The workflow borrows the App
# Store Connect key and the Sentry settings from Distronode's Google Cloud for
# the length of one run, writes the key to a mode-0600 file under the runner's
# temporary directory and passes its path as ASC_KEY_PATH. The same script still
# runs on a maintainer's Mac, which is how versions up to 1.2 were built.
#
# ⚠️ The flags live here rather than in the workflow so that both routes build
# the same thing, and so that scripts/archive-imac.test.sh can prove them.
#
# ── The App Store Connect key ────────────────────────────────────────────────
# ⛔ THE .p8 NEVER ENTERS THE REPO, A COMMIT, A LOG, A CI VARIABLE OR CHAT. The
# operator (or the workflow) places it at the path below, and nothing here ever
# reads, prints, rewrites or copies it, or passes its contents as an argument
# (argv is world-readable through `ps`): xcodebuild is handed the PATH. If the
# key is ever pasted somewhere, revoke it in App Store Connect and mint a new
# one; an ASC .p8 downloads exactly ONCE.
#
# ⚠️ THE DEFAULT PATH IS APPLE'S LOOKUP PATH. xcodebuild and altool look up an
# API key by id as AuthKey_<KEY_ID>.p8 in a private_keys directory under the
# home directory (and a couple of legacy siblings), which is where a Mac keeps
# it. -authenticationKeyPath below states the path explicitly, so ASC_KEY_PATH
# can put it anywhere else (a CI runner's temporary directory, which is wiped
# with the job); a path that is only implied by a lookup rule is a path nobody
# can debug.
#
# ── Environment ──────────────────────────────────────────────────────────────
#   ASC_KEY_ID      ASC API key id      (required)
#   ASC_ISSUER_ID   ASC API issuer id   (required)
#   ASC_KEY_PATH    the .p8 (default: ~/private_keys/AuthKey_<ASC_KEY_ID>.p8;
#                   required to exist, mode 0600; this script never writes or
#                   fetches it)
#   BUILD_DIR       archive + export output (default: DerivedData/release)
#   BUILD_NUMBER_OFFSET  added to the commit count (default: 4101; see below)
#   UPLOAD=0        stop after the archive, upload nothing (signed scratch build)
#   ALLOW_DIRTY=1   proceed with a dirty working tree
#   ALLOW_BRANCH=1  proceed when HEAD is not on main (the workflow sets it for a
#                   tag, whose commit it has already proved is on main)
#   SENTRY_DSN      the app's DSN (optional; when unset the build carries an
#                   EMPTY value, which DISABLES Sentry entirely — no SDK is
#                   started, so nothing is reported, symbolicated or otherwise)
#   SENTRY_AUTH_TOKEN  Sentry org token (optional); when set, dSYMs are uploaded after the archive
#   SENTRY_ORG      Sentry org slug (EU region); REQUIRED when SENTRY_AUTH_TOKEN is set
#
# Every credential comes from the caller's environment and the key file. The
# script reads no secret store and has no default for any of them.
#
# Proven by scripts/archive-imac.test.sh, which drives it against stub uname,
# git, xcodegen, xcodebuild and sentry-cli. There is no other way to test it:
# the real thing takes a Mac, an Apple account and ten minutes.
set -euo pipefail

# The team the archive is signed for. ⚠️ Must equal <key>teamID</key> in
# ExportOptions.plist; a mismatch fails at export naming neither file.
TEAM_ID="R935BA6767"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

die() {
  echo "FATAL - $*" >&2
  exit 1
}

# ── Host ─────────────────────────────────────────────────────────────────────
# ⛔ FIRST, BEFORE ANYTHING ELSE. Everything below shells out to xcodebuild; on
# Linux the failure would otherwise be "xcodegen: command not found" partway
# through, which reads like a missing dependency rather than the wrong machine.
HOST_OS="$(uname -s)"
[ "$HOST_OS" = "Darwin" ] ||
  die "archive-imac.sh runs on macOS only; uname -s reported '$HOST_OS', not 'Darwin'. This release lane needs a macOS host and there is no Linux path."

cd "$IOS_DIR"

# ── The tree being shipped ───────────────────────────────────────────────────
# ⛔ THE BUILD NUMBER IS DERIVED FROM HEAD, so a dirty tree or a side branch
# produces a build that App Store Connect labels with a number that maps to no
# commit anybody can check out. Both refusals are overridable, because a signed
# scratch build on a work branch is a legitimate thing to want and the
# alternative is somebody commenting the check out.
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
ALLOW_BRANCH="${ALLOW_BRANCH:-0}"

if [ "$ALLOW_DIRTY" != "1" ]; then
  tree_state="$(git status --porcelain)"
  [ -z "$tree_state" ] ||
    die "the working tree is dirty; commit or stash first, or set ALLOW_DIRTY=1 for a scratch build."
fi

if [ "$ALLOW_BRANCH" != "1" ]; then
  # ⚠️ Prints EMPTY on a detached HEAD rather than failing, which is why the
  # message quotes the value and names detached HEAD explicitly.
  branch="$(git branch --show-current)"
  [ "$branch" = "main" ] ||
    die "HEAD is on '$branch' (empty means a detached HEAD), not main; set ALLOW_BRANCH=1 for a scratch build."
fi

# ── The App Store Connect API key ────────────────────────────────────────────
# ⛔ BOTH IDENTIFIERS ARE REQUIRED, AND EACH REFUSAL NAMES THE ONE THAT IS
# MISSING, before anything is generated or built. A key id without its issuer
# (or the reverse) cannot authenticate.
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
[ -n "$ASC_KEY_ID" ] ||
  die "ASC_KEY_ID is unset. Both ASC_KEY_ID and ASC_ISSUER_ID are required (App Store Connect, Users and Access, Integrations)."
[ -n "$ASC_ISSUER_ID" ] ||
  die "ASC_ISSUER_ID is unset. Both ASC_KEY_ID and ASC_ISSUER_ID are required (App Store Connect, Users and Access, Integrations)."

# ⛔ THE KEY FILE IS THE CALLER'S, AND AN EXISTING ONE IS NEVER REWRITTEN.
# The script only checks that it is there: fetching, decoding or copying it would
# be a second place its contents could leak from. ASC_KEY_PATH moves it; the
# default is Apple's own lookup path on a Mac.
KEY_PATH="${ASC_KEY_PATH:-$HOME/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$KEY_PATH" ] ||
  die "no App Store Connect key at $KEY_PATH. Put the .p8 for key $ASC_KEY_ID there, mode 0600 (chmod 600); this script never writes or fetches it."
echo "Using the App Store Connect key at $KEY_PATH. Its contents are never printed."

# ── The Sentry DSN ───────────────────────────────────────────────────────────
# ⛔ THIS IS THE ONLY PLACE A REAL DSN ENTERS A BUILD, AND THAT IS A SAFETY
# DECISION, NOT AN OVERSIGHT. project.yml ships `SENTRY_DSN: ""` so no committed
# file carries a DSN and no Debug or CI build can report anything; the value
# comes from the operator's environment at archive time and is passed to
# xcodebuild as a build setting below.
#
# ⛔ ABSENCE IS NOT FATAL, AND IT SAYS SO IN ONE LINE. A build with no crash
# reporting is a legitimate thing to want (a scratch build, or a fork with no
# Sentry project), and the alternative to continuing is somebody commenting this
# block out. ⚠️ But a blank DSN does NOT mean "crashes arrive unsymbolicated":
# it means DistrictSentry.startIfConfigured() returns before SentrySDK.start, so
# no handler is installed and NOTHING is reported at all. The notice has to say
# that, because the two failures look identical from the outside — silence.
#
# ⛔ THE VALUE IS NEVER ECHOED. The notices name the variable, never the DSN.
#
# ⚠️ THE DSN DOES REACH xcodebuild's ARGV, unavoidably — a build setting is
# argv — and argv is world-readable through `ps`. That is bounded on purpose: a
# DSN's public key is compiled into every copy of the shipped app, so it is not
# credential material in the way the .p8 and SENTRY_AUTH_TOKEN are, and neither
# of those two ever reaches argv here.
SENTRY_DSN="${SENTRY_DSN:-}"
if [ -n "$SENTRY_DSN" ]; then
  echo "Using SENTRY_DSN from the environment. Its value is never printed."
else
  echo "SENTRY_DSN is unset - SENTRY IS DISABLED IN THIS BUILD: no SDK is started, so no crash or app hang is reported at all."
fi

# ── Paths and the build number ───────────────────────────────────────────────
# ⚠️ The default lives under DerivedData/, which .gitignore already covers, so an
# archive cannot be committed by accident. An override MUST be somewhere ignored
# too.
BUILD_DIR="${BUILD_DIR:-$IOS_DIR/DerivedData/release}"
ARCHIVE_PATH="$BUILD_DIR/DistrictAI.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
mkdir -p "$BUILD_DIR"

# ⛔ COMMIT COUNT PLUS AN OFFSET, NOT A TIMESTAMP OR A CI RUN NUMBER. App Store
# Connect refuses a build number at or below the last one uploaded, comparing
# them numerically, so the value has to rise monotonically; the count of commits
# on main does, is derivable from any checkout, and maps a build back to a sha
# once the offset is subtracted. This repository's history starts fresh, so the
# count alone would fall below the numbers the app has already shipped with; 4101
# clears them. (It was 4100 until the first single-commit tree was uploaded as
# build 4101, which App Store Connect will not accept a second time.)
# BUILD_NUMBER_OFFSET exists for a fork that needs a different floor. ExportOptions.plist sets manageAppVersionAndBuildNumber to false so
# nothing overrides it.
#
# ⛔ PASSING IT HERE IS ONLY HALF, AND THE OTHER HALF LIVES IN project.yml. This
# sets a BUILD SETTING; the bundle takes its CFBundleVersion from Info.plist, so
# the value arrives only because `info.properties` declares
# `CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"`. Without that declaration
# xcodegen writes a literal `1` and this line has no effect on the shipped app,
# silently. If a build ever reports version 1, look there and not here.
# 🔑 Prove it from the BUILT app, never from the generated Info.plist (which
# correctly contains the unsubstituted reference):
#   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
#     "$ARCHIVE_PATH/Products/Applications/DistrictAI.app/Info.plist"
BUILD_NUMBER=$(( ${BUILD_NUMBER_OFFSET:-4101} + $(git rev-list --count HEAD) ))

# ── Generate, archive, export ────────────────────────────────────────────────
# ⛔ THE .xcodeproj IS GENERATED, NEVER COMMITTED. project.yml is
# the source of truth and the bundle is gitignored, so this step is not optional
# on a fresh checkout.
xcodegen generate --spec project.yml

# ⛔ `generic/platform=iOS` ARCHIVES FOR DEVICE WITHOUT NAMING ONE. A concrete
# destination ties the archive to whatever this host happens to have paired, and
# a release host needs no paired iPhone.
xcodebuild archive \
  -project DistrictAI.xcodeproj \
  -scheme DistrictAI \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  SENTRY_DSN="$SENTRY_DSN"

# ── IOS-SEC-01: the UI-test seam must not be in a shipped binary ─────────────
# ⛔ THE ARCHIVE IS DISCARDED IF IT IS, RATHER THAN WARNED ABOUT. `UITestSession`
# and `AppContainerSeam`'s injection branch are inside `#if DEBUG`, and
# `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` is set on the Debug configuration
# only — verified against the generated pbxproj and `xcodebuild -showBuildSettings`
# rather than assumed. This archive is a Release build, so the strings cannot be
# here. That is exactly why it is worth checking: the whole class of bug this
# guards against is a branch everybody was sure was unreachable in the shipping
# configuration.
#
# ⚠️ `grep -c` ON `strings`, NOT `nm`. A Swift release build inlines and mangles,
# so a symbol search proves nothing; the launch argument and the environment
# variable are STRING LITERALS and survive. Absence of the literal is the check
# that can actually fail.
APP_BINARY="$ARCHIVE_PATH/Products/Applications/DistrictAI.app/DistrictAI"
# ⛔ THE BINARY MUST EXIST BEFORE IT IS SEARCHED. `strings` on a missing file
# fails, the count comes out as 0, and "0 hits" would read as a clean binary;
# an archive with nothing to inspect is refused, not passed.
[ -f "$APP_BINARY" ] ||
  die "no app binary at $APP_BINARY, so the seam check has nothing to inspect. Nothing was exported or uploaded."
SEAM_HITS="$(strings "$APP_BINARY" | grep -c 'DISTRICT_UITEST' || true)"
if [ "$SEAM_HITS" != "0" ]; then
  rm -rf "$ARCHIVE_PATH"
  echo "FATAL - the UI-test seam is present in the archived binary ($SEAM_HITS hits)." >&2
  echo "The archive has been DELETED. Nothing was exported or uploaded." >&2
  exit 1
fi
echo "IOS-SEC-01 ok - no UI-test seam in the archived binary"

# ── Debug symbols to Sentry ──────────────────────────────────────────────────
# ⛔ AFTER THE ARCHIVE AND BEFORE THE EXPORT, so a scratch build (UPLOAD=0)
# uploads its symbols too. A signed scratch build on a device is where the first
# real crashes come from, and an unsymbolicated crash report is a list of
# addresses.
#
# ⛔ THE INGEST HOST AND THE API HOST ARE DIFFERENT THINGS. sentry-cocoa reads
# the ingest host out of the DSN; sentry-cli does not, and defaults to the US
# control silo where an EU org does not exist. A mis-pointed debug-file upload
# SILENTLY DOES NOTHING while the build stays green. Hence SENTRY_URL,
# explicitly, on this one command.
#
# ⛔ THE TOKEN NEVER REACHES argv. sentry-cli reads SENTRY_AUTH_TOKEN from its
# environment; --auth-token would put a live org token into `ps` output for every
# user on the machine and into this script's own log.
#
# ⚠️ BOTH SKIPS SAY SO IN ONE LINE RATHER THAN PASSING QUIETLY. A missing upload
# is invisible until somebody reads a crash report weeks later, so the absence
# gets a sentence at the moment it happens.
if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "SENTRY_AUTH_TOKEN is unset - skipped the dSYM upload; crashes from this build will not symbolicate."
elif ! command -v sentry-cli >/dev/null 2>&1; then
  echo "SENTRY_AUTH_TOKEN is set but sentry-cli is not on PATH - skipped the dSYM upload; install it with: brew install getsentry/tools/sentry-cli"
else
  # ⚠️ REQUIRED RATHER THAN DEFAULTED. sentry-cli has no default org, and a wrong
  # one fails with a 404 that reads like a missing project.
  [ -n "${SENTRY_ORG:-}" ] ||
    die "SENTRY_AUTH_TOKEN is set but SENTRY_ORG is not; pass the EU org slug, there is no default."
  SENTRY_URL="https://de.sentry.io" sentry-cli debug-files upload \
    --org "$SENTRY_ORG" \
    --project district-ios \
    "$ARCHIVE_PATH/dSYMs"
fi

if [ "${UPLOAD:-1}" = "0" ]; then
  echo "UPLOAD=0 - stopped after the archive. Nothing was sent to App Store Connect."
else
  # ⚠️ THE AUTHENTICATION FLAGS ARE REPEATED ON PURPOSE. The export is a separate
  # xcodebuild invocation and inherits nothing from the archive; without them
  # -exportArchive cannot talk to App Store Connect and fails at the upload, i.e.
  # after the expensive half has already run.
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
fi

echo "build number: $BUILD_NUMBER"
echo "archive: $ARCHIVE_PATH"
