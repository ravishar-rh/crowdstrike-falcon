#!/usr/bin/env bash
#
# Copy the Falcon API client ID and secret from a Bitwarden entry into the
# AWS Secrets Manager secret that Terraform created.
#
# This exists so the credential never passes through Terraform state, a
# tfvars file, or your shell history. The payload is written to a mode-0600
# temp file on a trap-cleaned path and handed to the AWS CLI by reference --
# it is never an argv element, so it does not show up in `ps`.
#
# Requires: bw (logged in and unlocked), aws, jq.
#
# Usage:
#   export BW_SESSION="$(bw unlock --raw)"
#   ./scripts/bw-to-aws.sh \
#     --bw-item 'CrowdStrike Falcon API' \
#     --secret-id 'crowdstrike/falcon/api-credentials' \
#     --region eu-west-1
#
# Field resolution, in order:
#   1. custom fields named by --id-field / --secret-field
#   2. login.username / login.password
set -euo pipefail

BW_ITEM=""
SECRET_ID=""
REGION="${AWS_REGION:-eu-west-1}"
ID_FIELD="Client ID"
SECRET_FIELD="Client Secret"
DRY_RUN=false

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bw-item)      BW_ITEM="$2"; shift 2 ;;
    --secret-id)    SECRET_ID="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --id-field)     ID_FIELD="$2"; shift 2 ;;
    --secret-field) SECRET_FIELD="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage 0 ;;
    *)              die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n "$BW_ITEM"   ]] || die "--bw-item is required"
[[ -n "$SECRET_ID" ]] || die "--secret-id is required"

for bin in bw aws jq; do
  command -v "$bin" >/dev/null || die "$bin not found on PATH"
done

[[ -n "${BW_SESSION:-}" ]] || die 'BW_SESSION is not set. Run: export BW_SESSION="$(bw unlock --raw)"'

echo "==> Reading Bitwarden item: ${BW_ITEM}"
item_json="$(bw get item "$BW_ITEM" 2>/dev/null)" \
  || die "could not read Bitwarden item '${BW_ITEM}' (wrong name, or vault is locked)"

client_id="$(jq -r --arg f "$ID_FIELD" \
  'first((.fields // [])[] | select(.name == $f) | .value) // .login.username // ""' <<<"$item_json")"
client_secret="$(jq -r --arg f "$SECRET_FIELD" \
  'first((.fields // [])[] | select(.name == $f) | .value) // .login.password // ""' <<<"$item_json")"

[[ -n "$client_id" && "$client_id" != "null" ]] \
  || die "no client ID found (looked for custom field '${ID_FIELD}', then login.username)"
[[ -n "$client_secret" && "$client_secret" != "null" ]] \
  || die "no client secret found (looked for custom field '${SECRET_FIELD}', then login.password)"

# Only ever print a fingerprint, never the value.
echo "==> Found client_id ${client_id:0:6}… (${#client_id} chars), client_secret ${#client_secret} chars"

if [[ "$DRY_RUN" == true ]]; then
  echo "==> --dry-run: not writing to AWS"
  exit 0
fi

umask 077
payload_file="$(mktemp "${TMPDIR:-/tmp}/falcon-cred.XXXXXX")"
trap 'rm -f "$payload_file"' EXIT INT TERM

# Key names here must match the `property:` values in the ExternalSecret in
# acm/02-credentials/external-secrets.yaml.
jq -n --arg id "$client_id" --arg secret "$client_secret" \
  '{client_id: $id, client_secret: $secret}' >"$payload_file"

echo "==> Writing to AWS Secrets Manager: ${SECRET_ID} (${REGION})"
version_id="$(aws secretsmanager put-secret-value \
  --region "$REGION" \
  --secret-id "$SECRET_ID" \
  --secret-string "file://${payload_file}" \
  --query VersionId --output text)"

echo "==> Done. VersionId=${version_id}"
cat <<EOF

Next: ESO on the ACM hub picks this up within its refreshInterval (1h).
ACM then re-propagates the credential to every managed cluster on its own.

To pull it immediately, on the hub:

  oc annotate externalsecret falcon-api-credentials -n falcon-governance \\
    force-sync="\$(date +%s)" --overwrite

Then, if the fleet has not updated within a few minutes:

  oc annotate policy falcon-credentials -n falcon-governance \\
    policy.open-cluster-management.io/trigger-update="\$(date +%s)" --overwrite
EOF
