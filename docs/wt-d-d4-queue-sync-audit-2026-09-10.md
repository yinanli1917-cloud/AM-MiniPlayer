# WT-D D4：队列同步只读体检（2026-09-10）

## 结论先行
main 的队列同步在"检测到变化"方面基本可用（hash+通知+30s 兜底），但在"变化后正确清空/中止"方面有两个确认缺口：**Music.app 退出/停止播放后 Up Next/Recent 行不清空**（会显示上一首歌的残留队列），以及**电台/无 currentPlaylist 场景没有专门的失效通道**。慢 SB 读有 3s 超时且不会被误判为换歌。线程隔离正确：控制类操作（星标/随机/循环）用 `controlQueue`，从不在其上读队列。stale 分支的 20 个 `fix(queue)` commit 里，"generation 守卫防止扫描崩溃"这条已被 main 部分吸收（Up Next 扫描有守卫，Recent 扫描没有），但"停止/不可用时清空行"整套（provenance 模型）main 完全没有。

## 1. 漂移场景

- **(a) Music.app 内部纯重排 Up Next（不影响 currentPlaylist/count/currentID）**：hash = `"\(playlistName):\(tracks.count):\(currentID)"`（MusicController.swift:944）。纯重排不改变这三者 → **hash 不变，30s 轮询/DNC 通知都不会触发刷新**。唯一救济是 track-change 后 2.0s 的 debounce 刷新（MusicController.swift:1329-1335）和用户手动开面板时 `refreshQueueForPlaylistOpen`（若 >5s 未刷新会强刷，MusicController+Playback.swift:393-407）。结论：纯重排在最坏情况下可以停留到用户重新打开面板或换下一首，**没有专门检测路径**。
- **(b) 给正在播放的歌单加一首歌**：count 变了，hash 变化 → 30s 轮询内必检测到；DNC `playlistChanged` 通知到达时限流 1/s（MusicController.swift:964-971），实际感知延迟约 0.5-1.5s，早于 30s 兜底。
- **(c) Music.app 退出或停止播放**：`fetchUpNextViaBridge` 入口 `guard let app = queueApp, app.isRunning else { return }`（MusicController+Playback.swift:412-415）——直接静默 return，**不清空 `upNextTracks`/`recentTracks`**。`checkQueueHashAndRefresh` 同样在 `app.isRunning` 为假时整体跳过（MusicController.swift:924-926）。结论：**残留行确认存在**，与 stale 分支的 `markQueueUnavailableForNoCurrentTrack`（provenance=.unavailable，见下文）形成的能力空白一致。
- **(d) 库歌单切电台**：main 没有任何函数比较"切歌前后 trackClass/playlistName/isURLTrack 是否变化但 track 未变"（对应 stale 分支 `shouldInvalidateQueueForPlayerStateContextChange`，main 全仓库搜索无匹配）。电台流下 `currentPlaylist` 常不可用，`getUpNextTracksFromApp` 的 guard 会拿到 nil 直接 `return`（不落任何行，MusicController+Playback.swift:571-577），所以不会显示错误内容，但**旧库歌单的行会原样留在 `upNextTracks` 里**，与 (c) 是同一类缺口。
- **(e) 慢 SB 读（3s 超时）**：`getUpNextTracksFromApp`/`getRecentTracksFromApp` 都用 `SBTimeoutRunner.run(timeout: 3.0, lane: "queueSnapshot")`（MusicController+Playback.swift:566, 646）；超时返回 `nil` → 外层 `?? []` 得到空数组，但调用方 `applyUpNextTracksIfChanged`/`applyRecentTracksIfChanged` 走 `sameTrackIdentity` diff（MusicController+Playback.swift:714-724），**空数组与当前非空队列不同 → 会被当作"变化"写入并清空显示**，这不是"当作换歌"，但确实会把超时误当作队列已清空处理——不属于用户报告的场景，但值得记录为潜在误清空点。`getQueueHashFromApp` 单独用 1.5s 超时，超时返回 nil，调用方 `guard let hash = ... else { return }`（MusicController.swift:928）直接跳过，不改 `lastQueueHash`，不会误判。
- **(f) 快速连续切歌**：track-change 用 2.0s debounce timer + `artworkFetchGeneration` 校验（MusicController.swift:1329-1335, MusicController+Playback.swift:431-438 `shouldApplyQueueSnapshot`），扫描内部逐条 `guard self.artworkFetchGeneration == gen`（MusicController+Playback.swift:588, 608，仅 Up Next 扫描），可中止陈旧扫描，注释明确指出这是防 `EXC_BAD_ACCESS` 的手段（MusicController+Playback.swift:558-561）。**但 `getRecentTracksFromApp` 内部循环没有同款 generation 守卫**（MusicController+Playback.swift:665-701 全程无 `gen` 检查），只在方法级用 3s 超时兜底，不如 stale 分支 3919837 完整。

