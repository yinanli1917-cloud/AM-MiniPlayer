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

---

## 技术把关回应（2026-08-25，采纳评审意见）

评审正确指出原"QED"过头（同专辑同名 clean/explicit 版若 normalize 剥版本注释则同键异词）。以下三条按评审补齐。

### (c) normalize() 对版本括注的实际处理 — 已核实
`MetadataDiskCache.normalize` = 小写 + 合并空白 + **仅剥 ASCII 标点字符**（保留 CJK/数字/非 ASCII）。它剥的是 `(` `)` 字符本身，**保留括注里的词**：`Song (Clean)`→`song clean`、`(Explicit)`→`song explicit`、`(Live)`→`song live`、`(2023 Remaster)`→`song 2023 remaster`——**版本词进入键、互相区分**。故评审担心的 clean/explicit 同键**不成立**（除非版本信息根本不在标题里、而在独立 tag，且专辑+时长也全同——见残留风险）。

### (a) 等价性上界（取代 QED，作主论证）
- **Phase 1（非 CJK）已满足**：异步即时路径（LyricsFetcher:643）用 `canUseImmediateCachedLyrics(lyrics, source, title: ot, artist: oa)` + `scorer.calculateScore`；我的 `immediateSyncedDiskLyrics` 用**完全相同**的 `canUseImmediateCachedLyrics` + 同一 candidates 查询 + 同一 scorer（synced-only 是更严的子集，不更宽）。→ Phase 1 的任何命中都是异步路径本就会返回的同一条目、过同一验证器；**Phase 1 不新增任何碰撞面，正确性以现状为上界**。
- **Phase 2（CJK）尚未满足，需细化**：异步路径**不经**即时 607 路径服务 CJK（非 CJK 门挡住），而是经**解析/native-title 桥**（LyricsFetcher:705 `metadataResolver.diskCache.get`→native title→`lyricsDiskCache.candidates(nativeTitle)`）或 source 专用 `lyricsDiskCache.get`（LyricsSourceFetchers:2654）。所以 Phase 2 CJK 的上界**不是**即时路径，而是**解析路径**。实现前必须让 Phase 2 的 native-exact 直服**套用解析路径服务该 CJK 曲时的同一组验证器**（不止 `canUseImmediateCachedLyrics` 去掉 ASCII 门），使其成为解析路径的严格子集（query 标题已是 native、省掉解析步，其余验证不减）。**这条是 Phase 2 实现的前置门槛，未达不实现。**

### (b) 创始人真实 lyrics_cache.json 只读抽查（数字）
对真实资料库 **1715 首**（219 CJK 标题/艺人，1496 非 CJK）重算键、比对 450 条磁盘缓存：
- **exact-key 碰撞（不同 normalized (title,artist,album,dur) 的库曲撞同键）：0 条。** 碰撞风险在真实库上经验为零。
- **CJK 键命中：14/219（6%）** ← Phase 2 能同步直服的比例。**modest**——多数 CJK 曲要么没播过缓存、要么缓存在异于 native 的键下。
- **非 CJK 键命中：58/1496（4%）** ← Phase 1 已覆盖。
- 同 title+artist 异时长的版本对：3 组，均**异专辑→异键**（如 自作多情 322s『冬日浪漫』vs 320s『真經典』），不碰撞。

**诚实结论**：整库命中率低（4-6%）主因是绝大多数库曲根本没播过缓存（450 条 vs 1715 首）；**修复真正受益的是"重播过、已缓存"的歌**（创始人"这首我看过歌词，怎么又转圈"的正是这类），整库比例低估了重播收益。但也不能排除部分已缓存曲因键漂移（时长/专辑/标题在写入与读取间不一致）而 miss——这与 #3 的键稳定性同源，是 Phase 2 之外可另查的点。Phase 2 的**正确性不受命中率影响**（miss→异步，绝不错歌词）。

### 残留风险（更新风险表）
| 风险 | 覆盖 | 残留 |
|---|---|---|
| clean/explicit/live 同键异词 | normalize 保留版本词→异键 | 仅当版本信息不在标题、且专辑+时长(±1)全同——真实库经验命中 0 |
| exact-key 碰撞 | 真实库实测 0 | 可忽略 |
| ±1 时长邻居跨接 | 加 ≤1.5s 时长门 + 异曲必异标题/专辑 | 无（3 组版本对均异专辑） |

**给把关**：(c)(b) 已完成，(a) 的 Phase 1 部分已满足、Phase 2 部分转为"实现前须套解析路径同验证器"的前置门槛。是否认可以此门槛推进 Phase 2 实现？鉴于 CJK 收益仅 6%，是否值得现在做、还是先排查键漂移（可能一并抬高 Phase 1/2 命中率）由你/创始人定。

---

## 键漂移归因（2026-08-25，评审优先项①，只读）

对**当前** lyrics_cache.json（实时快照 336 条；早前 450 是旧快照，app 在跑会 prune）逐条归因：

- **215/336（64%）可被库曲 native exact-key 触达**——即"84% 触达不了"是我早前把 forward(库曲→缓存) 与 reverse(缓存→库曲) 弄混 + 旧快照所致，**实际 64% 可达**。
- 不可达 121 条归因：
  - **45（37%）album 不在库**：电台/流媒体/已删，或从 AM 流播非库版（如 給我唱過的男孩們、軟硬聯盟）——**本就不是库曲，非 bug**。
  - **56（46%）条目无 album 字段**：无法按 album 归因（旧写入或无 album 的源）；是 not-in-library 与漂移的混合，缺 title/artist 无法细分。
  - **15（12%）时长漂移 >2s**：album 在库但时长对不上。
  - **5（4%）album+dur 匹配库曲但键 MISS**：真正的 title/artist 漂移 / 解析标题写入候选（例：EPO "Escape"、Tanya Chua "Deep"）。

**结论（修正评审假设）**：**"解析标题写入"并非大头（仅 5 条）**。不可达主因是"本就不是库曲"（45+部分56）与"从没播过缓存"（整库层面）。→ **写侧双键落盘只惠及 ~5 条，不划算，不建议**。64% 可达说明 Phase 1/2 的读侧预检对"已缓存的库曲"本就有效；创始人"看过又转圈"更可能是**该曲这次会话首次播放（内存缓存冷）**——而磁盘预检（Phase 1 非 CJK 已修 / Phase 2 CJK 待定）正是解这个的。真正剩余可优化的键漂移仅约 15(dur)+5(title)=20 条，性价比低，**不作为优先**。

**净建议**：键漂移不是大问题；Phase 2 维持读侧 native-exact 方案（前置门槛不变），但鉴于 CJK 收益仅 6%、漂移仅 ~20 条，**是否现在实现 Phase 2 交你/创始人按性价比定**；写侧双键否决。
