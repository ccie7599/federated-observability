#!/bin/bash
# Start port-forwards to access all services
# Run this script to access the observability platform

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG="${PROJECT_DIR}/terraform/kubeconfig"

export KUBECONFIG

echo "=============================================="
echo "Federated Observability Platform"
echo "=============================================="
echo ""
echo "Starting port-forwards to services..."
echo ""

# Kill any existing port-forwards
pkill -f "port-forward" 2>/dev/null || true
sleep 2

# Start port-forwards in background
kubectl port-forward svc/grafana 3000:3000 -n monitoring &
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
kubectl port-forward svc/test-app 8080:80 -n test-app &
kubectl port-forward svc/tempo 3200:3200 -n monitoring &
kubectl port-forward svc/loki 3100:3100 -n monitoring &

sleep 3

echo "=============================================="
echo "Services are now accessible:"
echo "=============================================="
echo ""
echo "TEST APP (HTML Interface):"
echo "  http://localhost:8080"
echo "  - Click buttons to generate traces, logs, metrics"
echo ""
echo "GRAFANA (Dashboards):"
echo "  http://localhost:3000"
echo "  Username: admin"
echo "  Password: admin"
echo ""
echo "PROMETHEUS (Metrics):"
echo "  http://localhost:9090"
echo ""
echo "TEMPO (Traces API):"
echo "  http://localhost:3200"
echo ""
echo "LOKI (Logs API):"
echo "  http://localhost:3100"
echo ""
echo "=============================================="
echo ""
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Wait for all background jobs
wait
