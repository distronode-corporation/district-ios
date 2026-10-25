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
#   SENTRY_AUTH_TOKEN  Sentry org token (optional); when set, dSYMs and their sources are
#                   uploaded after the archive, and the release is given this commit
#   SENTRY_ORG      Sentry org slug (EU region); REQUIRED when SENTRY_AUTH_TOKEN is set
#
# Every credential comes from the caller's environment and the key file. The
# script reads no secret store and has no default for any of them.
#
# Proven by scripts/archive-imac.test.sh, which drives it against stub uname,
# git, xcodegen, xcodebuild, plutil, codesign and sentry-cli. There is no other way to test it:
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

# ── The archived bundles ─────────────────────────────────────────────────────
# Every guard below DELETES the archive when it fails, rather than warning: an
# archive that fails one is never exported, uploaded or kept for a re-run.
APPS_DIR="$ARCHIVE_PATH/Products/Applications"
APP_DIR="$APPS_DIR/DistrictAI.app"

discard_archive() {
  rm -rf "$ARCHIVE_PATH"
  echo "FATAL - $1" >&2
  echo "The archive has been DELETED. Nothing was exported or uploaded." >&2
  exit 1
}

# A bundle's path as the messages name it, relative to Products/Applications.
bundle_label() { echo "${1#"$APPS_DIR"/}"; }

