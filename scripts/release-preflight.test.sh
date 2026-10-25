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
  grep -E '^(RELEASE_|GITHUB_|ASC_|SENTRY_|HIGHEST$|MATCH$|UPLOADED$|BUILD_NUMBER_OFFSET$)'); do
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

echo "12. RELEASE_CHECK_UPLOADED refuses a build number App Store Connect already has"
# A stand-in for asc_release.py that answers highest-build from HIGHEST and
# already-uploaded from MATCH (ok, or anything else for a refusal), and appends each
# call's arguments as one line, so no credential or network is involved.
stub_asc() {
  cat >"$REPO/scripts/asc_release.py" <<'STUB'
import os, sys
with open(os.environ["ASC_ARGS"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
if sys.argv[1] == "already-uploaded":
    if os.environ.get("MATCH") == "ok":
        print("MATCH - stub")
        sys.exit(0)
    sys.exit("FATAL - stub: not this commit's build")
if os.environ.get("HIGHEST") == "fail":
    sys.exit("FATAL - stub refused")
print(os.environ["HIGHEST"])
STUB
}
new_repo 1.3
stub_asc
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main RELEASE_CHECK_UPLOADED=1 HIGHEST=4103 ASC_ARGS="$TMPROOT/args$N"
assert_zero "$RC" "4104 above 4103 is accepted"
assert_contains "$(cat "$TMPROOT/args$N")" "highest-build --version 1.3" "it asks for this version's builds"
assert_contains "$OUT" "build=4104" "the outputs are still written"
new_repo 1.3
stub_asc
(cd "$REPO" && git tag v1.3)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 RELEASE_CHECK_UPLOADED=1 HIGHEST=4104 ASC_ARGS="$TMPROOT/args$N"
assert_nonzero "$RC" "a tag of an uploaded number, not proven this commit's (no MATCH), is refused"
assert_contains "$OUT" "build 4104 of 1.3 is already in App Store Connect and is not proven" "the message names the number"
new_repo 1.3
stub_asc
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main RELEASE_CHECK_UPLOADED=1 HIGHEST=fail ASC_ARGS="$TMPROOT/args$N"
assert_nonzero "$RC" "a failed App Store Connect read is a refusal, not a pass"
new_repo 1.3
stub_asc
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main RELEASE_CHECK_UPLOADED=1 HIGHEST= ASC_ARGS="$TMPROOT/args$N"
assert_nonzero "$RC" "an empty answer is a refusal, not a pass"
new_repo 1.3
stub_asc
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main HIGHEST=9999 ASC_ARGS="$TMPROOT/args$N"
assert_zero "$RC" "without RELEASE_CHECK_UPLOADED nothing is asked"
if [ -e "$TMPROOT/args$N" ]; then fail "the stub was called without RELEASE_CHECK_UPLOADED"; else ok "the stub was not called"; fi
assert_not_contains() { case "$1" in *"$2"*) fail "$3 - did not expect: $2" ;; *) ok "$3" ;; esac }
assert_not_contains "$OUT" "uploaded=" "without RELEASE_CHECK_UPLOADED there is no uploaded line"
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main UPLOADED=yes
assert_not_contains "$OUT" "uploaded=" "an ambient UPLOADED is never taken as the answer"

echo "13. an unused number is uploaded=no"
new_repo 1.3
stub_asc
(cd "$REPO" && git tag v1.3)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 RELEASE_CHECK_UPLOADED=1 HIGHEST=4103 MATCH=ok ASC_ARGS="$TMPROOT/args$N"
assert_zero "$RC" "4104 above 4103 on a tag is accepted"
assert_contains "$OUT" "uploaded=no" "it says the build is to be uploaded"
assert_not_contains "$(cat "$TMPROOT/args$N")" "already-uploaded" "no match is asked for an unused number"

echo "14. a tag whose build is proven to be this commit's is uploaded=yes"
new_repo 1.3
stub_asc
(cd "$REPO" && git tag v1.3)
SHA="$(cd "$REPO" && git rev-parse HEAD)"
: >"$TMPROOT/out$N"
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 RELEASE_CHECK_UPLOADED=1 HIGHEST=4104 MATCH=ok ASC_ARGS="$TMPROOT/args$N" GITHUB_OUTPUT="$TMPROOT/out$N"
assert_zero "$RC" "the iMac's upload of this commit is accepted"
assert_contains "$(cat "$TMPROOT/args$N")" "already-uploaded --version 1.3 --build 4104 --commit $SHA" "it asks about this exact build and the full sha"
assert_contains "$(cat "$TMPROOT/out$N")" "uploaded=yes" "GITHUB_OUTPUT carries uploaded=yes"
assert_contains "$(cat "$TMPROOT/out$N")" "build=4104" "and the build number"
assert_contains "$OUT" "nothing will be built or uploaded" "the log says so"

echo "15. a higher number already taken, and the exact one proven, is uploaded=yes"
new_repo 1.3
stub_asc
(cd "$REPO" && git tag v1.3 && git commit -q --allow-empty -m four && git update-ref refs/remotes/origin/main HEAD && git checkout -q v1.3)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 RELEASE_CHECK_UPLOADED=1 HIGHEST=4105 MATCH=ok ASC_ARGS="$TMPROOT/args$N"
assert_zero "$RC" "a tag behind main, its own build proven, is accepted"
assert_contains "$OUT" "uploaded=yes" "it builds nothing"

echo "16. a tag whose build is not proven is refused"
new_repo 1.3
stub_asc
(cd "$REPO" && git tag v1.3)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 RELEASE_CHECK_UPLOADED=1 HIGHEST=4104 MATCH=no ASC_ARGS="$TMPROOT/args$N"
assert_nonzero "$RC" "a failed match is a refusal"
assert_contains "$OUT" "stub: not this commit's build" "the match's own reason is shown"
assert_contains "$OUT" "is not proven to be this commit's" "and the preflight says what it means"
assert_not_contains "$OUT" "uploaded=" "no outputs are written"

echo "17. a main dispatch of an uploaded number is refused, with no match asked"
new_repo 1.3
stub_asc
run RELEASE_REF_TYPE=branch RELEASE_REF_NAME=main RELEASE_CHECK_UPLOADED=1 HIGHEST=4104 MATCH=ok ASC_ARGS="$TMPROOT/args$N"
assert_nonzero "$RC" "main is never matched"
assert_contains "$OUT" "is not above 4104" "the old message"
assert_not_contains "$(cat "$TMPROOT/args$N")" "already-uploaded" "no match is asked on main"

echo "18. a commit on main that could share the number refuses the match"
# origin/main merges a side branch cut from HEAD~1: its one commit counts as many as HEAD.
new_repo 1.3
stub_asc
(
  cd "$REPO" || exit 1
  git tag v1.3
  git checkout -q -b side HEAD~1
  git commit -q --allow-empty -m side
  git checkout -q main
  git merge -q --no-ff --no-edit side
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q v1.3
)
run RELEASE_REF_TYPE=tag RELEASE_REF_NAME=v1.3 RELEASE_CHECK_UPLOADED=1 HIGHEST=4104 MATCH=ok ASC_ARGS="$TMPROOT/args$N"
assert_nonzero "$RC" "an incomparable commit on main is a refusal"
assert_contains "$OUT" "1 commit(s) on main are neither before nor after" "the message counts them"
assert_not_contains "$(cat "$TMPROOT/args$N")" "already-uploaded" "App Store Connect is not asked"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
