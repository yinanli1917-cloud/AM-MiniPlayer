# Historical UX and workload audit — 2026-05-30

## Verdict

The previous successful lyrics UX was not a generic smooth-scroll trick. It was
a layered contract:

- manual Y-axis lyric layout with dynamic row heights and hot height caches;
- manual-scroll ownership that freezes the display index instead of fighting the
  user;
- AMLL-style top-to-bottom row target wave, with natural playback kept separate
  from seek/tap/manual-scroll direct snap;
- row visual state preserved independently from wave position: blur, scale,
  opacity, interlude fade, and hover/tap affordances;
- syllable/word-level text sweep that keeps static layout stable while animating
  masks, float, glow, and translation sweep;
- resolver identity gates that keep the renderer benchmark on the same lyric
  source, timing granularity, and content.

The current native rewrite must rebuild that contract natively. A wrapper that
still hosts `LyricLineView` rows is not a rebuild and already failed.

## Git history evidence

| Date | Commit | Evidence |
|------|--------|----------|
| 2025-12-20 | `121e7c56` / `788bc288` | Lyrics moved toward manual Y-axis/dynamic layout after scroll spacing issues. POSTM-004 records fixed-height simplification as the root cause of broken scroll and tap animations. |
| 2025-12-22 | `f6d96dde` | Introduced AMLL wave scroll and manual-scroll lock: independent per-line target indices, top-to-bottom propagation, locked target snapshot during manual scroll. |
| 2026-03-22 | `8d37d46d` | Performance pass rendered fewer rows, merged some animations, kept manual-scroll freeze, but also added shortcuts that later had to be reverted. |
| 2026-03-22 | `7dd8474e` | Restored smooth feel by making wave control position only and letting scale/blur/opacity visually sync separately. This is a core lesson: CPU reductions that collapse visual semantics are regressions. |
| 2026-03-26 to 2026-04-17 | `94e4936e`, `ff441308`, `19a65049` | Word-level AMLL translation matured: stable layout, single-text rendering, AMLL fade width, visual-line wavefront, exact ease-out float curve, CJK-specific behavior. |
| 2026-05-03 to 2026-05-18 | `b771c86a`, `55a2cf40`, `6b88e47d`, `dc6894b7`, `388daa54`, `eb6750d1` | Successful CPU work was mostly invalidation control and stable render payload caching, not UX simplification. |
| 2026-05-21 | `8917b1fd` | Added line-motion diagnostics so drift/backlog/translation gaps can be verified without screenshots. |
| 2026-05-26 to 2026-05-27 | `fa4c259f`, `c3658c14`, `3ec0c760` | Wave lag and highlight sync were revisited: natural playback must keep one top-down wave, wordFillTime cadence must not be weakened, and diagnostics must share the corrected playback clock. |

## Prior failure patterns

- Fixed-height or simplified layout broke dynamic lyric/translation spacing.
- ScrollView or scroll-to style motion did not provide the AMLL-controlled wave.
- Wave target shortcuts made diagnostics quieter while changing the visible
  motion shape.
- Combining or removing the independent blur/scale/opacity springs damaged the
  Apple Music-like feel.
- Word-level render attempts that changed text layout, per-word clipping, or
  CJK spacing broke sweep continuity.
- Resolver fallbacks have repeatedly changed selected lyric identity. POSTM-008
  shows source fan-out and word-level source coverage must be modeled explicitly.
- The 2026-05-30 `NativeLyricsSurface` slice failed because AppKit owned row
  Y transforms while SwiftUI still owned row text/effects, and row hover/tap,
  manual-scroll ownership, blur parity, sweep, and interlude behavior were not
  native.

## Workload contamination found

The previous perf harness had a hole: fixtures with `expect_lyrics: any` skipped
`LyricsVerifier`, so process CPU could be sampled without proving that baseline
and candidate selected the same lyrics. That makes a fake CPU win possible when
the resolver switches from word/syllable lyrics to lighter line-level lyrics, or
changes source/line count.

The mandatory workload locks measured on this machine are:

| Fixture | Track | Source | Syllable | Lines | First real line SHA-256 |
|---------|-------|--------|----------|-------|--------------------------|
| `line-winter-trip` | `冬天一個遊` / Gordon Flanders / 256s | NetEase | yes | 67 | `15ce6b4d94c2f2b4f016cbd746a807825b26fa90608465af1dbb623ad645fee9` |
| `word-seek-fun` | `尋開心` / Bondy Chiu / 265s | NetEase | yes | 44 | `8b9a2fd7d0bc2de6d45adeb5758c5f11492b018c1900b67a6afe4002fbda4f3b` |
| `translated-word` | `Stardust Night` / JADOES / 234s | NetEase | yes | 25 | `43180988879b1854dfbdc28c2eac68f223c2b4210bda87cd87fed3897fd772e8` |

Any CPU, FPS, RSS, drift, or scroll-tap-jump result is invalid if those fields
change between baseline and candidate. The harness now fails before sampling
when the locked fields do not match.

## Rebuild implications

1. The next native slice starts with a native row/text model, not another
   `NSHostingView<LyricLineView>` bridge.
2. Native scroll state must own manual-scroll start/end, frozen display index,
   hover identity, tap-to-jump, and recovery as one state machine.
3. Native layout must produce stable measured rows and hit regions, with source
   indices traceable back to original `LyricLine` values.
4. Native text rendering must build immutable glyph/layout/sweep plans on
   semantic changes, then animate layer/texture/mask state on the display clock.
5. CPU reductions are only accepted after workload integrity, FPS cadence,
   scroll-tap-jump, drift, hover/tap, blur, sweep, backend latency, and idle
   page gates all pass together.
