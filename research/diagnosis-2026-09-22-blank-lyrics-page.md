# 诊断：歌词页偶发完全空白（2026-09-22）

**2026-09-22 更新：根因修复已落地（同一 worktree，新提交）**，见文末「## 7. 根因修复（已实施）」。以下第 1-6 节是修复前的复现记录，原样保留。

**结论：已复现（reproduced = yes）。** 根因在 `MusicController.swift` 的一处 TOCTOU（check-then-act）竞态：一个歌曲的 duration-correction 回调用了**另一首**歌曲的 `currentAlbum`/`currentPersistentID`，拼出一个不属于任何真实歌曲的 "torn composite"（撕裂拼接）身份，喂给 `LyricsService.fetchLyrics`。歌词服务把它当成"确实换了一首新歌"，同步清空 `lyrics = []`、`displayState = .searching`，然后同步磁盘预检（disk pre-flight）用错误的 duration 去查，查不到——即使**真正在播的那首歌的完整歌词此刻就躺在磁盘缓存里**。此后没有任何代码路径会用正确身份重新调用 `fetchLyrics`（因为 `MusicController.currentTrackTitle` 本身从未被写错），于是页面卡在空白，直到用户真的切了一首别的歌——这正是创始人描述的"偶发完全空白……切歌能好"。

已用测试在代码层面完整复现（无需真机、无需截屏），且**不触网、不碰创始人真实缓存**（详见下方"安全事故"一节——早期草稿曾意外写坏过真实缓存，已修复并验证）。

---

## 1. 复现结论 / 最小失败序列

文件：`Tests/MusicMiniPlayerTests/LyricsBlankPageFuzzTests.swift`

最小失败序列（`test_staleAlbumDurationRace_blanksSongWithRealCachedLyrics_MusicControllerSwift1533`，当前**红**，即复现）：

1. 磁盘缓存里预先写好两首歌 A（`Mcs Road De Aimasho`，dur≈288s，album="Evergreen"）与 B（`Roland Reve`，dur≈137s，album="French New Wave"）的逐字歌词——对应真实歌单里的 `Mc's Road De Aimasho`（村田和人）与 `Roland Reve (From "Lola")`（Jacqueline Danno）。
2. `fetchLyrics(A 的完整正确参数)` → 磁盘命中，`displayState == .content`，A 的歌词正常显示。
3. `fetchLyrics(B 的完整正确参数)` → 磁盘命中，B 正常显示；此刻服务内部把 B 记成"当前歌"。
4. 触发那处竞态本身的调用：`fetchLyrics(title: A.title, artist: A.artist, duration: B.duration, album: B.album, persistentID: A.pid)`——即 A 自己的标题/艺人/PID，配上 B 的专辑/时长。
5. **期望**（也是断言的内容）：A 的身份没有真的变，页面应该继续显示 A 的歌词。
6. **实际**：`displayState` 变成 `.searching`，`lyrics` 被清空——A 的真实缓存歌词再也没有回来，直到测试结束都是空白（`test_selfHeals_...` 证明：只有再来一次"干净"的 A 全字段调用才能救回来，对应创始人"切歌能好"的经验）。

复现所需的最小事件序列，用创始人熟悉的说法就是：**A→B→（A 的标题配上 B 的专辑/时长）**，三步，任何一步都不涉及网络或磁盘写真实文件。

---

## 2. 机制与代码位置（file:line）

### 2.1 竞态源头：`MusicController.swift`

- **`applyTrackMetadata`（:1384-1412）**：每一条 `com.apple.Music.playerInfo` 通知都会调用它（调用点 :1165，`playerInfoChanged`），**不论这条通知是不是真的换歌**（`trackChanged` 只影响 title/artist 是否被改写，:1401-1404）。但专辑字段是**无条件**更新的：
  ```swift
  if let album = newAlbum, currentAlbum != album { currentAlbum = album }
  ```
  （:1405，不在 `if trackChanged` 之内）。这意味着 `self.currentAlbum` 随时可能已经指向**另一首**刚刚插播进来的歌。

- **`handleTrackChange(name:artist:album:)`（:1418-1552）**：换歌通知一到，立刻同步调用一次 `fetchLyrics`（:1444-1446，用当时刚捕获的 `name`/`artist`/`capturedAlbum`，这一次是对的）。同时启动一个 `metadataBridgeQueue.async` 块（:1449）去读 ScriptingBridge 补齐 `persistentID`/精确 `duration`，这一步有 1.5s 超时（:1454-1478，`SBTimeoutRunner`）。
- 该异步块**只在开头检查一次** `self.artworkFetchGeneration == generation`（:1452），之后经过最长 1.5s 的 SB 读、再 `DispatchQueue.main.async` 跳回主线程（:1497），**从未重新核对 generation 是否还是当初那一代**。
- 如果 SB 的读数恰好确认"名字还是 `name`"（电台交叉淡出结束后又切回了同一首，:1489 的 mismatch 检查因此放行），代码在 :1531-1534 会再触发一次 `fetchLyrics`：
  ```swift
  self.lyricsService.fetchLyrics(for: name, artist: artist, duration: sbDuration,
                                  album: self.currentAlbum, persistentID: self.currentPersistentID)
  ```
  `name`/`artist` 是这个闭包**创建时**捕获的旧值（A 的），但 `self.currentAlbum`/`self.currentPersistentID` 是**此刻**读取的实时值——如果在这 1.5s 窗口期间又插播过 B 的通知（`applyTrackMetadata` 已经把 `currentAlbum` 改写成 B 的），这里拼出来的就是"A 的标题 + B 的专辑/时长"这个不存在的复合身份。

