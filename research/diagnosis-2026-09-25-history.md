# 歌单页 History 完整性/准确性/及时性诊断 — 第一阶段（取证+复现，未修）

2026-09-25。worktree `agent-a83fe069b9898cb1e`（分支 `worktree-agent-a83fe069b9898cb1e`）。本阶段只加了一个新测试文件（`Tests/MusicMiniPlayerTests/PlaybackHistoryCompletenessDiagnosisTests.swift`）和这份文档，**没有改任何生产代码**。全程没有启动 nanoPod.app、没有跑 e2e_smoke.sh、没有控制 Music.app 播放、没有截图/录屏/computer use。创始人的真实 `playback-history.json` 全程只读。

---

## 1. 数据流（Music.app 事件 → 记录 → 落盘 → 显示，每步 file:line）

两个"确认换歌"入口，都最终调用同一个私有方法：

**入口 A：通知路径**
`MusicController.playerInfoChanged`（MusicController.swift:1184，DistributedNotificationCenter 收到 `com.apple.Music.playerInfo`）
→ `applyTrackMetadata`（:1411-1439）用 `notificationIndicatesTrackChange`（:1344-1353，PID 双方已知则按 PID 判定，否则按标题/艺人）算出 `trackChanged`，为真时立刻把 `currentTrackTitle`/`currentArtist` 改写成通知里的新值（:1428-1431）
→ `handleTrackChange`（:1445 起）：立即发艺术图/歌词请求（不等 SB），同时在 `metadataBridgeQueue` 上异步用 `SBTimeoutRunner.run(timeout: 1.5, lane: "trackMetadata")`（:1489）去 Music.app 读真正的 `persistentID`
  - 若 SB 读到的曲名和通知不一致（`sbName != name`，:1519）→ **直接 return，不记录**，转而强制 `updatePlayerState()` 整体刷新（:1520-1524）
  - 否则 → `self.recordPlaybackHistory(...)`（:1541 附近）

**入口 B：轮询/快照路径**
`MusicController.processPlayerState`（:2336-2370，scriptingBridgeQueue）用 `snapshotIndicatesTrackChange`（:1381-1408）算 `trackChanged`
→ 派到主线程 `applySnapshot`（:2373）
→ `trackChanged` 为真时改写 `currentTrackTitle`/`currentArtist`（:2401-2404），随后 `recordPlaybackHistory(...)`（:2452 附近）

**记录本身**
`recordPlaybackHistory`（MusicController.swift:887-899）→ `PlaybackHistoryEntry.make(...)`（PlaybackHistoryStore.swift:66-92）按 PID 前缀/是否 URL track 派生 `sourceKind`
→ `playbackHistoryStore.record(candidate, now:)`（PlaybackHistoryStore.swift:177-184）
  - `shouldRecord`（:160-171）去重：PID 与"紧邻上一条"相同则跳过；双方 PID 都空且标题/艺人相同且 3 秒内也跳过
  - 插入 index 0，`capacity`=50（:105）满了就砍尾（:180-182）
  - `scheduleWrite()`（:204-211）1 秒防抖（`debounceInterval`=1.0，:106），到点 `performWrite()`（:213-221）`JSONEncoder().encode(entries)` 原子写到 `defaultDirectory`（:127-132）= `~/Library/Application Support/nanoPod/playback-history.json` —— **这个路径完全没经过 `NanoPodCacheLocation`**（对照 LyricsDiskCache/MetadataDiskCache/TranslationDiskCache 都经过）
→ `playbackHistory = playbackHistoryStore.entries`（MusicController.swift:898）republish 到 `@Published playbackHistory`（:200）

**显示**
`PlaylistView.displayedPlaybackHistory`（PlaylistView.swift:393-398，纯计算属性，每次 body 求值都重新算，不缓存）
→ `PlaybackHistoryDisplayPolicy.displayed`（PlaylistRowActivityPolicy.swift:53-63）：`currentPersistentID` 非空时，`history.filter { $0.persistentID != currentID }`（:61）—— **过滤条件是"PID 等于当前"，不是"是不是最新一条"**
→ `ForEach(displayedPlaybackHistory)`（PlaylistView.swift:161-178）→ `PlaylistItemRowCompact`（:756 起）
  - 行内艺术图抓取用 `.task(id: RowArtworkTaskKey(persistentID:, visible: RowArtworkVisibilityPolicy.shouldFetch(currentPage:)))`（:914-920），只有歌单页可见时才真正 `loadArtwork()`——这一层 2026-09-15 已修好、本次复核确认仍然生效，没有回归。

`MiniPlayerView.swift:98-101` 确认 `PlaylistView` 用 `.opacity`/`.zIndex`/`.allowsHitTesting` 切页，从不销毁重建；`@EnvironmentObject` 在任意 `@Published` 写入时都会让整个 `body` 重新求值（`PlaylistViewRenderChurnTests.swift` 文件头已有实测：20 次无关写入 → 20 次 body 求值），所以 History 底层数据一变，展示层理论上必跟着变——第 3 节 H7 会说这条链路穷举后没找到反例。

---

