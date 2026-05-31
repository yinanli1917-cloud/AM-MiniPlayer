# Lyrics UX Benchmark (LUXB)

Last updated: 2026-05-31

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
| `line-breakup-truth` | 分手真相 | Alvin Kwok | 250s | line |
| `word-seek-fun` | 尋開心 | Bondy Chiu | 265s | syllable |

Default harness list: `line-winter-trip,line-breakup-truth,word-seek-fun,translated-word`

## Workload Integrity Gate

CPU, RSS, frame, and drift comparisons are invalid unless baseline and
candidate select the same lyric workload. The harness must fail before sampling
when any locked fixture changes:

| Fixture | Source | Syllable | Lines | First real line SHA-256 |
|---------|--------|----------|-------|--------------------------|
| `line-winter-trip` | NetEase | yes | 67 | `15ce6b4d94c2f2b4f016cbd746a807825b26fa90608465af1dbb623ad645fee9` |
| `line-breakup-truth` | NetEase | no | 42 | `c3925990fd25b5c0a4891ef23968b2acd3d7db1e4d71fbb9cfdfeefdd2231ae9` |
| `word-seek-fun` | NetEase | yes | 44 | `8b9a2fd7d0bc2de6d45adeb5758c5f11492b018c1900b67a6afe4002fbda4f3b` |
| `translated-word` | NetEase | yes | 25 | `43180988879b1854dfbdc28c2eac68f223c2b4210bda87cd87fed3897fd772e8` |

Do not accept a CPU reduction if the resolver switched between line-level and
syllable/word-level lyrics, changed source, changed line count, or changed the
first real lyric identity. That is a workload change, not a renderer
improvement. `line-breakup-truth` is intentionally line-level and protects the
dense plain-line lag/drift path; it must fail if the resolver upgrades it to
word/syllable lyrics or selects a lighter/different line workload.

## Smoothness proxies (no literal FPS gate)

| Proxy | Source | Beat v2.8 |
|-------|--------|-------------|
| Presentation hitch | `lyrics.presentationFrame.delta.ms` max/p95 | Candidate lower |
| Line motion | `lyrics_line_motion_samples.csv` | Candidate max/p95 ≤ baseline |
| Lingering backlog | Evaluator: 4+ nearby rows stale target ≥1s after stable display | Zero on candidate |
| Layout clip | `lineBottomClipY` / `activeBottomClipY` on active row | ≤ baseline |
| CPU | `perf_harness` 16s lyrics avg | ≤ baseline |
| Soak | `soak_harness` stallCount, RSS slope, tail incidents | Strictly better |

## Native UX Parity Gate

`lyrics.nativeRenderer.summary` is a code-based UX parity gate, not a visual
capture. Candidate CPU/FPS numbers are invalid if any protected UX metric has a
gap:

- word sweep must report active syllable samples, zero phase error over 0.02,
  zero per-run sweep coverage gaps, and wavefront error no higher than 0.5pt;
- translation sweep phase error must stay at or below 0.02 when translations
  are present;
- held non-CJK word emphasis must report per-character geometry samples with
  position error no higher than 0.5pt, scale/alpha/glow error inside their
  benchmark tolerances, and nonzero scale/lift/glow motion when expected;
- line layout must emit frame parity samples and keep main/translation height
  and text width errors within 1pt;
- scroll-tap fixtures must record real manual-scroll delta/offset, hover
  feedback, tap-to-line during manual-scroll ownership, and a tapped target
  different from the current lyric row.
- frame cadence must report the active display refresh expectation, effective
  FPS, p50/p95/p99/max frame delta, dropped frames over 1.5x and 2x refresh,
  longest frame stall, and tick jitter. CPU improvements are invalid if these
  metrics are achieved by reducing active lyric cadence.

## Final Native Rebuild Gate Snapshot

The 2026-05-31 signed native rebuild gate is:

```bash
python3 scripts/lyrics_ux_benchmark.py \
  --skip-build \
  --skip-unit-tests \
  --candidate nanoPod.app \
  --label cattext-progress-active \
  --output-dir tmp/benchmark \
  --min-cpu-reduction 0.50
```

Passing summary:
`tmp/benchmark/luxb-20260531-054612-cattext-progress-active/summary.json`

CPU reductions versus same-machine `origin/main` baseline:

| Fixture | Avg CPU | Avg reduction | p95 CPU | Max CPU |
|---------|---------|---------------|---------|---------|
| `line-winter-trip` | 13.352 | 64.25% | 26.88 | 28.3 |
| `line-breakup-truth` | 12.439 | 53.91% | 27.6 | 30.9 |
| `word-seek-fun` | 11.655 | 51.22% | 25.82 | 32.2 |
| `translated-word` | 12.915 | 53.82% | 26.66 | 27.5 |

The gate reported no motion, wave, text parity, frame cadence, or CPU failures.
Frame cadence stayed at the expected 60 FPS with zero dropped frames over 1.5x
or 2x refresh interval.

Passing idle summaries on the same signed candidate:

