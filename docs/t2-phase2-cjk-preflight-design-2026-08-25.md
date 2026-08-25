# T2 · Phase 2 设计 — CJK 已缓存歌同步直服（技术把关稿，未实现）

创始人裁定（2026-08-25）：已缓存的歌绝不该露 spinner。Phase 1 已落实非 CJK（见 t2-bug1/#3 收敛修法）。Phase 2 让 **CJK 也 spinner-free**——创始人曲库偏 CJK，这才是体感大头。本页只出设计+风险，供技术把关，**不动手**。

## 核心洞察：exact-key 命中 = 同曲身份，与 006 无关

- 磁盘键 = `SHA256(normalize(title)|normalize(artist)|normalize(album)|round(dur)±1)`（LyricsDiskCache.cacheKeys）。
- **postmortem-006 的风险是"romanized 输入 fuzzy 匹配到错误 CJK 兄弟曲"**——前提是**输入标题 ≠ 缓存标题**（罗马音 vs 原生 CJK），需别名解析。
- 而**原生 CJK 精确重播**：播放提供原生 CJK 标题 → 与写入键同源（已核实 persist 用请求/原始标题 `title`/`ot`，LyricsFetcher:545/1556）→ **direct-key 命中 = 同一 normalized 身份**。罗马音输入会算出**不同的键**、直接 miss、回落异步解析——**006 的错兄弟路径在 exact-key 下根本不可达**。

结论：**exact-key 命中可安全同步直服，与语言无关。** 现有 `canUseImmediateCachedLyrics` 对"CJK 歌词 + 非 ASCII 标题"一律拒绝，是因为它为 romanized-fuzzy 场景设计、分不清"原生精确"与"罗马音模糊"；**exact-key 命中正是那个判别器**。

## 提案

新增同步方法（与 Phase 1 并列）：
```
immediateNativeExactDiskLyrics(title, artist, duration, album) -> LyricsFetchResult?
```
接受一条磁盘条目当且仅当：
1. 它是**本次查询自身键**的 direct 命中（`candidates(title,artist,album,duration)` 用查询原文，非任何别名/解析变体）；
2. **词级**（含 syllable sync）——与 Phase 1 一致；
3. synced（跳过 instrumental/unavailable 可用性行）；
4. 条目 `duration` 与查询相差 ≤ ~1.5s（键已含 ±1 邻居；这层再兜一道，避免邻居键跨接到时长明显不同的条目）。

**跳过** `canUseImmediateCachedLyrics` 的 ASCII-标题门（该门是 romanized-fuzzy 的守卫，对 exact-key 不适用），但保留词级/synced 要求。命中即在 `fetchLyrics` 同步预检直服（同 Phase 1）；miss 回落异步（现状，无倒退）。

## 安全性证明

服务错误歌词，需要**两首不同的歌**共享 `normalize(title)+normalize(artist)+normalize(album)` 且时长相差 ≤1s。不同的歌 → 不同标题 → 不同键。故"键碰撞 ⟹ 同一首歌（至多不同母带，歌词通用）"。QED。SHA256 碰撞可忽略。

所有失败模式都**降级为异步（spinner），绝不降级为错歌词**：
- album 归一化在写/读间有差 → 键 miss → 异步；
- 两次播放时长漂移 >1s → ±1 邻居键覆盖 ±1s，超出则 miss → 异步；
- 某路径把 CJK 歌缓存在**解析后（非原生）标题**下 → 原生查询 miss → 该曲仍 spinner（不修，但不错）。

## 有效性依赖（非正确性）

Phase 2 能否真的让某首 CJK 歌 spinner-free，取决于**它当初是否以原生播放标题写入磁盘**。已核实主路径 persist 用请求/原始标题（:545 `title`、:1556 `ot`），所以库内原生 CJK 歌大概率命中。若个别源在写入前把标题改写成解析变体，那几首仍走异步——正确性不受影响，只是没吃到加速。实现阶段需抽查几首创始人真实 CJK 歌的磁盘键与播放键是否一致（用他的 lyrics_cache.json 验证，不猜）。

## 测试计划（实现时）

- CJK 原生 exact-key + 词级 → 直服（新绿）。
- 同一首歌的 romanized 输入（不同键）→ miss → nil（回落异步，不误服）。
- 不同歌但 normalized 标题偶同、时长差 >1.5s → 被时长门挡（miss）。
- 非词级 CJK 条目 → 不直服。
- 全部复用 Phase 1 的临时磁盘缓存注入缝，不碰用户真实文件。

## 风险登记（供把关）

| 风险 | 处置 | 残留 |
|---|---|---|
| romanized→CJK 错兄弟（006） | exact-key 天然排除（不同键即 miss） | 无 |
| 键碰撞 | SHA256 + normalized 标题/艺人/专辑三重 | 可忽略 |
| ±1 时长邻居跨接异曲 | 加 ≤1.5s 时长门 | 无（异曲必异标题=异键） |
| 写入用了解析标题 | 原生查询 miss → 异步 | 该曲仍 spinner，不错歌词 |

**请把关点**：exact-key=身份 的论证是否认可；时长门 1.5s 是否合适；是否要求实现时先用创始人真实缓存抽查键一致性。认可后我实现 + 测试 + 全绿再报。
