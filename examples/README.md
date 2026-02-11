# Example Workloads

These are example applications used to generate telemetry traffic for testing the federated observability platform. They are **not** part of the core platform — any workload running on LKE can emit metrics, traces, and logs through the OTel pipeline.

## Inference (BERT GPU)

A GPU-accelerated BERT NLP inference server instrumented with OpenTelemetry auto-instrumentation for Python. Demonstrates:

- OTLP trace/metric/log export to the OTel agent via `OTEL_EXPORTER_OTLP_ENDPOINT`
- Prometheus `/metrics` endpoint scraped by the OTel scraper
- GPU workload monitored by dcgm-exporter

**Deployed to:** `bert-inference` namespace on both hub and edge clusters.

See [`inference/deployment.yaml`](inference/deployment.yaml) for the OTel environment variables pattern that works with any Python application.

## Vault (HashiCorp Vault)

A 3-node HashiCorp Vault HA cluster using Raft storage. Demonstrates:

- StatefulSet workload generating Kubernetes state metrics (via kube-state-metrics)
- Container logs collected by the OTel agent's filelog receiver
- RBAC and ServiceAccount patterns

**Deployed to:** `vault` namespace on the hub cluster.
