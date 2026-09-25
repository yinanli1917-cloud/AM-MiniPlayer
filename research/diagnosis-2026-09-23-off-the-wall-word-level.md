# 2026-09-23 — "Off the Wall" word-level → line-level degradation

## Report

Founder, listening to Michael Jackson's *Off the Wall* album: some songs
"inexplicably degrade to line-level lyrics" — word-level (逐字) timing that
should exist is not shown, or gets replaced by line-level.

## Evidence gathered (before touching any code)

- `/tmp/nanopod_debug.log` covers the whole day (00:17–22:51). Only ONE track
  from this album was actually played/logged today: the title track "Off the
  Wall" by Michael Jackson, dur=245.778s, album="Off the Wall" — played twice
  (line 16666 `fetchLyrics START` at 22:42:42, and a second `fetchLyrics
  START` at 22:43:57 triggered by an "Identity self-heal: reissuing clean
  fetch" event, line 16812).
- Both times, NetEase returned word-level YRC data and won the race:
  - `[22:42:44] [NetEase] 🎯 YRC word-level: 47 lines, 47 synced` (line 16720)
  - `[LyricsFetcher.swift:1391] ⚡ Early return: NetEase score=100.0 >= 70
    albumMatch=true` (line 16722)
  - `[LyricsResultSelection.swift:219] 🎯 Word-level pre-filter: keeping
    ["NetEase"], dropping ["LRCLIB-Search", "LRCLIB"]` (line 16725/16865)
  - `[LyricsResultSelection.swift:890] 🏆 Final selection: NetEase
    (score=100.0, kind=synced)` (line 16726/16866)
  - `📋 Applied: ... 57L, firstReal="when the world is on your shoulder",
    unsynced=false` (line 16733/16873)
  - So in BOTH plays today, the UI correctly displayed NetEase's word-level
    result. The pipeline's source race / selection logic worked correctly
    for this specific play.
- Immediately after each successful selection:
  `[LyricsFetcher.swift:1707] ⏭️ fetchAllSources cancelled before result
  normalization` (line 16727/16867) — right after `⚡ apply-on-select:
  verdict at 1.6-1.9s, delivered at 1.6-1.9s`.
- Cross-checked against the real, live disk cache
  (`~/Library/Application Support/nanoPod/lyrics_cache.v31.json`, read-only,
  mtimes recorded before/after — see Safety below): **zero entries** for
  title="Off the Wall" / artist="Michael Jackson", despite the "Applied" log
  showing the word-level result was cached and shown twice today. 34 other
  songs were present. The disk cache key is
  `SHA256("<norm title>|<norm artist>|<norm album>|<rounded duration ±1>")`
  (`LyricsDiskCache.cacheKeys`); none of the three duration buckets around
  245.778s matched any stored key, and no entry's `album` field or lyric text
  matched either.

## Mechanism (file:line)

`LyricsFetcher.fetchAllSourcesUncached` (LyricsFetcher.swift:587) calls
`withHardTimeout(seconds:) { deliver in await
fetchAllSourcesWithinForegroundBudget(..., deliver: ...) }`.

`fetchAllSourcesWithinForegroundBudget` (line 650) races all 8 sources; once
the drain loop has a verdict (a winning result, e.g. NetEase word-level), it
computes `selectedForeground`/`sortedResults` and calls `deliver?(sortedResults)`
(line 1703) — this is "apply-on-select" (introduced in
`fefb8ce fix(lyrics): apply-on-select — resume caller at drain-loop verdict,
not after group teardown`, 2026-09-11), which lets the UI update the instant
a verdict exists instead of waiting for `TaskGroup` teardown of cancelled
children.

Immediately after that closure returns, the SAME function hits:

```swift
guard !Task.isCancelled, let verdict = verdictBox.value else {
    DebugLogger.log("⏭️ fetchAllSources cancelled before result normalization")
    return []
}
...
persistTrustedForegroundLyrics(from: finalResults, ...)   // line 1713 — the
                                                            // ONLY call that
                                                            // writes a fast/
                                                            // early-return
                                                            // verdict to the
                                                            // disk cache
```

`deliver` ultimately calls `withHardTimeout`'s `TimeoutState.resume(_:)`
(line ~3619, pre-fix):

```swift
func resume(_ value: T?) {
    ...
    worker?.cancel()               // <-- unconditional
    continuation?.resume(returning: value)
}
```

`worker` here IS the currently-executing task (the one that just called
`deliver`, i.e. that is about to fall through to the `Task.isCancelled` guard
above). So every apply-on-select delivery cancels its own worker BEFORE the
worker's own remaining code — including `persistTrustedForegroundLyrics` —
gets to run. The `Task.isCancelled` guard at line 1706 always trips
immediately after a successful early-return delivery, and the log line
`⏭️ fetchAllSources cancelled before result normalization` fires on
essentially every fast/successful fetch. This directly contradicts the
`apply-on-select` commit's own stated intent ("the worker keeps running to
finish teardown and post-verdict persistence").

Net effect: **the disk cache only ever gets populated by the SLOW/partial
path** (the `else` branch in `fetchAllSourcesUncached`, used when the hard
deadline is hit before any verdict — see line ~621-641, which persists
`partialResults` directly from the outer function and is NOT gated behind
`Task.isCancelled`). Fast, successful, word-level results are silently
dropped from persistence. Concretely, for "Off the Wall": every play has to
re-race all 8 sources from scratch (no `canUseImmediateDiskLyrics` fast
serve, LyricsFetcher.swift:703-720), because the disk cache never learned
this song is word-level via NetEase. On any play where NetEase happens to be
slow relative to a line-level source (LRCLIB, Genius, etc. — network jitter,
NetEase mirror hiccup), the pipeline's own fast-exit thresholds
(`elapsed >= 0.15` / `>= 2.2` / `>= 2.9` conditions around
LyricsFetcher.swift:1637-1648) can legitimately let a line-level source win
that particular race — and the result reads as "the same song sometimes
shows word-level, sometimes line-level," matching the founder's report,
without any single play's selection logic being wrong in isolation.

This is a generic concurrency bug in the apply-on-select primitive, not
specific to this song, this source, or CJK/English — it affects every track
that resolves via the fast early-return path (the common/good case for any
source).

## Fix

`TimeoutState.resume(_:cancelWorker:)` (LyricsFetcher.swift) now takes an
explicit `cancelWorker` flag (default `true`, preserving existing behavior
for the wall-clock-deadline and outer-cancellation resume paths). The
`deliver` closure handed to `operation` — the ONE call site where the worker
resumes itself with its own verdict — passes `cancelWorker: false`, so
`Task.isCancelled` stays false for the worker's own continuation after
`deliver()` returns, and its post-verdict code
(`persistTrustedForegroundLyrics` and structured-concurrency teardown) runs
to completion as originally intended.

`setWorker`'s belated-cancel race (when `deliver` fires before `setWorker`
has run) now respects the same flag via a stored `resumeWantsWorkerCancelled`
bit, so the ordering of `setWorker` vs. `resume` cannot reintroduce the bug.

