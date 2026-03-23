# HANDOFF — 2026-03-23 (歌词翻译泄漏修复 + 全球基准测试)

## 当前任务
修复非中文歌曲（特别是 K-pop）主歌词行显示中文翻译的 bug，同时建立全球歌词基准测试系统。

## 完成状态
- ✅ 全球基准测试系统（10 区域 × 100 首热门歌曲，`swift run LyricsVerifier benchmark`）
- ✅ 五层验证器（翻译泄漏/语言一致性/源翻译/ML翻译/时间轴）
- ✅ `LyricsScorer` 混排翻译惩罚（同行中韩/中日混排 → 降分 + 取消翻译加成）
- ✅ `LyricsParser.stripChineseTranslations()` — 通用中文翻译剥离
- 🔄 **Supernatural 修复效果待用户验证** — 代码已部署，app 已重启，但用户尚未确认最终效果
- 🔄 **QQ 匹配到错误版本** — "Supernatural (Winter ver.) 颁奖礼现场版" 时间轴与原版不对齐

## 关键决策

### 1. 通用中文剥离（替代碎片化修复）
之前尝试了三个碎片化方案都不够：
- `extractInterleavedTranslations()` — 只检测纯中文独立行，漏掉同行混排
- `splitInlineTranslations()` — 只处理 Latin+CJK，漏掉 CJK+CJK（日+中）
- 评分惩罚 — 所有源都混排时无效

最终方案 `stripChineseTranslations()`：
- 统计中文行 vs 非中文行，中文歌不触发（安全阈值）
- 混排行（英+中、日+中、韩+中）→ 拆分，中文移到 `.translation`
- 纯中文行 → 附着到相邻非中文行的 `.translation`
- **不丢弃任何行** — 无法配对的保留原样，避免时间间隙

### 2. 评分惩罚仍保留
`LyricsScorer.mixedTranslationPenalty()` 作为第一道防线：
- 同行中韩/中日混排 ≥30% → -25 分 + 取消翻译加成
- 让干净源在评分中胜出

### 3. 全球基准测试独立于回归测试
- `docs/lyrics_benchmark_cases.json` — 100 首，与现有 15 条回归测试分开
- `BenchmarkValidator.swift` — 翻译泄漏检测用 Unicode 脚本检测
- `benchmark` 子命令支持 `--region` 过滤

## 已知问题 / 排查方向

### **核心问题：用户反馈修复后仍显示中文**
可能原因（按优先级排序）：
1. **QQ 匹配到 "Winter ver. 颁奖礼现场版"** — 时间轴不对齐，歌词卡顿。QQ P1 优先级选了 Δ2.0s 的 Winter ver 而非 Δ4-5s 的原版。需要在候选匹配中降低 live/remix/ver. 变体的优先级
2. **`stripChineseTranslations` 仍有遗漏** — 某些混排模式可能没被覆盖（如中文标点、数字混入）
3. **系统翻译覆盖** — Apple Translation 框架把韩/英翻译成中文后，如果 `.translation` 显示逻辑有问题，可能看起来像泄漏
4. **纯中文行保留后的视觉效果** — 无法配对的纯中文行仍作为主歌词显示

### 其他遗留
- `extractInterleavedTranslations` gap<2.0s 阈值可能太紧
- Spring Day 在 NetEase 返回日文版歌词（P2 匹配到日文翻唱）
- 泰文/阿拉伯文歌曲大部分无歌词源覆盖

## 下一步行动
1. **让用户播放 Supernatural 验证** — 检查截图中主歌词行是否还有中文
2. **如果仍有中文**：在 `LyricsService.applyLyrics()` 加 DebugLogger 逐行打印 `.text` 和 `.translation`，确认到底是源数据问题还是渲染问题
3. **QQ 版本匹配修复**：在候选匹配中对 "(Winter ver.)"、"(Live)"、"颁奖礼" 等变体降低优先级或跳过
4. **跑完整 benchmark** 确认无回归：`swift run LyricsVerifier benchmark --no-local-translation`
5. **回归测试确认**：`swift run LyricsVerifier run`（11/15 通过，R05/R06 是 lyrics.ovh 不稳定）

## 新增文件
- `Sources/LyricsVerifier/BenchmarkCases.swift` — 基准测试数据模型 + JSON 加载器
- `Sources/LyricsVerifier/BenchmarkValidator.swift` — 五层验证（翻译泄漏/语言/源翻译/ML翻译/时间轴）
- `docs/lyrics_benchmark_cases.json` — 100 首全球热门歌曲测试用例

## 修改文件
- `Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsParser.swift` — `stripChineseTranslations()` 通用中文剥离
- `Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsScorer.swift` — `mixedTranslationPenalty()` 混排惩罚
- `Sources/MusicMiniPlayerCore/Services/Lyrics/LyricsFetcher.swift` — NetEase/QQ 路径调用 `stripChineseTranslations`
- `Sources/LyricsVerifier/TestRunner.swift` — `translationEnabled` 参数 + `testSongWithLyrics()`
- `Sources/LyricsVerifier/main.swift` — `benchmark` 子命令
- `CLAUDE.md` — 目录清单 + benchmark 命令

## 调试命令速查
```bash
# 单首歌验证
swift run LyricsVerifier check "Supernatural" "NewJeans" 186

# 韩文区基准测试
swift run LyricsVerifier benchmark --region ko --no-local-translation

# 全量基准测试
swift run LyricsVerifier benchmark --no-local-translation

# 回归测试
swift run LyricsVerifier run

# App debug log
cat /tmp/nanopod_debug.log | grep -i supernatural

# 构建 + 重启
./build_app.sh && pkill -9 nanoPod; sleep 1; open nanoPod.app

# NetEase 原始歌词
curl -s "https://music.163.com/api/song/lyric?id=3314634768&lv=1&tv=1" \
  -H "User-Agent: Mozilla/5.0" -H "Referer: https://music.163.com"
```

---
*Created by Claude Code · 2026-03-23 09:50*
