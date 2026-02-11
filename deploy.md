# Federated Observability - Deployment Log

## Cluster Topology

| Role | Cluster Name | ID | Region | kubectl Context | Nodes |
|------|-------------|-----|--------|-----------------|-------|
| **Hub** | fed-observability-test | 564853 | us-ord | `lke564853-ctx` | 3x g6-standard-4 + 1x g2-gpu-rtx4000a1-s |
| **Edge (Remote)** | fed-observability-remote | 566951 | us-ord | `lke566951-ctx` | 2x g6-standard-2 + 1x g2-gpu-rtx4000a1-s |

---

## Phase 1: Create Remote Edge Cluster

**Date:** 2026-02-10

### 1.1 Create LKE Cluster

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

**Result:** Cluster ID 566951 created.

| Pool ID | Type | Count | Autoscale |
|---------|------|-------|-----------|
| 827928 | g6-standard-2 | 2 | 2-4 |
| 827929 | g2-gpu-rtx4000a1-s | 1 | 1-2 |

### 1.2 Kubeconfig Setup

```bash
linode-cli lke kubeconfig-view 566951 --text --no-headers | base64 -d > /tmp/fed-obs-remote-kubeconfig.yaml
KUBECONFIG=~/.kube/config:/tmp/fed-obs-remote-kubeconfig.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config
```

Kubeconfig available after ~60s. Context: `lke566951-ctx`

### 1.3 Node Readiness

Standard nodes ready within ~90s. GPU node takes longer (~5 min for provisioning).

| Node | Type | Status | External IP |
|------|------|--------|-------------|
| lke566951-827928-042382fb0000 | g6-standard-2 | Ready | 172.234.212.235 |
| lke566951-827928-1575bbd80000 | g6-standard-2 | Ready | 172.234.212.233 |
| lke566951-827929-53ba7dcc0000 | g2-gpu-rtx4000a1-s | Ready (~150s) | TBD |

### 1.4 Deploy Workloads

#### 1.4.1 BERT Inference + NVIDIA Plugin

```bash
kubectl --context lke566951-ctx apply -k inference/
```

Deploys: namespace, nvidia-device-plugin DaemonSet, BERT deployment, demo UI, service, HPA.
BERT pod stays Pending until GPU node joins.

#### 1.4.2 Local Monitoring Stack

```bash
kubectl --context lke566951-ctx apply -k monitoring/
# Fix: Grafana needs dashboard-providers configmap (not in kustomization)
kubectl --context lke564853-ctx get configmap grafana-dashboard-providers -n monitoring -o yaml | \
  kubectl --context lke566951-ctx apply -f -
```

Deploys: Prometheus, Loki, Tempo, Grafana (same single-cluster monitoring stack as hub).

**Note:** Missing `grafana-dashboard-providers` ConfigMap caused Grafana to fail mounting volumes. Fixed by copying from hub cluster. This should be added to the monitoring kustomization.yaml.

**TODO:** Add `grafana-dashboard-providers` to `monitoring/kustomization.yaml` so future deploys don't need the manual copy step.

#### 1.4.3 OTel Agent + Scraper

```bash
kubectl --context lke566951-ctx apply -k observability/
kubectl --context lke566951-ctx apply -f observability/scraper/config.yaml \
  -f observability/scraper/deployment.yaml
```

Deploys: OTel Agent DaemonSet (2 pods on standard nodes), OTel Scraper for BERT/DCGM metrics.

**Initial agent behavior:** Exports directly to local Prometheus/Loki/Tempo (single-cluster mode).
Agent started with transient connection errors to Tempo (gRPC 4317) and Loki (3100) during monitoring stack startup - resolved within ~60s as pods became ready.

### 1.5 Deployment Status (Standard Nodes)

| Namespace | Pod | Status | Notes |
|-----------|-----|--------|-------|
| bert-inference | bert-inference-* | Running (0/1) | GPU image pulled in ~75s; model loading (~1-2min for readiness) |
| bert-inference | demo-ui-* | Running | nginx frontend |
| monitoring | grafana-* | Running | After dashboard-providers fix |
| monitoring | loki-0 | Running | |
| monitoring | prometheus-* | Running | |
| monitoring | tempo-0 | Running | |
| observability | otel-agent (x3) | Running | DaemonSet on all 3 nodes (incl GPU) |
| observability | otel-scraper-* | Running | Prometheus receiver for BERT/DCGM |

### 1.6 GPU Node Setup

GPU node (g2-gpu-rtx4000a1-s) joined Kubernetes ~150s after cluster creation.

**Required manual step:** The GPU node did not automatically get the `nvidia.com/gpu.present=true` label that the BERT deployment's nodeSelector requires. The NVIDIA device plugin runs on the node but doesn't add this label by default on LKE.