| Page | Fixture | Avg CPU | p95 CPU | Max CPU |
|------|---------|---------|---------|---------|
| album | `word-seek-fun` | 0.411 | 0.9 | 1.6 |
| playlist | `word-seek-fun` | 0.482 | 1.15 | 1.7 |

Passing 30-minute soak summary:
`tmp/soak-cattext-progress-30min/soak-20260531-054927-cattext-progress-30min.json`

| Duration | Fixtures | Pages | Avg CPU | p95 CPU | Max CPU | RSS slope | Stalls |
|----------|----------|-------|---------|---------|---------|-----------|--------|
| 1800s | Winter Trip, Breakup Truth, Seek Fun, Translated Word | lyrics, album, playlist, lyrics | 3.703 | 11.3 | 27.2 | +10.529 MB/hour | 0 |

Dual-app v2.8 reference checks were run for process-level evidence. The current
dual monitor's motion CSV is not independent when both apps write to the same
diagnostics directory, so use its CPU/crash result as authoritative and use the
candidate-only LUXB motion/text/frame gates above for UX parity:

| Fixture | v2.8 avg CPU | Candidate avg CPU | v2.8 max CPU | Candidate max CPU |
|---------|--------------|-------------------|--------------|-------------------|
| `line-winter-trip` | 14.652 | 7.077 | 33.7 | 22.4 |
| `line-breakup-truth` | 18.044 | 4.931 | 39.2 | 22.9 |
| `word-seek-fun` | 21.275 | 5.425 | 44.2 | 13.9 |
| `translated-word` | 19.300 | 7.515 | 33.4 | 26.6 |

Sequential reference checks should be preferred for prior-version comparisons.
`scripts/luxb_sequential_reference.py` runs one app at a time, deletes the live
diagnostics CSV before each run, copies the resulting CSV into the artifact
folder, then kills the app before starting the next app. This makes same-bundle
`origin/main` comparisons valid without cross-process CSV contamination.

Observed mandatory Winter fixture evidence:

- v2.8 release reference: no line-motion CSV, so it is usable only for
  process-level CPU/crash evidence, not motion parity.
- `origin/main` reference at `2e073592`: CPU avg `29.985`; candidate CPU avg
  `13.158`; candidate ratio `0.439` (about `56.1%` lower) on the same
  scroll-tap-jump workload.
- `origin/main` line-motion CSV reports zero target/inter-line error for every
  row even while velocity is nonzero. Treat that as target-layout diagnostics,
  not presentation-layer drift evidence. The sequential comparator must report
  this as an incomparable reference motion signal instead of calling candidate
  presentation drift a regression against impossible zero-error reference data.

Observed owner line-level fixture evidence:

- `line-breakup-truth` (`分手真相` / Alvin Kwok) sequential `origin/main`
  comparison passed after ignoring unusable zero-settle baselines that also
  skipped settle windows.
- Artifact:
  `tmp/benchmark/sequential-reference/sequential-20260531-063834-breakup-origin-main-reference-fixed-line-breakup-truth/summary.json`
- CPU avg `26.697` -> `11.755` (candidate ratio `0.440`, about `56.0%`
  lower).
- Motion improved: reference settled target p95 `50.0` and settled inter-line
  p95 `50.0`; candidate settled target p95 `0.142` and settled inter-line p95
  `0.060`; lingering backlog `1` -> `0`.

## Contract (always)

- AMLL wave: 0.08s stagger, 3-row lead-in, radius 14, top-to-bottom order
- See [lyrics-renderer-performance.md](lyrics-renderer-performance.md) for protected UX list

## Dual-app live monitor (v2.8 vs candidate simultaneously)

```bash
python3 scripts/luxb_dual_monitor.py --fixture word-seek-fun --duration 60 --warmup 15
python3 scripts/luxb_dual_monitor.py --fixture line-winter-trip --duration 60 --warmup 15
python3 scripts/luxb_dual_monitor.py --fixture line-breakup-truth --duration 60 --warmup 15
```

Clones v2.8 to `tmp/reference-app/nanoPod-v28-reference.app` with bundle id `com.yinanli.nanoPod.v28reference` so both processes can run. Fails if either app crashes or candidate motion metrics regress vs reference (when live CSV exists).

## Sequential reference monitor

```bash
python3 scripts/luxb_sequential_reference.py \
  --reference-app /Users/yinanli/Documents/MusicMiniPlayer-main-cpu-baseline/nanoPod.app \
  --fixture line-winter-trip \
  --duration 16 \
  --warmup 8
```

Use this when comparing current candidate against `origin/main` or any other
same-bundle prior build. If the reference emits target-layout-only motion data,
the run must not be used as direct presentation drift parity evidence.
If the reference reports `activeTargetSettleTimeMax == 0` while also recording
settle skips, do not treat that zero as a perfect settle baseline; it is
incomplete settle evidence.

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
  --fixtures line-winter-trip,line-breakup-truth,word-seek-fun
```

## Stopping rule

Loop continues until: cold proxies beat v2.8 on all mandatory fixtures; 30–60 min soak tail cleaner than v2.8; owner sign-off on `冬天一个游` + `尋開心`.

Parity with v2.8 is **not** sufficient.
