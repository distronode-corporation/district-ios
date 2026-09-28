#!/usr/bin/env bash
#
# Submit an uploaded build for App Review. The one submission path, shared by the
# `submit` job of .github/workflows/release.yml and by .github/workflows/submit.yml.
#
#   GSM_ACCESS_TOKEN=<token> VERSION=1.3 BUILD=4110 scripts/release-submit.sh
#
# Both workflows run this only after the maintainers' explicit approval; it does not
# check that itself, because the workflows are where the approval is given.
#
# Fetches the App Store Connect key for this run only (mode 0600, under a temporary
# directory removed on exit), then runs `asc_release.py submit`, which waits for the
# build to be VALID, sets the release notes from CHANGELOG.md, attaches the build and
# submits it, doing only what is not already done.
set -euo pipefail

die() {
  echo "FATAL - $*" >&2
  exit 1
}

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ "${VERSION:-}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "VERSION '${VERSION:-}' is not a version number."
[[ "${BUILD:-}" =~ ^[0-9]+$ ]] || die "BUILD '${BUILD:-}' is not a build number."
[ -n "${GSM_ACCESS_TOKEN:-}" ] || die "GSM_ACCESS_TOKEN is unset."

# Fail before touching App Store Connect if the release notes are missing.
python3 scripts/asc_release.py whats-new --version "$VERSION" >/dev/null

umask 077
workdir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/asc.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

ASC_KEY_ID="$(scripts/gsm-secret.sh IOS_ASC_KEY_ID)"
ASC_ISSUER_ID="$(scripts/gsm-secret.sh IOS_ASC_ISSUER_ID)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::add-mask::$ASC_KEY_ID"
  echo "::add-mask::$ASC_ISSUER_ID"
fi
ASC_KEY_PATH="$workdir/AuthKey_${ASC_KEY_ID}.p8"
scripts/gsm-secret.sh IOS_ASC_API_KEY_P8 >"$ASC_KEY_PATH"
unset GSM_ACCESS_TOKEN
export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH

python3 scripts/asc_release.py submit --version "$VERSION" --build "$BUILD"
