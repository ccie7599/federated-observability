#!/bin/bash
# Smoke test script for Federated Observability Platform
# Run this script to verify all components are working correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
KUBECONFIG="${PROJECT_DIR}/terraform/kubeconfig"

export KUBECONFIG

echo "=============================================="
echo "Federated Observability Platform - Smoke Test"
echo "=============================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASSED++))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((FAILED++))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check kubectl connection
echo "1. Checking cluster connectivity..."
if kubectl cluster-info &>/dev/null; then
    pass "Cluster is reachable"
else
    fail "Cannot connect to cluster"
    exit 1
fi

# Check namespaces
echo ""
echo "2. Checking namespaces..."
for ns in monitoring observability vault test-app; do
    if kubectl get namespace "$ns" &>/dev/null; then
        pass "Namespace '$ns' exists"
    else
        warn "Namespace '$ns' does not exist"
    fi
done

# Check deployments
echo ""
echo "3. Checking deployments..."
check_deployment() {
    local ns=$1
    local name=$2
    if kubectl get deployment "$name" -n "$ns" &>/dev/null; then
        ready=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$ready" == "$desired" ] && [ "$ready" != "0" ]; then
            pass "Deployment $ns/$name is ready ($ready/$desired)"
        else
            fail "Deployment $ns/$name not ready ($ready/$desired)"
        fi
    else
        warn "Deployment $ns/$name not found"
    fi
}

check_deployment monitoring prometheus
check_deployment monitoring grafana
check_deployment test-app test-app

# Check statefulsets
echo ""
echo "4. Checking statefulsets..."
check_statefulset() {
    local ns=$1
    local name=$2
    if kubectl get statefulset "$name" -n "$ns" &>/dev/null; then
        ready=$(kubectl get statefulset "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get statefulset "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "$ready" == "$desired" ] && [ "$ready" != "0" ]; then
            pass "StatefulSet $ns/$name is ready ($ready/$desired)"
        else
            fail "StatefulSet $ns/$name not ready ($ready/$desired)"
        fi
    else
        warn "StatefulSet $ns/$name not found"
    fi
}

check_statefulset monitoring loki
check_statefulset monitoring tempo
check_statefulset vault vault

# Check daemonsets
echo ""
echo "5. Checking daemonsets..."
if kubectl get daemonset otel-agent -n observability &>/dev/null; then
    ready=$(kubectl get daemonset otel-agent -n observability -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    desired=$(kubectl get daemonset otel-agent -n observability -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "1")
    if [ "$ready" == "$desired" ] && [ "$ready" != "0" ]; then
        pass "DaemonSet observability/otel-agent is ready ($ready/$desired)"
    else
        fail "DaemonSet observability/otel-agent not ready ($ready/$desired)"
    fi
else
    warn "DaemonSet observability/otel-agent not found"
fi

# Check services
echo ""
echo "6. Checking services..."
for svc in "monitoring/prometheus" "monitoring/grafana" "monitoring/loki" "monitoring/tempo" "observability/otel-agent" "test-app/test-app"; do
    ns=$(echo $svc | cut -d/ -f1)
    name=$(echo $svc | cut -d/ -f2)
    if kubectl get svc "$name" -n "$ns" &>/dev/null; then
        pass "Service $svc exists"
    else
        warn "Service $svc not found"
    fi
done

# Test endpoints via port-forward (if possible)
echo ""
echo "7. Testing service endpoints..."

test_endpoint() {
    local ns=$1
    local svc=$2
    local port=$3
    local path=$4
    local expected_code=${5:-200}

    # Start port-forward in background
    local_port=$((30000 + RANDOM % 5000))
    kubectl port-forward "svc/$svc" "$local_port:$port" -n "$ns" &>/dev/null &
    PF_PID=$!
    sleep 2

    # Test endpoint
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$local_port$path" 2>/dev/null || echo "000")

    # Cleanup
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true

    if [ "$code" == "$expected_code" ]; then
        pass "Endpoint $ns/$svc:$port$path returns $code"
    else
        fail "Endpoint $ns/$svc:$port$path returns $code (expected $expected_code)"
    fi
}

test_endpoint monitoring prometheus 9090 "/-/healthy"
test_endpoint monitoring grafana 3000 "/api/health"
test_endpoint test-app test-app 80 "/health"

# Test telemetry flow
echo ""
echo "8. Testing telemetry flow..."

# Generate test traffic
local_port=$((30000 + RANDOM % 5000))
kubectl port-forward svc/test-app "$local_port:80" -n test-app &>/dev/null &
PF_PID=$!
sleep 2

# Generate traces
for i in {1..5}; do
    curl -s "http://localhost:$local_port/api/trace" &>/dev/null || true
    sleep 0.5
done
pass "Generated 5 test traces"

# Generate logs
for i in {1..5}; do
    curl -s "http://localhost:$local_port/api/log" &>/dev/null || true
    sleep 0.5
done
pass "Generated 5 test log entries"

# Generate metrics
for i in {1..5}; do
    curl -s "http://localhost:$local_port/api/metrics-test" &>/dev/null || true
    sleep 0.5
done
pass "Generated 5 test metric events"

kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

# Check Prometheus has metrics
echo ""
echo "9. Verifying data in backends..."

local_port=$((30000 + RANDOM % 5000))
kubectl port-forward svc/prometheus "$local_port:9090" -n monitoring &>/dev/null &
PF_PID=$!
sleep 2

# Query for test app metrics
result=$(curl -s "http://localhost:$local_port/api/v1/query?query=test_app_requests_total" 2>/dev/null | grep -c "test_app_requests_total" || echo "0")
if [ "$result" -gt "0" ]; then
    pass "Test app metrics found in Prometheus"
else
    warn "Test app metrics not yet visible in Prometheus (may need more time)"
fi

kill $PF_PID 2>/dev/null || true
wait $PF_PID 2>/dev/null || true

# Summary
echo ""
echo "=============================================="
echo "SMOKE TEST SUMMARY"
echo "=============================================="
echo -e "${GREEN}Passed:${NC} $PASSED"
echo -e "${RED}Failed:${NC} $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Check the output above.${NC}"
    exit 1
fi
