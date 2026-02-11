# Runbook: Scaling

## Edge Aggregator

The aggregator has HPA configured. Manual override:

```bash
# Scale up
kubectl -n observability scale deployment/otel-aggregator --replicas=5

# Check queue depth (high queue = need more consumers)
kubectl -n observability logs deployment/otel-aggregator | grep "queue"
```

**Scaling triggers:**
- CPU > 70% average
- Memory > 80% average
- Queue depth consistently > 5000

## Hub Gateway

HPA scales from 3 to 20 replicas in production.

```bash
# Check current scale
kubectl -n observability-hub get hpa otel-gateway

# Manual override
kubectl -n observability-hub scale deployment/otel-gateway --replicas=10
```

**Scaling triggers:**
- CPU > 70%
- Incoming request rate > 50k/sec per pod

## Redpanda

### Adding Brokers

Redpanda scales horizontally by increasing StatefulSet replicas:

```bash
# Scale from 3 to 5 brokers
kubectl -n observability-hub scale statefulset/redpanda --replicas=5

# Wait for new brokers to join
kubectl -n observability-hub exec -it redpanda-0 -- rpk cluster info

# Rebalance partitions across all brokers
kubectl -n observability-hub exec -it redpanda-0 -- rpk cluster partitions balance
```

### Expanding Storage

```bash
# Edit the PVC size (requires storage class to support expansion)
for i in 0 1 2; do
  kubectl -n observability-hub patch pvc data-redpanda-${i} \
    -p '{"spec":{"resources":{"requests":{"storage":"400Gi"}}}}'
done
```

### Topic Partition Scaling

```bash
# Add partitions to handle more throughput
kubectl -n observability-hub exec -it redpanda-0 -- \
  rpk topic alter-config otlp.metrics --set partition_count=24
```

## Destination Routers

Each router can be scaled independently:

```bash
kubectl -n observability-hub scale deployment/otel-router-splunk --replicas=5
kubectl -n observability-hub scale deployment/otel-router-datadog --replicas=5
kubectl -n observability-hub scale deployment/otel-router-otlp --replicas=5
```

**Note:** Scaling beyond the number of topic partitions provides no benefit for Kafka consumers. Default is 12 partitions per topic.

## Capacity Planning

| Component | Per-pod throughput | Recommended max |
|-----------|-------------------|-----------------|
| Agent | ~5k spans/sec | 1 per node (DaemonSet) |
| Aggregator | ~10k spans/sec | 10 replicas |
| Gateway | ~20k spans/sec | 20 replicas |
| Redpanda (per broker) | ~50k msgs/sec | 5 brokers |
| Router | ~15k events/sec | partitions / 2 replicas |