# ⛔ Products/Applications HOLDS DistrictAI.app AND NOTHING ELSE. The watch app
# ships INSIDE the iOS app (DistrictAI.app/Watch/), never beside it; a second
# top-level .app is a scheme or embed mistake, and App Store Connect would see an
# archive that is not the one these guards inspected. Every entry counts, hidden
# ones too.
STRAY_ENTRIES=""
shopt -s nullglob dotglob
for entry in "$APPS_DIR"/*; do
  [ "${entry##*/}" = "DistrictAI.app" ] || STRAY_ENTRIES="$STRAY_ENTRIES ${entry##*/}"
done
shopt -u nullglob dotglob
[ -z "$STRAY_ENTRIES" ] ||
  discard_archive "Products/Applications holds$STRAY_ENTRIES besides DistrictAI.app; it must hold DistrictAI.app alone (the watch app ships inside it, under Watch/)."

# ⛔ EVERY NESTED BUNDLE, AT ANY DEPTH: the watch app under the iOS app's Watch/,
# each extension under a PlugIns/ (the iOS app's own and the watch app's, where
# the complications live). Each one is a shipped binary, a set of localizations
# and a version of its own, and every guard below runs over all of them. An
# archive with none (no watch app) is checked exactly as before.
#
# ⚠️ bash 3.2 (a Mac's /bin/bash) treats "${empty[@]}" as unbound under `set -u`,
# hence the count beside the array and the ${a[@]+...} expansions.
NESTED_BUNDLES=()
NESTED_COUNT=0
collect_nested() {
  local child
  for child in "$1"/Watch/*.app "$1"/PlugIns/*.appex; do
    [ -d "$child" ] || continue
    NESTED_BUNDLES+=("$child")
    NESTED_COUNT=$((NESTED_COUNT + 1))
    collect_nested "$child"
  done
}
collect_nested "$APP_DIR"

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
#
# ⛔ EVERY MAIN EXECUTABLE, NOT ONLY THE iOS APP'S: the watch app and every
# extension link the same shared code. A nested bundle's executable is found by
# its own Info.plist's CFBundleExecutable, never guessed from the bundle name.
APP_BINARY="$APP_DIR/DistrictAI"
# ⛔ THE BINARY MUST EXIST BEFORE IT IS SEARCHED. `strings` on a missing file
# fails, the count comes out as 0, and "0 hits" would read as a clean binary;
# an archive with nothing to inspect is refused, not passed. The same holds for
# every nested bundle: no CFBundleExecutable, or no file by that name, refuses.
[ -f "$APP_BINARY" ] ||
  die "no app binary at $APP_BINARY, so the seam check has nothing to inspect. Nothing was exported or uploaded."
SEAM_BINARIES=("$APP_BINARY")
for bundle in ${NESTED_BUNDLES[@]+"${NESTED_BUNDLES[@]}"}; do
  executable="$(plutil -extract CFBundleExecutable raw -o - "$bundle/Info.plist" 2>/dev/null)" || executable=""
  [ -n "$executable" ] ||
    discard_archive "$(bundle_label "$bundle") has no readable CFBundleExecutable, so the seam check cannot find its binary."
  [ -f "$bundle/$executable" ] ||
    discard_archive "no binary at $(bundle_label "$bundle")/$executable (its CFBundleExecutable), so the seam check has nothing to inspect."
  SEAM_BINARIES+=("$bundle/$executable")
done
SEAM_REPORT=""
for binary in "${SEAM_BINARIES[@]}"; do
  hits="$(strings "$binary" | grep -c 'DISTRICT_UITEST' || true)"
  [ "$hits" = "0" ] || SEAM_REPORT="$SEAM_REPORT $(bundle_label "$binary") ($hits hits)"
done
[ -z "$SEAM_REPORT" ] ||
  discard_archive "the UI-test seam is present in the archived binary:$SEAM_REPORT."
echo "IOS-SEC-01 ok - no UI-test seam in the archived binary (${#SEAM_BINARIES[@]} executables checked)"

# ── Every nested bundle carries the iOS app's version ────────────────────────
# ⛔ CFBundleVersion AND CFBundleShortVersionString, BOTH, EQUAL TO THE iOS APP'S.
# App Store Connect refuses an upload whose embedded watch app or extension
# disagrees, and does so after the archive and the export have run; a target
# that missed the `$(CURRENT_PROJECT_VERSION)` mapping in project.yml ships `1`
# silently (see the build number above). Read from the BUILT bundles, never the
# generated Info.plists. Only when there is a nested bundle: an archive without
# one has nothing to compare, and is checked exactly as before.
read_plist_key() { plutil -extract "$1" raw -o - "$2/Info.plist" 2>/dev/null || true; }
if [ "$NESTED_COUNT" -gt 0 ]; then
  APP_SHORT_VERSION="$(read_plist_key CFBundleShortVersionString "$APP_DIR")"
  APP_BUILD_VERSION="$(read_plist_key CFBundleVersion "$APP_DIR")"
  [ -n "$APP_SHORT_VERSION" ] && [ -n "$APP_BUILD_VERSION" ] ||
    discard_archive "the archived app's Info.plist has no readable CFBundleShortVersionString or CFBundleVersion, so its nested bundles' versions cannot be checked."
  VERSION_REPORT=""
  for bundle in "${NESTED_BUNDLES[@]}"; do
    short="$(read_plist_key CFBundleShortVersionString "$bundle")"
    build="$(read_plist_key CFBundleVersion "$bundle")"
    if [ "$short" != "$APP_SHORT_VERSION" ] || [ "$build" != "$APP_BUILD_VERSION" ]; then
      VERSION_REPORT="$VERSION_REPORT $(bundle_label "$bundle") is '$short' ($build);"
    fi
  done
  [ -z "$VERSION_REPORT" ] ||
    discard_archive "every nested bundle must carry the archived app's version $APP_SHORT_VERSION ($APP_BUILD_VERSION), but$VERSION_REPORT"
  echo "Versions ok - $NESTED_COUNT nested bundles carry the app's $APP_SHORT_VERSION ($APP_BUILD_VERSION)"
fi

# ── French is held to the switch ──────────────────────────────────────────────
# ⛔ THE ARCHIVE IS DISCARDED IF IT HOLDS fr-CA.lproj WHILE DISTRICT_FRENCH IS OFF,
# OR LACKS ITS TABLES WHILE DISTRICT_FRENCH IS ON. Since 3.0 project.yml puts
# App/Localization/fr-CA.lproj in every build and the release workflow sets
# DISTRICT_FRENCH=YES; with it unset the bundle must hold en.lproj alone. A French table in an English release would turn the push titles
# and the permission prompts French for every French device, and AppL10n would then
# turn the whole app French (it answers French when the bundle ships French), with
# French that has not been reviewed. Same verdict as the seam guard: deleted, not
# warned about.
#
# ⛔ AND NEVER ANOTHER FRENCH .lproj, EVEN WITH FRENCH ON: fr.lproj, fr_CA.lproj,
# fr-FR.lproj, any spelling, any case. Beside fr-CA.lproj a plain fr.lproj would take
# every fr-FR, fr-BE and fr-CH device, which must read the Canadian French, and
# AppL10n turns the app French for ANY bundle localization starting with "fr", so a
# French table under another name is French switched on all the same.
#
# ⛔ WITH FRENCH ON, fr-CA.lproj MUST HOLD BOTH TABLES. At the 3.0 cut this is the
# proof French arrived: a DISTRICT_FRENCH build without them would show English
# push titles and permission prompts on French devices.
#
# ⛔ EVERY BUNDLE, THE SAME THREE RULES: the iOS app and each nested bundle (the
# watch app, its complications, any extension) is judged on its own .lproj
# folders. A watch app with French while French is off is French on the wrist; a
# watch app without its tables while French is on is English on the wrist.
#
# ⚠️ EACH BUNDLE'S OWN TOP LEVEL ONLY, never Frameworks/: AppL10n reads the main
# bundle's localizations, and a dependency's own .lproj tables are not this app's
# French. Bash builtins only (the glob, `[[ ]]` under nocasematch), which also run
# on the harness's stub PATH.
case "${DISTRICT_FRENCH:-}" in
  YES | yes | true | TRUE | 1) FRENCH_ON=1 ;;
  *) FRENCH_ON=0 ;;
esac
# Appends to FRENCH_REFUSAL the reason $1 (a bundle) breaks the rules, naming it
# as $2. Nothing is appended for a bundle that keeps them.
french_check() {
  local dir="$1" label="$2" lproj name has_fr_ca=0 other_french="" missing="" table
  shopt -s nocasematch
  for lproj in "$dir"/*.lproj; do
    [ -d "$lproj" ] || continue
    name="${lproj##*/}"
    if [ "$name" = "fr-CA.lproj" ]; then
      has_fr_ca=1
    elif [[ "$name" == fr* ]]; then
      other_french="$other_french $name"
    fi
  done
  shopt -u nocasematch
  if [ -n "$other_french" ]; then
    FRENCH_REFUSAL="$FRENCH_REFUSAL $label holds$other_french, which is never shipped (fr-CA.lproj is the only French)."
  elif [ "$FRENCH_ON" = "0" ] && [ "$has_fr_ca" = "1" ]; then
    FRENCH_REFUSAL="$FRENCH_REFUSAL $label holds fr-CA.lproj, but DISTRICT_FRENCH is not set, so French is off."
  elif [ "$FRENCH_ON" = "1" ]; then
    for table in Localizable InfoPlist; do
      [ -f "$dir/fr-CA.lproj/$table.strings" ] || missing="$missing fr-CA.lproj/$table.strings"
    done
    [ -z "$missing" ] ||
      FRENCH_REFUSAL="$FRENCH_REFUSAL DISTRICT_FRENCH is on, but $label has no$missing."
  fi
}
FRENCH_REFUSAL=""
french_check "$APP_DIR" "the archived app"
for bundle in ${NESTED_BUNDLES[@]+"${NESTED_BUNDLES[@]}"}; do
  french_check "$bundle" "the archived $(bundle_label "$bundle")"
