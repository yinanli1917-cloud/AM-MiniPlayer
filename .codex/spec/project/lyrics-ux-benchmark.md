# Lyrics UX Benchmark (LUXB)

Last updated: 2026-05-28

## Reference release (must be surpassed)

| Field | Value |
|-------|--------|
| Tag | `v2.8` — nanoPod 0.28 beta |
| Asset | `nanoPod-v0.28-beta.zip` |
| Zip SHA-256 | `3eea02ae553b927c7c88aad956df8a06f1f2a82a61eafa1402a143126b77c73a` |
| Git | `b24b182a89315526f83692d3bd09e1ab848db55c` |
| Stack | Pre-rebuild SwiftUI wave (no `LyricsScrollEngine`) |

Candidate builds must **beat** recorded v2.8 baselines on every smoothness proxy, not merely match.

## Owner-pinned fixtures

| Key | Title | Artist | Duration | Mode |
|-----|-------|--------|----------|------|
| `line-winter-trip` | 冬天一個遊 | Gordon Flanders | 256s | syllable |
| `word-seek-fun` | 尋開心 | Bondy Chiu | 265s | syllable |

Default harness list: `line-winter-trip,word-seek-fun,translated-word`

## Workload Integrity Gate

CPU, RSS, frame, and drift comparisons are invalid unless baseline and
candidate select the same lyric workload. The harness must fail before sampling
when any locked fixture changes:

| Fixture | Source | Syllable | Lines | First real line SHA-256 |
|---------|--------|----------|-------|--------------------------|
| `line-winter-trip` | NetEase | yes | 67 | `15ce6b4d94c2f2b4f016cbd746a807825b26fa90608465af1dbb623ad645fee9` |
| `word-seek-fun` | NetEase | yes | 44 | `8b9a2fd7d0bc2de6d45adeb5758c5f11492b018c1900b67a6afe4002fbda4f3b` |
| `translated-word` | NetEase | yes | 25 | `43180988879b1854dfbdc28c2eac68f223c2b4210bda87cd87fed3897fd772e8` |

Do not accept a CPU reduction if the resolver switched from syllable/word-level
lyrics to line-level lyrics, changed source, changed line count, or changed the
first real lyric identity. That is a workload change, not a renderer
improvement.

## Smoothness proxies (no literal FPS gate)

| Proxy | Source | Beat v2.8 |
|-------|--------|-------------|
| Presentation hitch | `lyrics.presentationFrame.delta.ms` max/p95 | Candidate lower |
| Line motion | `lyrics_line_motion_samples.csv` | Candidate max/p95 ≤ baseline |
| Lingering backlog | Evaluator: 4+ nearby rows stale target ≥1s after stable display | Zero on candidate |
| Layout clip | `lineBottomClipY` / `activeBottomClipY` on active row | ≤ baseline |
| CPU | `perf_harness` 16s lyrics avg | ≤ baseline |
| Soak | `soak_harness` stallCount, RSS slope, tail incidents | Strictly better |

## Contract (always)

- AMLL wave: 0.08s stagger, 3-row lead-in, radius 14, top-to-bottom order
- See [lyrics-renderer-performance.md](lyrics-renderer-performance.md) for protected UX list

## Dual-app live monitor (v2.8 vs candidate simultaneously)

```bash
python3 scripts/luxb_dual_monitor.py --fixture word-seek-fun --duration 60 --warmup 15
python3 scripts/luxb_dual_monitor.py --fixture line-winter-trip --duration 60 --warmup 15
```

Clones v2.8 to `tmp/reference-app/nanoPod-v28-reference.app` with bundle id `com.yinanli.nanoPod.v28reference` so both processes can run. Fails if either app crashes or candidate motion metrics regress vs reference (when live CSV exists).

## Commands

```bash
# Record v2.8 baselines once
python3 scripts/lyrics_ux_benchmark.py --record-baseline --reference-app tmp/reference-app/nanoPod.app

# Candidate vs reference
./build_app.sh
python3 scripts/lyrics_ux_benchmark.py \
  --reference-app tmp/reference-app/nanoPod.app \
  --candidate nanoPod.app \
  --require-beat-reference

# Long session
python3 scripts/soak_harness.py --duration 1800 \
  --fixtures line-winter-trip,word-seek-fun \
  --compare-baseline tmp/benchmark/v2.8-baseline
```

## Stopping rule

Loop continues until: cold proxies beat v2.8 on all mandatory fixtures; 30–60 min soak tail cleaner than v2.8; owner sign-off on `冬天一个游` + `尋開心`.

Parity with v2.8 is **not** sufficient.
