# 复现报告：2026-09-14 歌词管线四个缺陷

工作分支：`worktree-agent-af633cdb2495ca919`（原停在 277cd5b，已 fast-forward 到
main 当前 tip `a3d24b7`，见下方"方法论"一节）。
证据来源三路：(1) 创始人本机真实产出的
`~/Library/Application Support/nanoPod/lyrics_cache.json` /
`translation_cache.json` / `lyrics-backfill-census.jsonl`；(2)
`/tmp/nanopod_debug.log`（今天 17:52–20:56 本地时间的完整调试日志，`enableDebugFileLog`
已开，覆盖了创始人报告的全部三首歌真实播放）；(3) `swift run LyricsVerifier check
--dump`（debug 配置，`DEVELOPER_DIR=/Applications/Xcode.app`）与一个新写的真
Translation-框架集成测试。

## 方法论说明（先于结论）

worktree 起初停在 `277cd5b`（旧于 main），不含创始人点名的 6b34b7f / 4e3b59a /
a0397e5。已用 `git merge --ff-only a3d24b7` 快进到 main 当前 tip（worktree 分支
在此之前没有任何独有提交，fast-forward 是安全操作，非 reset）。所有下方结论均基于
`a3d24b7`（stage bundle 2 = 5e85f31 是其祖先）。

---

## 缺陷 1：翻译经常不出来

### 创始人看到的 ↔ 管线实际给出的

| | 创始人看到的 | 管线实际给出的（真实缓存/日志证据） |
|---|---|---|
| 现象 | 一首韩文歌整页无中文翻译 | `lyrics_cache.json` 中该歌词条目 **0/84 行有 translation 字段**（ts=2026-09-14 03:47:49 UTC） |
| 怀疑 | TranslationSession 跨曲复用，日语→韩语语言对不匹配静默失败 | **不成立**（见下方两组独立测试） |

### 复现结论：现象复现，但创始人的假设未复现；真根因是另一个、证据更硬的机制

**歌曲身份**：真实缓存内容与创始人截图逐字匹配（"All I know is now" / "알게 됐어
나" / "그동안 맨날"），经 `/tmp/nanopod_debug.log` 精确定位为 **NewJeans《How
Sweet》**（219s，非某首未知韩文歌）。

**创始人假设的两次独立证伪**：

1. 真实 Translation.framework 探针（`TranslationSession(installedSource:
   target:)`，本机 macOS 26，ja→zh-Hans 与 ko→zh-Hans 均 `.installed`）：
   用 JA 锚定的 session 直接喂 KO 文本，翻译成功（`"你好，世界"`），与全新 KO
   锚定 session 结果一致。session 复用跨语言**没有**静默失败。
2. 按创始人原话要求写的真集成测试
   `Tests/MusicMiniPlayerTests/LyricsServiceRealTranslationSessionReuseTests.swift`
   ——驱动真实 `LyricsService.performSystemTranslation`，同一个真实 session
   先译一首日语歌、再译一首取自 How Sweet 真实缓存内容的英韩混排歌，断言第二首
   非空翻译：**PASS**（`swift test --filter
   LyricsServiceRealTranslationSessionReuseTests`，1.36s，日语歌 3/3 行、混排歌
   有翻译）。session 复用跨语言这条路径本身是健康的。

**真根因（代码可证，日志实锤）**：`Sources/MusicMiniPlayerCore/UI/LyricsView.swift`
的 `.onChange(of: currentPage)`：

```swift
if newPage != .lyrics {
    ...
    translationPreflightTask = nil
    translationSessionConfigAny = nil   // 离开歌词页 → 会话配置清空
    ...
}
if newPage == .lyrics {
    ...                                  // 回到歌词页 → 没有任何地方重建配置
}
```

只有三处会重建 `translationSessionConfigAny`：`.onAppear`（进程内歌词页第一次挂载）、
`onChange(translationLanguage)`、`onChange(showTranslation)`。**单纯"离开歌词页
再回来"不在这三处之列**——一旦你离开过一次歌词页，`.translationTask` 被拆除，此后
`requestTranslation()` 只是把信号 yield 到一个没有消费者的 stream 上，翻译从此对
*任何歌* 都不会再出现，直到你手动切一次语言或开关一次翻译开关。

