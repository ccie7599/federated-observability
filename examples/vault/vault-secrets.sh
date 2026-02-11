#!/bin/bash
# Vault Secrets Management for Federated Observability Platform
#
# This script provides helper functions to manage secrets in Vault

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://172.236.105.15:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
    list                    List all secrets in observability path
    get-tls <name>          Get TLS certificate (e.g., grafana)
    get-destination <name>  Get destination credentials (splunk, datadog, otlp)
    set-splunk <token> <endpoint>     Set Splunk HEC credentials
    set-datadog <api_key> [site]      Set Datadog API key
    set-otlp <endpoint> <auth_header> Set customer OTLP credentials

Environment:
    VAULT_ADDR   Vault server address (default: http://172.236.105.15:8200)
    VAULT_TOKEN  Vault authentication token (required)

Examples:
    # List all secrets
    $0 list

    # Get Grafana TLS cert
    $0 get-tls grafana

    # Set real Splunk HEC token
    $0 set-splunk "your-hec-token" "https://splunk.example.com:8088"
EOF
    exit 1
}

check_auth() {
    if [[ -z "$VAULT_TOKEN" ]]; then
        echo "Error: VAULT_TOKEN environment variable not set"
        exit 1
    fi
}

list_secrets() {
    check_auth
    echo "=== TLS Certificates ==="
    curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/observability/metadata/tls?list=true" | \
        jq -r '.data.keys[]' 2>/dev/null || echo "(none)"

    echo ""
    echo "=== Destination Credentials ==="
    curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/observability/metadata/destinations?list=true" | \
        jq -r '.data.keys[]' 2>/dev/null || echo "(none)"
}

get_tls() {
    check_auth
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "Error: TLS name required"; exit 1; }

    curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/observability/data/tls/$name" | \
        jq '.data.data'
}

get_destination() {
    check_auth
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "Error: Destination name required"; exit 1; }

    curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/observability/data/destinations/$name" | \
        jq '.data.data'
}

set_splunk() {
    check_auth
    local token="${1:-}"
    local endpoint="${2:-}"
    [[ -z "$token" ]] && { echo "Error: Splunk HEC token required"; exit 1; }
    [[ -z "$endpoint" ]] && { echo "Error: Splunk endpoint required"; exit 1; }

    curl -s -X POST \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"data\": {\"token\": \"$token\", \"endpoint\": \"$endpoint\"}}" \
        "$VAULT_ADDR/v1/observability/data/destinations/splunk" | \
        jq '.data.version'
    echo "Splunk credentials updated"
}

set_datadog() {
    check_auth
    local api_key="${1:-}"
    local site="${2:-datadoghq.com}"
    [[ -z "$api_key" ]] && { echo "Error: Datadog API key required"; exit 1; }

    curl -s -X POST \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"data\": {\"api_key\": \"$api_key\", \"site\": \"$site\"}}" \
        "$VAULT_ADDR/v1/observability/data/destinations/datadog" | \
        jq '.data.version'
    echo "Datadog credentials updated"
}

set_otlp() {
    check_auth
    local endpoint="${1:-}"
    local auth_header="${2:-}"
    [[ -z "$endpoint" ]] && { echo "Error: OTLP endpoint required"; exit 1; }
    [[ -z "$auth_header" ]] && { echo "Error: Auth header required"; exit 1; }

    curl -s -X POST \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"data\": {\"endpoint\": \"$endpoint\", \"auth_header\": \"$auth_header\"}}" \
        "$VAULT_ADDR/v1/observability/data/destinations/otlp" | \
        jq '.data.version'
    echo "OTLP credentials updated"
}

# Main
case "${1:-}" in
    list) list_secrets ;;
    get-tls) get_tls "${2:-}" ;;
    get-destination) get_destination "${2:-}" ;;
    set-splunk) set_splunk "${2:-}" "${3:-}" ;;
    set-datadog) set_datadog "${2:-}" "${3:-}" ;;
    set-otlp) set_otlp "${2:-}" "${3:-}" ;;
    *) usage ;;
esac
