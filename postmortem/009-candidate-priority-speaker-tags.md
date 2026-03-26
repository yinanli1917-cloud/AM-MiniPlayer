# POSTM-009: Candidate Priority Inversion + Speaker Tag Pollution

**Date**: 2026-03-24
**Scope**: Lyrics matching / Lyrics display
**Severity**: P1
**Related Commit**: pending

---

## Summary
- **Symptom**: BTS "Spring Day" returns Japanese lyrics instead of Korean original; QQ Music lyrics contain speaker tags ("JJ：", "Bruno Mars：") as lyric lines
- **Duration**: Since P3 removal in previous session (candidate matching) + since initial implementation (speaker tags)
- **Impact**: Wrong-language lyrics for multi-language K-pop songs; cluttered display for QQ-sourced lyrics

---

## Root Cause Analysis

### Five Whys — Spring Day

1. Why does "Spring Day" by BTS return Japanese lyrics?
   - Because NetEase P2 (title+artist+Δ<20s) matches "Spring Day (Japanese ver.)" first
2. Why does P2 match the Japanese version over the Korean "봄날"?
   - Because "봄날" doesn't match the title "Spring Day" (different scripts), so it can only match via P3 (artist+CJK+Δ<0.5s)
3. Why doesn't P3 get a chance?
   - **Root cause**: P2 (loose title match, Δ<20s) was evaluated BEFORE P3 (precise duration + CJK, Δ<0.5s). A Δ10s title match shouldn't beat a Δ0s CJK match.

### Five Whys — Speaker Tags

1. Why do "JJ：" and "Bruno Mars：" appear as lyric lines?
   - Because `stripMetadataLines` doesn't detect them
2. Why doesn't it detect them?
   - `isMetadataKeywordLine` requires non-empty value after the colon. "JJ：" has empty value.
3. **Root cause**: No dedicated speaker-tag detection. Speaker tags are a QQ Music convention where the value IS empty — it's a label, not a key-value pair.

### Root Cause Category
- [x] **Architecture** — Priority ordering didn't account for cross-script title scenarios
- [x] **Bug** — Missing parser rule for speaker tag format

---

## Fix

### Candidate Priority Reorder (LyricsFetcher.swift)
- Old: P1 (title+artist+Δ<3) → P2 (title+artist+Δ<20) → P3 (artist+CJK+Δ<0.5)
- New: P1 (title+artist+Δ<3) → P2 (artist+CJK/token+Δ<0.5) → P3 (title+artist+Δ<20)
- Rationale: precise-duration CJK match is a stronger signal than loose title match

### Speaker Tag Stripping (LyricsParser.swift)
- Added `isSpeakerTag()` — detects lines ≤20 chars ending with `：` or `:` with no content after
- Raised `isMetadataKeywordLine` label limit from 15 → 25 chars (covers "Background Vocals by")

### Benchmark Fix
- BM-KO-03 duration 285s → 274s (Korean version is ~4:34, Japanese version is ~4:45)

---

## Verification
- Spring Day: Korean lyrics confirmed ("보고 싶다", "그 봄날이 올까") via --dump and Musixmatch cross-reference
- Uptown Funk: Speaker tags removed, lyrics start with "Doh" then "This hit that ice cold"
- Despacito: Speaker tags removed from QQ China Mix version
- 77/77 unit tests pass
- Full benchmark regression: no regressions vs pre-fix baseline

---

## Lessons Learned

### What went well
- Exhaustive --dump inspection across 115 songs caught the Spring Day bug that automated validators missed
- Cross-referencing with third-party lyrics services (Musixmatch, Lyrical Nonsense) confirmed correctness

### What could have gone better
- The P3→P2 priority swap (from previous session's "three-rule principle") inadvertently created this regression
- Benchmark test case BM-KO-03 had the Japanese version's duration (285s), masking the issue

### Lucky
- The QQ Music candidate list showed both "Spring Day" (JP) and "봄날" (KR) with clear duration deltas, making the root cause traceable

---

## Tags
#lyrics #matching #priority #parser #k-pop
