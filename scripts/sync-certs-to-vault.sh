#!/usr/bin/env bash
set -euo pipefail

# Sync cert-manager certificates to Vault for VSO distribution
#
# This script extracts cert-manager-managed TLS secrets from the hub cluster
# and writes them to Vault KV stores so VSO can sync them to target namespaces
# and clusters.
#
# Flow: cert-manager → K8s Secret → this script → Vault KV → VSO → K8s Secret (target)
#
# Usage:
#   ./sync-certs-to-vault.sh                    # Sync all certs
#   ./sync-certs-to-vault.sh --hub-only         # Only sync hub Vault
#   ./sync-certs-to-vault.sh --edge-only        # Only sync edge Vault
#   ./sync-certs-to-vault.sh --dry-run          # Show what would be synced

HUB_CONTEXT="${HUB_CONTEXT:-lke564853-ctx}"
EDGE_CONTEXT="${EDGE_CONTEXT:-lke566951-ctx}"
HUB_NAMESPACE="${HUB_NAMESPACE:-observability-hub}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

DRY_RUN=false
SYNC_HUB=true
SYNC_EDGE=true

for arg in "$@"; do
    case $arg in
        --dry-run)   DRY_RUN=true ;;
        --hub-only)  SYNC_EDGE=false ;;
        --edge-only) SYNC_HUB=false ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--hub-only] [--edge-only]"
            echo ""
            echo "Syncs cert-manager TLS secrets from hub K8s to Vault KV stores."
            echo "VSO then distributes them to target namespaces/clusters."
            echo ""
            echo "Environment variables:"
            echo "  HUB_CONTEXT      Hub kubectl context (default: lke564853-ctx)"
            echo "  EDGE_CONTEXT     Edge kubectl context (default: lke566951-ctx)"
            echo "  HUB_NAMESPACE    Hub observability namespace (default: observability-hub)"
            echo "  VAULT_NAMESPACE  Vault namespace (default: vault)"
            exit 0
            ;;
    esac
done

# Extract a K8s TLS secret's data as base64-decoded values
extract_secret_key() {
    local context=$1 namespace=$2 secret=$3 key=$4
    kubectl get secret "$secret" -n "$namespace" --context "$context" \
        -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d
}

# Write key-value pairs to Vault KV v2
vault_kv_put() {
    local context=$1 mount=$2 path=$3
    shift 3
    # Remaining args are key=value pairs
    if $DRY_RUN; then
        echo "  [DRY RUN] vault kv put ${mount}/${path} (${#} key-value pairs)"
        return 0
    fi
    kubectl exec -n "$VAULT_NAMESPACE" vault-0 --context "$context" -- \
        vault kv put "${mount}/${path}" "$@"
}

echo "=== Cert-Manager → Vault Sync ==="
echo ""
echo "Hub context:  $HUB_CONTEXT"
echo "Edge context: $EDGE_CONTEXT"
$DRY_RUN && echo "Mode: DRY RUN"
echo ""

# --- 1. Extract CA certificate from cert-manager CA secret ---
echo "1. Extracting CA certificate from hub cluster..."

CA_CERT=$(extract_secret_key "$HUB_CONTEXT" "cert-manager" "observability-ca-keypair" "tls.crt")
CA_KEY=$(extract_secret_key "$HUB_CONTEXT" "cert-manager" "observability-ca-keypair" "tls.key")

if [ -z "$CA_CERT" ]; then
    echo "   ERROR: Could not extract CA cert from cert-manager/observability-ca-keypair"
    echo "   Make sure the ClusterIssuer CA secret exists."
    exit 1
fi
echo "   CA cert extracted ($(echo "$CA_CERT" | wc -c) bytes)"

# --- 2. Extract edge client TLS cert ---
echo "2. Extracting edge client TLS certificate..."

CLIENT_CERT=$(extract_secret_key "$HUB_CONTEXT" "$HUB_NAMESPACE" "edge-client-tls" "tls.crt")
CLIENT_KEY=$(extract_secret_key "$HUB_CONTEXT" "$HUB_NAMESPACE" "edge-client-tls" "tls.key")

if [ -z "$CLIENT_CERT" ]; then
    echo "   ERROR: Could not extract client cert from ${HUB_NAMESPACE}/edge-client-tls"
    echo "   Make sure the cert-manager Certificate 'edge-client-tls' is issued."
    exit 1
fi
echo "   Client cert extracted ($(echo "$CLIENT_CERT" | wc -c) bytes)"

# --- 3. Sync to Hub Vault ---
if $SYNC_HUB; then
    echo ""
    echo "3. Syncing to Hub Vault (${HUB_CONTEXT})..."

    # CA cert for mTLS validation (used by gateway to verify edge clients)
    echo "   Writing observability/mtls-ca..."
    vault_kv_put "$HUB_CONTEXT" "observability" "mtls-ca" \
        "ca_crt=${CA_CERT}" \
        "ca_key=${CA_KEY}"

    # Edge client certs (backup copy on hub)
    echo "   Writing observability/edge-certs/default..."
    vault_kv_put "$HUB_CONTEXT" "observability" "edge-certs/default" \
        "tls_crt=${CLIENT_CERT}" \
        "tls_key=${CLIENT_KEY}" \
        "ca_crt=${CA_CERT}"

    echo "   Hub Vault sync complete."
fi

# --- 4. Sync to Edge Vault ---
if $SYNC_EDGE; then
    echo ""
    echo "4. Syncing to Edge Vault (${EDGE_CONTEXT})..."

    # Client TLS cert for edge agents to authenticate to hub gateway
    echo "   Writing secret/observability/client-tls..."
    vault_kv_put "$EDGE_CONTEXT" "secret" "observability/client-tls" \
        "tls_crt=${CLIENT_CERT}" \
        "tls_key=${CLIENT_KEY}" \
        "ca_crt=${CA_CERT}"

    # CA cert (for edge to verify hub gateway cert)
    echo "   Writing secret/observability/mtls-ca..."
    vault_kv_put "$EDGE_CONTEXT" "secret" "observability/mtls-ca" \
        "ca_crt=${CA_CERT}"

    echo "   Edge Vault sync complete."
fi

echo ""
echo "=== Sync Complete ==="
echo ""
echo "VSO will pick up changes within 60s (refreshAfter interval)."
echo "Monitor with:"
echo "  kubectl get vaultstaticsecret -A --context ${HUB_CONTEXT}"
echo "  kubectl get vaultstaticsecret -A --context ${EDGE_CONTEXT}"
