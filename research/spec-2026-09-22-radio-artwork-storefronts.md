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