## 2. 证据表：真实文件 vs Music.app 真值

### 2.1 真实文件现状（只读）

`~/Library/Application Support/nanoPod/playback-history.json`：50 条，9784 字节（**195.68 字节/条**，`ls -la` + `wc -c` 实测），最后写入 2026-09-25 02:10。50 条覆盖 **2026-09-23 19:25:34 → 2026-09-25 02:10:36，共 30.75 小时**（Python 解码 `startedAt`，Apple 参考纪元 2001-01-01 UTC 换算本地时间后实测）。全部 `sourceKind=library`；31 个不同 `persistentID`（有重复播放）。

### 2.2 Music.app 真值（一次有界只读 osascript 查询）

命令：built `/private/tmp/.../scratchpad/query_ground_truth.applescript`（日期对象在 `tell application "Music"` 外部构造，避免 Music.app 自己的字典把标准 AppleScript 的 `year of/time of` 遮蔽掉报 "Unknown object type" -1731；返回变量不能叫 `result`，AppleScript 里这是每条语句执行后自动刷新的隐式变量，命名冲突会让最终返回值被清空——两个坑都是这次现场踩出来的，记在这里防止下次重犯），过滤条件 `every track of library playlist 1 whose played date is greater than cutoff`，`cutoff` = 2026-09-23 18:00:00 本地（早于文件最老一条 1.5 小时留余量）。全程只读 `persistent ID/name/artist/played date/played count/duration`，未改任何曲目属性，未控制播放。Bash 超时 150s，实际数秒完成。

结果：全库 **1719** 首曲目，窗口内 `played date` 命中 **10** 首。

| 歌曲 | 艺人 | Apple played date（本地） | Apple 全时 played count | nanoPod 窗口内出现次数 | 结论 |
|---|---|---|---|---|---|
| New Precious World | Ami Ozaki | 09-23 19:25:34 | 2 | **0** | **确认漏记**，见下 |
| Gatsby Woman (2020 Remastered) | Kingo Hamada | 09-23 19:21:52 | 1 | **0** | **确认漏记**，见下 |
| It is the Hour | Hebe Tien | 09-23 19:17:25 | 2 | 1（01:53:53，同 pid/duration） | **时间矛盾，未定论**，见下 |
| This Time | Jeff Bernat | 09-23 22:29:58 | 12 | 1 | 一致（该曲明显是老歌，大部分播放在窗口外） |
| Winter Solstice | Karen Mok | 09-25 02:10:36 | 6 | 5 | 数量大致吻合，但内含明显"秒切"噪声，见 H5 |
| Roses | Mac Ayres 等 | 09-25 02:15:09 | 5 | 5 | **数量完全吻合**，但也内含"秒切"，见 H5 |
| Ring Around the Rosie | Michael Seyer | 09-24 17:49:08 | 3 | 3 | 一致 |
| Ocean Side | Momoko Kikuchi | 09-24 17:46:27 | 4 | 4 | 一致 |
| Damn | Bad Sweetheart | 09-25 01:53:53 | 3 | 1 | 一致（大部分播放在窗口外） |
| 谁为我等 | 彭羚 | 09-25 02:02:25 | **1** | **3**（17:30:53 / 01:57:13 / 02:04:11，每次中间都隔了别的歌，不是去重漏洞） | **Apple 反而少算**，与 It is the Hour 同一种矛盾 |

**两条确认漏记**：Gatsby Woman（19:21:52）和 New Precious World（19:25:34）都不在 nanoPod 的 50 条里，且都**恰好紧邻 nanoPod 当前最老一条**（19:25:34 "Mc's Road De Aimasho"）之前——New Precious World 的 played date 和这条最老记录的 `startedAt` 秒级重合，说明它大概率本来就被记录过、只是随环形缓冲被挤出了当前 50 条的窗口。这是**容量边界坐实的证据**（对应 H8），不是并发/竞态类 bug 的证据。

**一条时间矛盾**：It is the Hour 与 谁为我等 都是 nanoPod 记的次数 ≥ Apple 的 played count/date 反映的次数，且 It is the Hour 那次中间隔了 3 分 20 秒才切下一首（不是秒切）。说明 **Apple Music 自己的 played date/played count 在这台机器上不总是随每次真实播放更新**——两个独立例子指向同一方向，这让"拿 Apple 的计数当满分基准"本身不可靠。本次证据不足以判定 Apple 的确切规则，留作开放项，不归咎 nanoPod。

**一处高频切歌实况**：今天（09-25）02:03:38–02:04:15 的 38 秒内，`/tmp/nanopod_debug.log`（`defaults read com.yinanli.nanoPod enableDebugFileLog` = 1，创始人早已开着；只读确认，未修改）里连续出现 **9 次** `🎵 Track changed (notification):`（Roses→Ocean Side→Roses→Ring Around the Rosie→Ocean Side→Roses→Winter Solstice→谁为我等→Winter Solstice），平均 4.2 秒切一首，其中 02:03:55 那一秒notification 路径（Ocean Side）和快照路径（Roses）**同一秒都判定"换歌"**。这段与创始人当时正在用这台机器听歌的说明吻合（很可能是他在快速翻找/连按下一首），是"高频切歌"这个前提在真实场景里发生的第一手证据，不是我编的场景。