**回归判定**：这段 `newPage != .lyrics → nil` 的逻辑本身在 `e5a70c9`（阶段包 1）
就已存在，**不是新代码**。但触发它是否致命，前后不同：

- `e5a70c9`：`onChange(translationRequestTrigger)` 调用
  `scheduleTranslationRequest(after:trigger:)`，其内部会在延迟后判断
  `currentPage == .lyrics` 并**主动调用 `updateTranslationSessionConfig`**——
  也就是说，只要你回到歌词页后又换了一首歌（几乎每次都会发生），配置就会自愈重建。
- `a3d24b7`（含 6b34b7f/4e3b59a）：同一个 onChange 改成只调用
  `lyricsService.requestTranslation()`——纯粹入队，**不再重建配置**。A5 的
  commit message 自己说"removes the per-request session rebuild"，这正是为性能
  砍掉的那次重建，副作用是把原来的自愈路径也一起砍掉了。

**结论：这是 A5（6b34b7f + 4e3b59a）引入的回归**，机制与创始人猜的（session
跨曲语言不匹配）不同，但落点一致——都在"复用 session"这次改动里。

**真实日志实锤**（`/tmp/nanopod_debug.log`，本地时间）：全程 17:52–20:56
（约 4 小时、50+ 次换歌）里，`"🔄 Starting translation"` / `"✅ Translation
completed"` 只出现 **3 次**（84 行、4 行、8 行）。How Sweet 被完整播放/重访 4 次
（20:34:57 / 20:37:43 / 20:43:05 / 20:47:45），只有第 2 次（20:37:43，紧跟着一串
连续换歌，歌词页从未离开过）翻译成功；第 1、3、4 次（其中第 4 次正是创始人截图
那次，ts 对齐 03:47:49 UTC）**日志里连"开始翻译"都没有**——与"离开过歌词页后
永久失效"完全吻合。

**LyricsVerifier 对照**：`swift run LyricsVerifier check "Supernatural"
"NewJeans" 191 --dump` 里翻译 29/29 行全部成功——因为 verifier 没有"页面"概念，
不会触发这条回归，进一步印证问题出在 LyricsView 的页面生命周期管理，不在
翻译算法/评分本身。

---

## 缺陷 2：NewJeans《Supernatural》时间轴有误、跳行、无翻译

### 创始人看到的 ↔ 管线实际给出的

| | 创始人看到的 | 管线实际给出的 |
|---|---|---|
| 时间轴 | 中间跳过很多行，不是一一对应 | **NetEase 候选在 77.4s→140.6s 之间有 63.2 秒零歌词的空档**（`swift run LyricsVerifier check "Supernatural" "NewJeans" 191 --dump`：第 15 行 `77.4s "So it's sure"` 后直接跳到第 16 行 `140.6s "It's supernatural"`），191 秒的歌少了近三分之一 |
| 翻译 | 无 | 同缺陷 1 根因：真实日志显示 Supernatural 的两次真实播放（20:35:29、20:48:13）**都没有任何 "Starting translation" 日志** |

### 复现结论：两部分都复现；翻译部分与缺陷 1 同根因（回归）；时间轴部分是数据完整度问题，非本轮回归

**时间轴**：NetEase 候选本身缺失第二段主歌（真实缓存里另一次播放选中的 QQ 候选
在 82.69–136.94s 之间有完整的 15 行对应内容，NetEase 候选把这一整段跳过）。
这是 NetEase 该曲目 LRC 转写本身不完整，不是匹配到"错的歌"——`selectBest` 用
score=68.3 选中 NetEase 而非空 QQ 结果并不算错（QQ 那次网络查询直接没返回结果，
`found:false`），但这暴露一个更通用的问题：**评分公式对"中段大段静默"的覆盖率/
间隙惩罚不够狠**——68.3 分对一个丢了 63 秒内容的候选来说明显偏高。这属于打分
逻辑可以改进之处，但需要先跟创始人确认：这是否值得作为通用规则收紧（惩罚
`(gap / duration)` 超过某阈值的候选），还是接受"多源竞争总有优劣、QQ 那次没查到
纯属网络问题"。

