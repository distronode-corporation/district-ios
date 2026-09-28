#!/usr/bin/env bash
#
# Harness for release-preflight.sh, run against throwaway git repositories.
#
#   bash scripts/release-preflight.test.sh
#
# ⚠️ NO `set -e`: half of these cases assert a refusal.
set -uo pipefail

# ⛔ HERMETIC. The script falls back to GITHUB_REF_TYPE / GITHUB_REF_NAME, which are set
# in every Actions job, so an ambient value would silently become the fixture.
for _leaked in $(env 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' |
  grep -E '^(RELEASE_|GITHUB_|BUILD_NUMBER_OFFSET$)'); do
  unset "$_leaked"
done

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/release-preflight.sh"
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
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) fail "$3 - expected to find: $2 (got: $1)" ;; esac }
assert_zero() { if [ "$1" = "0" ]; then ok "$2"; else fail "$2 - expected exit 0, got $1"; fi; }
assert_nonzero() { if [ "$1" != "0" ]; then ok "$2"; else fail "$2 - expected a non-zero exit, got 0"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
N=0
REPO=""
OUT=""
RC=0

# A repository with the script, a project.yml at VERSION, and three commits on main,
# origin/main pointing at the tip.
new_repo() {
  N=$((N + 1))
  REPO="$TMPROOT/repo$N"
  mkdir -p "$REPO/scripts"
  cp "$SCRIPT" "$REPO/scripts/release-preflight.sh"
  (
    cd "$REPO" || exit 1
    git init -q -b main
    git config user.email harness@example.invalid
    git config user.name harness
    printf 'targets:\n  App:\n    settings:\n      base:\n        MARKETING_VERSION: "%s"\n' "$1" >project.yml
    git add -A && git commit -qm one
    git commit -q --allow-empty -m two
    git commit -q --allow-empty -m three
    git update-ref refs/remotes/origin/main HEAD
  )
}

run() {
  OUT="$(cd "$REPO" && env "$@" bash scripts/release-preflight.sh 2>&1)"
  RC=$?
}

echo "release-preflight.sh"

echo "1. main: the build number is 4101 plus the commit count"
new_repo 1.3
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main
assert_zero "$RC" "main is accepted"
assert_contains "$OUT" "version=1.3" "it reads MARKETING_VERSION"
assert_contains "$OUT" "build=4104" "4101 + 3 commits"
assert_contains "$OUT" "kind=main" "it names the kind"

echo "2. GITHUB_OUTPUT is written, and the GITHUB_ ref is the default"
new_repo 1.3
: >"$TMPROOT/out$N"
run GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_OUTPUT="$TMPROOT/out$N"
assert_zero "$RC" "the run's own ref is used when RELEASE_ is unset"
assert_contains "$(cat "$TMPROOT/out$N")" "build=4104" "GITHUB_OUTPUT carries the build number"

echo "3. BUILD_NUMBER_OFFSET replaces the offset"
new_repo 1.3
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main BUILD_NUMBER_OFFSET=10
assert_contains "$OUT" "build=13" "10 + 3"

echo "4. refuses a branch other than main"
new_repo 1.3
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=feature
assert_nonzero "$RC" "a side branch is refused"
assert_contains "$OUT" "'feature' is not main" "the message names the branch"

echo "5. a tag matching MARKETING_VERSION on main is accepted"
new_repo 1.3
(cd "$REPO" && git tag v1.3)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3
assert_zero "$RC" "v1.3 at 1.3 on main is accepted"
assert_contains "$OUT" "kind=tag" "it names the kind"

echo "6. refuses a tag that does not match MARKETING_VERSION"
new_repo 1.3
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.4
assert_nonzero "$RC" "v1.4 at 1.3 is refused"
assert_contains "$OUT" "does not match MARKETING_VERSION '1.3'" "the message names both"

echo "7. refuses a malformed tag"
new_repo 1.3
run RELEASE_REF_TYPE=tag 'RELEASE_REF_NAME=v1.3; echo pwned'
assert_nonzero "$RC" "a tag that is not v<version> is refused"
assert_contains "$OUT" "is not of the form" "the message says why"

echo "8. refuses a tag whose commit is not on main"
new_repo 1.3
(
  cd "$REPO" || exit 1
  git checkout -q -b side
  git commit -q --allow-empty -m side
)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3
assert_nonzero "$RC" "a commit off main is refused"
assert_contains "$OUT" "not on main" "the message says why"

echo "9. refuses when origin/main is missing"
new_repo 1.3
(cd "$REPO" && git update-ref -d refs/remotes/origin/main)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3
assert_nonzero "$RC" "no origin/main is refused rather than assumed"
assert_contains "$OUT" "origin/main is not in this clone" "the message says why"

echo "10. refuses a shallow clone"
new_repo 1.3
SRC="$REPO"
REPO="$TMPROOT/shallow$N"
git clone -q --depth 1 "file://$SRC" "$REPO"
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main
assert_nonzero "$RC" "a shallow clone is refused"
assert_contains "$OUT" "shallow clone" "the message says why"

echo "11. refuses an unknown ref type and a missing or duplicated MARKETING_VERSION"
new_repo 1.3
run RELEASE_REF_TYPE=pull RELEASE_REF_NAME=main
assert_nonzero "$RC" "an unknown ref type is refused"
new_repo 1.3
(cd "$REPO" && printf 'x: 1\n' >project.yml && git commit -qam none)
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main
assert_nonzero "$RC" "no MARKETING_VERSION is refused"
new_repo 1.3
(cd "$REPO" && printf '        MARKETING_VERSION: "1.4"\n' >>project.yml && git commit -qam two)
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main
assert_nonzero "$RC" "two MARKETING_VERSION lines are refused"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
