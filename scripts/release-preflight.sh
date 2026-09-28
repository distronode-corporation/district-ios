#!/usr/bin/env bash
#
# Decide what a release run builds, and refuse a ref that must not be released.
#
#   RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 scripts/release-preflight.sh
#
# Called first by .github/workflows/release.yml and submit.yml. The ref defaults to the
# run's own (GITHUB_REF_TYPE, GITHUB_REF_NAME); submit.yml runs on main and passes the tag
# it was asked to submit instead.
#
# Prints, and appends to $GITHUB_OUTPUT when it is set:
#   version=<MARKETING_VERSION from project.yml>
#   build=<BUILD_NUMBER_OFFSET (default 4101) + git rev-list --count HEAD>
#   kind=tag|main
#
# Refuses:
#   - a shallow clone. `git rev-list --count` on one answers the depth (1), not the
#     history, and the build number would collide with one App Store Connect has seen;
#   - a tag that is not v<MARKETING_VERSION>, because a build attaches only to the
#     App Store version record whose string equals its CFBundleShortVersionString;
#   - a tag whose commit is not on main;
#   - a branch other than main.
set -euo pipefail

die() {
  echo "FATAL - $*" >&2
  exit 1
}

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REF_TYPE="${RELEASE_REF_TYPE:-${GITHUB_REF_TYPE:-}}"
REF_NAME="${RELEASE_REF_NAME:-${GITHUB_REF_NAME:-}}"

[ "$(git rev-parse --is-shallow-repository)" = "false" ] ||
  die "this is a shallow clone, so the commit count and the build number would be wrong. Check out with fetch-depth: 0."

# Exactly one MARKETING_VERSION line, quoted, as project.yml writes it.
versions="$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' project.yml)"
[ -n "$versions" ] || die "no MARKETING_VERSION in project.yml."
[ "$(printf '%s\n' "$versions" | wc -l | tr -d ' ')" = "1" ] ||
  die "more than one MARKETING_VERSION in project.yml; expected exactly one."
VERSION="$versions"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "MARKETING_VERSION '$VERSION' is not a version number."

COUNT="$(git rev-list --count HEAD)"
BUILD=$((${BUILD_NUMBER_OFFSET:-4101} + COUNT))

case "$REF_TYPE" in
  tag)
    [[ "$REF_NAME" =~ ^v[0-9]+(\.[0-9]+){1,2}$ ]] || die "tag '$REF_NAME' is not of the form v<version>."
    [ "${REF_NAME#v}" = "$VERSION" ] ||
      die "tag '$REF_NAME' does not match MARKETING_VERSION '$VERSION' in project.yml at that commit. Nothing was built."
    git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null ||
      die "origin/main is not in this clone, so the tag cannot be checked against it."
    git merge-base --is-ancestor HEAD refs/remotes/origin/main ||
      die "tag '$REF_NAME' points at a commit that is not on main. Nothing was built."
    KIND=tag
    ;;
  branch)
    [ "$REF_NAME" = "main" ] || die "branch '$REF_NAME' is not main. Releases run from main or a v* tag only."
    KIND=main
    ;;
  *)
    die "unknown ref type '$REF_TYPE' (expected tag or branch)."
    ;;
esac

out="version=$VERSION
build=$BUILD
kind=$KIND"
printf '%s\n' "$out"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf '%s\n' "$out" >>"$GITHUB_OUTPUT"
fi
