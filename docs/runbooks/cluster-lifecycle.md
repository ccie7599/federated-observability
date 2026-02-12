# Runbook: Cluster Lifecycle (Build + Teardown)

Builds the federated observability test environment from scratch and tears it down cleanly. Matches the current live topology: 1 hub cluster + 1 edge cluster in us-ord.

**Total build time:** ~30-40 minutes (includes GPU node provisioning, Vault init, cert-manager issuance, VSO sync)
**Total teardown time:** ~5 minutes

---

## Cluster Topology

| Role | Label | Region | Nodes | Purpose |
|------|-------|--------|-------|---------|
| Hub | `fed-observability-test` | us-ord | 3x g6-standard-4 + 1x g2-gpu-rtx4000a1-s | Gateway, monitoring stack, Grafana, Vault |
| Edge | `fed-observability-remote` | us-ord | 2x g6-standard-2 + 1x g2-gpu-rtx4000a1-s | BERT inference, OTel agents exporting to hub |

---

## Prerequisites

```bash
# Required CLI tools
linode-cli --version        # Linode CLI (configured with API token)
kubectl version --client    # kubectl
helm version                # Helm 3
terraform version           # Terraform >= 1.0
jq --version                # jq (for Vault key parsing)

# Verify Linode API access
linode-cli account view

# Helm repos (add once)
helm repo add jetstack https://charts.jetstack.io
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

---

## Part 1: Build

### Step 1 — Provision Hub Cluster via Terraform (~3 min)

```bash
cd terraform

# Initialize (first time only)
terraform init

# Create the hub cluster + firewall
terraform apply -auto-approve
```

This creates:
- LKE cluster `fed-observability-test` (3x g6-standard-4 + 1x GPU)
- Cloud Firewall allowing SSH/HTTP/HTTPS/K8s API/NodePorts from `47.224.104.170` only
- Kubeconfig saved to `terraform/kubeconfig`

Save the cluster ID from output:

```bash
HUB_ID=$(terraform output -raw cluster_id)
echo "Hub cluster ID: $HUB_ID"
```

Merge kubeconfig:

```bash
KUBECONFIG=~/.kube/config:terraform/kubeconfig kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config
HUB_CTX="lke${HUB_ID}-ctx"
```

Wait for all nodes including GPU (~150s for GPU node):

```bash
kubectl --context $HUB_CTX get nodes -w
# Wait until all 4 nodes show Ready
```

Label the GPU node (LKE does not auto-label GPU nodes):

```bash
GPU_NODE=$(kubectl --context $HUB_CTX get nodes -o name | while read n; do
  kubectl --context $HUB_CTX get "$n" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null | grep -q 1 && echo "$n"
done)
kubectl --context $HUB_CTX label $GPU_NODE nvidia.com/gpu.present=true
```

### Step 2 — Provision Edge Cluster via Linode CLI (~3 min)

```bash
linode-cli lke cluster-create \
  --label fed-observability-remote \
  --region us-ord \
  --k8s_version 1.33 \
  --tags "observability" --tags "edge" --tags "remote" \
  --node_pools '[
    {"type":"g6-standard-2","count":2,"autoscaler":{"enabled":true,"min":2,"max":4}},
    {"type":"g2-gpu-rtx4000a1-s","count":1,"autoscaler":{"enabled":true,"min":1,"max":2}}
  ]'
```

Save the cluster ID from output and merge kubeconfig:

```bash
EDGE_ID=<from output>
linode-cli lke kubeconfig-view $EDGE_ID --text --no-headers | base64 -d > /tmp/edge-kubeconfig.yaml
KUBECONFIG=~/.kube/config:/tmp/edge-kubeconfig.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config
EDGE_CTX="lke${EDGE_ID}-ctx"
```

Wait for nodes and label the GPU node:

```bash
kubectl --context $EDGE_CTX get nodes -w
# Wait until all 3 nodes show Ready

