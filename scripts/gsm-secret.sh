#!/usr/bin/env bash
#
# Print one Google Secret Manager secret's latest version to stdout, and nothing else.
#
#   GSM_ACCESS_TOKEN=<token> scripts/gsm-secret.sh IOS_ASC_KEY_ID
#
# Used by the release workflows with the short-lived access token that
# google-github-actions/auth mints for the release service account. The caller masks
# the value (`::add-mask::`) and never echoes it.
#
# ⛔ THE TOKEN NEVER REACHES argv: curl reads its Authorization header from a config on
# stdin (`-K -`), because argv is world-readable through `ps`.
# ⛔ AN EMPTY VALUE IS A FAILURE, not an empty secret: an expired token or a wrong name
# must not turn into a blank key file or a build with no crash reporting.
set -euo pipefail

name="${1:-}"
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || {
  echo "FATAL - usage: gsm-secret.sh <SECRET_NAME>" >&2
  exit 1
}
[ -n "${GSM_ACCESS_TOKEN:-}" ] || {
  echo "FATAL - GSM_ACCESS_TOKEN is unset." >&2
  exit 1
}
project="${GSM_PROJECT:-distronode}"

response="$(printf 'header = "Authorization: Bearer %s"\n' "$GSM_ACCESS_TOKEN" |
  curl -fsS -K - --max-time 60 \
    "https://secretmanager.googleapis.com/v1/projects/${project}/secrets/${name}/versions/latest:access")" || {
  echo "FATAL - could not read secret $name from project $project." >&2
  exit 1
}

# The payload is base64 in `.payload.data`; decode it without a shell round trip.
printf '%s' "$response" | python3 -c '
import base64, json, sys
value = base64.b64decode(json.load(sys.stdin)["payload"]["data"])
if not value.strip():
    sys.exit("FATAL - secret " + sys.argv[1] + " is empty.")
sys.stdout.buffer.write(value)
' "$name"
