#!/bin/bash
# Deploy all components of the Federated Observability Platform
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG="${PROJECT_DIR}/terraform/kubeconfig"

export KUBECONFIG

echo "=============================================="
echo "Deploying Federated Observability Platform"
echo "=============================================="
echo ""

# Check kubectl connection
echo "Checking cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to cluster. Check your kubeconfig."
    exit 1
fi
echo "Connected to cluster."
echo ""

# Deploy namespaces first
echo "1. Creating namespaces..."
kubectl apply -f "${PROJECT_DIR}/base/namespace.yaml"
echo ""

# Deploy Vault
echo "2. Deploying Vault..."
kubectl apply -k "${PROJECT_DIR}/vault/"
echo "Waiting for Vault pods to be ready..."
kubectl wait --for=condition=ready pod -l app=vault -n vault --timeout=300s || true
echo ""

# Deploy monitoring stack
echo "3. Deploying monitoring stack (Prometheus, Loki, Tempo, Grafana)..."
kubectl apply -k "${PROJECT_DIR}/monitoring/"
echo "Waiting for monitoring pods to be ready..."
kubectl wait --for=condition=ready pod -l app=prometheus -n monitoring --timeout=300s || true
kubectl wait --for=condition=ready pod -l app=grafana -n monitoring --timeout=300s || true
echo ""

# Deploy observability collectors
echo "4. Deploying OTel collectors..."
kubectl apply -k "${PROJECT_DIR}/observability/"
echo "Waiting for OTel agent pods to be ready..."
kubectl wait --for=condition=ready pod -l app=otel-agent -n observability --timeout=300s || true
echo ""

# Deploy test app
echo "5. Deploying test application..."
kubectl apply -f "${PROJECT_DIR}/tests/test-app.yaml"
echo "Waiting for test app pods to be ready..."
kubectl wait --for=condition=ready pod -l app=test-app -n test-app --timeout=300s || true
echo ""

# Show deployment status
echo "=============================================="
echo "Deployment Complete!"
echo "=============================================="
echo ""
echo "Pod status:"
kubectl get pods -A | grep -E "monitoring|observability|vault|test-app"
echo ""
echo "Services:"
kubectl get svc -A | grep -E "monitoring|observability|vault|test-app"
echo ""
echo "=============================================="
echo "Access URLs (via port-forward):"
echo "=============================================="
echo ""
echo "Run these commands to access the services:"
echo ""
echo "# Grafana (admin/admin):"
echo "kubectl port-forward svc/grafana 3000:3000 -n monitoring"
echo "# Then open: http://localhost:3000"
echo ""
echo "# Prometheus:"
echo "kubectl port-forward svc/prometheus 9090:9090 -n monitoring"
echo "# Then open: http://localhost:9090"
echo ""
echo "# Test App:"
echo "kubectl port-forward svc/test-app 8080:80 -n test-app"
echo "# Then open: http://localhost:8080"
echo ""
echo "# Tempo:"
echo "kubectl port-forward svc/tempo 3200:3200 -n monitoring"
echo "# Then open: http://localhost:3200"
echo ""
echo "=============================================="
