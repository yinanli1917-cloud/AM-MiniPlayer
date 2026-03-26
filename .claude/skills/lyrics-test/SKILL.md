---
name: lyrics-test
description: "Unified lyrics test pipeline: 80-case regression + 77 unit tests + content/translation/metadata/timestamp verification + independent web cross-check. Use when: lyrics test, 歌词测试, 跑回归, verifier, run regression, test lyrics, run tests."
allowed-tools: Read, Grep, Glob, Bash(swift run LyricsVerifier:*), Bash(swift build:*), Bash(swift test:*), Bash(python3:*), Bash(cat:*), Bash(wc:*), Bash(grep:*), Agent, WebFetch, WebSearch, TodoWrite
user-invocable: true
---

# Unified Lyrics Test Pipeline

All verification in one skill. **No partial testing. No trusting scores alone.**

## Iron Rules

1. **Every matching algorithm change** → full pipeline before handing to user
2. **FAIL ≠ no lyrics exist** → web-verify every failure independently
3. **PASS ≠ correct lyrics** → verify content, translation, metadata, timestamps
4. **Stay in the loop** with subagents until clean or failures confirmed genuine
5. **Code changes in worktrees** — never modify main branch until all layers pass
6. **Subagents for all heavy lifting** — main context orchestrates only

## Architecture: Parallel Pipeline

```
Main Context (orchestrator — dispatches, collects, decides)
  │
  │  ┌─ Layer 1: swift test (77 unit tests)  ── GATE ──┐
  │  └─ Layer 2: swift build                            │
  │                                                     ▼
  │  ┌─ Batch Agent MH ── 20 Midnight Highway cases ──┐
  │  ├─ Batch Agent PE ── 20 Pearl of the East cases  ─┤ Layer 3
  │  ├─ Batch Agent HN ── 20 Harlem Nights cases ─────┤ (parallel)
  │  └─ Batch Agent AS ── 15 Ambient + 5 Popular ─────┘
  │                          │
  │                 collect failures + warnings
  │                          │
  │  ┌─ Content Verifier A ── batch of failures ──────┐
  │  └─ Content Verifier B ── batch of low-scores ────┘ Layer 4
  │                          │
  │              persistent failures only
  │                          │
  │  └─ Web Verifier(s) ── confirm lyrics exist ──────── Layer 5
  │
  └─ Final Report
```

**Speed**: Layer 3 runs 4 batches in parallel → ~80s instead of ~5min.
Layer 4 starts as soon as Layer 3 completes. Layer 5 only for persistent failures.

---

## Subcommands

### `/lyrics-test run` — Full pipeline (DEFAULT)

#### Step 1: Gate check (sequential, fast)

Run in the worktree (or main workspace if no code changes):

```bash
swift test 2>&1   # ~0.04s — must be 77/77
swift build 2>&1  # ~6s — must be zero errors
```

If either fails → stop immediately, report to user.

#### Step 2: Regression — 4 parallel batch agents (Layer 3)

Read `docs/lyrics_test_cases.json`, split by playlist prefix (MH/PE/HN/AS+POP+INS).
Dispatch 4 agents in ONE message (parallel):

```
Agent(prompt="Run these 20 lyrics tests using LyricsVerifier check.
For each song, run:
  swift run LyricsVerifier check \"Title\" \"Artist\" duration 2>&1
Collect: status (PASS/FAIL/NO_LYRICS), source, score, line count, first real line.
Flag any: score < 30, warnings, wrong first line (metadata instead of lyrics).

Songs:
MH-01|Behind You (2021 Remaster)|Hitomi Tohyama|208
MH-02|Mick Jagger Ni Hohoemi O|Akina Nakamori|283
... (20 songs)

Report format per song:
  [MH-01] PASS NetEase 55pts 22L first='そして何も言えなくなる'
  [MH-02] FAIL NO_LYRICS
  [MH-03] PASS QQ 30pts 15L ⚠️ first='词：xxx' METADATA_LEAK
")
```

Dispatch all 4 batch agents simultaneously. Each finishes in ~80s.

#### Step 3: Triage results

Collect all 4 batch reports. Categorize:
- **Clean PASS** (score ≥ 30, no warnings, first line is lyrics): done
- **Needs content check** (FAIL, score < 30, warning, metadata first line): → Layer 4
- **NO_LYRICS where expected**: → Layer 5

#### Step 4: Content verification — parallel subagents (Layer 4)

For songs needing deeper checks, dispatch subagent(s) with `--dump`:

```
Agent(prompt="Deep-verify these songs. For each, run:
  swift run LyricsVerifier check 'Title' 'Artist' duration --dump 2>&1

Verify:
  METADATA: first+last line are real lyrics, no credits/speaker tags
  TRANSLATION: if present, different language from source, no vocable translation
  TIMESTAMPS: monotonic, coverage ≥60% of duration, no overshoot
  LANGUAGE: matches song origin (J-pop→Japanese, Cantopop→Chinese)
  CORRECT SONG: lyrics match the requested song, not a same-artist collision

Songs: [list]")
```

