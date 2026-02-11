#!/bin/bash
set -e

# Vault HA Initialization Script for Raft Storage
# This script properly handles Raft-based HA clustering

echo "=== Vault Raft HA Initialization Script ==="
echo ""

# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
VAULT_POD="${VAULT_POD:-vault-0}"
NAMESPACE="${NAMESPACE:-vault}"

export VAULT_ADDR

echo "Using Vault address: $VAULT_ADDR"
echo "Using Vault pod: $VAULT_POD"
echo ""

# Function to check if Vault is initialized
check_initialized() {
    local pod=$1
    kubectl exec -n $NAMESPACE $pod -- vault status -format=json 2>/dev/null | jq -r '.initialized // false'
}

# Function to check if Vault is sealed
check_sealed() {
    local pod=$1
    kubectl exec -n $NAMESPACE $pod -- vault status -format=json 2>/dev/null | jq -r '.sealed // true'
}

# Step 1: Initialize vault-0 (Raft leader)
echo "Step 1: Initializing Raft leader (vault-0)..."
IS_INITIALIZED=$(check_initialized $VAULT_POD)

if [ "$IS_INITIALIZED" = "true" ]; then
    echo "Vault is already initialized."
    echo ""
    echo "⚠️  You need to provide the root token to continue."
    echo "If you have vault-init-keys.json, the root token is in that file."
    echo ""
    
    if [ -f "vault-init-keys.json" ]; then
        ROOT_TOKEN=$(cat vault-init-keys.json | jq -r '.root_token')
        echo "Root token loaded from vault-init-keys.json"
    else
        echo "Please enter the root token:"
        read -s ROOT_TOKEN
    fi
    
    export VAULT_TOKEN="$ROOT_TOKEN"
    echo ""
else
    echo "Initializing Vault with 5 key shares and threshold of 3..."
    
    INIT_OUTPUT=$(kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator init \
        -key-shares=5 \
        -key-threshold=3 \
        -format=json)
    
    # Save the output securely
    echo "$INIT_OUTPUT" > vault-init-keys.json
    chmod 600 vault-init-keys.json
    
    echo ""
    echo "⚠️  IMPORTANT: Vault initialization keys saved to vault-init-keys.json"
    echo "⚠️  SECURE THIS FILE IMMEDIATELY - It contains the unseal keys and root token!"
    echo "⚠️  Store in a secure location (e.g., password manager, KMS, secure vault)"
    echo ""
    
    # Extract keys for unsealing
    UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
    UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
    UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
    
    export VAULT_TOKEN="$ROOT_TOKEN"
    
    echo "Step 2: Unsealing Raft leader (vault-0)..."
    kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
    kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
    kubectl exec -n $NAMESPACE $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null
    
    echo "✓ vault-0 unsealed and active as Raft leader"
    echo ""
fi

# Wait for leader to be ready
echo "Waiting for Raft leader to be ready..."
sleep 5

# Step 3: Join vault-1 and vault-2 to the Raft cluster
echo "Step 3: Joining additional nodes to Raft cluster..."

for i in 1 2; do
    POD_NAME="vault-$i"
    echo ""
    echo "Processing $POD_NAME..."
    
    IS_INIT=$(check_initialized $POD_NAME)
    
    if [ "$IS_INIT" = "false" ]; then
        echo "  Joining $POD_NAME to Raft cluster..."
        kubectl exec -n $NAMESPACE $POD_NAME -- \
            vault operator raft join http://vault-0.vault-internal:8200
        
        echo "  ✓ $POD_NAME joined the cluster"
        
        # Now unseal it
        echo "  Unsealing $POD_NAME..."
        
        if [ -f "vault-init-keys.json" ]; then
            UNSEAL_KEY_1=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[0]')
            UNSEAL_KEY_2=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[1]')
            UNSEAL_KEY_3=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[2]')
        else
            echo "  ERROR: vault-init-keys.json not found. Cannot unseal."
            echo "  Please manually unseal $POD_NAME with: kubectl exec -n vault $POD_NAME -- vault operator unseal"
            continue
        fi
        
        kubectl exec -n $NAMESPACE $POD_NAME -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
        kubectl exec -n $NAMESPACE $POD_NAME -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
        kubectl exec -n $NAMESPACE $POD_NAME -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null
        
        echo "  ✓ $POD_NAME unsealed"
    else
        IS_SEALED=$(check_sealed $POD_NAME)
        if [ "$IS_SEALED" = "true" ]; then
            echo "  $POD_NAME is initialized but sealed. Unsealing..."
            
            if [ -f "vault-init-keys.json" ]; then
                UNSEAL_KEY_1=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[0]')
                UNSEAL_KEY_2=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[1]')
                UNSEAL_KEY_3=$(cat vault-init-keys.json | jq -r '.unseal_keys_b64[2]')
                
                kubectl exec -n $NAMESPACE $POD_NAME -- vault operator unseal "$UNSEAL_KEY_1" > /dev/null
                kubectl exec -n $NAMESPACE $POD_NAME -- vault operator unseal "$UNSEAL_KEY_2" > /dev/null
                kubectl exec -n $NAMESPACE $POD_NAME -- vault operator unseal "$UNSEAL_KEY_3" > /dev/null
                
                echo "  ✓ $POD_NAME unsealed"
            else
                echo "  ERROR: vault-init-keys.json not found. Cannot unseal."
            fi
        else
            echo "  ✓ $POD_NAME is already unsealed"
        fi
    fi
