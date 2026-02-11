# ADR 001: OTLP over HTTPS on Port 443

## Status
Accepted

## Context
Bank firewalls restrict outbound traffic to well-known ports. Raw gRPC on port 4317 is blocked by network security policies. We need edge clusters to send telemetry to the hub cluster through corporate firewalls.

## Decision
Use OTLP/HTTP protocol over HTTPS on port 443 for edge-to-hub communication instead of OTLP/gRPC on port 4317.

## Consequences
- **Positive**: Works through all corporate firewalls and proxies
- **Positive**: Standard HTTPS port requires no firewall exceptions
- **Positive**: HTTP/2 still provides multiplexing benefits
- **Negative**: Slightly higher overhead than raw gRPC (HTTP framing)
- **Negative**: Some OTel features may have better gRPC support
- **Mitigation**: Internal cluster communication (agent → aggregator) still uses gRPC for performance
