# Lyrics Visual Regression Harness

Last updated: 2026-05-18

## Purpose

Protected lyrics renderer work must prove visual parity on the lyrics page before
it is kept. Album-page screenshots are not enough because the protected behavior
lives in `LyricsView`, `LyricLineView`, word-level rendering, translation sweep,
interlude dots, and scroll anchoring.

Use `scripts/lyrics_visual_harness.py` to capture local screenshots or short
recordings under `tmp/visual/`. Keep generated media out of normal commits
unless the release or review task explicitly asks for it.

The rebuilt app also supports direct page routing:

```bash
open 'nanopod://page/lyrics'
open 'nanopod://page/album'
open 'nanopod://page/playlist'
```

Use this route to jump straight to the lyrics page after launching the latest
local `nanoPod.app`.

## Fixture Set

| Fixture | Track | Expected workload | What it protects |
|---|---|---|---|
| `translated-word` | `Koibitotachi no Chiheisen` - Momoko Kikuchi, 229s | syllable/word-level + translation | deterministic translated word sweep, active-word timing, spacing, blur, translation layout |
| `word-english-dense` | `Shape of You` - Ed Sheeran, 234s | line-synced | dense English fallback layout and active-line anchoring |
| `word-english-sparse` | `Bad Guy` - Billie Eilish, 194s | line-synced | sparser English fallback layout, blur, and active-line anchoring |
| `word-japanese` | `Namidanokatachino Earring` - Akina Nakamori, 276s | syllable/word-level + translation | Japanese word timing, CJK glyph metrics, translated line alignment |
| `word-level-alt` | `Stardust Night` - JADOES, 234s | syllable/word-level + translation | alternate translated word-level workload and Japanese catalog behavior |
| `line-english` | `Uptown Funk` - Mark Ronson, 270s | line-synced | English line-synced layout, active-line anchoring, translated line baseline |
| `line-cjk` | `女爵` - `杨乃文`, 252s | line-synced | CJK wrapping, font metrics, active/non-active emphasis |
| `line-breakup-truth` | `分手真相` - Alvin Kwok, 250s | line-synced | owner-provided Cantonese plain-line lag/drift regression gate |
| `interlude` | `Bohemian Rhapsody` - Queen, 355s | line-synced | long gaps, interlude/prelude dots, scroll continuity |

The harness validates the expected workload with `LyricsVerifier` before
capturing. If the selected provider changes and the workload no longer matches,
the fixture must be replaced or the expected workload must be updated with fresh
evidence.

Current fixture evidence:

- `translated-word` verified on 2026-05-18 as NetEase, 25 lines, syllable sync,
  and source translation.
- `word-japanese` verified on 2026-05-18 as NetEase, 29 lines, syllable sync,
  and source translation.
- `word-level-alt` verified on 2026-05-18 as NetEase, 25 lines, syllable sync,
  and source translation.
- `Shape of You`, `Bad Guy`, and `Bohemian Rhapsody` verified on 2026-05-18 as
  LRCLIB-Search line-synced results without source translation. They are kept as
  fallback layout fixtures, not word-level gates.
- `Uptown Funk` verified on 2026-05-18 as LRCLIB-Search line-synced lyrics.
- `女爵` verified on 2026-05-18 as NetEase line-synced lyrics.
- `分手真相` verified on 2026-05-30 as NetEase, 42 lines, no syllable sync,
  first real line `雾里的街灯`, SHA
  `c3925990fd25b5c0a4891ef23968b2acd3d7db1e4d71fbb9cfdfeefdd2231ae9`.

## Commands

List fixtures:

```bash
python3 scripts/lyrics_visual_harness.py --list-fixtures
```

Dry-run a capture without controlling Music.app:

```bash
python3 scripts/lyrics_visual_harness.py --fixture translated-word --mode screenshot --label baseline --dry-run
```

Capture a baseline screenshot:

```bash
python3 scripts/lyrics_visual_harness.py --fixture translated-word --mode screenshot --label baseline
```

If macOS blocks window-bounds access because the runner does not have
Accessibility permission, use the full-screen fallback:

```bash
python3 scripts/lyrics_visual_harness.py --fixture translated-word --mode screenshot --label baseline --allow-fullscreen-fallback
```

Screenshot captures are rejected when the resulting PNG is effectively blank.
This catches missing Screen Recording permission, a sleeping display, or a
locked/black desktop before the harness writes misleading visual evidence.

Capture a short after-change recording:

```bash
python3 scripts/lyrics_visual_harness.py --fixture translated-word --mode record --label after --record-duration 12
```

Run the deterministic lyrics-page performance gate:

```bash
python3 scripts/perf_harness.py \
  --page lyrics \
  --fixture translated-word \
  --expect-lyrics syllable \
  --expect-translation \
  --duration 16 \
  --warmup 8 \
  --interval 0.5 \
  --require-music-playing
```

Run the line-level lag/drift gate with scroll-then-visible-row-jump input:

```bash
python3 scripts/perf_harness.py \
  --page lyrics \
  --fixture line-breakup-truth \
  --expect-lyrics line \
  --duration 16 \
  --warmup 8 \
  --interval 0.5 \
  --interaction scroll-tap-jump \
  --require-music-playing
```

The performance harness reuses the fixture workload validation where possible,
routes the app through `nanopod://page/lyrics`, and writes CPU/RSS CSV plus JSON
summary files under `tmp/perf/`.

## Pass/Fail Checklist

A protected lyrics change passes the visual gate only when the before/after
evidence shows:

- lyrics page is captured, not the album page;
- the capture is nonblank and visibly includes the app surface;
- active line position, spacing, and wrapping are unchanged;
- active word or line highlight timing lands on the same words/lines;
- translation text appears in the same place with the same sweep/transition;
- blur, scale, opacity, wave, glow, and held-word behavior remain intact;
- interlude/prelude dots appear at the same gaps and do not steal layout space;
- manual scroll and automatic scroll anchoring remain continuous;
- rapid page/song switching does not leave stale lyrics, stale translation, or a
  broken loading/no-lyrics state.

If visual parity is not obvious, revert the protected renderer experiment before
continuing performance work.

## GEB Impact

Documentation level: L1/L2. This file defines a durable project verification
contract for protected lyrics UI changes and supports the renderer performance
spec.
