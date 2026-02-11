#!/usr/bin/env bash
set -euo pipefail

# Load test the observability pipeline using telemetrygen
# Usage: ./scripts/load-test.sh [--rps 10000] [--duration 5m] [--endpoint localhost:4318]

RPS="${RPS:-1000}"
DURATION="${DURATION:-5m}"
ENDPOINT="${ENDPOINT:-localhost:4318}"
WORKERS="${WORKERS:-10}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --rps) RPS="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Check for telemetrygen
if ! command -v telemetrygen &>/dev/null; then
    echo "Installing telemetrygen..."
    go install github.com/open-telemetry/opentelemetry-collector-contrib/cmd/telemetrygen@latest
fi

echo "========================================="
echo " Federated Observability Load Test"
echo "========================================="
echo " Endpoint:  ${ENDPOINT}"
echo " Rate:      ${RPS} per second"
echo " Duration:  ${DURATION}"
echo " Workers:   ${WORKERS}"
echo "========================================="
echo ""

# Calculate per-second rate for traces
TRACE_RPS=$((RPS / 3))
METRIC_RPS=$((RPS / 3))
LOG_RPS=$((RPS / 3))

echo "Starting trace generation (${TRACE_RPS} spans/sec)..."
telemetrygen traces \
    --otlp-http \
    --endpoint "${ENDPOINT}" \
    --rate "${TRACE_RPS}" \
    --duration "${DURATION}" \
    --workers "${WORKERS}" \
    --service-name "load-test-service" \
    --otlp-attributes='cluster.id="load-test"' \
    --otlp-attributes='environment="load-test"' &
TRACE_PID=$!

echo "Starting metric generation (${METRIC_RPS} metrics/sec)..."
telemetrygen metrics \
    --otlp-http \
    --endpoint "${ENDPOINT}" \
    --rate "${METRIC_RPS}" \
    --duration "${DURATION}" \
    --workers "${WORKERS}" \
    --service-name "load-test-service" \
    --otlp-attributes='cluster.id="load-test"' &
METRIC_PID=$!

echo "Starting log generation (${LOG_RPS} logs/sec)..."
telemetrygen logs \
    --otlp-http \
    --endpoint "${ENDPOINT}" \
    --rate "${LOG_RPS}" \
    --duration "${DURATION}" \
    --workers "${WORKERS}" \
    --service-name "load-test-service" \
    --otlp-attributes='cluster.id="load-test"' &
LOG_PID=$!

echo ""
echo "Load test running... (PIDs: traces=${TRACE_PID}, metrics=${METRIC_PID}, logs=${LOG_PID})"
echo "Press Ctrl+C to stop early."

cleanup() {
    echo ""
    echo "Stopping load test..."
    kill "${TRACE_PID}" "${METRIC_PID}" "${LOG_PID}" 2>/dev/null || true
    wait "${TRACE_PID}" "${METRIC_PID}" "${LOG_PID}" 2>/dev/null || true
    echo "Load test stopped."
}

trap cleanup INT TERM

wait "${TRACE_PID}" "${METRIC_PID}" "${LOG_PID}" 2>/dev/null || true

echo ""
echo "Load test complete."
