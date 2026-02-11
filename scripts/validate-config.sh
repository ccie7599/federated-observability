#!/usr/bin/env bash
set -euo pipefail

# Validate all OTel collector configs and Kustomize overlays
# Usage: ./scripts/validate-config.sh [--fix]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "========================================="
echo " Federated Observability Config Validator"
echo "========================================="
echo ""

# Check for required tools
check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${YELLOW}WARNING: $1 not found, skipping $2 validation${NC}"
        return 1
    fi
    return 0
}

# 1. Validate OTel Collector configs
echo "--- OTel Collector Config Validation ---"
if check_tool otelcol-contrib "OTel collector"; then
    for config in $(find "${BASE_DIR}" -name '*-config.yaml' \( -path '*/edge-collector/*' -o -path '*/hub-gateway/*' -o -path '*/hub-routing/*' \)); do
        echo -n "  Validating $(basename "$(dirname "$config")")/$(basename "$config")... "
        if otelcol-contrib validate --config="$config" 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            ((ERRORS++))
        fi
    done
fi
echo ""

# 2. Validate Kustomize builds
echo "--- Kustomize Build Validation ---"
if check_tool kustomize "Kustomize"; then
    for overlay in $(find "${BASE_DIR}" -type d -name 'overlays' -exec find {} -mindepth 1 -maxdepth 1 -type d \;); do
        echo -n "  Building ${overlay#${BASE_DIR}/}... "
        if kustomize build "$overlay" >/dev/null 2>&1; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            kustomize build "$overlay" 2>&1 | head -5
            ((ERRORS++))
        fi
    done
fi
echo ""

# 3. Validate Kubernetes manifests with kubeconform
echo "--- Kubernetes Manifest Validation ---"
if check_tool kubeconform "Kubernetes manifest" && check_tool kustomize "Kustomize"; then
    for overlay in $(find "${BASE_DIR}" -type d -name 'overlays' -exec find {} -mindepth 1 -maxdepth 1 -type d \;); do
        echo -n "  Validating ${overlay#${BASE_DIR}/}... "
        if kustomize build "$overlay" 2>/dev/null | kubeconform -strict -summary 2>/dev/null; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            ((ERRORS++))
        fi
    done
fi
echo ""

# 4. Check for common issues
echo "--- Security Checks ---"

# Check for insecure TLS settings in prod configs
echo -n "  Checking for insecure TLS in production configs... "
if grep -r "insecure: true" "${BASE_DIR}"/*/overlays/prod/ 2>/dev/null; then
    echo -e "${RED}FAILED - Found insecure TLS in production configs${NC}"
    ((ERRORS++))
else
    echo -e "${GREEN}OK${NC}"
fi

# Check PII scrubbing is present in aggregator config
echo -n "  Checking PII scrubbing in aggregator config... "
if grep -q "EMAIL_REDACTED" "${BASE_DIR}/edge-collector/aggregator-config.yaml" 2>/dev/null && \
   grep -q "SSN_REDACTED" "${BASE_DIR}/edge-collector/aggregator-config.yaml" 2>/dev/null && \
   grep -q "CC_REDACTED" "${BASE_DIR}/edge-collector/aggregator-config.yaml" 2>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED - Missing PII scrubbing patterns${NC}"
    ((ERRORS++))
fi

# Check resource limits are set
echo -n "  Checking resource limits on deployments... "
MISSING_LIMITS=$(grep -rL "limits:" "${BASE_DIR}"/{edge-collector,hub-gateway,hub-routing}/*-deployment.yaml "${BASE_DIR}"/hub-routing/router-*/deployment.yaml 2>/dev/null || true)
if [ -z "$MISSING_LIMITS" ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}WARNING - Missing resource limits in: ${MISSING_LIMITS}${NC}"
    ((WARNINGS++))
fi

echo ""
echo "========================================="
echo -e " Results: ${RED}${ERRORS} errors${NC}, ${YELLOW}${WARNINGS} warnings${NC}"
echo "========================================="

exit $ERRORS
