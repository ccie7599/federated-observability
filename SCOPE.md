# Scope: Federated Observability on LKE

## Problem Statement

Enterprise customers running distributed workloads across multiple LKE clusters need unified observability (metrics, logs, traces) with a single pane of glass. The platform must support multi-destination routing, mTLS transport security, PII scrubbing at the edge, and zero-code application instrumentation via OpenTelemetry.

## Tier Classification

- [ ] Tier 1 — Demo/POC (1-2 days, throwaway OK)
- [x] Tier 2 — Reference Architecture (1-2 weeks, reusable)
- [ ] Tier 3 — Production Candidate (2-6 weeks, hardened)

## In Scope

- Hub-and-spoke OTel collection (hub gateway + edge agents/scrapers)
- Grafana stack backends (Prometheus, Loki, Tempo) on hub cluster
- Pre-provisioned Grafana dashboards (BERT inference, federation overview, GPU health, K8s resources)
- mTLS for all edge-to-hub OTLP transport (cert-manager CA + Vault + VSO)
- Vault HA (Raft) on hub and edge clusters for secret storage
- Vault Secrets Operator for automated cert distribution and rotation
- External destination fan-out patterns (Splunk HEC, Datadog, custom OTLP)
- Auto-instrumentation examples (Python/BERT inference)
- GPU metrics collection via DCGM exporter
- Kyverno policies (mTLS enforcement, PII scrubbing, resource limits)
- Deployment guide, security docs, ADRs

## Explicit Non-Goals

1. **NOT building a production-grade Kafka/Redpanda tier** — Direct fan-out from gateway is sufficient for <10 clusters. Redpanda is documented as a scaling path but not deployed.
2. **NOT implementing PII scrubbing** — Documented as planned enhancement. Requires an edge aggregator layer that is not yet deployed.
3. **NOT providing multi-region hub failover** — Single hub cluster in us-ord. DR and multi-region hub federation are out of scope.
4. **NOT managing customer application deployments** — The platform collects telemetry; it does not deploy, manage, or lifecycle customer workloads.
5. **NOT building a self-service onboarding portal** — New edge clusters are onboarded manually via the deployment guide.

## Scale Commitments

| Metric | Proven (Tested) | Target (Architectural) |
|--------|----------------|----------------------|
| Edge clusters | 2 | 10-50 |
| Metrics throughput | Not yet benchmarked | 50k data points/sec |
| Log throughput | Not yet benchmarked | 10k events/sec |
| Trace throughput | Not yet benchmarked | 5k spans/sec |
| Certificate rotation | Automated via VSO | Zero-downtime, <2 min propagation |

## Exit Criteria

- [ ] Hub + 1 edge cluster fully operational with mTLS
- [ ] All three signal types (metrics, logs, traces) flowing edge → hub → Grafana
- [ ] VSO-managed certificate lifecycle working end-to-end (issue, sync, rotate, restart)
- [ ] At least one external destination pattern documented and validated (Splunk/Datadog/OTLP)
- [ ] Deployment guide tested by someone other than the author
- [ ] Security documentation reflects actual implementation (not aspirational)
- [ ] Load test baseline established with telemetrygen

## Tech Debt

- Vault runs with HTTP internally (not TLS) — acceptable for POC, must be hardened for customer delivery
- PII scrubbing is documented but not deployed (requires aggregator layer)
- Redpanda topic-based routing is designed but not implemented (direct fan-out is current path)
- `vault-keys.json` stored locally — needs proper key ceremony for production
- Edge Vault init/unseal is manual — no auto-unseal configured
