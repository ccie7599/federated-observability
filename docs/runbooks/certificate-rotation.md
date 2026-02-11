# Runbook: Certificate Rotation

## Scheduled Rotation

Certificates should be rotated 30 days before expiry. Check expiry dates:

```bash
for dir in ./certs/*/; do
  cluster=$(basename "$dir")
  expiry=$(openssl x509 -in "${dir}/client.crt" -noout -enddate 2>/dev/null || echo "N/A")
  echo "${cluster}: ${expiry}"
done
```

## Rotating an Edge Cluster Certificate

### Automated (recommended):
```bash
./scripts/rotate-certs.sh <cluster-name> --apply
```

This will:
1. Back up the existing certificate
2. Generate a new certificate signed by the CA
3. Update the Kubernetes secret
4. Rolling restart the aggregator pods

### Manual:
```bash
# 1. Generate new cert
./scripts/generate-client-cert.sh <cluster-name>

# 2. Update the secret
kubectl create secret generic otel-aggregator-mtls \
  --from-file=client.crt=./certs/<cluster-name>/client.crt \
  --from-file=client.key=./certs/<cluster-name>/client.key \
  --from-file=ca.crt=./certs/<cluster-name>/ca.crt \
  -n observability --dry-run=client -o yaml | kubectl apply -f -

# 3. Restart aggregator
kubectl rollout restart deployment/otel-aggregator -n observability
kubectl rollout status deployment/otel-aggregator -n observability
```

## Rotating the CA Certificate

**High impact** - requires updating all edge cluster certificates.

1. Generate new CA (update `CA_DIR` or backup old CA first)
2. Re-generate all edge cluster client certs with new CA
3. Update the `client-ca` secret on the hub cluster
4. Roll out new client certs to all edge clusters
5. Verify connectivity from each edge cluster

## Rotating Hub Server Certificate

Managed by cert-manager. Force renewal:

```bash
kubectl -n observability-hub delete secret gateway-tls
# cert-manager will automatically re-issue
```

## Rotating Redpanda TLS Certificates

```bash
# Update the secret
kubectl -n observability-hub create secret generic redpanda-tls \
  --from-file=tls.crt=<new-cert> \
  --from-file=tls.key=<new-key> \
  --from-file=ca.crt=<ca-cert> \
  --dry-run=client -o yaml | kubectl apply -f -

# Rolling restart (one broker at a time)
for i in 0 1 2; do
  kubectl -n observability-hub delete pod redpanda-${i}
  kubectl -n observability-hub wait --for=condition=ready pod/redpanda-${i} --timeout=120s
  sleep 30
done
```
