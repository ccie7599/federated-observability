# Federated Observability Platform - Claude Code Instructions

## Project Context

You are building a **federated observability platform** for a Fortune 5 bank (think JPMC-level security requirements). The platform collects metrics, logs, and traces from distributed LKE (Linode Kubernetes Engine) clusters and routes them to multiple enterprise destinations.

### Business Requirements

1. **Multi-cluster ingestion**: 10-50 LKE clusters sending telemetry to a central hub
2. **Multiple destinations**: Splunk (SIEM/logs), Datadog (APM), Customer OTLP endpoint
3. **Enterprise security**: mTLS everywhere, PII scrubbing before egress, audit trail
4. **High availability**: No data loss during destination outages or maintenance
5. **Compliance**: Data residency awareness, replay capability for audits

### Technical Constraints

- All telemetry uses OpenTelemetry (OTLP) protocol
- Bank firewalls require HTTPS on port 443 (no raw gRPC on 4317)
- Must support backpressure and persistent queuing
- PII must be scrubbed at the edge before leaving source clusters
- Need internal observability (Grafana stack) independent of customer destinations

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  EDGE: LKE Cluster (one per customer environment)                           │
│                                                                             │
│  ┌─────────────┐      ┌─────────────────────────────────────────────────┐  │
│  │ Application │      │ OTel Collector Agent (DaemonSet)                │  │
│  │ Pods w/     │─────▶│ - Receives OTLP from app SDKs                   │  │
│  │ OTel SDK    │      │ - Adds k8s metadata (pod, node, namespace)      │  │
│  └─────────────┘      │ - Forwards to aggregator                        │  │
│                       └──────────────────┬──────────────────────────────┘  │
│                                          │                                  │
│                                          ▼                                  │
│                       ┌─────────────────────────────────────────────────┐  │
│                       │ OTel Collector Aggregator (Deployment, 2+ pods) │  │
│                       │ - PII detection and scrubbing                   │  │
│                       │ - Tail-based trace sampling                     │  │
│                       │ - Metrics pre-aggregation                       │  │
│                       │ - Batch compression (zstd)                      │  │
│                       │ - Persistent queue (survives restarts)          │  │
│                       │ - mTLS client cert authentication               │  │
│                       └──────────────────┬──────────────────────────────┘  │
└──────────────────────────────────────────┼──────────────────────────────────┘
                                           │
                                           │ HTTPS/OTLP (mTLS) port 443
                                           │
┌──────────────────────────────────────────┼──────────────────────────────────┐
│  HUB: Federation Hub (dedicated LKE cluster)                                │
│                                          │                                  │
│                                          ▼                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Ingress (nginx or envoy)                                            │   │
│  │ - TLS termination                                                   │   │
│  │ - mTLS client cert validation                                       │   │
│  │ - Rate limiting per cluster                                         │   │
│  └──────────────────────────────────┬──────────────────────────────────┘   │
│                                     │                                       │
│                                     ▼                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ OTel Gateway (Deployment, 3+ replicas, HPA)                         │   │
│  │ - Receives OTLP/HTTP                                                │   │
│  │ - Validates and enriches                                            │   │
│  │ - Writes to Kafka/Redpanda                                          │   │
│  └──────────────────────────────────┬──────────────────────────────────┘   │
│                                     │                                       │
│                                     ▼                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │ Redpanda (StatefulSet, 3 brokers)                                   │   │
│  │ Topics:                                                             │   │
│  │ - otlp.metrics (retention: 7d)                                      │   │
│  │ - otlp.logs (retention: 7d)                                         │   │
│  │ - otlp.traces (retention: 3d)                                       │   │
│  │ - otlp.dlq (dead letter queue, retention: 30d)                      │   │
│  └──────────────────────────────────┬──────────────────────────────────┘   │
│                                     │                                       │
│              ┌──────────────────────┼──────────────────────┐               │
│              │                      │                      │               │
│              ▼                      ▼                      ▼               │
│  ┌───────────────────┐  ┌───────────────────┐  ┌───────────────────┐      │
│  │ OTel Router       │  │ OTel Router       │  │ OTel Router       │      │
│  │ (Splunk)          │  │ (Datadog)         │  │ (Customer OTLP)   │      │
│  │                   │  │                   │  │                   │      │
│  │ - Kafka consumer  │  │ - Kafka consumer  │  │ - Kafka consumer  │      │
│  │ - Transform       │  │ - Transform       │  │ - Transform       │      │
│  │ - Splunk HEC out  │  │ - DD API out      │  │ - OTLP out        │      │
│  └─────────┬─────────┘  └─────────┬─────────┘  └─────────┬─────────┘      │
│            │                      │                      │                 │
└────────────┼──────────────────────┼──────────────────────┼─────────────────┘
             │                      │                      │
             ▼                      ▼                      ▼
      ┌──────────┐           ┌──────────┐           ┌──────────┐
      │  Splunk  │           │ Datadog  │           │ Customer │
      │  Cloud   │           │          │           │ OTLP     │
      └──────────┘           └──────────┘           └──────────┘


