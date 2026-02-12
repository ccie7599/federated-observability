# Federated Observability on LKE

A reference architecture for multi-cluster, multi-region observability on Akamai Cloud (Linode Kubernetes Engine) using OpenTelemetry and the Grafana stack.

## What This Is

This repo implements a **hub-and-spoke** observability platform where:

- A **hub cluster** runs the central monitoring stack (Prometheus, Loki, Tempo, Grafana) and an OTel gateway that ingests telemetry from all clusters
- **Edge clusters** run OTel agents that collect metrics, traces, and logs from every node and application, then forward everything to the hub over OTLP/gRPC
- Any application on any cluster can emit telemetry with zero code changes using OpenTelemetry auto-instrumentation

The platform is live on two LKE clusters and serves as a working reference for customers building multi-cluster observability.

## Architecture

```
  EDGE CLUSTER (any region)                         HUB CLUSTER
  ─────────────────────────                         ───────────

  ┌─────────────────────────┐
  │  Your Workloads         │
  │  (any language/framework)│
  └────────────┬────────────┘
               │ OTLP (traces, metrics, logs)
               ▼
  ┌─────────────────────────┐
  │  OTel Agent (DaemonSet) │  Runs on every node. Collects:
  │  ├─ otlp receiver       │  - App traces/metrics/logs via OTLP
  │  ├─ kubeletstats        │  - Node/pod/container resource metrics
  │  ├─ filelog             │  - All container stdout/stderr
  │  └─ k8sattributes      │  - Pod, namespace, deployment labels
  ├─────────────────────────┤
  │  OTel Scraper           │  Scrapes Prometheus /metrics endpoints:
  │  ├─ kube-state-metrics  │  - kube_pod_*, kube_deployment_*, etc.
  │  ├─ dcgm-exporter       │  - GPU utilization, memory, temperature
  │  └─ app /metrics        │  - Application-specific metrics
  └────────────┬────────────┘
               │
               │ OTLP/gRPC (port 4317)
               │ Labels: cluster.id, cluster.role
               │
               ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  OTel Gateway (LoadBalancer)                                │
  │  Adds hub.received_at label, batches, fans out to:         │
  │  ├─ Prometheus  (metrics via remote-write)                  │
  │  ├─ Loki        (logs via push API)                         │
  │  ├─ Tempo       (traces via OTLP/gRPC)                     │
  │  └─ [Optional: Splunk, Datadog, custom OTLP endpoint]      │
  └─────────────────────────────────────────────────────────────┘
               │
               ▼
  ┌──────────────────────────┐
  │  Grafana                 │  Single pane of glass:
  │  ├─ 4 dashboards         │  - All clusters, all signals
  │  ├─ Trace → Log linking  │  - Click a span, see its logs
  │  └─ Service map          │  - Auto-generated topology
  └──────────────────────────┘
```

## What Gets Collected Automatically

With no application changes, every cluster reports:

| Signal | Source | Examples |
|--------|--------|---------|
| Node metrics | kubeletstats | CPU, memory, disk, network per node |
| Pod/container metrics | kubeletstats | CPU/memory per pod and container, restarts |
| Kubernetes state | kube-state-metrics | Pod phase, deployment replicas, DaemonSet status |
| Container logs | filelog receiver | All pod stdout/stderr, parsed as JSON or plaintext |
| GPU metrics | dcgm-exporter | Utilization, memory, temperature, power (if GPUs present) |
| Application traces | OTel SDK | HTTP requests, DB queries, gRPC calls (with auto-instrumentation) |
| Application metrics | Prometheus scrape | Any `/metrics` endpoint on your services |

## Repository Structure

```
├── hub/                         # Hub cluster manifests
│   ├── gateway/                 # OTel Gateway (OTLP ingestion point)
│   │   ├── config.yaml          # Gateway collector config (fan-out to backends)
│   │   ├── deployment.yaml      # Gateway pods + LoadBalancer service
│   │   └── cert-manager/        # mTLS certificate resources
│   ├── monitoring/              # Internal observability backends
│   │   ├── prometheus/          # Metrics storage (remote-write receiver)
│   │   ├── loki/                # Log aggregation
│   │   ├── tempo/               # Distributed tracing
│   │   └── grafana/             # Dashboards and visualization
│   └── observability/           # OTel collection agents (hub cluster)
│       ├── agent/               # DaemonSet: OTLP, kubeletstats, filelog
│       ├── scraper/             # Deployment: Prometheus metric scraping
│       └── kube-state-metrics.yaml
│
├── edge/                        # Edge cluster configs
│   ├── agent-config.yaml        # OTel agent config (exports to hub gateway)
│   └── scraper-config.yaml      # OTel scraper config (exports to hub gateway)
│
├── examples/                    # Example workloads (for generating telemetry)
│   ├── inference/               # BERT GPU inference with OTel auto-instrumentation
│   └── vault/                   # HashiCorp Vault HA cluster
│
├── terraform/                   # LKE cluster provisioning
├── docs/                        # Deployment guide, architecture, security
├── scripts/                     # Cert generation, load testing, validation
├── policies/                    # Kyverno policies (mTLS, PII, resource limits)
└── tests/                       # Smoke tests and config validation
```

## Quick Start

See **[docs/deployment-guide.md](docs/deployment-guide.md)** for the full step-by-step guide covering:

1. Hub cluster setup (Prometheus, Loki, Tempo, Grafana, OTel gateway)
2. Edge cluster setup (OTel agents pointing to hub)
3. Application instrumentation (Python, Java, Node.js, Go, .NET)
4. Adding external destinations (Splunk, Datadog, custom OTLP)
5. Trace demo walkthrough
6. Troubleshooting and load testing

### Minimal Deploy

```bash
# Hub cluster
kubectl apply -k hub/monitoring/
kubectl apply -k hub/observability/
kubectl apply -k hub/gateway/

# Edge cluster (set context first)
kubectl --context <edge-ctx> apply -f edge/agent-config.yaml
kubectl --context <edge-ctx> apply -f edge/scraper-config.yaml
```

## Grafana Dashboards

Four dashboards are provisioned automatically:

| Dashboard | Shows |
|-----------|-------|
| BERT Inference | Request rate, latency histograms, GPU utilization per cluster |
| Federation Overview | Cluster count, hub/edge targets, cross-cluster metrics |
| GPU Health | DCGM deep dive: utilization, memory, temperature, power by GPU |
| Kubernetes Resources | Node CPU/memory, pod resources, deployment status, container restarts |

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Collection agent | OTel Collector DaemonSet | Collects OTLP + kubeletstats + filelog in one agent |
| Node/pod metrics | `kubeletstats` receiver | Direct kubelet API, no cadvisor proxy issues on LKE |
| K8s object metrics | kube-state-metrics | Standard, widely supported, ~152 metrics |
| Hub message bus | Direct fan-out (no Kafka) | Simpler for <10 clusters; add Redpanda when scaling beyond |
| Traces backend | Tempo | Native OTLP, integrates with Grafana trace-to-log linking |
| Metrics backend | Prometheus | Remote-write receiver, PromQL ecosystem |
| Log backend | Loki | Label-based, lightweight, Grafana-native |
| Cluster identity | `resource` processor | Injects `cluster.id` and `cluster.role` on all telemetry |

## Documentation

- [Deployment Guide](docs/deployment-guide.md) — Full setup instructions with YAML configs
- [Architecture](docs/architecture.md) — Design principles and data flow
- [Security](docs/security.md) — mTLS, PII scrubbing, network policies
- [ADRs](docs/adr/) — Architecture decision records
