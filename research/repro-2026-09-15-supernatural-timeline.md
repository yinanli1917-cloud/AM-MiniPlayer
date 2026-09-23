# 复现报告：阶段包 3 真机反馈复核——Supernatural（QQ 48L）时间轴/逐字缺口

工作 worktree：`worktree-agent-a51235b25ab8f2630`，起初停在 `277cd5b`（旧于 main），
fast-forward 到 main 当前 tip `493ab2c`（`git merge --ff-only`，worktree 分支无独有提
交，安全操作）。含 09-14 已落地的 df2a421（比例制覆盖率/空档惩罚）、e13d867（人工标
注源容忍带让位真实空档）、65b7210（AMLL 请求/命中日志）、e8058c4（QQ 48L 无缺陷判
定）。

## 背景：这次要判定什么

创始人真机反馈（阶段包 3，2026-09-14 22:xx 场次）：当前显示的 QQ 48 行版本 (1) 少开
头三句 hook，(2) 时间轴不太对得上，(3) 不是逐字歌词版本。前序复现报告
（`repro-2026-09-14-supernatural-qq-verdict.md`）已判定 QQ 候选本身评分/选择逻辑无
缺陷；本报告在此基础上做两件新事：A. 把"时间轴不太对得上"从感受量化成逐行数字；
B. 核实"是否真的没有可用的逐字版本"，包括之前报告里"NetEase YRC 是候选池里唯一逐字
版本"这个前提本身是否站得住。

## 复现方法

```bash
export DEVELOPER_DIR=/Applications/Xcode.app
export NANOPOD_DEBUG_LOG=1
swift run LyricsVerifier check "Supernatural" "NewJeans" 191 --dump
```

连续跑 14 次：QQ `found:true` 4 次（run 8/9/10/11），`found:false` 10 次——命中率
4/14 (29%)，比前序报告记录的 3/8 (38%) 更差，同一现象（QQ 搜索接口间歇性空结果），
不是本次新缺陷,是已知上游可用性波动的再次观测。4 次命中的 QQ 结果（分数/行数/文本/
时间戳）逐字段一致，确认是同一次真实决策路径。

为拿到 NetEase 完整时间轴（NetEase 分数 58.1 从未赢过，`--dump` 只打印胜出源，拿不
到它的逐行内容），另写了一个临时诊断测试直接调用 `LyricsFetcher.shared
.fetchFromNetEase(...)`，跑完后已删除（未提交，`git status` 确认工作区干净）：

```swift
// 已删除，验证后不保留
let result = await LyricsFetcher.shared.fetchFromNetEase(
    title: "Supernatural", artist: "NewJeans",
    originalTitle: "Supernatural", originalArtist: "NewJeans",
    duration: 191, translationEnabled: false)
```

`swift test --filter ZZDiagNetEaseDumpTests`（1.29s，通过）打印出 NetEase 候选的真
实 29 行时间戳与 `hasSyllableSync` 逐行标记。

## A. 时间轴偏差量化

### 三份候选的真实结构（`--dump` 原样输出，未编辑）

| 候选 | 行数 | 首句时间 | 内部最大空档 | hasSyllableSync |
|---|---|---|---|---|
| QQ | 47 真实行 | 26.3s "Stormy night" | 8.6s（136.9→145.5，"It's supernatural"间奏，正常乐句停顿） | 全 0（行级） |
| LRCLIB | 36 真实行 | 8.7s "Come on" | 11.4s（同一处间奏） | 全 0（行级） |
| NetEase | 29 真实行 | 26.9s "Stormy night" | **63.2s（77.4→140.6s）** | **全 0（行级，见下方 B 节更正）** |

### 逐句对照（QQ 切分粒度为准，前 16 行；数字均为真实 `--dump`/诊断测试输出）

QQ 与 NetEase 用的是同一种断句粒度（"Stormy night"/"Cloudy sky"分开成两行）；LRCLIB
把双语对句合并成一行，因此下表 LRCLIB 一列标注的是"该句所在合并行"的时间戳。