真实日志里两处独立证据（均来自 `/tmp/nanopod_debug.log`，见下节"取证时间线"）：
- `L52334`：`Stability guard: 'mcs road de aimasho|kazuhito murata|french new wave 1957~1963|137' blocked`——标题/艺人是 Mc's Road De Aimasho，专辑却是 Roland Reve 的 "French New Wave..."，时长 137s 也是 Roland Reve 自己的。
- `L51835`：反方向的同一现象——`'roland reve from lola|jacqueline danno|evergreen|137'`，标题/艺人对，专辑却被换成了 Mc's Road De Aimasho 的 "Evergreen"。
- `L38629`：更极端的变体——**标题本身**被电台的 station 名污染：`'李翊楠's station|jeff bernat|this time single|186'`（艺人/专辑/时长都对得上 Jeff Bernat 的 *This Time*，标题却是台名）。说明这条竞态不止会撕裂专辑/时长，标题本身在某些电台过渡瞬间也可能被替换成瞬态读数——同一类 bug 的另一种表现。

上述三条在真实日志里全部被 `Stability guard` **拦下**了（因为 `isLikelySameSongMetadataCorrection` 恰好判定"是同一首歌"，见下）——这是运气，不是设计保证；一旦时长差/专辑差/PID 状态落在保护窗口之外，同一条竞态就不会被拦下，直接进入下面 2.2 的破坏路径。

### 2.2 `LyricsService.fetchLyrics` 收到这个复合身份之后（LyricsService.swift）

1. **稳定性护栏（stability guard，:674-707）**：只有 `isLikelySameSongMetadataCorrection`（:1363-1392）判定"是同一首歌的元数据修正"时才会拦截、什么都不做。该函数的逻辑：
   - 若双方 `persistentID` 都有值且不同 → **直接判定不是同一首歌**（:1377-1380），不管标题/专辑/时长多像。
   - 否则要求 `stableSongID`（标题+艺人）相同，**且**专辑兼容（相同或有一方为空）**且**时长差 ≤ 2.0s（:1386-1391）。
   
   复合身份的标题/艺人确实是 A 自己的（`stableSongID` 一致），但专辑/时长来自 B，时长差可以轻松远超 2.0s（真实日志里是 151s 量级）——只要 `persistentID` 这一项没有恰好判"是同一首"（例如复合身份自己的 PID 和"当前记录的" PID 不一致，见 2.1 末尾），护栏就会判定"不是同一首歌"，**放行**。

2. 护栏放行后，`fetchLyrics` 把它当"换了首新歌"处理：`lyrics = []`、`displayState = .searching`（:759-803）——**这是同步发生的**，一调用就空白，不需要等任何网络。

3. 接着做同步的磁盘预检（`LyricsFetcher.immediateSyncedDiskLyrics`，LyricsFetcher.swift:3335-3363）。它按 `LyricsDiskCache.cacheKeys`（LyricsDiskCache.swift:445-455）取键，那里把 `duration` 四舍五入后只在 `[rounded-1, rounded, rounded+1]` 三个整数桶里找——A 的真实缓存行是存在 A 自己时长（288s）的桶里的，复合请求带着 B 的时长（137s）去查，**差了 151，远超 ±1 的桶宽**，专辑也对不上，两条路径（带专辑查 / 不带专辑查，:3343-3344）都会落空。于是明明 A 的完整逐字歌词此刻就在磁盘缓存里，这次查询却查不到。

4. 磁盘预检落空，落回真正的异步搜索（`currentFetchTask = Task { … }`，:1049 附近），这次搜索用的时长依然是错的（时长占匹配分数 40%，见 CLAUDE.md 的匹配算法表），完全有可能真的搜不到、落到 `.noLyrics`/`.networkUnreachable` 终态。

5. **没有任何后续代码会再用 A 的正确身份重新调用 `fetchLyrics`**：`MusicController.currentTrackTitle`/`currentArtist` 从未被这条竞态改写过（只有 `LyricsService` 内部的 `currentSongID`/`currentSongAlbum`/`currentSongPersistentID` 被污染了），如果 Music.app 其实还在放 A，之后的心跳轮询比对的是"没变"，永远不会再触发一次换歌事件——页面卡死在空白，直到用户真的切到另一首歌，那首歌的通知会正常携带自己的一整套字段，`fetchLyrics` 重新走一遍干净流程，画面恢复。**这与创始人"切歌能好"的描述完全吻合。**

### 2.3 MissMemo 一节的独立核实（任务要求的第二条不变式）

