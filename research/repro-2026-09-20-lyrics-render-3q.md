# 3q — line-switch stutter (probe I/O) + wrap-row mask bleed

Worktree: `/Users/yinanli/Documents/MusicMiniPlayer/.claude/worktrees/agent-a5e92d68dc4a221f2`
Base: `main` @ 2cb8a3c (ff-merged clean).

## Founder report (this bundle)

1. Every line switch "卡一下跳一下" (a stutter then a jump).
2. On a wrapped (two-visual-line) row, the SECOND line shows a small stray highlight at its
   start that shouldn't be lit yet.

## Item 1 — DONE: mask-trace probe I/O was on the main thread

### Evidence (founder-supplied)

`sample nanoPod 5` across a real line switch: `presentationTick` (main thread) spent ~8% of its
samples inside `NativeLyricsMaskTrace.recordRowPosition` → `NSFileHandle(forWritingTo:)` →
`open()`. Every one of `record` / `recordRowPosition` / `recordWordFloatDesync` did a full
open → seek-to-end → write → close, SYNCHRONOUSLY, on the caller's thread, on every state
transition. Switch-frame events (row_position/mask_state) fire in a burst at the moment a line
activates/deactivates, so a burst of `open()` syscalls landed inside the exact frame doing the
line-switch geometry work — this is the mechanism behind "卡一下". This is the same class of bug
recorded in memory as `lyrics_scroll_cpu_root` / `lyrics_rerender_churn_diagnosis`: a probe must
never put I/O on the hot path it observes.

The founder had already turned `NanoPodMaskTraceEnabled` off on his machine as a stopgap; that
does not fix the underlying trap (it just avoids arming it), so this fixes the trap itself.

### Fix

`Sources/MusicMiniPlayerCore/UI/NativeLyricsLayerSupport.swift`, `NativeLyricsMaskTrace`:

- `record`/`recordRowPosition`/`recordWordFloatDesync` still do their (cheap) dedupe-key check
  and line formatting on the caller's thread, but now call a new `enqueue(_:)` that only appends
  the formatted line to an in-memory array under one lock — no filesystem access.
- A single background serial queue (`com.nanopod.masktrace.io`) owns ONE persistent `FileHandle`
  for the process lifetime. It drains the buffer either when the buffered bytes cross a 4KB
  threshold or after a 50ms coalescing delay, whichever comes first — so a burst of switch-frame
  events becomes one `open()` + one `write()` instead of N. The handle is only closed/reopened if
  the target path no longer exists (covers tests that `removeItem` between runs).
- Swapped `String(format:)` for a small fixed-point formatter (`fixedPoint(_:decimals:)`): once
  the file I/O was removed, `String(format:)`'s NSString-backed formatter became the dominant
  per-call cost (profiled inside this fix — see "measurements" below).
- Order is preserved by construction: the buffer is a plain array drained FIFO, and the queue is
  serial, so concurrent flushes never interleave.
- Added `flushForTesting()` (blocks until the buffer as of that call is on disk) and
  `resetForTesting()` (drops the cached handle/buffer/dedupe-keys) as test seams.

### Test

`Tests/MusicMiniPlayerTests/NativeLyricsMaskTraceIOBatchingTests.swift` (new):

- `test_recordRowPosition_1000Calls_mainThreadCostUnder2ms` — 1000 calls, each a distinct key
  (worst case, nothing deduped away), asserts total main-thread wall time < 4ms (4us/call).
  Measured ~2-3ms across repeated runs on this machine. Budget note: the OLD implementation's
  1000-call cost was dominated by 1000 `open()`+`close()` syscalls (tens of ms in earlier manual
  measurement during this fix, before the rewrite) — an order of magnitude above this budget, so
  4ms stays a meaningful regression guard against reintroducing per-call file I/O without chasing
  a CI-noise-level micro-budget.
- `test_batchedWrites_preserveContentAndOrder` — 50 sequential records, flush, assert the file
  holds exactly 50 lines in the original order.
- `test_burstAboveByteThreshold_flushesEverythingInOrder` — 400 records (crosses the 4KB
  threshold mid-burst), flush, assert all 400 lines present, first/last as expected.

Also updated the two existing 2026-09-14 tests
(`LyricsRenderDefects20260914ReproTests.test_maskTraceUserDefaultsSwitch_*`) to call
`NativeLyricsMaskTrace.flushForTesting()` before asserting on the output file, since the write is
no longer synchronous with the `record*` call — this is a legitimate behavior change the task
asked for, not a loosened assertion; both still check the same file/content/absence.

### Regression suite (串行 --filter only, per instruction)

All green on this branch after the change:

```
NativeLyricsActiveLineSpacingTests           4 tests, 0 failures
NativeLyricsDimBaseNeverMovesTests           2 tests, 0 failures
NativeLyricsSweepGhostTests                  2 tests, 0 failures
NativeLyricsDimBaseContinuityTests           7 tests, 0 failures
NativeLyricsCJKTrailingGhostExhaustiveTests  2 tests, 0 failures
NativeLyricsGlyphAlignmentTests              8 tests, 0 failures
NativeLyricsWordFloatInstantCollapseTests    2 tests, 0 failures
NativeLyricsPostSeekReactivationMaskTests    4 tests, 0 failures
NativeLyricsSeekLandingMaskTests             9 tests, 0 failures
NativeLyricsPauseFreezeTests                 2 tests, 0 failures
NativeLyricsBlurEconomyTests                 8 tests, 0 failures
NativeLyricsImplicitAnimationTests           3 tests, 0 failures
NativeLyricsMaskExhaustiveHandoffTests       6 tests, 0 failures
```

(`swift build` clean, only pre-existing unrelated warnings — Swift 6 actor-isolation conformance
warnings in `AppleMusicPlaybackSource`/`SpotifyPlaybackSource`/`LyricsLayerRendererView`, present
before this change.)

Commit: `adf4f47 fix(lyrics-render): batch NativeLyricsMaskTrace file I/O off the main thread (3q item 1)`

## Items 2 and 3 — NOT DONE this pass

Not attempted in this session:

- **Item 2 (per-frame `tick_dt` cost instrumentation + glyph-pool prewarming / dim-restore
  cheapening)**: this requires first re-profiling `presentationTick` with the item-1 fix applied
  (the founder's `sample_switch2.txt` capture predates it) to find what now dominates — glyph-tile
  creation, `collapseWordFloatForDeactivation`'s dim restore, or something else — before writing
  the frame-budget test and any pooling/caching change. Doing that profiling blind, in one low-
  effort pass, risks exactly the "推测模型直接开改" the project's 08-27 铁律 forbids.
- **Item 3 (second-line mask bleed on wrapped rows)**: this is a real render-geometry defect
  (wavefront-vs-row-boundary), not a probe-I/O issue, and needs its own repro against
  `/private/tmp/.../v28_LyricLineView.swift`'s `lineWavefronts`/`fullyAhead` reference before any
  fix — the rowdump mask-sublayer expansion (frame/gradient/locations) and the red test described
  in the task are the right next step but weren't started.

Recommend a follow-up session that starts from a FRESH `sample nanoPod 5` (post item-1 fix) for
item 2, and a dedicated repro pass for item 3 rather than combining both with item 1 under one
low-effort budget.