**回归判定**：`git diff e5a70c9 a3d24b7 -- .../MetadataResolver.swift` 显示
a0397e5 改动的是"artist-only 标题关联"这条别名共识分支（用于跨语言标题翻译场景），
与 NetEase/QQ 候选池的抓取、评分完全无关；Supernatural 的匹配走的是 NetEase 自己
的 title+artist 精确匹配（P1，非 artist-only 分支）。**没有证据显示这是本轮回归**
——更可能是 NetEase 该曲目转写数据本身一直就不全，只是创始人这次恰好赶上了。

---

## 缺陷 3：eill《Plastic Love》先错配后纠正

### 创始人看到的 ↔ 管线实际给出的

| | 创始人看到的 | 管线实际给出的（真实日志两次真实写入，相隔 5 秒） |
|---|---|---|
| 第一次展示 | 先给了错配歌词 | `20:54:53` 磁盘缓存命中（source=NetEase, score=91.8, 26 行, **首句 "私のことを決して本気で愛さないで"**——这其实是歌曲中段副歌，不是开头） |
| 之后 | 过很久才莫名换成正确的 | `20:54:58`（仅 5 秒后）`Authoritative lyrics backfill HIT: NetEase 44L in 3.0s` → 重新应用为 45 行，**首句 "突然のキスや"**（歌曲真实开头）——伴随 `20:54:57 [MetadataResolver] 💿 album scoped resolve: 'Plastic Love'/'Plastic Love - Single' → 'プラスティック・ラブ'/'プラスティック・ラブ - Single' by 'eill'` |

### 复现结论：复现，机制清楚，判定为已有架构特性、非本轮回归

**机制**：前台快速通道（≤3s SLA）命中的是一个标题为罗马字 "Plastic Love"
的通用/歧义候选（NetEase 候选池里同时存在竹内まりや原唱、Night Tempo remix、
Friday Night Plans 翻唱等同名条目），拿到的 26 行版本缺失真正的开头段——这不是
"唱片版本选错"意义上的错配（词是对的，eill 翻唱用的就是原曲歌词），而是**首台
命中的转写本身从中段起录，丢了前 31 秒**。5 秒后，回填（backfill）跑了目录别名
桥（`MetadataResolver` 的 album-scoped 解析），发现 eill 这首歌在目录里真正的
条目是日文原题「プラスティック・ラブ」，用这个更准的身份重新查到 44 行、从头
开始的完整版本，热替换（`📊 Applied`）。

这个"前台先出可能不完整的结果、回填秒级纠正、热切换"是项目文档里已经记录的既有
设计（`postmortem/010-lyrics-alias-evidence-and-deadline.md`、CLAUDE.md 里
"目录别名共识桥"）。`git diff e5a70c9 a3d24b7` 里 album-scoped resolve 函数本身
**没有改动**。`swift run LyricsVerifier check "Plastic Love" "eill" 262 --dump`
（跑满整条管线再返回，不做前台/回填两阶段展示）直接给出正确的 37/38 行、首句
"突然のキスや"、`hasSyllableSync: true`——证实"错→对"只是真实 app 里"先给
反应速度、后给准确度"这个 UX 节奏本身可观察到的表现，不是选错了根本身份。

**回归判定**：机制代码本轮未改动，判定为**旧问题**（架构既有行为），不是
A2/A5/A6 引入的新东西。创始人报告的"过很久"实际测得是 5 秒，符合项目 A 规则里
"3 秒出原文、之后无缝补上"的设计意图——只是这次"补上"补的是从中段换到开头，
观感上像换了一份完全不同的歌词，比通常的"行级→逐字"热切换更显眼。

---

## 缺陷 4：普遍偏向行级、不是逐字

### 创始人看到的 ↔ 管线实际给出的

| | 创始人看到的 | 管线实际给出的 |
|---|---|---|
| 感觉 | 普遍偏向行级歌词而不是逐字 | How Sweet / Supernatural 两首经 `LyricsVerifier --dump` 与真实 census 均确认 `hasSyllableSync: false`（行级）；Plastic Love 反而是 `hasSyllableSync: true`（逐字） |

### 复现结论：部分复现（并非全面"偏向"），根因很可能是两大逐字源本轮会话内不可用，而非选择器逻辑本身偏行级

