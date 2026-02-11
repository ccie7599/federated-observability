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

The monitoring stack provides Prometheus (metrics), Loki (logs), Tempo (traces), and Grafana (dashboards) on the hub cluster.

#### 3.2.1 Create Namespace

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    app.kubernetes.io/part-of: federated-observability
EOF
```

#### 3.2.2 Deploy Prometheus

Prometheus runs as a **remote-write receiver only**. It does not scrape any targets directly — all metrics arrive via OpenTelemetry.

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
      external_labels:
        cluster: 'my-observability-hub'
    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: prometheus
  namespace: monitoring
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      serviceAccountName: prometheus
      containers:
        - name: prometheus
          image: prom/prometheus:v2.49.1
          args:
            - '--config.file=/etc/prometheus/prometheus.yml'
            - '--storage.tsdb.path=/prometheus'
            - '--web.enable-remote-write-receiver'
            - '--storage.tsdb.retention.time=7d'
            - '--web.enable-lifecycle'
          ports:
            - containerPort: 9090
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
            - name: storage
              mountPath: /prometheus
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2
              memory: 4Gi
      volumes:
        - name: config
          configMap:
            name: prometheus-config
        - name: storage
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    app: prometheus
  ports:
    - port: 9090
      targetPort: 9090
EOF
```

> **Note:** The `--web.enable-remote-write-receiver` flag is critical. Without it, Prometheus won't accept incoming metrics from the OTel gateway.

#### 3.2.3 Deploy Loki

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: monitoring
data:
  loki.yaml: |
    auth_enabled: false
    server:
      http_listen_port: 3100
      grpc_listen_port: 9096
    common:
      instance_addr: 127.0.0.1
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory
    query_range:
      results_cache:
        cache:
          embedded_cache:
            enabled: true
            max_size_mb: 100
    schema_config:
      configs:
        - from: 2020-10-24
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h
    limits_config:
      reject_old_samples: true
      reject_old_samples_max_age: 168h
      ingestion_rate_mb: 10
      ingestion_burst_size_mb: 20
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: loki
  namespace: monitoring
spec:
  serviceName: loki
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
        - name: loki
          image: grafana/loki:2.9.4
          args: ['-config.file=/etc/loki/loki.yaml']
          ports:
            - containerPort: 3100
            - containerPort: 9096
          volumeMounts:
            - name: config
              mountPath: /etc/loki
            - name: storage
              mountPath: /loki
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1
              memory: 2Gi
      volumes:
        - name: config
          configMap:
            name: loki-config
        - name: storage
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: monitoring
spec:
  selector:
    app: loki
  ports:
    - name: http
      port: 3100
      targetPort: 3100
    - name: grpc
      port: 9096
      targetPort: 9096
EOF
```

#### 3.2.4 Deploy Tempo

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: monitoring
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
      grpc_listen_port: 9095
    distributor:
      receivers:
        otlp:
          protocols:
            grpc:
              endpoint: 0.0.0.0:4317
            http:
              endpoint: 0.0.0.0:4318
    ingester:
      max_block_duration: 5m
    compactor:
      compaction:
        block_retention: 48h
    metrics_generator:
      registry:
        external_labels:
          source: tempo
          cluster: my-observability-hub
      storage:
        path: /var/tempo/wal
        remote_write:
          - url: http://prometheus.monitoring:9090/api/v1/write
            send_exemplars: true
    storage:
      trace:
        backend: local
        wal:
          path: /var/tempo/wal
        local:
          path: /var/tempo/blocks
    querier:
      frontend_worker:
        frontend_address: localhost:9095
    query_frontend:
      search:
        duration_slo: 5s
        throughput_bytes_slo: 1.073741824e+09
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: tempo
  namespace: monitoring
spec:
  serviceName: tempo
  replicas: 1
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
    spec:
      containers:
        - name: tempo
          image: grafana/tempo:2.3.1
          args: ['-config.file=/etc/tempo/tempo.yaml']
          ports:
            - containerPort: 3200
            - containerPort: 9095
            - containerPort: 4317
            - containerPort: 4318
          volumeMounts:
            - name: config
              mountPath: /etc/tempo
            - name: storage
              mountPath: /var/tempo
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: 1
              memory: 2Gi
      volumes:
        - name: config
          configMap:
            name: tempo-config
        - name: storage
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: monitoring
spec:
  selector:
    app: tempo
  ports:
    - name: http
      port: 3200
      targetPort: 3200
    - name: grpc
      port: 9095
      targetPort: 9095
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
EOF
```

#### 3.2.5 Deploy Grafana

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-config
  namespace: monitoring
data:
  grafana.ini: |
    [server]
    root_url = %(protocol)s://%(domain)s:%(http_port)s/
    [security]
    admin_user = admin
    admin_password = admin
    [auth.anonymous]
    enabled = true
    org_name = Main Org.
    org_role = Viewer
    [users]
    allow_sign_up = false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus.monitoring:9090
        isDefault: true
        editable: false
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.monitoring:3100
        editable: false
        jsonData:
          derivedFields:
            - datasourceUid: tempo
              matcherRegex: "traceID=(\\w+)"
              name: TraceID
              url: "$${__value.raw}"
      - name: Tempo
        type: tempo
        access: proxy
        url: http://tempo.monitoring:3200
        uid: tempo
        editable: false
        jsonData:
          httpMethod: GET
          tracesToLogs:
            datasourceUid: loki
            tags: ['job', 'instance', 'pod', 'namespace']
            mappedTags: [{ key: 'service.name', value: 'service' }]
            mapTagNamesEnabled: true
            filterByTraceID: true
          serviceMap:
            datasourceUid: prometheus
          nodeGraph:
            enabled: true
          lokiSearch:
            datasourceUid: loki
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:10.3.1
          ports:
            - containerPort: 3000
          volumeMounts:
            - name: config
              mountPath: /etc/grafana/grafana.ini
              subPath: grafana.ini
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: config
          configMap:
            name: grafana-config
        - name: datasources
          configMap:
            name: grafana-datasources
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: monitoring
spec:
  type: LoadBalancer
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
EOF
```

After applying, get the Grafana external IP:

```bash
kubectl --context $HUB_CTX get svc grafana -n monitoring -w
# Wait for EXTERNAL-IP to be assigned (1-2 minutes)
```

### 3.3 Deploy Observability Agents

The observability namespace hosts the OTel DaemonSet agent (collects from every node), OTel scraper (scrapes Prometheus endpoints), and kube-state-metrics.

#### 3.3.1 Create Namespace and RBAC

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    app.kubernetes.io/part-of: federated-observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-agent
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "nodes/stats", "nodes/proxy", "namespaces", "endpoints", "services", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-agent
subjects:
  - kind: ServiceAccount
    name: otel-agent
    namespace: observability
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-scraper
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-scraper
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "nodes/metrics", "nodes/proxy", "namespaces", "endpoints", "services"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets", "deployments", "daemonsets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["extensions"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
  - nonResourceURLs: ["/metrics"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-scraper
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-scraper
subjects:
  - kind: ServiceAccount
    name: otel-scraper
    namespace: observability
EOF
```

