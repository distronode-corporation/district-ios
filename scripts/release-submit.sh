#!/usr/bin/env bash
#
# Submit an uploaded build for App Review. The one submission path: the job of
# .github/workflows/submit.yml, which release.yml's `submit` job also calls.
#
#   GSM_ACCESS_TOKEN=<token> VERSION=1.3 BUILD=4110 scripts/release-submit.sh
#
# submit.yml runs this only after the maintainers' explicit approval; it does not check
# that itself, because the workflow is where the approval is given.
#
# Fetches the App Store Connect key for this run only with scripts/asc-key.sh (mode 0600,
# masked, under a temporary directory removed on exit), then runs `asc_release.py
# submit`, which waits for the build to be VALID, sets the release notes from
# CHANGELOG.md, attaches the build and submits it, doing only what is not already done.
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

scripts/asc-key.sh "$workdir"
unset GSM_ACCESS_TOKEN
while IFS='=' read -r name value; do
  case "$name" in
    ASC_KEY_ID | ASC_ISSUER_ID | ASC_KEY_PATH) export "$name=$value" ;;
    *) die "unexpected line in asc.env." ;;
  esac
done <"$workdir/asc.env"

python3 scripts/asc_release.py submit --version "$VERSION" --build "$BUILD"
