# POSTM-007: Chinese Translation Leak — Three Root Causes

**Date**: 2026-03-22
**Impact**: Feature regression — Chinese text displayed as main lyrics in non-Chinese songs
**Severity**: P1 (recurring — reported fixed 3+ times, kept coming back)
**Fix Commit**: 16a7cd5

---

## Summary
- **Symptom**: Non-Chinese songs (especially K-pop like NewJeans "Supernatural") displayed Chinese translation text as main lyrics lines instead of in the `.translation` field. Additionally, the entire second verse (1:22–2:21) was missing.
- **Duration**: Persisted across multiple fix attempts. Previous fixes (interleaved extraction, mixed penalty, stripChineseTranslations) each solved part of the problem but left escape paths.
- **Impact**: All non-Chinese songs fetched from NetEase/QQ with user-uploaded lyrics that embed Chinese translations inline.

---

## Root Cause Analysis

### The Data: NetEase User-Uploaded Lyrics

NetEase song ID 3314634768 ("SuperNatural" by NewJeans/DANNIELE) has Chinese translations embedded in three formats within the **main lyrics track** (`lrc`):

```
Format 1 — Standalone Chinese line (interleaved):
  [00:27.938]夜晚 狂风暴雨              ← pure Chinese
  [00:30.296]Cloudy sky                  ← English

Format 2 — Korean+Chinese mixed in same line:
  [00:51.659]내 심박수를 믿어 我相信 自己的心跳声

Format 3 — Japanese+Chinese mixed in same line:
  [01:06.876]もう知っている我 都已了然
```

A separate `tlyric` translation track also exists but contains completely different translations at mismatched timestamps.

### Three Root Causes

#### Bug 1: Unpaired pure Chinese lines kept as main lyrics

**Five Whys:**
1. Why did Chinese text appear in main lyrics?
   - `stripChineseTranslations()` Pass 2 left unpaired pure Chinese lines in the output.
2. Why were they unpaired?
   - The function only attaches a pure Chinese line to the **next** non-Chinese line if `line.translation == nil`.
3. Why did adjacent lines already have translations?
   - `extractInterleavedTranslations()` ran first and paired some Chinese lines. Then `mergeLyricsWithTranslation()` merged the `tlyric` track, populating `.translation` on most remaining lines.
4. Why weren't unpaired lines dropped?
   - Explicit design decision: "don't discard any lines to avoid time gaps."
5. **Root cause**: The "don't discard" policy was wrong. The function already verified the song is non-Chinese (guard at top). Any orphaned pure Chinese line is a confirmed translation leak, not a content line. Keeping it is worse than dropping it.

**Concrete example (line at 42.8s):**
```
[05] 38.0s  너와 나 다시 한번 만나게  (trans: 让你我再一次相见)  ← has trans from tlyric
[06] 42.8s  向着彼此 不断靠近          (trans: nil)             ← pure Chinese, ORPHANED
[07] 44.2s  My feeling's getting deeper (trans: nil)             ← will claim [08] below
[08] 48.6s  对你的感觉日渐强烈          (trans: nil)             ← pure Chinese
```

Line [06] can't pair with [05] (already has translation) or [07] (hasn't been processed yet). Old code: keep as main lyrics. Fix: drop it.

#### Bug 2: Japanese kanji destroyed by stripChineseChars()

**Five Whys:**
1. Why did Japanese lines show corrupted text like `もうっている`?
   - `stripChineseChars()` removed the character `知` from `もう知っている`.
2. Why was `知` removed?
   - `stripChineseChars()` removes all CJK Unified Ideographs (U+4E00–9FFF).
3. Why is `知` in that range?
   - CJK Unified Ideographs contains both Chinese characters AND Japanese kanji — they share the same Unicode block.
4. **Root cause**: The function treated the entire CJK range as "Chinese" with no awareness that Japanese text uses kanji from the same range. The distinction requires context (kana proximity), not Unicode range alone.

**Concrete example:**
```
Input:  もう知っている我 都已了然
                ↑ kanji      ↑ Chinese

Old behavior: strip all CJK → もうっている (corrupted Japanese)
New behavior: split at last kana boundary →
  Japanese: もう知っている
  Chinese:  我 都已了然 (→ .translation)
```

The heuristic: kana (hiragana/katakana) only exists in Japanese. CJK characters adjacent to kana are kanji; CJK characters after all kana ended are Chinese.

#### Bug 3: Incomplete lyrics won on score due to translation bonus

**Five Whys:**
1. Why was the second verse (1:22–2:21) missing?
   - NetEase source data jumped from [01:18] to [02:21] — the upload simply omitted the second verse.
2. Why was NetEase selected over QQ (which had complete lyrics)?
   - NetEase scored 63pts vs QQ's 58pts.
3. Why did incomplete NetEase outscore complete QQ?
   - NetEase had translations (+15 bonus) and higher source bonus (+8 vs +6). QQ had no translations.
4. Why didn't the scorer catch the 63-second gap?
   - The scorer only checked `(last.endTime - first.startTime) / duration` — first-to-last span. A massive internal hole looked fine because the first and last lines covered the song boundaries.
5. **Root cause**: The coverage metric measured span, not density. A source with line 1 at 0s and line 2 at 180s would score perfect "coverage" despite having only 2 lines.

---

## Fix Summary

### Fix 1: Drop orphaned Chinese lines ([LyricsParser.swift:503](Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsParser.swift#L503))