全日志范围内（覆盖到至少前一天 18:37）：
- `grep -c "SB track mismatch"` = **0**——H3 假设里那个具体的字面触发分支，今天一次都没触发过，即使在上面那段高频切歌突发里也没有。
- `grep -c "timeout"` 相关 = 45，但全部是 artwork/position 两条 lane，**没有一条 `lane="trackMetadata"`**——H4 假设的具体前提（SB 曲目元数据读取超时）今天也没被现场观测到。

这两条"0 次现场命中"很重要：说明 H3/H4 描述的机制在**结构上**是真实存在的漏洞（下节会用真实生产代码 100% 复现），但触发门槛比字面推测的更窄，不能不加限定地说"这就是创始人这次抱怨的直接原因"。

---

## 3. 每个机制的状态

### H1 — 展示层过滤隐藏同 PID 的全部历史，不只最新一条：**已复现**

测试 `PlaybackHistoryDisplayFilterCompletenessTests.test_repeatPlay_earlierPastPlayOfCurrentSong_mustStayVisible`，红：
```
XCTAssertTrue failed - the EARLIER, already-finished play of Song A must remain in History —
only the row that duplicates the current Now Playing card (the newest Song A entry) should
be hidden. Got: [("Song B", 1970-01-01 00:33:20 +0000)]
```
`PlaybackHistoryDisplayPolicy.displayed` 用 `$0.persistentID != currentID` 把**所有**匹配当前 PID 的历史行都滤掉，不只是"重复了 Now Playing 卡片"的那一条。A→B→A 场景下，更早那次 A 的播放记录整条消失。

### H2 — 非生产进程/多进程共享同一份真实文件，后写者赢：**已复现**

测试 `PlaybackHistoryMultiProcessCollisionTests.test_twoStoresSameDirectory_secondWriterSilentlyDiscardsFirstWritersEntry`（临时目录模拟两进程，全程未碰真实 Application Support），红：
```
XCTAssertTrue failed - process A's entry must survive on disk even though process B wrote
afterward — got only: ["FROM_PROCESS_B"]
```
根因：`PlaybackHistoryStore` 在内存里维护自己那份完整 `entries`，`performWrite()` 每次都整体覆盖磁盘文件；两个进程各自的内存快照互不知情，谁最后写谁赢，之前写的那份被整体丢弃——不是"合并丢字段"，是"整份丢弃"。

`MusicController.swift:262` 的 `private let playbackHistoryStore = PlaybackHistoryStore()` 用的是全默认构造（真实 clock、真实主队列 scheduler、真实文件写、且 `defaultDirectory` 完全不经过 `NanoPodCacheLocation`）——是本仓库**唯一**没做这层隔离的磁盘缓存（Lyrics/Metadata/Translation 三个磁盘缓存都经过）。

补充安全性核查（用 ARC 语义静态分析，没有真的跑这个有风险的现有测试）：现有 `PlaybackHistoryWiringTests.test_clearPlaybackHistory_emptiesPublishedHistory` 会构造一个 `MusicController(preview: true)`，其属性初始化器仍会无条件跑出一个指向真实目录的 `PlaybackHistoryStore()`；调用 `clearPlaybackHistory()` 会对着从真实文件加载的非空 `entries` 触发 1 秒防抖真实写。但 `scheduleWrite` 的闭包是 `[weak self]`（self 指 `PlaybackHistoryStore` 实例），而该测试方法是纯同步代码、无任何 `await`/等待，函数一返回 `controller`（进而它持有的 store）就应被 ARC 立即释放——防抖到期时 `weak self` 大概率已是 nil，`performWrite()` 不会真的执行。这是"侥幸安全"，不是设计保证：真正会踩雷的是**两个真的操作系统进程同时跑**（创始人真身 + 误开的第二份 app、旧构建、或将来某个忘记覆盖 `NANOPOD_CACHE_DIR` 的工具）——这正是上面单元测试复现的场景。

### H3（模型级）— 通知/快照交错导致某次切歌完全漏记：**纯函数模型下已复现；今天真实日志里该具体分支 0 次命中**

`MusicController` 两个确认点没有可注入缝（`PlaybackHistoryWiringTests.swift` 自己的头注释已说明："driving them directly would require a live Music.app"）。本测试没有发明新逻辑，而是用 MusicController **真实**导出的静态纯函数（`notificationIndicatesTrackChange`、`snapshotIndicatesTrackChange`）按生产代码同样的调用顺序搭一个最小状态机（文件内逐行注了对应的 MusicController.swift 行号）。

