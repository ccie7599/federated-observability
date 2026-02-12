#!/bin/bash
# Vault Setup Script for Federated Observability Platform
# This script initializes Vault, unseals it, and configures Kubernetes auth

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG="${PROJECT_DIR}/terraform/kubeconfig"
VAULT_KEYS_FILE="${PROJECT_DIR}/vault-keys.json"

export KUBECONFIG

echo "=============================================="
echo "Vault Setup for Federated Observability"
echo "=============================================="
echo ""

# Check if vault is running
echo "1. Checking Vault pods..."
kubectl get pods -n vault -l app=vault

# Wait for all vault pods to be running
echo ""
echo "2. Waiting for Vault pods to be ready..."
kubectl wait --for=condition=ready pod -l app=vault -n vault --timeout=300s || true

# Initialize Vault on vault-0
echo ""
echo "3. Initializing Vault..."
VAULT_STATUS=$(kubectl exec -n vault vault-0 -- vault status -format=json 2>/dev/null || echo '{"initialized": false}')
INITIALIZED=$(echo "$VAULT_STATUS" | jq -r '.initialized')

if [ "$INITIALIZED" == "false" ]; then
    echo "   Vault not initialized. Initializing now..."
    INIT_OUTPUT=$(kubectl exec -n vault vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json)
    echo "$INIT_OUTPUT" > "$VAULT_KEYS_FILE"
    echo "   Vault keys saved to: $VAULT_KEYS_FILE"
    echo "   IMPORTANT: Keep this file secure!"
else
    echo "   Vault already initialized."
fi

# Unseal Vault on all pods
echo ""
echo "4. Unsealing Vault on all pods..."
if [ -f "$VAULT_KEYS_FILE" ]; then
    UNSEAL_KEYS=$(cat "$VAULT_KEYS_FILE" | jq -r '.unseal_keys_b64[0:3][]')

    for POD in vault-0 vault-1 vault-2; do
        echo "   Unsealing $POD..."
        for KEY in $UNSEAL_KEYS; do
            kubectl exec -n vault $POD -- vault operator unseal "$KEY" 2>/dev/null || true
        done
    done
else
    echo "   WARNING: Vault keys file not found at $VAULT_KEYS_FILE"
    echo "   Please manually unseal Vault using the keys from initialization."
fi

# Check Vault status
echo ""
echo "5. Checking Vault status..."
kubectl exec -n vault vault-0 -- vault status || true

# Login with root token
echo ""
echo "6. Logging into Vault..."
if [ -f "$VAULT_KEYS_FILE" ]; then
    ROOT_TOKEN=$(cat "$VAULT_KEYS_FILE" | jq -r '.root_token')
    kubectl exec -n vault vault-0 -- vault login "$ROOT_TOKEN" >/dev/null 2>&1
    echo "   Logged in successfully."
fi

# Enable Kubernetes auth
echo ""
echo "7. Configuring Kubernetes authentication..."
kubectl exec -n vault vault-0 -- vault auth enable kubernetes 2>/dev/null || echo "   Kubernetes auth already enabled."

# Configure Kubernetes auth
kubectl exec -n vault vault-0 -- sh -c '
    vault write auth/kubernetes/config \
        kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
'
echo "   Kubernetes auth configured."

# Create secrets engine for observability
echo ""
echo "8. Creating secrets for observability..."
kubectl exec -n vault vault-0 -- vault secrets enable -path=observability kv-v2 2>/dev/null || echo "   Secrets engine already enabled."

# Create placeholder secrets (to be filled with real values later)
kubectl exec -n vault vault-0 -- vault kv put observability/splunk-hec token=placeholder-splunk-token
kubectl exec -n vault vault-0 -- vault kv put observability/datadog api_key=placeholder-dd-api-key
kubectl exec -n vault vault-0 -- vault kv put observability/otlp endpoint=placeholder-otlp-endpoint

echo "   Placeholder secrets created."

# Create policy for observability secrets
echo ""
echo "9. Creating Vault policies..."
kubectl exec -n vault vault-0 -- sh -c 'vault policy write observability-read - <<EOF
path "observability/*" {
  capabilities = ["read", "list"]
}
EOF'

# Create Kubernetes auth role
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/observability \
    bound_service_account_names=otel-agent,otel-router \
    bound_service_account_namespaces=observability \
    policies=observability-read \
    ttl=1h

echo "   Policies and roles created."

# Create VSO (Vault Secrets Operator) policy and role
echo ""
echo "10. Creating VSO policy and role..."
kubectl exec -n vault vault-0 -- sh -c 'vault policy write vso-read - <<EOF
path "observability/data/*" {
  capabilities = ["read"]
}
path "observability/metadata/*" {
  capabilities = ["read", "list"]
}
EOF'

kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/vso \
    bound_service_account_names=vault-secrets-operator-controller-manager,vso-auth \
    bound_service_account_namespaces=vault-secrets-operator-system,observability,observability-hub \
    policies=vso-read \
    ttl=1h

echo "   VSO policy and role created."
echo "   Bound SAs: vault-secrets-operator-controller-manager, vso-auth"
echo "   Bound namespaces: vault-secrets-operator-system, observability, observability-hub"

# Enable audit logging
echo ""
echo "11. Enabling audit logging..."
kubectl exec -n vault vault-0 -- vault audit enable file file_path=/vault/logs/audit.log 2>/dev/null || echo "   Audit logging already enabled."

echo ""
echo "=============================================="
echo "Vault Setup Complete!"
echo "=============================================="
echo ""
echo "Vault UI is available via port-forward:"
echo "  kubectl port-forward svc/vault 8200:8200 -n vault"
echo "  Then open: http://localhost:8200"
echo ""
if [ -f "$VAULT_KEYS_FILE" ]; then
    ROOT_TOKEN=$(cat "$VAULT_KEYS_FILE" | jq -r '.root_token')
    echo "Root Token: $ROOT_TOKEN"
fi
echo ""