```swift
// Before: keep as main lyrics
} else {
    result.append(line)  // "don't discard, avoid time gaps"
}

// After: confirmed translation leak → drop
} else {
    continue  // song is non-Chinese (guard passed), orphan = leak
}
```

### Fix 2: Japanese-aware splitting ([LyricsParser.swift:467](Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsParser.swift#L467))

```swift
// Lines with Japanese kana: split at kana→CJK boundary
if LanguageUtils.containsJapanese(text) {
    let (jpPart, cnPart) = splitJapaneseAndChinese(text)
    // jpPart keeps kanji intact, cnPart → .translation
}
```

`splitJapaneseAndChinese()` finds the last kana position and splits there. Everything before (including kanji mixed with kana) is Japanese; everything after is Chinese.

### Fix 3: Internal gap penalty ([LyricsScorer.swift:99](Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsScorer.swift#L99))

```swift
// >45s gap between consecutive lines → -20 points
if !isUnsyncedSource && lyrics.count >= 5 {
    let maxGap = (1..<lyrics.count)
        .map { lyrics[$0].startTime - lyrics[$0 - 1].startTime }
        .max() ?? 0
    if maxGap > 45 { score -= 20 }
}
```

Threshold is 45s to avoid penalizing normal instrumental breaks (typically <40s). Supernatural's 63s gap triggers the penalty, making NetEase (43pts) lose to QQ (58pts).

### Fix 4: Metadata title line stripping ([LyricsParser.swift:388](Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsParser.swift#L388))

```swift
// Before: "Song - Artist" stripped only if < 50 chars
if trimmed.contains(" - ") && trimmed.count < 50 && line.startTime < 20

// After: any "Song - Artist" line at ≤1s is metadata
if trimmed.contains(" - ") && line.startTime <= 1.0
```

QQ's verbose title `"Supernatural (Winter ver.) (2024 韩国AAA颁奖礼现场) - Newjeans"` (~90 chars) escaped the old 50-char limit.

---

## Why Previous Fixes Failed

| Fix attempt | What it solved | What it missed |
|-------------|---------------|----------------|
| `extractInterleavedTranslations()` | Standalone Chinese lines with gap < 2.0s | Lines with gap > 2.0s; mixed-in-line Chinese |
| `splitInlineTranslations()` | Latin+CJK mixed lines | CJK+CJK mixed (Japanese+Chinese, Korean+Chinese) |
| `mixedTranslationPenalty()` | Deprioritizes mixed sources in scoring | All sources mixed → no clean alternative wins |
| `stripChineseTranslations()` v1 | Mixed Korean+Chinese split | Orphaned Chinese lines; Japanese kanji corruption |

Each fix addressed one format but left others. The recurring pattern: **the translation embedding is multi-format, and each fix only covered one format**.

This round's fix is comprehensive because it handles all three embedding formats (standalone, Korean+Chinese mixed, Japanese+Chinese mixed) AND has a fallback (drop orphans) instead of hoping every line gets paired.

---

## Verification

| Test | Before | After |
|------|--------|-------|
| Supernatural — Chinese in main lyrics | 3+ lines with Chinese | 0 lines |
| Supernatural — missing second verse | 63s gap (30 lines) | Full coverage (46 lines) |
| Supernatural — Japanese kanji | `もうっている` (corrupted) | `もう知っている` (intact) |
| Korean benchmark (12 songs) | Multiple leaks | 12/12 pass, 0 body leaks |
| Unit tests (77) | 77/77 | 77/77 |
| Regression tests (15) | 11/15 | 11/15 (same 4 unrelated) |
| 残酷な天使のテーゼ (Japanese) | Not tested | Kanji intact, 0 corruption |

---

## Lessons Learned

### Key Insights
- **"Don't discard" is not always safe**: Keeping orphaned translation lines as main lyrics is worse than the time gap they might create. Safety policies must account for what happens when they fail.
- **Shared Unicode ranges need context**: CJK Unified Ideographs (U+4E00–9FFF) is NOT "Chinese" — it's a shared block for Chinese, Japanese kanji, and Korean hanja. Stripping the entire range corrupts Japanese text. The distinction requires contextual signals (kana proximity).
- **Coverage ≠ span**: Measuring first-to-last timestamps misses internal gaps. A 186s song with a 63s hole in the middle still "covers" 178s.
- **Translation bonus can invert quality**: A +15 translation bonus is enough to make a 30-line incomplete source outrank a 46-line complete source. Score components must be balanced against completeness.

### Defensive Checklist
When modifying lyrics stripping/scoring, verify against:
- [ ] K-pop with embedded Chinese translations (Supernatural, How You Like That)
- [ ] Japanese songs with kanji (残酷な天使のテーゼ)
- [ ] Japanese+Chinese mixed lines (Supernatural's もう知っている我 都已了然)
- [ ] Chinese songs are NOT affected by stripping (女爵, 晴天, 起风了)
- [ ] Songs with long instrumental breaks are NOT penalized (>30s interludes)
- [ ] Complete sources beat incomplete sources with translations

---

## Related
- **Fix Commit**: 16a7cd5
- **Related Postmortem**: POSTM-006 (romanized→CJK false positive)
- **Test command**: `swift run LyricsVerifier check "Supernatural" "NewJeans" 186 --dump`

---

## Tags
#lyrics #translation-leak #chinese #japanese #kanji #scoring #stripChineseTranslations #netease #qq