测试 `PlaybackHistoryNotificationSnapshotRaceModelTests.test_rapidDoubleSkip_sbMismatchOnFirstTrack_dropsItEntirely`，红：
```
XCTAssertTrue failed - Track A was a real, confirmed (if brief) track change nanoPod's own
notification handler received — it must still get a History row, even though its SB
persistentID read lost the race. Currently it never does: got only ["Track B"]
```
机制：通知先到 A（`applyTrackMetadata` 已把 `currentTrackTitle` 改成 A），A 的 SB 异步读还没回来，Music.app 已经真的切到了 B；A 的 SB 完成回调发现"实际曲目"是 B（`sbName != name`，MusicController.swift:1519），直接 return，**A 从未被 recordPlaybackHistory**；随后被迫的整体刷新读到 B，B 正常入账。结果：A 这次真实发生过的切歌，在 History 里彻底消失，不留痕迹。

现实语境：`grep -c "SB track mismatch"` 在今天全部日志（覆盖到前一天 18:37 之后）里是 **0**，即便在 02:03:38-02:04:15 那段 9 次/38 秒的真实高频切歌里也没触发。说明这条分支在结构上成立，但触发门槛（SB 1.5 秒窗口内被后一次通知反超）比字面推测更窄——今天的真实高频切歌似乎每次 SB 都还是跟上了。

同一批数据里还有一个**确定性回放、证明"不是 bug"**的负面对照：测试 `test_realCapture_20260925_rosesRapidReDetection_correctlyDeduped`（绿），直接回放今天日志里 02:03:55 那次快照路径对 Roses 的重复探测（离上一条 Roses 记录只有 17 秒）——`shouldRecord` 的"PID 与紧邻上一条相同则跳过"规则正确吸收了它，没有产生重复记录。**不是每种交错时序都会丢/多**，需要精确到具体分支。

### H4 — SB 解析超时误判为电台/流，随后真 PID 到手又记一条：**已复现（100% 用真实生产代码，不依赖时序）**

测试 `PlaybackHistorySBTimeoutDoubleRecordTests.test_sbTimeoutThenRealPID_recordsTheSamePlayTwice`，红：
```
XCTAssertEqual failed: ("2") is not equal to ("1") - one physical play of one song must
produce ONE History row, not two ("" then the real PID) — got
[("Real Library Song", "E6CA87B2C0269A9C", library), ("Real Library Song", "", radioOrStream)]
```
机制：`handleTrackChange` 的 SB 读超时（`SBTimeoutRunner.run(timeout: 1.5, lane: "trackMetadata")`，MusicController.swift:1489）时用 `?? (persistentID: "", ...)` 兜底（:1508），`PlaybackHistoryEntry.make` 把空 PID 的库内曲目也分类成 `.radioOrStream`；下一次轮询拿到真 PID 再记一次时，`shouldRecord` 只在 PID 与"紧邻上一条"**相等**时才去重，`"" != "E6CA..."`，两条都留下。这一步不依赖任何多线程交错，只要 SB 曾经超时过，用真实 `PlaybackHistoryStore`/`PlaybackHistoryEntry.make` 直接调用就能稳定复现。

现实语境：今天 45 次 timeout 全部是 artwork/position lane，没有一次是 `trackMetadata` lane——今天没被现场观测到，但机制本身不依赖运气，一旦真的发生 SB 超时就会触发。

### H5 — "什么才算播放过"：**证据已收集，不拍板，见第 6 节**

### H6 — Spotify 播放是否进 History：**已排除（不是"没有 bug"意义上的排除，是"功能未接线"）**

`grep -rln "PlaybackSourceRegistry\|SpotifyPlaybackSource" Sources/ Tests/` 只命中它们自己（`Services/PlaybackSource/PlaybackSourceRegistry.swift`、`Services/PlaybackSource/Spotify/SpotifyPlaybackSource.swift`、`Services/PlaybackSource/Spotify/SpotifyScriptingReader.swift`）和各自的测试文件（`SpotifyPlaybackSourceTests.swift`、`AppleMusicPlaybackSourceTests.swift`）——**`MusicController.swift` 全文零引用**。`MusicController` 只监听 `com.apple.Music.playerInfo` 这一个 DistributedNotificationCenter 通知、只对 Music.app 做 AppleScript 轮询，对 Spotify 毫无感知通道。`PlaybackSource` 协议家族（`PlaybackSource.swift` 头注释自己写着"Apple Music 是第一实现…第三方源…留待裁决后再接"）是准备好但还没接线的抽象层。结论：Spotify 播放目前 100% 不会进入 nanoPod 的 History，这是产品范围问题，不是记录逻辑的缺陷。

### H7 — 及时性（渲染去抖/缓存/身份键让 History 显示滞后）：**穷举未复现**

已检查、均未发现缓存/去抖层：
- `displayedPlaybackHistory` 是纯计算属性（PlaylistView.swift:393），每次 body 求值都重新算，没有 `@State`/memo 缓存。
- `PlaylistView` 用 `.opacity`/`.zIndex` 切页（MiniPlayerView.swift:98-101），从不被销毁重建（不是 `if currentPage == .playlist { PlaylistView() }` 这种条件渲染）。
- `@EnvironmentObject` 在**任意** `@Published` 写入时都会让整个 `body` 重新求值——`PlaylistViewRenderChurnTests.swift` 文件头已有实测（20 次无关写入 → 20 次 body 求值），本次复核了这个结论仍然成立，两处 `recordPlaybackHistory` 调用都直接在主线程闭包里写 `@Published playbackHistory`，没有额外队列跳转。

