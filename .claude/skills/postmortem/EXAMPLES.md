# Postmortem Examples

## Example 1: Creating a Postmortem for a Recent Fix

**Scenario**: You just fixed a bug where artwork images were showing the wrong covers due to race conditions in the prefetch queue.

**Command**: `/postmortem create <commit-hash>`

**Interactive Flow**:

```
Analyzing commit abc123...

📋 Commit Message: fix: artwork race condition in playlist prefetch

📁 Files Changed:
- Sources/MusicMiniPlayerCore/Services/MusicController.swift

🔍 Diff Summary:
- Added artworkRequestID to track individual fetch requests
- Changed artworkFetchQueue to serial instead of concurrent
- Added request completion validation

✨ Drafting postmortem...
```

**Questions Asked**:

1. **What was the symptom?**
   - User saw wrong artwork covers in playlist
   - Artwork flickered when scrolling quickly

2. **How long to fix?**
   - 2 hours (1h diagnosis, 1h fix + test)

3. **Five Whys - Step 1**: Why wrong artwork?
   - Multiple fetch requests completed out of order

4. **Five Whys - Step 2**: Why out of order?
   - Concurrent queue allowed requests to finish in any order

5. **Five Whys - Step 3**: Why concurrent queue?
   - Originally designed for performance, prioritizing speed over correctness

6. **Root Cause**: Premature optimization - fire-and-forget fetch without ordering guarantees. Category: **Architecture**

7. **Impact**:
   - User: Confusing UI, wrong album covers
   - Technical: Data integrity issue

8. **Follow-up Actions**:
   - Review other fire-and-forget patterns
   - Add integration test for concurrent artwork fetches

**Generated Postmortem**: Saved to `postmortem/002-artwork-race-condition.md`

---

## Example 2: Pre-Release Check

**Scenario**: You're about to release a new version and want to ensure you haven't introduced any known issues.

**Command**: `/postmortem check`

**Output**:

```
🔍 Checking current changes against known postmortems...

📊 Current Changes:
- Modified: PlaylistView.swift
- Modified: LyricsView.swift
- New: ScrollDetector.swift

⚠️  Pattern Matches Found:

1. POSTM-001: SwiftUI Section Recursive Bug
   Risk: LOW
   Reason: No Section usage detected in current changes
   Status: ✅ PASS

2. State Management Review Needed
   Risk: MEDIUM
   Reason: ScrollDetector.swift introduces new state tracking
   Recommendation: Ensure state is reset on page switch
   Reference: Verify against any existing state desync postmortems

3. Concurrency Review Needed
   Risk: LOW
   Reason: No artwork fetch changes detected
   Status: ✅ PASS

✅ Pre-release check complete. 1 recommendation to review.
```

---

## Example 3: Onboarding

**Scenario**: New project, want to analyze all historical fixes.

**Command**: `/postmortem onboarding`

**Output**:

```
🔍 Analyzing git history for fix commits...

Found 15 fix commits:
1. abc123 - fix: artwork race condition
2. def456 - fix: lyrics state desync
3. ghi789 - fix: section performance bug
...

Processing 3/15...

✅ Generated postmortem/001-swiftui-section-recursive-bug.md
✅ Generated postmortem/002-artwork-race-condition.md
✅ Generated postmortem/003-lyrics-state-desync.md

📊 Summary:
- Total fix commits: 15
- Postmortems created: 3 (P0/P1 severity)
- Skipped: 12 (minor/trivial fixes)

📝 Updated postmortem/README.md index

🏷️  Issue Patterns Detected:
- SwiftUI macOS issues: 2
- State management: 3
- Concurrency: 2
- Performance: 1
```

---

## Example 4: Completed Postmortem

See [postmortem/001-swiftui-section-recursive-bug.md](../postmortem/001-swiftui-section-recursive-bug.md) for a fully filled-out example.

Key sections:
- Five Whys reaching framework-level root cause
- Specific actions with file references
- Lessons learned including "what we got lucky"
- Proper blameless language ("standard SwiftUI pattern" not "I used Section")

---

## Tips for Good Postmortems

### DO ✅
- Focus on system design, not individual mistakes
- Include exact file paths and line numbers for fixes
- Use specific, actionable follow-up items
- Document what went well too
- Mention luck/serendipity

### DON'T ❌
- Use names (use "the on-call engineer")
- Write vague actions ("investigate performance")
- Stop Five Whys too early ("because I typo'd")
- Blame external dependencies without analysis
- Skip the timeline
