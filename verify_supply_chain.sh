#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./verify_supply_chain.sh <sha256-digest-without-prefix>
Example:
  ./verify_supply_chain.sh f37af7741e6ad784c456f95ac7b77f7f13fabb39d6263d72e8320ca355758b71

Environment overrides (optional):
  GHCR_REPO   (default: ghcr.io/rossgovo/secure-docker-images)
  GH_REPO     (default: rossgovo/secure-docker-images)
  WORKFLOW_RE (default: .github/workflows/.*)
EOF
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing dependency: $1" >&2; exit 127; }
}

[[ $# -ge 1 ]] || { usage; exit 2; }

DIGEST="$1"
shift || true

# Defaults (override via env vars)
GHCR_REPO="${GHCR_REPO:-ghcr.io/rossgovo/secure-docker-images}"
GH_REPO="${GH_REPO:-rossgovo/secure-docker-images}"
WORKFLOW_RE="${WORKFLOW_RE:-.github/workflows/.*}"

# Tools
need cosign
need gh
need jq

IMAGE_REF="${GHCR_REPO}@sha256:${DIGEST}"
OCI_REF="oci://${IMAGE_REF}"

echo "== Supply chain verification =="
echo "Image: ${IMAGE_REF}"
echo "Repo:  ${GH_REPO}"
echo

# --- 1) Verify cosign signature (keyless GitHub Actions identity) ---
echo "== 1) Verifying cosign signature =="

# Identity format in keyless signing is typically the workflow file path + ref.
# We keep it flexible: any workflow file in this repo, built from a tag ref.
IDENTITY_RE="https://github.com/${GH_REPO}/${WORKFLOW_RE}@refs/tags/.*"

cosign verify "${IMAGE_REF}" \
  --certificate-identity-regexp "${IDENTITY_RE}" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --output json \
  | jq .

echo "✅ cosign signature OK"
echo

# --- 2) Verify GitHub attestations (SBOM + SLSA provenance) ---
echo "== 2) Verifying GitHub attestations =="

# NOTE: Requires `gh auth login` locally with appropriate scopes.
# Prefer --repo to avoid org/user ambiguity.
echo "-- SBOM attestation (CycloneDX) --"
gh attestation verify \
  "${OCI_REF}" \
  --repo "${GH_REPO}" \
  --predicate-type "https://cyclonedx.org/bom"

echo "-- Build provenance attestation (SLSA) --"
gh attestation verify \
  "${OCI_REF}" \
  --repo "${GH_REPO}" \
  --predicate-type "https://slsa.dev/provenance/v1"
