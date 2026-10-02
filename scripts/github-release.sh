#!/usr/bin/env bash
#
# Publish a tag's GitHub Release once App Store Connect has that version on sale. The one
# place a Release is made: the `github-release` job of .github/workflows/submit.yml, after
# each submission and on its schedule, and a maintainer's backfill.
#
#   GH_TOKEN=<token> GSM_ACCESS_TOKEN=<token> TAG=v1.3 scripts/github-release.sh
#
# Run from a full-history checkout of main: the body is main's CHANGELOG.md section, which
# is final by the time a version is on sale (a tag's own copy can predate it), and the
# build number is the tag's, BUILD_NUMBER_OFFSET (default 4101) plus its commit count, as
# scripts/release-preflight.sh derives it. With ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH
# already set, GSM_ACCESS_TOKEN is not needed.
#
# The Release copies v1.2's: titled "District AI for iOS <version>", the source of the
# App Store release (build N), the App Store link, then the CHANGELOG section; no assets;
# Latest unless a published Release has a higher version.
#
# ⛔ PUBLISHED ONLY WHEN THE VERSION IS ON SALE, never at submission. Releases here are
# immutable and published once, never drafted and edited: a published one's tag can
# never move, so a Release made at submission would lock the tag before Apple's verdict
# (a fix for a rejection would need a new version) and call a version that may never
# ship an "App Store release", and Latest would leave the version people can install.
# ⛔ IDEMPOTENT: a tag that already has a Release is left alone, before any credential is
# read. Every run that publishes nothing exits 0 and says why.
set -euo pipefail

die() {
  echo "FATAL - $*" >&2
  exit 1
}

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO="${GITHUB_REPOSITORY:-distronode-corporation/district-ios}"
[[ "${TAG:-}" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]] || die "TAG '${TAG:-}' is not of the form v<version>."
VERSION="${TAG#v}"

release_exists() {
  local err
  if err="$(gh release view "$TAG" -R "$REPO" --json tagName 2>&1 >/dev/null)"; then
    return 0
  fi
  # Anything but "not found" (an expired token, a network failure) is not an answer.
  case "$err" in
    *"release not found"*) return 1 ;;
    *) die "could not ask GitHub whether $TAG has a Release: $err" ;;
  esac
}

# 1. A Release, once published, is never touched again.
if release_exists; then
  echo "$TAG: a GitHub Release already exists. Nothing was published."
  exit 0
fi

# 2. The build the tag produced, and the body, before any credential is read.
[ "$(git rev-parse --is-shallow-repository)" = "false" ] ||
  die "this is a shallow clone, so the commit count and the build number would be wrong."
git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" >/dev/null || die "there is no tag $TAG in this clone."
BUILD=$((${BUILD_NUMBER_OFFSET:-4101} + $(git rev-list --count "refs/tags/$TAG")))

umask 077
workdir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ghrel.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT
python3 scripts/asc_release.py release-body --version "$VERSION" --build "$BUILD" >"$workdir/notes.md"

# 3. Is it on sale, and with this tag's build? Read only.
if [ -z "${ASC_KEY_PATH:-}" ]; then
  [ -n "${GSM_ACCESS_TOKEN:-}" ] || die "neither ASC_KEY_PATH nor GSM_ACCESS_TOKEN is set."
  scripts/asc-key.sh "$workdir/asc"
  while IFS='=' read -r name value; do
    case "$name" in
      ASC_KEY_ID | ASC_ISSUER_ID | ASC_KEY_PATH) export "$name=$value" ;;
      *) die "unexpected line in asc.env." ;;
    esac
  done <"$workdir/asc/asc.env"
fi
unset GSM_ACCESS_TOKEN

state="" asc_build="" on_sale=""
while IFS='=' read -r name value; do
  case "$name" in
    state) state="$value" ;;
    build) asc_build="$value" ;;
    on_sale) on_sale="$value" ;;
  esac
done < <(python3 scripts/asc_release.py store-state --version "$VERSION")
[ -n "$state" ] && [ -n "$on_sale" ] || die "App Store Connect gave no state for $VERSION."

if [ "$on_sale" != "yes" ]; then
  echo "$TAG: $VERSION is $state on App Store Connect, not on sale. Nothing was published; it is published once it is."
  exit 0
fi
[ "$asc_build" = "$BUILD" ] ||
  die "$VERSION is on sale with build '${asc_build}', but $TAG builds $BUILD, so $TAG is not its source. Nothing was published."

# 4. Latest unless a published Release has a higher version.
highest="$({
  gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 1000 --json tagName --jq '.[].tagName'
  echo "$TAG"
} | sed -n 's/^v\([0-9][0-9.]*\)$/\1/p' | sort -V | tail -n 1)"
latest=false
if [ "$highest" = "$VERSION" ]; then latest=true; fi

# 5. Publish. A run that loses a race to another still ends with exactly one Release.
if ! gh release create "$TAG" -R "$REPO" --verify-tag --title "District AI for iOS $VERSION" \
  --notes-file "$workdir/notes.md" --latest="$latest"; then
  release_exists && {
    echo "$TAG: another run published its Release first. Nothing more was published."
    exit 0
  }
  die "could not publish the Release for $TAG."
fi
echo "PUBLISHED - the GitHub Release for $TAG ($VERSION, build $BUILD), latest=$latest."