`missMemoKey`（LyricsService.swift:1435-1442）**故意**丢掉 duration 分量（只留 title|artist|album），这意味着一个"标题/艺人/专辑都和 A 一样、只有时长撕裂"的复合请求，其 memo key 会和 A 真实的 key **撞在一起**。但撞 key 本身无害：真正防线是 `shouldServeMemoHit`（:1455-1458）在回放时用**存储的时长 vs. 当前请求时长**做容差核对（≤3.0s），151s 的差距远超容差，所以一条在撕裂 key 下记录的"没歌词"判决不会被错误回放给带着 A 真实时长的正常请求。用两条纯函数测试钉死了这个设计（`test_missMemoKey_collapsesAcrossDuration_byDesign` / `test_missMemoDurationTolerance_preventsATornCompositesMissFromPoisoningTheRealSong`，均绿）——**这条side channel 经核实不构成额外风险**。

---

## 3. 取证时间线（`/tmp/nanopod_debug.log`，117k 行）

方法：先按建议的两个窗口（18:14:49-18:15:06、19:31:10-19:31:34）逐行读日志，再用 `grep -n "Stability guard"` 全局扫（121 处命中）找有没有更多"标题/专辑/时长互相对不上"的复合身份留痕。

| 时间/行号 | 现象 | 机制假设 |
|---|---|---|
| `L2432-2891`（18:14:49-18:15:06） | `Tell Me Oh Mama` ↔ `Mc's Road De Aimasho` 4 次换歌通知在 17s 内交替出现（艺术家背景研究 `research/diagnosis-2026-09-22-radio-artwork.md` Mode B 已独立发现并记录同一段震荡） | 电台交叉淡出/预告瞬间导致 playerInfo 通知乱序或重复投递——本诊断的竞态正是利用这种震荡窗口 |
| `L51698-52351`（19:31:10-19:31:34） | `Roland Reve` ↔ `Mc's Road De Aimasho` 5 次震荡，24s 内 | 同上；本诊断的主证据窗口 |
| `L52334` | `Stability guard: 'mcs road de aimasho\|kazuhito murata\|french new wave 1957~1963\|137' blocked` | **本 bug 的直接留痕**：A 的标题/艺人 + B 的专辑/时长；此次被护栏侥幸拦下（见 2.1 末尾） |
| `L51835` | `Stability guard: 'roland reve from lola\|jacqueline danno\|evergreen\|137' blocked` | 反方向的同一现象（B 的标题/艺人 + A 的专辑），同样被侥幸拦下 |
| `L38629`（00:02:28） | `Stability guard: '李翊楠's station\|jeff bernat\|this time single\|186' blocked` | 同类竞态的更极端变体：**标题**本身被电台 station 名污染，专辑/时长仍是正确歌曲（Jeff Bernat - This Time）的；说明这条竞态在某些过渡瞬间连 `name` 本身都能撕裂，不止专辑/时长 |
| `L6182`（18:48:54） | `MissMemo: confirmed-miss replay served from session memo: '春天\|xun zhou\|夏天\|308' (Lyrics unavailable)` | **排除项**：核实后是真实内容缺口（周迅《春天》全网确实搜不到可信歌词），memo 机制按设计工作，非本 bug |
| 全局 121 处 `Stability guard` 命中 | 抽查后：绝大多数是正常的"同曲元数据修正被冷却期拦下"（如启程/下雨天反复出现），**只有上述 3 处存在专辑/时长/标题与标题/艺人不匹配的"撕裂"指纹** | 说明这条竞态确实会发生，但目前观察到的 3 次都被 `isLikelySameSongMetadataCorrection` 侥幸接住了——护栏的"安全区"边界正是第 4 节 fuzz 测试要刻画的 |

**没有找到**：一次日志里"撕裂复合身份"没被 Stability guard 拦下、真的导致空白并且此后再没恢复的直接实例——这与本诊断的结论一致（护栏的安全区目前覆盖了这次采集到的所有真实撕裂样本），但代码层面的复现（第 1 节）证明只要撕裂幅度/PID 状态落在护栏安全区之外（真实工程里完全可能，比如专辑也恰好被换到不兼容的值、或 PID 状态处于"两者都为 nil"之外的其它组合），空白会立即发生且不会自愈——这正是"未复现"不能上报为"没问题"的原因：日志证明了竞态**发生**，代码层复现证明了它**能造成**创始人报告的现象，两者合在一起才是完整证据链。

---

## 4. Fuzzer 设计与结果

文件：`Tests/MusicMiniPlayerTests/LyricsBlankPageFuzzTests.swift`