#### Step 5: Web verification — parallel subagents (Layer 5)

Only for songs that FAIL and need confirmation:

```
Agent(prompt="Web-verify these songs independently.
WebSearch '[title] [artist] lyrics', check NetEase/QQ/Genius/LRCLIB.
Report: has lyrics? first line? instrumental? available sources?

Songs: [list of persistent failures]")
```

If lyrics exist online but pipeline missed → **real bug**.
If genuinely no lyrics → update `shouldFindLyrics: false` in test case.

#### Step 6: Final report

```
=== LYRICS TEST PIPELINE REPORT ===
Unit tests:     77/77 ✅
Build:          PASS ✅
Regression:     X/80 passed (Xm Xs elapsed)

  MH: X/20   PE: X/20   HN: X/20   AS+POP: X/20

Content verification:
  Metadata clean:     X/X ✅
  Translation valid:  X/X ✅
  Timestamps valid:   X/X ✅
  Correct song:       X/X ✅

Web verification:
  Confirmed no-lyrics:  X (test cases updated)
  Real pipeline bugs:   X ⚠️

VERDICT: PASS ✅ / FAIL ❌
```

---

### `/lyrics-test check "Song" "Artist" duration` — Single song deep verify

Dispatch ONE subagent that does everything:
```
Agent(prompt="Full verify: '[Song]' by '[Artist]' ([duration]s).
1. swift run LyricsVerifier check '[Song]' '[Artist]' [duration] --dump 2>&1
2. Check metadata (first+last line), translation, timestamps, language
3. WebSearch '[Song] [Artist] lyrics' to independently confirm first line
Report all findings.")
```

---

### `/lyrics-test baseline` — Snapshot before changes

```bash
swift test 2>&1 | tail -3
swift run LyricsVerifier run 2>/dev/null > /tmp/lyrics_baseline.jsonl
echo "✅ Baseline: $(grep -c '"id"' /tmp/lyrics_baseline.jsonl) cases"
```

---

### `/lyrics-test diff` — Compare against baseline

```bash
swift run LyricsVerifier run 2>/dev/null > /tmp/lyrics_current.jsonl
python3 << 'PYEOF'
import json

def load(path):
    results = {}
    with open(path) as f:
        for line in f:
            try:
                r = json.loads(line)
                results[f"{r['title']}-{r['artist']}"] = r
            except: pass
    return results

baseline = load("/tmp/lyrics_baseline.jsonl")
current = load("/tmp/lyrics_current.jsonl")

regressions, improvements, source_changes = [], [], []
for key in baseline:
    if key not in current: continue
    b, c = baseline[key], current[key]
    if b["passed"] and not c["passed"]:
        regressions.append(f"  ❌ {b['title']} - {b['artist']}: {b.get('selectedSource','N/A')} -> NO LYRICS")
    elif not b["passed"] and c["passed"]:
        improvements.append(f"  ✅ {c['title']} - {c['artist']}: -> {c['selectedSource']} ({c['selectedScore']:.0f}pts)")
    elif b.get("selectedSource") != c.get("selectedSource"):
        s1 = f"{b.get('selectedSource','N/A')}({b.get('selectedScore',0):.0f})"
        s2 = f"{c.get('selectedSource','N/A')}({c.get('selectedScore',0):.0f})"
        source_changes.append(f"  🔄 {c['title']}: {s1} -> {s2}")

if regressions:
    print(f"🔴 REGRESSIONS ({len(regressions)}):")
    print("\n".join(regressions))
if improvements:
    print(f"🟢 Improvements ({len(improvements)}):")
    print("\n".join(improvements))
if source_changes:
    print(f"🔄 Source changes ({len(source_changes)}):")
    print("\n".join(source_changes))
if not regressions and not improvements and not source_changes:
    print("✅ No changes")
if regressions:
    print(f"\n⛔ {len(regressions)} regressions — DO NOT SHIP")
PYEOF
```

---

### `/lyrics-test library [--recent N]` — Apple Music library smoke test

```bash
swift run LyricsVerifier library --recent 50 2>&1
```

Informational, not a gate.

### `/lyrics-test benchmark [--region XX]` — 100-song global benchmark

```bash
swift run LyricsVerifier benchmark 2>&1
```

---

## Key Files

| File | Purpose |
|------|---------|
| `docs/lyrics_test_cases.json` | 80 regression cases |
| `docs/lyrics_benchmark_cases.json` | 100 global benchmark |
| `Tests/MusicMiniPlayerTests/` | 77 unit tests |
| `Sources/LyricsVerifier/` | CLI test tool |
| `Sources/MusicMiniPlayerCore/Services/Lyrics/` | Pipeline core |

## Workflow for matching algorithm changes

1. `/lyrics-test baseline`
2. Create worktree — **never edit main directly**
3. `/lyrics-test run` — full parallel pipeline
4. `/lyrics-test diff` — zero regressions
5. Merge to main, hand to user