冷启动场景单独验证：`currentTrackTitle` 默认值是 `kNotPlayingSentinel`（MusicController.swift:175），`isValidTrackDisplayName` 判它无效，`snapshotIndicatesTrackChange` 的"poisoned-display heal"分支（:1396-1398）让第一次快照必定判定为换歌——"app 启动时已在放的歌"会被记录，不是缺陷，与既有测试 `test_snapshot_launchSentinel_isAChange` 结论一致。

"Music.app 中途退出重开"/"睡眠唤醒"没有做到同等深度（没找到直接证据，也没找到反例），列入第二阶段矩阵，不在本阶段下结论。

若创始人今后真的目睹 History 显示滞后于实际播放，建议埋点（当前完全没有针对 History 记录/跳过决策的日志——`recordPlaybackHistory`/`PlaybackHistoryStore.record`/`shouldRecord` 里目前一行 DebugLogger 调用都没有，这是本次取证过程里唯一没法靠日志直接印证 H3/H4 具体触发次数的原因）：在 `recordPlaybackHistory` 记录/跳过分支各打一行 `DebugLogger.log("History", ...)`（候选 vs 记录/去重跳过），以及 `PlaylistView.displayedPlaybackHistory` 每次求值打一行时间戳+条目数，对照真实操作时间就能直接定位，不用再靠事后翻两天份不带日期的日志做考古。

### H8 — 容量 50 条的时间窗对"完整"不够：**已用真实数据坐实，是设计参数问题，不是并发/竞态 bug**

50 条实测 195.68 字节/条，只覆盖 30.75 小时（第 2 节实测数字）。两条确认漏记（Gatsby Woman、New Precious World）都恰好卡在当前最老一条紧邻之前，与容量边界完全吻合——这是本次证据链里对"不完整"最直接、最无歧义的解释。

---

## 4. 修复设计（第二阶段实现；mini 约束逐条满足）

不在本阶段改代码，先把方向和取舍写清楚：

1. **`playback-history.json` 路径经过 `NanoPodCacheLocation`**（照抄 Lyrics/Metadata/Translation 三个缓存已用的模式）。核对过：`NanoPodCacheLocation.directory(for: .production, ...)`（NanoPodCacheLocation.swift:100-101）算出来的路径和 `PlaybackHistoryStore.defaultDirectory` 今天算出来的完全一样——**这个改动不会挪动创始人的真实文件**，只隔离 XCTest/dev build/worktree 这些非生产进程。顺带用 `versionedFileURL`+`legacySeedURL`（NanoPodCacheLocation.swift:136-147，既有模式）做一次性迁移读旧文件名，不用创始人手动搬家。修 H2。
2. **展示过滤只隐藏"当前播放那一条"，不隐藏同 PID 的历史行**：`PlaybackHistoryDisplayPolicy.displayed` 改成只排除 `history.first`（当它的 PID 等于 currentPersistentID 时），而不是过滤全部匹配 PID 的条目。修 H1。
3. **SB 超时的空 PID 条目，等真 PID 到手后"原地打补丁"而不是再插一条**：`shouldRecord`/`record` 的逻辑改成——如果紧邻上一条是同标题+同艺人、PID 为空、且在一个短窗口内（例如 SB 超时的 1.5 秒 + 轮询间隔的合理余量），新来的真 PID 记录去更新那一条的 `persistentID`/`sourceKind`，而不是新插一行。不额外占用环形缓冲的槽位，天然 mini-友好。修 H4。
4. **H3 的"整通道丢弃"改成"乐观先记、后补 PID"**：SB mismatch 触发的整体刷新，不必让 A 完全消失——通知本身已经是"确认换歌"的证据，可以在通知时刻就用标题/艺人乐观记一条空 PID（复用第 3 点的补丁机制，PID 之后解析到就地补，解析不到就以空 PID 留存）。这样 H3 和 H4 共享同一个"先记后补"设计，不引入两套并行机制。**这一步会让 History 行短暂只有标题没有 PID/来源判定**（行内 artwork 兜底逻辑要认这种过渡态)——这个取舍要不要,第 6 节留给创始人过一遍再定，不在这里直接拍板。
5. **容量从 50 提高**：见第 6 节证据与推荐默认值，具体数字创始人定。字节开销是线性的（见下），不需要额外机制去限制文件大小——条目数上限本身就是文件大小上限。
6. **加载有界**：`load()`（PlaybackHistoryStore.swift:195-202）目前直接 `Data(contentsOf: fileURL)` 整读再解码，没有任何大小检查。改成：解码前先用 `FileManager.attributesOfItem(atPath:)[.size]` 读文件大小（不读内容），超过一个远高于合法上限、但远低于病态大小的门槛（例如 512KB——按新容量算的合法文件通常在几十到二百 KB 量级，512KB 已经是好几倍余量）就直接当损坏处理（`entries = []`，和现有 `test_corruptFile_loadsAsEmpty` 同一套恢复路径），不去碰文件内容，也不主动覆盖它（只有之后真的发生新的 `record()`/`clear()` 才会触发防抖写，不会因为加载失败就抢先把可能还能救的原文件清空）。
7. **行挂载成本、页面不可见零行级工作**：这两条本次复核确认**现有代码已经做对**（`RowArtworkVisibilityPolicy.shouldFetch`+`.task(id:)` 双重门，`RowArtworkFetchGate`/`RowArtworkNegativeCache` 并发上限与退避），第二阶段任何改动都要保持这个不变式，不能因为提高容量或改去重逻辑而在行级引入新的 SB/网络调用。
8. **单次防抖写**：现有 `scheduleWrite`/`performWrite` 的 generation 机制（PlaybackHistoryStore.swift:204-221）已经是"只有最后一次调度真正落盘"，第二阶段不需要重新设计，只需要在新增的补丁写路径（第 3/4 点）里复用同一个 `scheduleWrite()` 入口。
9. **"什么算播放过"的最短播放门槛**：在 `record()` 前加一道判断（不是展示层过滤），具体阈值见第 6 节。
10. **埋点**：`recordPlaybackHistory` 记录/跳过分支、`PlaylistView.displayedPlaybackHistory` 求值处，各加一行 DebugLogger（见第 3 节 H7 末尾）——这条独立于以上修复，任何时候都能先落地，成本很低。

