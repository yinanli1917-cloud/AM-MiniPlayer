# Spec: 电台封面取不到 — 多店面 iTunes 查询（2026-09-22）

## 证据（已核实）
- 调研报告：`research/diagnosis-2026-09-22-radio-artwork.md`（主 checkout 里；只读参考）。今天 302 次取封面中 18 次换歌前始终无图，其中 10 次整首歌都没图（最长 330s）。这 18 次都是同一个样子：SB 对流媒体/电台曲目静默返回 nil（结构性，已知），iTunes 两轮「全部策略失败」，NetEase 无果，PlaybackSession 无果。
- 调研把这 10 次判为「各曲库都没有这首歌」。**这个结论是错的**，主会话已用 curl 实测推翻：
  - 用户的 Apple Music 店面是中国区（`com.apple.itunescloud` storefrontID 143465），系统 locale `en_CN`。
  - `fetchArtworkViaITunesAPI`（`Sources/MusicMiniPlayerCore/Services/MusicController+Artwork.swift` 约 781 行）请求 `https://itunes.apple.com/search?term=…&media=music&entity=song&limit=15`，**不带 `country`**，默认只查美区。
  - iTunes Search API 对 `country=CN` 一律返回 0 条（实测 7 首全 0）。
  - 失败曲目在别的店面都能查到，且 TW/HK 店面（加 `lang=en_us`）常给出与电台元数据**完全相同**的英文标题与艺人：
    - `Gatsby Woman (2020 Remastered)` / `Kingo Hamada`：US 0；TW/HK 有同名同艺人。
    - `Who Are You? (DJ Version) [2022 Remaster]` / `Fujimaru Yoshino`：US 0；TW/HK 有。
    - `Starlight Ballet` / `Piper`、`Jellyfish (feat. Michael Seyer)` / `Sunset Rollercoaster`、`SHYNESS BOY` / `Anri`：US 0 或只有别人的同名翻唱；JP/TW/HK 有。
    - `Misty (feat. Glenn Osser and His Orchestra)` / `Johnny Mathis`：US 用完整标题 0 条，用 `Misty Johnny Mathis` 能查到。
    - `Ripples` / `Danny Chan`：只有 `漣漪/陳百強`（标题艺人都本地化），文本上对不上 —— 本次不强求。
  - 连续二三十次请求后 iTunes 开始拒绝（返回非 JSON），**有频率上限**，不能无脑扇出。

## 要做的
1. **先复现（项目铁律）**：给 iTunes 封面查询加一个最小的注入缝（HTTP 取数闭包或协议，参照 `RowArtworkStoreTests.swift` 的闭包注入风格，以及 `TrackIdentityDisciplineTests.swift` 抽纯函数的做法），用上面实测的形状做 fixture：美区空、TW 区有同名同艺人。对现有代码跑，必须失败（返回 nil）。再加一条：完整标题带 `(feat. …)` 查空、去掉括号段后能查到。
2. **修**：
   - 同一查询词并行查多个店面，取 `scoreArtworkCandidate` 可靠且总分最高的结果；分数相同按店面顺序定。店面集合做成一个有注释的常量（覆盖 Search API 实际能服务的主要目录：US、JP、TW、HK），加 `lang=en_us` 让非英语店面尽量回英文名。如果 `MetadataResolver` 已有可复用的地区推断（`inferRegions`），把推断出的地区排在前面。不要写针对某首歌、某个艺人的特判。
   - 控制请求量：多店面只用在第一个查询词上；只有全部店面都没有可靠结果时，才用「去掉括号/方括号段的标题 + 艺人」再查一轮（仍多店面）。去掉原来会大量无效扇出的顺序调换词与纯标题词，或者说明为什么保留。总请求数在报告里列出（最坏情况每次换歌几次请求）。
   - 超时：现在是 1.0s，从中国网络偏紧。多店面是并行的，可以放宽到与 3 秒体验预算相容的值（例如 1.5–2.0s），说明取值理由。
   - 日志：每个店面记一行结果（hit / empty / error 及错误类型），让日常使用自动留证。`fetchArtwork` 里 SB 取不到时补一行 `else` 日志。
3. 复现测试转绿；已有的 `RowArtworkFetchPolicyTests`、`RowArtworkStoreTests`、`TrackIdentityDisciplineTests` 仍通过。