| # | 歌词（QQ 切分） | QQ | LRCLIB（对应合并行） | NetEase | QQ−NetEase |
|---|---|---|---|---|---|
| 1 | Stormy night | 26.3 | 26.2（"Stormy night, cloudy sky"） | 26.9 | −0.6 |
| 2 | Cloudy sky | 28.5 | 同上合并行 | 29.6 | −1.1 |
| 3 | In a moment you and I | 30.0 | 29.9（"In the moment, you and I"） | 31.7 | −1.7 |
| 4 | One more chance | 35.1 | 35.1（"One more chance, 너와 나"） | 35.8 | −0.7 |
| 5 | 너와 나 다시 한번 만나게 | 37.3 | 38.6（"다시 한번 만나게 서로에게 향하게"，文本切法不同） | 38.0（文本与 QQ 完全一致） | −0.7 |
| 6 | 서로에게 향하게 | 40.8 | 并入上一合并行 | （NetEase 未单独成行，见下方说明） | — |
| 7 | My feeling's getting deeper | 43.7 | 43.7 | 44.2 | −0.5 |
| 8 | 내 심박수를 믿어 | 48.1 | 48.1 | 51.0 | **−2.9** |
| 9 | 우리 인연은 깊어 | 52.5 | 52.6 | 55.2 | **−2.7** |
| 10 | I gotta see the meaning of it | 56.6 | 56.9（"...(come on)"） | 58.1 | −1.5 |
| 11 | I don't know what we've done | 61.6 | 61.9 | 60.2 | **+1.4** |
| 12 | 되돌아가긴 싫어 | 63.8 | 63.8（合并"もう知っている"） | 63.8 | **0.0** |
| 13 | もう知っている | 66.4 | 同上合并行 | 66.2 | +0.2 |
| 14 | Don't know what we've been sold | 70.5 | 70.5 | 70.5 | **0.0** |
| 15 | 見つけられるよ | 72.7 | 72.8（"...so it's sure (come on)"） | 74.2 | −1.5 |
| 16 | So it's sure | 76.6 | 同上合并行 | 77.4（NetEase 内部空档从这里开始） | −0.8 |

### 判定：不是整体提前/滞后，也不是从某点开始单向漂移

- QQ 相对 NetEase 的逐句差值在 −2.9s 到 +1.4s 之间来回摆动，且在 63.8s / 70.5s 两处
  精确归零（Δ=0.0）——如果是恒定偏移（比如 qqTimeOffset 校准不准），差值应该保持同
  一符号、大致同一量级；如果是"从某处开始漂移"，差值应该单调增长。两种模式都不成
  立，实测形状是**双向震荡后又对齐**，是两份独立转写各自的断句/取整误差叠加，不是
  单一时钟偏移或累积漂移。
- QQ 与 LRCLIB 对齐得更紧（大多数句子 Δ≤0.3s），因为二者的原始转写更可能出自同一
  条社区 LRC 谱系；NetEase 独立转写，偏差幅度更大属正常范围。
- `qqTimeOffset=0.4`（CLAUDE.md 记录的既有 QQ 全局校正）已经应用在上表的 QQ 时间戳
  里（`--dump` 输出的是 `applyTimeOffset` 之后的最终值），上述震荡是校正后的残余误
  差，量级（±1-3s）不足以在 191 秒的歌里造成"跟不上"的观感——真正会让人觉得"跟不
  上"的是下一条。
- **头部缺口才是真问题，但它不是 QQ 独有**：QQ 从 26.3s 才开始出词，NetEase 从
  26.9s 才开始——两者几乎一样晚。只有 LRCLIB 收录了 8.7–25.8s 的三句前奏 hook
  （"Come on"/"(Ah-ah)"/"Come on (let's go)"）。创始人反馈里"确实少开头三句
  hook"这个观察是对的，但归因需要更正：**这不是"QQ 转写比 NetEase 差"，而是"这三
  句前奏 hook 本身只有 LRCLIB 一家转写收录了"**——QQ 和 NetEase 两条独立来源都同样
  从 26.3/26.9s 才开始，说明这三句 ad-lib 在多数转写习惯里就不被当作正文收录（可能
  被当成纯人声点缀/和声，不是所有转写者都会录入）。26.3s 的头部偏移远低于
  `LyricsResultSelection` 的 90s 硬门槛，也低于 `LyricsScorer` 5c 头部空档惩罚的
  `max(90, 191*0.30)=90s` 门槛——两层规则都判定这是正常范围，不是"从中段起录"。

