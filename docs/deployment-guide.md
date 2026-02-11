# Federated Observability on Linode Kubernetes Engine

A complete guide to deploying multi-cluster, multi-region observability using OpenTelemetry and the Grafana stack on Akamai Cloud (LKE).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Deploy the Hub Cluster](#3-deploy-the-hub-cluster)
4. [Deploy Edge Clusters](#4-deploy-edge-clusters)
5. [Instrumenting Your Applications](#5-instrumenting-your-applications)
6. [Configuring External Destinations](#6-configuring-external-destinations)
7. [Trace Demo: End-to-End Walkthrough](#7-trace-demo-end-to-end-walkthrough)
8. [Troubleshooting and Testing](#8-troubleshooting-and-testing)
9. [Scaling to Production](#9-scaling-to-production)

---

## 1. Architecture Overview

### Hub-and-Spoke Model

Federated observability follows a **hub-and-spoke** pattern. One dedicated LKE cluster acts as the central hub for telemetry ingestion, storage, and visualization. All other clusters (edge clusters) collect local telemetry and forward it to the hub over OTLP/gRPC.

```
 EDGE CLUSTER A (us-east)         EDGE CLUSTER B (eu-west)        EDGE CLUSTER C (ap-south)
 ─────────────────────────        ─────────────────────────       ──────────────────────────

 ┌──────────────────────┐         ┌──────────────────────┐        ┌──────────────────────┐
 │ Your Workloads       │         │ Your Workloads       │        │ Your Workloads       │
 │ (any app/language)   │         │ (any app/language)   │        │ (any app/language)   │
 └──────────┬───────────┘         └──────────┬───────────┘        └──────────┬───────────┘
            │ OTLP                            │ OTLP                          │ OTLP
            ▼                                 ▼                               ▼
 ┌──────────────────────┐         ┌──────────────────────┐        ┌──────────────────────┐
 │ OTel Agent (DaemonSet)│        │ OTel Agent (DaemonSet)│       │ OTel Agent (DaemonSet)│
 │  + kubeletstats      │         │  + kubeletstats      │        │  + kubeletstats      │
 │  + filelog (pod logs)│         │  + filelog (pod logs)│        │  + filelog (pod logs)│
 │  + k8s metadata      │         │  + k8s metadata      │        │  + k8s metadata      │
 │                      │         │                      │        │                      │
 │ OTel Scraper         │         │ OTel Scraper         │        │ OTel Scraper         │
 │  + kube-state-metrics│         │  + kube-state-metrics│        │  + kube-state-metrics│
 │  + app /metrics      │         │  + app /metrics      │        │  + app /metrics      │
 └──────────┬───────────┘         └──────────┬───────────┘        └──────────┬───────────┘
            │                                 │                               │
            │ OTLP/gRPC (port 4317)           │                               │
            └──────────────────┐              │              ┌────────────────┘
                               │              │              │
                               ▼              ▼              ▼
                      ┌─────────────────────────────────────────┐
                      │          HUB CLUSTER (us-ord)           │
                      │                                         │
                      │  ┌───────────────────────────────────┐  │
                      │  │ OTel Gateway (LoadBalancer)       │  │
                      │  │  + memory_limiter                 │  │
                      │  │  + resource enrichment            │  │
                      │  │  + batch                          │  │
                      │  └──────────────┬────────────────────┘  │
                      │                 │                        │
                      │    ┌────────────┼────────────┐          │
                      │    ▼            ▼            ▼          │
                      │ Prometheus    Loki        Tempo         │
                      │ (metrics)    (logs)      (traces)       │
                      │    └────────────┼────────────┘          │
                      │                 ▼                        │
                      │             Grafana                      │
                      │        (single pane of glass)            │
                      │                                         │
                      │  Optional: fan-out to external backends │
                      │  ├── Splunk HEC (logs)                  │
                      │  ├── Datadog (metrics + traces)         │
                      │  └── Customer OTLP endpoint             │
                      └─────────────────────────────────────────┘
```

### What Gets Collected Automatically

Once deployed, every cluster automatically collects:

| Signal | Source | Receiver | Metrics Count |
|--------|--------|----------|--------------|
| **Node metrics** | kubelet API | `kubeletstats` receiver (DaemonSet) | ~37 (CPU, memory, disk, network per node/pod/container) |
| **Kubernetes state** | kube-state-metrics | OTel `prometheus` receiver (Scraper) | ~152 (pod status, deployment replicas, daemonset status, etc.) |
| **Container logs** | `/var/log/pods/` | `filelog` receiver (DaemonSet) | All pod stdout/stderr |
| **Application metrics** | App `/metrics` endpoint | OTel `prometheus` receiver (Scraper) | Varies by app |
| **Application traces** | App OTel SDK | `otlp` receiver (DaemonSet) | Varies by app |
| **Application logs** | App OTel SDK | `otlp` receiver (DaemonSet) | Varies by app |
| **GPU metrics** | DCGM exporter | OTel `prometheus` receiver (Scraper) | ~19 (utilization, memory, temp, power) |

### Data Flow

All telemetry follows the same path regardless of origin cluster:

```
Source (edge or hub) ──OTLP/gRPC──▶ Gateway ──▶ Prometheus (metrics via remote-write)
                                             ──▶ Loki (logs via Loki push API)
                                             ──▶ Tempo (traces via OTLP/gRPC)
```

Every metric, log, and trace carries:
- `cluster.id` — identifies the source cluster (e.g., `my-prod-cluster-us-east`)
- `cluster.role` — `hub` or `edge`
- `hub.received_at` — gateway pod that processed it (proves it traversed the hub)
- Kubernetes metadata — pod name, namespace, node, deployment (added by k8sattributes processor)

---

## 2. Prerequisites

### Required Tools

```bash
# Linode CLI (for cluster provisioning)
pip3 install linode-cli
linode-cli configure  # Enter your API token

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# kustomize (optional, for overlay builds)
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
sudo mv kustomize /usr/local/bin/
```

### Cluster Sizing

| Role | Minimum Nodes | Recommended | Purpose |
|------|--------------|-------------|---------|
| **Hub** | 3x g6-standard-4 (8 CPU, 16 GB each) | 3-5x g6-standard-4 | Gateway, Prometheus, Loki, Tempo, Grafana |
| **Edge** | 2x g6-standard-2 (4 CPU, 8 GB each) | 2-4x g6-standard-2 | OTel agents, your workloads |
| **Edge (GPU)** | Add 1x g2-gpu-* per GPU workload | Varies | GPU inference, DCGM exporter |

### Network Requirements

| From | To | Port | Protocol | Purpose |
|------|----|------|----------|---------|
| Edge clusters | Hub gateway LB | 4317 | gRPC (OTLP) | Telemetry export |
| Edge clusters | Hub gateway LB | 4318 | HTTP (OTLP) | Telemetry export (alternative) |
| Your browser | Hub Grafana LB | 3000 | HTTP | Dashboard access |
| Hub internal | Prometheus | 9090 | HTTP | Metrics storage |
| Hub internal | Loki | 3100 | HTTP | Log storage |
| Hub internal | Tempo | 4317 | gRPC | Trace storage |

---

## 3. Deploy the Hub Cluster

### 3.1 Create the Hub LKE Cluster

```bash
linode-cli lke cluster-create \
  --label my-observability-hub \
  --region us-ord \
  --k8s_version 1.33 \
  --tags "observability" --tags "hub" \
  --node_pools '[
    {"type":"g6-standard-4","count":3,"autoscaler":{"enabled":true,"min":3,"max":5}}
  ]'
```

Save the cluster ID from the output (e.g., `564853`).

```bash
# Download kubeconfig
CLUSTER_ID=564853
linode-cli lke kubeconfig-view $CLUSTER_ID --text --no-headers | base64 -d > /tmp/hub-kubeconfig.yaml

# Merge into your kubeconfig
KUBECONFIG=~/.kube/config:/tmp/hub-kubeconfig.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config

# Set alias for convenience
HUB_CTX="lke${CLUSTER_ID}-ctx"
kubectl --context $HUB_CTX get nodes
```

Wait for all nodes to be `Ready` (~90 seconds for standard nodes).

### 3.2 Deploy the Monitoring Stack

The monitoring stack provides Prometheus, Loki, Tempo, and Grafana on the hub cluster. All manifests are in [`hub/monitoring/`](../hub/monitoring/).

| Component | Config | Purpose |
|-----------|--------|---------|
| [Prometheus](../hub/monitoring/prometheus/) | Remote-write receiver only (no scraping) | Metrics storage, PromQL queries |
| [Loki](../hub/monitoring/loki/) | Filesystem storage, 7-day retention | Log aggregation |
| [Tempo](../hub/monitoring/tempo/) | OTLP receiver, metrics generator → Prometheus | Distributed tracing |
| [Grafana](../hub/monitoring/grafana/) | Pre-provisioned datasources + 4 dashboards | Visualization |
| [dcgm-exporter](../hub/monitoring/dcgm-exporter.yaml) | DaemonSet on GPU nodes | GPU metrics |

```bash
kubectl --context $HUB_CTX apply -k hub/monitoring/
```

> **Key detail:** Prometheus runs with `--web.enable-remote-write-receiver` so it accepts incoming metrics from the OTel gateway. It does not scrape any targets directly — OTel is the single source of truth. See [`hub/monitoring/prometheus/config.yaml`](../hub/monitoring/prometheus/config.yaml).

Wait for all pods to be ready:

```bash
kubectl --context $HUB_CTX get pods -n monitoring -w
```

Get the Grafana external IP:

```bash
kubectl --context $HUB_CTX get svc grafana-external -n monitoring
# EXTERNAL-IP will be assigned in 1-2 minutes
```

### 3.3 Deploy Observability Agents

The observability namespace hosts the OTel DaemonSet agent, OTel scraper, and kube-state-metrics. All manifests are in [`hub/observability/`](../hub/observability/).

| Component | Type | Config | Purpose |
|-----------|------|--------|---------|
| [OTel Agent](../hub/observability/agent/) | DaemonSet | OTLP + kubeletstats + filelog receivers | Collects from every node |
| [OTel Scraper](../hub/observability/scraper/) | Deployment | Prometheus receiver with k8s SD | Scrapes `/metrics` endpoints |
| [kube-state-metrics](../hub/observability/kube-state-metrics.yaml) | Deployment | v2.13.0 | Kubernetes object state metrics |

Before deploying, update the `cluster.id` in the agent and scraper configs to match your cluster name:

```bash
# Edit hub/observability/agent/config.yaml — set cluster.id value
# Edit hub/observability/scraper/config.yaml — set cluster.id value
```

Then deploy:

```bash
kubectl --context $HUB_CTX apply -k hub/observability/
```

> **Important:** The kubeletstats receiver uses `K8S_NODE_IP` (from `status.hostIP`), not `K8S_NODE_NAME`. On LKE, node hostnames are not DNS-resolvable, so using the node IP is required. See the DaemonSet env vars in [`hub/observability/agent/daemonset.yaml`](../hub/observability/agent/daemonset.yaml).

Verify agents are running on all nodes:

```bash
kubectl --context $HUB_CTX get ds otel-agent -n observability
# DESIRED = CURRENT = READY should match your node count
```

### 3.4 Deploy OTel Gateway

The gateway is the central ingestion point. It receives OTLP from all agents (hub and edge clusters), enriches data with a `hub.received_at` label, and fans out to Prometheus, Loki, and Tempo. Manifests are in [`hub/gateway/`](../hub/gateway/).

The gateway config ([`hub/gateway/config.yaml`](../hub/gateway/config.yaml)) defines three exporters:
- `prometheusremotewrite` → Prometheus (metrics)
- `loki` → Loki (logs)
- `otlp/tempo` → Tempo (traces, with persistent queue via `file_storage` extension)

```bash
kubectl --context $HUB_CTX apply -k hub/gateway/
```

Get the gateway's external IP — edge clusters will use this:

```bash
kubectl --context $HUB_CTX get svc otel-gateway-external -n observability-hub -w
# Wait for EXTERNAL-IP (1-2 minutes)
GATEWAY_IP=$(kubectl --context $HUB_CTX get svc otel-gateway-external -n observability-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway IP: $GATEWAY_IP"
```

### 3.5 (Optional) Firewall the Gateway

Restrict gateway access to known edge cluster IPs using a Linode Cloud Firewall:

```bash
# Get edge cluster node IPs (after creating edge clusters)
EDGE_IPS=$(kubectl --context $EDGE_CTX get nodes \
  -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}')

# Create firewall via Linode CLI
linode-cli firewalls create \
  --label gateway-firewall \
  --rules.inbound_policy DROP \
  --rules.outbound_policy ACCEPT \
  --rules.inbound "[{
    \"action\": \"ACCEPT\",
    \"protocol\": \"TCP\",
    \"ports\": \"4317,4318\",
    \"addresses\": {\"ipv4\": [\"<EDGE_NODE_IP_1>/32\", \"<EDGE_NODE_IP_2>/32\"]}
  }]"
```

### 3.6 Verify Hub Deployment

```bash
# All pods should be Running
kubectl --context $HUB_CTX get pods -n monitoring
kubectl --context $HUB_CTX get pods -n observability
kubectl --context $HUB_CTX get pods -n observability-hub

# Gateway health check
kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 13133:13133 &
curl -s http://localhost:13133 | head -5
kill %1

# Check Prometheus has metrics
kubectl --context $HUB_CTX port-forward svc/prometheus -n monitoring 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -m json.tool | head -20
kill %1
```

---

## 4. Deploy Edge Clusters

Repeat this section for each edge cluster you want to federate.

### 4.1 Create the Edge LKE Cluster

```bash
linode-cli lke cluster-create \
  --label my-edge-us-east \
  --region us-east \
  --k8s_version 1.33 \
  --tags "observability" --tags "edge" \
  --node_pools '[
    {"type":"g6-standard-2","count":2,"autoscaler":{"enabled":true,"min":2,"max":4}}
  ]'

# Download and merge kubeconfig
EDGE_CLUSTER_ID=<from output>
linode-cli lke kubeconfig-view $EDGE_CLUSTER_ID --text --no-headers | base64 -d > /tmp/edge-kubeconfig.yaml
KUBECONFIG=~/.kube/config:/tmp/edge-kubeconfig.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config

EDGE_CTX="lke${EDGE_CLUSTER_ID}-ctx"
kubectl --context $EDGE_CTX get nodes
```

### 4.2 Deploy Observability Agents on Edge

Edge agents are identical to hub agents except:
- `cluster.id` is set to the edge cluster's unique name
- `cluster.role` is `edge`
- The exporter sends to the hub gateway's external IP instead of an internal service

The edge-specific configs are in [`edge/`](../edge/):
- [`edge/agent-config.yaml`](../edge/agent-config.yaml) — OTel agent ConfigMap
- [`edge/scraper-config.yaml`](../edge/scraper-config.yaml) — OTel scraper ConfigMap

Before deploying, customize these configs:

1. Set `cluster.id` to your edge cluster's name (in the `resource` processor)
2. Set the exporter endpoint to your hub gateway's external IP

```yaml
# In edge/agent-config.yaml, update these:
processors:
  resource:
    attributes:
      - key: cluster.id
        value: my-edge-us-east      # <-- your cluster name
        action: insert
      - key: cluster.role
        value: edge
        action: insert

exporters:
  otlp/hub:
    endpoint: <GATEWAY_IP>:4317     # <-- hub gateway LoadBalancer IP
    tls:
      insecure: true
```

Deploy the same RBAC, kube-state-metrics, DaemonSet, and scraper manifests used on the hub — they're generic. Copy them from `hub/observability/` and apply with the edge ConfigMaps:

```bash
# Apply RBAC and kube-state-metrics (same as hub)
kubectl --context $EDGE_CTX apply -f hub/observability/namespace.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/agent/rbac.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/scraper/rbac.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/kube-state-metrics.yaml

# Apply edge-specific configs
kubectl --context $EDGE_CTX apply -f edge/agent-config.yaml
kubectl --context $EDGE_CTX apply -f edge/scraper-config.yaml

# Apply DaemonSet and scraper deployment (same manifests, different config)
kubectl --context $EDGE_CTX apply -f hub/observability/agent/daemonset.yaml
kubectl --context $EDGE_CTX apply -f hub/observability/scraper/deployment.yaml
```

### 4.3 (Optional) Deploy DCGM Exporter for GPU Nodes

If the edge cluster has GPU nodes:

```bash
kubectl --context $EDGE_CTX apply -f hub/monitoring/dcgm-exporter.yaml
```

Add a dcgm-exporter scrape job to the edge scraper config. See the hub scraper config ([`hub/observability/scraper/config.yaml`](../hub/observability/scraper/config.yaml)) for the pattern.

### 4.4 Verify Edge-to-Hub Data Flow

```bash
# Check edge agents are running
kubectl --context $EDGE_CTX get pods -n observability

# On the hub, query Prometheus for edge metrics
kubectl --context $HUB_CTX port-forward svc/prometheus -n monitoring 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=up{cluster_id="my-edge-us-east"}' \
  | python3 -m json.tool
kill %1
```

You should see metrics with `cluster_id="my-edge-us-east"` and `cluster_role="edge"`.

---

## 5. Instrumenting Your Applications

OpenTelemetry supports **auto-instrumentation** (zero code changes) and **manual instrumentation** (custom spans). Both send telemetry to the OTel agent DaemonSet on each node.

### 5.1 How It Works

```
Your App ──OTLP/gRPC──▶ otel-agent:4317 (DaemonSet, hostPort)
                              │
                              ▼
                        OTel Gateway ──▶ Prometheus / Loki / Tempo
```

The agent is accessible at `otel-agent.observability:4317` (ClusterIP) or `<node-ip>:4317` (hostPort).

### 5.2 Environment Variables (All Languages)

Add these to any Kubernetes Deployment to enable OTel export:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-agent.observability:4317"
  - name: OTEL_SERVICE_NAME
    value: "my-service"
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.namespace=my-namespace,deployment.environment=production"
  - name: OTEL_TRACES_EXPORTER
    value: "otlp"
  - name: OTEL_METRICS_EXPORTER
    value: "otlp"
  - name: OTEL_LOGS_EXPORTER
    value: "otlp"
```

For a working example, see [`examples/inference/deployment.yaml`](../examples/inference/deployment.yaml) — the BERT inference app uses exactly this pattern.

### 5.3 Auto-Instrumentation by Language

#### Python (FastAPI, Flask, Django)

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt \
    opentelemetry-distro \
    opentelemetry-exporter-otlp-proto-grpc
RUN opentelemetry-bootstrap -a install
COPY . .
ENTRYPOINT ["opentelemetry-instrument", "python", "app.py"]
```

Auto-instruments: FastAPI/Flask/Django routes, requests/httpx, SQLAlchemy/psycopg2, Redis, Celery, gRPC.

#### Java (Spring Boot, Quarkus)

```yaml
initContainers:
  - name: otel-agent-init
    image: ghcr.io/open-telemetry/opentelemetry-java-instrumentation:v2.1.0
    command: ['cp', '/javaagent.jar', '/otel/opentelemetry-javaagent.jar']
    volumeMounts:
      - name: otel-agent-jar
        mountPath: /otel
containers:
  - name: my-app
    env:
      - name: JAVA_TOOL_OPTIONS
        value: "-javaagent:/otel/opentelemetry-javaagent.jar"
    volumeMounts:
      - name: otel-agent-jar
        mountPath: /otel
volumes:
  - name: otel-agent-jar
    emptyDir: {}
```

Auto-instruments: Spring MVC/WebFlux, JDBC/JPA, HTTP clients, gRPC, Kafka, Redis.

#### Node.js (Express, Fastify, NestJS)

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm install && npm install @opentelemetry/auto-instrumentations-node @opentelemetry/exporter-trace-otlp-grpc
COPY . .
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "server.js"]
```

Auto-instruments: Express/Fastify/Koa routes, HTTP/HTTPS client, pg/mysql2, ioredis, gRPC, AWS SDK.

#### Go

Go requires manual SDK setup (no runtime agent). Use instrumentation wrappers:

```go
import "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"

// Wrap HTTP handler
handler := otelhttp.NewHandler(mux, "server")

// Wrap HTTP client
client := &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}
```

Available wrappers: `net/http`, `gin`, `echo`, `gRPC`, `database/sql`, `go-redis`, `sarama`.

#### .NET (ASP.NET Core)

```yaml
env:
  - name: CORECLR_ENABLE_PROFILING
    value: "1"
  - name: CORECLR_PROFILER
    value: "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
  - name: CORECLR_PROFILER_PATH
    value: "/otel-dotnet/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so"
  - name: DOTNET_STARTUP_HOOKS
    value: "/otel-dotnet/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll"
```

### 5.4 Adding Custom Spans

For business logic not covered by auto-instrumentation:

**Python:**
```python
from opentelemetry import trace
tracer = trace.get_tracer("my-service")

@app.post("/process-order")
async def process_order(order: Order):
    with tracer.start_as_current_span("validate-order") as span:
        span.set_attribute("order.id", order.id)
        validate(order)
```

**Java:**
```java
Tracer tracer = GlobalOpenTelemetry.getTracer("my-service");
Span span = tracer.spanBuilder("validate-order").startSpan();
try (Scope scope = span.makeCurrent()) {
    span.setAttribute("order.id", orderId);
    validate(order);
} finally {
    span.end();
}
```

**Node.js:**
```javascript
const { trace } = require('@opentelemetry/api');
const tracer = trace.getTracer('my-service');

app.post('/process-order', async (req, res) => {
  const span = tracer.startSpan('validate-order');
  span.setAttribute('order.id', req.body.orderId);
  // ... business logic
  span.end();
});
```

### 5.5 Exposing Prometheus Metrics

If your app exposes a `/metrics` endpoint, add a scrape job to the OTel scraper config:

```yaml
# Add to the scraper config under receivers.prometheus.config.scrape_configs:
- job_name: 'my-app'
  scrape_interval: 15s
  kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
          - my-app-namespace
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name]
      action: keep
      regex: my-app-service
    - source_labels: [__meta_kubernetes_endpoint_port_name]
      action: keep
      regex: http
```

Then restart the scraper: `kubectl rollout restart deployment/otel-scraper -n observability`

### 5.6 What You Get for Free (No App Changes)

| Data | Source | Example Query in Grafana |
|------|--------|--------------------------|
| Node CPU | kubeletstats | `k8s_node_cpu_utilization` |
| Node memory | kubeletstats | `k8s_node_memory_working_set` |
| Pod CPU/memory | kubeletstats | `k8s_pod_cpu_utilization` |
| Container restarts | kubeletstats | `k8s_container_restarts` |
| Pod phase | kube-state-metrics | `kube_pod_status_phase` |
| Deployment replicas | kube-state-metrics | `kube_deployment_status_replicas` |
| All pod logs | filelog receiver | Loki: `{exporter="OTLP"} \|= "error"` |

---

## 6. Configuring External Destinations

The OTel gateway can fan out telemetry to external platforms by adding exporters to [`hub/gateway/config.yaml`](../hub/gateway/config.yaml).

### 6.1 Adding Splunk HEC (Logs)

Create a secret and add the exporter:

```bash
kubectl --context $HUB_CTX create secret generic splunk-hec-token \
  -n observability-hub \
  --from-literal=token=YOUR_SPLUNK_HEC_TOKEN
```

Add to the gateway config `exporters` section:

```yaml
splunk_hec:
  endpoint: "https://your-splunk-hec.example.com:8088"
  token: "${env:SPLUNK_HEC_TOKEN}"
  source: "otel"
  sourcetype: "otel"
  index: "main"
  tls:
    insecure_skip_verify: false
  retry_on_failure:
    enabled: true
    initial_interval: 10s
    max_interval: 60s
  sending_queue:
    enabled: true
    queue_size: 5000
    storage: file_storage
```

Add `splunk_hec` to the logs pipeline:

```yaml
pipelines:
  logs:
    receivers: [otlp]
    processors: [memory_limiter, resource, batch]
    exporters: [loki, splunk_hec]        # Fan out to both
```

Add the `SPLUNK_HEC_TOKEN` env var to the gateway Deployment from the secret.

### 6.2 Adding Datadog (Metrics + Traces)

```bash
kubectl --context $HUB_CTX create secret generic datadog-api-key \
  -n observability-hub \
  --from-literal=api-key=YOUR_DD_API_KEY
```

Add to the gateway config:

```yaml
datadog:
  api:
    key: "${env:DD_API_KEY}"
    site: "datadoghq.com"
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
```

Add `datadog` to metrics and traces pipelines:

```yaml
pipelines:
  metrics:
    exporters: [prometheusremotewrite, datadog]
  traces:
    exporters: [otlp/tempo, datadog]
```

### 6.3 Adding a Custom OTLP Endpoint

For any OTLP-compatible backend (Grafana Cloud, Honeycomb, Elastic, New Relic):

```yaml
otlp/custom:
  endpoint: "https://otlp.your-backend.example.com:4317"
  compression: zstd
  tls:
    insecure: false
  headers:
    Authorization: "Bearer ${env:CUSTOM_OTLP_TOKEN}"
  retry_on_failure:
    enabled: true
    initial_interval: 5s
    max_interval: 60s
  sending_queue:
    enabled: true
    queue_size: 5000
    storage: file_storage
```

Add to whichever pipelines you want:

```yaml
pipelines:
  metrics:
    exporters: [prometheusremotewrite, otlp/custom]
  logs:
    exporters: [loki, otlp/custom]
  traces:
    exporters: [otlp/tempo, otlp/custom]
```

> **Key point:** Each exporter operates independently. If Splunk goes down, Datadog and the internal backends continue receiving data. The `sending_queue` with `file_storage` provides per-exporter persistent buffering.

---

## 7. Trace Demo: End-to-End Walkthrough

### 7.1 Generate Traces

**Option A:** Send a request to an instrumented app (e.g., the BERT inference example):

```bash
kubectl port-forward svc/bert-inference 8080:8080 -n bert-inference &
curl http://localhost:8080/predict -X POST -H "Content-Type: application/json" \
  -d '{"text": "Hello world"}'
kill %1
```

**Option B:** Use `telemetrygen` to generate synthetic traces directly to the gateway:

```bash
go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest

kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 4317:4317 &
telemetrygen traces \
  --otlp-endpoint localhost:4317 \
  --otlp-insecure \
  --service "demo-service" \
  --traces 5 \
  --child-spans 3
kill %1
```

### 7.2 Find the Trace in Grafana

1. Open Grafana (`http://<GRAFANA_IP>:80`, default login: `admin/admin`)
2. Navigate to **Explore** > Select **Tempo** datasource
3. Search by **Service Name** → select your service
4. Click a trace to see the span waterfall

### 7.3 Correlate Traces to Logs

Tempo is configured to link traces to Loki logs:

1. Click any span in the trace waterfall
2. Click **Logs for this span** — Grafana queries Loki for logs from the same pod during the span's time window

### 7.4 Cross-Cluster Queries

Filter by cluster in Grafana:

- **Tempo:** Add tag `cluster.id = my-edge-us-east` to show only edge traces
- **Prometheus:** `up{cluster_id="my-edge-us-east"}` for edge metrics
- **Loki:** `{exporter="OTLP"} |= "my-edge-us-east"` for edge logs

---

## 8. Troubleshooting and Testing

### 8.1 Verify OTel Agents

```bash
# DaemonSet should match node count
kubectl --context $HUB_CTX get ds otel-agent -n observability

# Check agent logs for errors
kubectl --context $HUB_CTX logs -n observability daemonset/otel-agent --tail=20
```

**Common agent issues:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `dial tcp: lookup lke...: no such host` | Using `K8S_NODE_NAME` for kubeletstats | Use `K8S_NODE_IP` from `status.hostIP` instead |
| Agent OOMKilled | Memory limit too low | Increase `memory_limiter` and container limits |
| No logs collected | filelog path wrong | Verify `/var/log/pods` is mounted read-only |
| OTLP export failures | Gateway unreachable | Check gateway service DNS, network policies |

### 8.2 Verify Gateway

```bash
# Health check
kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 13133:13133 &
curl -s http://localhost:13133
kill %1

# Check accepted vs dropped data
kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 8888:8888 &
curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted
curl -s http://localhost:8888/metrics | grep otelcol_exporter_sent
kill %1
```

**Key gateway metrics:**

| Metric | Meaning |
|--------|---------|
| `otelcol_receiver_accepted_spans` | Traces received |
| `otelcol_receiver_accepted_metric_points` | Metric data points received |
| `otelcol_exporter_sent_spans` | Traces exported to backends |
| `otelcol_exporter_send_failed_spans` | Failed trace exports |
| `otelcol_exporter_queue_size` | Current send queue depth |

### 8.3 Verify Backends

```bash
# Prometheus: check metrics from all clusters
kubectl --context $HUB_CTX port-forward svc/prometheus -n monitoring 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=count(count%20by%20(cluster_id)%20(up%7Bcluster_id!%3D%22%22%7D))' \
  | python3 -m json.tool
kill %1

# Loki: check recent logs
kubectl --context $HUB_CTX port-forward svc/loki -n monitoring 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}&limit=5' \
  | python3 -m json.tool
kill %1

# Tempo: search for recent traces
kubectl --context $HUB_CTX port-forward svc/tempo -n monitoring 3200:3200 &
curl -s 'http://localhost:3200/api/search?limit=5' | python3 -m json.tool
kill %1
```

### 8.4 Load Testing

```bash
# Generate 1000 traces/sec for 5 minutes
telemetrygen traces \
  --otlp-endpoint $GATEWAY_IP:4317 \
  --otlp-insecure \
  --service "load-test" \
  --traces 300000 \
  --rate 1000 \
  --child-spans 3 \
  --workers 10

# Generate metrics
telemetrygen metrics \
  --otlp-endpoint $GATEWAY_IP:4317 \
  --otlp-insecure \
  --duration 5m \
  --rate 5000

# Generate logs
telemetrygen logs \
  --otlp-endpoint $GATEWAY_IP:4317 \
  --otlp-insecure \
  --duration 5m \
  --rate 2000
```

### 8.5 Smoke Test Script

```bash
#!/bin/bash
set -e
HUB_CTX="${1:-lke564853-ctx}"
echo "=== Federated Observability Smoke Test ==="

echo "1. Hub pods..."
kubectl --context $HUB_CTX get pods -n monitoring -o wide | grep -E "NAME|Running"
kubectl --context $HUB_CTX get pods -n observability -o wide | grep -E "NAME|Running"
kubectl --context $HUB_CTX get pods -n observability-hub -o wide | grep -E "NAME|Running"

echo "2. Gateway health..."
kubectl --context $HUB_CTX exec -n observability-hub deploy/otel-gateway -- \
  wget -qO- http://localhost:13133 2>/dev/null

echo "3. Cluster count..."
kubectl --context $HUB_CTX exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(count+by+(cluster_id)(up{cluster_id!=""}))' 2>/dev/null \
  | python3 -c "import sys,json; print('Clusters:', json.load(sys.stdin)['data']['result'][0]['value'][1])"

echo "=== Done ==="
```

---

## 9. Scaling to Production

### 9.1 Adding More Edge Clusters

Each new edge cluster follows the same pattern from [Section 4](#4-deploy-edge-clusters):
1. Create LKE cluster
2. Deploy RBAC, kube-state-metrics, OTel agent, OTel scraper
3. Set unique `cluster.id`, set `cluster.role` to `edge`
4. Point exporter to hub gateway's external IP
5. (If firewalled) Add new cluster's node IPs to the gateway firewall

### 9.2 HPA on Gateway

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: otel-gateway
  namespace: observability-hub
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: otel-gateway
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

A scaffold HPA is already in [`hub/gateway/hpa.yaml`](../hub/gateway/hpa.yaml).

### 9.3 Persistent Queue Storage

Replace `emptyDir` with PVCs for queue durability across pod restarts:

```yaml
volumeClaimTemplates:
  - metadata:
      name: queue-storage
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: linode-block-storage-retain
      resources:
        requests:
          storage: 10Gi
```

### 9.4 mTLS Between Edge and Hub

For production, enable mTLS so only authorized edge clusters can send data:
1. Deploy cert-manager on the hub cluster
2. Create a CA issuer (see [`hub/gateway/cert-manager/`](../hub/gateway/cert-manager/))
3. Generate client certificates per edge cluster using [`scripts/generate-client-cert.sh`](../scripts/generate-client-cert.sh)
4. Configure hub ingress to validate client certificates
5. Configure edge exporters to present client certificates

### 9.5 PII Scrubbing at Edge

Add the `transform` processor to edge agent configs to scrub sensitive data before it leaves the cluster:

```yaml
processors:
  transform:
    error_mode: ignore
    log_statements:
      - context: log
        statements:
          - replace_pattern(body, "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b", "[EMAIL_REDACTED]")
          - replace_pattern(body, "\\b\\d{3}-\\d{2}-\\d{4}\\b", "[SSN_REDACTED]")
          - replace_pattern(body, "\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b", "[CC_REDACTED]")
    trace_statements:
      - context: span
        statements:
          - replace_pattern(attributes["http.url"], "password=[^&]*", "password=[REDACTED]")
          - replace_pattern(attributes["http.url"], "token=[^&]*", "token=[REDACTED]")
```

### 9.6 Network Policies

Restrict traffic between namespaces:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-gateway-to-monitoring
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              app.kubernetes.io/part-of: federated-observability
      ports:
        - port: 9090
        - port: 3100
        - port: 4317
```
