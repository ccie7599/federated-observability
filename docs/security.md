# Security

## mTLS Architecture

All telemetry transport between clusters uses mutual TLS:

- **Edge → Hub**: Edge OTel agents and scrapers present client certificates; hub gateway validates against internal CA
- **Hub internal**: Gateway → Prometheus/Loki/Tempo uses cluster-internal HTTP (no TLS required — same trust boundary)
- **Hub → Destinations**: TLS to external endpoints (Splunk HEC, Datadog API, customer OTLP) when configured

### Certificate Management

Two certificate tiers are used:

| Tier | Issuer | Purpose | Storage |
|------|--------|---------|---------|
| **Public TLS** | Let's Encrypt (via cert-manager) | HTTPS for BERT demo UIs, Grafana | cert-manager auto-renew |
| **Internal mTLS** | Self-signed CA (via cert-manager CA issuer) | Edge→Hub OTLP authentication | HashiCorp Vault |

- Hub server certificate and edge client certificates issued by cert-manager using an internal CA (`observability-ca-issuer`)
- CA keypair stored in Vault (`secret/observability/mtls-ca`) and synced to `observability-ca-keypair` K8s secret
- Edge client certificates stored in each edge cluster's local Vault instance
- Default validity: 1 year, auto-renew 30 days before expiry

### Certificate Rotation

- cert-manager handles automatic rotation for both Let's Encrypt and internal CA certificates
- Manual rotation: `scripts/generate-client-cert.sh` for generating client certs outside cert-manager
- Rotation script: `scripts/rotate-certs.sh` for zero-downtime rolling restart after cert update

## PII Scrubbing

> **Status: Planned enhancement.** PII scrubbing requires an edge aggregator deployment between the agent and hub gateway. The current architecture sends telemetry directly from edge agents to the hub. When an aggregator layer is added, the following patterns will be enforced at the edge before data leaves the source cluster:

| Pattern | Replacement | Processor |
|---------|-------------|-----------|
| Email addresses | `[EMAIL_REDACTED]` | transform |
| SSN (XXX-XX-XXXX) | `[SSN_REDACTED]` | transform |
| Credit card numbers | `[CC_REDACTED]` | transform |
| Phone numbers | `[PHONE_REDACTED]` | transform |
| URL passwords/tokens | `[REDACTED]` | transform |
| `user.email`, `user.ssn` attributes | deleted | transform |
| `db.statement` | SHA-256 hash | attributes |
| Authorization header | deleted | attributes |
| Cookie header | deleted | attributes |
| X-Api-Key header | deleted | attributes |

## Network Policies

Enforced via Kyverno policies in `policies/`:

- `require-mtls.yaml` - All OTel deployments must mount TLS certificates
- `pii-scrubbing-required.yaml` - Aggregator config must include PII scrubbing patterns
- `resource-limits.yaml` - All containers must have resource requests and limits

## Secrets Management

- **HashiCorp Vault** runs on both hub and edge clusters (3-pod raft HA)
- Hub Vault stores: mTLS CA keypair, gateway server cert, edge client certs
- Edge Vault stores: local client cert + key, CA cert (no CA key)
- Vault Kubernetes auth enables pods to retrieve secrets at runtime
- Never commit plaintext secrets to git (placeholder values only in manifest templates)

## Pod Security

- Hub namespace enforces `restricted` Pod Security Standard
- Edge namespace enforces `baseline` Pod Security Standard
- All containers run as non-root where possible
