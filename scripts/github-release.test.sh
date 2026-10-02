#!/usr/bin/env bash
#
# Harness for github-release.sh, run against throwaway git repositories with stand-ins
# for gh, asc-key.sh and asc_release.py's App Store Connect read. release-body is the
# real one.
#
#   bash scripts/github-release.test.sh
#
# ⚠️ NO `set -e`: half of these cases assert a refusal.
set -uo pipefail

# ⛔ HERMETIC. An ambient credential or repository name would silently become the fixture.
for _leaked in $(env 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' |
  grep -E '^(GITHUB_|ASC_|GSM_|GH_|STUB_|TAG$|BUILD_NUMBER_OFFSET$|RUNNER_TEMP$)'); do
  unset "$_leaked"
done

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
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
assert_absent() { case "$1" in *"$2"*) fail "$3 - did not expect: $2" ;; *) ok "$3" ;; esac }
assert_zero() { if [ "$1" = "0" ]; then ok "$2"; else fail "$2 - expected exit 0, got $1"; fi; }
assert_nonzero() { if [ "$1" != "0" ]; then ok "$2"; else fail "$2 - expected a non-zero exit, got 0"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
N=0
REPO=""
OUT=""
RC=0

# gh: `release view` answers from GH_EXISTS (yes, no, error, or race: no until a create
# has been tried), `release list` prints GH_RELEASES, `release create` succeeds unless
# GH_CREATE is fail or race, and copies its notes file to $GH_LOG.notes. Every call's
# arguments go to $GH_LOG.
mkdir -p "$TMPROOT/bin"
cat >"$TMPROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$1 $2" in
  "release view")
    case "$GH_EXISTS" in
      yes) exit 0 ;;
      error) echo "HTTP 401: Bad credentials" >&2; exit 1 ;;
      race) [ -e "$GH_LOG.tried" ] && exit 0 ;;
    esac
    echo "release not found" >&2
    exit 1
    ;;
  "release list") printf '%s' "${GH_RELEASES:-}" ;;
  "release create")
    touch "$GH_LOG.tried"
    while [ $# -gt 0 ]; do
      [ "$1" = "--notes-file" ] && cp "$2" "$GH_LOG.notes"
      shift
    done
    case "${GH_CREATE:-ok}" in fail | race) exit 1 ;; esac
    ;;
esac
STUB
chmod +x "$TMPROOT/bin/gh"

# A repository on main with the script, the real asc_release.py behind a stand-in that
# answers store-state from STUB_STATE (or fails when it is "fail"), an asc-key.sh that
# records its call, a CHANGELOG with a 1.3 section, three commits and the tag v1.3.
new_repo() {
  N=$((N + 1))
  REPO="$TMPROOT/repo$N"
  mkdir -p "$REPO/scripts"
  cp "$HERE/github-release.sh" "$REPO/scripts/github-release.sh"
  cp "$HERE/asc_release.py" "$REPO/scripts/asc_release_real.py"
  cat >"$REPO/scripts/asc_release.py" <<'STUB'
import os, runpy, sys
if sys.argv[1] == "store-state":
    if os.environ["STUB_STATE"] == "fail":
        sys.exit("FATAL - stub refused")
    print(os.environ["STUB_STATE"].replace("|", "\n"))
    sys.exit(0)
sys.argv[0] = os.path.join(os.path.dirname(__file__), "asc_release_real.py")
runpy.run_path(sys.argv[0], run_name="__main__")
STUB
  cat >"$REPO/scripts/asc-key.sh" <<'STUB'
#!/usr/bin/env bash
echo "asc-key $GSM_ACCESS_TOKEN" >>"$GH_LOG"
mkdir -p "$1"
printf 'ASC_KEY_ID=K\nASC_ISSUER_ID=I\nASC_KEY_PATH=%s/AuthKey_K.p8\n' "$1" >"$1/asc.env"
STUB
  chmod +x "$REPO/scripts/asc-key.sh"
  printf '# Changelog\n\n## [Unreleased]\n\n## [1.3] - 2026-10-02\n\n### Fixed\n\n- A fix that is\n  wrapped.\n\n## [1.2] - 2026-09-26\n\n- Older.\n' \
    >"$REPO/CHANGELOG.md"
  (
    cd "$REPO" || exit 1
    git init -q -b main
    git config user.email harness@example.invalid
    git config user.name harness
    git add -A && git commit -qm one
    git commit -q --allow-empty -m two
    git commit -q --allow-empty -m three
    git tag v1.3
  )
  : >"$TMPROOT/gh$N"
}

LIVE="state=READY_FOR_DISTRIBUTION|build=4104|on_sale=yes"

run() {
  OUT="$(cd "$REPO" && env PATH="$TMPROOT/bin:$PATH" GH_LOG="$TMPROOT/gh$N" GITHUB_REPOSITORY=o/r "$@" \
    bash scripts/github-release.sh 2>&1)"
  RC=$?
  LOG="$(cat "$TMPROOT/gh$N")"
}

echo "github-release.sh"

