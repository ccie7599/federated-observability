# Deployment Guide

## Prerequisites

- kubectl configured for target clusters
- kustomize v5+
- cert-manager installed on hub cluster
- Access to container registry for OTel Collector images

## Deployment Order

### 1. Hub Cluster

Deploy in this order (dependencies flow top to bottom):

```bash
# Namespaces and cert-manager resources
kubectl apply -k hub-gateway/overlays/prod/

# Storage layer (wait for Redpanda to be ready)
kubectl apply -k hub-storage/overlays/prod/
kubectl -n observability-hub rollout status statefulset/redpanda --timeout=300s

# Create Kafka topics
kubectl -n observability-hub wait --for=condition=ready pod/redpanda-0 --timeout=120s
kubectl apply -f hub-storage/topics.yaml

# Destination routers
kubectl apply -k hub-routing/overlays/prod/

# Internal observability
kubectl apply -k hub-internal/overlays/prod/
```

### 2. Edge Clusters

For each edge cluster:

```bash
# Generate client certificate
./scripts/generate-client-cert.sh <cluster-name>

# Create mTLS secret
kubectl create secret generic otel-aggregator-mtls \
  --from-file=client.crt=./certs/<cluster-name>/client.crt \
  --from-file=client.key=./certs/<cluster-name>/client.key \
  --from-file=ca.crt=./certs/<cluster-name>/ca.crt \
  -n observability

# Update cluster-identity ConfigMap with correct cluster ID
# Then deploy
kubectl apply -k edge-collector/overlays/prod/
```

## Validation

```bash
# Check all pods are running
kubectl -n observability get pods
kubectl -n observability-hub get pods

# Verify gateway health
kubectl -n observability-hub port-forward svc/otel-gateway 13133:13133 &
curl http://localhost:13133/health

# Check Redpanda topic lag
kubectl -n observability-hub exec -it redpanda-0 -- rpk group list

# Run config validation
./scripts/validate-config.sh
```

## Environment Overlays

| Environment | Edge Replicas | Gateway Replicas | Redpanda Replicas | Storage |
|-------------|---------------|------------------|-------------------|---------|
| dev         | 1 aggregator  | 1                | 1                 | 20Gi    |
| staging     | 2 aggregators | 2                | 3                 | 50Gi    |
| prod        | 3 aggregators | 3 (HPA to 20)   | 3                 | 200Gi   |
