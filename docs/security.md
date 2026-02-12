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

### Vault Infrastructure

- **HashiCorp Vault** runs on both hub and edge clusters (3-pod Raft HA)
- Hub Vault stores: mTLS CA keypair, gateway server cert, edge client certs
- Edge Vault stores: local client cert + key, CA cert (no CA key)
- Vault Kubernetes auth enables service accounts to authenticate to Vault
- Never commit plaintext secrets to git (placeholder values only in manifest templates)

### Vault Secrets Operator (VSO)

The **Vault Secrets Operator** automates secret distribution from Vault to K8s secrets:

```
cert-manager ──issues──▶ K8s Secret ──sync-certs-to-vault.sh──▶ Vault KV
                                                                    │
                                                                   VSO
                                                                    │
                                                                    ▼
                                                              K8s Secret ──▶ Pod
```

| Component | Purpose |
|-----------|---------|
| `VaultConnection` | Points VSO to the cluster-local Vault instance |
| `VaultAuth` | Configures K8s auth with a dedicated `vso-auth` ServiceAccount |
| `VaultStaticSecret` | Syncs a Vault KV path to a K8s Secret, polls every 60s |

**Automatic rotation:** When certs are renewed (cert-manager → sync script → Vault), VSO detects the change and:
1. Updates the K8s Secret with new cert data
2. Triggers a rolling restart of configured workloads via `rolloutRestartTargets`

**Degradation behavior:** If Vault is sealed or unavailable, existing K8s secrets persist and pods continue running with current certs. VSO resumes syncing when Vault is available.

**Key manifests:**
- Hub: `hub/vault-secrets-operator/` (syncs `client-ca` for gateway mTLS validation)
- Edge: `edge/vault-secrets-operator/` (syncs `otel-client-tls` for agent/scraper mTLS)

See [ADR-004](adr/004-vault-secrets-operator.md) for the decision rationale and comparison with alternatives (External Secrets Operator, Vault Agent sidecar).

### Dynamic Secrets (Future)

For dynamic secrets (database credentials, short-lived tokens), the **Vault Agent sidecar** approach is recommended alongside VSO:
- VSO handles static secrets (TLS certs) — writes to K8s Secrets, no sidecar overhead
- Vault Agent sidecar handles dynamic secrets — injects credentials directly into pod filesystem, manages lease renewal
- This hybrid approach avoids sidecar overhead for static certs while enabling Vault's full dynamic secrets capabilities where needed

## Pod Security

- Hub namespace enforces `restricted` Pod Security Standard
- Edge namespace enforces `baseline` Pod Security Standard
- All containers run as non-root where possible