---

## 5. 压力/边界测试矩阵（第二阶段实现用，每条给通过阈值）

| # | 场景 | 状态 | 通过阈值 |
|---|---|---|---|
| 1 | 假时钟 10ms 步长连续 1000 次确认换歌 | 待写 | 条数 ≤ 容量上限；防抖后**恰好一次**落盘（`writeHook` 调用次数 = 1）；单次 `record()` 主线程耗时 < 1ms（纯内存数组操作，≤ 容量个小 struct，无 I/O——`record()`本身不含磁盘/网络调用，此阈值按这个事实推算，非实测） |
| 2 | 10 万次记录 soak（假时钟，禁真实长跑计时器） | 待写 | `entries.count` 全程 ≤ 容量上限，不增长；`writeHook`收到的字节数每次都 ≤ 容量×~200B（按 H8 实测 195.68B/条估算的上界） |
| 3 | 启动遇到损坏/截断/超大文件（20MB / 20 万条） | 待写（需先落地第 4 节第 6 点的大小检查） | 加载判定（含文件大小检查）耗时 < 100ms；优雅恢复=`entries`为空、不 crash；不把垃圾回写（只有后续真实 `record()`/`clear()` 才触发写，加载失败本身不写） |
| 4 | 同一文件两个 store 实例 | **本阶段已复现**（`PlaybackHistoryMultiProcessCollisionTests`） | 双方各自记录的条目修复后都不丢 |
| 5 | A→B→A | **本阶段已复现**（`PlaybackHistoryDisplayFilterCompletenessTests`） | 两次 A 的记录都在 History 展示列表可见，只隐藏"当前播放"那一条 |
| 6 | 单曲循环 | 待写（逻辑上被现有"同 PID 与上一条相同则跳过"规则覆盖，需要专门测试钉死不回归） | 同 PID 连续循环只记一条 |
| 7 | 同曲 seek 回 0 | 待写（未找到现有测试直接覆盖这个精确组合） | seek 不产生新 History 记录（PID/标题/艺人都未变，两个 `*IndicatesTrackChange` 都应判 false） |
| 8 | 电台标题抖动 | 待写（现有 `RadioTrackChangeDebounceTests` 只钉死"是否算换歌"，没钉死"History 是否被污染"） | 复用两次一致读数才确认换歌的规则，History 不因抖动产生多余记录 |
| 9 | SB 超时后快照带真 PID | **本阶段已复现**（`PlaybackHistorySBTimeoutDoubleRecordTests`） | 记 1 条，不是 2 条（修复后：原地打补丁） |
| 10 | 快速切歌时通知与轮询两种先后顺序 | **本阶段已复现一种顺序**（`PlaybackHistoryNotificationSnapshotRaceModelTests`） | 两种顺序下，每次真正发生过的"确认换歌"至少产生 1 条记录（允许合理去重，不允许整条消失） |
| 11 | app 在歌曲中途启动 | **本阶段已用代码+既有测试验证非缺陷**，第二阶段补一条集成级回归钉死结论 | 冷启动时的当前曲目必须成为 History 第 1 条 |
| 12 | Music.app 中途退出重开 | 未验证（未找到直接证据，也未找到反例） | 重开后新曲目被记为一次换歌，不漏记也不重复记 —— 需要先确认 `applyNoTrack()` 后 `currentTrackTitle` 是否回落到 sentinel，若是，理论上被同一套 poisoned-display heal 覆盖，需要专门测试而非假设 |
| 13 | 系统时间回拨 | 未验证 | 不崩溃、不丢数据；顺序按插入顺序而非要求对 `startedAt` 重排（明确不承诺强一致时间排序） |
| 14 | 有待写入时清空历史 | 现有 `test_clear_emptiesEntriesAndSchedulesWrite` 覆盖基本情形；本次代码读确认 generation-guard 设计正确 | 第二阶段补一条"pending write + 立即 clear"专门时序，确认只落盘一次且是清空后的状态 |
| 15 | 歌单页不可见期间 100 次换歌后再显示 | 待写（`RowArtworkFetchGate.currentCountForTesting()` 已是现成的断言点） | 100 次期间 `currentCountForTesting()` 恒为 0，没有 SB 调用；再次可见后展示的是最新列表，不是陈旧快照 |

