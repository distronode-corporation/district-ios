#!/usr/bin/env bash
#
# Fetch the App Store Connect API key for one run. The one place the release lane reads
# it, shared by release.yml's build job and scripts/release-submit.sh.
#
#   GSM_ACCESS_TOKEN=<token> scripts/asc-key.sh <directory>
#
# Writes, under <directory> (created mode 0700, files mode 0600):
#   AuthKey_<key id>.p8   the key
#   asc.env               ASC_KEY_ID=..., ASC_ISSUER_ID=... and ASC_KEY_PATH=..., one per
#                         line, unquoted, as $GITHUB_ENV reads them
# The caller removes the directory when it is done.
#
# ⛔ ON GITHUB ACTIONS EVERY VALUE IS MASKED BEFORE ANYTHING ELSE CAN PRINT IT: the key
# id, the issuer, and each line of the .p8, because a PEM printed by a later failure
# would otherwise reach the log one unmasked line at a time.
# ⛔ The key id and the issuer are checked against their shapes before they are written
# anywhere: a newline would add a line to $GITHUB_ENV, and the key id becomes part of a
# path.
set -euo pipefail

die() {
  echo "FATAL - $*" >&2
  exit 1
}

dir="${1:-}"
[ -n "$dir" ] || die "usage: asc-key.sh <directory>"
[ -n "${GSM_ACCESS_TOKEN:-}" ] || die "GSM_ACCESS_TOKEN is unset."

umask 077
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mask() {
  if [ -n "${GITHUB_ACTIONS:-}" ] && [ -n "$1" ]; then echo "::add-mask::$1"; fi
}

key_id="$(scripts/gsm-secret.sh IOS_ASC_KEY_ID)"
mask "$key_id"
issuer="$(scripts/gsm-secret.sh IOS_ASC_ISSUER_ID)"
mask "$issuer"
[[ "$key_id" =~ ^[A-Za-z0-9]+$ ]] || die "the App Store Connect key id is not alphanumeric."
[[ "$issuer" =~ ^[A-Za-z0-9-]+$ ]] || die "the App Store Connect issuer id is not a UUID."

key_path="$dir/AuthKey_${key_id}.p8"
scripts/gsm-secret.sh IOS_ASC_API_KEY_P8 >"$key_path"
while IFS= read -r line || [ -n "$line" ]; do
  mask "$line"
done <"$key_path"

{
  echo "ASC_KEY_ID=$key_id"
  echo "ASC_ISSUER_ID=$issuer"
  echo "ASC_KEY_PATH=$key_path"
} >"$dir/asc.env"