#### 3.3.2 Deploy kube-state-metrics

kube-state-metrics exposes Kubernetes object state as Prometheus metrics (`kube_pod_*`, `kube_deployment_*`, etc.).

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-state-metrics
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-state-metrics
rules:
  - apiGroups: [""]
    resources: ["configmaps","secrets","nodes","pods","services","serviceaccounts",
                "resourcequotas","replicationcontrollers","limitranges",
                "persistentvolumeclaims","persistentvolumes","namespaces","endpoints"]
    verbs: ["list","watch"]
  - apiGroups: ["apps"]
    resources: ["statefulsets","daemonsets","deployments","replicasets"]
    verbs: ["list","watch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs","jobs"]
    verbs: ["list","watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["list","watch"]
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["subjectaccessreviews"]
    verbs: ["create"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["list","watch"]
  - apiGroups: ["certificates.k8s.io"]
    resources: ["certificatesigningrequests"]
    verbs: ["list","watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses","volumeattachments"]
    verbs: ["list","watch"]
  - apiGroups: ["admissionregistration.k8s.io"]
    resources: ["mutatingwebhookconfigurations","validatingwebhookconfigurations"]
    verbs: ["list","watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies","ingresses"]
    verbs: ["list","watch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["list","watch"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["clusterrolebindings","clusterroles","rolebindings","roles"]
    verbs: ["list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-state-metrics
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-state-metrics
subjects:
  - kind: ServiceAccount
    name: kube-state-metrics
    namespace: observability
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-state-metrics
  template:
    metadata:
      labels:
        app: kube-state-metrics
    spec:
      serviceAccountName: kube-state-metrics
      containers:
        - name: kube-state-metrics
          image: registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.13.0
          ports:
            - name: http-metrics
              containerPort: 8080
            - name: telemetry
              containerPort: 8081
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: /
              port: 8081
            initialDelaySeconds: 5
            timeoutSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: kube-state-metrics
  namespace: observability
spec:
  selector:
    app: kube-state-metrics
  ports:
    - name: http-metrics
      port: 8080
      targetPort: 8080
    - name: telemetry
      port: 8081
      targetPort: 8081
EOF
```

#### 3.3.3 Deploy OTel Agent (DaemonSet)

The OTel Agent runs on every node and collects:
- **OTLP** from your applications (port 4317 gRPC, 4318 HTTP)
- **kubeletstats** — node, pod, and container resource metrics directly from the kubelet
- **filelog** — all container stdout/stderr logs from `/var/log/pods/`
- **k8s metadata** — enriches everything with pod name, namespace, node, deployment labels

```bash
# Replace YOUR_CLUSTER_ID with your cluster's unique name
CLUSTER_ID="my-observability-hub"

kubectl --context $HUB_CTX apply -f - <<EOF
---
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

      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: "https://\${env:K8S_NODE_IP}:10250"
        insecure_skip_verify: true
        metric_groups:
          - node
          - pod
          - container

      filelog:
        include:
          - /var/log/pods/*/*/*.log
        exclude:
          - /var/log/pods/*/otel-agent/*.log
        operators:
          - type: router
            routes:
              - expr: 'body matches "^\\\\{"'
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
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
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
            - tag_name: component
              key: app.kubernetes.io/component

      resourcedetection:
        detectors: [env, system]
        timeout: 5s
        override: false

      resource:
        attributes:
          - key: cluster.id
            value: ${CLUSTER_ID}
            action: insert
          - key: cluster.role
            value: hub
            action: insert

      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100

      batch:
        send_batch_size: 1000
        send_batch_max_size: 1500
        timeout: 10s

    exporters:
      otlp/gateway:
        endpoint: otel-gateway.observability-hub.svc.cluster.local:4317
        tls:
          insecure: true

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

    service:
      extensions: [health_check]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, resource, batch]
          exporters: [otlp/gateway]
        metrics:
          receivers: [otlp, kubeletstats]
          processors: [memory_limiter, k8sattributes, resourcedetection, resource, batch]
          exporters: [otlp/gateway]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, resource, batch]
          exporters: [otlp/gateway]
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-agent
  namespace: observability
spec:
  selector:
    matchLabels:
      app: otel-agent
  template:
    metadata:
      labels:
        app: otel-agent
    spec:
      serviceAccountName: otel-agent
      tolerations:
        - operator: Exists
      containers:
        - name: otel-agent
          image: otel/opentelemetry-collector-contrib:0.96.0
          args: ["--config=/etc/otel/config.yaml"]
          ports:
            - containerPort: 4317
              hostPort: 4317
              protocol: TCP
            - containerPort: 4318
              hostPort: 4318
              protocol: TCP
            - containerPort: 13133
              protocol: TCP
          env:
            - name: K8S_NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: K8S_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: K8S_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: K8S_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
            - name: config
              mountPath: /etc/otel
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: dockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
          readinessProbe:
            httpGet:
              path: /
              port: 13133
      volumes:
        - name: config
          configMap:
            name: otel-agent-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: dockercontainers
          hostPath:
            path: /var/lib/docker/containers
---
apiVersion: v1
kind: Service
metadata:
  name: otel-agent
  namespace: observability
spec:
  selector:
    app: otel-agent
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: health
      port: 13133
      targetPort: 13133
EOF
```

> **Important:** The kubeletstats receiver uses `K8S_NODE_IP` (from `status.hostIP`), not `K8S_NODE_NAME`. On LKE, node hostnames are not DNS-resolvable, so using the IP is required.

#### 3.3.4 Deploy OTel Scraper

The scraper uses the Prometheus receiver to scrape any services that expose `/metrics` endpoints (kube-state-metrics, your apps, GPU exporters, etc.).

```bash
CLUSTER_ID="my-observability-hub"

kubectl --context $HUB_CTX apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-scraper-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      prometheus:
        config:
          scrape_configs:
            - job_name: 'kube-state-metrics'
              scrape_interval: 30s
              kubernetes_sd_configs:
                - role: endpoints
                  namespaces:
                    names:
                      - observability
              relabel_configs:
                - source_labels: [__meta_kubernetes_service_name]
                  action: keep
                  regex: kube-state-metrics
                - source_labels: [__meta_kubernetes_endpoint_port_name]
                  action: keep
                  regex: http-metrics
                - source_labels: [__meta_kubernetes_namespace]
                  target_label: namespace
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: pod

            # Add scrape jobs for your applications here:
            # - job_name: 'my-app'
            #   scrape_interval: 15s
            #   kubernetes_sd_configs:
            #     - role: endpoints
            #       namespaces:
            #         names:
            #           - my-app-namespace
            #   relabel_configs:
            #     - source_labels: [__meta_kubernetes_service_name]
            #       action: keep
            #       regex: my-app-service

    processors:
      resource:
        attributes:
          - key: cluster.id
            value: ${CLUSTER_ID}
            action: insert
          - key: cluster.role
            value: hub
            action: insert

      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100

      batch:
        send_batch_size: 1000
        send_batch_max_size: 1500
        timeout: 10s

    exporters:
      otlp/gateway:
        endpoint: otel-gateway.observability-hub.svc.cluster.local:4317
        tls:
          insecure: true

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

    service:
      extensions: [health_check]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        metrics:
          receivers: [prometheus]
          processors: [memory_limiter, resource, batch]
          exporters: [otlp/gateway]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-scraper
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-scraper
  template:
    metadata:
      labels:
        app: otel-scraper
    spec:
      serviceAccountName: otel-scraper
      containers:
        - name: otel-scraper
          image: otel/opentelemetry-collector-contrib:0.96.0
          args: ["--config=/etc/otel/config.yaml"]
          ports:
            - containerPort: 13133
          volumeMounts:
            - name: config
              mountPath: /etc/otel
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: config
          configMap:
            name: otel-scraper-config
EOF
```

### 3.4 Deploy OTel Gateway

The gateway is the central ingestion point. It receives OTLP from all agents (hub and edge), enriches data with a `hub.received_at` label, and fans out to Prometheus, Loki, and Tempo.

```bash
kubectl --context $HUB_CTX apply -f - <<'EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability-hub
  labels:
    app.kubernetes.io/part-of: federated-observability
---
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
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
            cors:
              allowed_origins: ["*"]
              allowed_headers: ["X-Cluster-ID", "X-Environment"]

    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 1500
        spike_limit_mib: 400

      resource:
        attributes:
          - key: hub.received_at
            value: ${env:HOSTNAME}
            action: insert

      batch:
        send_batch_size: 5000
        timeout: 5s

    exporters:
      prometheusremotewrite:
        endpoint: http://prometheus.monitoring.svc.cluster.local:9090/api/v1/write
        resource_to_telemetry_conversion:
          enabled: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s

      loki:
        endpoint: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push
        default_labels_enabled:
          exporter: true
          job: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s

      otlp/tempo:
        endpoint: tempo.monitoring.svc.cluster.local:4317
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
        sending_queue:
          enabled: true
          num_consumers: 4
          queue_size: 5000
          storage: file_storage

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133
      zpages:
        endpoint: 0.0.0.0:55679
      file_storage:
        directory: /var/otel/queue
        timeout: 10s
        compaction:
          on_start: true
          on_rebound: true
          directory: /var/otel/queue/compaction

    service:
      extensions: [health_check, zpages, file_storage]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheusremotewrite]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [loki]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [otlp/tempo]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-gateway
  namespace: observability-hub
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-gateway
  template:
    metadata:
      labels:
        app: otel-gateway
    spec:
      initContainers:
        - name: init-queue-dir
          image: busybox:1.36
          command: ['sh', '-c', 'mkdir -p /var/otel/queue/compaction && chmod -R 777 /var/otel/queue']
          volumeMounts:
            - name: queue-storage
              mountPath: /var/otel/queue
      containers:
        - name: otel-gateway
          image: otel/opentelemetry-collector-contrib:0.96.0
          args: ["--config=/etc/otel/config.yaml"]
          ports:
            - containerPort: 4317
            - containerPort: 4318
            - containerPort: 13133
            - containerPort: 8888
          volumeMounts:
            - name: config
              mountPath: /etc/otel
            - name: queue-storage
              mountPath: /var/otel/queue
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2
              memory: 2Gi
          livenessProbe:
            httpGet:
              path: /
              port: 13133
          readinessProbe:
            httpGet:
              path: /
              port: 13133
      volumes:
        - name: config
          configMap:
            name: otel-gateway-config
        - name: queue-storage
          emptyDir:
            sizeLimit: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
  namespace: observability-hub
spec:
  selector:
    app: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: health
      port: 13133
      targetPort: 13133
---
# External LoadBalancer for edge clusters to reach the gateway
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway-external
  namespace: observability-hub
spec:
  type: LoadBalancer
  selector:
    app: otel-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
EOF
```

Get the gateway's external IP:

```bash
kubectl --context $HUB_CTX get svc otel-gateway-external -n observability-hub -w
# Wait for EXTERNAL-IP (1-2 minutes)
# Save this IP - edge clusters will use it
GATEWAY_IP=$(kubectl --context $HUB_CTX get svc otel-gateway-external -n observability-hub -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway IP: $GATEWAY_IP"
```

### 3.5 (Optional) Firewall the Gateway

Restrict gateway access to known edge cluster IPs using a Linode Cloud Firewall:

```bash
# Get edge cluster node IPs (after creating edge clusters)
EDGE_IPS=$(kubectl --context $EDGE_CTX get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}')

# Create firewall via Linode API
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

# Attach to the gateway's NodeBalancer
# Find the NodeBalancer ID from the Linode Cloud Manager or API
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

# Save the cluster ID
EDGE_CLUSTER_ID=<from output>

# Download and merge kubeconfig
linode-cli lke kubeconfig-view $EDGE_CLUSTER_ID --text --no-headers | base64 -d > /tmp/edge-kubeconfig.yaml
KUBECONFIG=~/.kube/config:/tmp/edge-kubeconfig.yaml kubectl config view --flatten > /tmp/merged.yaml
mv /tmp/merged.yaml ~/.kube/config

EDGE_CTX="lke${EDGE_CLUSTER_ID}-ctx"
kubectl --context $EDGE_CTX get nodes
```

### 4.2 Deploy Observability Agents on Edge

Edge agents are identical to hub agents except:
- `cluster.id` is set to the edge cluster's name
- `cluster.role` is `edge`
- The exporter sends to the hub gateway's external IP instead of internal service

```bash
# Set these for your edge cluster
EDGE_CLUSTER_NAME="my-edge-us-east"
GATEWAY_IP="<hub-gateway-external-ip>"  # From step 3.4

kubectl --context $EDGE_CTX apply -f - <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
  labels:
    app.kubernetes.io/part-of: federated-observability
---
# (Apply the same RBAC as hub - ServiceAccounts, ClusterRoles, ClusterRoleBindings)
# Copy the RBAC from step 3.3.1 exactly
---
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

      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: "https://\${env:K8S_NODE_IP}:10250"
        insecure_skip_verify: true
        metric_groups:
          - node
          - pod
          - container

      filelog:
        include:
          - /var/log/pods/*/*/*.log
        exclude:
          - /var/log/pods/*/otel-agent/*.log
        operators:
          - type: router
            routes:
              - expr: 'body matches "^\\\\{"'
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
      k8sattributes:
        auth_type: serviceAccount
        passthrough: false
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
            - tag_name: component
              key: app.kubernetes.io/component

      resourcedetection:
        detectors: [env, system]
        timeout: 5s
        override: false

      resource:
        attributes:
          - key: cluster.id
            value: ${EDGE_CLUSTER_NAME}
            action: insert
          - key: cluster.role
            value: edge
            action: insert

      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100

      batch:
        send_batch_size: 1000
        send_batch_max_size: 1500
        timeout: 10s

    exporters:
      otlp/hub:
        endpoint: ${GATEWAY_IP}:4317
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 60s

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

    service:
      extensions: [health_check]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, resourcedetection, resource, batch]
          exporters: [otlp/hub]
        metrics:
          receivers: [otlp, kubeletstats]
          processors: [memory_limiter, k8sattributes, resourcedetection, resource, batch]
          exporters: [otlp/hub]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, k8sattributes, resourcedetection, resource, batch]
          exporters: [otlp/hub]
EOF
```

Then deploy the same DaemonSet, Service, kube-state-metrics, and scraper from step 3.3 (with the edge ConfigMaps).

### 4.3 Deploy kube-state-metrics on Edge

Apply the same kube-state-metrics manifest from step 3.3.2 to the edge cluster:

```bash
# Same manifest as hub, just different context
kubectl --context $EDGE_CTX apply -f - <<'EOF'
# (paste kube-state-metrics manifest from step 3.3.2)
EOF
```

### 4.4 Deploy OTel Scraper on Edge

The edge scraper is similar to the hub scraper but exports to the hub gateway's external IP:

```bash
EDGE_CLUSTER_NAME="my-edge-us-east"
GATEWAY_IP="<hub-gateway-external-ip>"

kubectl --context $EDGE_CTX apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-scraper-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      prometheus:
        config:
          scrape_configs:
            - job_name: 'kube-state-metrics'
              scrape_interval: 30s
              kubernetes_sd_configs:
                - role: endpoints
                  namespaces:
                    names:
                      - observability
              relabel_configs:
                - source_labels: [__meta_kubernetes_service_name]
                  action: keep
                  regex: kube-state-metrics
                - source_labels: [__meta_kubernetes_endpoint_port_name]
                  action: keep
                  regex: http-metrics
                - source_labels: [__meta_kubernetes_namespace]
                  target_label: namespace
                - source_labels: [__meta_kubernetes_pod_name]
                  target_label: pod

            # Add your application scrape jobs here

    processors:
      resource:
        attributes:
          - key: cluster.id
            value: ${EDGE_CLUSTER_NAME}
            action: insert
          - key: cluster.role
            value: edge
            action: insert

      memory_limiter:
        check_interval: 1s
        limit_mib: 400
        spike_limit_mib: 100

      batch:
        send_batch_size: 1000
        send_batch_max_size: 1500
        timeout: 10s

    exporters:
      otlp/hub:
        endpoint: ${GATEWAY_IP}:4317
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 60s

    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

    service:
      extensions: [health_check]
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        metrics:
          receivers: [prometheus]
          processors: [memory_limiter, resource, batch]
          exporters: [otlp/hub]
EOF
```

### 4.5 Verify Edge-to-Hub Data Flow

```bash
# Check edge agents are running
kubectl --context $EDGE_CTX get pods -n observability

# On the hub, query Prometheus for edge metrics
kubectl --context $HUB_CTX port-forward svc/prometheus -n monitoring 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query?query=up{cluster_id="my-edge-us-east"}' | python3 -m json.tool
kill %1

# Check edge logs in Loki
kubectl --context $HUB_CTX port-forward svc/loki -n monitoring 3100:3100 &
curl -s 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}&limit=5' | python3 -m json.tool
kill %1
```

You should see metrics with `cluster_id="my-edge-us-east"` and `cluster_role="edge"` in Prometheus.

---

## 5. Instrumenting Your Applications

OpenTelemetry supports two instrumentation approaches: **auto-instrumentation** (zero code changes) and **manual instrumentation** (custom spans and metrics). Both send telemetry to the OTel agent DaemonSet running on each node.

### 5.1 How It Works

Your application sends OTLP telemetry to the OTel agent on the same node:

```
Your App ──OTLP/gRPC──▶ otel-agent:4317 (DaemonSet, hostPort)
                              │
                              ▼
                        OTel Gateway ──▶ Prometheus / Loki / Tempo
```

The agent is accessible at `otel-agent.observability:4317` (ClusterIP service) or `<node-ip>:4317` (hostPort). Use the service name in your app configuration.

### 5.2 Environment Variables (All Languages)

Every OTel SDK respects the same environment variables. Add these to your Kubernetes deployment:

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-agent.observability:4317"
  - name: OTEL_SERVICE_NAME
    value: "my-service"                    # Your service name
  - name: OTEL_RESOURCE_ATTRIBUTES
    value: "service.namespace=my-namespace,deployment.environment=production"
  - name: OTEL_TRACES_EXPORTER
    value: "otlp"
  - name: OTEL_METRICS_EXPORTER
    value: "otlp"                          # or "none" to disable
  - name: OTEL_LOGS_EXPORTER
    value: "otlp"                          # or "none" to disable
```

### 5.3 Auto-Instrumentation by Language

Auto-instrumentation captures HTTP requests, database calls, and framework operations automatically with no code changes.

#### Python (FastAPI, Flask, Django)

```yaml
# In your Deployment spec:
containers:
  - name: my-app
    image: my-app:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        pip install opentelemetry-distro opentelemetry-exporter-otlp-proto-grpc
        opentelemetry-bootstrap -a install
        opentelemetry-instrument python app.py
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://otel-agent.observability:4317"
      - name: OTEL_SERVICE_NAME
        value: "my-python-service"
      - name: OTEL_TRACES_EXPORTER
        value: "otlp"
      - name: OTEL_METRICS_EXPORTER
        value: "otlp"
      - name: OTEL_LOGS_EXPORTER
        value: "otlp"
      - name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
        value: "true"
```

Or bake it into your Dockerfile:

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

**What gets auto-instrumented:** FastAPI/Flask/Django routes, requests/httpx HTTP calls, SQLAlchemy/psycopg2 database queries, Redis, Celery, gRPC.

#### Java (Spring Boot, Quarkus)

```yaml
containers:
  - name: my-app
    image: my-app:latest
    env:
      - name: JAVA_TOOL_OPTIONS
        value: "-javaagent:/otel/opentelemetry-javaagent.jar"
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://otel-agent.observability:4317"
      - name: OTEL_SERVICE_NAME
        value: "my-java-service"
    volumeMounts:
      - name: otel-agent-jar
        mountPath: /otel
  initContainers:
    - name: otel-agent-init
      image: ghcr.io/open-telemetry/opentelemetry-java-instrumentation:v2.1.0
      command: ['cp', '/javaagent.jar', '/otel/opentelemetry-javaagent.jar']
      volumeMounts:
        - name: otel-agent-jar
          mountPath: /otel
  volumes:
    - name: otel-agent-jar
      emptyDir: {}
```

**What gets auto-instrumented:** Spring MVC/WebFlux controllers, JDBC/JPA database calls, HTTP clients (OkHttp, Apache HttpClient), gRPC, Kafka, Redis (Jedis, Lettuce).

#### Node.js (Express, Fastify, NestJS)

```yaml
containers:
  - name: my-app
    image: my-app:latest
    command: ["node"]
    args: ["--require", "@opentelemetry/auto-instrumentations-node/register", "server.js"]
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://otel-agent.observability:4317"
      - name: OTEL_SERVICE_NAME
        value: "my-node-service"
      - name: NODE_OPTIONS
        value: "--require @opentelemetry/auto-instrumentations-node/register"
```

Or in your Dockerfile:

```dockerfile
FROM node:20-slim
WORKDIR /app
COPY package*.json ./
RUN npm install && npm install @opentelemetry/auto-instrumentations-node @opentelemetry/exporter-trace-otlp-grpc
COPY . .
CMD ["node", "--require", "@opentelemetry/auto-instrumentations-node/register", "server.js"]
```

**What gets auto-instrumented:** Express/Fastify/Koa routes, HTTP/HTTPS client requests, pg/mysql2 database queries, ioredis, gRPC, AWS SDK.

#### Go

Go does not have a runtime agent — use the OTel Go SDK directly. However, many libraries have instrumentation wrappers:

```go
import (
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
)

// Wrap your HTTP handler
handler := otelhttp.NewHandler(mux, "server")

// Wrap HTTP client
client := &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}
```

**Available wrappers:** `net/http`, `gin`, `echo`, `gRPC`, `database/sql`, `go-redis`, `sarama` (Kafka).

#### .NET (ASP.NET Core)

```yaml
containers:
  - name: my-app
    image: my-app:latest
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://otel-agent.observability:4317"
      - name: OTEL_SERVICE_NAME
        value: "my-dotnet-service"
      - name: OTEL_DOTNET_AUTO_HOME
        value: "/otel-dotnet"
      - name: CORECLR_ENABLE_PROFILING
        value: "1"
      - name: CORECLR_PROFILER
        value: "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
      - name: CORECLR_PROFILER_PATH
        value: "/otel-dotnet/linux-x64/OpenTelemetry.AutoInstrumentation.Native.so"
      - name: DOTNET_ADDITIONAL_DEPS
        value: "/otel-dotnet/AdditionalDeps"
      - name: DOTNET_SHARED_STORE
        value: "/otel-dotnet/store"
      - name: DOTNET_STARTUP_HOOKS
        value: "/otel-dotnet/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll"
```

### 5.4 Adding Custom Spans

Auto-instrumentation covers framework and library calls. For business logic, add manual spans:

**Python:**
```python
from opentelemetry import trace

tracer = trace.get_tracer("my-service")

@app.post("/process-order")
async def process_order(order: Order):
    with tracer.start_as_current_span("validate-order") as span:
        span.set_attribute("order.id", order.id)
        span.set_attribute("order.amount", order.total)
        validate(order)

    with tracer.start_as_current_span("charge-payment") as span:
        span.set_attribute("payment.method", order.payment_method)
        result = charge(order)
        span.set_attribute("payment.success", result.success)
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

If your application exports Prometheus-format metrics on a `/metrics` endpoint, the OTel scraper can pick them up. Add a scrape job to the scraper's ConfigMap:

```yaml
# In otel-scraper-config ConfigMap, under receivers.prometheus.config.scrape_configs:
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
      regex: http            # Match your port name
    - source_labels: [__meta_kubernetes_namespace]
      target_label: namespace
    - source_labels: [__meta_kubernetes_pod_name]
      target_label: pod
```

Then restart the scraper:

```bash
kubectl rollout restart deployment/otel-scraper -n observability
```

### 5.6 What You Get for Free (No App Changes)

Even without any application instrumentation, the OTel stack automatically collects:

| Data | Source | Example Query in Grafana |
|------|--------|--------------------------|
| Node CPU | kubeletstats | `k8s_node_cpu_utilization` |
| Node memory | kubeletstats | `k8s_node_memory_working_set` |
| Pod CPU/memory | kubeletstats | `k8s_pod_cpu_utilization` |
| Container restarts | kubeletstats | `k8s_container_restarts` |
| Pod phase | kube-state-metrics | `kube_pod_status_phase` |
| Deployment replicas | kube-state-metrics | `kube_deployment_status_replicas` |
| All pod logs | filelog receiver | Loki: `{exporter="OTLP"} \|= "error"` |
| Cluster identity | resource processor | All data tagged with `cluster_id`, `cluster_role` |

---

## 6. Configuring External Destinations

The hub gateway can fan out telemetry to external platforms (Splunk, Datadog, or any OTLP-compatible endpoint) by adding exporters to the gateway configuration.

### 6.1 Architecture with External Destinations

```
                    OTel Gateway
                         │
           ┌─────────────┼─────────────────────────┐
           │             │                │         │
           ▼             ▼                ▼         ▼
      Prometheus       Loki           Tempo     External
      (metrics)       (logs)        (traces)   Destinations
                                                   │
                                        ┌──────────┼──────────┐
                                        ▼          ▼          ▼
                                    Splunk      Datadog    Custom
                                    (logs)    (metrics+   OTLP
                                              traces)
```

### 6.2 Adding Splunk HEC (Logs)

To send logs to Splunk, add a `splunk_hec` exporter to the gateway config.

**Step 1:** Create a secret for the Splunk HEC token:

```bash
kubectl --context $HUB_CTX create secret generic splunk-hec-token \
  -n observability-hub \
  --from-literal=token=YOUR_SPLUNK_HEC_TOKEN
```

**Step 2:** Update the gateway ConfigMap to add the Splunk exporter:

```yaml
# Add to the exporters section of otel-gateway-config:
exporters:
  # ... existing exporters (prometheusremotewrite, loki, otlp/tempo) ...

  splunk_hec:
    endpoint: "https://your-splunk-hec.example.com:8088"
    token: "${env:SPLUNK_HEC_TOKEN}"
    source: "otel"
    sourcetype: "otel"
    index: "main"
    tls:
      insecure_skip_verify: false      # Set true for self-signed certs
    retry_on_failure:
      enabled: true
      initial_interval: 10s
      max_interval: 60s
    sending_queue:
      enabled: true
      queue_size: 5000
      storage: file_storage
```

**Step 3:** Add Splunk to the logs pipeline:

```yaml
service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [loki, splunk_hec]      # Fan out to both
```

**Step 4:** Add the `SPLUNK_HEC_TOKEN` env var to the gateway Deployment:

```yaml
env:
  - name: SPLUNK_HEC_TOKEN
    valueFrom:
      secretKeyRef:
        name: splunk-hec-token
        key: token
```

### 6.3 Adding Datadog (Metrics + Traces)

**Step 1:** Create a secret for the Datadog API key:

```bash
kubectl --context $HUB_CTX create secret generic datadog-api-key \
  -n observability-hub \
  --from-literal=api-key=YOUR_DD_API_KEY
```

**Step 2:** Add the Datadog exporter to the gateway config:

```yaml
exporters:
  # ... existing exporters ...

  datadog:
    api:
      key: "${env:DD_API_KEY}"
      site: "datadoghq.com"             # or datadoghq.eu, etc.
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

**Step 3:** Add Datadog to the metrics and traces pipelines:

```yaml
service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite, datadog]  # Fan out to both
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlp/tempo, datadog]              # Fan out to both
```

### 6.4 Adding a Custom OTLP Endpoint

For any OTLP-compatible backend (Grafana Cloud, Honeycomb, Elastic, New Relic, your own collector):

```yaml
exporters:
  # ... existing exporters ...

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
service:
  pipelines:
    metrics:
      exporters: [prometheusremotewrite, otlp/custom]
    logs:
      exporters: [loki, otlp/custom]
    traces:
      exporters: [otlp/tempo, otlp/custom]
```

### 6.5 Complete Gateway Config with All Destinations

Here is a full gateway config example with Prometheus, Loki, Tempo, Splunk, Datadog, and a custom OTLP endpoint:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 1500
    spike_limit_mib: 400
  resource:
    attributes:
      - key: hub.received_at
        value: ${env:HOSTNAME}
        action: insert
  batch:
    send_batch_size: 5000
    timeout: 5s

exporters:
  # Internal: Prometheus (metrics)
  prometheusremotewrite:
    endpoint: http://prometheus.monitoring.svc.cluster.local:9090/api/v1/write
    resource_to_telemetry_conversion:
      enabled: true

  # Internal: Loki (logs)
  loki:
    endpoint: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push

  # Internal: Tempo (traces)
  otlp/tempo:
    endpoint: tempo.monitoring.svc.cluster.local:4317
    tls:
      insecure: true

  # External: Splunk (logs)
  splunk_hec:
    endpoint: "https://splunk-hec.example.com:8088"
    token: "${env:SPLUNK_HEC_TOKEN}"
    source: "otel-federated"
    index: "main"

  # External: Datadog (metrics + traces)
  datadog:
    api:
      key: "${env:DD_API_KEY}"
      site: "datadoghq.com"
    metrics:
      resource_attributes_as_tags: true

  # External: Custom OTLP endpoint
  otlp/customer:
    endpoint: "https://otlp.customer.example.com:4317"
    headers:
      Authorization: "Bearer ${env:CUSTOMER_OTLP_TOKEN}"

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  file_storage:
    directory: /var/otel/queue
    compaction:
      on_start: true
      on_rebound: true
      directory: /var/otel/queue/compaction

service:
  extensions: [health_check, file_storage]
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite, datadog, otlp/customer]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [loki, splunk_hec, otlp/customer]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlp/tempo, datadog, otlp/customer]
```

> **Key point:** Each exporter operates independently. If Splunk goes down, Datadog and the internal backends continue receiving data. The `sending_queue` with `file_storage` provides per-exporter persistent buffering so data isn't lost during destination outages.

---

## 7. Trace Demo: End-to-End Walkthrough

This walkthrough demonstrates a complete trace flowing from an application through the OTel pipeline to Grafana/Tempo. The example uses a Python FastAPI service, but the pattern works for any language.

### 7.1 Deploy a Traced Application

Here is a minimal traced application. This could be any service — a web API, a worker process, a batch job:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-traced-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-traced-app
  template:
    metadata:
      labels:
        app: my-traced-app
    spec:
      containers:
        - name: app
          image: my-app:latest
          ports:
            - containerPort: 8080
          env:
            # Point to the OTel agent running on this node
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://otel-agent.observability:4317"
            - name: OTEL_SERVICE_NAME
              value: "my-traced-app"
            - name: OTEL_RESOURCE_ATTRIBUTES
              value: "service.namespace=default,deployment.environment=production"
            - name: OTEL_TRACES_EXPORTER
              value: "otlp"
            - name: OTEL_METRICS_EXPORTER
              value: "otlp"
            - name: OTEL_LOGS_EXPORTER
              value: "otlp"
```

### 7.2 Generate a Trace

Send a request to your application:

```bash
# Port-forward to your app
kubectl port-forward svc/my-traced-app 8080:8080 &

# Send a request (this creates a trace)
curl -v http://localhost:8080/api/endpoint
kill %1
```

Or use `telemetrygen` to generate synthetic traces directly:

```bash
# Install telemetrygen
go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest

# Generate traces directly to the gateway
kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 4317:4317 &

telemetrygen traces \
  --otlp-endpoint localhost:4317 \
  --otlp-insecure \
  --service "demo-service" \
  --traces 5 \
  --child-spans 3 \
  --rate 1

kill %1
```

### 7.3 Find the Trace in Grafana

1. Open Grafana (hub cluster):

```bash
kubectl --context $HUB_CTX port-forward svc/grafana -n monitoring 3000:3000 &
# Open http://localhost:3000
```

2. Navigate to **Explore** > Select **Tempo** datasource

3. Search for traces:
   - **Service Name:** `my-traced-app` (or `demo-service` if using telemetrygen)
   - **Duration:** Last 15 minutes
   - Click **Run query**

4. Click on a trace to see the span waterfall:

```
my-traced-app: POST /api/endpoint                    [────────── 245ms ──────────]
  ├── validate-input                                    [──── 12ms ────]
  ├── database.query SELECT * FROM users                    [────── 89ms ──────]
  └── http.client GET https://external-api.com                  [──── 134ms ────]
```

Each span shows:
- **Duration** — how long the operation took
- **Attributes** — HTTP method, URL, status code, database statement
- **Resource attributes** — `cluster.id`, `k8s.pod.name`, `k8s.namespace.name`
- **Events** — log messages correlated with the span

### 7.4 Correlate Traces to Logs

In Grafana, Tempo is configured to link traces to Loki logs:

1. Click on any span in the trace waterfall
2. Click the **Logs for this span** button
3. Grafana queries Loki for logs from the same pod during the span's time window

You can also search Loki directly:

```
{exporter="OTLP"} |= "traceID=<your-trace-id>"
```

### 7.5 Cross-Cluster Trace Queries

With multiple clusters, you can filter traces by cluster:

In Grafana Tempo search:
- Add tag: `cluster.id` = `my-edge-us-east` — show only edge traces
- Add tag: `cluster.role` = `hub` — show only hub traces

In Prometheus (for trace-derived metrics):
```promql
# Request rate by cluster
rate(traces_spanmetrics_calls_total{service_name="my-app"}[5m])

# P99 latency by cluster
histogram_quantile(0.99, rate(traces_spanmetrics_duration_seconds_bucket{service_name="my-app"}[5m]))
```

---

## 8. Troubleshooting and Testing

### 8.1 Verify OTel Agents

```bash
# Check DaemonSet is running on all nodes
kubectl --context $HUB_CTX get ds otel-agent -n observability
# DESIRED = CURRENT = READY should match node count

# Check agent logs for errors
kubectl --context $HUB_CTX logs -n observability daemonset/otel-agent --tail=20

# Check agent health
kubectl --context $HUB_CTX port-forward ds/otel-agent -n observability 13133:13133 &
curl -s http://localhost:13133 | python3 -m json.tool
kill %1
```

**Common agent issues:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kubeletstats` errors: `dial tcp: lookup lke...: no such host` | Using `K8S_NODE_NAME` instead of `K8S_NODE_IP` | Change kubeletstats endpoint to use `K8S_NODE_IP` env var from `status.hostIP` |
| Agent OOMKilled | Memory limit too low for log volume | Increase `memory_limiter` to 512 MiB and container limits to 768 Mi |
| No logs collected | filelog include path wrong | Verify `/var/log/pods` is mounted and readable |
| OTLP export failures | Gateway unreachable | Check gateway service DNS, network policies |

### 8.2 Verify Gateway

```bash
# Check gateway is running
kubectl --context $HUB_CTX get pods -n observability-hub

# Check gateway logs
kubectl --context $HUB_CTX logs -n observability-hub deployment/otel-gateway --tail=30

# Check gateway zpages (pipeline status)
kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 55679:55679 &
curl -s http://localhost:55679/debug/pipelinez | head -50
kill %1

# Check gateway metrics (accepted vs dropped data points)
kubectl --context $HUB_CTX port-forward svc/otel-gateway -n observability-hub 8888:8888 &
curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted
curl -s http://localhost:8888/metrics | grep otelcol_exporter_sent
kill %1
```

**Key gateway metrics to monitor:**

| Metric | Meaning |
|--------|---------|
| `otelcol_receiver_accepted_spans` | Traces received |
| `otelcol_receiver_accepted_metric_points` | Metric data points received |
| `otelcol_receiver_accepted_log_records` | Log records received |
| `otelcol_exporter_sent_spans` | Traces exported to backends |
| `otelcol_exporter_send_failed_spans` | Failed trace exports |
| `otelcol_exporter_queue_size` | Current send queue depth |

### 8.3 Verify Prometheus (Metrics)

```bash
kubectl --context $HUB_CTX port-forward svc/prometheus -n monitoring 9090:9090 &

# Check metrics exist from each cluster
curl -s 'http://localhost:9090/api/v1/query?query=count(count%20by%20(cluster_id)%20(up%7Bcluster_id!%3D%22%22%7D))' | python3 -m json.tool

# Check kubeletstats metrics
curl -s 'http://localhost:9090/api/v1/query?query=k8s_node_cpu_utilization' | python3 -m json.tool | head -20

# Check kube-state-metrics
curl -s 'http://localhost:9090/api/v1/query?query=kube_pod_status_phase' | python3 -m json.tool | head -20

# Verify hub.received_at label exists (proves data went through gateway)
curl -s 'http://localhost:9090/api/v1/query?query=up%7Bhub_received_at!%3D%22%22%7D' | python3 -m json.tool | head -10

kill %1
```

### 8.4 Verify Loki (Logs)

```bash
kubectl --context $HUB_CTX port-forward svc/loki -n monitoring 3100:3100 &

# Check recent logs exist
curl -s 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}&limit=5' | python3 -m json.tool

# Search for logs from a specific cluster
curl -s 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}|="my-edge-cluster"&limit=5' | python3 -m json.tool

kill %1
```

### 8.5 Verify Tempo (Traces)

```bash
kubectl --context $HUB_CTX port-forward svc/tempo -n monitoring 3200:3200 &

# Search for recent traces by service
curl -s 'http://localhost:3200/api/search?q={resource.service.name="my-app"}&limit=5' | python3 -m json.tool

# Fetch a specific trace by ID
curl -s 'http://localhost:3200/api/traces/<trace-id>' | python3 -m json.tool

kill %1
```

### 8.6 Load Testing

Use `telemetrygen` to validate the pipeline handles expected throughput:

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

# Generate 5000 metric data points/sec
telemetrygen metrics \
  --otlp-endpoint $GATEWAY_IP:4317 \
  --otlp-insecure \
  --duration 5m \
  --rate 5000

# Generate 2000 log records/sec
telemetrygen logs \
  --otlp-endpoint $GATEWAY_IP:4317 \
  --otlp-insecure \
  --duration 5m \
  --rate 2000
```

During the load test, monitor gateway metrics:

```bash
# Watch for queue buildup or dropped data
watch 'kubectl exec -n monitoring deploy/prometheus -- wget -qO- "http://localhost:9090/api/v1/query?query=otelcol_exporter_queue_size" 2>/dev/null | python3 -m json.tool'
```

### 8.7 End-to-End Smoke Test

A quick script to validate the full pipeline:

```bash
#!/bin/bash
# smoke-test.sh - Verify federated observability pipeline
set -e

HUB_CTX="${1:-lke564853-ctx}"
echo "=== Federated Observability Smoke Test ==="

echo ""
echo "1. Checking hub pods..."
kubectl --context $HUB_CTX get pods -n monitoring -o wide | grep -E "NAME|Running"
kubectl --context $HUB_CTX get pods -n observability -o wide | grep -E "NAME|Running"
kubectl --context $HUB_CTX get pods -n observability-hub -o wide | grep -E "NAME|Running"

echo ""
echo "2. Checking gateway health..."
kubectl --context $HUB_CTX exec -n observability-hub deploy/otel-gateway -- wget -qO- http://localhost:13133 2>/dev/null

echo ""
echo "3. Checking Prometheus for metrics from all clusters..."
CLUSTER_COUNT=$(kubectl --context $HUB_CTX exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(count%20by%20(cluster_id)%20(up%7Bcluster_id!%3D%22%22%7D))' 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])")
echo "   Clusters reporting: $CLUSTER_COUNT"

echo ""
echo "4. Checking kubeletstats metrics..."
NODE_COUNT=$(kubectl --context $HUB_CTX exec -n monitoring deploy/prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(k8s_node_cpu_utilization)' 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['result'][0]['value'][1])")
echo "   Nodes with CPU metrics: $NODE_COUNT"

echo ""
echo "5. Checking Loki for recent logs..."
kubectl --context $HUB_CTX exec -n monitoring statefulset/loki -- \
  wget -qO- 'http://localhost:3100/loki/api/v1/query?query={exporter="OTLP"}&limit=1' 2>/dev/null \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(f'   Log streams found: {len(r)}')"

echo ""
echo "=== Smoke test complete ==="
```

---

## 9. Scaling to Production

### 9.1 Adding More Edge Clusters

Each new edge cluster follows the same pattern:

1. Create LKE cluster
2. Deploy RBAC, kube-state-metrics, OTel agent, OTel scraper
3. Set `cluster.id` to a unique name, `cluster.role` to `edge`
4. Point the exporter to the hub gateway's external IP
5. (If firewalled) Add the new cluster's node IPs to the gateway firewall

### 9.2 HPA on Gateway

Scale the gateway based on CPU/memory:

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
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

### 9.3 PVC-Backed Persistent Queues

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
2. Create a CA issuer for client certificates
3. Generate client certificates per edge cluster
4. Configure the hub ingress to validate client certificates
5. Configure edge aggregators to present client certificates

See `scripts/generate-client-cert.sh` for certificate generation.

### 9.5 PII Scrubbing at Edge

Add the transform processor to edge aggregators to scrub sensitive data before it leaves the cluster:

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

See `edge-collector/aggregator-config.yaml` for a complete PII scrubbing configuration.

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
        - port: 9090    # Prometheus
        - port: 3100    # Loki
        - port: 4317    # Tempo
```