echo "1. a version on sale with this tag's build is published, as Latest"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no GH_RELEASES=$'v1.2\n' STUB_STATE="$LIVE"
assert_zero "$RC" "it succeeds"
assert_contains "$LOG" "asc-key tok" "the key is fetched with the Google token"
assert_contains "$LOG" "gh release create v1.3 -R o/r --verify-tag --title District AI for iOS 1.3" "the title and an existing tag"
assert_contains "$LOG" "--latest=true" "it is marked Latest"
NOTES="$(cat "$TMPROOT/gh$N.notes" 2>/dev/null)"
assert_contains "$NOTES" "District AI for iOS 1.3, the source of the App Store release (build 4104)." "4101 + 3 commits, from the tag"
assert_contains "$NOTES" "On the App Store: https://apps.apple.com/app/id6809297970" "the App Store link"
assert_contains "$NOTES" $'### Fixed\n\n- A fix that is wrapped.' "the CHANGELOG section as Markdown, unwrapped"
assert_absent "$NOTES" "Older." "and nothing of the next section"
assert_contains "$OUT" "PUBLISHED - the GitHub Release for v1.3" "it says so"

echo "2. a tag with a Release is left alone before any credential is read"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=yes STUB_STATE="$LIVE"
assert_zero "$RC" "it succeeds"
assert_contains "$OUT" "already exists. Nothing was published." "it says so"
assert_absent "$LOG" "asc-key" "no key is fetched"
assert_absent "$LOG" "release create" "nothing is created"

echo "3. a version not on sale yet publishes nothing and succeeds"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE="state=WAITING_FOR_REVIEW|build=4104|on_sale=no"
assert_zero "$RC" "it succeeds"
assert_contains "$OUT" "1.3 is WAITING_FOR_REVIEW on App Store Connect, not on sale" "it names the state"
assert_absent "$LOG" "release create" "nothing is created"

echo "4. a higher published version keeps Latest, compared as versions"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no GH_RELEASES=$'v1.10\nv1.2\n' STUB_STATE="$LIVE"
assert_zero "$RC" "it succeeds"
assert_contains "$LOG" "--latest=false" "1.10 is above 1.3"

echo "5. refuses a version on sale with another build"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE="state=READY_FOR_DISTRIBUTION|build=4109|on_sale=yes"
assert_nonzero "$RC" "a mismatched build is refused"
assert_contains "$OUT" "on sale with build '4109', but v1.3 builds 4104" "the message names both"
assert_absent "$LOG" "release create" "nothing is created"

echo "6. an unreadable GitHub or App Store Connect is a refusal, not a pass"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=error STUB_STATE="$LIVE"
assert_nonzero "$RC" "a failed release view is refused"
assert_contains "$OUT" "Bad credentials" "the message carries gh's"
assert_absent "$LOG" "asc-key" "no key is fetched"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE=fail
assert_nonzero "$RC" "a failed store-state is refused"
assert_absent "$LOG" "release create" "nothing is created"

echo "7. a run that loses the race to another succeeds; a failed create does not"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=race GH_CREATE=race STUB_STATE="$LIVE"
assert_zero "$RC" "the other run's Release counts"
assert_contains "$OUT" "another run published its Release first" "it says so"
new_repo
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no GH_CREATE=fail STUB_STATE="$LIVE"
assert_nonzero "$RC" "a failed create with no Release is refused"

echo "8. a key already in the environment is used as is"
new_repo
run TAG=v1.3 ASC_KEY_PATH=/k ASC_KEY_ID=K ASC_ISSUER_ID=I GH_EXISTS=no STUB_STATE="$LIVE"
assert_zero "$RC" "it succeeds"
assert_absent "$LOG" "asc-key" "no key is fetched"

echo "9. refuses bad input before App Store Connect"
new_repo
run 'TAG=v1.3; echo pwned' GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE="$LIVE"
assert_nonzero "$RC" "a malformed tag is refused"
assert_contains "$OUT" "is not of the form" "the message says why"
new_repo
run TAG=v1.4 GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE="$LIVE"
assert_nonzero "$RC" "a tag not in the clone is refused"
assert_contains "$OUT" "there is no tag v1.4" "the message says why"
new_repo
(cd "$REPO" && git tag v1.5)
run TAG=v1.5 GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE="$LIVE"
assert_nonzero "$RC" "a version with no CHANGELOG section is refused"
assert_absent "$LOG" "asc-key" "before the key is fetched"
new_repo
run TAG=v1.3 GH_EXISTS=no STUB_STATE="$LIVE"
assert_nonzero "$RC" "no credential at all is refused"
assert_contains "$OUT" "neither ASC_KEY_PATH nor GSM_ACCESS_TOKEN" "the message says why"

echo "10. refuses a shallow clone"
new_repo
SRC="$REPO"
REPO="$TMPROOT/shallow$N"
git clone -q --depth 1 "file://$SRC" "$REPO"
(cd "$REPO" && git fetch -q --depth 1 origin tag v1.3)
run TAG=v1.3 GSM_ACCESS_TOKEN=tok GH_EXISTS=no STUB_STATE="$LIVE"
assert_nonzero "$RC" "a shallow clone is refused"
assert_contains "$OUT" "shallow clone" "the message says why"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
