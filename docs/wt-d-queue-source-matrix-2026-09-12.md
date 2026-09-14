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

## 补测 2026-09-12 第二轮

订阅歌单 Classical Chill（103首）：subscription playlist，`current playlist` 可读，8s→20s 读数不变（曲目数103/剩余102/current track class shared track）。Jazz Chill（49首）复测一致，佐证订阅歌单稳定可读。

AM 专辑 Kind of Blue：`open location` 后 30s 轮询 `player state` 始终 `playing`，但 `current track name` 全程仍是此前歌单曲目（Endless Stairs），track 从未切换；显式 `play` 后仍是同一曲目。判定：本机本轮 `open location` 未能让该专辑实际开始播放。

电台 Apple Music 1：`open location`（https:// 与 itmss:// 两种 URL 均试）后轮询 30s+16s，`player state` 始终 `playing`，但曲目在第16s 变成库内曲目「葉子」（current playlist = Music / user playlist / special kind Music，非电台），可判定为库内接续播放而非电台真正起播；两种 URL 变体均未能让电台开始播放。按要求标注：**需创始人手动起播**，未伪造电台已播成功。

AM 目录单曲复现：多次 `open location` 尝试均未切歌，直到 `tell application "Music" to activate` 前置激活应用后，`open location` 才生效——此时 `player state` 变为 `stopped`（非 playing）；`class of current track` 报 `-1700`（无法把 «class pTrk» 强转 string，说明有个 track 对象但类型系统层面取不到具体 class 字符串）；`name of current track`、`current playlist` 相关全部 `-1728`；`current playlist exists` 干净返回 `false`（非异常）。多次显式 `play` 均未能让其从 stopped 变为 playing——如实记录：本轮未能复现"目录单曲处于 playing 态"，只复现了"目录单曲已加载但未播放"这一子状态，`current track`/`current playlist` 的 -1728 报错在此状态下同样成立。

## ScriptingBridge 异常 vs nil 实测

编译并运行 `/private/tmp/.../scratchpad/sbprobe.m`（ObjC，`SBApplication applicationWithBundleIdentifier:@"com.apple.Music"`），在上述目录单曲状态（current track 存在但 -1728、current playlist 不可读）下：

```
currentTrack: VALUE SBObject
currentTrack: lastError = (nil)
currentPlaylist: VALUE SBObject
currentPlaylist: lastError = (nil)
currentPlaylist.tracks: VALUE SBElementArray
currentPlaylist.tracks: lastError = (nil)
```

`valueForKey:@"currentTrack"` / `@"currentPlaylist"` / 其 `.tracks` 三者都**不抛异常、不返回 nil**——ScriptingBridge 直接给一个未解析的 `SBObject`/`SBElementArray` 代理对象，`[app lastError]` 也是 nil。继续深一层，对该代理对象取具体属性（`sbprobe2.m`）：

```
currentPlaylist.name: NIL
currentPlaylist.name: lastError = (nil)
currentPlaylist.tracks.count: VALUE __NSCFNumber (0)
currentPlaylist.tracks.count: lastError = (nil)
currentTrack.name: NIL
currentTrack.name: lastError = (nil)
```

代理对象的 `.name` 属性静默返回 `NIL`（不抛异常），`.tracks.count` 返回 `0`（不是错误），`lastError` 全程 `nil`。控制组（`play user playlist "Piano Chronicle"` 播放中）用同一二进制跑：`currentPlaylist.name` = `Piano Chronicle`，`tracks.count` = `218`，`currentTrack.name` = `Ylang Ylang`，全部正常取值。

**结论（修正此前的异常假设）**：`getUpNextTracksFromApp` 的 `app.value(forKey: "currentPlaylist")` 这一步在目录内容场景下拿到的不是 nil、也不抛 Objective-C 异常，而是一个可以成功 `as?` 转型的空代理对象；guard 因此会通过。真正的失败点在guard之后：读该代理对象的 `name`/其它属性时，ScriptingBridge 把 AppleEvent 的 `-1728` 静默吞成 `nil`（无异常、`lastError` 也不填）。也就是说本轮实测排除了"OBJCCatch 吞异常"这个假设——代码里如果只在 `value(forKey:)` 那一层做 guard，永远走不到 `.noCurrentPlaylist` 分支；必须在读取代理对象的具体属性（如 name 或 tracks）时再判一次 nil，才能把这类目录单曲/专辑/电台命中到 `.noCurrentPlaylistForTrackClass`，否则 `outcome` 会一路停留在初始值 `.noCurrentTrack`（对应 UI 上笼统的 "Queue is empty"，而非 D3 专属文案）。

