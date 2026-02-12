Review HANDOFF.md and the current project state. Assess whether a competent engineer who has never seen this project could deploy, operate, and troubleshoot it using only the documentation provided.

## Audit Checklist

### 1. Architecture Documentation
- [ ] Is there an architecture diagram (Mermaid, SVG, or image)?
- [ ] Does the narrative explain WHY components were chosen, not just WHAT they are?
- [ ] Is every deployed component (service, database, queue, cache, proxy, load balancer) represented?
- [ ] Are network flows and data flows documented?
- [ ] Are external dependencies (APIs, DNS, certificates, third-party services) listed?

### 2. Proven vs. Projected Honesty
- [ ] Is the Proven vs. Projected table present and filled in?
- [ ] Does every "Proven" claim have a link to test results, logs, or screenshots?
- [ ] Are "Projected" capabilities clearly labeled as untested?
- [ ] If the README or any customer-facing doc cites scale numbers, do they match the "Proven" column?
- Flag any scale claims that appear in docs but lack test evidence.

### 3. Deployment Runbook
- [ ] Are deployment steps written as executable commands (not prose descriptions)?
- [ ] Are all environment variables, secrets, and configuration values documented?
- [ ] Are there placeholder values or `TODO` markers that would block deployment?
- [ ] Can the deployment be run from a clean machine? (no assumed local tooling beyond standard)
- [ ] Is the order of operations explicit? (what gets deployed first, dependency chain)
- [ ] Are rollback steps documented?
- Test: mentally walk through each step. Would step N work if you'd only done steps 1 through N-1?

### 4. Day 2 Operations
- [ ] Is there a monitoring section? (what dashboards, what alerts)
- [ ] Are common failure modes listed with symptoms and remediation?
- [ ] Are scaling levers documented? (what to increase when load grows)
- [ ] Is there a "what breaks first" section? (the weakest link under pressure)
- [ ] Are log locations and formats documented?
- [ ] Is there a health check endpoint or verification procedure?

### 5. Decision Records
- [ ] Does DECISIONS.md exist?
- [ ] Is there an ADR for every major component choice? (database, message broker, compute platform, networking model)
- [ ] Does each ADR include alternatives considered and tradeoffs?
- [ ] Are there components in the architecture with NO corresponding ADR? Flag them.

### 6. Cost Model
- [ ] Is there a cost estimate for the target deployment?
- [ ] Does it specify which Akamai services and tiers are assumed?
- [ ] Is there a scaling cost curve (what happens at 2x, 5x, 10x)?
- [ ] Are there cost assumptions that may not hold? (e.g., egress, storage growth, burst pricing)

### 7. Known Gaps & Tech Debt
- [ ] Is there an honest list of known limitations?
- [ ] Are there shortcuts taken for demo purposes that would need hardening for production?
- [ ] Are security considerations addressed? (secrets management, network policy, RBAC)

## Output Format

```
# Handoff Readiness Report — [Project Name]
Date: [today]
Tier: [from SCOPE.md]

## Overall Status: 🟢 Green | 🟡 Yellow | 🔴 Red

### Scoring
- Architecture Docs:    [🟢🟡🔴] — [brief note]
- Scale Honesty:        [🟢🟡🔴] — [brief note]
- Deployment Runbook:   [🟢🟡🔴] — [brief note]
- Day 2 Operations:     [🟢🟡🔴] — [brief note]
- Decision Records:     [🟢🟡🔴] — [brief note]
- Cost Model:           [🟢🟡🔴] — [brief note]
- Known Gaps:           [🟢🟡🔴] — [brief note]

### Critical Gaps (must fix before handoff)
1. [specific gap and what to do about it]

### Important Gaps (should fix, will cause pain if not)
1. [specific gap]

### Nice to Have (improves quality but not blocking)
1. [specific gap]

### What's Working Well
- [call out what's already solid]
```

Scoring guide:
- 🟢 Green: A new engineer could use this section without asking questions.
- 🟡 Yellow: Usable but has gaps that would require Slack messages or meetings to fill.
- 🔴 Red: Missing or insufficient. Would block an independent deployment.

Be tough. A Yellow that should be Red helps no one.