---

## 6. 给创始人的开放产品问题

**1. "什么算播放过"要不要引入最短播放时长/比例门槛？**

已核实的行业证据：
- Last.fm 官方 scrobble 规则（<https://www.last.fm/api/scrobbling>，本次 WebFetch 已取原文验证）：**"The track must be longer than 30 seconds"** 且 **"The track has been played for at least half its duration, or for 4 minutes (whichever occurs earlier)"**。
- Spotify 官方 Web API 文档（`developer.spotify.com/.../get-recently-played`，本次 WebFetch 已核实）：**未公开**任何"recently played"计入门槛——坊间流传的"30 秒算一次播放"是关于版税结算的说法，本次没能找到 Spotify 官方来源佐证，**标"未证实"，不采信**。
- Apple Music/Music.app 的 played count/played date 更新门槛没有查到官方文档（**未证实**）；本次实测拿到的信号是矛盾的——Roses 那几次 20-30 秒的快速切歌全部被 Apple 计入了 playedCount，但 It is the Hour 播了 3 分 20 秒却没让 played date 前移。样本太小（1719 首库里只抽样验证了 10 首），不足以反推 Apple 的规则。

推荐默认值：参照 Last.fm 公开规则定一个宽松版本（例如 ≥20 秒 或 ≥30% 时长，取更早者），跳过更短的快速切歌不计入 History——但具体数字是产品判断，这里只给证据和一个可执行的起点，不代创始人拍板。

**2. 容量/时间窗要设多少？**

字节开销是线性的、已实测：50 条 = 9784 字节 = **9.55KB**（195.68 字节/条）。按同样的每条开销推算：200 条 ≈ 38.2KB，300 条 ≈ 57.3KB，500 条 ≈ 95.5KB，1000 条 ≈ 191.1KB——对"mini"而言，即使放大 10-20 倍也就是几十到二百 KB，不构成体积负担；真正的取舍是"History 列表要滚动多长"这个 UI 可用性问题，不是磁盘开销问题。

按实测 30.75 小时 50 条换算，日均约 39 次确认换歌（含被 H5 门槛会过滤掉的快速切歌噪声——加了最短播放门槛之后这个日均数字会下降,但本次没法反推下降到多少,因为不知道全部真实切歌里有多少是快速跳过）。若目标是"覆盖至少一周日常使用"，按当前（未过滤噪声的）日均估算需要约 273 条；建议 300 条上限（≈57.3KB）作为起点，但最终数字请创始人定——尤其在门槛 1 落地之后，同样的容量能覆盖的真实天数会变长，两个决定最好放在一起看。

**3. H3/H4 共用的"先乐观记、后补 PID"修复方向,要不要？**

好处是 A（快速切歌里被 SB 竞速甩掉的那一半）不会再完全消失；代价是这类 History 行会有一段短暂的"只有标题/艺人，没有 PID"过渡态（期间行内点击跳转、艺术图来源判定都要认这种半成品状态,详见第 4 节第 4 点）。这个取舍值得创始人过一遍再定，本阶段没有直接拍板。

---

## 附：本阶段产出文件

- 复现测试（新增，未改任何生产代码）：`Tests/MusicMiniPlayerTests/PlaybackHistoryCompletenessDiagnosisTests.swift`
  - 4 red + 1 green，全部跑通确认（`swift test --filter` 串行跑完，见下方摘要）：
    - `PlaybackHistoryDisplayFilterCompletenessTests.test_repeatPlay_earlierPastPlayOfCurrentSong_mustStayVisible` — RED（H1）
    - `PlaybackHistoryMultiProcessCollisionTests.test_twoStoresSameDirectory_secondWriterSilentlyDiscardsFirstWritersEntry` — RED（H2）
    - `PlaybackHistoryNotificationSnapshotRaceModelTests.test_rapidDoubleSkip_sbMismatchOnFirstTrack_dropsItEntirely` — RED（H3 模型级）
    - `PlaybackHistoryNotificationSnapshotRaceModelTests.test_realCapture_20260925_rosesRapidReDetection_correctlyDeduped` — GREEN（真实数据回放，排除一种"不是 bug"的交错）
    - `PlaybackHistorySBTimeoutDoubleRecordTests.test_sbTimeoutThenRealPID_recordsTheSamePlayTwice` — RED（H4）
- 本文档：`research/diagnosis-2026-09-25-history.md`

本阶段到此为止，等待确认后再进入修复实现。

---

## 第二阶段实现结果（2026-09-25，同日）

第一阶段审过后，按主会话拍板的设计做了实现，非拍脑袋部分（第 3 条容量）已实测定数字。以下只记结果，完整取舍见主会话回复。