## 补测 2026-09-12 第三轮：随机态、真实历史、实时队列其他路径

### 1. 随机（shuffle）态下 AppleScript 能否拿到随机顺序或下一首
- 字典实查（`sdef Music.app`）：与随机相关的只有 `shuffle enabled`（布尔）、`shuffle mode`（songs/albums/groupings）、`song repeat`；没有任何「下一首」「播放顺序」「队列」属性，`current playlist` 只是「包含当前曲的歌单」（access r）。
- 真机（Piano Chronicle，shuffle 开）：`index of current track` 序列 19 → 36 → 183，连续两次 `next track` 之间没有任何可读属性能预测下一个 index。结论：随机态下 Up Next 无法从公开接口得到，`getUpNextTracksFromApp` 按存储顺序取当前曲之后的行在随机态下必然与实际不符。
- 已确认的代码事实：History 也是按存储顺序取当前曲之前的行，不是播放记录。

### 2. Music.app 自己的播放记录能不能当 History
- 字典有 `played date` / `played count` / `skipped date`（track 属性）。
- 真机：`next track` 跳过后 2 秒内 `played date` 与 `skipped date` 都没有更新（短播放不计入）。Music 只在曲目播满或达到阈值后更新 played date，且只对库内曲目有效（AM 目录曲不在库中无此属性）。结论：可作为「已完整播放」的持久证据，但不是实时、不覆盖非库曲，不能单独当 History。

### 3. 「实时队列」其他路径
- MusicKit：SystemMusicPlayer 平台清单无 macOS（仅 Mac Catalyst），macOS 上没有读 Music.app 播放会话队列的 API；ApplicationMusicPlayer 的队列是 nanoPod 自己的，"doesn't affect the Music app's state"（见 09-11 三批核实）。
- Accessibility：Music.app 主窗口 AX 树里有 `AXCheckBox description="playing next"`（工具栏切换）；点开后 AX 树从 1826 个元素增至 2827 个，新增一个 AXTable（1245 行/格），Playing Next 列表确实暴露。代价：①需要辅助功能授权（沙盒 app 可被授予，但要用户去系统设置手动开）；②必须 Music 主窗口存在且面板处于打开状态（会改用户的 Music 界面）；③本次用 AppleScript 枚举整棵树耗时超过 3 分钟（AX C API 会快得多，但仍是 UI 抓取，随 Music 版本随时失效）。结论：纯净版（App Store）不可行；完整版技术上可行但脆弱，属 UI 抓取。
- MediaRemote adapter（ungive/mediaremote-adapter）：只暴露 now-playing 元数据与播放命令，README 明确无队列；实现靠 Apple 签名的 /usr/bin/perl 加载私有框架绕过 15.4 的限制，与「不用私有 API」规矩冲突。
- 分布式通知 `com.apple.Music.playerInfo`：切随机/循环时会发（本机 ObjC 监听实测，四次切换四次通知），但 userInfo 只有曲目元数据键（Artist/Album/Name/PersistentID/Player State/Total Time 等），没有 Shuffle/Repeat 键，也没有队列信息。

## 第四轮 2026-09-13：AXUIElement C API 读 Playing Next（完整版 spike）

工具：`research/spikes/ax-playing-next/{main.swift,axspike}`，独立编译，未碰 Package.swift/Sources/。测试曲库：Piano Chronicle（218首，非随机）。