done
[ -z "$FRENCH_REFUSAL" ] || discard_archive "${FRENCH_REFUSAL# }"
if [ "$FRENCH_ON" = "1" ]; then
  echo "French ok - DISTRICT_FRENCH is on, and fr-CA.lproj holds both tables in the app and its $NESTED_COUNT nested bundles"
else
  echo "French ok - no French localization in the archived app or its $NESTED_COUNT nested bundles"
fi

# ── The Keychain groups' order ───────────────────────────────────────────────
# ⛔ THE APP'S PRIVATE GROUP MUST BE THE FIRST keychain-access-groups ENTRY IN THE
# SIGNATURE, OR THE ARCHIVE IS DISCARDED. Since 3.2 the app is entitled to a second,
# shared group that the notification service extension reads, and a Keychain item
# written without a group lands in the FIRST one listed: with the shared group first,
# one unnamed write would put the session where a second process can read it.
# KeychainTokenStore names its group on every query, and project.yml lists the private
# group first; this reads what was actually SIGNED, from the archived app, since the
# entitlements file is only the input (Xcode substitutes $(AppIdentifierPrefix) at
# signing). `codesign -d --entitlements - --xml` prints the signed entitlements as a
# property list; a signature with no readable list is refused, not passed.
PRIVATE_KEYCHAIN_GROUP="$TEAM_ID.com.distronode.district"
ENTITLEMENTS_FILE="$BUILD_DIR/DistrictAI.signed-entitlements.plist"
codesign -d --entitlements - --xml "$APP_DIR" >"$ENTITLEMENTS_FILE" 2>/dev/null ||
  discard_archive "codesign could not read the archived app's entitlements, so the Keychain group order cannot be checked."