## Repro test (red → green)

`Tests/MusicMiniPlayerTests/LyricsFetcherApplyOnSelectTests.swift`:
`test_deliverDoesNotCancelWorker_postVerdictWorkStillRuns` — calls the real
`withHardTimeout` primitive directly (no network), has the operation closure
call `deliver()` then check `Task.isCancelled` and run a "post-verdict work"
flag, structured exactly like `fetchAllSourcesWithinForegroundBudget`'s own
guard at line 1706. Confirmed red against the pre-fix code (`Task.isCancelled
== true` after `deliver()`, post-verdict work never runs — verified by
temporarily stashing the production fix and re-running), green after the fix.

## Safety / verification

- `~/Library/Application Support/nanoPod/` mtimes recorded before this
  session's test runs (lyrics_cache.v31.json 573025 bytes, 34 entries,
  16:59) and after (753394 bytes, 43 entries, 23:02). Every `swift test`
  invocation in this session logged `caches isolated at
  /var/folders/.../nanoPod-xctest-<pid> (scope testRun)` — confirming
  `NanoPodCacheLocation` correctly isolated test I/O away from the real
  directory. The real directory's growth (+9 entries) is attributable to the
  founder's own live app instance running independently during this session,
  not to any test run in this worktree — no test in this diagnosis ever
  passed a `url`/path under `~/Library/Application Support/nanoPod/`.
- No `Off the Wall` / Michael Jackson entry appeared in the real disk cache
  at any point during this session (checked before and after), consistent
  with the bug still being present in the founder's currently-running app
  binary (this fix has not been built/shipped yet).

## Tests run (all serial, DEVELOPER_DIR=Xcode)

- `LyricsFetcherApplyOnSelectTests` — 8/8 pass (incl. new test)
- `LyricsWordLevelPriorityTests` — 8/8 pass
- `LyricsSelectionTests` — 92/92 pass
- `AuthoritativeBackfillBudgetTests` — 10/10 pass
- `LyricsOriginalDeliverySLATests` — 10/10 pass
- `LyricsDiskCacheTests`, `LyricsCachePolicyTests`, `NanoPodCacheLocationTests`,
  `LyricsSelectionMemoizationTests`, `ResolverSingleFlightTests`,
  `NetworkOutcomeLedgerTests`, `MetadataDiskCacheTierTests` — 75/75 pass

No `LyricsVerifier` network runs were needed — the bug and its fix are fully
pinned by the `withHardTimeout`/`TimeoutState` unit test, which needs no
network, and the forensics used only the existing debug log + a read-only
inspection of the real disk cache file.