### a. 定位 Table + 读取耗时 —— 判定：**有条件可用（条件：面板须处于打开态，且身份识别用行数启发式，非稳固路径）**
- 路径：`AXUIElementCreateApplication(pid) → kAXMainWindowAttribute → 深度优先找 AXCheckBox(description含"playing next") → AXPress → 新增一个 AXTable`。开关前主窗口 AX 树里没有该 AXTable，开关后出现且 `kAXRowsAttribute` 行数=302（含1条 "History" 分组头行，不是曲目，读取端需按角色/文本过滤）。
- 识别方式目前是"行数最多的 AXTable"启发式（对比开关前后 table 集合的差集更稳，本轮用行数堆更简单但脆弱，几个曲目的库该值会很小甚至反超库表）。
- 行数（`kAXRowsAttribute` 数组长度，不取内容）：3 次热跑 0.6/1.6/0.7ms（冷跑同量级 0.6ms）——可视为免费。
- 用 `AXUIElementCopyAttributeValues` 按区间读前20行标题+艺人（每行内 `axFindAll` 找 AXStaticText，深度6）：5 次独立冷跑（不同进程）963/1090/1252/1145/1027ms；同进程3次热跑1016/1026/1645ms——**耗时几乎不随冷热变化，每行约50ms**，20行接近1秒，这个量级对"实时读队列"是硬伤。

### b. 不激活 Music 能否操作与读取 —— 判定：**可用（AXPress 不偷焦点）；(1)未测；(2)(3)(4) 见下**
- AXPress 在 checkbox 上全程未让 Music 变为前台进程（`frontmost` 全程停在发起测试的进程/TextEdit），确认"后台操作"成立。
- (1) 另一个 Space：未测——本沙盒环境无法可靠切 Space 做对照，跳过，原因是 AppleScript 无法确定性地把窗口钉到指定 Space 再验证。
- (2) 遮挡：`open -a TextEdit`，用 TextEdit 自身 `set bounds of window 1` 覆盖 Music 窗口约 2/3 区域（System Events 版 `set position/size` 在本机对 TextEdit 报 -1719，换用应用自带 `bounds` 属性绕过）；全程 frontmost=TextEdit，读前5行 220~233ms（与非遮挡同量级）。**判定：可用**。
- (3) 最小化：`tell application "Music" to set collapsed of window 1 to true`（Music 字典里真实属性名是 `collapsed` 不是 `miniaturized`）与 `System Events...set miniaturized...to true` 均**未生效**：前者无报错但 `collapsed` 读回仍 false，后者报 `-10006 Can't set miniaturized of UI element to any`。**判定：不可用（条件：本机/本版本 Music.app 窗口无法被 AppleScript 最小化，需要真实点击红绿灯或 Dock 手势，二者都要 UI 交互而非纯后台脚本）**——未能构造出"最小化态"这个前提，因此该态下的可读性本身也**未测**。
- (4) 窗口关闭态：`tell application "Music" to close window 1` 成功（frontmost 全程未变），关闭后 `mainWindow` 拿不到（AX 主窗口属性消失），读表返回 "no window"。`reopen` 恢复窗口且未抢焦点。**判定：不可用（关闭态下 AX 树无窗口可读，是预期行为不是 bug）**。

### c. AXObserver 实时通知 —— 判定：**不可用**
- 在 table 和 window 两层各订阅 `kAXRowCountChangedNotification`/`kAXValueChangedNotification`/`kAXSelectedRowsChangedNotification`，`AXObserverAddNotification` 全部返回 `err=0`（订阅成功），`CFRunLoopAddSource` 接入 `.defaultMode`。
- 触发：t=3s 发 `next track`，t=10s 发 `shuffle enabled` 取反（均记录 osascript 发出时间戳）。20秒观测窗口内**零次回调**，三种通知一次都没触发。
- 结论：换歌、切随机都不会让这张 AXTable 发出可订阅的 AX 通知（大概率因为面板处于折叠/非可见状态、或 Music 这张表压根不发这些通知）——**实时监听不可行，只能轮询**，轮询成本见 a 项（~50ms/行）。

### d. 随机态下预测 vs 实际 —— 判定：**不可用（结果不一致，证伪队列预测能力）**
- 打开 shuffle 后立即读表前5行（未重新走"关闭再打开面板"刷新路径），预测为 Pale Jay 的3首+Loaded Honey 1首；随后 `next track` ×3（2秒间隔）实际得到 `Dekalog VI, Pt. 1` → `Easy Walker` → `Sundays (Just Piano Version)`，与预测**完全不吻合**，且实际曲目分布不在预测的 Pale Jay 专辑内。
- 与 09-12 第三轮笔记一致的根因：面板内容是"存储顺序"快照，AXTable 不会随 shuffle 切换重新洗牌顺序；必须每次都强制关闭再重新打开面板才能拿到当前一批候选，且即便如此也无法保证与 Music 内部真实随机指针一致（这次连打开后立即读都对不上，说明面板本身的随机重排时机也不可控）。

