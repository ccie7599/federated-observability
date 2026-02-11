# Architecture

## Overview

The Federated Observability Platform collects metrics, logs, and traces from distributed LKE (Linode Kubernetes Engine) clusters and routes them to multiple enterprise destinations (Splunk, Datadog, Customer OTLP endpoints).

## Design Principles

1. **Edge processing** - PII scrubbing and sampling happen at source before data leaves the cluster
2. **Decoupled delivery** - Redpanda buffers telemetry between ingestion and destination routing
3. **Independent routing** - Each destination has its own consumer, so outages don't affect others
4. **Defense in depth** - mTLS everywhere, network policies, Kyverno enforcement

## Data Flow

```
Edge Cluster                          Hub Cluster
┌──────────────────┐                  ┌──────────────────────────────────────┐
│ App → Agent      │                  │ Ingress (mTLS)                       │
│      → Aggregator│──HTTPS/mTLS───→ │ → Gateway → Redpanda                 │
│        (PII scrub│                  │              ├→ Router-Splunk → Splunk│
│         sampling)│                  │              ├→ Router-DD → Datadog   │
└──────────────────┘                  │              ├→ Router-OTLP → Cust.  │
                                      │              └→ Internal → Grafana   │
                                      └──────────────────────────────────────┘
```

## Components

### Edge Layer
- **OTel Agent (DaemonSet)** - Collects OTLP from app SDKs, container logs via filelog, host metrics, k8s events
- **OTel Aggregator (Deployment)** - PII scrubbing, tail-based trace sampling, metrics pre-aggregation, persistent queue with mTLS export to hub

### Hub Layer
- **Ingress (nginx)** - TLS termination, mTLS client cert validation, rate limiting per cluster
- **OTel Gateway** - Receives OTLP/HTTP, validates service.name, enriches with hub metadata, writes to Redpanda
- **Redpanda** - 3-broker StatefulSet with topics: otlp.metrics (7d), otlp.logs (7d), otlp.traces (3d), otlp.dlq (30d)
- **Destination Routers** - Independent OTel collectors consuming from Redpanda and exporting to Splunk HEC, Datadog API, or customer OTLP endpoint

### Internal Observability
- **VictoriaMetrics** - Long-term metrics storage for platform self-monitoring
- **Loki** - Log aggregation for platform logs
- **Tempo** - Distributed tracing for platform traces
- **Grafana** - Dashboards for pipeline overview, edge health, destination health

## Key Decisions

See [ADR directory](adr/) for detailed decision records:
- [001: OTLP over HTTPS](adr/001-otlp-over-https.md)
- [002: Redpanda vs Kafka](adr/002-redpanda-vs-kafka.md)
- [003: PII Scrubbing at Edge](adr/003-pii-scrubbing-at-edge.md)
