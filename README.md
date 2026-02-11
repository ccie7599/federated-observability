# Federated Observability Platform

Multi-cluster observability platform that collects metrics, logs, and traces from distributed LKE clusters and routes them through a central hub to internal backends and enterprise destinations.

Built on **OpenTelemetry**, **Grafana Stack** (Prometheus, Loki, Tempo, Grafana), and **Linode Kubernetes Engine (LKE)**.

## Architecture

```
 EDGE CLUSTER (fed-observability-remote)           HUB CLUSTER (fed-observability-test)
 us-ord | 2x g6-standard-2 + 1x GPU               us-ord | 3x g6-standard-4 + 1x GPU
 ──────────────────────────────────────             ──────────────────────────────────────

 ┌─────────────────────────────────┐
 │ Workloads                       │
 │  BERT Inference (GPU)           │
 │  Demo UI                        │
 └───────────┬─────────────────────┘
             │ OTLP
             ▼
 ┌─────────────────────────────────┐
 │ OTel Agent (DaemonSet, 3 pods)  │
 │  + kubeletstats (node/pod/ctr)  │
 │  + filelog receiver             │
 │  + k8s metadata enrichment      │
 │  + cluster.id label injection   │
 │                                 │
 │ OTel Scraper (Deployment)       │
 │  + BERT, DCGM, KSM scraping    │
 │                                 │
 │ kube-state-metrics              │
 │ dcgm-exporter (GPU node)        │
 └───────────┬─────────────────────┘
             │
             │ OTLP/gRPC
             │ port 4317
             │ (LoadBalancer
             │  172.238.181.107)
             │
             └──────────────────────▶┌───────────────────┐
                                     │  OTel Gateway     │◀── OTel Agent (hub, 4 pods)
                                     │  (observability-  │◀── OTel Scraper (hub)
                                     │   hub namespace)  │◀── (+ KSM, DCGM on hub)
                                     │                   │
                                     │                   │
                                     │  Processors:      │
                                     │   memory_limiter  │
                                     │   resource enrich │
                                     │   batch           │
                                     └─────────┬─────────┘
                                               │
                          ┌────────────────────┼────────────────────┐
                          │                    │                    │
                          ▼                    ▼                    ▼
                 INTERNAL BACKENDS      EXTERNAL DESTINATIONS (TODO)
                 (deployed)             (scaffolded, not yet wired)
                          │                    │
             ┌────────────┼──────────┐         ├──▶ Splunk HEC (logs)
             ▼            ▼          ▼         ├──▶ Datadog (metrics + traces)
      ┌────────────┐┌──────────┐┌────────┐    └──▶ Customer OTLP endpoint
      │ Prometheus ││   Loki   ││ Tempo  │
      │ (remote   ││  (logs)  ││(traces)│
      │  write)   ││          ││        │
      └─────┬──────┘└────┬─────┘└───┬────┘
            │            │          │
            └────────────┼──────────┘
                         ▼
                  ┌────────────┐
                  │  Grafana   │  ◀── single pane of glass
                  │  (hub UI)  │      for all clusters
                  └────────────┘
```

### Data Flow

All telemetry follows the same path regardless of origin:

```
Source (edge or hub) ──OTLP/gRPC──▶ Gateway ──▶ Prometheus (metrics)
                                            ──▶ Loki (logs)
                                            ──▶ Tempo (traces)
```

- **Edge clusters** export exclusively to the hub gateway (no local backends)
- **Hub cluster** exports exclusively through the gateway
- The gateway adds `hub.received_at` to all data; both hub and edge agents add `cluster.id` and `cluster.role`
- Buffering uses OTel persistent queues (`file_storage` extension) -- no external broker needed

### Metrics Path: OTel is the Single Source of Truth

Prometheus does **not** scrape any targets directly (except its own self-metrics). All metrics flow through OTel:

```
Workloads ──OTLP──▶ OTel Agent ──OTLP──▶ Gateway ──remote-write──▶ Prometheus
                         │                                              │
                    kubeletstats                                        │
                  (node/pod/container)                                  │
                                                                        │
BERT/DCGM/KSM ──scrape──▶ OTel Scraper ──OTLP──▶ Gateway ─────────────┘
```