## B. 逐字版本可得性核查

### 关键更正：候选池里没有真正的逐字（syllable-level）候选——包括 NetEase

前序报告（`repro-2026-09-14-lyrics-pipeline.md`）称"候选池里唯一逐字的是 NetEase
YRC（29 行）"。这次用诊断测试直接读取 NetEase 候选的 `hasSyllableSync` 标记，结果是
**29 行全部 `hasSyllableSync=false`**——这个 NetEase 候选本身就是行级（逐句 LRC 落
地），不是逐字 YRC。前序报告的"YRC"措辞不准确，这次予以更正。也就是说：**当前 8
个源里，对这首歌没有任何一个真正返回了逐字同步内容**——"逐字优先"规则不是在"两个
逐字候选里选错了行级"，而是"候选池里本来就没有逐字候选可选"。

真实调试日志证据（本次 + 前序报告合并）：

| 源 | 状态 | 证据 |
|---|---|---|
| AppleMusic | 开发者令牌不可用，进程内整体禁用 | 本次复现：14 次全部 `[AppleMusic] ❌ developer token unavailable — source disabled for this process`；前序报告：创始人真机会话（非 verifier）同样 64 次失败——**不是 verifier CLI 未签名的环境限定问题，真机签名版 app 同样拿不到令牌**。`Sources/MusicMiniPlayerApp/MusicMiniPlayer.entitlements` 里没有显式 MusicKit 相关 entitlement（只有 network.client + automation.apple-events），`MusicDataRequest` 走的是系统自动令牌签发，失败原因大概率是 Apple Developer 账号的 App ID 未在开发者后台开启 MusicKit 能力——这是账号配置问题，不在本仓库代码可查范围内，需要创始人在 Apple Developer 后台确认。 |
| AMLL | 索引常未就绪；两次索引就绪时均无匹配候选 | 65b7210 已加日志。本次 9 次请求里 7 次是"索引未就绪，后台加载中"（verifier 每次跑都是新进程，索引缓存不会跨进程持久化，这是 verifier 工具本身的局限，不代表真实长驻 app 的命中率）；2 次索引就绪后是"索引无匹配候选"——即使排除 verifier 的冷启动劣势，AMLL 社区库现阶段确实没有这首歌的 TTML 条目。 |
| NetEase | 有候选，但是行级，且 77.4–140.6s 有 63.2 秒空档 | 见上节；`songId=3314634768`，与"NewJeans"精确同名匹配（Δ0.0s），是搜索结果里唯一的官方版本候选（其余候选是翻唱/AI 翻唱/不同艺人）。 |
| QQ | 有候选，行级，无空档，但缺 3 句前奏 hook | 见 A 节。 |
| LRCLIB | 有候选，行级，无空档，含前奏 hook | 见 A 节。 |

### QQ 是否有逐字（QRC）接口而我们没用——核实：有，我们确实没用

直接用真实 QQ 公开接口验证（curl，非模拟，songmid=`003kva882toU7E`，songID=
`496097783`，均来自真实搜索响应）：

```
POST https://u.y.qq.com/cgi-bin/musicu.fcg
{"lyric":{"method":"GetPlayLyricInfo","module":"music.musichallSong.PlayLyricInfo",
  "param":{"songMID":"003kva882toU7E","songID":496097783,"qrc":1,"trans":1,"roma":1}}}
```

返回（真实响应，已截断）：

```json
{"lyric":{"data":{"qrc":1,"crypt":0,
  "lyric":"162F6DC3F67305C74C633217EBFD02FEC61BC72C94FB6F524A1D244BA1E50F5..."}}}
```

