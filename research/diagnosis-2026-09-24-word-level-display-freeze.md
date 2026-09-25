# 2026-09-24 — word-level (逐字) lyrics silently displayed as line-level (逐行)

## Report

Founder, radio: Teresa Teng "The Way We Were" — word-level lyrics degrade to
line-level on screen. Same symptom earlier on Michael Jackson "Off the Wall".
`/tmp/nanopod_debug.log` (00:49:22–00:49:23) shows the pipeline behaving
correctly:

```
[NetEase] 🎯 YRC word-level: 16 lines, 16 synced … 🏆 Final selection: NetEase (score=76.7) … 📋 Applied: … 17L, unsynced=false
[Translation] 🧩 piece-translation tiers for 'The Way We Were' (origin=human): lines_split=9 tier1_clauseAligned=2 tier2_humanSplit=16 …
[Translation] 🈶 translation source resolved … language=en
```

The task brief noted a prior agent had already found and fixed a real but
unrelated bug in this area (`research/diagnosis-2026-09-23-off-the-wall-word-level.md`
— `TimeoutState.resume` cancelling the worker before `persistTrustedForegroundLyrics`
ran, breaking disk-cache persistence of fast word-level results). That fix is
already merged (main, prior to this task's `git merge --ff-only main`) and
does not explain the founder's on-screen symptom by itself — it only explains
why a song might have to re-fetch on the next play, not why a fetch that DID
apply word-level data (as this log confirms) would render as line-level.

## Investigation

Traced every `LyricLine(` construction that could run between "pipeline
applies word-level data" and "renderer draws the row" (per the task's
hypothesis 1): `LyricsView.makeDisplayLyricLines`'s `hasSyllableSync` branch
(`LyricsView.swift:2170-2229`), `LyricsParser.mergeLyricsWithTranslation` /
`mergeOneLineDelayedTranslationsIfSupported` (`LyricsParser.swift:1359-1437`),
`LyricsService.mergingTranslations`/`applyLateTranslationWriteback`
(`LyricsService.swift:1394-1466`), and the Traditional-Chinese conversion
pass in `LyricsFetcher.swift:1792-1805`. **All of these correctly propagate
`words:`** — every one either forwards `line.words`/`group` verbatim or
mutates only the `translation` field of an existing value. This rules out
hypothesis 1 as literally stated (a rebuild that drops `words`).

The actual mechanism is the INVERSE: a rebuild that should run, silently
doesn't.

## Mechanism (file:line)

`LyricsView.swift`'s `refreshDisplayLineCache()` (was line ~2438, now
~2480) is the sole place `cachedDisplayLyrics`/`cachedLayerRows` (what the
native renderer actually reads) get rebuilt from `lyricsService.lyrics`. It
opens with a dedup guard:

```swift
let inputFingerprint = displayLineInputFingerprint()
guard forceRebuild || inputFingerprint != lastCommittedRowsFingerprint else { return }
```

`displayLineInputFingerprint()` (was lines 2393-2406) hashed:

```swift
hasher.combine(Self.layerRowsTrackKey(for: musicController))
hasher.combine(lyricsService.showTranslation)
hasher.combine(lyricsService.firstRealLyricIndex)
hasher.combine(lyricsService.interludeAfterIndex)
hasher.combine(lyrics.count)
for line in lyrics {
    hasher.combine(line.text)
    hasher.combine(line.translation)
}
```

— **`line.words` / `hasSyllableSync` was never part of the hash.** The
comment above it even states the (correct, still-preserved) intent: "hash
the content ... never the line identity" — but the "content" hashed was
incomplete.