## 不在本次范围（写进报告当后续项，不要修）
- 电台换歌通知在十几秒内在两首歌间来回翻转 4–5 次，导致取封面被打断（报告 Mode B，`MusicController.swift:1433`、`:2347`）。
- Deezer 全程 0 命中且错误被吞；MusicKit 因 developer token 失败从不运行。
- `Ripples`→`漣漪` 这类标题艺人都本地化的情况。

## 约束
- 只串行跑相关测试类：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter <Class>`。禁止全量、禁止并行 swift test。`swift build` 必须过。
- 测试里不许打真网络。
- 不用 computer use、不截图、不启动 app。
- 验证完在 worktree 里用英文 commit（`fix(artwork): …`），结尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。不 push，不 merge。

---

## 结果（2026-09-22 实现完成）

### 复现（先复现再修）

`fetchArtworkViaITunesAPI` 原来是 private 实例方法，直接用 `URLSession`/`HTTPClient` 打真网络，没有任何注入缝，无法在"改之前的代码"上直接跑单元测试。按项目铁律的做法：先加最小注入缝（`ITunesArtworkTransport` closure，风格照抄 `RowArtworkStore` 的 closure-injection），再在同一个注入缝上先用"旧行为"验证失败、再验证新实现转绿——不是分两次提交，是同一个会话里先后跑了两遍：

1. 把 `fetchArtworkViaITunesAPIRound` 里的店面来源临时改成写死 `[ArtworkStorefront(country: "US", lang: nil)]`（旧代码从来没传 `country`，效果上就等于只查美区），跑 `ArtworkStorefrontSelectionTests`——**6 个测试失败**，全部是依赖多店面的编排级测试：
   ```
   test_orchestration_round1Hit_returnsImage_withoutRound2: XCTAssertNotNil failed（TW 命中拿不到，因为只查了 US）
   test_orchestration_round1EmptyEverywhere_fallsBackToStrippedTitleRound2: XCTAssertNotNil failed + 请求数 2≠8
   test_orchestration_noBracketsToStrip_skipsRound2_afterTotalMiss: 请求数 1≠4
   test_orchestration_totalMissWithBrackets_costsAtMostTwoRoundsOfStorefronts: 请求数 2≠8
   （另 2 个同类失败）
   Executed 17 tests, with 6 failures
   ```
   纯函数级测试（`selectBestITunesArtwork` 直接喂 fixture）在这一步不受影响——它们本来就不依赖店面遍历逻辑，用真实 curl 证据("美区空、TW 区有同名同艺人")做 fixture，天然验证的是"给它多店面数据它能不能选对"，这条证据链在报告 `research/diagnosis-2026-09-22-radio-artwork.md` 和创始人主会话 curl 实测里都成立。
2. 撤回临时改动，恢复 `orderedArtworkStorefronts(title:artist:)`，重跑同一测试类——**17/17 通过**。

这证明了：问题确实出在"只查一个店面"，不是评分逻辑，也不是别的假设。

### 设计

- **店面集合**（`MusicController.artworkITunesStorefronts`，写死 4 个，带注释）：`US`(无 lang) / `JP`(lang=en_us) / `TW`(lang=en_us) / `HK`(lang=en_us)。四个店面覆盖了报告里全部失败样本（Gatsby Woman/Kingo Hamada、Who Are You?/Fujimaru Yoshino、Starlight Ballet/Piper、SHYNESS BOY/Anri、Misty/Johnny Mathis）。没有做成全店面扫描——报告明确写了"连续二三十次请求后 iTunes 开始拒绝"，4 个是刻意的小集合。
- **店面排序**：`orderedArtworkStorefronts` 复用 `LanguageUtils.inferRegions`（`MetadataResolver.inferRegions` 只是转发同一个函数），把猜出的地区排到前面，其余按声明顺序追加——纯排序，不影响"查不查"，只影响同分时"谁赢"。对纯 ASCII 标题+艺人（电台这批失败样本全是这种），`inferRegions` 猜 `JP/KR/HK/TW`，其中 `KR` 不在我们的店面集合里被丢弃，最终顺序是 `JP, HK, TW, US`。
- **两轮查询**：round1 用 `"title artist"` 原文查全部店面；只有 round1 每个店面都没有可靠结果时，才用 `stripBracketedTitleSegments(title)`（通用去括号/方括号，不是关键词白名单——按项目铁律不做枚举式补丁）拼 round2 再查一遍全部店面。旧的"艺人+标题倒序"和"纯标题"两条策略删掉了——报告点名它们是"大量无效扇出、低命中"，且分数复用同一个 `scoreArtworkCandidate` 的 contains 部分匹配已经覆盖了大部分变体场景，真正需要换 query 词的只有"标题里带 (feat. ...) 导致搜索本身 0 条"这一类（Misty 案例），round2 精确针对这个。
- **请求数**（最坏情况，单次 `fetchArtworkViaITunesAPI` 调用）：
  - round1 命中：4 次搜索 + 1 次图片下载 = **5 次**。
  - round1 全灭、round2 命中：4 + 4 + 1 = **9 次**。
  - 两轮都灭（真内容缺口）：4 + 4 = **8 次**（不下载图片）。
  - `fetchArtwork` 本身在首次全灭后会走一次 `retryArtworkFetch`（也调用同一个函数），所以单次换歌最坏情况约 **2×8=16～2×9=18 次** iTunes 请求；正常命中路径只有 **5 次**。测试 `test_orchestration_*` 系列把这几个数字钉死成断言，不是口头估计。
- **超时**：单店面请求从 1.0s 提到 **1.6s**（`artworkITunesStorefrontTimeout`，理由：中国大陆到 itunes.apple.com 的往返经常超过 1s，店面是并行的，提高单店面超时不等于累加总时长）。`fetchArtworkResult` 里包住整个 iTunes 分支的外层超时从 1.4s 提到 **3.6s**（理由：两轮最坏情况顺序执行 ≈1.6+1.6=3.2s，外层要留出余量，否则会在内层还没来得及返回时被外层先切断，造成"明明要成功了却被判超时"的假阴性）。
- **日志**：`fetchArtworkViaITunesAPIRound` 给每个店面、每一轮都记一行（`empty` / `N result(s)` / `error (类型): 描述`），区分"真的没有"和"请求本身失败"（对应报告 Mode F 的"超时被吞"疑点，现在能在日常日志里直接看到错误类型）。`fetchArtwork` 里 SB 分支补了 `else` 分支日志（原来完全静默，对应报告 Mode A2）。

### 改动文件
- `Sources/MusicMiniPlayerCore/Services/MusicController+Artwork.swift`：新增 `ArtworkStorefront` / `artworkITunesStorefronts` / `artworkITunesStorefrontTimeout` / `orderedArtworkStorefronts` / `stripBracketedTitleSegments` / `selectBestITunesArtwork` / `ITunesArtworkTransport` / 新版 `fetchArtworkViaITunesAPI`（static，可注入 transport）+ `fetchArtworkViaITunesAPIRound`；删除旧的三策略单店面 `fetchArtworkViaITunesAPI`；`fetchArtworkResult` 调用点改用新函数并把外层超时 1.4s→3.6s；SB 分支补 `else` 日志。
- `Tests/MusicMiniPlayerTests/ArtworkStorefrontSelectionTests.swift`（新增）：17 个测试，覆盖复现 fixture、修复后选型、跨店面同分打平、可靠性门槛、店面排序、括号剥离、端到端编排（含请求数断言）。

### 测试结果
- `ArtworkStorefrontSelectionTests`：17/17 通过（含前述"改回旧行为跑一遍确认红→改回新实现确认绿"的往返）。
- `RowArtworkFetchPolicyTests`：12/12 通过（无回归）。
- `RowArtworkStoreTests`：7/7 通过（无回归）。
- `TrackIdentityDisciplineTests`：19/19 通过（无回归）。
- `swift build`：通过，无新增警告/错误。
- 测试全程零真网络（`ITunesArtworkTransport` 注入 fixture closure）。

### 后续项（本次不做，按 spec 要求写在这里）
- 电台换歌通知在十几秒内在两首歌间来回翻转 4–5 次，打断取封面（报告 Mode B，`MusicController.swift:1433`、`:2347`）——不在本次范围。
- Deezer 全程 0 命中且错误被吞、MusicKit 因 developer token 失败从不运行——不在本次范围，本次只加了 iTunes 侧的错误类型日志，没有动 Deezer/MusicKit。
- `Ripples`→`漣漪` 这类标题艺人都本地化（非拉丁转写关系）的情况——spec 明确排除，本次的 `scoreArtworkCandidate`/`stripBracketedTitleSegments` 都不处理跨文字系统的完全本地化标题。
- `fetchArtwork` 里 SB 分支新增的 `else` 日志是纯日志改动，未写对应单元测试——SB 路径依赖真实 `SBApplication`/Music.app，项目现有测试里也没有对 SB 分支做单元测试的先例（全部是纯函数级测试），这里保持一致，留给日常使用 + 下次真机验证自动积累证据。

---

## 结果补充（2026-09-22 二轮：code review 发现的限流回归 + 上线复核）

### 1. 限流回归——问题

Code review 指出：`fetchArtworkResult`（本次改动的多店面查询入口）不只服务正在播的歌，还同时服务播放列表**行封面**（`makeRowArtworkStore` 的 fetch 闭包、`PlaylistView.swift:973` 经 `fetchMusicKitArtwork` 调用）和 `preloadArtwork`（预取接下来 4 首）。改动前每行大约 1 次 iTunes 请求；改动后每行并行发 4 次店面请求。冷播放列表约 20 行同时挂载时可能瞬间打出 80+ 并发请求，而 iTunes Search 有限流（今天创始人主会话实测：约 25 次/分钟后开始返回非 JSON）——行级请求风暴可能连带饿死正在播歌曲的封面请求和 `MetadataResolver`（歌词元数据）自己的 iTunes 调用。

### 2. 修复设计

**(a) 显式优先级，按调用方意图区分，不猜调用栈**

新增 `MusicController.ArtworkFetchPriority`（`.nowPlaying` / `.background`），作为**必填参数**（无默认值）贯穿 `fetchArtworkResult` → `fetchArtworkViaITunesAPI` → `fetchArtworkViaITunesAPIRound`：
- `.nowPlaying`：`fetchArtwork`（Path 1）、`retryArtworkFetch` —— 保留原有并行店面扇出（一次只处理一首正在播的歌，值得多花请求）。
- `.background`：`preloadArtwork`、`makeRowArtworkStore` 的 fetch 闭包、`fetchMusicKitArtwork`（无 metadataKey 分支）—— 改为**顺序**逐店面查询，命中第一个可靠结果就停，不再等其余店面。冷播放列表下每行同一时刻只有 1 个 iTunes 请求在飞，而不是 4 个——`test_backgroundPriority_neverOverlapsRequests` 用一个记并发峰值的 harness 钉死这一点（maxConcurrentInFlight 必须 ==1）。

**(b) 主机级熔断器（circuit breaker）**

新增 `MusicController.ArtworkITunesCircuitBreaker`：纯 NSLock + 可注入 `now:` 时钟（照抄 `RowArtworkNegativeCache` 的写法，`RowArtworkFetchPolicyTests` 同款风格，测试里全程假时钟不真睡）。`isITunesRateLimitSignal(_:)` 识别 HTTP 403/429，以及"非 JSON 响应体"（`ITunesArtworkTransport.live` 在这种情况下唯一会产生的错误就是 `.decodingFailed`，这正是报告里"连续请求后 iTunes 返回非 JSON"的落地信号）。命中限流信号：
  - 顺序（background）搜索立即中止本次调用剩余店面，不再往一个已经在拒绝的主机上继续打。
  - 熔断器进入 open 状态 45 秒（`openDuration`），open 期间 **background 优先级直接跳过 iTunes**（0 次请求）；**nowPlaying 优先级仍尝试 1 个店面**（正在播的歌仍有机会拿到真封面），不做全店面扇出。
  - 熔断触发只在"关→开"这次跳变记一行日志（`trip(now:)` 返回值判断），不会每条被拒请求都刷一行。
  - 熔断器是进程级共享单例（`.shared`），任何调用方（nowPlaying 或 background）触发的熔断都保护其余共享同一实例的调用——测试 `test_breakerTrip_isSharedAcrossCalls_backgroundSeesEarlierNowPlayingTrip` 钉死这点。

**(c) 请求数**

| 场景 | 熔断关闭（正常） | 熔断打开（限流中） |
|---|---:|---:|
| 换歌（nowPlaying，单次 `fetchArtwork` 调用，含其自带一次 retry） | 命中 round1：5 次；两轮全灭：16 次；round2 命中：18 次（最坏） | 命中：2 次；全灭：2 次；round2 命中：3 次（每轮限 1 店面，×2 次尝试） |
| 冷 20 行播放列表（background，逐行顺序店面查询，`rowArtworkFetchGate` 限并发 3 行） | 每行最好 2 次（首店面命中）、最坏 8 次（两轮全灭）；20 行理论最坏 160 次，但并发峰值仍是 3（与修复前单店面时代同一并发量级） | 每行 0 次（直接跳过 iTunes），直到 45s 熔断窗口过期 |

现实意义：熔断器把"理论最坏 160 次"这类数字压到"第一次限流信号出现后立即清零"——一旦 iTunes 真的开始拒绝（今天观测约 25 次/分钟），后续 45 秒内所有 background 请求直接短路，不会继续拿一个已经在拒绝的主机练手。

### 3. 改动/新增文件（本轮）
- `Sources/MusicMiniPlayerCore/Services/MusicController+Artwork.swift`：新增 `ArtworkFetchPriority`、`ArtworkITunesCircuitBreaker`、`isITunesRateLimitSignal`、`searchStorefrontsInParallel`/`searchStorefrontsSequentially`、`ITunesArtworkMatch` + `fetchArtworkViaITunesAPIDetailed`（供上线复核读取命中店面/匹配字段）；`selectBestITunesArtwork` 返回值追加 `trackName`/`artistName`/`collectionName`；`fetchArtworkResult` 新增必填 `priority` 参数，5 个调用点（`preloadArtwork` / `fetchArtwork` Path1 / `fetchMusicKitArtwork` / `makeRowArtworkStore` / `retryArtworkFetch`）分别打上 `.background`/`.background`/`.background`/`.background`/`.nowPlaying` 标签。
- `Tests/MusicMiniPlayerTests/ArtworkStorefrontSelectionTests.swift`：既有 6 个 `fetchArtworkViaITunesAPI` 调用点补 `priority: .nowPlaying` + 独立 breaker 实例（避免共享单例污染其他测试）。
- `Tests/MusicMiniPlayerTests/ArtworkPriorityAndCircuitBreakerTests.swift`（新增，16 个测试）：熔断器纯逻辑（假时钟开/关/跳变/续期）、限流信号分类、background 顺序停在首个可靠命中 + 从不并发、nowPlaying 仍并行、限流触发熔断并中止当次剩余店面、熔断开启时 background 零请求/nowPlaying 限 1 店面、熔断跨调用共享。
- `Tests/MusicMiniPlayerTests/ArtworkLiveStorefrontEvalTests.swift`（新增，见下）。

### 4. 测试结果（本轮）
- `ArtworkPriorityAndCircuitBreakerTests`：16/16 通过。
- `ArtworkStorefrontSelectionTests`：17/17 通过（无回归，补了 priority 参数）。
- `RowArtworkFetchPolicyTests`：12/12 通过。
- `RowArtworkStoreTests`：7/7 通过。
- `TrackIdentityDisciplineTests`：19/19 通过。
- `swift build`：通过，无新增警告/错误。
- 除下面第 5 节说明的现场复核外，全程零真网络。

### 5. 上线复核（NANOPOD_LIVE_ARTWORK_EVAL=1）——**本环境无法给出真实数据，如实说明**

测试已按要求写好：`Tests/MusicMiniPlayerTests/ArtworkLiveStorefrontEvalTests.swift`，`NANOPOD_LIVE_ARTWORK_EVAL=1` 门控，调用真实 `fetchArtworkViaITunesAPIDetailed`（`.nowPlaying` 优先级、真实 `.live` transport、独立 breaker 实例），18 首今天失败曲目 + 8 首对照曲目，曲目间 sleep 4 秒，逐条记录命中/未命中、命中店面、匹配的 trackName/artistName/collectionName、耗时，并用 `scoreArtworkCandidate` 的 reliable 判定标出"匹配到的是不是同一首歌"。不设 `NANOPOD_LIVE_ARTWORK_EVAL=1` 时确认会 `XCTSkip`（已验证，不占用日常测试）。

**但本 worktree 所在的沙盒环境，出站访问 itunes.apple.com 被无条件拒绝**——直接 curl 验证（非本次改动引入，与限流无关）：
```
curl -m5 "https://itunes.apple.com/search?term=test&media=music&entity=song&limit=1"
→ HTTP/2 403，body 为空，来自 Apple 自己的 daiquiri/Akamai 边缘（apple-timing-app: 2ms，说明请求确实到达 Apple 服务端并被拒绝，不是本地网络故障）；example.com 同时返回 200，证明沙盒本身能上网，只是这一个 host 被挡。
```
按要求实际跑了一次（`NANOPOD_LIVE_ARTWORK_EVAL=1`，105.7 秒，26 首×4s 间隔）——结果是 **0/26 命中，包括 8 首"今天确认成功"的对照曲目**，证实这不是修复本身的效果，而是沙盒出口 IP 对 itunes.apple.com 的无差别拒绝（连对照组都全灭，若是真限流不会连一直成功的曲目也 100% 落空）。逐条延迟均在 47–412ms，与"连接建立即被拒"一致，不是超时。完整表格（诊断用，非真实验收数据）：

| Track (was failing?) | Artist | Result | Storefront | Matched | Latency (ms) |
|---|---|---|---|---|---:|
| Tell Me Oh Mama (failed) | Naoko Gushima | miss | — | — | 320 |
| some (feat. LiI Boi) (failed) | SoYou & Junggigo | miss | — | — | 405 |
| Let's Stay In Tonight (failed) | Brian Culbertson | miss | — | — | 60 |
| Jellyfish (feat. Michael Seyer) (failed) | Sunset Rollercoaster | miss | — | — | 303 |
| 春天 (failed) | Xun Zhou | miss | — | — | 148 |
| Time After Time (failed) | Sarah Menescal | miss | — | — | 56 |
| Roland Reve (From "Lola") (failed) | Jacqueline Danno | miss | — | — | 312 |
| SHYNESS BOY (failed) | Anri | miss | — | — | 110 |
| Starlight Ballet (failed) | Piper | miss | — | — | 56 |
| Gatsby Woman (2020 Remastered) (failed) | Kingo Hamada | miss | — | — | 358 |
| Who Are You? (DJ Version) [2022 Remaster] (failed) | Fujimaru Yoshino | miss | — | — | 243 |
| Gatsby Woman (failed) | Hamada Kingo | miss | — | — | 125 |
| 葉子 (電視劇《薔薇之戀》原聲帶版) (failed) | A-Sun | miss | — | — | 308 |
| Ripples (failed) | Danny Chan | miss | — | — | 124 |
| Misty (feat. Glenn Osser and His Orchestra) (failed) | Johnny Mathis | miss | — | — | 251 |
| Second Love (failed) | Akina Nakamori | miss | — | — | 118 |
| A House Is Not a Home (French & English) (failed) | Dionne Warwick | miss | — | — | 229 |
| Oceanside Café (failed) | CinCin Lee | miss | — | — | 66 |
| Supernatural (control) | NewJeans | miss | — | — | 412 |
| 啟程 (control) | Christine Fan | miss | — | — | 50 |
| Yume No Tsuzuki (2017 Remaster) (control) | Mariya Takeuchi | miss | — | — | 193 |
| Private Beach (control) | Meiko Nakahara | miss | — | — | 48 |
| If You Want It (control) | Niteflyte | miss | — | — | 50 |
| Mc's Road De Aimasho (control) | Kazuhito Murata | miss | — | — | 130 |
| Soiree (control) | Bill Evans | miss | — | — | 47 |
| Where Is My Mind (control) | Jacques Astor | miss | — | — | 97 |

**结论**：测试本身已实现且验证可用（skip 门禁、真实调用路径、breaker 隔离、表格产出均已跑通），但真实命中率/店面命中分布/错配核查需要在能访问 itunes.apple.com 的机器（例如创始人自己的 Mac）上跑：
```
NANOPOD_LIVE_ARTWORK_EVAL=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ArtworkLiveStorefrontEvalTests
```
跑完后终端会打印同样格式的 Markdown 表格（含命中率、店面、匹配到的 trackName/artistName/collectionName、错配标记），可直接贴回本节替换上面这张"诊断表"。本次未能提供真实命中率对比（之前 0/18、之后 ?/18），如实标注为待创始人本机复核项，不编造数字。