```bash
kubectl --context lke566951-ctx label node lke566951-827929-53ba7dcc0000 nvidia.com/gpu.present=true
```

After labeling, BERT pod moved from Pending → ContainerCreating (pulling the ~5GB GPU image).

**Sequence:** GPU node Ready → NVIDIA plugin schedules → Label node → BERT schedules → OTel agent schedules (3rd pod)

### 1.7 External Services (Remote Cluster)

| Service | External IP | Port |
|---------|-------------|------|
| BERT Inference LB | 172.238.178.182 | 80 |

Grafana on remote is ClusterIP only. To access:
```bash
kubectl --context lke566951-ctx port-forward svc/grafana -n monitoring 3001:3000
# Then browse http://localhost:3001
```

### 1.8 Phase 1 Complete

**Total time:** ~7 minutes from cluster creation to all pods running.

| Step | Duration |
|------|----------|
| Cluster creation API call | instant |
| Kubeconfig available | ~60s |
| Standard nodes Ready | ~90s |
| GPU node Ready | ~150s |
| All workloads deployed | ~180s |
| BERT image pulled + running | ~75s after GPU node |
| **Total** | **~5-6 min** |

---

## Phase 2: Deploy Hub Components

**Date:** 2026-02-10

### 2.1 Architecture Decision: Persistent Queues over Redpanda

