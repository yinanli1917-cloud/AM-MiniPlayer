# Postmortem Reference Guide

## Root Cause Categories

| Category | Definition | Typical Actions |
|----------|------------|-----------------|
| **Bug** | Code defect | Add tests, code review, canary deployment |
| **Architecture** | Design mismatch with runtime conditions | Redesign, platform migration |
| **Scale** | Resource constraints/capacity issues | Capacity planning, monitoring |
| **Dependency** | Third-party service failure | Add resilience, adjust expectations |
| **Process** | Missing workflow/check | Create checklist, automation |
| **Unknown** | Need more observability | Add logging, monitoring, debugging |

## Five Whys Examples

### Example 1: UI Performance Bug
1. Why is scrolling slow? → Because `SubgraphList.applyNodes` is called 223x
2. Why is it called so much? → Because `Section` triggers recursive layout in macOS 26
3. Why does `Section` recurse? → Framework bug with `pinnedViews`
4. Why use `Section`? → Standard SwiftUI pattern
5. **Root cause**: SwiftUI framework bug on macOS 26 with `Section` + `LazyVStack`

### Example 2: State Desync
1. Why is hover state wrong after page switch? → Because `@State` not reset
2. Why not reset? → Because no lifecycle hook for page switch
3. Why no lifecycle? → SwiftUI doesn't provide viewDidAppear equivalent
4. Why manually track? → Custom page switching implementation
5. **Root cause**: Missing state management pattern for custom page transitions

### Example 3: Race Condition
1. Why are artworks wrong? → Multiple fetches complete out of order
2. Why out of order? → No synchronization mechanism
3. Why no sync? → Fire-and-forget fetch design
4. Why fire-and-forget? → Optimized for simplicity
5. **Root cause**: Premature optimization without correctness guarantee

## Known Issue Patterns

### SwiftUI macOS Patterns
| Pattern | Known Issue | Postmortem | Mitigation |
|---------|-------------|------------|------------|
| `Section` + `LazyVStack` + `pinnedViews` | Recursive layout bug | POSTM-001 | Use `VStack` instead |
| `.hudWindow` material | Overexposure in Liquid Glass | POSTM-001 | Use `.underWindowBackground` |
| Custom page switching | State not reset | - | Manually reset state in `onChange` |

### Concurrency Patterns
| Pattern | Known Issue | Mitigation |
|---------|-------------|------------|
| Fire-and-forget fetches | Race conditions | Use task IDs / serial queue |
| Main-thread artwork loads | UI stutter | Background queue + main-thread publish |

### State Management Patterns
| Pattern | Known Issue | Mitigation |
|---------|-------------|------------|
| `@State` across pages | Desync on page switch | Reset in `onChange(of: currentPage)` |
| Shared without `@Published` | Stale updates | Add `@Published` to all shared state |

## Action Item Templates

### Test Actions
- Add unit test for [specific edge case]
- Add integration test for [component interaction]
- Add E2E test for [user flow]

### Monitoring Actions
- Add signpost monitoring to [function]
- Add alert for [metric] > [threshold]
- Add dashboard for [system health]

### Process Actions
- Create code review checklist for [component]
- Add pre-commit check for [pattern]
- Document [process] in CLAUDE.md

### Architecture Actions
- Refactor [component] to use [pattern]
- Replace [dependency] with [alternative]
- Add fallback mechanism for [failure mode]

## Git Commands for Analysis

### Get Fix Commits
```bash
# All fix commits
git log --all --grep="fix" -i --oneline

# Fixes in last month
git log --since="1 month ago" --grep="fix" -i --oneline

# Fixes with file changes
git log --grep="fix" -i --name-only --pretty=format:"%h %s"
```

### Analyze a Commit
```bash
# Show commit details
git show <hash> --stat

# Show full diff
git show <hash>

# Show files changed
git show <hash> --name-only --pretty=format:""
```

### Search Patterns
```bash
# Search for risky patterns in changes
git diff | grep -i "Section"

# Check for specific file changes
git diff --name-only | grep "PlaylistView"
```

## Postmortem Review Checklist

Before approving a postmortem, check:

- [ ] Root cause is a **system/process/design** issue, not human error
- [ ] Five Whys went deep enough (reached architectural/process level)
- [ ] Actions are Actionable (start with verb, describe outcome)
- [ ] Actions are Specific (scope is clearly defined)
- [ ] Actions are Bounded (has clear completion criteria)
- [ ] Category is correctly selected
- [ ] Lessons learned include all three: went well / to improve / got lucky
- [ ] Tags are added for discoverability
- [ ] Commit hash is linked

## Blameless Language Guide

| Instead of... | Use... |
|---------------|--------|
| "John forgot to..." | "The on-call engineer missed..." |
| "I made a typo" | "No input validation caught..." |
| "You didn't test this" | "No test coverage for this edge case" |
| "We should have known" | "The process didn't catch this" |
| "Careless mistake" | "System allowed this invalid state" |