The `otel-agent` (DaemonSet) collects workload telemetry via OTLP and node/pod/container metrics via the `kubeletstats` receiver (directly from local kubelet on each node). The `otel-scraper` uses OTel's `prometheus` receiver to scrape BERT inference, DCGM GPU exporter, and kube-state-metrics, then exports via OTLP to the gateway. Prometheus is configured with `--web.enable-remote-write-receiver` and only accepts incoming writes -- its only scrape config is `localhost:9090` (self-monitoring).

Every metric in Prometheus carries a `hub_received_at` label proving it passed through the gateway (except Prometheus's own `up{job="prometheus"}` self-scrape). All metrics also carry `cluster_id` and `cluster_role` labels identifying their source cluster.

### Cluster Topology

| Role | Cluster | ID | Context | Nodes |
|------|---------|-----|---------|-------|
| **Hub** | fed-observability-test | 564853 | `lke564853-ctx` | 3x g6-standard-4 + 1x GPU |
| **Edge** | fed-observability-remote | 566951 | `lke566951-ctx` | 2x g6-standard-2 + 1x GPU |

### What Runs Where

**Hub cluster (`lke564853-ctx`)**

| Namespace | Component | Type | Purpose |
|-----------|-----------|------|---------|
| observability-hub | otel-gateway | Deployment | Central ingestion + fan-out |
| observability-hub | otel-gateway-external | LoadBalancer | Edge cluster ingress (172.238.181.107) |
| observability | otel-agent | DaemonSet (4) | Hub telemetry: OTLP, kubeletstats, filelog |
| observability | otel-scraper | Deployment | Scrapes BERT, DCGM, kube-state-metrics |
| observability | kube-state-metrics | Deployment | Kubernetes object metrics (scraped by otel-scraper) |
| monitoring | prometheus | Deployment | Metrics storage (remote-write receiver only, no direct scraping) |
| monitoring | loki | StatefulSet | Log storage |
| monitoring | tempo | StatefulSet | Trace storage |
| monitoring | grafana | Deployment | 4 dashboards (BERT, Federation, GPU, K8s Resources) |
| monitoring | dcgm-exporter | DaemonSet | NVIDIA GPU metrics (scraped by otel-scraper) |
| bert-inference | bert-inference | Deployment | GPU inference workload |
| bert-inference | demo-ui | Deployment | Web frontend for BERT |
| test-app | test-app | Deployment (2) | Telemetry test endpoint |
| cert-manager | cert-manager | Deployment (3) | TLS certificate automation |
| ingress-nginx | ingress-nginx-controller | Deployment | Ingress controller (172.237.143.51) |
| vault | vault | StatefulSet (3) | Secrets management |

**Edge cluster (`lke566951-ctx`)**

| Namespace | Component | Type | Purpose |
|-----------|-----------|------|---------|
| observability | otel-agent | DaemonSet (3) | Edge telemetry: OTLP, kubeletstats, filelog → hub gateway |
| observability | otel-scraper | Deployment | Scrapes BERT, DCGM, kube-state-metrics → hub gateway |
| observability | kube-state-metrics | Deployment | Kubernetes object metrics (scraped by otel-scraper) |
| observability | dcgm-exporter | DaemonSet | NVIDIA GPU metrics (scraped by otel-scraper) |
| bert-inference | bert-inference | Deployment | GPU inference workload |
| bert-inference | demo-ui | Deployment | Web frontend for BERT |

### Grafana Dashboards

Four dashboards under the **Federated Observability** folder, all with cluster selector dropdowns:

| Dashboard | Panels | Metrics Used |
|-----------|--------|-------------|
| **BERT Inference** | 24 | `inference_*`, `DCGM_FI_DEV_*`, `container_*`, `kube_horizontalpodautoscaler_*` |
| **Federation Overview** | 18 | `up` by cluster/job, `inference_*` by cluster, `DCGM_FI_DEV_*` by cluster |
| **GPU Health** | 23 | `DCGM_FI_DEV_*` (utilization, memory, temp, power, clocks, XID errors, PCIe) |
| **Kubernetes Resources** | 23 | `k8s_node_*`, `k8s_pod_*`, `container_*`, `kube_pod_*`, `kube_deployment_*` |

### Metrics Inventory (~450 metrics)

| Source | Count | Examples |
|--------|-------|---------|
| kubeletstats | 37 | `k8s_node_cpu_utilization_ratio`, `k8s_pod_memory_working_set_bytes`, `container_cpu_utilization_ratio` |
| kube-state-metrics | 152 | `kube_pod_status_phase`, `kube_deployment_status_replicas`, `kube_daemonset_status_*` |
| DCGM | 19 | `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE` |
| BERT Inference | 10 | `inference_requests_total`, `inference_request_duration_seconds_bucket` |

## Quick Start

### Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [linode-cli](https://www.linode.com/docs/products/tools/cli/get-started/) with API token
- [kustomize](https://kustomize.io/) (optional, for overlay builds)

### Deploy from Scratch

See [deploy.md](deploy.md) for the full step-by-step deployment log with exact commands and timing.

```bash
# Hub cluster - deploy monitoring + observability + gateway
kubectl --context lke564853-ctx apply -k monitoring/
kubectl --context lke564853-ctx apply -k observability/
# Gateway deployed via kubectl apply -f (see deploy.md Phase 2)

# Edge cluster - deploy monitoring + observability + inference
kubectl --context lke566951-ctx apply -k monitoring/
kubectl --context lke566951-ctx apply -k observability/
kubectl --context lke566951-ctx apply -k inference/
```

### Access Services

```bash
# Hub Grafana (all clusters' data in one place)
kubectl --context lke564853-ctx port-forward svc/grafana -n monitoring 3000:3000
# http://localhost:3000 (admin / admin)

# Hub Prometheus
kubectl --context lke564853-ctx port-forward svc/prometheus -n monitoring 9090:9090
```

### Verify Federation

```bash
# Check edge metrics appear in hub Prometheus
kubectl --context lke564853-ctx exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{cluster_id="fed-observability-remote"}'

# Check edge logs appear in hub Loki
kubectl --context lke564853-ctx exec -n monitoring statefulset/loki -- \
  wget -qO- 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}&limit=3'
```

## Project Structure

```
federated-observability/
├── CLAUDE.md                # Project spec and architecture reference
├── deploy.md                # Deployment log with exact commands and results
├── edge-collector/          # Edge OTel agent + aggregator (Kustomize, scaffolded)
├── hub-gateway/             # Hub OTel gateway (Kustomize + overlays)
├── hub-storage/             # Message storage manifests (unused; persistent queues used instead)
├── hub-routing/             # Destination routers: Splunk, Datadog, OTLP, internal
├── hub-internal/            # Prometheus, Loki, Tempo, Grafana for hub (scaffolded)
├── monitoring/              # Prometheus, Loki, Tempo, Grafana, dcgm-exporter (deployed)
├── observability/           # OTel agent + scraper + kube-state-metrics (deployed)
├── kubernetes/edge/         # Edge-specific OTel agent and scraper configs
├── inference/               # BERT inference + NVIDIA device plugin
├── terraform/               # LKE cluster provisioning
├── vault/                   # Vault HA cluster manifests
├── policies/                # Kyverno policies (mTLS, PII, resource limits)
├── scripts/                 # Cert generation, validation, load testing
├── docs/                    # Architecture docs, runbooks, ADRs
├── tests/                   # E2E and config validation tests
└── .github/workflows/       # CI: config validation, kustomize build, kubeconform
```

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Buffering | OTel persistent queues | Built-in `file_storage` extension with retry; no external broker needed |
| Hub routing | Gateway fan-out | Single gateway exports to all backends directly (no intermediate broker) |
| Edge export | Hub-only | No local backends on edge; all telemetry sent to hub gateway |
| Metrics path | Prometheus remote-write only | No direct scraping; OTel is the single source of truth |
| Cluster ID | Resource attributes | `cluster.id` and `cluster.role` injected by all OTel agents/scrapers |
| Node metrics | kubeletstats receiver | DaemonSet agent connects to local kubelet; avoids API proxy failures |
| K8s object metrics | kube-state-metrics | Deployed per-cluster, scraped by OTel scraper for `kube_*` metrics |

## Production Hardening (TODO)

- [ ] mTLS between edge and hub (cert-manager + client certs)
- [ ] PII scrubbing at edge (OTel transform processor: email, SSN, CC, phone)
- [ ] Destination routers (Splunk HEC, Datadog API, customer OTLP)
- [ ] Loki label extraction for `cluster.id`, `service.name`
- [ ] PVC-backed persistent queues (replace emptyDir)
- [ ] HPA on gateway
- [ ] Network policies between namespaces
- [ ] External Secrets / Sealed Secrets for API keys

## Cleanup

```bash
# Delete edge cluster
linode-cli lke cluster-delete 566951

# Delete hub cluster
linode-cli lke cluster-delete 564853
```
