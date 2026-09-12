# WT-D 队列来源矩阵实测（2026-09-12）

真机 `osascript` 只读探测，脚本 `scripts/probe_queue_source.sh`。全程未改动任何播放列表、未碰 shuffle/repeat。

## 复现结论（先说结论）

`current playlist` 对 Apple Music 目录内容（不在库中的单曲/专辑/编辑精选/电台）稳定报错 `-1728 Can't get current playlist`，8s→20s 两次读数一致，不是瞬时未就绪。这与 `MusicController+Playback.swift:591-596` 的预期分支一致：guard 失败应把 `outcome` 置为 `.noCurrentPlaylist`。

但代码里真正的风险点在 `getUpNextTracksFromApp`（`Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift:564-675`）：`outcome` 的初始值在第 566 行被设为 `.noCurrentTrack`（不是某个"未知"哨兵值），随后整段读取逻辑包在 `OBJCCatch { ... }`（第 578-659 行）里。`guard let playlist = app.value(forKey: "currentPlaylist") ... else { outcome = .noCurrentPlaylist; return }`（591-595 行）只在 `value(forKey:)` **正常返回 nil 或类型转换失败**时才会把 `outcome` 改写成 `.noCurrentPlaylist`；如果 ScriptingBridge 把 Music.app 的 AppleEvent 错误 `-1728`（就是本文探测到的那个错误)以 Objective-C 异常形式抛出而不是返回 nil，`guard let` 那一行本身就会抛出，`outcome = .noCurrentPlaylist` 这句赋值永远不会执行，异常会被外层 `OBJCCatch` 吞掉（第 661-663 行只打日志），函数最终返回时 `outcome` 还停留在第 566 行的默认值 `.noCurrentTrack`。

`.noCurrentTrack` → `provenance(for:)`（428-448 行）→ `.unavailable(reason: .noCurrentTrack)`；`UpNextEmptyState.messageKey`（PlaylistView.swift:547-557）只对 `.noPublicQueueObject` / `.noCurrentPlaylistForTrackClass` 两种原因返回 `"queueUnavailableForSource"`（即 D3 文案「Music 未对该来源暴露队列」），其余（包括 `.noCurrentTrack`）一律落到 default 分支返回 `"queueEmpty"`（「Queue is empty」）。这正好解释了创始人报告的现象：**目录单曲播放时 Up Next 显示的是通用「Queue is empty」，不是 D3 专属文案**。

这一步是代码推理，不是本次真机复现的直接证据——本次没有跑 `swift build`/单测，也没有给 ScriptingBridge 加日志埋点，`value(forKey:)` 是否真的抛异常而非返回 nil 需要下一步在 Swift 侧加时间戳日志验证（先复现再修的铁律要求这步落地才能定案）。

另外，`MusicQueueProvenance.swift:5` 已经声明了 `noCurrentPlaylistForTrackClass(String)` 这个原因，`UpNextEmptyState.messageKey` 也已经把它接进 D3 文案分支，但全仓库搜索（`grep -rn "noCurrentPlaylistForTrackClass" Sources/`）确认**从未有任何生产代码产出这个 case**——只有声明和消费方,没有生产方。说明这是此前设想的"按 track class 判断"方案已经写了一半就搁置了。

## 探测矩阵

| 来源 | current track class | current playlist 可读? | playlist name/class/kind | 曲目数 | 当前曲后曲目数 | 首次读延迟 | 8s→20s 变化 | 落到的 QueueFetchOutcome / 文案 |
|---|---|---|---|---|---|---|---|---|
| 场景0：AM 目录单曲（创始人报告的原始状态，已 paused） | URL track | 否（-1728） | n/a | n/a | n/a（同错误） | 首次 osascript 各 ~150-170ms | 未再采（已 paused，未重复读） | 若无异常吞噬：`.noCurrentPlaylist`→D3；若异常被吞：`.noCurrentTrack`→queueEmpty（见结论） |
| a. 库内用户播放列表 Piano Chronicle | shared track | 是 | Piano Chronicle / user playlist / none | 217 | 216 | ~150-200ms | 无变化 | `.success(playlistName:)`→`.playlistContextOnly`→queueEmpty（非 unavailable，正常空态） |
| b. AM 编辑精选歌单 Today's Hits | — | 否（连 current track 都拿不到，-1728） | n/a | n/a | n/a | ~150-330ms | 无变化（stopped 两轮 + play 重试仍 stopped） | `.noCurrentTrack`→`.unavailable(.noCurrentTrack)`→queueEmpty |
| c. AM 专辑 Kind of Blue | — | 否（同上，current track 都拿不到） | n/a | n/a | n/a | ~140-190ms | 无变化 | `.noCurrentTrack`→queueEmpty |
| d. AM 目录单曲（复测，实际解析成另一首「歡樂今宵」——URL id 未精确锁定预期曲目，但来源类型一致） | URL track | 否（-1728） | n/a | n/a | n/a | ~145-220ms | 无变化 | 同场景0 |
| e. 电台 Apple Music 1 | — | 否（current track 都拿不到，-1728） | n/a | n/a | n/a | ~135-205ms | 无变化（play 重试仍 stopped） | `.noCurrentTrack`→queueEmpty |

备注：
- b/c/e 三个来源在本机通过 `open location` + 一次 `play` 重试后仍是 `stopped`、`current track` 直接报 `-1728`，没能进入"播放中但无 currentPlaylist"这个更细的状态——大概率是这台机器上 Apple Music 账号/网络对这几类目录内容的解析比单曲慢或需要前台交互，不代表 nanoPod 逻辑在这三类来源上没问题；只有 a（库内播放列表）和 场景0/d（AM 目录单曲）拿到了确定性的、持续 8s→20s 不变的读数。
- 场景0是创始人报告 bug 时的原始现场（已被后续操作探测覆盖，只做一次性读取，未反复轮询验证 outcome 是否漂移）。

## 一个正确的 gate 需要看什么

现有 guard 只看「`currentPlaylist` 这个 key 能不能取到值」，取不到就该认定为"来源无队列"。但从这次真机读数看，`current track` 本身也可能先失败（b/c/e 场景），这时候连"当前是什么类型的来源"都不知道，笼统地都归到 `.noCurrentTrack` 会掩盖"电台/编辑精选到底有没有队列"这个更细的问题。一个更完整的 gate 应该：
1. 分别处理"current track 读不到"（真的没有东西在播）和"current track 读得到但 current playlist 读不到"（有东西在播，只是这个来源没有公开队列对象）两种情况——目前 `getUpNextTracksFromApp` 已经分两步 guard，方向是对的。
2. 第二步 guard 失败时，需要确认失败路径是"正常返回 nil/类型不符"还是"AppleEvent 异常直接抛出"——如果是后者，`outcome = .noCurrentPlaylist` 这行赋值必须在异常抛出点之前完成，或者在 `OBJCCatch` 捕获异常时按已读到的 `currentTrack.class`（URL track 等）显式回填 `.noCurrentPlaylistForTrackClass`，而不是让 `outcome` 停留在初始的 `.noCurrentTrack`。
3. `MusicQueueProvenance.noCurrentPlaylistForTrackClass(String)` 这个已声明未使用的 case，正是为这条路径设计的——用真实读到的 `class of current track`（如「URL track」）作为参数，比笼统的 `.noPublicQueueObject` 更精确，且已经被 UI 消费。