**机制**：记录管线改成「待定播放（PendingPlaybackAccumulator）→ 达标入账」——确认换歌立刻开一条待定播放（通知路径在发 SB 读之前就开，H3 不再靠竞速窗口窄侥幸躲过，而是结构性不丢）；PID 晚到原地打补丁，不管补丁发生在入账前还是入账后都不会插第二行（H4）；实际播放时长（暂停不计）达到 `MusicController.minimumListenSecondsForHistory`（默认 10 秒，0 = 旧行为）或播到自身更短的自然结束才入账，入账那一刻立刻写，不等下次切歌（app 中途退出不丢）；展示层只隐藏 `history.first` 这一条，不再按 PID 广泛过滤（H1）。

**H2**：`PlaybackHistoryStore` 改走 `NanoPodCacheLocation`（`versionedFileURL`+`legacySeedURL`，照抄 Lyrics/Metadata/Translation 三个缓存的模式）。生产环境（`.production` scope）算出的目录和旧代码手写的路径完全一样，创始人的真实文件不挪窝；旧文件名作一次性迁移种子，只读不回写。核对过 `NanoPodCacheLocation.scope(for:)`：XCTest 进程靠自己独立的 `isXCTestCase`/环境变量检测落到 `.testRun`（不依赖 MusicController 自己那套 preview 短路），`LyricsVerifier` 是纯 SwiftPM 可执行文件、`Bundle.main.bundleIdentifier` 为 nil，落到 `.isolated`——两者都摸不到真实文件。跨进程合并写不做，两个生产实例同时跑仍是后写者赢，写进代码注释与本文档当已知残留风险，未列为本次修复范围。

**容量**：真机 NSWindow 托管 PlaylistView 实测（`PlaybackHistoryCapacityMeasurementTests`，全部行封面预置内存缓存，零网络/SB 调用）：History 50/100/200/300 行时，一次无关 @Published 写入触发的 body 求值+布局耗时分别是 **11.2~11.5ms / 10.8~12.3ms / 22.2~23.6ms / 32.8ms**（两次独立跑的区间）。线性插值算出 60fps 单帧 16.67ms 预算的越界点在约 139 行。选了 **100** 作为新容量：留出实测余量（~12ms vs 16.67ms 预算，约 4ms 缓冲）、字节开销约 19.1KB（195.68B/条实测值 ×100，在创始人"几十 KB"预算内）、覆盖窗口从实测 30.75 小时翻倍到约 61.5 小时（≈2.6 天）——且这是按含"秒切"噪声的旧速率算的，10 秒门槛上线后噪声会被过滤掉一部分，实际覆盖天数只会更长（没有精确数字，未夸大）。行封面抓取并发/总量不受行数放大影响：`RowArtworkVisibilityPolicy`（页面可见门）+`RowArtworkFetchGate`（同时 3 个）+`RowArtworkNegativeCache`（失败退避）三层没有改动，容量变大只是让排队变长，不会引入 09-15 那种无界并发。没有加"只抓视口"之类的界面改动——现有三层机制已经把最坏情况的伤害界定住了，如果创始人想要更快收敛可以再议，这次没有自作主张加 UI。

**加载有界**：`load()` 解码前先用 `attributesOfItem` 查文件大小（不读内容），超过 512KB 当损坏处理，不碰文件字节、不主动覆盖。

**埋点**：`PendingPlaybackAccumulator` 的 begin/skip（同曲重复探测）/discard（未达门槛）/patch PID/commit 五个分支各打一行 `DebugLogger.log("History", ...)`，走现有文件日志开关，关闭时零成本（`DebugLogger.log` 的 `@autoclosure` 参数在开关关闭时连字符串插值都不做）。

**Spotify**：确认仍未接线（同第一阶段结论），列为后续项，本次未动。

**测试**：第一阶段 5 个诊断测试的断言迁移进了各自更合适的永久测试文件（不是同名文件里红改绿——H1 并入 `PlaylistRowActivityPolicyTests.swift` 已有的 `PlaybackHistoryDisplayPolicyTests`，H2 并入 `PlaybackHistoryStoreTests.swift`，H3/H4 从「模型」升级为直接测真实 `PendingPlaybackAccumulator`，放进新建的 `PendingPlaybackAccumulatorTests.swift`），第一阶段那个纯诊断文件已删除。新增/改动测试文件：`PlaybackHistoryStoreTests.swift`（36 用例，含 NanoPodCacheLocation 迁移、`patchPersistentID`、`flush()`、`onChange`、超限文件）、`PendingPlaybackAccumulatorTests.swift`（23+13 用例，含 0/10 两档门槛、9.9s/10.0s 边界、暂停不计时、极短曲自然结束、真实 09-25 凌晨连切段两个版本——理想化"零新增"与精确间隔"恰好 1 条"分开测，没有为了凑"零新增"而篡改真实间隔）、`PlaylistRowActivityPolicyTests.swift`（H1 新签名）、`PlaybackHistoryCapacityMeasurementTests.swift`（容量实测）。第二阶段全部相关测试类 `swift test --filter` 串行跑通：133 个用例，0 失败（两次独立跑）。
