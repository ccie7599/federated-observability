# ADR 004: Vault Secrets Operator for Secret Distribution

## Status
Accepted

## Context
The federated observability platform runs on multiple LKE clusters (hub + edge). mTLS certificates are issued by cert-manager on the hub cluster and must be distributed to edge clusters for OTLP transport authentication.

Previously, secrets were manually copied between clusters using kubectl, which is not scalable, error-prone, and lacks automatic rotation support.

Vault runs on both hub and edge clusters in HA Raft mode with 3 pods each. We need automated, declarative secret synchronization with automatic workload restart on certificate rotation.

## Options Considered
1. **Vault Secrets Operator (VSO)** - Purpose-built for Vault with native CRDs (VaultAuth, VaultStaticSecret)
2. **External Secrets Operator (ESO)** - Supports many backends (Vault, AWS Secrets Manager, etc.) but adds complexity
3. **Vault Agent Sidecar Injector** - Best for dynamic secrets (database credentials, PKI); heavyweight for static TLS certificates
4. **Manual kubectl scripting** - Not scalable, error-prone, no automatic rotation

## Decision
Use Vault Secrets Operator (VSO) for distributing static TLS certificates from Vault to Kubernetes Secrets.

## Rationale
- **Purpose-built**: VSO is specifically designed for Vault integration with native Kubernetes CRDs
- **No sidecar overhead**: VSO writes directly to Kubernetes Secrets, which existing volumeMounts already consume (unlike Vault Agent which requires a sidecar container per pod)
- **Automatic rotation**: VaultStaticSecret.rolloutRestartTargets automatically restarts workloads when certificates are renewed
- **GitOps-friendly**: Declarative VaultStaticSecret resources can be managed via ArgoCD/FluxCD
- **60-second refresh cycle**: Catches certificate renewals quickly
- **Simpler than ESO**: We only use Vault, so ESO's multi-backend support is unnecessary complexity

## Architecture
1. **cert-manager** handles certificate lifecycle (issuance, auto-renewal at 2/3 of certificate lifetime)
2. **sync-certs-to-vault.sh** bridges cert-manager Secrets → Vault KV (runs as a CronJob or manually)
3. **VSO VaultStaticSecret** syncs Vault KV → Kubernetes Secret in target namespace
4. **VaultStaticSecret.rolloutRestartTargets** restarts workloads (Deployments, StatefulSets) when secrets change
5. **VaultAuth + VaultConnection** per target namespace (no cross-namespace references allowed)
6. **Dedicated vso-auth ServiceAccount** in each target namespace with Vault Kubernetes auth role binding

## Implementation Details

### Hub Cluster
VSO resources in `hub/vault-secrets-operator/`:
- VaultConnection pointing to hub Vault (https://vault.vault.svc.cluster.local:8200)
- VaultAuth with Kubernetes auth method (serviceAccount: vso-auth)
- VaultStaticSecret for client-ca certificate (used to validate edge cluster client certificates)

### Edge Cluster
VSO resources in `edge/vault-secrets-operator/`:
- VaultConnection pointing to edge Vault
- VaultAuth with Kubernetes auth method
- VaultStaticSecret for otel-client-tls certificate (used to authenticate to hub cluster)

### Key Files
- Hub VSO manifests: `/home/bapley/federatated-observability/hub/vault-secrets-operator/`
- Edge VSO manifests: `/home/bapley/federatated-observability/edge/vault-secrets-operator/`
- Certificate sync script: `/home/bapley/federatated-observability/scripts/sync-certs-to-vault.sh`
- Vault setup: `/home/bapley/federatated-observability/examples/vault/vault-setup.sh`
- Vault initialization: `/home/bapley/federatated-observability/examples/vault/vault-init.sh`

## Consequences
- **Positive**: Declarative, GitOps-compatible secret management
- **Positive**: Automatic workload restart on certificate rotation (zero-downtime)
- **Positive**: No sidecar overhead; existing volumeMount patterns unchanged
- **Positive**: 60-second refresh cycle catches certificate renewals quickly
- **Positive**: Vault provides centralized audit logging of secret access
- **Negative**: Requires Vault to be unsealed for secret sync (Kubernetes Secrets persist if Vault goes down temporarily)
- **Negative**: Additional operator to manage (vault-secrets-operator Helm chart)
- **Negative**: VaultAuth and VaultConnection must be duplicated in every namespace (no cross-namespace references)

## Future Considerations
When dynamic secrets are needed (e.g., database credentials with short TTLs), Vault Agent sidecar should be used alongside VSO:
- **VSO**: For static TLS certificates (long-lived, infrequent rotation)
- **Vault Agent sidecar**: For dynamic credentials (short-lived, frequent rotation, requires injection into application containers)

This hybrid approach leverages the strengths of both patterns without unnecessary complexity.

## Enforcement
The Kyverno policy `require-vault-secrets-operator.yaml` validates that OTel collector Deployments reference Secrets managed by VaultStaticSecret (by checking for the `vso.secrets.hashicorp.com/` annotation).

## References
- Vault Secrets Operator: https://developer.hashicorp.com/vault/docs/platform/k8s/vso
- cert-manager: https://cert-manager.io/docs/
- VaultStaticSecret CRD: https://developer.hashicorp.com/vault/docs/platform/k8s/vso/api-reference#vaultstaticsecret
