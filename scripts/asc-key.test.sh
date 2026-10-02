#!/usr/bin/env bash
#
# Harness for asc-key.sh, with a stub gsm-secret.sh in a throwaway copy of scripts/.
#
#   bash scripts/asc-key.test.sh
#
# ⚠️ NO `set -e`: some of these cases assert a refusal.
set -uo pipefail

# ⛔ HERMETIC. GITHUB_ACTIONS turns masking on, and an ambient token or secret value
# would silently become the fixture.
for _leaked in $(env 2>/dev/null | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' |
  grep -E '^(GITHUB_|GSM_|ASC_|STUB_)'); do
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
assert_not_contains() { case "$1" in *"$2"*) fail "$3 - did not expect: $2" ;; *) ok "$3" ;; esac }
assert_zero() { if [ "$1" = "0" ]; then ok "$2"; else fail "$2 - expected exit 0, got $1"; fi; }
assert_nonzero() { if [ "$1" != "0" ]; then ok "$2"; else fail "$2 - expected a non-zero exit, got 0"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
REPO="$TMPROOT/repo"
mkdir -p "$REPO/scripts"
cp "$HERE/asc-key.sh" "$REPO/scripts/asc-key.sh"
# The stub answers each secret from STUB_<NAME>, the way gsm-secret.sh prints one.
cat >"$REPO/scripts/gsm-secret.sh" <<'STUB'
#!/usr/bin/env bash
var="STUB_$1"
printf '%s' "${!var}"
STUB
chmod +x "$REPO/scripts/gsm-secret.sh"

PEM='-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg
-----END PRIVATE KEY-----'
OUT=""
RC=0
run() {
  OUT="$(cd "$TMPROOT" && env GSM_ACCESS_TOKEN=token STUB_IOS_ASC_KEY_ID=ABC123 \
    STUB_IOS_ASC_ISSUER_ID=69a6de70-0000-47e3-e053-5b8c7c11a4d1 STUB_IOS_ASC_API_KEY_P8="$PEM" \
    "$@" bash "$REPO/scripts/asc-key.sh" out 2>&1)"
  RC=$?
}

echo "asc-key.sh"

echo "1. writes the key and asc.env, relative to the caller's directory"
run
assert_zero "$RC" "it succeeds"
assert_contains "$(cat "$TMPROOT/out/AuthKey_ABC123.p8")" "MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg" "the .p8 is written"
assert_contains "$(cat "$TMPROOT/out/asc.env")" "ASC_KEY_ID=ABC123" "asc.env names the key id"
assert_contains "$(cat "$TMPROOT/out/asc.env")" "ASC_KEY_PATH=$(cd "$TMPROOT/out" && pwd)/AuthKey_ABC123.p8" "asc.env carries the absolute key path"
assert_contains "$(ls -l "$TMPROOT/out/AuthKey_ABC123.p8")" "-rw-------" "the .p8 is mode 0600"
assert_not_contains "$OUT" "::add-mask::" "nothing is masked outside GitHub Actions"
rm -rf "$TMPROOT/out"

echo "2. on GitHub Actions, the ids and every line of the .p8 are masked"
run GITHUB_ACTIONS=true
assert_zero "$RC" "it succeeds"
assert_contains "$OUT" "::add-mask::ABC123" "the key id is masked"
assert_contains "$OUT" "::add-mask::69a6de70-0000-47e3-e053-5b8c7c11a4d1" "the issuer is masked"
assert_contains "$OUT" "::add-mask::MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg" "the key body is masked"
assert_contains "$OUT" "::add-mask::-----END PRIVATE KEY-----" "the last line is masked without a newline"
rm -rf "$TMPROOT/out"

echo "3. refusals"
run GSM_ACCESS_TOKEN=
assert_nonzero "$RC" "no token is refused"
run 'STUB_IOS_ASC_KEY_ID=../../x'
assert_nonzero "$RC" "a key id that is not alphanumeric is refused"
assert_contains "$OUT" "not alphanumeric" "the message says why"
if [ -e "$TMPROOT/out/asc.env" ]; then fail "asc.env was written for a bad key id"; else ok "nothing is written for a bad key id"; fi
run "STUB_IOS_ASC_ISSUER_ID=a"$'\n'"ASC_KEY_PATH=/etc/passwd"
assert_nonzero "$RC" "an issuer that is not a UUID is refused"
assert_contains "$OUT" "issuer id is not a UUID" "the message says why"
(cd "$TMPROOT" && GSM_ACCESS_TOKEN=token bash "$REPO/scripts/asc-key.sh" >/dev/null 2>&1)
assert_nonzero "$?" "a missing directory argument is refused"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