done

echo ""
echo "Step 4: Verifying Raft cluster status..."
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault operator raft list-peers

echo ""
echo "Step 5: Configuring Kubernetes auth method..."

# Enable Kubernetes auth
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault auth enable kubernetes 2>/dev/null || echo "Kubernetes auth already enabled"

# Configure Kubernetes auth
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

echo "✓ Kubernetes auth configured"
echo ""

# Step 6: Enable KV v2 secrets engines for each namespace
echo "Step 6: Enabling KV v2 secrets engines..."

kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault secrets enable -path=admin -version=2 kv 2>/dev/null || echo "admin kv already enabled"

kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault secrets enable -path=api -version=2 kv 2>/dev/null || echo "api kv already enabled"

echo "✓ Secrets engines enabled"
echo ""

# Step 7: Upload and create policies
echo "Step 7: Creating Vault policies..."

if [ ! -f "vault-policy-admin.hcl" ] || [ ! -f "vault-policy-api.hcl" ] || [ ! -f "vault-policy-operator.hcl" ]; then
    echo "⚠️  Warning: Policy files not found in current directory."
    echo "Skipping policy creation. You can create them later with:"
    echo "  cat vault-policy-admin.hcl | kubectl exec -n vault vault-0 -i -- env VAULT_TOKEN=\$VAULT_TOKEN vault policy write admin-policy -"
else
    # Admin policy
    cat vault-policy-admin.hcl | kubectl exec -n $NAMESPACE $VAULT_POD -i -- env VAULT_TOKEN=$VAULT_TOKEN \
        vault policy write admin-policy -

    # API policy
    cat vault-policy-api.hcl | kubectl exec -n $NAMESPACE $VAULT_POD -i -- env VAULT_TOKEN=$VAULT_TOKEN \
        vault policy write api-policy -

    # Operator policy
    cat vault-policy-operator.hcl | kubectl exec -n $NAMESPACE $VAULT_POD -i -- env VAULT_TOKEN=$VAULT_TOKEN \
        vault policy write operator-policy -

    echo "✓ Policies created"
fi

echo ""

# Step 8: Create Kubernetes auth roles
echo "Step 8: Creating Kubernetes auth roles..."

# Admin role (bound to specific service account)
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault write auth/kubernetes/role/admin \
    bound_service_account_names=vault-admin \
    bound_service_account_namespaces=vault \
    policies=admin-policy \
    ttl=24h

# API role (for application pods)
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault write auth/kubernetes/role/api \
    bound_service_account_names=app-vault-access \
    bound_service_account_namespaces=default,apps,production \
    policies=api-policy \
    ttl=1h

# Operator role (for SRE team)
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault write auth/kubernetes/role/operator \
    bound_service_account_names=vault-operator \
    bound_service_account_namespaces=vault \
    policies=operator-policy \
    ttl=12h

echo "✓ Kubernetes auth roles created"
echo ""

# Step 9: Enable audit logging
echo "Step 9: Enabling audit logging..."

kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault audit enable file file_path=/vault/data/vault-audit.log 2>/dev/null || echo "Audit log already enabled"

echo "✓ Audit logging enabled"
echo ""

echo "=== Vault Configuration Complete ==="
echo ""
echo "Cluster Status:"
kubectl exec -n $NAMESPACE $VAULT_POD -- env VAULT_TOKEN=$VAULT_TOKEN \
    vault status

echo ""
echo "✓ All done! Your Vault HA cluster is ready."
echo ""
echo "Important files:"
echo "  - vault-init-keys.json (SECURE THIS IMMEDIATELY!)"
echo ""
echo "Next steps:"
echo "1. Securely store vault-init-keys.json"
echo "2. Test access with different roles"
echo "3. Access Vault UI at: http://\$(kubectl -n vault get svc vault -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8200/ui"
echo ""