INTERNAL OBSERVABILITY (also on Hub cluster):

┌─────────────────────────────────────────────────────────────────────────────┐
│  Internal Stack (your team's visibility, independent of customer backends)  │
│                                                                             │
│  Redpanda ──▶ OTel Router (Internal) ──┬──▶ VictoriaMetrics (metrics)      │
│                                        ├──▶ Loki (logs)                     │
│                                        └──▶ Tempo (traces)                  │
│                                                    │                        │
│                                                    ▼                        │
│                                              ┌──────────┐                   │
│                                              │ Grafana  │                   │
│                                              └──────────┘                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Directory Structure

Create this structure:

```
federated-observability/
├── CLAUDE.md                 # This file
├── README.md                 # Project overview
├── Makefile                  # Common operations
│
├── base/                     # Kustomize base resources
│   ├── kustomization.yaml
│   └── namespace.yaml
│
├── edge-collector/           # Deployed to each LKE source cluster
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── agent-daemonset.yaml
│   ├── agent-config.yaml
│   ├── aggregator-deployment.yaml
│   ├── aggregator-config.yaml
│   ├── aggregator-hpa.yaml
│   ├── aggregator-pdb.yaml
│   ├── servicemonitor.yaml   # Self-monitoring
│   └── overlays/
│       ├── dev/
│       │   └── kustomization.yaml
│       ├── staging/
│       │   └── kustomization.yaml
│       └── prod/
│           └── kustomization.yaml
│
├── hub-gateway/              # Ingress + OTel Gateway on hub cluster
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── gateway-deployment.yaml
│   ├── gateway-config.yaml
│   ├── gateway-hpa.yaml
│   ├── gateway-pdb.yaml
│   ├── ingress.yaml
│   ├── cert-manager/         # mTLS certificate management
│   │   ├── cluster-issuer.yaml
│   │   ├── gateway-cert.yaml
│   │   └── client-ca-secret.yaml
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── hub-storage/              # Redpanda on hub cluster
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── redpanda-statefulset.yaml
│   ├── redpanda-config.yaml
│   ├── redpanda-service.yaml
│   ├── topics.yaml           # Topic definitions
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── hub-routing/              # Destination routers on hub cluster
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── router-splunk/
│   │   ├── deployment.yaml
│   │   ├── config.yaml
│   │   └── secret.yaml       # HEC token (sealed/external-secrets)
│   ├── router-datadog/
│   │   ├── deployment.yaml
│   │   ├── config.yaml
│   │   └── secret.yaml       # API key
│   ├── router-otlp/
│   │   ├── deployment.yaml
│   │   └── config.yaml
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── hub-internal/             # Internal observability stack
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── victoria-metrics/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── config.yaml
│   ├── loki/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── config.yaml
│   ├── tempo/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   └── config.yaml
│   ├── grafana/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── configmap.yaml
│   │   └── dashboards/
│   │       ├── overview.json
│   │       ├── edge-health.json
│   │       └── destination-health.json
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
│
├── secrets/                  # External Secrets or Sealed Secrets configs
│   ├── external-secrets.yaml
│   └── sealed-secrets/
│
├── policies/                 # OPA/Kyverno policies
│   ├── require-mtls.yaml
│   ├── pii-scrubbing-required.yaml
│   └── resource-limits.yaml
│
├── scripts/
│   ├── generate-client-cert.sh    # Generate mTLS certs for edge clusters
│   ├── rotate-certs.sh
│   ├── validate-config.sh
│   └── load-test.sh               # k6 or locust based load testing
│
├── docs/
│   ├── architecture.md
│   ├── deployment-guide.md
│   ├── security.md
│   ├── runbooks/
│   │   ├── destination-outage.md
│   │   ├── certificate-rotation.md
│   │   └── scaling.md
│   └── adr/                       # Architecture Decision Records
│       ├── 001-otlp-over-https.md
│       ├── 002-redpanda-vs-kafka.md
│       └── 003-pii-scrubbing-at-edge.md
│
└── tests/
    ├── e2e/
    │   └── test-pipeline.yaml     # Trace/metric injection tests
    └── unit/
        └── config-validation/
```

---

## Key Configuration Files

### 1. Edge Collector Agent (DaemonSet)

File: `edge-collector/agent-config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      
      # Scrape node-level metrics
      hostmetrics:
        collection_interval: 30s
        scrapers:
          cpu:
          memory:
          disk:
          network:
      
      # Kubernetes events and metadata
      k8s_events:
        namespaces: [all]
      
      # Container logs via filelog
      filelog:
        include:
          - /var/log/pods/*/*/*.log
        operators:
          - type: router
            routes:
              - expr: 'body matches "^\\{"'
                output: json_parser
              - expr: 'true'
                output: regex_parser
          - id: json_parser
            type: json_parser
            timestamp:
              parse_from: attributes.time
              layout: '%Y-%m-%dT%H:%M:%S.%LZ'
          - id: regex_parser
            type: regex_parser
            regex: '^(?P<time>[^ ]+) (?P<stream>stdout|stderr) (?P<flags>[^ ]*) (?P<log>.*)$'
    
    processors:
      # Add Kubernetes metadata
      k8sattributes:
        auth_type: serviceAccount
        extract:
          metadata:
            - k8s.pod.name
            - k8s.pod.uid
            - k8s.namespace.name
            - k8s.node.name
            - k8s.deployment.name
          labels:
            - tag_name: app
              key: app.kubernetes.io/name
            - tag_name: version
              key: app.kubernetes.io/version
      
      # Resource detection
      resourcedetection:
        detectors: [env, system]
        timeout: 5s
      
      # Memory limiter to prevent OOM
      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100
      
      # Batch for efficiency
      batch:
        send_batch_size: 1000
        send_batch_max_size: 1500
        timeout: 10s
    
    exporters:
      otlp:
        endpoint: otel-aggregator.observability.svc.cluster.local:4317
        tls:
          insecure: true  # Internal cluster traffic
    
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679
    
    service:
      extensions: [health_check, zpages]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        metrics:
          receivers: [otlp, hostmetrics]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, batch]
          exporters: [otlp]
```

### 2. Edge Collector Aggregator (Deployment)

File: `edge-collector/aggregator-config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-aggregator-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    
    processors:
      # Memory safety
      memory_limiter:
        check_interval: 1s
        limit_mib: 1800
        spike_limit_mib: 400
      
      # PII Scrubbing - CRITICAL FOR BANK COMPLIANCE
      transform:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              # Redact email addresses
              - replace_pattern(body, "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b", "[EMAIL_REDACTED]")
              # Redact SSN patterns
              - replace_pattern(body, "\\b\\d{3}-\\d{2}-\\d{4}\\b", "[SSN_REDACTED]")
              # Redact credit card numbers (basic pattern)
              - replace_pattern(body, "\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b", "[CC_REDACTED]")
              # Redact phone numbers
              - replace_pattern(body, "\\b\\d{3}[-.\\s]?\\d{3}[-.\\s]?\\d{4}\\b", "[PHONE_REDACTED]")
        trace_statements:
          - context: span
            statements:
              # Scrub sensitive attributes
              - replace_pattern(attributes["http.url"], "password=[^&]*", "password=[REDACTED]")
              - replace_pattern(attributes["http.url"], "token=[^&]*", "token=[REDACTED]")
              - replace_pattern(attributes["http.url"], "api_key=[^&]*", "api_key=[REDACTED]")
              - delete_key(attributes, "user.email") where attributes["user.email"] != nil
              - delete_key(attributes, "user.ssn") where attributes["user.ssn"] != nil
      
      # Remove sensitive attribute keys entirely
      attributes:
        actions:
          - key: db.statement
            action: hash
          - key: http.request.header.authorization
            action: delete
          - key: http.request.header.cookie
            action: delete
          - key: http.request.header.x-api-key
            action: delete
      
      # Filter out noisy/unwanted data
      filter:
        error_mode: ignore
        logs:
          log_record:
            - 'severity_number < SEVERITY_NUMBER_INFO'  # Drop DEBUG and below
            - 'IsMatch(body, "healthcheck")'
            - 'IsMatch(body, "readiness")'
            - 'IsMatch(body, "liveness")'
        traces:
          span:
            - 'name == "health"'
            - 'name == "ready"'
            - 'name == "live"'
      
      # Tail-based sampling for traces (keep errors, slow, sample rest)
      tail_sampling:
        decision_wait: 10s
        num_traces: 100000
        policies:
          - name: errors-always
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: slow-traces
            type: latency
            latency:
              threshold_ms: 1000
          - name: high-value-services
            type: string_attribute
            string_attribute:
              key: service.name
              values: [payment-service, auth-service, transaction-service]
          - name: probabilistic-sample
            type: probabilistic
            probabilistic:
              sampling_percentage: 10
      
      # Pre-aggregate metrics to reduce cardinality
      metricstransform:
        transforms:
          - include: ^http_server_request_duration.*
            match_type: regexp
            action: update
            operations:
              - action: aggregate_labels
                aggregation_type: sum
                label_set: [http_method, http_status_code, service_name]
      
      # Batch with compression
      batch:
        send_batch_size: 5000
        send_batch_max_size: 10000
        timeout: 30s
    
    exporters:
      otlphttp:
        endpoint: https://hub.observability.example.com:443
        compression: zstd
        tls:
          cert_file: /certs/client.crt
          key_file: /certs/client.key
          ca_file: /certs/ca.crt
        headers:
          X-Cluster-ID: ${env:CLUSTER_ID}
          X-Environment: ${env:ENVIRONMENT}
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 60s
          max_elapsed_time: 300s
        sending_queue:
          enabled: true
          num_consumers: 10
          queue_size: 10000
          storage: file_storage
    
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      file_storage:
        directory: /var/otel/queue
        timeout: 10s
        compaction:
          on_start: true
          on_rebound: true
          directory: /var/otel/queue/compaction
    
    service:
      extensions: [health_check, file_storage]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, transform, attributes, filter, tail_sampling, batch]
          exporters: [otlphttp]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, transform, attributes, filter, metricstransform, batch]
          exporters: [otlphttp]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, transform, attributes, filter, batch]
          exporters: [otlphttp]
```

### 3. Hub Gateway Config

File: `hub-gateway/gateway-config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-gateway-config
  namespace: observability-hub
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 0.0.0.0:4318
            cors:
              allowed_origins: []
              allowed_headers: ["X-Cluster-ID", "X-Environment"]
            # TLS handled by ingress
    
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 3500
        spike_limit_mib: 800
      
      # Add hub-level metadata
      resource:
        attributes:
          - key: hub.received_at
            value: ${env:HOSTNAME}
            action: insert
          - key: hub.region
            value: ${env:HUB_REGION}
            action: insert
      
      # Validate required attributes exist
      filter:
        error_mode: ignore
        traces:
          span:
            - 'attributes["service.name"] == nil'  # Drop spans without service name
        metrics:
          metric:
            - 'resource.attributes["service.name"] == nil'
      
      batch:
        send_batch_size: 10000
        timeout: 5s
    
    exporters:
      kafka/metrics:
        brokers:
          - redpanda-0.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-1.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-2.redpanda.observability-hub.svc.cluster.local:9093
        topic: otlp.metrics
        encoding: otlp_proto
        producer:
          compression: zstd
          max_message_bytes: 10000000
          required_acks: -1  # Wait for all replicas
        auth:
          tls:
            cert_file: /certs/kafka-client.crt
            key_file: /certs/kafka-client.key
            ca_file: /certs/kafka-ca.crt
      
      kafka/logs:
        brokers:
          - redpanda-0.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-1.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-2.redpanda.observability-hub.svc.cluster.local:9093
        topic: otlp.logs
        encoding: otlp_proto
        producer:
          compression: zstd
          max_message_bytes: 10000000
          required_acks: -1
        auth:
          tls:
            cert_file: /certs/kafka-client.crt
            key_file: /certs/kafka-client.key
            ca_file: /certs/kafka-ca.crt
      
      kafka/traces:
        brokers:
          - redpanda-0.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-1.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-2.redpanda.observability-hub.svc.cluster.local:9093
        topic: otlp.traces
        encoding: otlp_proto
        producer:
          compression: zstd
          max_message_bytes: 10000000
          required_acks: -1
        auth:
          tls:
            cert_file: /certs/kafka-client.crt
            key_file: /certs/kafka-client.key
            ca_file: /certs/kafka-ca.crt
    
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679
    
    service:
      extensions: [health_check, zpages]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, filter, batch]
          exporters: [kafka/traces]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource, filter, batch]
          exporters: [kafka/metrics]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, filter, batch]
          exporters: [kafka/logs]
```

### 4. Splunk Router Config

File: `hub-routing/router-splunk/config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-router-splunk-config
  namespace: observability-hub
data:
  config.yaml: |
    receivers:
      kafka:
        brokers:
          - redpanda-0.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-1.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-2.redpanda.observability-hub.svc.cluster.local:9093
        topic: otlp.logs
        encoding: otlp_proto
        group_id: router-splunk-logs
        auth:
          tls:
            cert_file: /certs/kafka-client.crt
            key_file: /certs/kafka-client.key
            ca_file: /certs/kafka-ca.crt
    
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 1500
        spike_limit_mib: 300
      
      # Transform to Splunk-friendly format
      transform:
        log_statements:
          - context: log
            statements:
              - set(attributes["index"], "main") where attributes["index"] == nil
              - set(attributes["sourcetype"], Concat(["otel:", resource.attributes["service.name"]], ""))
      
      batch:
        send_batch_size: 8000
        timeout: 10s
    
    exporters:
      splunk_hec:
        endpoint: https://splunk-hec.customer.example.com:8088
        token: ${env:SPLUNK_HEC_TOKEN}
        source: otel
        sourcetype: otel
        index: main
        tls:
          ca_file: /certs/splunk-ca.crt
        retry_on_failure:
          enabled: true
          initial_interval: 10s
          max_interval: 60s
        sending_queue:
          enabled: true
          queue_size: 5000
          storage: file_storage
    
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      file_storage:
        directory: /var/otel/queue
    
    service:
      extensions: [health_check, file_storage]
      pipelines:
        logs:
          receivers: [kafka]
          processors: [memory_limiter, transform, batch]
          exporters: [splunk_hec]
```

### 5. Datadog Router Config

File: `hub-routing/router-datadog/config.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-router-datadog-config
  namespace: observability-hub
data:
  config.yaml: |
    receivers:
      kafka/metrics:
        brokers:
          - redpanda-0.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-1.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-2.redpanda.observability-hub.svc.cluster.local:9093
        topic: otlp.metrics
        encoding: otlp_proto
        group_id: router-datadog-metrics
        auth:
          tls:
            cert_file: /certs/kafka-client.crt
            key_file: /certs/kafka-client.key
            ca_file: /certs/kafka-ca.crt
      
      kafka/traces:
        brokers:
          - redpanda-0.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-1.redpanda.observability-hub.svc.cluster.local:9093
          - redpanda-2.redpanda.observability-hub.svc.cluster.local:9093
        topic: otlp.traces
        encoding: otlp_proto
        group_id: router-datadog-traces
        auth:
          tls:
            cert_file: /certs/kafka-client.crt
            key_file: /certs/kafka-client.key
            ca_file: /certs/kafka-ca.crt
    
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 2000
        spike_limit_mib: 500
      
      batch:
        send_batch_size: 5000
        timeout: 10s
    
    exporters:
      datadog:
        api:
          key: ${env:DD_API_KEY}
          site: datadoghq.com
        traces:
          span_name_as_resource_name: true
        metrics:
          resource_attributes_as_tags: true
        retry_on_failure:
          enabled: true
          initial_interval: 10s
          max_interval: 60s
        sending_queue:
          enabled: true
          queue_size: 5000
          storage: file_storage
    
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      file_storage:
        directory: /var/otel/queue
    
    service:
      extensions: [health_check, file_storage]
      pipelines:
        traces:
          receivers: [kafka/traces]
          processors: [memory_limiter, batch]
          exporters: [datadog]
        metrics:
          receivers: [kafka/metrics]
          processors: [memory_limiter, batch]
          exporters: [datadog]
```

---

## Tasks for Claude Code

When I say "scaffold the project", create the full directory structure and all configuration files listed above.

When I say "add a new destination", ask me for:
1. Destination name (e.g., "elastic", "newrelic")
2. Destination type (metrics, logs, traces, or combination)
3. Authentication method
4. Any special transformation requirements

Then create a new router under `hub-routing/router-{name}/` with appropriate config.

When I say "add a new edge cluster", generate:
1. A new client certificate using the script
2. Kustomize overlay for that cluster
3. ArgoCD Application manifest if using GitOps

When I say "validate configs", run:
1. `otelcol validate --config=<file>` on all collector configs
2. Kustomize build dry-run on all overlays
3. Kubeval/kubeconform on generated manifests

---

## Security Checklist

Before deploying to production, verify:

- [ ] All OTLP endpoints use mTLS
- [ ] PII scrubbing processors are enabled on all edge aggregators
- [ ] Redpanda has TLS enabled with SASL authentication
- [ ] All secrets are managed via External Secrets or Sealed Secrets
- [ ] Network policies restrict traffic to expected flows
- [ ] Pod Security Standards are enforced (restricted or baseline)
- [ ] Resource limits are set on all containers
- [ ] PDBs prevent accidental full outages
- [ ] Audit logging is enabled on the hub cluster
- [ ] Client certificates have appropriate expiry and rotation

---

## Common Operations

```bash
# Deploy edge collector to a cluster
kubectl apply -k edge-collector/overlays/prod/

# Deploy hub components
kubectl apply -k hub-gateway/overlays/prod/
kubectl apply -k hub-storage/overlays/prod/
kubectl apply -k hub-routing/overlays/prod/

# Generate a new client cert for edge cluster
./scripts/generate-client-cert.sh cluster-name

# Validate all configs
./scripts/validate-config.sh

# Load test the pipeline
./scripts/load-test.sh --rps 10000 --duration 5m

# Check hub gateway health
kubectl -n observability-hub port-forward svc/otel-gateway 13133:13133
curl http://localhost:13133/health

# View Redpanda topic lag
kubectl -n observability-hub exec -it redpanda-0 -- rpk topic consume otlp.logs --num 1
```

---

## Environment Variables Reference

### Edge Collector
| Variable | Description | Example |
|----------|-------------|---------|
| `CLUSTER_ID` | Unique identifier for this cluster | `lke-us-east-prod-01` |
| `ENVIRONMENT` | Environment name | `production` |
| `HUB_ENDPOINT` | Federation hub URL | `https://hub.observability.example.com` |

### Hub Gateway
| Variable | Description | Example |
|----------|-------------|---------|
| `HUB_REGION` | Region identifier | `us-east-1` |

### Hub Routers
| Variable | Description | Example |
|----------|-------------|---------|
| `SPLUNK_HEC_TOKEN` | Splunk HEC authentication token | `(from secrets manager)` |
| `DD_API_KEY` | Datadog API key | `(from secrets manager)` |
| `CUSTOMER_OTLP_ENDPOINT` | Customer's OTLP endpoint | `https://otlp.customer.com:4317` |

---

## GitHub Repository Setup

After creating the project structure, initialize as:

```bash
cd federated-observability
git init
git add .
git commit -m "Initial scaffold: federated observability platform"

# Create GitHub repo (requires gh CLI)
gh repo create akamai/federated-observability --private --source=. --push

# Set up branch protection
gh api repos/akamai/federated-observability/branches/main/protection \
  -X PUT \
  -F required_status_checks='{"strict":true,"contexts":["validate-configs","kustomize-build"]}' \
  -F enforce_admins=true \
  -F required_pull_request_reviews='{"required_approving_review_count":1}'
```

---

## CI/CD Pipeline

Create `.github/workflows/validate.yaml`:

```yaml
name: Validate Configs

on:
  pull_request:
    paths:
      - '**/*.yaml'
      - '**/*.yml'

jobs:
  validate-otel:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install otelcol
        run: |
          curl -LO https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.96.0/otelcol-contrib_0.96.0_linux_amd64.tar.gz
          tar -xzf otelcol-contrib_0.96.0_linux_amd64.tar.gz
          sudo mv otelcol-contrib /usr/local/bin/
      
      - name: Validate collector configs
        run: |
          for config in $(find . -name '*-config.yaml' -path '*/edge-collector/*' -o -name '*-config.yaml' -path '*/hub-*/*'); do
            echo "Validating $config"
            otelcol-contrib validate --config=$config
          done

  kustomize-build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install kustomize
        run: |
          curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/
      
      - name: Build all overlays
        run: |
          for overlay in $(find . -type d -name 'overlays' -exec find {} -mindepth 1 -maxdepth 1 -type d \;); do
            echo "Building $overlay"
            kustomize build $overlay > /dev/null
          done

  kubeconform:
    runs-on: ubuntu-latest
    needs: kustomize-build
    steps:
      - uses: actions/checkout@v4
      
      - name: Install tools
        run: |
          curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/
          curl -LO https://github.com/yannh/kubeconform/releases/download/v0.6.4/kubeconform-linux-amd64.tar.gz
          tar -xzf kubeconform-linux-amd64.tar.gz
          sudo mv kubeconform /usr/local/bin/
      
      - name: Validate Kubernetes manifests
        run: |
          for overlay in $(find . -type d -name 'overlays' -exec find {} -mindepth 1 -maxdepth 1 -type d \;); do
            echo "Validating $overlay"
            kustomize build $overlay | kubeconform -strict -summary
          done
```

---

## Next Steps

1. **Scaffold the project** - Create all directories and config files
2. **Set up CI** - Add GitHub Actions for config validation
3. **Deploy dev environment** - Start with single edge cluster → hub
4. **Add destinations incrementally** - Splunk first, then Datadog, then customer OTLP
5. **Security hardening** - Enable mTLS, add network policies
6. **Load testing** - Validate throughput meets requirements
7. **Documentation** - Runbooks for common operations and incident response
