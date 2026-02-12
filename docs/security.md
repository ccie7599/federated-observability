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
| **Public TLS** | Let's Encrypt (via cert-manager) | HTTPS for BERT demo UIs, Grafana | Vault KV (`observability/grafana-tls`) |
| **Internal mTLS** | Self-signed CA (via cert-manager CA issuer) | Edge→Hub OTLP authentication | Vault KV (`observability/mtls-ca`, `secret/observability/client-tls`) |

- Hub server certificate and edge client certificates issued by cert-manager using an internal CA (`observability-ca-issuer`)
- CA keypair stored in Vault (`observability/mtls-ca`) and synced to the `client-ca` K8s secret via VSO
- Edge client certificates stored in each edge cluster's Vault instance (`secret/observability/client-tls`)
- Grafana TLS certificate (Let's Encrypt) stored in Vault (`observability/grafana-tls`) and synced to the `monitoring` namespace via VSO
- Default validity: 1 year, auto-renew 30 days before expiry

### Certificate Rotation

Certificate rotation is fully automated through a four-stage pipeline:

```
cert-manager           sync-certs-to-vault.sh         VSO                    Workloads
(issues/renews) ─────▶ (K8s Secret → Vault KV) ─────▶ (Vault KV → K8s Secret) ─────▶ (rolling restart)
```

1. **cert-manager** renews the certificate automatically at 2/3 of its lifetime
2. **`scripts/sync-certs-to-vault.sh`** extracts the renewed cert from the K8s secret and writes it to Vault KV
3. **VSO VaultStaticSecret** detects the change within 60 seconds and updates the target K8s secret
4. **rolloutRestartTargets** triggers a rolling restart of affected workloads (zero downtime)

Manual rotation is also available:
- `scripts/generate-client-cert.sh` — generate client certs outside cert-manager
- `scripts/rotate-certs.sh` — zero-downtime rolling restart after manual cert update

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

All secrets are stored in HashiCorp Vault and distributed to Kubernetes via the Vault Secrets Operator (VSO). No secrets are stored as plaintext in Git or managed manually through kubectl.

### Vault Infrastructure

- **HashiCorp Vault** runs on both hub and edge clusters (3-pod Raft HA, version 1.15.4)
- Vault is initialized with 5 key shares and a threshold of 3 for unsealing
- Audit logging is enabled to `/vault/logs/audit.log`
- Vault Kubernetes auth enables service accounts to authenticate to Vault

### Vault KV Stores

Hub and edge clusters use separate KV mount paths to allow independent secret management and prevent accidental overwrites.

**Hub Vault** (`observability` KV-v2 mount):

| KV Path | Contents | Consumed By |
|---------|----------|-------------|
| `observability/mtls-ca` | CA cert + key | Hub gateway (validates edge client certs) |
| `observability/edge-certs/fed-observability-remote` | Edge client cert + key + CA | Hub OTel agents/scrapers (mTLS to gateway) |
| `observability/edge-certs/default` | Edge client cert backup | Archive |
| `observability/grafana-tls` | Grafana TLS cert + key (Let's Encrypt) | Grafana ingress (HTTPS) |
| `observability/splunk-hec` | Splunk HEC token | Splunk router (placeholder) |
| `observability/datadog` | Datadog API key | Datadog router (placeholder) |
| `observability/otlp` | Customer OTLP endpoint | OTLP router (placeholder) |

**Edge Vault** (`secret` KV-v2 mount):

| KV Path | Contents | Consumed By |
|---------|----------|-------------|
| `secret/observability/client-tls` | Edge client cert + key + CA | Edge OTel agents/scrapers (mTLS to hub) |
| `secret/observability/mtls-ca` | CA cert only (no key) | Edge (verify hub gateway cert) |

### Vault Policies and Roles

Two Vault policies control access:

**`observability-read`** — for OTel workloads accessing destination secrets:
```hcl
path "observability/*" {
  capabilities = ["read", "list"]
}
```

**`vso-read`** — for the Vault Secrets Operator to sync secrets:
```hcl
path "observability/data/*" {
  capabilities = ["read"]
}
path "observability/metadata/*" {
  capabilities = ["read", "list"]
}
```

Two Kubernetes auth roles bind service accounts to these policies:

| Role | Bound Service Accounts | Bound Namespaces | Policy |
|------|----------------------|-------------------|--------|
| `observability` | `otel-agent`, `otel-router` | `observability` | `observability-read` |
| `vso` | `vault-secrets-operator-controller-manager`, `vso-auth` | `vault-secrets-operator-system`, `observability`, `observability-hub`, `monitoring` | `vso-read` |

### Vault Secrets Operator (VSO)

VSO automates secret distribution from Vault KV to Kubernetes secrets using three CRD types:

| CRD | Purpose |
|-----|---------|
| `VaultConnection` | Points VSO to the cluster-local Vault instance (`http://vault.vault.svc.cluster.local:8200`) |
| `VaultAuth` | Configures Kubernetes auth with a dedicated `vso-auth` ServiceAccount per namespace |
| `VaultStaticSecret` | Syncs a Vault KV path to a K8s Secret, polls every 60 seconds, restarts workloads on change |

Each target namespace requires its own set of VSO CRDs (VaultConnection, VaultAuth, VaultStaticSecret) because VSO does not support cross-namespace references.

#### VSO Installations

Four VaultStaticSecret resources distribute secrets across the platform:

**Hub — `observability-hub` namespace** (`hub/vault-secrets-operator/`):

| VaultStaticSecret | Vault Path | K8s Secret | Restarts |
|-------------------|-----------|------------|----------|
| `client-ca` | `observability/mtls-ca` | `client-ca` | Deployment/`otel-gateway` |

Provides the CA certificate the gateway uses to validate edge client certificates during mTLS handshake. Only the `ca.crt` key is synced (the CA private key is excluded from this secret via transformation template).

**Hub — `observability` namespace** (`hub/observability/vault-secrets-operator/`):

| VaultStaticSecret | Vault Path | K8s Secret | Restarts |
|-------------------|-----------|------------|----------|
| `hub-client-tls` | `observability/edge-certs/fed-observability-remote` | `otel-client-tls` | DaemonSet/`otel-agent`, Deployment/`otel-scraper` |

Provides client certificates for hub-local OTel agents and scrapers to authenticate to the gateway over mTLS. Syncs `tls.crt`, `tls.key`, and `ca.crt`.

**Hub — `monitoring` namespace** (`hub/monitoring/vault-secrets-operator/`):

| VaultStaticSecret | Vault Path | K8s Secret | Restarts |
|-------------------|-----------|------------|----------|
| `grafana-tls` | `observability/grafana-tls` | `grafana-tls` | Deployment/`grafana` |

Provides the Let's Encrypt TLS certificate for Grafana HTTPS ingress. Created as `kubernetes.io/tls` secret type. Syncs `tls.crt` and `tls.key`.

**Edge — `observability` namespace** (`edge/vault-secrets-operator/`):

| VaultStaticSecret | Vault Path | K8s Secret | Restarts |
|-------------------|-----------|------------|----------|
| `otel-client-tls` | `secret/observability/client-tls` | `otel-client-tls` | DaemonSet/`otel-agent`, Deployment/`otel-scraper` |

Provides client certificates for edge OTel agents and scrapers to authenticate to the hub gateway over mTLS. Syncs `tls.crt`, `tls.key`, and `ca.crt`.

#### VSO Secret Transformation

VSO uses Go templates to remap Vault KV keys (underscore-delimited) to Kubernetes-standard keys (dot-delimited):

```yaml
transformation:
  excludeRaw: true
  excludes: [tls_crt, tls_key, ca_crt]
  templates:
    tls.crt:
      text: '{{ get .Secrets "tls_crt" }}'
    tls.key:
      text: '{{ get .Secrets "tls_key" }}'
    ca.crt:
      text: '{{ get .Secrets "ca_crt" }}'
```

`excludeRaw: true` and the `excludes` list prevent the original underscore-delimited keys from appearing in the K8s secret alongside the transformed keys.

#### VSO RBAC

Each namespace with rollout restart targets requires a Role and RoleBinding granting the VSO controller-manager permission to patch workloads:

```yaml
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "daemonsets"]  # varies by namespace
    verbs: ["get", "patch"]
subjects:
  - kind: ServiceAccount
    name: vault-secrets-operator-controller-manager
    namespace: vault-secrets-operator-system
```

#### Degradation Behavior

If Vault is sealed or unavailable, existing K8s secrets persist and pods continue running with current certs. VSO resumes syncing when Vault becomes available. The 60-second `refreshAfter` interval means certificate updates propagate within ~2 minutes (poll + rolling restart).

### Certificate Sync Script

`scripts/sync-certs-to-vault.sh` bridges cert-manager-issued certificates to Vault KV:

```bash
# Sync all certs (hub and edge Vault)
./scripts/sync-certs-to-vault.sh

# Only sync hub Vault
./scripts/sync-certs-to-vault.sh --hub-only

# Only sync edge Vault
./scripts/sync-certs-to-vault.sh --edge-only

# Dry run (shows what would be synced without writing)
./scripts/sync-certs-to-vault.sh --dry-run
```

The script extracts certificates from these K8s secrets on the hub cluster:

| Source Secret | Namespace | Destination |
|---------------|-----------|-------------|
| `observability-ca-keypair` | `cert-manager` | Hub Vault: `observability/mtls-ca` |
| `edge-client-tls` | `observability-hub` | Hub Vault: `observability/edge-certs/default`, Edge Vault: `secret/observability/client-tls` |
| `obs-connected-cloud-tls` | `monitoring` | Hub Vault: `observability/grafana-tls` |

### Dynamic Secrets (Future)

For dynamic secrets (database credentials, short-lived tokens), the **Vault Agent sidecar** approach is recommended alongside VSO:
- VSO handles static secrets (TLS certs) — writes to K8s Secrets, no sidecar overhead
- Vault Agent sidecar handles dynamic secrets — injects credentials directly into pod filesystem, manages lease renewal
- This hybrid approach avoids sidecar overhead for static certs while enabling Vault's full dynamic secrets capabilities where needed

See [ADR-004](adr/004-vault-secrets-operator.md) for the decision rationale and comparison with alternatives (External Secrets Operator, Vault Agent sidecar).

## Pod Security

- Hub namespace enforces `restricted` Pod Security Standard
- Edge namespace enforces `baseline` Pod Security Standard
- All containers run as non-root where possible

## Verification

```bash
# Check VSO is running
kubectl -n vault-secrets-operator-system get pods

# List all VaultStaticSecret resources and their sync status
kubectl get vaultstaticsecret -A

# Verify secrets are synced to K8s
kubectl get secret otel-client-tls -n observability
kubectl get secret client-ca -n observability-hub
kubectl get secret grafana-tls -n monitoring

# Check Vault auth role configuration
kubectl -n vault exec vault-0 -- vault read auth/kubernetes/role/vso

# Verify Vault audit log is active
kubectl -n vault exec vault-0 -- vault audit list
```
