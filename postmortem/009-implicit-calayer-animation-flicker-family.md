# POSTM-009: Implicit CALayer Animation Flicker Family

**Date**: 2026-06-09
**Impact**: UI (flicker family: translation drift-in from top-left, one-frame ghost rows, page-swap giant doubled text, sweep/dot smear)
**Severity**: P1
**Commit**: 286d669b (layer fix) + 907e67a1 (stale-rows gate) + dc32cfca (bg crossfade) + f772c8f9 (duration heartbeat)

## Summary

The native lyrics renderer exhibited a persistent family of flickers that survived ~30 fix commits over 6 days: translation text drifted in diagonally from the top-left corner when it first loaded, ghost rows flashed for one frame at interlude/reflow boundaries, lyric text briefly rendered doubled at ~2× scale during loading↔content swaps, and the karaoke wavefront/dots smeared. Frame-by-frame analysis of a 60fps screen recording plus a layer-tree auditor proved a single root cause behind most of the family: manually-created CALayer sublayers carry Core Animation's default 0.25s implicit action on every property change, and the assignment site (NSView.layout()) runs in AppKit's own transaction, which no call-site CATransaction wrap can reach.

## Timeline

| Time | Event |
|------|-------|
| 2026-06-03 ~ 06-09 | ~30 `fix(lyrics)` commits chase individual flash sites (CATransaction wraps, prepareForReuse resets, debounces) — each fixes one symptom, new ones keep appearing |
| 2026-06-09 04:02 | User records 18s video showing 5 distinct glitch classes; reports translation drifting in from top-left, "attempted thousands of times, all failed" |
| 2026-06-09 (this session) | ffmpeg scene-detection + 60fps burst extraction localize every glitch to a frame; code recon finds 25 bare layer-creation sites and only 3 `setDisableActions` wraps in a 4,800-line renderer |
| same day | Failing unit test reproduces the drift (`["position","bounds"]` implicit animations on the translation layer) — first deterministic reproduction; layer-level fix lands; auditor + live captures verify zero leaks |

## Root Cause Analysis

### Five Whys

1. Why did the translation drift in from the top-left? Because its `CATextLayer` was parked at `frame = .zero` while loading, and when the real frame arrived, Core Animation implicitly animated `position` + `bounds` from the origin over 0.25s.
2. Why did an implicit animation run at all? Because manual sublayers of a layer-backed NSView get the full default action search on every animatable property change — AppKit only suppresses actions for the view's OWN backing layer.
3. Why didn't the existing `CATransaction.setDisableActions` fixes cover it? Because the frames are assigned inside `NSView.layout()`, which AppKit invokes inside its own, un-wrapped transaction — call-site wrapping can never reach it.
4. Why did 30 commits of fixes fail to converge? Because each fix targeted a mutation *site* while the leak class lives on the *layers*; any new property write anywhere reintroduced the bug (whack-a-mole by construction).
5. **Root cause**: The renderer had no layer-level implicit-animation policy and no objective detector for stray animations, so an entire class of invisible one-frame defects could neither be prevented nor proven fixed.

### Category
- [x] Architecture (missing hygiene invariant + missing observability)
- [ ] Bug
- [ ] Scale
- [ ] Dependency
- [ ] Process
- [ ] Unknown

## Impact

- User impact: visible flickers on translation load, track change, interlude handoff, and page swap — severe UX degradation, repeatedly reported.
- Technical impact: per-tick property sets (wavefront, dots) each spawned interrupted 0.25s animations, adding render-server churn; fix attempts consumed days.

## Actions Taken

- [x] `NativeLyricsInertLayerDelegate` (returns `NSNull` for every action) applied via `.lyricsInert()` to all 25 renderer layer-creation sites; `NativeLyricsSweepMaskLineLayer` overrides `action(forKey:)`. Explicit named CAAnimations (loading dots) are unaffected — they bypass the action search.
- [x] `NativeLyricsImplicitAnimationTests`: deterministic reproduction. Key discovery: the test MUST host views in a realized `NSWindow` AND `CATransaction.flush()` + spin the run loop between the committed state and the mutation — CA never animates layers added in the current uncommitted transaction, which is why naive tests pass silently against broken code.
- [x] Runtime auditor (`#if LOCAL_DEVELOPER_BUILD`): ~4Hz layer-tree sweep in `presentationTick` logs any animation key not explicitly allowlisted (`ImplicitAnimLeak` lines). An implicit action lives 0.25s, so 4Hz cannot miss one.
- [x] Stale-rows gate (907e67a1): SwiftUI `onChange` runs after body, so the first post-track-change render carried new identity + old cached rows → one-frame old-song flash. Cache now tagged with its track key; mismatched rows render as `[]`.
- [x] Background crossfade (dc32cfca) and duration/identity heartbeat (f772c8f9) for the two non-renderer glitches from the same recording.

## Verification

- Unit: RED (`["position","bounds"]` attached) → GREEN after fix; full 554-test suite green.
- Live: 22s @120fps steady-state capture — zero scene-detect events ≥0.02 (the broken recording had 12 at the same threshold); auditor logged zero leaks across a full user session of rapid track-skipping, scrolling, and hovering; sweep/blur/dots verified intact frame-by-frame.

## Follow-up Actions

| ID | Action | Owner | Due Date | Status |
|----|--------|-------|----------|--------|
| PM-009-1 | Slow no-result lyric fetches (~18s source exhaustion) leave a bare spinner; decide loading-state UX (progress hint vs. faster terminal) with user input | - | - | Pending |
| PM-009-2 | LyricsLayerRendererView.swift is 4,900+ lines (limit 800); split when renderer work stabilizes | - | - | Pending |

## Lessons Learned

### What went well
- Objective tooling first: ffmpeg scene-detection turned "hard to capture" one-frame glitches into timestamps; the auditor turned them into log lines; the unit test turned the mechanism into a regression gate.
- The TDD gate caught two false test designs (detached views, single-transaction mutations) before they could fake a GREEN.

### What could be improved
- A 4,800-line view manipulating 25 layers had no creation-time policy; invariants this global must be installed at the factory, not the call sites.
- Past fixes claimed success from looking at single screenshots; full-capture scene-detection should be the standard gate for motion work (now in CLAUDE.md / banned-patterns).

### Where we got lucky
- All intended motion was already per-tick property sets or explicit named animations, so blocking every implicit action lost nothing — no UX had to be rebuilt.

## Tags
#architecture #lyrics #calayer #implicit-animation #flicker #rendering
