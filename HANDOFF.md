# HANDOFF — 2026-04-11

## Fixed: cross-region lyric aliasing (以小见大)

User reported a regression on **mei ehara — Invisible** (right panel
showed correct content but wrong timestamps). They later clarified two
more cases — **王菀之 — 忘记有时** (wrong-song match) and **Eman Lam —
Xia Nie Piao Piao Chu Chu Wen** (no lyrics) — and made the broader
point: this is a structural bug class, not three independent issues.

Investigation revealed the structural failure mode: Apple Music,
NetEase, QQ, LRCLIB, and the iTunes regional catalogs label the SAME
recording with DIFFERENT display titles depending on region/locale.
mei ehara's "Invisible" is "不確か" on JP iTunes; Eman Lam's romanised
"Xia Nie Piao Piao Chu Chu Wen" is "仙乐飘飘处处闻" on NetEase. Branch-1
fetched community sources with the original title only and got 404s;
Branch-2 only fed resolved CJK aliases into NetEase/QQ, never LRCLIB.
And on top of that, NetEase/QQ tagged plain-text fallbacks as `.synced`,
so the UI auto-scrolled against fabricated timestamps when no real
data existed.

Three structural fixes (commit `c8021a3`):

### 1. Parse-time `LyricsKind` is the single source of truth

`LyricsParser.detectKind(_:)` is the new canonical detector — returns
`.unsynced` when:
- fewer than 3 lines, OR
- all timestamps are 0, OR
- distinct timestamp count is < `max(2, lines/2)`, OR
- the total span is less than 30 s.

`fetchNetEaseLyrics` and `fetchQQMusicLyrics` now return `(lyrics, kind)`.
The `createUnsyncedLyrics` fallback flips kind to `.unsynced` AND skips
`applyTimeOffset` (no real timestamps to align). The UI's existing
`isUnsyncedLyrics` flag then suppresses auto-scroll.

### 2. Branch-2 fans out to ALL title-keyed sources

Previously Branch-2 only fed the resolved CJK alias into NetEase and
QQ. Now it also fans out to **LRCLIB**, **LRCLIB-Search**, and **AMLL**.
This is what makes Invisible find LRCLIB's real synced 不確か lyrics
that Branch-1 (querying with the romanised title) couldn't reach.

To prevent the new five-source fan-out from doing 5 × N regions = 20+
duplicate iTunes round-trips, MetadataResolver gained a per-song actor
cache (`RegionResolveCache`) that memoises
`fetchMetadataFromRegionWithExactFlag`. Concurrent callers share a
single in-flight Task per `(title, artist, ~duration, region)`.

### 3. P3 CJK escape requires `isPureASCII(input)`

The romanised→CJK P3 escape was firing for CJK input too, picking
same-artist different-song collisions like 忘记有时 → 原来如此 by 王菀之.
The escape now requires the input title to be pure ASCII (a genuine
romanisation that can't textually match a CJK candidate). The token-
overlap path keeps the strict <0.5 s window; the CJK escape path is
bumped to <1.0 s to absorb routine 0.3–0.8 s mastering differences
between Apple Music and NetEase / QQ (Eman Lam — Xia Nie Piao Piao
→ 仙乐飘飘处处闻 was Δ0.5 s, sitting on the old boundary).

Cross-script artist tolerance in `buildCandidates` got the matching
treatment: the no-title-match tier now requires `resultTitleIsCJK`
and uses the same <1.0 s window, so search-engine-confirmed cross-
script artist mappings (Eman Lam → 林二汶, Kay Huang → 黄韵玲) survive
slight master differences.

## Verifier (43-song set, --inter-song-delay 1.0)

```
39/43 passed   0 warnings   4 no-lyrics
total 71740 ms  avg 1668 ms (best yet)
```

Remaining 4 "fails" are all genuine "no lyrics across all 7 sources":

| ID  | Title                    | Artist         | Notes |
|-----|--------------------------|----------------|-------|
| H09 | Twelfth Floor            | Karen Mok      | Cantopop B-side |
| H12 | Mayonaka No Shujinkou    | Sudo Kaoru     | Obscure 70s J-pop |
| H13 | Hiroshima mon amour      | Karen Mok      | French cover |
| H22 | 我的寶貝                 | Lee Chih Ching | Intermittent NetEase flake |

R07 Invisible PASSES with LRCLIB synced lyrics. The first-line
expectation in the test JSON was updated from the old (wrong) "不確か"
title token to "幽霊", the first sung word.

New regression anchors added:
- **H25 忘记有时 — 王菀之** (CJK input, P3 ASCII guard)
- **H26 Xia Nie Piao Piao Chu Chu Wen — Eman Lam** (cross-region alias,
  Branch-2 fan-out + cross-script artist tolerance)

## Live verification (signed app, screenshot-confirmed)

| Track | Source | First line | Notes |
|-------|--------|------------|-------|
| mei ehara — Invisible | LRCLIB-Search | 幽霊 ほどけていたんだ @24.23 s | real synced 不確か |
| 王菀之 — 忘记有时 | QQ | 有时无心的散聚 @16.32 s | P3 ASCII guard prevents 原来如此 collision |
| Eman Lam — Xia Nie Piao Piao Chu Chu Wen | NetEase | 想 飞往东京 @28.67 s | cross-region 仙乐飘飘处处闻, syllable sync |

## Unit tests

`swift test` → 93 pass, 2 skipped, 0 failures.

## Build

```
md5 nanoPod.app/Contents/MacOS/nanoPod = 7c85727162f4ea01a7a4a732842e01be
size: 4393712 bytes
DebugLogger: reverted to #if DEBUG (release-disabled)
```

App relaunched.

## Commits this session

```
c8021a3 fix: cross-region lyric aliasing — Branch-2 fan-out + parse-time kind tagging
00671ad feat: persistent metadata disk cache for warm cold-start latency
508e546 fix: Invisible wrong-lyrics — iTunes exact-match preflight + particle-gated P3 escape (superseded)
3a28ceb merge: GAMMA speculative branches + LyricsKind parse-time classification
```

(508e546's narrower preflight gate has been generalised by c8021a3.)

## Open tasks

1. Visual confirmation of the three fixed songs in the live app (done
   via screenshots — please double-check during real listening).
2. Merge `worktree-lyrics-pipeline-final` → `main` and delete the
   three agent worktrees once you're satisfied.
3. Consider adding a postmortem 009 documenting the
   "cross-region recording aliasing" bug class so future sessions
   don't reintroduce the per-song patches I tried first.

---
*Session 2026-04-10 → 2026-04-11 · structural fix for cross-region lyric aliasing · 39/43 verifier · binary md5 verified*
