#!/usr/bin/env bash
set -euo pipefail

# Rotate mTLS client certificates for edge clusters
# Usage: ./rotate-certs.sh <cluster-name> [--apply]
#
# This script generates a new certificate and optionally updates
# the Kubernetes secret in the target cluster.

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [--apply]}"
APPLY="${2:-}"
NAMESPACE="${NAMESPACE:-observability}"
SECRET_NAME="${SECRET_NAME:-otel-aggregator-mtls}"
CERTS_DIR="./certs/${CLUSTER_NAME}"
BACKUP_DIR="./certs/${CLUSTER_NAME}/backup-$(date +%Y%m%d%H%M%S)"

# Backup existing certs
if [ -d "${CERTS_DIR}" ]; then
    echo "Backing up existing certificates to ${BACKUP_DIR}"
    mkdir -p "${BACKUP_DIR}"
    cp "${CERTS_DIR}/client.crt" "${BACKUP_DIR}/" 2>/dev/null || true
    cp "${CERTS_DIR}/client.key" "${BACKUP_DIR}/" 2>/dev/null || true
fi

# Generate new certificate
echo "Generating new certificate for ${CLUSTER_NAME}..."
./scripts/generate-client-cert.sh "${CLUSTER_NAME}" "${CERTS_DIR}"

if [ "${APPLY}" = "--apply" ]; then
    echo ""
    echo "Updating Kubernetes secret ${SECRET_NAME} in namespace ${NAMESPACE}..."

    kubectl create secret generic "${SECRET_NAME}" \
        --from-file=client.crt="${CERTS_DIR}/client.crt" \
        --from-file=client.key="${CERTS_DIR}/client.key" \
        --from-file=ca.crt="${CERTS_DIR}/ca.crt" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | kubectl apply -f -

    echo "Secret updated. Restarting aggregator pods..."
    kubectl rollout restart deployment/otel-aggregator -n "${NAMESPACE}"
    kubectl rollout status deployment/otel-aggregator -n "${NAMESPACE}" --timeout=120s

    echo "Certificate rotation complete."
else
    echo ""
    echo "Dry run complete. To apply to the cluster, run:"
    echo "  $0 ${CLUSTER_NAME} --apply"
fi