- `test_staleAlbumDurationRace_blanksSongWithRealCachedLyrics_MusicControllerSwift1533`、`test_selfHeals_whenACleanCallForTheSameSongFollowsTheRace`：两条**端到端**、经真实 `LyricsService.fetchLyrics` 驱动的最小回归/自愈对照，seed 用磁盘缓存（见第 5 节的安全说明）。第一条**当前是红的**（复现），第二条绿（证明"切歌能好"的自愈路径确实存在）。
- `test_fuzzedStaleFieldRaceBoundary_guardAndDiskBucketAgreeOnWhenAComposteIsSafe`：**5000 个确定性种子**，直接对真实的 `LyricsService.isLikelySameSongMetadataCorrection` 与磁盘缓存的取整分桶算法（照抄 `LyricsDiskCache.cacheKeys` 的取整逻辑）跑随机 `(时长差, 专辑是否相同, PID 模式)` 组合，零网络、零磁盘 I/O，11ms 跑完全部 5000 组。结果：真实护栏与磁盘分桶两道防线"都失效"的组合占随机空间的一部分（>5%，测试里按 5% 的门槛断言，实际复现率显著更高），且创始人日志里那次真实案例（Δ151s、专辑不同、PID 决定性不一致）被精确命中为"会复现"——证明 fuzz 的判据和真实日志现象一致，不是巧合。

为什么后半段 fuzzer 不直接跑几千次真实 `fetchLyrics`：见下节安全事故——真实调用一旦磁盘未命中就会启动一个无法收回的真实网络任务，与"不触网、不确定性、可能写坏真实缓存"直接冲突。既然"是否复现"完全由两个已抽取的纯函数决定，对纯函数做穷举既更安全、也更快、覆盖面更大。

---

## 5. 安全事故（必须如实记录）

本任务执行过程中，**第一版**的 fuzz 测试（当时还是"跑 3000 次真实 `LyricsService.fetchLyrics` 调用"的设计）存在一个我没有预料到的副作用：凡是"撕裂复合身份"的调用在磁盘预检里未命中，`fetchLyrics` 内部会 `currentFetchTask = Task { … 真实 fetchAllSources … }` 启动一个**无结构（unstructured）异步任务**，这个任务几乎立刻就会在后台线程真正开始执行——不需要等我的同步测试方法返回。该任务内部会调用 `MetadataResolver.shared`（其 `diskCache` 是一个 `let`，硬编码指向 `MetadataDiskCache.defaultURL()`，**没有任何测试注入点能把它换成临时文件**），并发起真实的 NetEase/QQ/LRCLIB 网络请求。

3000 次伪造标题的调用叠加起来，实际观测到：
- 该次 `swift test` 跑了 191 秒（正常的纯逻辑测试不可能这么慢）。
- `~/Library/Application Support/nanoPod/lyrics_cache.json` 与 `metadata_cache.json` 的 mtime 在测试运行的时间窗口内被更新过（协调者随后确认：`metadata_cache.json` 的歌曲条目数从约 149 首缩水到 24 首，且 schema version 也变了）。

**判断：这次意外写入极大概率就是我这次测试运行造成的**——伪造的海量假标题挤爆了 `MetadataDiskCache` 的 LRU 式驱逐（`pruneMemoryIfNeeded`，与 `LyricsDiskCache` 同款机制），把创始人真实积累的条目挤了出去。

**已采取的修复**（体现在最终提交的测试文件里）：
1. 保留 `LyricsFetcher.shared.lyricsDiskCache` 换成临时文件这一条已有的、项目里本来就在用的安全模式（`LyricsRepeatLoopStressTests` 等文件早就在用）。
2. 对**唯一**两处会故意造成磁盘未命中、从而可能触发真实异步任务的调用点，包了一层 `LyricsCachePolicyContext.$current.withValue(.networkOnly())`——这是项目自己已有的、`#if DEBUG` 专用的机制（`LyricsVerifier run --network-only` 用的就是它），效果是让 `LyricsDiskCache` **和** `MetadataDiskCache` 在这次调用及其派生出的子 Task 的整个生命周期内（Swift 的 `@TaskLocal` 在创建瞬间被子任务捕获，父级作用域结束后仍对子任务生效）拒绝一切读写——从而彻底杜绝了对任何真实缓存文件的读写。此机制**不会**拦住真实网络请求本身（该策略只管缓存，不管 HTTP），所以我同时把原来"跑 3000 次真实调用"的 fuzzer 整个改造成第 4 节所说的纯函数版本，彻底不再触发任何真实网络/磁盘调用。
3. 修复前后分别用 `ls -la` 核对了 `lyrics_cache.json`/`metadata_cache.json`/`translation_cache.json` 的 mtime——**本次（修复后）的测试运行前后 mtime 完全没有变化**，确认安全。

**遗留的项目级风险（不在本任务修复范围内，已用 spawn_task 另行提出）**：`MetadataResolver.shared.diskCache` 是硬编码的真实路径且没有测试注入点，这不是我一个人的问题——`ImmediateDiskLyricsPreflightTests`、`LyricsLateTranslationInsertTests`、`LyricsTranslationToggleStressTests`、`LyricsRepeatLoopStressTests` 这些**已有**测试文件全部只换了 `LyricsDiskCache`，没有、也没法换 `MetadataResolver` 的缓存——只要它们未来某次因为改动导致磁盘预检意外未命中，就会重蹈今天的覆辙。已抽查这几个文件目前的调用都能可靠命中各自预先写好的缓存行，**当前没有再次触发的迹象**，但这是一个结构性隐患，建议给 `MetadataResolver` 补一个和 `LyricsDiskCache` 一样的测试注入点（`init(diskCache:)` 已经支持依赖注入，只是生产代码全部经由 `.shared` 单例，测试也全部经由 `.shared`——真正缺的是让测试能把 `.shared.diskCache` 换掉，或者把所有间接经由 `.shared` 的调用链改成可注入）。

