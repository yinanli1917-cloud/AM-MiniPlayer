# Resolver Optimization Round 2 — Gate Record (started 2026-06-12)

Scope: review proposals #8a/#8b (verdict memoization), #9 (CN-tier resolver cache),
#11 (Japanese reading corroboration) from docs/lyrics-pipeline-review-2026-06-10.md,
corrected forms. One proposal per commit. Task: .codex/tasks/06-12-resolver-optimization-round-2-matching-speed-and.

## Baseline (2026-06-12, pre-change)

- swift test: 606 tests green (pre-8a).
- Verifier: 77/82 passed — tmp/review-gates/verifier-baseline-2026-06-12.txt.
- Benchmark run1: 90/100 (16 no-lyrics) — benchmark-baseline-2026-06-12-run1.txt.
- Benchmark run2 (back-to-back): 77/100 (37 no-lyrics) — run2.txt.

### Methodology finding 1 — provider noise envelope

Run1 vs run2, minutes apart with NO code change: 7 verdict flips (BM-FR-06,
BM-HI-02/06/07/09/10, BM-PT-07 — all NetEase/QQ-sourced) — a transient NetEase
instability window, disproved as cumulative throttling by benchmark-8a (4th heavy
run, day's best 92/100, all 7 recovered). RULE: absolute pass counts never gate a
commit; gates compare per-case against the run1-vs-run2 stable set, and every new
flip gets an individual `check` recheck; only a flip that REPRODUCES individually
counts as a regression.

### Methodology finding 2 — stdout JSONL tears

~28% of streamed per-case JSON rows are unparseable (concurrent pipeline logging
interleaves mid-row; ids present 100/99 but only ~72 rows parse). Fixed by
`benchmark --json-out <path>` (single atomic post-run write, this round's tooling
commit). Diffs: tmp/review-gates/diff_cases.py (quote-aware brace scanner, salvage
mode for stdout files).

## 8a — token memo + per-result solo verdict

Commit: (pending)

- TDD: failing-first probe assertions (576 tokenization passes / 12 solo verdicts
  pre-memo on fixtures), then green: tokens ≤4 (once per result), solo = 1.
- swift test: 611 tests (606 + 5 new LyricsSelectionMemoizationTests), 0 failures —
  fresh run by orchestrator, exit 0.
- Equivalence: drain-style repeated calls vs single calls identical winner+score over
  growing-prefix × repeat fixture matrix, durations 0 and 240; duration-key safety
  pinned (verdict flips between durations recompute, never stale-serve).
- Verifier: 76/82 — 4 changed cases vs baseline, all NetEase-vanishing shaped
  (K01 LRCLIB-mirror flip PASS→PASS; X07 NetEase→QQ; X24 NetEase→LRCLIB-Search;
  X27 NetEase→none). Individual rechecks: (pending below)
- Benchmark: 92/100, ZERO pass flips vs baseline run1 among parseable cases; all 7
  run2-collapsed cases recovered. BM-PT-06 (run2 PASS → 8a FAIL, run1 row torn):
  individual recheck (pending below).
- Real-app (app rebuilt c8f36c31, relaunched 01:56:01, 自寻烦恼 — Buddha Jump,
  CN catalog): lyrics Applied 35L at +2s (inside 3s budget), NetEase score=100
  early-return; selectBestResult lines per fetch = 7 (6 solo across ~4 distinct
  result instances + 1 pool) vs historical 12+ with per-event repetition trains
  eliminated. The strict ≤4 line target closes with 8b (exit-closure split removes
  remaining per-event solo evaluations). Playback state captured and restored
  (paused @ 141.25).

### 8a flip rechecks (individual, post-cooldown)

All five PASS — no flip reproduces; verdict: provider weather, not 8a.

- K01 PASS LRCLIB-Search 69pts (mirror flip healed)
- X07 PASS LRCLIB 49pts 43L — the ONLY true pass→fail in verifier-8a; --dump
  full-text inspected: 言不由衷 prayer verses (容我为我们写一篇祷文…), fixture
  content-identity oracle green (recheck-X07-dump.txt)
- X24 PASS LRCLIB-Search 68pts
- X27 PASS (fixture tolerates unresolved; NetEase still weather-flaky for it —
  note: X27 had passed in BOTH full runs; only content source differed)
- BM-PT-06 PASS Genius 31pts 61L

8a verdict: LANDED — identity proven offline (611 tests), zero reproducible
per-case regression, real-app applied at +2s with selection-line drop visible.

## 8b — exit-closure split (cached vs event-dependent terms)

Commit: (this commit)

- Mechanism: per-result PURE exit terms (syllable-sync presence, lyrics-CJK,
  romanized-CJK sniff, sane-timeline [duration-keyed], strong/tight alias
  identity) move into write-once DrainExitFacts on the 8a memo box; scorer
  romaji/quality verdicts memoized; 1-element selectBestResult pools route
  through the solo-verdict memo (single chokepoint). Pool composition, elapsed
  time, and branch-flag boxes stay verbatim event-side. Orchestrator verified
  the chokepoint invariant independently: zero LyricsFetchResult constructions
  in LyricsResultSelection.swift — selection only ever returns pool elements.
- TDD: probe assertions failing pre-split (48 facts computations for 4 results
  × 12 events → 4; romaji 24 → ≤4; quality 12 → ≤4; warm 1-element selections
  24 full passes → 0), then green; pinned-value equivalence + duration keying.
- swift test: 616 (611 + 5 new), agent green; orchestrator chain run showed ONE
  transient unidentified failure whose detail a summary-only pipe discarded —
  5 consecutive full-suite re-runs green; all later gate chains capture full
  output to files so any recurrence is identifiable.
- Verifier: 77/82 == baseline count, ZERO pass flips vs baseline. Source flips
  without pass changes (H12 NetEase→QQ, H13 QQ→NetEase): H12 individually
  rechecked → NetEase 100pts, SHA byte-identical to baseline suite run —
  provider weather. (Observation, out of scope: `check` mode fails H12's
  first-line phrase oracle while `run` mode treats it as advisory — same
  content, different harness verdicts.)
- Benchmark: 92/100 via clean --json-out (first live use), ZERO pass flips vs
  baseline run1; vs 8a only X07/BM-PT-06 recovered (the known weather pair).
- Real-app (binary d5763fa5, relaunch 02:38): cached JP track applied instantly
  with correct content (泣かないで… 28L); fresh drain fetch (track switch)
  selection lines = 3 (2 empty-pool + 1 solo) — review target ≤4 per fetch MET
  (12+ pre-#8 → 7 post-8a → 3 post-8b). Launch refetch of the CN track: 3 lines
  before backfill. Playback state restored (自寻烦恼 paused @ 141.25).

8b verdict: LANDED — #8 family complete, perf gate satisfied.

## #9 — CN-tier resolver cache (tier-separated, schema v6)

Commit: (this commit)

- Mechanism: CN-tier resolutions persist to their own `cn_entries` dictionary
  (separate store → cross-tier overwrite structurally impossible; the 5 external
  readers of the localized store are untouched). Replay rebuilds the cached row
  as a synthetic iTunes result and pushes it back through matchCNResult itself —
  zero guard duplication: S/T title match, same-script artist rule, romanized
  corroboration (postmortem 006), Δ window vs the stored REAL durationDiff.
  Guard failure → stale row logged, fresh search overwrites. Successes only —
  no negative rows. Dead preflightExact chain deleted (grep: zero call sites of
  its only caller; live store was already empty). persist() debounced (~1s) on
  the SAME pre-existing serial queue; flush() on app terminate (before bundle
  swap) and at verifier-CLI exit (gate determinism). Schema 5→6 flushes all old
  rows once. MetadataResolver net SMALLER (1249→1216).
- TDD: tier-overwrite RED (TW write destroyed CN row, "1 != 2") + schema-flush
  RED + API-absence compile reds → all green; 621 tests (616+5), 0 failures,
  fresh orchestrator run (/tmp/swift-test-9-orch.log).
- Cold/warm (targeted, per noise methodology — full-benchmark doubles are
  weather-confounded): 自寻烦恼/Buddha Jump — cold persisted 佛跳墙 Δ0.15 row
  (2118ms), warm ts-unchanged + identical result (1258ms), instrumented warm
  shows 💾 CN disk hit ×2 with ZERO 搜索开始; Love You More & More/Rene Liu —
  cold persisted 很爱很爱你/刘若英 Δ0.00, warm disk hit, zero refires. Tiers
  coexist live (18 CN rows after the suite; localized store independent).
- Verifier 78/82 (baseline 77), ZERO pass flips among parsed cases. Marker-level
  audit of every verdict change: C02 + X04 improved (weather); X13/X14 torn-row
  artifacts (verdicts unchanged); X34 PASS→FAIL — proven ENVIRONMENTAL by
  control experiment: pre-#9 binary (stash) fails identically (NetEase 54pts,
  3.8s) in the same window; direct cause visible in logs — iTunes CN/HK/TW
  returned 无结果 for every term incl. bare 'Li Ronghao'; no CN row existed for
  the song (no cache involvement possible).
- Benchmark 92/100, ZERO pass flips vs baseline run1 AND vs 8b (full-coverage
  json-out diff, no salvage gaps).
- Real-app (binary a1d75ee8): restart + play CN track → fetch START, 💾 CN disk
  hit ×2, Applied 35L correct content — all within the same log second, row
  written by a different process (CLI). 3s budget: met with ~2.9s headroom.
- Observation recorded (pre-existing, NOT #9): the CN translated-candidate door
  admits cross-script artist rows (e.g. 'Shape of You'/Ed Sheeran → 七元 cover,
  Δ0.32) — downstream lyric-level three-rule guards hold (BM-EN-01 passes via
  AMLL in all runs); candidate for a later admission audit.

#9 verdict: LANDED — warm CN replays serve from disk with zero network.

## #11 — Japanese reading corroboration (whitelist deleted, schema v7)

Commit: (this commit)

- Mechanism: real Japanese-reading function in LanguageUtils (CFStringTokenizer
  ja-locale Latin transcription; long-vowel fold derived from probed
  transcriptions — 東京→toukyou folds to tokyo class; S/T retry covers 梦/风;
  FAIL-CLOSED on any empty token). The one shared corroboration helper
  (romanizedTitleCorroboration) gains a reading lane (pinyin lane extracted
  byte-identical); every postmortem-006 door now reading-aware with thresholds
  and order untouched. isTitleMatch's whitelist alias lookup replaced by
  reading EQUALITY (no fuzz at this door); containment shortcut floored at the
  existing ≥4 Latin-identity rule; `japaneseRomanizedTitleAliases` DELETED —
  grep-proven zero whitelists remain. Schema 6→7 flushes rows judged under
  pinyin-only corroboration.
- TDD: 16 new tests, 27 RED first (transcription keys, ranking pins,
  containment floor, negatives) → green. Suite: 640 tests 0 failures (includes
  a CONCURRENT session's 3 WIP renderer tests in the same tree — isolation run
  637/0 with --skip; commit stages only this campaign's files).
- Verifier 77/82: every marker change audited — C02 + X01 improved, H11/H27
  torn-row artifacts (verdicts identical), X34 still the established
  environmental failure.
- Benchmark 92→91/100 with ZERO pass flips vs #9 and vs baseline run1
  (full-coverage json diffs). Focused --region ja 11/12 and zh 10/12: one flip
  each (BM-JA-05 紅蓮華, BM-ZH-01 晴天) minutes after both PASSED in the full
  #11 run — neither reproduces individually (both PASS on recheck; 晴天's
  recheck also exercised the #9 CN disk row, Δ0.75 hit before correct lyrics).
- BM-JA-11 すずめ source flip (NetEase→QQ, translations 31→1) fully diagnosed,
  NOT #11: today NetEase's own search results no longer contain the studio
  すずめ row (raw candidate lists show only 東京上空/すずめの涙/feat.十明), its
  fallback pick すずめの涙 is the WRONG song at 91pts, and the cross-source
  identity cluster correctly rejects it for QQ+Genius's agreeing correct
  content (QQ 40L dump-verified: 君の中にある赤と青き線…). Pre-#11 stash
  control in the same window picks NetEase-91 only because QQ's fetch flaked
  there (its candidate logs show the identical pick). #9-era record shows both
  sources present with NetEase content passing the oracle — provider data rot
  mid-day, pipeline routed around it. Self-heals when NetEase's row returns.
- Real-app (binary 971506a4): romaji-titled track OUTSIDE the 8 words —
  'Yuki No Hana' / Akina Nakamori (covers album): NetEase candidate 雪の華
  marked T=true and selected at P1 Δ0.8s (only the reading door can produce
  that match), Applied 48L in ~1s with the exact 雪の華 opening line
  のびた人陰を　舗道に並べ. Playback state restored.

#11 verdict: LANDED — Japanese title matching generalizes from 8 words to the
language; a whitelist is deleted from production.

## Latency-regression fix A+B — warm-up sweep + single-flight (post-round-2)

Commits: (B then A, this pair)

User-reported regression: waits >3s, "searching more sources" repeatedly.
Diagnosis from the user's own session log (06:26-06:53): schema double-flush
left 34 cold resolver waves vs 5 disk hits; resolver fired its full wave TWICE
per fetch (concurrent Branch-2/Branch-3/backfill consults); hard-miss songs
re-ran the full sweep on every replay. Immediate mitigation: manual
`library --recent 60` warm sweep restored 55 localized + 43 CN rows.

- B single-flight: per-entry-point actor coalescing (unstructured shared Task —
  awaiter cancellation never forwards; dedupe-only, entry dropped on completion
  so sequential consults re-enter disk replay + live guards). TDD: 6 tests RED
  (8≠1, 6≠1, 4≠1, cancellation 2≠1) → green.
- A warm-up sweep: once per schema version (stamped only on completion),
  utility QoS, sequential 1s spacing, 50-track cap, yields to foreground
  fetches, metadata-only via the normal entry points. TDD: 6 tests.
- Suite: 658 tests 0 failures (fresh orchestrator run). Verifier 73/82 and
  benchmark 87/100 in a visibly degraded provider window: ALL pass flips
  adjudicated — ES-09/KO-05/PT-06 recover individually (Genius fallback
  carrying while synced sources flake); FR-03/PT-04/C02/X01/X04 improved;
  R07 and H21 reproduce BUT fail byte-identically on stashed pre-change code
  (R07 UNRESOLVED, H21 wrong NetEase row 22L) — today's provider state.
  Zero A+B-attributable regressions.
- Real-app (binary 08d8de03): warm-up start line at +1s of launch, 2 queue
  tracks resolved throttled, "schema v7 stamped" completion; cold-track fetch
  (SHYNESS BOY/Anri) fired exactly ONE CN wave (was 2) and applied correct
  lyrics (夏の Partyで声を, 28L synced) in 1s. Playback restored.

A+B verdict: LANDED — duplicate waves gone, schema flushes can never silently
cold the library again.