### e. 权限 —— 判定：**可用**
- `AXIsProcessTrustedWithOptions(prompt:false)` = `true`（spike 独立二进制，已被此前手动授权过一次）。`prompt:true` 会弹一次系统授权框（未重新触发，沿用已有授权）。非沙盒 spike 二进制不需要任何 entitlement 声明；App Store 沙盒版若要用同一套 API 需要在 `com.apple.security.temp-exception` 或直接使用可被沙盒接受的辅助功能授权流程（超出本次 spike 范围）。

### 结论（写给 WT-E）
四项里三项（a 计时、b 后台可读性、e 权限）证明"不激活也能读"的核心假设成立，但 c（无实时通知，只能轮询）+ d（shuffle 下预测失真）+ b.3（无法程序化最小化验证）三条都是硬缺口：`AXPlayingNextQueueReader.readPlayingNext(limit:)` 技术上可实现，但其 `AsyncStream<Void>` 变更通知拿不到 AX 原生事件，只能自己起一个轮询 Timer（每次 ~1s/20行，代价不小，需要限流到"面板打开时才轮询"）；shuffle 态下这个 reader 给出的"upcoming"必须标注为不可信/仅供参考，不能当作真实下一首预测。

重建/运行命令：
```bash
cd /Users/yinanli/Documents/MusicMiniPlayer/.claude/worktrees/exciting-mclean-ccb7e0
swiftc -O -framework ApplicationServices -framework AppKit research/spikes/ax-playing-next/*.swift -o research/spikes/ax-playing-next/axspike
./research/spikes/ax-playing-next/axspike permission
./research/spikes/ax-playing-next/axspike find-table
./research/spikes/ax-playing-next/axspike read-rows 20
./research/spikes/ax-playing-next/axspike window-state <occlude|minimize|close|reopen>
./research/spikes/ax-playing-next/axspike observe
./research/spikes/ax-playing-next/axspike shuffle-check
```

### 第四轮补测（同日）

1. 行号地图 —— 判定：**可用**
   - 302 行全部 role=AXRow，用 `kAXChildrenAttribute` 一次+子元素 value/title 拼字符串导出到 `research/spikes/ax-playing-next/rowmap.txt`。两个分组头都是纯文本单字段行（无 `—`/`|` 分隔符），据此定位：**行 0 = "History"**（历史分组头），**行 201 = "Continue Playing"**（不是文档假设的 "Playing Next"/"接下来播放"/"Up Next"，是 Music.app 这版本实际用的字符串，识别逻辑需要把这个词也算进去）。历史行 = 1..200 共 200 行；接下来播放行 = 202..301 共 100 行。

2. 随机开关正确性 —— 判定：**可用（条件：开关后等 2 秒结算，不重开面板）**
   - 开 shuffle 后等 2s（不重开面板）读头行后前 8 行，随后 `next track` ×3（2s 间隔），三次实际当前曲目**全部命中**预测集合且顺序一致（this is what love is → Opus → Musique Strand 2）。
   - 开关前后 2s 对照头行后前 8 行：8 行**全部不同**，证明表内容确实随 shuffle 切换即时重排，不需要关闭重开面板。
   - 关→开→关：两次"关"状态读到的前 8 行**完全一致**（8/8 same=true），说明关闭态顺序是确定性的（大概率是曲库/专辑顺序），可重复。
   - 与第四轮 d 项结论相反：d 项在**未等待**、未过 2s 结算时读取，读到的是过渡态脏数据；补测证明只要等 2s 结算，随机预测是准的。

3. 最快单行读取 —— 判定：**可用**
   - fast path（`kAXChildrenAttribute` 读一次 + 子元素 value/title，无 depth-6 递归搜索）：20 行 3 次热跑 1.7/1.5/1.7ms，约 **0.08ms/行**。
   - `AXUIElementCopyMultipleAttributeValues`（每行 cell 子元素一次拿 value+title）：3 次热跑 1.4/1.2/1.3ms，约 **0.065ms/行**，是三种读法里最快的。
   - `kAXVisibleRowsAttribute`：面板实际可见行数=15（非全部302），读取 7.2ms，约 0.48ms/行，比全表 fast path 慢但仍远快于 a 项旧测的 ~50ms/行。
   - 结论：a 项旧测"每行约50ms"的耗时几乎全部来自 `axFindAll` 的 depth-6 递归遍历本身，不是 AX IPC 调用开销；换成"只读一层子节点"或批量属性调用后，单行成本降到亚毫秒级，"实时读队列"这条路径技术上是可用的。

