Review SCOPE.md and compare it against the current state of the project. Perform a thorough audit.

## Check these items:

### 1. Scope Alignment
- Read SCOPE.md and identify the stated Problem Statement, Tier Classification, and Exit Criteria.
- List every file, directory, and infrastructure component in the project.
- Flag anything that is NOT directly traceable to the stated problem. Be specific — name the file/component and explain why it may be out of scope.

### 2. Scope Creep Indicators
- Check git log (if available) or file modification times for components added after the initial project structure was established.
- Look for infrastructure components (Helm charts, Terraform modules, Docker configs, new services) that weren't part of the original architecture. List them.
- Search for TODO/FIXME/HACK comments that suggest rabbit holes or tangential work.

### 3. Debugging Time Check
- Review git log for repeated commits against the same file or issue area that suggest extended debugging sessions.
- Flag any area where it appears more than 2 hours of effort has been spent debugging a single issue without a resolution or architectural pivot.

### 4. Scale Honesty
- Check the Scale Commitment table in SCOPE.md.
- Are the "Proven (tested)" columns filled in with actual test results, or are they empty/aspirational?
- Are there load test scripts in `tests/load/` that validate the proven numbers?
- If Proven columns are empty but the README or architecture docs cite specific scale numbers, flag this as a proven/projected gap.

### 5. Non-Goals Enforcement
- Re-read the Explicit Non-Goals section.
- Check if any current code or infrastructure appears to violate a stated non-goal.

## Output Format

```
# Scope Health Report — [Project Name]
Date: [today]
Tier: [from SCOPE.md]

## Status: 🟢 Green | 🟡 Yellow | 🔴 Red

## Scope Alignment
- [findings]

## Creep Detected
- [list any out-of-scope additions]

## Debugging Rabbit Holes
- [list any extended debugging sessions]

## Scale Honesty
- Proven claims with evidence: X
- Projected claims without evidence: Y
- ⚠️ Gaps: [list]

## Non-Goal Violations
- [list any]

## Recommendations
1. [specific action]
2. [specific action]
```

Be direct and honest. The purpose of this check is to catch drift early, not to validate that everything is fine.