GPU_NODE=$(kubectl --context $EDGE_CTX get nodes -o name | while read n; do
  kubectl --context $EDGE_CTX get "$n" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null | grep -q 1 && echo "$n"
done)
kubectl --context $EDGE_CTX label $GPU_NODE nvidia.com/gpu.present=true
```

### Step 3 — Deploy Hub Monitoring Stack (~2 min)

Prometheus, Loki, Tempo, Grafana, DCGM exporter:

```bash
kubectl --context $HUB_CTX apply -k hub/monitoring/
```

Wait for all pods:

```bash
kubectl --context $HUB_CTX get pods -n monitoring -w
# Wait until all pods are Running/Ready
```

### Step 4 — Deploy Hub OTel Agents + Scraper (~1 min)

```bash
kubectl --context $HUB_CTX apply -k hub/observability/
```

Verify agent DaemonSet matches node count (4 pods — 3 standard + 1 GPU):

```bash
kubectl --context $HUB_CTX get ds otel-agent -n observability
```

### Step 5 — Deploy Vault on Hub (~5 min)

```bash
# Deploy Vault StatefulSet (3-pod Raft HA)
kubectl --context $HUB_CTX apply -k examples/vault/

# Wait for pods to start (they will be 0/1 Running — not yet initialized)
kubectl --context $HUB_CTX get pods -n vault -w
```

Run the automated setup script:

```bash
./examples/vault/vault-setup.sh
```

This initializes vault-0, unseals all 3 pods, joins Raft, creates the `observability` KV-v2 mount, configures K8s auth, creates VSO policy/role, and enables audit logging.

**Save `vault-keys.json` securely.** Contains unseal keys and root token.

### Step 6 — Install cert-manager + Bootstrap CA (~2 min)

```bash
# Install cert-manager on hub
helm install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --context $HUB_CTX
```

Bootstrap the internal CA for mTLS:

```bash
# Generate self-signed CA (10-year validity)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256 -days 3650 -nodes \
  -keyout /tmp/ca.key -out /tmp/ca.crt \
  -subj "/CN=Observability mTLS CA/O=Federated Observability"

# Create CA secret in cert-manager namespace
kubectl --context $HUB_CTX create secret tls observability-ca-keypair \
  -n cert-manager --cert=/tmp/ca.crt --key=/tmp/ca.key

# Deploy CA ClusterIssuer
kubectl --context $HUB_CTX apply -f hub/gateway/cert-manager/cluster-issuer.yaml
```

### Step 7 — Issue Certificates (~1 min)

Issue gateway server cert and edge client cert:

```bash
kubectl --context $HUB_CTX apply -f hub/gateway/cert-manager/gateway-cert.yaml
kubectl --context $HUB_CTX apply -f hub/gateway/cert-manager/edge-client-cert.yaml
```

> **Note:** `gateway-cert.yaml` contains a hardcoded `ipAddresses` field with the previous gateway LoadBalancer IP. If the IP changes, update the cert before applying. You can also remove the IP SAN and rely on DNS names only.

Verify both certs are issued:

```bash
kubectl --context $HUB_CTX get certificate -n observability-hub
# NAME              READY   SECRET            AGE
# gateway-tls       True    gateway-tls       30s
# edge-client-cert  True    edge-client-tls   30s
```

### Step 8 — Sync Certs to Vault (~1 min)

Push cert-manager certificates to both hub and edge Vault:

```bash
# Set context variables for the sync script
export HUB_CONTEXT=$HUB_CTX
export EDGE_CONTEXT=$EDGE_CTX

./scripts/sync-certs-to-vault.sh
```

> **Prerequisite:** Edge Vault must be running and unsealed before syncing (see Step 11). If building sequentially, run `--hub-only` now and `--edge-only` after Step 11.

### Step 9 — Install VSO + Apply Hub VSO CRDs (~2 min)

```bash
# Install Vault Secrets Operator on hub
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator-system --create-namespace --context $HUB_CTX

