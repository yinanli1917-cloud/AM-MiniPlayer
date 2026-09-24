# 2026-09-24 (follow-up) — U+00A0 NO-BREAK SPACE clears word-level sync on split display pieces

## Report

Coordinator follow-up to the same-day founder report ("The Way We Were" /
"Off the Wall" word-level lyrics degrading to line-level on screen). The
fingerprint fix landed earlier the same session
(`research/diagnosis-2026-09-24-word-level-display-freeze.md`) is real but
does not explain this specific case: the founder's debug log shows exactly
ONE apply for "The Way We Were" (NetEase word-level, 00:49:23), no earlier
line-level apply, so no line→word hot-switch happened.

Coordinator read the real data from the founder's own disk cache
(`lyrics_cache.v31.json`, NetEase entry, album 愛之世界, 207s): every word
carries a trailing **U+00A0 NO-BREAK SPACE** instead of a plain space, e.g.
for the line "Memories light the corners of my mind":

```
words = ["Memories\u{00A0}", "light\u{00A0}", "the\u{00A0}", "corners\u{00A0}", "of\u{00A0}", "my\u{00A0}", "mind"]
```

Other lines from the same cache entry: "Misty water color memories", "Of
the way we were", "Scattered pictures of the smiles we left behind",
"Smiles we gave to one another", "Fore the way we were" (verbatim, incl.
the apparent "Fore"/"For" garble). An earlier eval
(`research/long-line-eval-2026-09-22.md`, ground-truth gt-005) also hit NBSP
in NetEase data (there, a U+00A0 mid-line, fixed as an orphan-merge edge
case, unrelated to this mechanism).

## Investigation

