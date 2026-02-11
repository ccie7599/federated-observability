#!/usr/bin/env bash
set -euo pipefail

# Unit tests for OTel collector configuration validation
# Checks structural correctness without requiring otelcol binary

BASE_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
ERRORS=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; ((ERRORS++)); }

echo "=== Config Structure Validation ==="

# Test: All configs have required service section
echo ""
echo "--- Service Section Checks ---"
for config in "${BASE_DIR}"/edge-collector/*-config.yaml \
              "${BASE_DIR}"/hub-gateway/gateway-config.yaml \
              "${BASE_DIR}"/hub-routing/router-*/config.yaml; do
    name="$(basename "$(dirname "$config")")/$(basename "$config")"
    if grep -q "service:" "$config" 2>/dev/null; then
        pass "${name} has service section"
    else
        fail "${name} missing service section"
    fi
done

# Test: All configs have health_check extension
echo ""
echo "--- Health Check Extension ---"
for config in "${BASE_DIR}"/edge-collector/*-config.yaml \
              "${BASE_DIR}"/hub-gateway/gateway-config.yaml \
              "${BASE_DIR}"/hub-routing/router-*/config.yaml; do
    name="$(basename "$(dirname "$config")")/$(basename "$config")"
    if grep -q "health_check:" "$config" 2>/dev/null; then
        pass "${name} has health_check"
    else
        fail "${name} missing health_check extension"
    fi
done

# Test: All configs have memory_limiter
echo ""
echo "--- Memory Limiter ---"
for config in "${BASE_DIR}"/edge-collector/*-config.yaml \
              "${BASE_DIR}"/hub-gateway/gateway-config.yaml \
              "${BASE_DIR}"/hub-routing/router-*/config.yaml; do
    name="$(basename "$(dirname "$config")")/$(basename "$config")"
    if grep -q "memory_limiter:" "$config" 2>/dev/null; then
        pass "${name} has memory_limiter"
    else
        fail "${name} missing memory_limiter processor"
    fi
done

# Test: Aggregator has PII scrubbing
echo ""
echo "--- PII Scrubbing (Aggregator) ---"
AGG_CONFIG="${BASE_DIR}/edge-collector/aggregator-config.yaml"
for pattern in "EMAIL_REDACTED" "SSN_REDACTED" "CC_REDACTED" "PHONE_REDACTED"; do
    if grep -q "${pattern}" "${AGG_CONFIG}" 2>/dev/null; then
        pass "Aggregator has ${pattern}"
    else
        fail "Aggregator missing ${pattern}"
    fi
done

# Test: Aggregator has sensitive header deletion
echo ""
echo "--- Sensitive Header Deletion ---"
for header in "http.request.header.authorization" "http.request.header.cookie" "http.request.header.x-api-key"; do
    if grep -q "${header}" "${AGG_CONFIG}" 2>/dev/null; then
        pass "Aggregator deletes ${header}"
    else
        fail "Aggregator does not delete ${header}"
    fi
done

# Test: Aggregator uses persistent queue
echo ""
echo "--- Persistent Queue ---"
if grep -q "file_storage" "${AGG_CONFIG}" 2>/dev/null; then
    pass "Aggregator uses file_storage for persistent queue"
else
    fail "Aggregator missing file_storage extension"
fi

# Test: Gateway exports to Kafka
echo ""
echo "--- Gateway Kafka Export ---"
GW_CONFIG="${BASE_DIR}/hub-gateway/gateway-config.yaml"
for topic in "otlp.metrics" "otlp.logs" "otlp.traces"; do
    if grep -q "${topic}" "${GW_CONFIG}" 2>/dev/null; then
        pass "Gateway exports to ${topic}"
    else
        fail "Gateway missing export to ${topic}"
    fi
done

echo ""
echo "=== Results: ${ERRORS} failures ==="
exit ${ERRORS}
