# Security

## mTLS Architecture

All telemetry transport uses mutual TLS:

- **Edge → Hub**: Edge aggregator presents client cert; hub ingress validates against client CA
- **Hub internal**: Gateway → Redpanda and Routers → Redpanda use TLS with client certs
- **Hub → Destinations**: TLS to Splunk HEC, Datadog API, customer OTLP endpoints

### Certificate Management

- Hub server certificates managed by cert-manager with internal CA
- Edge client certificates generated via `scripts/generate-client-cert.sh`
- Rotation via `scripts/rotate-certs.sh` (zero-downtime rolling restart)
- Default validity: 365 days, rotate at 30 days before expiry

## PII Scrubbing

All PII scrubbing happens at the edge aggregator **before** data leaves the source cluster:

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

- Production: External Secrets Operator syncing from HashiCorp Vault
- Secrets stored: Splunk HEC token, Datadog API key, TLS certificates
- Never commit plaintext secrets to git (placeholder values only in secret.yaml files)

## Pod Security

- Hub namespace enforces `restricted` Pod Security Standard
- Edge namespace enforces `baseline` Pod Security Standard
- All containers run as non-root where possible