FIRST_KEYCHAIN_GROUP="$(plutil -extract keychain-access-groups.0 raw -o - "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
rm -f "$ENTITLEMENTS_FILE"
[ "$FIRST_KEYCHAIN_GROUP" = "$PRIVATE_KEYCHAIN_GROUP" ] ||
  discard_archive "the archived app's signature lists '$FIRST_KEYCHAIN_GROUP' first in keychain-access-groups (empty means none); its private group $PRIVATE_KEYCHAIN_GROUP must come first, or a session written without a group would land in the group the notification service extension reads."
echo "Keychain ok - the archived app lists its private group $PRIVATE_KEYCHAIN_GROUP first"

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
# explicitly, on every sentry-cli command (sentry_eu below).
#
# ⛔ THE TOKEN NEVER REACHES argv. sentry-cli reads SENTRY_AUTH_TOKEN from its
# environment; --auth-token would put a live org token into `ps` output for every
# user on the machine and into this script's own log.
#
# ⚠️ BOTH SKIPS SAY SO IN ONE LINE RATHER THAN PASSING QUIETLY. A missing upload
# is invisible until somebody reads a crash report weeks later, so the absence
# gets a sentence at the moment it happens.
#
# `--include-sources` uploads a source bundle beside each dSYM, so an issue shows
# the lines around each frame and Seer can read them, not only file and line.
#
# ── The Sentry release, with its commits ─────────────────────────────────────
# After the dSYMs, the release this archive reports as gets this commit, which is
# what gives an issue its suspect commits and "fixed in release". Sentry fetches
# the range since the previous release from GitHub through its integration.
#
# ⛔ THE NAME IS READ FROM THE ARCHIVED APP, NEVER REBUILT HERE. The SDK reports
# `<CFBundleIdentifier>@<CFBundleShortVersionString>+<CFBundleVersion>` (see
# DistrictSentry.releaseName), and a name that differs by one character creates
# a second, empty release that no event ever lands in.
#
# ⚠️ NON-FATAL, UNLIKE THE dSYM UPLOAD. Without the release a crash still
# symbolicates; it only loses its commits. A failure here is a warning on the
# run, and the archive goes on to the export.
sentry_eu() { SENTRY_URL="https://de.sentry.io" sentry-cli "$@"; }
sentry_release() {
  local plist="$ARCHIVE_PATH/Products/Applications/DistrictAI.app/Info.plist"
  local identifier short build release sha
  identifier="$(plutil -extract CFBundleIdentifier raw -o - "$plist")" || return 1
  short="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" || return 1
  build="$(plutil -extract CFBundleVersion raw -o - "$plist")" || return 1
  [ -n "$identifier" ] && [ -n "$short" ] && [ -n "$build" ] || return 1
  release="$identifier@$short+$build"
  sha="$(git rev-parse HEAD)" || return 1
  echo "Sentry release: $release (commit $sha)"
  sentry_eu releases new --org "$SENTRY_ORG" --project district-ios "$release" &&
    sentry_eu releases set-commits --org "$SENTRY_ORG" "$release" \
      --commit "distronode-corporation/district-ios@$sha" --ignore-missing &&
    sentry_eu releases finalize --org "$SENTRY_ORG" "$release"
}

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "SENTRY_AUTH_TOKEN is unset - skipped the dSYM upload; crashes from this build will not symbolicate."
elif ! command -v sentry-cli >/dev/null 2>&1; then
  echo "SENTRY_AUTH_TOKEN is set but sentry-cli is not on PATH - skipped the dSYM upload; install it with: brew install getsentry/tools/sentry-cli"
else
  # ⚠️ REQUIRED RATHER THAN DEFAULTED. sentry-cli has no default org, and a wrong
  # one fails with a 404 that reads like a missing project.
  [ -n "${SENTRY_ORG:-}" ] ||
    die "SENTRY_AUTH_TOKEN is set but SENTRY_ORG is not; pass the EU org slug, there is no default."
  sentry_eu debug-files upload \
    --org "$SENTRY_ORG" \
    --project district-ios \
    --include-sources \
    "$ARCHIVE_PATH/dSYMs"
  sentry_release ||
    echo "::warning::the Sentry release for this archive was not created or has no commits; crashes still symbolicate, but carry no suspect commits."
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
