---
name: lyrics-test
description: 歌词管线回归测试。跑 12+ 条预定义用例、单首歌测试、或 AM 资料库大规模测试。触发词：lyrics test、歌词测试、跑回归、verifier、测试歌词。
allowed-tools: Read, Grep, Glob, Bash(swift run LyricsVerifier:*), Bash(swift build:*), Bash(python3:*)
user-invocable: true
---

# 歌词管线回归测试

使用 LyricsVerifier CLI 测试歌词搜索、匹配、评分的完整管线。

## 子命令

### 1. `/lyrics-test run` — 跑预定义回归用例

```bash
swift run LyricsVerifier run 2>&1
```

读取 `docs/lyrics_test_cases.json`，逐条测试。期望：全部 PASS。

**输出解读**：
- `[+] PASS` — 找到歌词且符合期望
- `[x] FAIL` — 未找到歌词或不符合期望
- `⚠️` — 内容验证警告（可能错配）
- `[syllable]` — 有逐字时间轴
- `[trans]` — 有翻译

### 2. `/lyrics-test check "歌名" "艺术家" 秒数` — 测试单首歌

```bash
swift run LyricsVerifier check "晴天" "周杰伦" 269 2>&1
```

用于调试特定歌曲的匹配问题。

### 3. `/lyrics-test library [--recent N]` — AM 资料库测试

```bash
swift run LyricsVerifier library --recent 50 2>&1
```

从 Apple Music 资料库取最近 N 首歌测试（默认 20）。用于大规模回归。

### 4. `/lyrics-test baseline` — 建立基线快照

在修改匹配逻辑之前运行，保存当前结果用于对比：

```bash
swift run LyricsVerifier run 2>/dev/null > /tmp/lyrics_baseline.jsonl
swift run LyricsVerifier library --recent 50 2>/dev/null >> /tmp/lyrics_baseline.jsonl
echo "✅ 基线已保存到 /tmp/lyrics_baseline.jsonl ($(wc -l < /tmp/lyrics_baseline.jsonl) 条)"
```

### 5. `/lyrics-test diff` — 与基线对比

修改匹配逻辑后运行，与基线对比差异：

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

regressions = []
improvements = []

for key in baseline:
    if key not in current:
        continue
    b, c = baseline[key], current[key]
    if b["passed"] and not c["passed"]:
        regressions.append(f"  ❌ {b['title']} - {b['artist']}: {b['selectedSource']} -> NO LYRICS")
    elif not b["passed"] and c["passed"]:
        improvements.append(f"  ✅ {c['title']} - {c['artist']}: -> {c['selectedSource']} ({c['selectedScore']:.0f}pts)")
    elif b.get("selectedSource") != c.get("selectedSource"):
        s1 = f"{b.get('selectedSource','N/A')}({b.get('selectedScore',0):.0f})"
        s2 = f"{c.get('selectedSource','N/A')}({c.get('selectedScore',0):.0f})"
        improvements.append(f"  🔄 {c['title']} - {c['artist']}: {s1} -> {s2}")

if regressions:
    print(f"🔴 回归 ({len(regressions)}):")
    print("\n".join(regressions))
if improvements:
    print(f"🟢 改进 ({len(improvements)}):")
    print("\n".join(improvements))
if not regressions and not improvements:
    print("✅ 无变化")
PYEOF
```

## 关键文件

- `docs/lyrics_test_cases.json` — 预定义测试用例
- `Sources/LyricsVerifier/` — CLI 工具源码
- `Sources/MusicMiniPlayerCore/Services/Lyrics/` — 歌词管线核心

## 典型工作流

1. 改匹配逻辑前：`/lyrics-test baseline`
2. 改代码
3. 改完后：`/lyrics-test diff`（确认无回归）
4. 最终验证：`/lyrics-test run`（全部 PASS）
