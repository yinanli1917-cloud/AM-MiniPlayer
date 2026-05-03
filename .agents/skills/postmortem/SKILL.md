---
name: postmortem
description: Create and manage postmortem reports for bug fixes. Use /postmortem onboarding to analyze historical commits, /postmortem check to verify changes against known issues, or /postmortem create to document a new fix.
allowed-tools: Read, Grep, Glob, Bash(git:*)
user-invocable: true
---

# Postmortem Management Skill

This skill automates the creation and management of postmortem reports for bug fixes, helping prevent recurring issues through systematic analysis.

## When to Use

1. **Onboarding** - First time setup: analyze all historical fix commits
2. **Pre-Release** - Before releasing: check if changes trigger known issues
3. **Post-Fix** - After fixing a bug: create a new postmortem

## Workflow

### 1. Onboarding: Analyze Historical Commits

```
/postmortem onboarding
```

This will:
1. Scan all git commits with "fix" in the message
2. Analyze each fix commit for root causes
3. Generate postmortem reports in `postmortem/` directory
4. Update the index in `postmortem/README.md`

**Execution Steps:**
```bash
# Get all fix commits
git log --all --grep="fix" --grep="Fix" --grep="FIX" -i --oneline

# For each commit, analyze:
git show <commit-hash> --stat
git show <commit-hash> --format=fuller
```

**For each fix commit, create a postmortem using the template:**
1. Copy `postmortem/TEMPLATE.md` to `postmortem/XXX-brief-title.md`
2. Fill in:
   - Summary of what happened
   - Five Whys root cause analysis
   - Root cause category (Bug/Architecture/Scale/Dependency/Process/Unknown)
   - Impact assessment
   - Actions taken and follow-up actions

### 2. Pre-Release Check

```
/postmortem check
```

This will:
1. Check current uncommitted changes
2. Compare against all existing postmortems
3. Flag if changes might trigger known issue patterns
4. Provide recommendations

**Check Patterns:**
- SwiftUI `Section` + `LazyVStack` combinations → POSTM-001
- `.hudWindow` material usage → POSTM-001 (macOS 26 overexposure)
- State management changes without `@Published` → Check for state desync
- Concurrent artwork fetching without queue → Check for race conditions

**Execution:**
```bash
# Check current changes
git diff --name-only

# Check staged changes
git diff --staged --name-only

# Search for risky patterns
git diff | grep -i "Section" && echo "⚠️  Possible POSTM-001 trigger"
```

### 3. Create Postmortem for New Fix

```
/postmortem create <commit-hash>
```

This will:
1. Analyze the commit to understand what was fixed
2. Extract context from commit message and diff
3. Generate a postmortem draft
4. Prompt for Five Whys analysis
5. Create the postmortem file

**Interactive Questions:**
1. What was the symptom/user impact?
2. How long did it take to fix?
3. What was the root cause? (Five Whys)
4. What category does this fall under?
5. What follow-up actions are needed?

### 4. Update Index

```
/postmortem index
```

Updates `postmortem/README.md` with all postmortems organized by:
- ID (chronological)
- Category
- Severity

## Output Format

Each postmortem should follow this structure:

```markdown
# POSTM-XXX: [Brief Title]

**Date**: YYYY-MM-DD
**Impact**: [UI/Performance/Crash/Regression]
**Severity**: P0/P1/P2
**Commit**: [hash]

## Summary
[2-3 sentences: what happened, why, duration]

## Timeline
| Time | Event |
|------|-------|

## Root Cause Analysis

### Five Whys
1. Why [symptom]? Because [direct cause]
2. Why [direct cause]? Because [deeper cause]
3. **Root cause**: [System/process/design issue]

### Category
- [ ] Bug
- [ ] Architecture
- [ ] Scale
- [ ] Dependency
- [ ] Process
- [ ] Unknown

## Impact
- User impact: [what users saw]
- Technical impact: [system stability/performance]

## Actions Taken
- [ ] [Specific fix 1]
- [ ] [Specific fix 2]

## Follow-up Actions
| ID | Action | Owner | Due Date | Status |
|----|--------|-------|----------|--------|
| PM-XXX-1 | [Actionable + Specific + Bounded] | - | - | Pending |

## Lessons Learned
### What went well
### What could be improved
### Where we got lucky

## Tags
#category #component
```

## Examples

See `postmortem/001-swiftui-section-recursive-bug.md` for a complete example.

## Best Practices

### Five Whys Technique
Keep asking "why" until you reach a **system/process/design** issue, not a human error:

❌ **Bad**: "Because I made a typo"
✅ **Good**: "Because there's no automated test for this edge case"

### Action Wording
Make actions **Actionable**, **Specific**, and **Bounded**:

❌ **Bad**: "Investigate performance"
✅ **Good**: "Add signpost monitoring to PlaylistView scroll events"

### Blameless Culture
Focus on **why the system allowed the error**, not **who made the error**:

- Use role names ("the on-call engineer") not personal names
- Identify process gaps ("no code review checklist") not individual failures
- Think: "What change would prevent this class of incident?"

## Resources

- Main template: [`@postmortem/TEMPLATE.md`](postmortem/TEMPLATE.md)
- Index: [`@postmortem/README.md`](postmortem/README.md)
- Example: [`@postmortem/001-swiftui-section-recursive-bug.md`](postmortem/001-swiftui-section-recursive-bug.md)
- Reference: [`@.Codex/skills/postmortem/REFERENCE.md`](.Codex/skills/postmortem/REFERENCE.md)
