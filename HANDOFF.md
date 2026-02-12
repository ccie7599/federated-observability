# Handoff Guide: Federated Observability on LKE

## Overview

This document provides everything a delivery engineer needs to take over, extend, or deploy the federated observability platform for a customer engagement.

## Architecture Summary

Hub-and-spoke observability using OpenTelemetry. A central hub cluster runs Prometheus, Loki, Tempo, and Grafana. Edge clusters run OTel agents that collect metrics, logs, and traces and forward them to the hub via OTLP/gRPC with mTLS.

See [docs/architecture.md](docs/architecture.md) for the full design and [docs/deployment-guide.md](docs/deployment-guide.md) for step-by-step setup.

## Repository Layout

| Directory | Purpose |
|-----------|---------|
| `hub/gateway/` | OTel Gateway — central OTLP ingestion point with mTLS |
| `hub/monitoring/` | Prometheus, Loki, Tempo, Grafana |
| `hub/observability/` | Hub-local OTel agents, scrapers, kube-state-metrics |
| `hub/vault-secrets-operator/` | VSO CRDs for `observability-hub` namespace |
| `edge/` | Edge cluster OTel agent and scraper configs |
| `edge/vault-secrets-operator/` | VSO CRDs for edge `observability` namespace |
| `examples/vault/` | Vault HA StatefulSet, init, and setup scripts |
| `examples/inference/` | BERT inference demo with OTel auto-instrumentation |
| `terraform/` | LKE cluster provisioning |
| `policies/` | Kyverno policies (mTLS, PII, resource limits) |
| `scripts/` | Cert sync, cert generation, load testing |
| `docs/` | Deployment guide, security, architecture, ADRs |

## Prerequisites for Deployment

- 2+ LKE clusters (hub: 3x g6-standard-4, edge: 2x g6-standard-2)
- `kubectl`, `helm`, `linode-cli` installed
- Akamai Edge DNS access (for `connected-cloud.io` or customer domain)
- HashiCorp Vault Secrets Operator Helm chart (`hashicorp/vault-secrets-operator`)
- cert-manager Helm chart (`jetstack/cert-manager`)

## Deployment Sequence

1. Provision clusters (Terraform or `linode-cli`)
2. Deploy hub monitoring stack (`hub/monitoring/`)
3. Deploy hub observability agents (`hub/observability/`)
4. Deploy Vault HA on hub, initialize, run `vault-setup.sh`
5. Install cert-manager, bootstrap internal CA
6. Issue gateway server cert + edge client cert
7. Sync certs to Vault (`scripts/sync-certs-to-vault.sh`)
8. Install VSO, apply hub VSO CRDs (3 namespaces)
9. Deploy gateway with mTLS (`hub/gateway/`)
10. Deploy edge Vault, initialize, configure K8s auth
11. Install VSO on edge, apply edge VSO CRDs
12. Sync certs to edge Vault
13. Deploy edge agents + scrapers
14. Verify end-to-end data flow in Grafana

Full instructions: [docs/deployment-guide.md](docs/deployment-guide.md)

## Secrets and Credentials

All secrets are stored in HashiCorp Vault and distributed via VSO. No secrets in Git.

| Secret | Vault Path | Cluster |
|--------|-----------|---------|
| mTLS CA cert + key | `observability/mtls-ca` | Hub |
| Edge client cert | `observability/edge-certs/<cluster-name>` | Hub |
| Grafana TLS cert | `observability/grafana-tls` | Hub |
| Edge client TLS | `secret/observability/client-tls` | Edge |
| Splunk HEC token | `observability/splunk-hec` | Hub (placeholder) |
| Datadog API key | `observability/datadog` | Hub (placeholder) |

See [docs/security.md](docs/security.md) for the full VSO architecture.

## Known Issues and Tech Debt

| Issue | Impact | Priority |
|-------|--------|----------|
| Vault uses HTTP internally (no TLS) | Acceptable for demo; must enable TLS for customer delivery | High for prod |
| PII scrubbing not deployed | Documented patterns exist but require edge aggregator layer | Medium |
| Vault unseal is manual | Pods require 3/5 Shamir keys after restart | Medium |
| `vault-keys.json` stored locally | Needs key ceremony / secure storage for production | High for prod |
| No automated load test baseline | telemetrygen patterns documented but not run as CI | Low |

## Customer Customization Checklist

When deploying for a specific customer:

- [ ] Update `cluster.id` values in agent/scraper configs
- [ ] Replace `connected-cloud.io` DNS with customer domain
- [ ] Update gateway cert SANs (IP + DNS) for customer infrastructure
- [ ] Replace destination placeholder secrets with real API keys (Splunk, Datadog)
- [ ] Review PII scrubbing patterns for customer-specific data (add patterns as needed)
- [ ] Adjust resource limits and HPA thresholds for expected telemetry volume
- [ ] Enable Vault TLS for production deployments
- [ ] Configure Vault auto-unseal if customer requires it
- [ ] Review and apply Kyverno policies

## Escalation

- **Architecture questions**: See [DECISIONS.md](DECISIONS.md) and [docs/adr/](docs/adr/)
- **Scope boundaries**: See [SCOPE.md](SCOPE.md)
- **Original author**: Brian (TSA)
