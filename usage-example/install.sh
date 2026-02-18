#!/usr/bin/env bash
set -euo pipefail

# ---------------------------
# Config (override via env)
# ---------------------------
CLUSTER_NAME="${CLUSTER_NAME:-secure-lab}"
KIND_CONFIG="${KIND_CONFIG:-kind-cluster.yaml}"
KYVERNO_NAMESPACE="${KYVERNO_NAMESPACE:-kyverno}"
KYVERNO_RELEASE="${KYVERNO_RELEASE:-kyverno}"
KYVERNO_CHART="${KYVERNO_CHART:-kyverno/kyverno}"

# Policy files
POLICY_MUTATE="${POLICY_MUTATE:-mutate-tags.yaml}"
POLICY_SIG="${POLICY_SIG:-require-sig.yaml}"
POLICY_PROV="${POLICY_PROV:-require-provenance.yaml}"

# ---------------------------
# Helpers
# ---------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing dependency: $1" >&2
    exit 127
  }
}

info()  { echo -e "\033[1;34m[info]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[ok]\033[0m   $*"; }
warn()  { echo -e "\033[1;33m[warn]\033[0m $*"; }
err()   { echo -e "\033[1;31m[err]\033[0m  $*"; }

require_file() {
  [[ -f "$1" ]] || { err "Required file not found: $1"; exit 2; }
}

use_context() {
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
}

# ---------------------------
# Pre-flight checks
# ---------------------------
need kind
need kubectl
need helm

require_file "$KIND_CONFIG"
require_file "$POLICY_MUTATE"
require_file "$POLICY_SIG"
require_file "$POLICY_PROV"

# ---------------------------
# Create / verify cluster
# ---------------------------
info "Ensuring kind cluster exists: ${CLUSTER_NAME}"

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  ok "Cluster already exists"
else
  info "Creating cluster from config: ${KIND_CONFIG}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
  ok "Cluster created"
fi

use_context
info "Cluster info:"
kubectl cluster-info

# Wait for core components to be ready
info "Waiting for nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
ok "Nodes are Ready"

# ---------------------------
# Install Kyverno
# ---------------------------
info "Installing/Upgrading Kyverno via Helm..."

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null

if helm -n "${KYVERNO_NAMESPACE}" status "${KYVERNO_RELEASE}" >/dev/null 2>&1; then
  info "Kyverno already installed, upgrading..."
else
  info "Kyverno not installed, installing..."
fi

helm upgrade --install "${KYVERNO_RELEASE}" "${KYVERNO_CHART}" \
  -n "${KYVERNO_NAMESPACE}" --create-namespace \
  --wait --timeout 5m

ok "Kyverno installed"

info "Waiting for Kyverno pods to be Ready..."
kubectl -n "${KYVERNO_NAMESPACE}" wait --for=condition=Ready pod --all --timeout=300s
ok "Kyverno pods are Ready"

# ---------------------------
# Apply policies
# ---------------------------
info "Applying Kyverno policies..."
kubectl apply -f "${POLICY_MUTATE}"
kubectl apply -f "${POLICY_SIG}"
kubectl apply -f "${POLICY_PROV}"
ok "Policies applied"


info "Policy status:"
kubectl get cpol

