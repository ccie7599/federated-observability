#!/usr/bin/env bash
set -euo pipefail

# Generate mTLS client certificate for an edge cluster
# Usage: ./generate-client-cert.sh <cluster-name> [output-dir]

CLUSTER_NAME="${1:?Usage: $0 <cluster-name> [output-dir]}"
OUTPUT_DIR="${2:-./certs/${CLUSTER_NAME}}"
CA_DIR="${CA_DIR:-./certs/ca}"
DAYS_VALID="${DAYS_VALID:-365}"

mkdir -p "${OUTPUT_DIR}" "${CA_DIR}"

# Generate CA if it doesn't exist
if [ ! -f "${CA_DIR}/ca.key" ]; then
    echo "Generating Certificate Authority..."
    openssl genrsa -out "${CA_DIR}/ca.key" 4096
    openssl req -new -x509 -days 3650 -key "${CA_DIR}/ca.key" \
        -out "${CA_DIR}/ca.crt" \
        -subj "/C=US/ST=New York/O=FederatedObservability/CN=Observability CA"
    echo "CA certificate created at ${CA_DIR}/ca.crt"
fi

# Generate client key and CSR
echo "Generating client certificate for cluster: ${CLUSTER_NAME}"
openssl genrsa -out "${OUTPUT_DIR}/client.key" 2048

openssl req -new -key "${OUTPUT_DIR}/client.key" \
    -out "${OUTPUT_DIR}/client.csr" \
    -subj "/C=US/ST=New York/O=FederatedObservability/CN=${CLUSTER_NAME}"

# Create extensions file for client auth
cat > "${OUTPUT_DIR}/extensions.cnf" <<EOF
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${CLUSTER_NAME}
DNS.2 = ${CLUSTER_NAME}.observability.svc.cluster.local
EOF

# Sign the client certificate with CA
openssl x509 -req -days "${DAYS_VALID}" \
    -in "${OUTPUT_DIR}/client.csr" \
    -CA "${CA_DIR}/ca.crt" \
    -CAkey "${CA_DIR}/ca.key" \
    -CAcreateserial \
    -out "${OUTPUT_DIR}/client.crt" \
    -extensions v3_req \
    -extfile "${OUTPUT_DIR}/extensions.cnf"

# Copy CA cert for the client
cp "${CA_DIR}/ca.crt" "${OUTPUT_DIR}/ca.crt"

# Clean up CSR and extensions
rm -f "${OUTPUT_DIR}/client.csr" "${OUTPUT_DIR}/extensions.cnf"

# Verify
echo ""
echo "Certificate generated successfully:"
echo "  Client cert: ${OUTPUT_DIR}/client.crt"
echo "  Client key:  ${OUTPUT_DIR}/client.key"
echo "  CA cert:     ${OUTPUT_DIR}/ca.crt"
echo ""
echo "Expires: $(openssl x509 -in "${OUTPUT_DIR}/client.crt" -noout -enddate)"
echo ""
echo "To create a Kubernetes secret:"
echo "  kubectl create secret generic otel-aggregator-mtls \\"
echo "    --from-file=client.crt=${OUTPUT_DIR}/client.crt \\"
echo "    --from-file=client.key=${OUTPUT_DIR}/client.key \\"
echo "    --from-file=ca.crt=${OUTPUT_DIR}/ca.crt \\"
echo "    -n observability"