## 2. 线程
所有队列读（`getQueueHashFromApp`、`getUpNextTracksFromApp`、`getRecentTracksFromApp`）都经 `scriptingBridgeQueue.async`（MusicController.swift:924, MusicController+Playback.swift:421, 580）。`scriptingBridgeQueue`/`controlQueue` 分别定义于 MusicController.swift:246/263。`controlQueue` 仅出现在 `toggleStar`/`setShuffle`/`setRepeat`/seek 等写操作（MusicController+Playback.swift:77-310, 819-880），**未发现任何队列读跑在 controlQueue 上**。这两个文件内 `grep Thread.sleep` 零命中。

## 3. 与 stale 分支对照（不合并，仅列差距）
`git log --oneline main..origin/codex/real-time-queue-sync-proof-gates` 共 29 条，6 条相关抽样：

| commit | 内容 | main 现状 |
|---|---|---|
| 8b3de52 停止时清空快照 | 新增 `markQueueUnavailableForNoCurrentTrack` 清空行+置 provenance | main 无此函数，无 provenance 模型（缺口，对应上面 (c)） |
| 3127c63 停止时清空 track identity | 清 `currentPersistentID`/`currentTrackClass` 等 | main 未搜到等价重置（同一缺口的另一半） |
| 9a6e670 Music 不可用时清行 | `applyWholeQueueUnavailableSnapshotIfNeeded` | main 无此路径，`fetchUpNextViaBridge` 直接 silent return（MusicController+Playback.swift:412-415） |
| 6aebc54 同曲跨源变化时失效 | `shouldInvalidateQueueForPlayerStateContextChange` | main 全仓库无匹配，对应缺口 (d) |
| 5fdad4c 扫描前后 row count 守卫 | Up Next + Recent 均加 gen 守卫 | main 只有 Up Next 一侧有（MusicController+Playback.swift:588,608），Recent 侧无（缺口，对应上面 (f)） |
| 3919837 中止陈旧 recent 扫描 | Recent 循环内逐条 gen 检查 | 同上，main 缺失 |

## 4. 现有测试覆盖
`Tests/MusicMiniPlayerTests/` 下已存在：`RapidSwitchTests.swift`、`RadioTrackChangeDebounceTests.swift`、`TrackIdentityDisciplineTests.swift`、`SBTimeoutRunnerLaneTests.swift`。均为文件级确认存在，未逐条读用例内容（只读体检范围内，避免过度展开）。

## 5. 建议（≤5 项，按用户可见影响排序）
1. **Music 退出/播放停止清空残留行**——影响最大（用户会看到"幽灵队列"）。抽出纯函数 `shouldClearQueueForUnavailableSource(appIsRunning: Bool, hasCurrentTrack: Bool) -> Bool`，配合现有 `sameTrackIdentity` 改造 `applyUpNextTracksIfChanged([])` 强制路径；测试用假 `appIsRunning=false` 输入，断言返回 true，无需真 SB。
2. **Recent 扫描补 generation 守卫**，复用 Up Next 已有写法（MusicController+Playback.swift:588 同款），抽出 `shouldAbortScan(capturedGen: Int, currentGen: Int) -> Bool`（其实已是 `!=` 判断，可直接抽成静态函数复用两处）；测试注入 gen 序列断言中止时机。
3. **库歌单→电台的失效通道**：抽出纯函数（对照 stale 分支 `shouldInvalidateQueueForPlayerStateContextChange` 的签名思路，不抄实现）`shouldInvalidateQueueForContextChange(trackChanged:, oldClass:, newClass:, oldPlaylist:, newPlaylist:) -> Bool`；假时钟/字符串输入即可测试。
4. **纯重排检测**（影响较小，用户少见但确实存在）：视是否值得引入 track 顺序摘要（如首尾几个 persistentID 拼接）加入 hash，需先评估 SB 调用成本，本次审计不下结论，仅记录为待权衡项。
5. 补一条 `SuperStaleQueueClearedTests`（或纳入现有 `TrackIdentityDisciplineTests`）钉死第 1/2 项行为，避免回归。

**不要做**：不要把 30s 轮询改快（已有 hash+DNC 兜底，加密轮询只加 SB 负载不解决本质）；不要整体合并/cherry-pick stale 分支（3 个月无 review，且引入了本审计未验证的 provenance 类型改动面过大）；不要在 `controlQueue` 上加任何队列读。

## 文件证据索引
`Sources/MusicMiniPlayerCore/Services/MusicController.swift:453,922-972,1329-1335`；`Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift:325-460,558-714`；`Tests/MusicMiniPlayerTests/{RapidSwitchTests,RadioTrackChangeDebounceTests,TrackIdentityDisciplineTests,SBTimeoutRunnerLaneTests}.swift`。
