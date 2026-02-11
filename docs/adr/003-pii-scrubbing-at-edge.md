# ADR 003: PII Scrubbing at the Edge

## Status
Accepted

## Context
Bank compliance requires that Personally Identifiable Information (PII) never leaves the source environment unprotected. Telemetry data from application pods may contain PII in log messages, trace attributes, and metric labels.

## Options Considered
1. **Scrub at edge (aggregator)** - Before data leaves the source cluster
2. **Scrub at hub (gateway)** - After data arrives at the central hub
3. **Scrub at both** - Defense in depth

## Decision
Primary PII scrubbing happens at the edge aggregator. The hub does not perform additional PII scrubbing but validates that required attributes are present.

## Rationale
- **Data residency**: PII never transits the network between clusters
- **Compliance**: Meets bank requirement that PII is scrubbed before egress
- **Performance**: Distributed processing across edge clusters instead of centralizing at hub
- **Auditability**: Each edge cluster's config can be audited independently

## Implementation
The edge aggregator uses the OTel `transform` processor with regex patterns for:
- Email addresses → `[EMAIL_REDACTED]`
- Social Security Numbers → `[SSN_REDACTED]`
- Credit card numbers → `[CC_REDACTED]`
- Phone numbers → `[PHONE_REDACTED]`
- URL query parameters (password, token, api_key) → `[REDACTED]`

The `attributes` processor additionally:
- Hashes `db.statement` values (preserves uniqueness without exposing queries)
- Deletes authorization, cookie, and API key headers

## Enforcement
Kyverno policy `pii-scrubbing-required.yaml` validates that aggregator configs contain the required scrubbing patterns.

## Consequences
- **Positive**: PII never leaves the source cluster
- **Positive**: Kyverno policy prevents deploying configs without scrubbing
- **Negative**: Edge aggregator is more complex and resource-intensive
- **Negative**: New PII patterns require updating all edge clusters
- **Mitigation**: Kustomize overlays ensure consistent config across edges