Built the exact fixture (this line, real word timings, NBSP separators)
and drove it through the real display-construction and rendering path
directly (not mocked): `LyricLine`/`LyricWord` construction →
`LyricDisplaySegmenter.realWrapWordPieces` (Plan A's word-level split) →
`NativeLyricsStaticTextRenderPlan`/`NativeLyricsTextRenderPlan` →
`NativeLyricsTextSweepLayout.makePlan` (the real `NSLayoutManager`-backed
glyph geometry the row draws from). Compared against an identical fixture
with plain ASCII spaces instead of NBSP.

## Mechanism (file:line)

Two independent effects follow from the SAME non-standard character, but
only one is this bug's proximate cause:

1. **Not a break opportunity.** Unicode defines U+00A0 to NOT be a valid
   line-break point, so `NSLayoutManager`'s `.byWordWrapping` cannot wrap a
   line at an NBSP boundary. Confirmed but NOT the direct cause of "looks
   line-level" -- `NativeLyricsTextSweepLayout.makePlan` still falls back to
   character-level wrap and still locates correct per-glyph geometry when
   given the RAW string; this alone would show as odd wrap points, not a
   whole-line sweep.

2. **The actual cause: `LyricLine.init`'s words/text consistency invariant**
   (`Sources/MusicMiniPlayerCore/Models/LyricModels.swift`, was lines
   90-98):

   ```swift
   let wordsText = words.map(\.word).joined().replacingOccurrences(of: " ", with: "")
   let normalizedText = text.replacingOccurrences(of: " ", with: "")
   self.words = normalizedText.hasPrefix(wordsText) || wordsText.hasPrefix(normalizedText) ? words : []
   ```

   only strips the plain ASCII space (U+0020) before comparing -- never
   U+00A0. `LyricsView.makeDisplayLyricLines`'s word-level split branch
   (`LyricsView.swift:2170-2229`, Plan A, 2026-09-22) builds each split
   display piece as:

   ```swift
   let segmentLine = LyricLine(
       text: groupTexts[segmentIndex],   // LyricDisplaySegmenter.displayText(forWords:) -- ALWAYS plain space
       ...
       words: group,                      // RAW LyricWord array -- untouched, still has NBSP
       ...
   )
   ```

   `LyricDisplaySegmenter.displayText(forWords:)` (via `displayTokens`)
   already normalizes a word's trailing whitespace to a plain space when it
   reconstructs the joined display string (its own `Character.isWhitespace`
   check already treats U+00A0 as a boundary) -- but that normalization
   only lives in the TEXT it returns, not in the `words` array the caller
   still holds. So `text` uses plain spaces, `words` still has NBSP: the
   invariant's prefix check fails on the very first separator character,
   and `self.words` is silently cleared. `line.hasSyllableSync` flips to
   `false` for that split piece with no error, no log line -- and
   `NativeLyricsRowView`'s `line.hasSyllableSync && !plan.wordRuns.isEmpty`
   gate (used throughout, e.g. lines 835/1600/1893/1909/3037) falls through
   to whole-line/line-level rendering for that row.

   This hits every real-world word-level line long enough to need more
   than one display piece -- the common case at the app's narrow default
   width, not an edge case (per `research/long-line-eval-2026-09-22.md`,
   most real lyric lines DO need splitting at 180-250pt). It only affects
   lines that GO THROUGH the split reconstruction; an unsplit word-level
   line uses the original `LyricLine` object directly
   (`LyricsView.swift:2172-2180`) and is unaffected -- consistent with the
   founder seeing SOME word-level rendering per song (short lines) and some
   degraded (long lines needing a split), which reads as "degrades to
   line-level" rather than "never word-level at all".

## Repro (red → green)

`Tests/MusicMiniPlayerTests/LyricsWordWhitespaceNormalizationTests.swift`,
14 tests. The end-to-end fixture tests build the founder's exact reported
lines (all six) with realistic NBSP-separated word timings, mirror
`LyricsView.makeDisplayLyricLines`'s word-level split branch exactly
(`realWrapWordPieces` → one `LyricLine` per group, `words: group` verbatim,
`text` from `displayText(forWords:)` -- same construction, same two call
sites), and assert at BOTH 250pt and 180pt widths that:

- every split piece keeps `hasSyllableSync == true` and its full word count
  (`test_fixture_allSplitPieces_keepWordLevelSync_at250And180`)
- the render plan produces one word run per word and the renderer's own
  sweep-path gate (`hasSyllableSync && !wordRuns.isEmpty`) passes for every
  piece (`test_fixture_renderPlan_producesWordRunsAndSweepGate_forEveryPiece`)
- the real `NativeLyricsTextSweepLayout.makePlan` (actual `NSLayoutManager`
  glyph geometry) locates every word as its own visual run with real
  glyphs, none merged or dropped
  (`test_fixture_sweepLayout_locatesEveryWordAsARun_forRepresentativeLine`)

Confirmed RED against the pre-fix code (v1, before the scope correction
below): temporarily reverted `LyricWord.init`/`LyricLine.init` to plain
assignment (no whitespace normalization) and reran -- 8 of 9 tests then in
the file failed, reproducing the founder's symptom across every fixture
line at both widths (e.g. `width=250.0 line=0 piece=0 ('Memories light
the') lost word-level sync`, word counts collapsing to 0 across every
split). Restored the fix, reran green.

## Fix (v1)

`Sources/MusicMiniPlayerCore/Models/LyricModels.swift`: `LyricWord.init`
and `LyricLine.init` normalized every Unicode whitespace character other
than the plain ASCII space (`Character.isWhitespace`) to `" "` at
construction.

## Fix (v2, coordinator scope correction, same day)

v1 was too broad: `Character.isWhitespace` also matches U+3000 IDEOGRAPHIC
SPACE, which is a DELIBERATE full-width clause separator in CJK
lyrics/translations (founder-tuned spacing, not a data artifact) -- v1
would have silently rewritten it, and would have turned a literal tab or
newline inside a word into a space too.

Storage-level normalization (`LyricWord.normalizingNonBreakingSpaces`) is
now narrowed to exactly two things: (1) map the non-breaking space FAMILY
that actually causes the U+00A0 wrap failure -- U+00A0 NO-BREAK SPACE,
U+202F NARROW NO-BREAK SPACE, U+2007 FIGURE SPACE -- to a plain space; (2)
DROP (not replace) the zero-width formatting characters U+200B ZERO WIDTH
SPACE, U+2060 WORD JOINER, U+FEFF ZERO WIDTH NO-BREAK SPACE (BOM), since
they render as nothing and folding them to a visible space would be wrong.
U+3000, tabs, newlines, and every other whitespace variant are left
completely untouched, in both `LyricWord.word` and `LyricLine.text`.

Because that narrower set can still leave OTHER whitespace mismatches
between `words` and `text` unresolved (e.g. a caller's `text` uses U+3000
where the underlying `words` concatenation has a plain space, or none, at
the same position), the words/text consistency invariant in `LyricLine.init`
no longer compares the raw stored strings at all. It now compares through
a NEW `LyricWord.whitespaceStrippedComparisonKey(_:)` helper, which strips
EVERY `Character.isWhitespace` character (not just the narrowed
non-breaking family) for the COMPARISON ONLY -- the stored `text`/`words`
are never touched by it. This is the actual belt-and-suspenders fix for
the words-silently-cleared class of bug: any future whitespace variant
that shows up in a lyric source, known or not, can no longer trip this
invariant, while the narrower storage-level normalization only handles the
specific U+00A0 wrap-and-clear mechanism and keeps rendered text free of
invisible zero-width characters.

Confirmed RED for the v2-specific tests by two separate temporary reverts:
(a) storage normalization reverted to v1's blanket
`Character.isWhitespace` substitution -- `test_ideographicAndOtherGeneral
SpacesAreNeverTouched`, `test_zeroWidthFormattingCharactersAreDropped`,
and `test_tabsAndNewlinesAreNeverTouched` failed (U+3000/EM SPACE got
rewritten to plain space, zero-width characters got rewritten to a VISIBLE
space instead of dropped, tabs/newlines got rewritten to space); (b)
comparison invariant reverted to the pre-v2 raw-string
`.replacingOccurrences(of: " ", with: "")` compare (with storage
normalization restored) -- `test_wordsSurviveConsistencyCheck_whenOnly
OtherWhitespaceDiffers` and `..._whenOnlyTabDiffers` failed
(`hasSyllableSync` false, `words` cleared). Both restored, full file green
(14/14).

This is the single choke point every `LyricWord`/`LyricLine` in the app is
built through -- every parser (YRC/TTML/LRC), `LyricsWordRepair`,
Traditional-Chinese conversion (`LyricsFetcher.swift`), and
`LyricsDiskCache.lyricLines(from:)` on every disk-cache read. Fixing it here
generalizes to every current and future lyric source and every code path
that reconstructs a `LyricLine` from words, instead of special-casing
NetEase's YRC parser, and it self-heals stale disk-cache entries written
before this fix (no schema bump needed) since the disk-cache decoder
reconstructs `LyricWord` through this same initializer on every read.

Renderer files (`NativeLyricsRowView.swift`, `NativeLyricsTextSweepLayout.swift`,
`NativeLyricsActiveLineDrawLayer.swift`) were read in full during this
investigation and confirmed to correctly locate per-word glyph geometry
from whatever string they are given (they operate on real `NSLayoutManager`
glyph/character ranges, not assumed word boundaries) -- the root cause was
entirely in the data layer (`LyricModels.swift`), not the renderer, so no
renderer file was touched.

## Tests run (all serial, DEVELOPER_DIR=Xcode, no network)

- `LyricsWordWhitespaceNormalizationTests` (new/updated for v2) -- 14/14 pass
- `LyricsParserTests` -- 57/57 pass
- `LongLineEvalTests` -- 8/8 pass
- `LyricsWordLevelPriorityTests` -- 8/8 pass
- `LyricsDisplayLineFingerprintTests` (this session's earlier fix) -- 7/7 pass
- `LyricsScorerTests` -- 37/37 pass

No `LyricsVerifier` network runs needed -- pure data/layout logic,
reproducible without network. No test in this session touched
`~/Library/Application Support/nanoPod/`.
