#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./create_vex.sh CVE-YYYY-NNNNN \
    --image-repo "ghcr.io/OWNER/REPO" \
    --trivy-json "trivy.json" \
    --status "not_affected" \
    --justification "vulnerable_code_not_in_execute_path" \
    --comment "Reason here" \
    [--out vex.openvex.json] \
    [--author "name"] \
    [--vex-id "https://..."]

Notes:
- Requires: jq
- Writes an OpenVEX file with a statement scoped to your OCI image + subcomponents.
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi

CVE="$1"; shift

TRIVY_JSON="trivy.json"
OUT="vex.openvex.json"
IMAGE_REPO=""
STATUS="not_affected"
JUSTIFICATION="vulnerable_code_not_in_execute_path"
COMMENT=""
AUTHOR="${USER:-unknown}"
VEX_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --trivy-json) TRIVY_JSON="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --image-repo) IMAGE_REPO="$2"; shift 2 ;;
    --status) STATUS="$2"; shift 2 ;;
    --justification) JUSTIFICATION="$2"; shift 2 ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --vex-id) VEX_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$IMAGE_REPO" ]]; then
  echo "ERROR: --image-repo is required (e.g. ghcr.io/rossgovo/secure-docker-images)" >&2
  exit 1
fi

if [[ ! -f "$TRIVY_JSON" ]]; then
  echo "ERROR: Trivy JSON not found: $TRIVY_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

PURLS_RAW="$(
  jq -r --arg cve "$CVE" '
    .Results[]?
    | .Vulnerabilities[]?
    | select(.VulnerabilityID == $cve)
    | (.PkgIdentifier.PURL // empty)
  ' "$TRIVY_JSON" | sort -u
)"

if [[ -z "$PURLS_RAW" ]]; then
  echo "ERROR: No PURLs found for $CVE in $TRIVY_JSON" >&2
  exit 1
fi

# Build product @id in the format Trivy examples use: pkg:oci/<name>?repository_url=<urlencoded>
# Derive <name> from repo name (after last /)
IMAGE_NAME="${IMAGE_REPO##*/}"
REPO_URL_ENC="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${IMAGE_REPO}", safe=""))
PY
)"
PRODUCT_ID="pkg:oci/${IMAGE_NAME}?repository_url=${REPO_URL_ENC}"

# Default VEX @id if not provided
if [[ -z "$VEX_ID" ]]; then
  VEX_ID="https://${IMAGE_REPO}/vex/${CVE}"
fi

TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Build the new statement JSON
STATEMENT_JSON="$(jq -n \
  --arg cve "$CVE" \
  --arg product "$PRODUCT_ID" \
  --arg status "$STATUS" \
  --arg justification "$JUSTIFICATION" \
  --arg comment "$COMMENT" \
  --arg timestamp "$TIMESTAMP" \
  --arg author "$AUTHOR" \
  --arg vexid "$VEX_ID" \
  --argjson subs "$(printf '%s\n' "$PURLS_RAW" | jq -R . | jq -s 'map(select(length>0) | {"@id": .})')" \
  '{
    "@context": "https://openvex.dev/ns/v0.2.0",
    "@id": $vexid,
    "author": $author,
    "timestamp": $timestamp,
    "version": 1,
    "statements": [
      {
        "vulnerability": {"name": $cve},
        "products": [
          {
            "@id": $product,
            "subcomponents": $subs
          }
        ],
        "status": $status,
        "justification": $justification,
        "action_statement": $comment
      }
    ]
  }'
)"

# If OUT exists, merge by replacing/adding statement for same CVE, preserving others.
if [[ -f "$OUT" ]]; then
  TMP="$(mktemp)"
  jq --arg cve "$CVE" --argjson new "$(echo "$STATEMENT_JSON" | jq '.statements[0]')" '
    .statements = (
      ([.statements[] | select(.vulnerability.name != $cve)] + [$new])
    )
    | .timestamp = (now | todateiso8601)
  ' "$OUT" > "$TMP"

  # Ensure top-level keys exist (if OUT had different shape)
  jq -s '
    (.[0] // {}) as $old
    | (.[1] // {}) as $updated
    | $old
    | .["@context"] = "https://openvex.dev/ns/v0.2.0"
    | .version = 1
    | .statements = $updated.statements
    | .author = ($old.author // $updated.author)
    | .["@id"] = ($old["@id"] // $updated["@id"])
    | .timestamp = $updated.timestamp
  ' "$OUT" "$TMP" > "${TMP}.2"

  mv "${TMP}.2" "$OUT"
  rm -f "$TMP"
else
  echo "$STATEMENT_JSON" > "$OUT"
fi

echo "✅ Wrote/updated $OUT for $CVE"
echo "   Product: $PRODUCT_ID"
echo "   Subcomponents:"
printf '   - %s\n' $PURLS_RAW