Separately, `LyricsService.applyFetchedLyricsIfCurrent` (`LyricsService.swift:1922-1955`)
implements an intentional, tested feature: a line-level/unsynced result on
screen MUST hot-switch to a later word-level result for the same song
(`upgradedLineToWord: !displayedHadWordLevel && incomingHasWordLevel`,
guarded by `Self.shouldReplaceDisplayedLyrics`'s P1 no-demotion rule). This
is exercised by `LyricsWordLevelPriorityTests` — but only at the
`LyricsService.lyrics` level, never through `LyricsView`'s display-cache
layer, so that suite could not have caught this bug.

When two different providers transcribe the SAME real lyrics (the common
case — a plain line-level fallback and a later word-level source usually
agree on the actual words, just not on per-word timing), the hot-switch
changes `lyricsService.lyrics` with `text`/`translation` UNCHANGED and ONLY
`words` populated. `LyricLine.id` is a fresh `UUID()` on every construction
(confirmed in `LyricModels.swift:63`, `Equatable` is synthesized and
includes `id`), so SwiftUI's `.onChange(of: lyricsService.lyrics)`
(`LyricsView.swift:785`) DOES fire and calls `refreshDisplayLineCache()` —
but the fingerprint computed inside is IDENTICAL to the one already
committed (same `text`/`translation`, `words` not hashed), so the `guard`
returns immediately. `cachedDisplayLyrics`/`cachedLayerRows` stay frozen at
the earlier line-level split forever (or until some UNRELATED input changes
the fingerprint, e.g. a translation edit or a column-width resize) — the
native renderer keeps drawing a whole-line sweep even though
`lyricsService.lyrics` (and the debug log) show the word-level upgrade
landed.

This is a generic bug in the cache-invalidation gate, not specific to this
song, this source, or CJK/English — it affects any line-level→word-level
(or word-count-only) hot-switch whose text happens to match the previously
displayed text, which is the ordinary case for real songs.

## Repro test (red → green)

`Tests/MusicMiniPlayerTests/LyricsDisplayLineFingerprintTests.swift`:
`test_fingerprintChangesWhenWordLevelSyncAppears_identicalTextAndTranslation`
— builds two `[LyricLine]` arrays with byte-identical `text`/`translation`,
one with `words: []` and one with real `words`, and calls the (now
non-private, directly testable) `LyricsView.displayLineInputFingerprint(...)`
on each. Confirmed RED against the pre-fix hash (temporarily removed
`hasher.combine(line.words.count)`, reran, `XCTAssertNotEqual` failed with
both fingerprints identical), GREEN after restoring the fix. Six more tests
in the same file pin: word-count-only changes (sync stays true) also change
the fingerprint; content-identical-but-distinct-UUID arrays still fingerprint
IDENTICAL (preserves the original "never hash line identity" intent, so a
genuine no-op still dedups); the pre-existing non-lyrics inputs
(track/showTranslation/firstRealLyricIndex/interludeAfterIndex) still
participate; a DEBUG-only defensive invariant
(`LyricsView.wordLevelDowngradeViolations`) that would catch a FUTURE bug of
the literally-hypothesized kind (a split path that drops `words`), tested
both on the clean path (no violations) and an injected violation; and an
end-to-end check that a word-level `LyricLine` with words intact actually
produces non-empty `wordRuns` from the real `NativeLyricsTextRenderPlan`
(closing the loop to the on-screen symptom).

## Fix

1. `LyricsView.displayLineInputFingerprint(trackKey:showTranslation:firstRealLyricIndex:interludeAfterIndex:lyrics:)`
   extracted to a `static func` (was a private instance method inlining the
   same logic) so it is directly unit-testable, and the per-line hash now
   includes `line.words.count` alongside `text`/`translation`. `words.count`
   (not just the `hasSyllableSync` boolean) also catches a backfill that
   changes word content without flipping the sync boolean.
2. `LyricsView.wordLevelDowngradeViolations(sourceLines:displayLines:)` /
   `logWordLevelDowngradeInvariantViolations(...)` (DEBUG-only): after every
   `refreshDisplayLineCache()` rebuild, checks that no display row built
   from a word-level source line ended up without words, and logs via
   `DebugLogger` if it ever does. This is a defense-in-depth invariant for
   the literal hypothesis 1 mechanism (a split/rewrite that drops `words`),
   which this investigation found NOT to be the actual bug today, but which
   a future edit to `makeDisplayLyricLines` or a translation-writeback path
   could reintroduce.

Both changes are confined to `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`
— no renderer files touched (`NativeLyricsTextRenderPlan.swift`,
`NativeLyricsRowView.swift`, etc. were read for the investigation, confirmed
correct, and left unmodified).

## Tests run (all serial, DEVELOPER_DIR=Xcode, no network)

- `LyricsDisplayLineFingerprintTests` (new) — 7/7 pass
- `LyricsLateTranslationInsertTests` — 6/6 pass
- `TranslationWritebackTests` — 4/4 pass
- `LyricPieceTranslationTests` — 26/26 pass
- `LongLineEvalTests` — 8/8 pass
- `LyricsWordLevelPriorityTests` — 8/8 pass
- `LyricsParserTests` — 57/57 pass
- `LyricsViewTranslationRetryWiringTests`, `RapidSwitchTests` (source-scan /
  wiring tests that also touch `LyricsView.swift`) — both fully green

No `LyricsVerifier` network runs needed — this is a pure display-cache logic
bug, fully reproducible and pinned without network access. No test in this
session touched `~/Library/Application Support/nanoPod/`; every `swift test`
invocation logged `caches isolated at /var/folders/.../nanoPod-xctest-<pid>
(scope testRun)`.
