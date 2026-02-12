Review this project and identify components that are reusable across future customer engagements. The goal is to build a personal asset library that accelerates future pre-sales work.

## Scan for these asset categories:

### 1. Terraform Modules
- Identify any Terraform configurations in the project.
- For each module, assess portability:
  - **Ready**: No customer-specific hardcoding, uses variables for all environment-specific values.
  - **Needs Abstraction**: Works but has hardcoded values (regions, names, sizing) that would need parameterization.
  - **Too Coupled**: Deeply intertwined with this specific deployment; extraction cost exceeds value.
- For "Ready" and "Needs Abstraction" modules, describe what changes would make them drop-in reusable.

### 2. Architecture Patterns
- Read SCOPE.md, README.md, DECISIONS.md, and any architecture docs.
- Identify the core architectural pattern being demonstrated (e.g., "fan-out messaging at edge", "federated observability with OTel collector hierarchy", "mTLS service mesh on LKE").
- Describe the pattern in vendor-neutral terms first, then note the Akamai-specific implementation.
- Assess: could this pattern narrative be reused in a customer presentation with minimal changes?

### 3. Configuration Templates
- Look for Kubernetes manifests, Helm values, Docker Compose files, or service configurations.
- Identify which ones represent good starting points for similar deployments.
- Flag any that contain secrets, customer-specific endpoints, or non-portable assumptions.

### 4. Test Harnesses
- Check `tests/`, `load/`, or any load testing configurations (Locust, k6, Artillery, etc.).
- Identify test scenarios that validate a general capability (e.g., "WebSocket connection scaling", "MQTT subscriber throughput") vs. customer-specific tests.
- Note the target scale numbers and whether results are captured.

### 5. Diagrams and Narratives
- Find any architecture diagrams (Mermaid, SVG, PNG, draw.io).
- Find any written architecture narratives or customer-facing docs.
- Assess which could be adapted for other customers or for external content (blog posts, talks).

### 6. Scripts and Utilities
- Look for helper scripts (deployment, monitoring setup, data generation, benchmarking).
- Identify which are general-purpose vs. project-specific.

## Output Format

```
# Asset Extraction Report — [Project Name]
Date: [today]

## High-Value Reusable Assets

### Ready to Extract (copy to asset library as-is)
| Asset | Type | Description | Suggested Library Path |
|-------|------|-------------|----------------------|
| [name] | [terraform/pattern/config/test/diagram/script] | [what it does] | [suggested path in ~/akamai-tsa-assets/] |

### Needs Abstraction (30-60 min of work to make portable)
| Asset | Type | What Needs to Change | Effort |
|-------|------|---------------------|--------|
| [name] | [type] | [specific changes needed] | [time estimate] |

### Not Reusable (document why, move on)
| Asset | Reason |
|-------|--------|
| [name] | [why it's too coupled] |

## Pattern Summary
**Core Pattern**: [1-2 sentence description of the reusable architectural pattern]
**Applicable To**: [types of customers/use cases this pattern serves]
**Akamai Services Used**: [list]

## Recommended Next Steps
1. [specific action to extract highest-value asset]
2. [specific action]
```

Prioritize assets by reuse potential — what would save the most time on the next similar engagement?