Initially attempted Redpanda as a Kafka-compatible message buffer between gateway and routers. Encountered:
- ConfigMap mounting issues (Redpanda couldn't find config file)
- Command-line config workarounds needed (`rpk redpanda start` vs `redpanda start`)
- Operational complexity too high for dev environment

**Decision:** Replaced Redpanda with OTel Collector's built-in persistent queues (`file_storage` extension). Each exporter gets its own file-backed queue with retry logic. Simpler, fewer moving parts, sufficient durability for the use case.

### 2.2 Create Namespace

```bash
kubectl --context lke564853-ctx create namespace observability-hub
```

### 2.3 Deploy OTel Gateway

The gateway receives OTLP from all sources (hub agent, hub scraper, edge clusters) and fans out directly to backends with persistent queues per exporter.

**Config:** Gateway fans out to 3 backends:
- `prometheusremotewrite` → Prometheus (metrics)
- `loki` → Loki (logs)
- `otlp/tempo` → Tempo (traces, with file_storage persistent queue)

```bash
# Apply gateway config, deployment, and services
kubectl --context lke564853-ctx apply -f - <<EOF
# ConfigMap with fan-out config (see hub-gateway/overlays/dev/gateway-config-patch.yaml)
# Deployment with init container for queue dirs + emptyDir volume
# ClusterIP service (4317, 4318, 13133)
# LoadBalancer service for external access (4317, 4318)
EOF
```

**Key details:**
- Init container creates `/var/otel/queue/compaction` with `chmod 777` (OTel runs as non-root)
- `emptyDir` volume (5Gi) for persistent queue storage
- `resource` processor adds `hub.received_at` label with gateway pod name
- External LoadBalancer IP: `172.238.181.107`

**Troubleshooting encountered:**
1. `prometheusremotewrite` exporter doesn't support `sending_queue` → removed, uses built-in retry
2. `file_storage` extension requires compaction directory to exist → added init container
3. Compaction directory permission denied → added `chmod -R 777` to init container
4. WAL for prometheusremotewrite spammed "not found" errors on empty WAL → removed WAL, retry alone is sufficient for dev

### 2.4 Rewire Hub Agent Through Gateway

Changed hub's OTel agent (DaemonSet) and scraper to export through the gateway instead of directly to Prometheus/Loki/Tempo.

**Before:** Agent → Prometheus/Loki/Tempo (direct)
**After:** Agent → Gateway (OTLP gRPC) → Prometheus/Loki/Tempo

```bash
# Update agent config: replace prometheusremotewrite/loki/otlp exporters with single otlp/gateway
kubectl --context lke564853-ctx apply -f - # (otel-agent-config ConfigMap)
kubectl --context lke564853-ctx apply -f - # (otel-scraper-config ConfigMap)
kubectl --context lke564853-ctx rollout restart daemonset/otel-agent -n observability
kubectl --context lke564853-ctx rollout restart deployment/otel-scraper -n observability
```

**Verification:** Prometheus query `up` shows `hub_received_at="otel-gateway-..."` label on all metrics, confirming data flows through gateway.

### 2.5 Hub Deployment Status

| Namespace | Resource | Status | Notes |
|-----------|----------|--------|-------|
| observability-hub | otel-gateway (Deployment) | Running | 1 replica, fan-out to 3 backends |
| observability-hub | otel-gateway (ClusterIP) | Active | 4317, 4318, 13133 |
| observability-hub | otel-gateway-external (LB) | Active | 172.238.181.107 |
| observability | otel-agent (DaemonSet, 4 pods) | Running | Exports via gateway |
| observability | otel-scraper (Deployment) | Running | Exports via gateway |

---

## Phase 3: Connect Edge to Hub

**Date:** 2026-02-10

### 3.1 Edge Agent Rewiring

Configured edge cluster's OTel agent and scraper to export exclusively to the hub gateway.

Added resource attributes for cluster identification:
- `cluster.id: fed-observability-remote`
- `cluster.role: edge`

```bash
kubectl --context lke566951-ctx apply -f - # (otel-agent-config ConfigMap)
kubectl --context lke566951-ctx apply -f - # (otel-scraper-config ConfigMap)
kubectl --context lke566951-ctx rollout restart daemonset/otel-agent -n observability
kubectl --context lke566951-ctx rollout restart deployment/otel-scraper -n observability
```

### 3.2 Remove Edge Local Monitoring Stack

Removed the local Prometheus/Loki/Tempo/Grafana stack from the edge cluster. All telemetry is centralized on the hub — no need to duplicate storage and compute on every edge cluster.

```bash
kubectl --context lke566951-ctx delete deployment grafana prometheus -n monitoring
kubectl --context lke566951-ctx delete statefulset loki tempo -n monitoring
kubectl --context lke566951-ctx delete svc grafana loki tempo prometheus -n monitoring
kubectl --context lke566951-ctx delete configmap --all -n monitoring
```

### 3.3 End-to-End Verification

**Metrics:** Hub Prometheus shows edge metrics with labels:
- `cluster_id="fed-observability-remote"`
- `cluster_role="edge"`
- `hub_received_at="otel-gateway-..."`

Query: `up{cluster_id="fed-observability-remote"}` returns metrics from all 3 edge nodes (2x g6-standard-2, 1x GPU) plus BERT inference.

**Logs:** Hub Loki receives edge logs via OTLP. Log bodies contain resource attributes including `cluster.id` and `hub.received_at`.

**Traces:** Edge traces forwarded to hub Tempo via gateway.

### 3.4 Current Data Flow

```
Edge Cluster (lke566951-ctx)
  ├── otel-agent (DaemonSet, 3 pods) → hub gateway 172.238.181.107:4317
  └── otel-scraper (Deployment)      → hub gateway 172.238.181.107:4317

Hub Cluster (lke564853-ctx)
  ├── otel-agent (DaemonSet, 4 pods) → gateway (OTLP gRPC)
  ├── otel-scraper (Deployment)      → gateway (OTLP gRPC)
  └── otel-gateway (observability-hub)
      ├── → prometheusremotewrite → Prometheus
      ├── → loki → Loki
      └── → otlp/tempo → Tempo (with persistent queue)
```

---

## Phase 4: Production Hardening (TODO)

1. **mTLS:** Add cert-manager, generate client certs for edge clusters, enable TLS on gateway
2. **PII scrubbing:** Deploy edge aggregator between agent and hub (transform processor for email/SSN/CC/phone redaction)
3. **Destination routers:** Add Splunk HEC, Datadog, customer OTLP routers as additional gateway exporters
4. **Loki labels:** Configure `resource_attributes` in loki exporter for cluster.id, service.name, etc.
5. **Persistent storage:** Replace emptyDir with PVC for gateway queue volume
6. **HPA:** Add horizontal pod autoscaler to gateway
7. **Network policies:** Restrict traffic flows between namespaces

---

## Quick Reference

```bash
# Switch to hub cluster
kubectl config use-context lke564853-ctx

# Switch to remote edge cluster
kubectl config use-context lke566951-ctx

# Check all pods on hub
kubectl --context lke564853-ctx get pods -A

# Check all pods on remote
kubectl --context lke566951-ctx get pods -A

# Check gateway status
kubectl --context lke564853-ctx get pods -n observability-hub
kubectl --context lke564853-ctx logs -n observability-hub deployment/otel-gateway --tail=20

# Check OTel agent logs on hub
kubectl --context lke564853-ctx logs -n observability daemonset/otel-agent --tail=20

# Check OTel agent logs on remote
kubectl --context lke566951-ctx logs -n observability daemonset/otel-agent --tail=20

# Query hub Prometheus for edge metrics
kubectl --context lke564853-ctx exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{cluster_id="fed-observability-remote"}'

# Query hub Loki for edge logs
kubectl --context lke564853-ctx exec -n monitoring statefulset/loki -- \
  wget -qO- 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}&limit=5'

# Port-forward hub Grafana (single pane of glass for all clusters)
kubectl --context lke564853-ctx port-forward svc/grafana -n monitoring 3000:3000

# Gateway external IP (for edge → hub)
kubectl --context lke564853-ctx get svc otel-gateway-external -n observability-hub

# Delete remote cluster (when done)
linode-cli lke cluster-delete 566951
```
