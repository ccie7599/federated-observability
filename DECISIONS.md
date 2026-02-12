# Architecture Decision Records

Detailed ADRs are maintained in [`docs/adr/`](docs/adr/). This file provides a summary index.

| ADR | Decision | Status | Date |
|-----|----------|--------|------|
| [001](docs/adr/001-otlp-over-https.md) | OTLP over HTTPS on port 443 for edge→hub transport | Accepted | — |
| [002](docs/adr/002-redpanda-vs-kafka.md) | Redpanda over Kafka for future message bus tier | Accepted | — |
| [003](docs/adr/003-pii-scrubbing-at-edge.md) | PII scrubbing at the edge (before data leaves source cluster) | Accepted | — |
| [004](docs/adr/004-vault-secrets-operator.md) | Vault Secrets Operator for automated cert distribution | Accepted | — |

## Pending Decisions

- **Redpanda deployment**: Currently using direct fan-out. When scaling beyond ~10 clusters, evaluate deploying Redpanda as the buffering/routing tier (ADR-002 covers the technology choice, not the deployment trigger).
- **PII scrubbing deployment**: Edge aggregator layer needed to enforce PII patterns (ADR-003). Not yet deployed.
- **Vault auto-unseal**: Currently manual unseal with Shamir keys. Evaluate transit auto-unseal or cloud KMS for production.
