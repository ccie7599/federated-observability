End-of-session wrap-up. Run this before closing out a work session to maintain documentation hygiene and catch drift early.

## Perform these checks in order:

### 1. Quick Scope Pulse
- Read SCOPE.md
- Compare against files modified in this session (check git status or recent file timestamps)
- Were any files created or modified that aren't traceable to the stated scope?
- One sentence: are we still on track? If not, what drifted?

### 2. Documentation Delta
- What was built or changed in this session?
- Is that change reflected in:
  - [ ] README.md (if user-facing behavior changed)
  - [ ] HANDOFF.md (if infrastructure or deployment changed)
  - [ ] DECISIONS.md (if a new component was introduced or a significant choice was made)
- List specific documentation updates needed. Don't just say "update docs" — name the file and the section.

### 3. ADR Check
- Were any new infrastructure components added this session? (services, databases, queues, proxies, Terraform resources)
- If yes, is there a corresponding ADR in DECISIONS.md?
- If no ADR exists, draft one now using the standard template.

### 4. Scale Table Update
- Were any performance tests run this session?
- If yes, update the Scale Commitment table in SCOPE.md:
  - Move tested capabilities from "Projected" to "Proven"
  - Add specific test results (numbers, dates, conditions)
  - Link to test output if available

### 5. Debugging Journal
- Was any significant debugging done this session (>30 min on a single issue)?
- If yes, capture:
  - What was the symptom?
  - What was the root cause?
  - How long did it take?
  - Should this inform an architecture change or is it a one-off?
  - Add a note to the runbook if it's a failure mode others might hit.

### 6. Tomorrow's Starting Point
- What is the single most important next step for the next session?
- Are there any blockers or decisions needed before work can continue?
- Is there anything that should be timeboxed in the next session to prevent rabbit-holing?

## Output Format

```
# Session Wrap-Up — [Project Name]
Date: [today]
Session Duration: [estimated]

## Scope Status: ✅ On Track | ⚠️ Minor Drift | 🚨 Significant Drift
[1 sentence explanation]

## What Changed
- [bullet list of meaningful changes this session]

## Documentation Updates Needed
- [ ] [specific file]: [specific section] — [what to add/update]

## Missing ADRs
- [ ] [component]: [brief description of decision to document]

## Scale Updates
- [any new proven capabilities, or "no tests this session"]

## Debug Notes
- [any significant debugging, or "clean session"]

## Next Session
**Priority**: [single most important task]
**Timebox**: [if something needs a time limit, state it]
**Blockers**: [any, or "none"]
```

Keep it brief. This should take 2-3 minutes to review, not 20.