`"qrc":1` 确认服务端识别到这首歌有逐字版本，`lyric` 字段是一串十六进制加密数据
（QQ 音乐私有的逐字/卡拉OK 格式，社区惯称 QRC，需要 DES 解密+zlib 解压才能还原成明
文，算法是被逆向工程公开过的固定密钥流程，但仍是未公开的私有格式）。

**我们当前代码只调用了 `fcg_query_lyric_new.fcg`（`fetchQQMusicLyrics`，第 2612 行）
和不带 `qrc` 参数的 `GetPlayLyricInfo`（`fetchQQMusicLyricsViaMusicu`，第 3051 行）
——两处都只取 `lyric`/`trans` 明文字段，都没有传 `qrc=1`，也没有实现对应的解密逻
辑。** 这确认了创始人的猜测：QQ 有逐字数据，我们没接。

### NetEase 是否有别的候选 ID 不带空洞——核实：搜索池里没有看到别的官方版本

`selectBestCandidate` 的调试日志只打印按时长差排序的前 5 条（`desc.prefix(5)`），本
次真实请求返回：

```
1. 'SuperNatural' by 'NewJeans / DanielleMarsh' alb='Super Natural' Δ0.0s  ← 命中，唯一精确时长匹配
2. 'Supernatural' by 'ioi'                                          Δ0.3s  （不同艺人，A=false）
3. 'Supernatural' by 'noli'                                          Δ1.8s  （翻唱，A=false）
4. '【AI aespa】Supernatural' by '俄罗斯就好小号'                      Δ2.0s  （AI 翻唱，A=false）
5. 'Supernatural' by '全网找歌君'                                     Δ3.8s  （疑似搬运/合集账号）
```

总候选 20 条，日志只截断显示前 5——不能排除第 6-20 条里存在另一个艺人字段写法不同
但同样是 NewJeans 官方版本、且转写更完整的候选，但从已暴露的证据看：**在 duration
误差最小的前 5 条里，唯一符合"官方艺人+精确时长"的只有这一条**（其余要么艺人不
符，要么时长差距明显更大，明显是翻唱/AI 二创/合辑搬运）。selectBestCandidate 本身
不做"抓来比一比找不带空洞的"，它只按元数据（时长/标题/艺人/专辑）选一条最像的候
选，内容层面的空档是拿到歌词内容之后才能发现的——这是架构性的：**候选选择发生在
"看到歌词内容"之前**，selectBestCandidate 无法把"是否有内部空档"当作选择依据。

值得注意：`LyricsSourceFetchers.swift` 里已经有一套专门处理"选中的 NetEase 候选
质量可疑，回头找同曲目其他 songId 兜底"的机制（`shouldProbeNetEaseAuthoritativeSibling`
/ `shouldProbeNetEaseCanonicalWordLevelSibling` / `fetchNetEaseSiblingQualityFallback`，
第 497-760 行），但触发条件都没有覆盖"主候选已经是 synced 且没有逐字同步、但存在
大段内部空档"这一种情况：

- `shouldProbeNetEaseAuthoritativeSibling` 要求 `!hasSyllableSync(primary)` 触发升
  级找逐字兜底——但它还要求 `match.albumMatched && !params.normalizedAlbum.isEmpty`
  或 `looksLikeOpeningCatalogCreditLine`，Supernatural 这次调用没传专辑名（album=
  ""），首句也不是版权信息行，两个条件都不满足，**从未进入这条探测路径**。
- `shouldProbeNetEaseCanonicalWordLevelSibling` 要求 `hasSyllableSync(primary) ==
  true`——但本候选恰恰是 false，**这条路径的前置条件本身就与本候选矛盾，永远不会
  触发**。
- `isSuspiciousCompressedLineTiming` 只检查**尾部**空档（`leavesLargeTail`），不检
  查内部空档，63.2 秒的洞在歌曲中段，不影响 `tailGap`（本候选 tailGap 仅 9.4s），
  **这条探测同样不会触发**。

