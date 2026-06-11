# Phase 0+1 (items 0a, 0b, #1, #2) gate record — 2026-06-10
Commits: 984d218c, cd545727, 9e5adf57, 8236f6b8
- swift build (both flavors): clean. swift test: 559 tests, 0 failures.
- Verifier run: IDENTICAL to baseline (72 pass / 10 fail, same set).
- Benchmark vs baseline (91/9): after-cold 92/7, after-warm 89/9.
  ZERO new stable failures (intersection of both after-runs ⊆ baseline fail set).
  Stable fails: AR-04, FR-03, PT-05, TH-04, ZH-05 (all pre-existing).
  Flap set (≤1 run each, network-dependent regions): FR-01, KO-05, PT-02, PT-01, PT-06, HI-02, PT-04.
- #2 replay-determinism property: verified via identical verifier run (disk-cache heavy) +
  MetadataDiskCacheTests round-trip/flush tests; benchmark cold≠warm delta attributed to
  live-source inter-run noise (pre-existing; baseline region flake list matches).