# Apply VSO CRDs for all three hub namespaces
kubectl --context $HUB_CTX apply -k hub/vault-secrets-operator/
kubectl --context $HUB_CTX apply -k hub/observability/vault-secrets-operator/
kubectl --context $HUB_CTX apply -k hub/monitoring/vault-secrets-operator/
```

Verify secrets sync (may take up to 60s):

```bash
kubectl --context $HUB_CTX get vaultstaticsecret -A
# NAMESPACE          NAME              AGE
# monitoring         grafana-tls       30s
# observability      hub-client-tls    30s
# observability-hub  client-ca         30s
```

### Step 10 — Deploy Hub Gateway with mTLS (~1 min)

```bash
kubectl --context $HUB_CTX apply -k hub/gateway/
```

Get the gateway's external IP (edge clusters need this):

```bash
kubectl --context $HUB_CTX get svc otel-gateway-external -n observability-hub -w
# Wait for EXTERNAL-IP assignment
GATEWAY_IP=$(kubectl --context $HUB_CTX get svc otel-gateway-external -n observability-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway IP: $GATEWAY_IP"
```

Verify gateway health:

```bash
kubectl --context $HUB_CTX exec -n observability-hub deploy/otel-gateway -- \
  wget -qO- http://localhost:13133 2>/dev/null
```

### Step 11 — Deploy Vault on Edge (~5 min)

```bash
kubectl --context $EDGE_CTX apply -k examples/vault/
kubectl --context $EDGE_CTX get pods -n vault -w
```

Initialize and configure edge Vault:

```bash
# Initialize edge vault-0
kubectl --context $EDGE_CTX exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > /tmp/edge-vault-keys.json

# Unseal all 3 pods
for POD in vault-0 vault-1 vault-2; do
  for KEY in $(jq -r '.unseal_keys_b64[0:3][]' /tmp/edge-vault-keys.json); do
    kubectl --context $EDGE_CTX exec -n vault $POD -- vault operator unseal "$KEY" 2>/dev/null || true
  done
done

# Join vault-1 and vault-2 to Raft
for POD in vault-1 vault-2; do
  kubectl --context $EDGE_CTX exec -n vault $POD -- vault operator raft join http://vault-0.vault-internal:8200
done

EDGE_ROOT_TOKEN=$(jq -r '.root_token' /tmp/edge-vault-keys.json)

# Enable KV v2 engine (edge uses 'secret' mount, not 'observability')
kubectl --context $EDGE_CTX exec -n vault vault-0 -- sh -c \
  "export VAULT_TOKEN=$EDGE_ROOT_TOKEN && vault secrets enable -version=2 -path=secret kv"

# Enable K8s auth
kubectl --context $EDGE_CTX exec -n vault vault-0 -- sh -c \
  "export VAULT_TOKEN=$EDGE_ROOT_TOKEN && \
   vault auth enable kubernetes && \
   vault write auth/kubernetes/config kubernetes_host=\"https://\$KUBERNETES_PORT_443_TCP_ADDR:443\""

# Create VSO policy and role
kubectl --context $EDGE_CTX exec -n vault vault-0 -- sh -c "export VAULT_TOKEN=$EDGE_ROOT_TOKEN && \
  vault policy write vso-read - <<EOF
path \"secret/data/observability/*\" { capabilities = [\"read\"] }
path \"secret/metadata/observability/*\" { capabilities = [\"read\", \"list\"] }
EOF"

kubectl --context $EDGE_CTX exec -n vault vault-0 -- sh -c "export VAULT_TOKEN=$EDGE_ROOT_TOKEN && \
  vault write auth/kubernetes/role/vso \
    bound_service_account_names=vault-secrets-operator-controller-manager,vso-auth \
    bound_service_account_namespaces=vault-secrets-operator-system,observability \
    policies=vso-read ttl=1h"

# Enable audit logging
kubectl --context $EDGE_CTX exec -n vault vault-0 -- sh -c "export VAULT_TOKEN=$EDGE_ROOT_TOKEN && \
  vault audit enable file file_path=/vault/logs/audit.log"
```

**Save `/tmp/edge-vault-keys.json` securely.**

### Step 12 — Sync Certs to Edge Vault + Install Edge VSO (~2 min)

If you skipped edge sync in Step 8, run it now:

```bash
export HUB_CONTEXT=$HUB_CTX
export EDGE_CONTEXT=$EDGE_CTX
./scripts/sync-certs-to-vault.sh --edge-only
```

Install VSO and apply edge CRDs:

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  -n vault-secrets-operator-system --create-namespace --context $EDGE_CTX

kubectl --context $EDGE_CTX apply -k edge/vault-secrets-operator/
```

Verify the `otel-client-tls` secret syncs:

```bash
kubectl --context $EDGE_CTX get vaultstaticsecret -n observability
# NAME              AGE
# otel-client-tls   30s

kubectl --context $EDGE_CTX get secret otel-client-tls -n observability
# NAME              TYPE     DATA   AGE
# otel-client-tls   Opaque   3      30s   (keys: ca.crt, tls.crt, tls.key)
```

### Step 13 — Deploy Edge Agents + Scrapers (~2 min)

Update the edge configs with the correct gateway IP if it changed:

```bash
# Check current gateway IP in edge configs
grep -n "endpoint:" edge/agent-config.yaml edge/scraper-config.yaml
# Should show $GATEWAY_IP:4317 — update if needed
```

Deploy edge observability stack:

```bash
# Namespace, RBAC, kube-state-metrics (reuse hub manifests)
kubectl --context $EDGE_CTX apply -f hub/observability/namespace.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/agent/rbac.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/scraper/rbac.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/kube-state-metrics.yaml

# Edge-specific configs (point to hub gateway with mTLS)
kubectl --context $EDGE_CTX apply -f edge/agent-config.yaml
kubectl --context $EDGE_CTX apply -f edge/scraper-config.yaml

# DaemonSet and scraper (same manifests as hub, different config)
kubectl --context $EDGE_CTX apply -f hub/observability/agent/daemonset.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/scraper/deployment.yaml
```

### Step 14 — Deploy BERT Inference Demo (Both Clusters) (~3 min)

```bash
# Hub — BERT + NVIDIA device plugin + ingress
kubectl --context $HUB_CTX apply -k examples/inference/

# Edge — same deployment
kubectl --context $EDGE_CTX apply -k examples/inference/
```

Deploy DCGM exporter for GPU metrics on edge:

```bash
kubectl --context $EDGE_CTX apply -f hub/monitoring/dcgm-exporter.yaml
```

BERT pods will be Pending until the GPU node is ready and labeled (done in Steps 1-2).

### Step 15 — Deploy DNS + Let's Encrypt Ingress (Optional)

If using `connected-cloud.io` DNS:

```bash
# Get hub and edge nginx ingress IPs
HUB_NGINX_IP=$(kubectl --context $HUB_CTX get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
EDGE_NGINX_IP=$(kubectl --context $EDGE_CTX get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

# Create DNS records via Akamai Edge DNS
akamai dns create-recordset connected-cloud.io \
  --name bert-hub.connected-cloud.io --type A --ttl 300 --rdata $HUB_NGINX_IP
akamai dns create-recordset connected-cloud.io \
  --name bert-remote.connected-cloud.io --type A --ttl 300 --rdata $EDGE_NGINX_IP
akamai dns create-recordset connected-cloud.io \
  --name obs.connected-cloud.io --type A --ttl 300 --rdata $HUB_NGINX_IP

# Deploy Let's Encrypt issuers on both clusters
kubectl --context $HUB_CTX apply -f examples/inference/letsencrypt-issuer.yaml
kubectl --context $EDGE_CTX apply -f examples/inference/letsencrypt-issuer.yaml

# Deploy ingress resources
kubectl --context $HUB_CTX apply -f examples/inference/bert-ingress.yaml
kubectl --context $HUB_CTX apply -f examples/inference/demo-ingress.yaml
kubectl --context $EDGE_CTX apply -f examples/inference/edge-bert-ingress.yaml
kubectl --context $EDGE_CTX apply -f examples/inference/edge-demo-ingress.yaml
```

### Step 16 — Verify End-to-End

```bash
# All hub pods running
kubectl --context $HUB_CTX get pods -A | grep -E "monitoring|observability|vault|bert"

# All edge pods running
kubectl --context $EDGE_CTX get pods -A | grep -E "observability|vault|bert"

# VSO secrets synced on both clusters
kubectl --context $HUB_CTX get vaultstaticsecret -A
kubectl --context $EDGE_CTX get vaultstaticsecret -A

# Gateway health
kubectl --context $HUB_CTX exec -n observability-hub deploy/otel-gateway -- \
  wget -qO- http://localhost:13133 2>/dev/null

# Metrics flowing from both clusters
kubectl --context $HUB_CTX exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(count+by+(cluster_id)(up{cluster_id!=""}))' 2>/dev/null \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(f'Clusters reporting: {r[0][\"value\"][1]}' if r else 'No clusters found')"

# Edge metrics specifically
kubectl --context $HUB_CTX exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{cluster_id="fed-observability-remote"}' 2>/dev/null \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(f'Edge targets: {len(r)}')"

# GPU metrics from both clusters
kubectl --context $HUB_CTX exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(DCGM_FI_DEV_GPU_UTIL)+by+(cluster_id)' 2>/dev/null \
  | python3 -c "import sys,json; [print(f'{r[\"metric\"][\"cluster_id\"]}: {r[\"value\"][1]} GPUs') for r in json.load(sys.stdin)['data']['result']]"

# Open Grafana
echo "Grafana: kubectl --context $HUB_CTX port-forward svc/grafana -n monitoring 3000:3000"
echo "Then open http://localhost:3000 (admin/admin)"
```

---

## Part 2: Teardown

### Option A — Full Teardown (Destroy Both Clusters)

This deletes everything — clusters, nodes, LoadBalancers, firewalls. Non-reversible.

#### 1. Delete Edge Cluster

```bash
# Get edge cluster ID
EDGE_ID=$(linode-cli lke clusters-list --label fed-observability-remote --json | jq -r '.[0].id')

# Delete the cluster
linode-cli lke cluster-delete $EDGE_ID

echo "Edge cluster $EDGE_ID deleted"
```

#### 2. Delete Hub Cluster via Terraform

```bash
cd terraform
terraform destroy -auto-approve
cd ..
```

#### 3. Clean Up Local State

```bash
# Remove merged kubeconfig contexts
kubectl config delete-context $HUB_CTX 2>/dev/null || true
kubectl config delete-context $EDGE_CTX 2>/dev/null || true

# Remove Terraform local files
rm -rf terraform/.terraform terraform/kubeconfig terraform/.terraform.lock.hcl

# Remove Vault keys (ONLY after confirming clusters are gone)
rm -f vault-keys.json /tmp/edge-vault-keys.json

# Remove temp CA files
rm -f /tmp/ca.key /tmp/ca.crt /tmp/edge-kubeconfig.yaml
```

#### 4. Clean Up DNS Records (if created)

```bash
akamai dns delete-recordset connected-cloud.io --name bert-hub.connected-cloud.io --type A
akamai dns delete-recordset connected-cloud.io --name bert-remote.connected-cloud.io --type A
akamai dns delete-recordset connected-cloud.io --name obs.connected-cloud.io --type A
```

#### 5. Verify Teardown

```bash
# Confirm no LKE clusters remain
linode-cli lke clusters-list --json | jq '.[].label'

# Confirm no orphaned NodeBalancers (LoadBalancer services create these)
linode-cli nodebalancers list --json | jq '.[] | {id, label, region}'

# Confirm no orphaned firewalls
linode-cli firewalls list --json | jq '.[] | {id, label, status}'
```

> **Note:** LKE automatically cleans up NodeBalancers created by LoadBalancer Services when the cluster is deleted. If any remain, delete manually:
> ```bash
> linode-cli nodebalancers delete <ID>
> ```

### Option B — Teardown Workloads Only (Keep Clusters)

Use this to reset workloads without reprovisioning clusters.

```bash
# --- Edge cluster ---
kubectl --context $EDGE_CTX delete -k edge/vault-secrets-operator/ --ignore-not-found
kubectl --context $EDGE_CTX delete -f hub/observability/agent/daemonset.yaml --ignore-not-found
kubectl --context $EDGE_CTX delete -f hub/observability/scraper/deployment.yaml --ignore-not-found
kubectl --context $EDGE_CTX delete -f hub/observability/kube-state-metrics.yaml --ignore-not-found
kubectl --context $EDGE_CTX delete -f edge/agent-config.yaml --ignore-not-found
kubectl --context $EDGE_CTX delete -f edge/scraper-config.yaml --ignore-not-found
kubectl --context $EDGE_CTX delete -k examples/inference/ --ignore-not-found
kubectl --context $EDGE_CTX delete -k examples/vault/ --ignore-not-found
helm uninstall vault-secrets-operator -n vault-secrets-operator-system --kube-context $EDGE_CTX 2>/dev/null || true

# --- Hub cluster ---
kubectl --context $HUB_CTX delete -k hub/gateway/ --ignore-not-found
kubectl --context $HUB_CTX delete -k hub/vault-secrets-operator/ --ignore-not-found
kubectl --context $HUB_CTX delete -k hub/observability/vault-secrets-operator/ --ignore-not-found
kubectl --context $HUB_CTX delete -k hub/monitoring/vault-secrets-operator/ --ignore-not-found
kubectl --context $HUB_CTX delete -k hub/observability/ --ignore-not-found
kubectl --context $HUB_CTX delete -k hub/monitoring/ --ignore-not-found
kubectl --context $HUB_CTX delete -k examples/inference/ --ignore-not-found
kubectl --context $HUB_CTX delete -k examples/vault/ --ignore-not-found
kubectl --context $HUB_CTX delete -f hub/gateway/cert-manager/gateway-cert.yaml --ignore-not-found
kubectl --context $HUB_CTX delete -f hub/gateway/cert-manager/edge-client-cert.yaml --ignore-not-found
kubectl --context $HUB_CTX delete -f hub/gateway/cert-manager/cluster-issuer.yaml --ignore-not-found
kubectl --context $HUB_CTX delete secret observability-ca-keypair -n cert-manager --ignore-not-found
helm uninstall vault-secrets-operator -n vault-secrets-operator-system --kube-context $HUB_CTX 2>/dev/null || true
helm uninstall cert-manager -n cert-manager --kube-context $HUB_CTX 2>/dev/null || true

# Clean up namespaces
for NS in observability-hub observability monitoring vault vault-secrets-operator-system cert-manager bert-inference; do
  kubectl --context $HUB_CTX delete namespace $NS --ignore-not-found &
  kubectl --context $EDGE_CTX delete namespace $NS --ignore-not-found &
done
wait
```

---

## Timing Reference

| Step | Duration | Notes |
|------|----------|-------|
| Hub cluster provision (Terraform) | ~3 min | GPU node takes longest |
| Edge cluster provision (linode-cli) | ~3 min | GPU node takes longest |
| Hub monitoring stack | ~2 min | Prometheus, Loki, Tempo, Grafana |
| Hub observability agents | ~1 min | DaemonSet + scraper |
| Hub Vault init + setup | ~5 min | 3-pod Raft, K8s auth, policies |
| cert-manager + CA bootstrap | ~2 min | Helm install + CA secret + issuer |
| Certificate issuance | ~1 min | Gateway server + edge client certs |
| Cert sync to Vault | ~1 min | Hub + edge Vault writes |
| VSO install + hub CRDs | ~2 min | 3 namespace installations |
| Hub gateway deploy | ~1 min | mTLS-enabled, 3 replicas |
| Edge Vault init + setup | ~5 min | Same as hub Vault |
| Edge VSO + cert sync | ~2 min | Helm install + CRDs |
| Edge agents + scrapers | ~2 min | RBAC, configs, DaemonSet |
| BERT inference (both) | ~3 min | GPU image pull is slow |
| DNS + ingress (optional) | ~2 min | Akamai Edge DNS + Let's Encrypt |
| Verification | ~2 min | Prometheus queries, gateway health |
| **Total build** | **~35 min** | |
| **Full teardown** | **~5 min** | |