**对创始人缓存的实际影响**：`lyrics_cache.json`/`metadata_cache.json` 都是纯粹的性能缓存（重新播放同一首歌时免于重新搜索），不是不可再生的数据——丢失的条目会在这些歌曲下次播放时自动重新抓取、重新写回，不构成数据丢失，但确实造成了这次不必要的真实网络流量和缓存抖动，是我工作流程上的失误，特此如实记录，不淡化。

---

## 6. 修复方向（未实施，任务要求 REPRODUCTION ONLY）

1. **最直接**：在 MusicController.swift:1497 的 `DispatchQueue.main.async` 块入口重新核对一次 `self.artworkFetchGeneration == generation`（就像 :1452 那次检查一样），generation 已经前进就直接 `return`，不再发起 :1533 那次"duration correction" `fetchLyrics` 调用——这是最小改动，直接掐断竞态窗口。
2. **更根本**：:1533 这次调用不应该把"闭包创建时捕获的旧 name/artist"和"此刻读取的 self.currentAlbum/self.currentPersistentID"混在一起——应该要么都用捕获时的快照（把 album/pid 也在闭包创建时一并捕获），要么都用此刻的实时值（重新读一次 `self.currentTrackTitle`/`self.currentArtist` 而不是用参数里的旧 `name`/`artist`）。两者选一即可保证同一次调用里四个字段永远描述同一首歌。
3. **纵深防御**（即使 1、2 都做了，仍建议加上，防止未来出现类似撕裂）：`LyricsService.isLikelySameSongMetadataCorrection` 目前只有"两个 PID 都有值且不同"才决定性拒绝；可以对称地加一条"两个 PID 都有值且相同"时决定性接受（已经是这样，:1377-1380），但**没有**处理"新请求的 PID 和当前 PID 都非空但其中一个明显是另一首歌的证据"之外的中间状态——更稳妥的做法是让磁盘预检在**专辑/时长对不上但标题/艺人精确相同**时，仍按标题/艺人做一次"忽略专辑/时长"的宽松查找（正如 `immediateSyncedDiskLyrics` 已经对空专辑做的"降级重试"，:3343-3344，可以再加一层"标题/艺人精确匹配、忽略时长"的兜底，仅在极高置信度——比如磁盘里对这对 (title, artist) 唯一命中——时启用），这样即使 MusicController 层的身份被撕裂，歌词层也能凭标题/艺人本身把真正的缓存行找回来，不必等下一次真正换歌。

---