也就是说：**现有三套兜底探测逻辑加起来，没有一条会对"行级 + 中段大空洞"这种组合
生效**——不是探测逻辑判断错了，是这类组合从来没有被设计进任何一条触发条件里。

## C. 修法方案（分析，不实现）

结论先行：这首歌当前没有真正的逐字候选可选，"逐字优先"规则在这次没有失效——它没
有可选的逐字候选去优先。三个方向里，方案 1（QQ QRC 解密）是唯一能让"逐字优先"真正
生效的路径；方案 2（换 NetEase 候选）和方案 3（放宽内部空档门槛）都只能把当前的行
级候选换成另一个行级候选，治标不治本，但成本更低、可以先做。

### 方案 1：实现 QQ QRC 解密，把 QQ 从行级升级为真逐字源

- **可行性**：中等。接口已验证可用（本报告已拿到真实加密 payload），解密算法（DES
  ECB + 固定密钥 + zlib inflate）是社区公开逆向的成熟流程，多个开源项目（如
  `lyric-api`、`qq-music-api` 系列）有可参照实现；Swift 侧需要引入 DES 解密（
  `CommonCrypto` 原生支持 DES，不需要第三方依赖）+ zlib（`Compression` 框架原生支
  持），技术上不需要新依赖。QRC 本身是逐字时间戳 XML 相似结构，需要新写一个
  `parseQRC` 解析器（类似现有 `parseYRC`/`parseTTML`）。
- **风险**：(1) 私有格式解密协议属于"服务条款灰色地带"——lyrics.ovh/Genius 已经是
  单方面爬取，QQ 音乐的官方 API 本身也未公开许可第三方调用，这条风险在现有 8 个源
  里已经存在，QRC 解密不新增性质上的风险，只是把同一个源的"读到什么字段"从明文
  换成需要解密的字段，风险量级相近，不是质变。(2) 解密密钥/算法如果上游更换会静默
  失效，需要和其它 HTTP 源一样做好优雅降级（拿不到就退回明文 lyric 字段，不是新概
  念，现有 `fetchQQMusicLyrics` 已经这么做）。(3) 需要新的 QRC→LyricLine 解析器，
  按现有 parser 测试覆盖惯例（`LyricsParserTests.swift`）补测试，工作量不小。
- **对 82/100 基准的预期影响**：只影响 QQ 候选是否能拿到逐字分数加成（`hasSyllableSync`
  相关评分项），不改变匹配/选择逻辑本身；预期让更多中文流行曲从"行级 QQ 获胜"变
  成"逐字 QQ 获胜"（分数会更高），风险方向主要是新解析器本身的正确性（时间戳换算/
  分词边界），需要先在几十首已知 QQ 命中的曲目上人工核对文本与实际发音是否对齐，
  再跑两套回归确认无退化。

### 方案 2：NetEase 换一个不带空洞的候选 ID

- **可行性**：低到中等。本报告已确认搜索结果前 5 条里没有第二个"官方 NewJeans+精确
  时长"候选——这首歌大概率在 NetEase 上就只有这一个转写版本，"换一个"这个前提本身
  可能不成立。可以做的是把 `selectBestCandidate` 打印的候选数从 `prefix(5)` 放宽到
  全部 20 条核实一遍（本报告受限于日志截断，没有拿到完整 20 条列表），但基于已看
  到的证据（其余候选要么是不同艺人的翻唱/AI 二创，艺人验证会直接拒绝），**换候选
  能解决这首歌问题的概率不高**。
- **风险**：即使找到，仍然是行级（换候选不解决"没有逐字数据"的根本问题，最多解决
  "有没有 63 秒的洞"），价值有限。
- **对 82/100 基准的预期影响**：如果要做，应该是给 `shouldProbeNetEaseAuthoritativeSibling`
  补一条"主候选 synced 且无逐字同步、且存在超阈值内部空档"的触发条件（目前这个组合
  确实没被覆盖，见 B 节），而不是针对这首歌本身；影响面是所有"NetEase 唯一候选、
  行级、中段空洞超过 `LyricsScorer` 内部空档阈值"的歌——需要先摸清这类歌在 82/100
  两套里的覆盖数（目前未知，没有现成清单），再评估兜底探测的额外网络请求是否会拖
  慢这批歌的取词耗时（≤3s SLA 是硬约束，加一次探测请求需要预算内完成）。

