# HANDOFF — 2026-03-26 (Session 4)

## Current Task
Two open issues from lyrics pipeline testing:
1. **Slow lyrics fetching** — user reports it's slower than before (early return optimization may have regressed)
2. **MetadataResolver mismatches low-quality sources** — LRCLIB/lyrics.ovh/Genius win over NetEase/QQ due to scoring, not because they're better

## Completion Status
- ✅ Genius section tags stripped (`isSectionTag` in `stripMetadataLines`)
- ✅ Timestamp overflow clamped (`rescaleTimestamps` endTime clamp)
- ✅ Language tags stripped (`(日文)` etc. in `normalizeTrackName` + `cleanTrackTitle`)
- ✅ EN→CJK artist resolution (cross-script tolerance in `matchCNResult`)
- ✅ Traditional↔Simplified CN title matching (`toSimplifiedChinese` in `matchCNResult`)
- ✅ CN cross-validation guard relaxed (exact artist match bypasses CN requirement)
- ✅ SimpMusic source restored (was removed in 91dbf10 refactor)
- ✅ NetEase lyrics-retry fallback (when matched song has no lyrics, retry excluding that ID)
- ✅ NetEase/QQ search limit increased to 30
- ✅ P2 duration threshold widened to 30s (was 20s)
- ✅ `isAcceptable` duration relaxed to 30s when title+artist both match
- ✅ 11 test cases corrected to `shouldFindLyrics: false`
- ✅ 77/77 unit tests pass
- 🔄 **Slow fetching** — user says it's noticeably slower than before optimizations
- 🔄 **MetadataResolver quality** — low-quality sources (LRCLIB/Genius) sometimes win over NetEase/QQ
- ⏳ Test case duration for POP-01 "How Sweet" needs fixing: 191→219s

## Key Decisions (this session)
- `isSectionTag`: generalized `[…]` line detection (any short non-timestamp bracket content)
- CN cross-validation: relaxed when artist name matches exactly — indie JP artists (mei ehara) were being blocked because CN iTunes had nothing
- P2 30s threshold: Apple Music durations differ significantly from NetEase/QQ versions (e.g., "How Sweet" AM=219s vs NetEase remix=192s). Old 20s threshold rejected legitimate matches
- SimpMusic restored but its API is behind Vercel bot protection — effectively dead, kept for when/if it comes back
- NetEase retry: when P1 matches a remix with no lyrics, retry excluding that ID to find the original

## Known Issues / Pitfalls

### 1. Speed regression
User had previously optimized early-return. Current session added:
- SimpMusic source (8th parallel source, always times out due to Vercel block → 6s wasted)
- NetEase retry (second full search round when first match has no lyrics)
- Search limit 30 instead of 20 (slightly more data per request)

**Fix approach**: Remove SimpMusic (dead API), or add a fast-fail check. Consider if early return threshold (80pts) is still effective.

### 2. MetadataResolver mismatch pattern
The user reports that MetadataResolver sometimes resolves to titles/artists that only match low-quality sources. Root cause: MetadataResolver queries iTunes API which may return different metadata than what NetEase/QQ index. When the resolved title doesn't match NetEase/QQ's database, only LRCLIB/Genius find results.

**Fix approach**: The scoring system already has source bonuses (NetEase +8, QQ +6, LRCLIB +3, Genius +0). The issue is when NetEase/QQ return NO results and only low-quality sources return anything. The `selectBest` logic prefers synced≥30 over unsynced, which is correct. The real fix is improving MetadataResolver's title resolution to align with NetEase/QQ's database naming — possibly by sending BOTH original and resolved titles to each source.

### 3. LRCLIB flakiness
LRCLIB exact match API returns data via curl but sometimes fails silently in the app. Likely connection pooling or timeout issue in `HTTPClient.getJSON`. Debug logging added to `fetchFromLRCLIB` to trace this.

### 4. QQ Music API non-determinism
QQ's search API returns different result sets across calls. Songs that appear in one run may not appear in the next. No fix — this is QQ's API behavior. The title-only search fallback helps but doesn't guarantee consistency.

## Next Steps
1. **Fix speed**: Remove dead SimpMusic source, profile the early-return path
2. **Fix MetadataResolver quality**: Send both original AND resolved titles to NetEase/QQ (currently only resolved title is sent) — this ensures NetEase/QQ can match even when MetadataResolver resolves to a different name
3. **Fix POP-01 test case**: Change duration from 191 to 219
4. **Run full 80-case regression** to verify no regressions from this session's changes

## Changed Files
- `LyricsFetcher.swift`: SimpMusic restored, retry fallback, title-only search, limit=30, P2→30s
- `LyricsParser.swift`: `isSectionTag` for Genius `[Verse]`/`[Chorus]` stripping
- `MetadataResolver.swift`: cross-script artist tolerance, Trad→Simp CN matching, CN guard relaxed
- `LanguageUtils.swift`: CJK language tag regex `(日文)` etc.
- `MatchingUtils.swift`: `isAcceptable` duration 30s when title+artist match
- `docs/lyrics_test_cases.json`: 11 songs corrected to `shouldFindLyrics: false` (user edited externally)

---
*Created by Claude Code · 2026-03-26T09:40*