**关键证据**：`swift run LyricsVerifier check` 的 `allSources` 字段显示，
How Sweet / Supernatural / Plastic Love 三次独立运行里，**AppleMusic 与 AMLL
两个逐字源全部 `found:false`**。真实调试日志里：

- `"developer token"` 失败 **64 次**——`AppleMusicCapabilityLatch`
  的设计就是"首次 developer-token 失败后，整个进程生命周期内跳过 MusicKit"
  （`Sources/.../LyricsSourceFetchers.swift` 注释原文），也就是说本次真实会话里
  Apple Music（+12 分、逐字 TTML 第一方源）从头到尾都被自己闩死了。
- `"[AMLL]"` 标签在 29098 行日志里 **0 次出现**——但 AMLL 抓取函数本身没有
  `DebugLogger` 埋点（不像 NetEase/QQ/LRCLIB 那样每步都打日志），所以无法从日志
  区分"AMLL 真的被调用但没结果"还是"AMLL 这条链路本身没走到"。这是一个真实的
  埋点缺口，建议后续补一条 `DebugLogger.log("AMLL", ...)`，但本次时间预算内未能
  坐实。

在两大逐字源全程缺席的情况下，NetEase/QQ/LRCLIB（这三首歌的实际候选池）对这三首
流行曲目普遍只有行级 LRC，"选出来的结果偏行级"更像是**候选池本身的天花板**，
不是"逐字优先"裁决逻辑本身开倒车（`LyricsWordLevelPriorityTests` 覆盖的正是这条
裁决逻辑，行级候选确实会去 launch 回填找逐字源，回填日志里 `backfillOutcome:
"hit-rejected-no-demotion"` 也证实回填确实跑过、只是没找到更好的）。

**回归判定**：**未能定位到具体一次代码改动**导致的"变得更偏行级"；证据指向
"今天这台机器这次会话 Apple Music 认证失败 + AMLL 命中率存疑"这个环境/数据
可用性因素，而非评分/优先级公式的回归。若要坐实是否为回归，需要 AMLL 埋点
（见上）或在 e5a70c9 上对同样三首歌跑一次 network-only 对照——因为 LRCLIB/
NetEase/QQ 的候选池本身随时间波动（How Sweet 和 Supernatural 各自的两次真实
播放里 QQ 一次有结果一次没有），"同一份代码、不同时刻网络状态不同"这件事本身
就会让 A/B 对照很难干净——这点也如实列在"未做项"里。

---

## 未做项 / 局限

1. **缺陷 2 的评分间隙惩罚是否要收紧**：需要创始人先确认方向（阈值式收紧 vs
   接受现状），再决定是否动 `LyricsScorer`。
2. **缺陷 4 的 AMLL 埋点缺口**：未加日志前无法证明 AMLL 这次到底有没有被真正
   调用；也未做 e5a70c9 vs a3d24b7 的干净 network-only A/B（网络候选池本身随时间
   波动，四个缺陷里这条的信号最弱）。
3. **LyricsServiceTranslationSessionReuseTests.swift 测试脏写产线缓存**（发现于
   排查过程中，非本次四个缺陷之一）：该文件用 `LyricsService.shared` 真单例但
   没有把 `translationDiskCache` 重定向到临时文件，`swift test` 每次跑都会往
   `~/Library/Application Support/nanoPod/translation_cache.json` 写入
   `"译:hello world"` 垃圾行——实测该文件 82 条记录里 79 条是这个污染
   （仅 3 条是真实翻译）。按规矩不顺手修，只记录；本次新写的
   `LyricsServiceRealTranslationSessionReuseTests.swift` 已经用临时文件规避了
   同样的问题，可以作为以后修那个文件时的参照写法。

## 复现用命令记录

```bash
export DEVELOPER_DIR=/Applications/Xcode.app
swift run LyricsVerifier check "How Sweet" "NewJeans" 219 --dump
swift run LyricsVerifier check "Supernatural" "NewJeans" 191 --dump
swift run LyricsVerifier check "Plastic Love" "eill" 262 --dump
swift test --filter LyricsServiceRealTranslationSessionReuseTests
```

真实缓存/日志读取（只读，未修改）：
`~/Library/Application Support/nanoPod/lyrics_cache.json`、
`translation_cache.json`、`lyrics-backfill-census.jsonl`、`/tmp/nanopod_debug.log`。