### 方案 3：空洞惩罚只在覆盖比例超阈值时才让行级候选获胜，不是一律

- **可行性**：高，改动量最小——本质是给现有 df2a421 比例惩罚再加一层"如果这是候选
  池里唯一的逐字/近逐字候选，适度放宽内部空档门槛"的例外条件。但**这次复现直接证
  伪了这个方案对本曲的适用性**：NetEase 候选根本不是逐字（`hasSyllableSync` 全
  false），"放宽门槛保护逐字候选"这个理由在 Supernatural 身上不成立——放宽了也只
  是让一个带 63 秒洞的行级候选去赢另外两个没洞的行级候选，用户观感只会更差（同样
  是行级，还多个大洞），不建议做。
- 如果未来遇到"真逐字候选因内部空档惩罚输给行级候选"的真实案例（需要先找到一首真
  实存在两种候选、其中一个真的 `hasSyllableSync=true` 的歌来复现），再考虑类似
  `isExactLongIntro` 那样的例外豁免——但那需要专门的复现证据，本次没有找到，不建
  议现在凭空加。

## 未做项

1. **QQ 搜索接口间歇性空结果的根因**：本次 14 次里 4 次命中（29%），比前序报告的
   38% 更低，仍判定为上游可用性波动，不在本仓库代码范围内；未做长时间段（比如逐小
   时）统计来判断是否有时段规律。
2. **NetEase 完整 20 条候选列表未逐条核实**：`selectBestCandidate` 调试日志只打印
   `prefix(5)`，方案 2 的可行性判断基于这 5 条的证据外推，没有拿到完整候选列表逐条
   核对艺人/时长/是否带专辑标注。如果要认真评估方案 2，需要临时给调试日志改
   `prefix(20)`（未做，属于会改动生产日志输出的改动，按"先报后动手"原则留到创始人
   确认方向之后）。
3. **QQ QRC 解密未实现，只验证了接口可达性**：本报告只确认了 `qrc=1` 参数能拿到非
   空加密 payload，没有实现解密、没有验证解密后的内容是否真的是这首歌的逐字歌词
   （不排除返回的是占位符或需要额外鉴权字段）——方案 1 如果要做，第一步应该是先把
   这段十六进制数据解密出来人工核对文本，再决定是否值得投入写完整解析器。
4. **前序报告"NetEase YRC"措辞的更正**：本报告发现的"候选池里没有一个源提供逐字
   同步"这个事实，只覆盖了 Supernatural 这一首歌；没有去检查其他"行级 vs 逐字"讨
   论过的歌曲（How Sweet 等）是否也有同样被误记为"逐字候选"实际是行级的情况——如
   果创始人认为这值得系统性核查，需要另开一轮复现。

## 复现用命令记录

```bash
export DEVELOPER_DIR=/Applications/Xcode.app
export NANOPOD_DEBUG_LOG=1
swift run LyricsVerifier check "Supernatural" "NewJeans" 191 --dump   # 跑 14 次，QQ 4/14 命中
swift test --filter ZZDiagNetEaseDumpTests   # 临时诊断，已删除，验证 NetEase 候选逐行 hasSyllableSync
```

真实上游探针（curl，只读，未修改本仓库任何生产代码）：

```bash
curl -X POST https://u.y.qq.com/cgi-bin/musicu.fcg \
  -d '{"comm":{"ct":19,"cv":1845},"req":{"method":"DoSearchForQQMusicDesktop",...}}'
curl -X POST https://u.y.qq.com/cgi-bin/musicu.fcg \
  -d '{"lyric":{"method":"GetPlayLyricInfo","module":"music.musichallSong.PlayLyricInfo",
       "param":{"songMID":"003kva882toU7E","songID":496097783,"qrc":1,"trans":1,"roma":1}}}'
```
