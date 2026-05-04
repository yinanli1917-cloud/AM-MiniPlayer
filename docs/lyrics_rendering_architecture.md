# Lyrics Rendering Architecture

Last updated: 2026-05-04

## Purpose

This document records how the current lyrics rendering path works before any
protected renderer refactor. It exists so performance work can target specific
invalidation points without changing lyrics layout, animation, spacing, wave,
translation, interlude, or scroll behavior by accident.

## Ownership Map

| Layer | File | Responsibility | Performance sensitivity |
|---|---|---|---|
| Page container | `Sources/MusicMiniPlayerCore/UI/LyricsView.swift` | Page visibility, background, controls, translation trigger, scroll gestures, current-line wave offsets, height cache, visible-line culling. | Recomputes offsets for every lyric row when line index, manual scroll, translation height, or measured heights change. |
| Line view | `Sources/MusicMiniPlayerCore/UI/LyricLineView.swift` | Per-line opacity, scale, blur, hover/tap, translation display, interlude blend, word-level vs plain-line branch. | Must keep stable identity across current/non-current states to avoid layout jumps. |
| Word-level text builder | `SyllableSyncedLine` in `LyricLineView.swift` | Builds one concatenated `Text` with `WordTimingAttribute` on each word. | Static word/timing attributes are immutable for a line, but `body` can be re-entered during active-line animation. |
| Animated renderer | `LyricsTextRenderer` in `LyricLineView.swift` | Draws dim base, bright sweep, emphasis lift/glow, CJK shared wavefront, and post-line fade. | Runs on animation frames for the active syllable line; stack samples point at TextRenderer/display-list/glyph work. |
| Translation sweep | `TranslationSweepText` in `LyricLineView.swift` | Mirrors word-level sweep over translated text with the original `TextRenderer` dim-base + bright-sweep path. | Animated only when translation is visible on the active syllable line; protected because visual simplifications are noticeable. |

## Current Rendering Flow

1. `MusicController` updates `LyricsService.currentLineIndex` outside SwiftUI's
   high-frequency `currentTime` publishing path.
2. `LyricsView.scrollableLyricsContent` chooses a display index:
   - live current line during normal playback;
   - frozen index during manual scroll.
3. `LyricsView` computes accumulated line heights and per-line offsets around
   the AMLL-style anchor position.
4. Every rendered row calls `lyricLineContent`.
5. Word-level rows enter `SyllableSyncedLine`.
6. Only the current word-level row uses `TimelineView(.animation)` with
   `musicController.wordFillTime`.
7. `LyricsTextRenderer` receives `currentTime` through `animatableData` and draws
   the sweep without changing measured layout.

## Existing Protections

- `currentTime` is not `@Published` on `MusicController`; high-frequency updates
  are isolated from broad SwiftUI invalidation.
- Word-level current and non-current lines use the same `SyllableSyncedLine`
  branch on macOS 15+ to prevent layout jumps.
- `LyricsTextRenderer.displayPadding` must stay zero; non-zero padding changes
  wrapped line height and creates translation gaps.
- Hidden rows are opacity-gated only after line heights are known; previous
  render-list culling attempts were rejected.
- Manual scrolling freezes the active display index to preserve scroll continuity.

## Current Hot Evidence

- `tmp/perf/sample-20260503-203254.txt` points at `LyricsTextRenderer`,
  `TextRendererBox`, `ResolvedStyledText`, and glyph/display-list rendering.
- `tmp/perf/nanopod-lyrics-swiftui-20260503-2043.trace` showed
  `AnimatableAttribute<LyricsTextRenderer>` and
  `StaticBody<ViewBodyAccessor<SyllableSyncedLine>>` feeding
  `_TextRendererViewModifier<LyricsTextRenderer>` 1537 times.
- `tmp/perf/sample-20260504-000535.txt` on deterministic local word-level
  `Strangers By Nature` showed `TranslationSweepRenderer` as a major user-code
  text rendering path when source translations are visible.
- Removing `LyricsTextRenderer.animatableData` regressed CPU.
- Caching `Text` in `@State` inside `SyllableSyncedLine` regressed rapid switching
  and must not be repeated as-is.
- Materializing `Array(layout.flattenedRuns)` once inside `LyricsTextRenderer.draw`
  regressed p95/max under the forced lyrics-page harness and must not be repeated
  as a standalone renderer micro-optimization.
- Replacing the current translated line's `TextRenderer` sweep with a masked
  `Text` fast path improved deterministic settled word-level CPU on
  `Strangers By Nature` from avg 48.31%, p95 53.4% to avg 37.61%, p95 40.2%,
  and `Escape` by EPO measured avg 31.73%, p95 39.1%, max 41.4. The user
  rejected the resulting translation animation on 2026-05-04, so this path is
  not an acceptable final optimization.

## Next Approved Hypothesis Candidate

The next protected renderer experiment should not change timing cadence,
spacing, masking math, translation layout, translation sweep character, or the
word renderer's visual output.

Candidate: isolate immutable per-line word/timing preparation from frame-time
animation by introducing a small value model for precomputed word attributes.
The renderer would still receive the same `Text` attributes and the same
`currentTime`; the experiment is only worth keeping if it reduces
`SyllableSyncedLine` / `_TextRendererViewModifier` invalidation without changing
pixels.

Required evidence before keeping it:

- Same-track before/after lyrics-page screenshot or recording.
- `swift build`.
- `swift test`.
- Forced lyrics-page settled word-level run.
- Forced lyrics-page rapid-switch run with `--page lyrics`.
- Revert if p95/max regress or visual parity is not obvious.

## Non-Goals

- Do not replace the word-level renderer with a low-cost approximation.
- Do not replace the translation sweep with the rejected masked `Text` shortcut.
- Do not lower animation cadence as a shortcut.
- Do not remove blur, wave, translation sweep, interlude, or line spacing.
- Do not use album-page screenshots as lyrics-page evidence.
