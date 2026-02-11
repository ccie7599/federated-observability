# Runbook: Destination Outage

## Symptoms

- Grafana "Destination Health" dashboard shows export success rate < 99%
- Router queue size increasing
- Kafka consumer lag growing for affected router group

## Diagnosis

1. Check which destination is affected:
   ```bash
   kubectl -n observability-hub logs -l app.kubernetes.io/component=router --tail=100
   ```

2. Check queue depth:
   ```bash
   kubectl -n observability-hub exec -it redpanda-0 -- rpk group describe router-splunk-logs
   ```

3. Check exporter errors in router logs:
   ```bash
   kubectl -n observability-hub logs deployment/otel-router-splunk | grep -i error
   ```

## Response

### If destination is temporarily down:

No immediate action needed. The architecture handles this:
- Routers have retry with exponential backoff (10s → 60s)
- Persistent file-backed queues buffer up to 5000 batches
- Redpanda retains data for 7 days (logs/metrics) or 3 days (traces)

Monitor queue depth. If it approaches capacity, consider scaling router replicas.

### If destination is permanently unreachable:

1. Pause the router to prevent log noise:
   ```bash
   kubectl -n observability-hub scale deployment/otel-router-splunk --replicas=0
   ```

2. Data is preserved in Redpanda. When the destination is restored:
   ```bash
   kubectl -n observability-hub scale deployment/otel-router-splunk --replicas=2
   ```
   The router will resume consuming from the last committed offset.

### If Redpanda itself is unhealthy:

See [scaling runbook](scaling.md) for Redpanda recovery procedures.

## Impact

- Other destinations are **NOT affected** (independent consumers)
- Edge clusters continue sending data normally (gateway writes to Redpanda)
- Data loss risk only if Redpanda retention expires before destination recovers