4. AX 方式最小化 —— 判定：**不可用**
   - 直接对 window 元素调用 `AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanTrue)`，返回 `err=0`（调用本身成功），但立即读回 `kAXMinimizedAttribute` 仍是 `false`——跟第四轮用 AppleScript/System Events 设置失败是同一现象，换成"正牌" AX C API 直接调用也无法让 Music 窗口真正进入最小化态。因为窗口实际没有最小化，"最小化态下能否读表"这个前提依旧没有被构造出来（本次读表成功是因为窗口根本没最小化，不能算作该态下的验证）。

5. Observer 通知复测 —— 判定：**有条件可用（条件：只看 `kAXRowCountChangedNotification` / `kAXUIElementDestroyedNotification`，屏蔽 `kAXValueChangedNotification` 噪声）**
   - 在 WINDOW + APPLICATION 两级订阅 `kAXLayoutChangedNotification`/`kAXCreatedNotification`/`kAXUIElementDestroyedNotification`/`kAXValueChangedNotification`/`kAXRowCountChangedNotification`/`kAXFocusedUIElementChangedNotification`，TABLE 级订阅 `kAXRowCountChangedNotification`/`kAXSelectedRowsChangedNotification`，25s 窗口内 t=3 next track、t=10 切 shuffle、t=17 next track。
   - **确实触发**：`kAXValueChangedNotification` 几乎每 0.3~0.4s 连续触发（大概率是播放进度条/时间控件在跳，噪声源，不能拿来当队列变化信号）；`kAXRowCountChangedNotification` 与 `kAXUIElementDestroyedNotification` 在三次触发点附近各精确触发一次，相对操作时间戳延迟约 0.45~0.51s（三次分别 ~0.45s / ~0.50s / ~0.51s），延迟稳定。
   - **未触发**：`kAXCreatedNotification`、`kAXLayoutChangedNotification`、`kAXFocusedUIElementChangedNotification`、`kAXSelectedRowsChangedNotification` 全程零次；另做"先关闭面板再重开"的对照（10s 窗口，t=3 按 checkbox 重开），`kAXCreatedNotification` 依然 0 次回调。
   - 与第四轮 c 项"零回调、不可行只能轮询"结论相反：只要把订阅范围扩到 WINDOW/APPLICATION 两级并只筛 `RowCountChanged`+`UIElementDestroyed` 这两个事件，是能拿到"队列变了"的实时信号的，只是延迟约0.5s，且必须自己过滤掉 ValueChanged 的高频噪声。

### 结论（写给 WT-E，本轮修订）

补测把第四轮四个薄弱点里的三个从"不可用/证伪"翻成了"可用/有条件可用"：读取速度用一层子节点（非 depth-6 递归）读法把单行成本从 ~50ms 压到 ~0.08ms（多属性批量调用 ~0.065ms 最快）；随机态预测只要等 2s 结算不重开面板即可准确匹配连续三次 next track，且开关瞬间表内容确认会随之重排；observer 只要多订阅 WINDOW/APPLICATION 级并专盯 `kAXRowCountChangedNotification`/`kAXUIElementDestroyedNotification`（屏蔽 `kAXValueChangedNotification` 噪声），能拿到约0.5s延迟的真实变更信号，不必退化成纯轮询。仍然不可用的只剩一项：AX 直接设置 `kAXMinimizedAttribute` 依旧调用"成功"但不生效，最小化态本身构造不出来，该态下的可读性仍未验证。分组头行号也已钉死：History=行0，Playing Next 分组头实际文本是 "Continue Playing"（行201），不是本轮之前假设的 "Playing Next"/接下来播放/Up Next 字面量，任何按文本匹配头行的实现都要把这个词加进去。综合看，`AXPlayingNextQueueReader` 的可行性比第四轮判断的更乐观：轮询代价可以做到极低（亚毫秒级/行），且有一个约0.5s延迟的事件驱动信号可用于减少轮询频率；唯一没解决的是最小化态、以及仍需在更多曲库/更长时间上复核 observer 延迟与漏报率再定案。