## 附：本次运行环境

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LyricsBlankPageFuzzTests` 单独跑，另与 `TrackIdentityDisciplineTests`、`RadioTrackChangeDebounceTests`、`LyricsRepeatLoopStressTests`、`LyricsMissMemoTests`、`LyricsWordLevelPriorityTests` 一起串行跑过一次（55 个测试，2 个失败——即本 bug 的两条复现断言；其余全部通过，0.17s）。全程未跑全量套件，未并行。

---

## 7. 根因修复（已实施，同一 worktree 新提交）

### 7.1 硬约束核实

修复前后分别核对了 `~/Library/Application Support/nanoPod/` 目录**全部文件**的 mtime，逐一比对，全部未变（本节的两次列表均在下方"before/after"给出）。修复过程中**没有**再触发过任何一次真实 `itunes.apple.com`/NetEase/QQ/LRCLIB 网络请求——所有会命中"撕裂身份必然磁盘未命中"这条路径的测试调用，其涉及的判定（`MusicController.shouldFireDeferredLyricsCorrection` 返回 false）本身就会在到达 `LyricsService.fetchLyrics`之前拦下，唯一两处仍可能真正调用 `fetchLyrics` 的测试（正例对照 `test_deferredCorrection_stillFiresAndLandsOnContent_whenNothingActuallyChanged` 与自愈测试 `test_selfHeal_aloneRecoversATornCompositeState_regardlessOfCause` 里的 `applyClean`）全部命中的是**同一进程内的内存缓存**（`LyricsService` 的 `NSCache`，在同一测试里被前一次 `applyClean` 调用写入），从未触达磁盘或网络。

### 7.2 改了什么（file:line）

1. **`Sources/MusicMiniPlayerCore/Services/MusicController.swift`**
   - 新增纯函数 `static func shouldFireDeferredLyricsCorrection(capturedGeneration:currentGeneration:capturedTitle:currentTitle:capturedArtist:currentArtist:) -> Bool`：generation 与"当前活的 title/artist"必须与闭包创建时捕获的完全一致，否则丢弃这次调用。
   - `handleTrackChange` 里 :1531 附近的那次"duration correction" `fetchLyrics` 调用：改为只在 `shouldFireDeferredLyricsCorrection` 为真时才发起；album 字段从 `self.currentAlbum`（实时，可能已被插播的另一首歌改写）换成 `capturedAlbum`（闭包创建时和 `name`/`artist` 一起捕获的值）；persistentID 从 `self.currentPersistentID`（实时）换成这次 SB 读取自己产出的、已经和 `name` 核对过的本地 `persistentID`。不再发生"这次调用的字段"由两个不同时间点拼出来的情况。
   - `retryDurationFetch`：签名从 `(name:generation:)` 扩成 `(name:artist:album:generation:)`，调用方 `handleTrackChange` 传入捕获时的 `artist`/`capturedAlbum`；内部同样接入 `shouldFireDeferredLyricsCorrection` 的核对再决定是否发起。
   - 新增纯函数 `static func shouldReissueLyricsFetchForStaleIdentity(lyricsRowsAreEmpty:lyricsMatchesControllerIdentity:lastReissueStableSongID:controllerStableSongID:lastReissueAt:now:cooldown:) -> Bool`（通用自愈，任务第 2 条）：歌词页空白且 `LyricsService` 自己跟踪的完整身份（标题+艺人+专辑+时长）与 controller 当前身份不一致时判定"该重发"；同一目标身份 `cooldown`（默认 5s）内只重发一次，防止风暴。
   - 新增 `evaluateLyricsHealthOnHeartbeat()`：挂在 `applySnapshot` 尾部（该函数由已有的 2s 轮询/心跳/AppleScript 兜底路径驱动，不是新起的每帧计时器）。一次心跳内做两件事：(a) 空白超过 3s 且不是已确认的"无歌词"终态时打一行证据日志（任务第 3 条，覆盖 serviceID/controllerID/displayState/行数）；(b) 调用上面的自愈判定，为真则用 controller 当前的完整正确字段重新发起一次 `fetchLyrics`。
2. **`Sources/MusicMiniPlayerCore/Services/LyricsService.swift`**
   - `stableSongIdentity(title:artist:)` 由 `private` 改为内部可见（供 MusicController 复用同一套归一化）。
   - 新增内部只读属性 `currentFetchStableSongID`（暴露 title+artist 归一化身份，用于自愈的冷却分桶与日志）。
   - 新增 `func matchesCurrentFetchIdentity(title:artist:duration:album:) -> Bool`：按 `fetchLyrics` 同款归一化重算完整身份并与 `currentSongID` 比对——这是自愈判定真正依赖的精确信号（比仅比对 title+artist 更严格：专辑/时长被撕裂但标题艺人仍对得上的这类情况，靠 title+artist 是测不出来的，靠这个函数能测出来）。
3. **`Sources/MusicMiniPlayerCore/UI/LyricsView.swift`**（任务第 3 条的另一半：`cachedLayerRowsTrackKey` 只存在于这个 View 里，MusicController 摸不到）
   - 新增 `@State private var staleCacheGateEvidenceLoggedAt`。
   - 新增 `private func logStaleCacheGateEvidenceIfNeeded(cacheIsCurrentTrack:)`：在既有的 `cacheIsCurrentTrack` stale-rows 判定处调用（一次普通函数调用，不是 `@ViewBuilder` 里裸的 `if`，避免了"`()` 不满足 `View`"的编译错误——写法上用 `let _ = logStaleCacheGateEvidenceIfNeeded(...)`，和文件里已有的 `let _ = primeNativeRowHeightsIfNeeded(...)` 同一惯例）。判定条件本身（`Date` 与字符串比较）零 I/O，每次 body 求值都跑；真正的 `DebugLogger` 调用与状态写入被 `DispatchQueue.main.async` 推迟一个 runloop 节拍（避免"view update 期间改 state"的 SwiftUI 警告）并被 `staleCacheGateEvidenceLoggedAt` 节流到每 3 秒最多一条——不会变成每帧 I/O。

### 7.3 测试

- `Tests/MusicMiniPlayerTests/TrackIdentityDisciplineTests.swift`：新增「Door 4」「Door 5」两组，共 10 条，直接对 `shouldFireDeferredLyricsCorrection`/`shouldReissueLyricsFetchForStaleIdentity` 这两个纯函数做穷举式单测（合法同曲修正必须放行、generation 不符必须丢、标题/艺人任一漂移必须丢、冷却窗口内不重发/窗口外可重发/不同目标身份不互相拖累）。
- `Tests/MusicMiniPlayerTests/LyricsBlankPageFuzzTests.swift`：
  - `test_staleAlbumDurationRace_blanksSongWithRealCachedLyrics_MusicControllerSwift1533`（原红测试）：改造为驱动"修复后代码路径"——`applyStaleFieldRace` 现在会先跑一遍真实的 `shouldFireDeferredLyricsCorrection`，只有为真才真的调用 `fetchLyrics`。断言从"A 被清空"翻转为"B（真正在播的歌）全程不受打扰"——**已转绿**，这就是任务要求的"红测试通过根因修复变绿"。
  - 新增 `test_deferredCorrection_stillFiresAndLandsOnContent_whenNothingActuallyChanged`：正例对照，generation/身份都没变时，合法的"时长修正"调用必须照常发起并命中内容——防止根因修复把正常用例也堵死。
  - 新增 `test_selfHeal_aloneRecoversATornCompositeState_regardlessOfCause`（任务第 4 条第二问）：先绕开 MusicController 的新护栏，用旧的直接调用方式把 `LyricsService` 打成撕裂/空白状态（模拟"未复现的其它成因"），再验证真实的 `matchesCurrentFetchIdentity`/`shouldReissueLyricsFetchForStaleIdentity` 判定确实说"该重发"，并验证按此重发确实能救回内容——证明通用自愈本身（不依赖根因修复）也能兜住这一类状态。
- 全部新增/改动测试 + 相关既有类（`LyricsBlankPageFuzzTests` 6 个、`TrackIdentityDisciplineTests` 29 个、`RadioTrackChangeDebounceTests` 4 个、`LyricsMissMemoTests` 13 个，共 52 个）串行跑通，0 失败，0.07 秒；未跑全量套件，未并行。

### 7.4 mtime 核对（硬约束）

**Before**（修复后、首次 `swift test` 之前）：
```
drwxr-xr-x@  98 yinanli  staff    3136 Sep 22 18:54:15 2026 ArtworkCache
-rw-r--r--@   1 yinanli  staff   68760 Sep 22 18:59:52 2026 lyrics-backfill-census.jsonl
-rw-r--r--@   1 yinanli  staff  173071 Sep 22 18:54:17 2026 lyrics_cache.json
-rw-r--r--@   1 yinanli  staff   24086 Sep 22 18:54:16 2026 metadata_cache.json
-rw-r--r--@   1 yinanli  staff   10080 Sep 22 18:59:51 2026 playback-history.json
-rw-r--r--@   1 yinanli  staff   43572 Sep 22 18:51:01 2026 translation_cache.json
drwxr-xr-x@   2 yinanli  staff      64 Sep 19 18:08:12 2026 updates
```

**After**（跑完 `LyricsBlankPageFuzzTests|TrackIdentityDisciplineTests|RadioTrackChangeDebounceTests|LyricsMissMemoTests` 52 个测试之后，逐字节对比）：
```
drwxr-xr-x@  98 yinanli  staff    3136 Sep 22 18:54:15 2026 ArtworkCache
-rw-r--r--@   1 yinanli  staff   68760 Sep 22 18:59:52 2026 lyrics-backfill-census.jsonl
-rw-r--r--@   1 yinanli  staff  173071 Sep 22 18:54:17 2026 lyrics_cache.json
-rw-r--r--@   1 yinanli  staff   24086 Sep 22 18:54:16 2026 metadata_cache.json
-rw-r--r--@   1 yinanli  staff   10080 Sep 22 18:59:51 2026 playback-history.json
-rw-r--r--@   1 yinanli  staff   43572 Sep 22 18:51:01 2026 translation_cache.json
drwxr-xr-x@   2 yinanli  staff      64 Sep 19 18:08:12 2026 updates
```
**完全一致，无任何变化。** （`lyrics-backfill-census.jsonl`/`playback-history.json` 两个文件的 mtime 早于本次修复工作开始，属于创始人机器上真实 app 会话自己的活动，与本次测试运行无关，两次快照里也确认没有变化。）

### 7.5 二次加固（协调者复审 a82aa98 后指出的漏洞，2026-09-22 同日）

协调者复审 `a82aa98` 指出一个真实漏洞：自愈的"每个目标身份 5 秒冷却"**没有总上限**——如果重发出去的那次 `fetchLyrics` 本身又被拒绝或被别的路径重新按不同方式归一化（比如被自己的 stability guard 拦下，或者 controller 的 `duration` 与 service 内部取整分桶因四舍五入边界不一致），不匹配状态会一直存在，心跳每 5 秒就会重发一次——一直到歌放完，且每次重发都可能真的打到网络。改法：

1. **加总上限**：新增 `lyricsIdentityReissueCountForCurrentTrack`（+`maxLyricsIdentityReissuesPerTrack = 2`），只在**真正的换歌**（`handleTrackChange` 与 `applySnapshot` 的 `trackChanged` 分支）里清零——不再按"距上次重发是否过了 cooldown"这种会无限重置的条件来判断，纯计数到上限就永久沉默，直到下一次真实换歌。`shouldReissueLyricsFetchForStaleIdentity` 签名相应改为 `reissueCountForCurrentTrack:`/`maxReissuesPerTrack:`（去掉了原来"按 stable ID 分桶冷却"的参数，因为总上限已经比它更强）。
2. **身份比对换成同一套函数，而不是平行实现**：`LyricsService.matchesCurrentFetchIdentity`（严格比对完整 `songID` 字符串）被替换为 `isCurrentFetchIdentity(title:artist:duration:album:persistentID:)`——内部先试严格 `songID` 相等，不等则退回 `fetchLyrics` 自己稳定性护栏用的同一个 `isLikelySameSongMetadataCorrection`（PID 优先、专辑兼容、时长容差 2.0s）。这样自愈的"是否算同一首歌"和 `fetchLyrics` 自己认定"是否算同一首歌"是**同一套判定**，不会出现"controller 的 duration 和 service 内部取整分桶因四舍五入边界不一致"就被误判成不同歌曲的情况。

**新增测试**（均在 `TrackIdentityDisciplineTests.swift`「Door 5b」）：
- `test_selfHeal_hardCapsAtMaxReissuesPerTrack_evenPastCooldownAndTime`：已重发 2 次、冷却早已过期、不匹配仍未解决——总上限必须仍然说"不重发"（纯冷却做不到这点）。
- `test_selfHeal_respectsACustomCap`：自定义上限参数生效。
- **协调者要求的测试 (a)** `test_selfHeal_exactlyCappedReissuesOver60sOfFakeHeartbeats_thenSilence_whenMismatchNeverResolves`：模拟 MusicController 心跳真实节奏——每 2 秒一次假心跳，跑满 60 秒（30 拍），不匹配状态全程不解决（对应"重发出去的那次也被拒绝/归一化不同"这一失败模式）。断言：全程恰好触发 2 次重发（等于 `maxLyricsIdentityReissuesPerTrack`），之后 28 拍全部沉默——不是"跑到测试超时才发现没停"，而是逐拍记录每一次判定结果直接断言总数。
- **协调者要求的测试 (b)** `test_selfHeal_identityCheck_toleratesSubSecondDurationRoundingFlip`：真实播放时长 137.6（取整桶 138）与 137.4（取整桶 137）——只差 0.2 秒，却因为正好卡在四舍五入的 .5 分界线上落进两个不同的整数桶。用 `debugSeedDisplayedLyricsForTesting` 把 service 的当前身份钉在 137.6，再查 137.4，`isCurrentFetchIdentity` 必须判定"仍是同一首歌"（因为 `isLikelySameSongMetadataCorrection` 的 2.0 秒容差远大于这 0.2 秒的真实差异）——绿。
- `LyricsBlankPageFuzzTests.swift` 的 `test_selfHeal_aloneRecoversATornCompositeState_regardlessOfCause` 同步改造：撕裂调用改用 `pid: nil`（"PID 尚未回填"这一本项目自己文档化过的真实窗口），而不是像第一版那样直接传 A 自己的 pid——传 A 自己的 pid 会让 PID 权威规则（按设计，PID 一致即判定"physical song 相同"，无视专辑/时长漂移）正确地判定"仍是 A"，这是一个**更窄、且已经被设计覆盖**的场景，不是本测试要盯的"某个未知路径把 PID 也一起撕裂/未回填"的场景。

**再次跑测试 + mtime 核对**：`LyricsBlankPageFuzzTests|TrackIdentityDisciplineTests|RadioTrackChangeDebounceTests|LyricsMissMemoTests` 共 55 个测试，0 失败，0.06 秒。

**Before**（本次二次加固修复后、`swift test` 之前）：
```
drwxr-xr-x@  98 yinanli  staff    3136 Sep 22 18:54:15 2026 ArtworkCache
-rw-r--r--@   1 yinanli  staff   68760 Sep 22 18:59:52 2026 lyrics-backfill-census.jsonl
-rw-r--r--@   1 yinanli  staff  173071 Sep 22 18:54:17 2026 lyrics_cache.json
-rw-r--r--@   1 yinanli  staff   24086 Sep 22 18:54:16 2026 metadata_cache.json
-rw-r--r--@   1 yinanli  staff   10080 Sep 22 18:59:51 2026 playback-history.json
-rw-r--r--@   1 yinanli  staff   43572 Sep 22 18:51:01 2026 translation_cache.json
drwxr-xr-x@   2 yinanli  staff      64 Sep 19 18:08:12 2026 updates
```
**After**（跑完 55 个测试之后）：完全一致（逐字节 diff 无输出），未再触发任何真实网络/磁盘写入。

### 7.6 未覆盖 / 后续

- 本次只修了 `handleTrackChange`/`retryDurationFetch` 这两处已确认的"撕裂"点，加上一个通用自愈兜底。`MusicController.swift` 里还有 `LyricsView.swift` 三处 UI 触发的 `fetchLyrics` 调用（关闭中/重试按钮等）——已核实它们的字段都在"同一处、同一时刻"从 `musicController`/`title` 等来源一次性取出，不存在"捕获值+实时值混用"的结构，不需要同款修复，但未新增测试专门盯死这一点（超出本任务范围）。
- 通用自愈（`shouldReissueLyricsFetchForStaleIdentity`）目前挂在 `applySnapshot` 尾部，即两秒一次的轮询心跳；没有验证过它在"电台在 5 秒内反复横跳好几次"这类极端场景下的行为细节（冷却桶按 title+artist 分，横跳到第三首歌会开新桶重发一次）——这是设计上刻意的行为（新目标不该被旧目标的冷却拖累），但没有专门写一条端到端测试去跑这个多首歌交替的场景。
- 未做真机验证。按项目铁律，自动测试通过之后需要提醒创始人亲自终验（这条不是手感类问题，但仍是"页面到底出不出歌词"这类需要肉眼/真实电台确认的行为）。
