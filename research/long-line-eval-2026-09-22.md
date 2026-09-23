# 超长歌词行 Eval 数据集与基线测量（2026-09-22）

## 背景

创始人 2026-09-22 反馈：单行歌词能折成 4 视觉行，占满整个播放器窗口。现有缓解手段（`LyricDisplaySegmenter` 拆行，接在 `LyricsView.makeDisplayLyricLines` 里）拆得很硬——断点砍在短语中间、翻译跟着被硬切、拆出来的片段时间轴和真实演唱进度对不上。创始人要求做一套自己的 brute-force 边界情况数据集/eval set 来验收后续方案。

本任务只做数据集与测量，不改生产行为。`git status` 确认：改动只有两个新文件，`Sources/` 零改动。

- `Tests/MusicMiniPlayerTests/Fixtures/long_line_eval.json` — 54 行 eval 数据集
- `Tests/MusicMiniPlayerTests/LongLineEvalTests.swift` — 5 个 XCTest，跑当前行为基线 + 3 个候选方案的量化对比

## 现有实现回顾

`LyricsView.makeDisplayLyricLines`（LyricsView.swift ~2014 行）：
- 逐字歌词行（`line.hasSyllableSync == true`，即 word-level）**永远不拆**，不管折几行。
- 行级（line-level）歌词先跑 `LyricDisplaySegmenter.segments(text, options: .mainLyric)`：`maxVisualLines=3, maxLineUnits=7.0` → 单位预算上限 21（一个中文字/假名/谚文/泰文算 1.0 单位，ASCII 算 0.55，其它非 ASCII 算 0.85，空白 0.28，标点 0.35）。断点优先落在强/弱标点（`.!?。！？…` / `,;:，、；：` 等）后面；找不到标点就按空格分词平衡拆；再找不到（没有空格也没有标点，比如一长串没分隔符的汉字）就走 `hardWrap` 逐字硬切，不管切在哪。
- 超过预算的行按整数个片段（`textSegments.count`）**平均分配时长**（`displayTiming`：`line 总时长 / 片段数`），不看真实演唱节奏。
- 翻译走 `LyricDisplaySegmenter.balancedSegments(translation, count: 原文片段数, options: .translation)`——**按原文的片段数**去切翻译，不管翻译自己的标点在哪。
- 有一道兜底：`shouldKeepDisplayLineUnsplit`——如果拆出来单片段时长 `< 1.65s`（`lyricMinimumGeneratedSegmentDuration`），干脆不拆，宁可整行超长。

## 业界调研

### Apple Music / AMLL（Apple Music-like Lyrics 开源复刻）

查了 AMLL TTML 规范文档（`amll-dev/amll-ttml-db` 仓库 `instructions/ttml-specification-en.md`）：**规范里没有"单行太长要不要拆"的规则**。逐字歌词的时间信息是挂在 `<p>`（一整行）内部的多个 `<span>`（每个音节/字一个）上；`<p>` 到 `<p>` 的切分——也就是"这句该在哪儿断成下一行"——是制作 TTML 文件的人（或 Apple 官方的字幕团队）在**制作时手工决定**的，不是播放端在渲染时按屏幕宽度现算的。规范里唯一提到的自动化是"把一个多字符音节按字符数比例分配时间"（auto-segmentation，用于处理源数据没给到逐字级别但给了逐音节级别的情况）——这正好是本次候选方案 C（按字符数比例分配时长）在业界的先例，但它解决的是"一个音节内部怎么分时间"，不是"一整句话该不该断行"。

换句话说：Apple 的路径是**把断行留给内容作者**，播放器本身不需要在运行时对着一句过长的话做自动折行决策。nanoPod 的处境不同——歌词源（NetEase/QQ/LRCLIB/Genius/lyrics.ovh）给的是别人做好的行切分，好坏不一，nanoPod 只能在运行时二次加工。

### 社区工具 lyric-align（`ijuinryukichi/lyric-align`）

这是一个把已知歌词贴到音频时间轴上的工具（面向没有官方逐字 TTML、要自己对时间的场景）。它的 "breath split" 功能正是"一段 ASR 识别结果覆盖了好几行歌词"时的拆分算法：**在按字符数估算出的切分点附近，找最大的一处词间静默（呼吸）来下刀**——是"按字符数比例"和"按停顿位置"两个信号的结合，不是二选一。CJK 按字符切、拉丁文按空格分词，各自的分隔符照抄源文本，不臆造。这个"字符数定位 + 就近找停顿精修"的思路,是本报告候选方案 A（按真实词间隔）与方案 C（按字符比例）的一个更成熟的合并版本，值得作为方案参考。

### Spotify（Musixmatch 供词）

Spotify 的歌词是 Musixmatch 按**整行**同步的（不是逐字/逐音节高亮，一整行一起亮）。即便只是整行同步这么简单的模型，Spotify 社区论坛上仍有真实的用户报告：**歌词自动滚动会在一行需要折成两行屏幕行时卡住**（点一下"Sync"才恢复，直到下一次遇到需要折行的句子又卡住），跨语言、跨歌曲都复现过。这说明"一行歌词折成多屏幕行"这个边界本身就是行业级的难题，不是 nanoPod 独有的实现疏漏——即使不做逐字高亮、只做整行显示，折行时机和滚动/同步逻辑对不齐依然会翻车。

**结论**：三家都没有"运行时把一句过长的话智能拆成语义完整的几段、还给每段配准时间轴"这个功能的公开先例——Apple/AMLL 把断行完全前置到制作阶段回避了这个问题；Spotify 干脆不逐字高亮但仍被折行边界坑过。nanoPod 面对的是外部歌词源）+ 运行时窄窗口，没有"制作阶段"可以回避，所以这确实需要自己设计一个通用方案，而不是抄一个现成答案。

Sources:
- [amll-ttml-db/instructions/ttml-specification-en.md](https://github.com/amll-dev/amll-ttml-db/blob/main/instructions/ttml-specification-en.md)
- [Steve-xmh/applemusic-like-lyrics](https://github.com/Steve-xmh/applemusic-like-lyrics)
- [ijuinryukichi/lyric-align](https://github.com/ijuinryukichi/lyric-align)
- [Spotify Community: Lyrics stop scrolling when a line wraps](https://community.spotify.com/t5/Desktop-Windows/Lyrics-stop-scrolling-when-Your-Library-is-collapsed-hidden/td-p/7001310)
- [Managing your lyrics on Spotify (Musixmatch, line-by-line sync)](https://support.spotify.com/us/artists/article/managing-your-lyrics-on-spotify/)

## Eval 数据集设计

文件：`Tests/MusicMiniPlayerTests/Fixtures/long_line_eval.json`，54 行，分三类：

| category | 数量 | 说明 |
|---|---:|---|
| real | 31 | 真实歌词行（26 条来自本机磁盘缓存，5 条来自仓库内已有的真实歌词 fixture） |
| groundTruthTiming | 11 | 真实逐字歌词，剥掉逐字时间轴模拟"只有行级时间轴"，`trueWords` 字段保留原始逐字时间戳供打分 |
| synthetic | 12 | 人工构造的边界情况 |

### 真实数据来源与两个重要限制（如实记录）

1. **标题/艺人不可逆**：`LyricsDiskCache.cacheKeys()`（`Sources/MusicMiniPlayerCore/Utils/LyricsDiskCache.swift:445`）把 title/artist 过 SHA256 哈希之后才落盘当 key，缓存条目本身根本不存 title/artist 字段——这是有意的隐私设计，不是本次任务的疏漏。数据集里的 `song.key` 是本次抓取时生成的编号，`song.album`/`song.source`/`song.durationSec` 是唯一能拿到的身份线索。
2. **磁盘缓存是活文件，不是快照**：抓取过程中，`~/Library/Application Support/nanoPod/lyrics_cache.json` 在本会话期间从 149 首歌缩到了 9 首（后台 TTL/条目数上限清理，八成是 app 当时在跑）。第一次读到的 149 首没来得及落盘就没了，最终数据集基于缩水后的 9 首歌 / 288 行歌词。这导致：
   - 这台机器当前缓存里**零**韩语（hangul）内容、**零**逐字（word-level）歌词——两个真实 stratum 因此是空的。
   - 韩语 stratum 用仓库里已有的真实 fixture（`Tests/Fixtures/netease_newjeans_howsweet_3328905844.json` 的原始 NetEase LRC）补了 5 行真实韩语歌词，但这几行短，够不到"≥3 视觉行"的门槛（数据集里标了 `note` 说明,不冒充符合症状的样本)。
   - 逐字歌词 stratum 用仓库里已有的真实 fixture（`Tests/Fixtures/netease_qicheng_wordlevel.json`，真实 NetEase 逐字歌词《启程》）补了 11 条去重后的独立行——这 11 条**全部**在窄宽度下真实折到 3 视觉行，是最贴近创始人原始症状的真实样本。
   - 纯假名（无汉字）日语、纯韩语的"≥3 视觉行"真实样本仍然缺失，用 2 条明确标注 `synthetic` 的行补齐 stratum（不冒充真实数据）。

### 度量宽度：为什么用 180pt 而不是 250pt

`MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift`：`windowSize = NSSize(250, 316)` 只是**首次启动**的默认尺寸；`snappableWindow.minSize = NSSize(180, 228)` 才是这个锁定宽高比的窗口能拖到的**实际下限**。用同一份磁盘缓存做直方图探测（真实 `NSLayoutManager` 折行，24pt 半粗体字体，32/32 边距）：

| 窗口宽度 | 内容宽度 | 折到 ≥3 视觉行的真实歌词行数（288 行里） |
|---|---:|---:|
| 250pt（首次启动默认值） | 186pt | 21（全部是英文/Latin，无翻译不参与） |
| 180pt（真实可拖到的下限） | 116pt | 135 |

窄宽度下候选行数是默认宽度的 6 倍还多——创始人报的"占满整个窗口"，大概率是窗口被拖到接近下限时更容易复现，而不是默认尺寸下的偶发。数据集的"real"行按 180pt 门槛抓取；eval harness 对每一行**两个宽度都测**，方便对照。

### Synthetic 12 条清单

| id | subtype | 覆盖点 |
|---|---|---|
| syn-001 | no_space_no_punct_cjk_60 | 60 个中文字无空格无标点，且是**逐字歌词**（word-level）——最贴近创始人症状的极端形状 |
| syn-002 | huge_single_latin_word | 一个 80 字符的英文长单词（没有内部空白/标点可切） |
| syn-003 | long_parenthetical_backing_vocal | 括号包裹的长和声/backing vocal 行 |
| syn-004 | many_short_words | 很多短单词重复，无标点 |
| syn-005 | punctuation_dense | 几乎每个词后面都有标点 |
| syn-006 | very_short_duration_long_text | 38 个汉字压在 0.3 秒的时间窗里 |
| syn-007 | long_translation_short_original | 原文 4 个字符，翻译约 45 个汉字 |
| syn-008 | short_translation_long_original | 原文一整句英文，翻译只有 2 个汉字 |
| syn-009 | emoji_numbers | 表情符号 + 数字 + 中英混排 |
| syn-010 | rtl_arabic | 阿拉伯语（RTL，从右到左书写） |
| syn-011 | hangul_long_line_stratification_fill | 补齐真实韩语样本不够长的缺口（明确标注 synthetic） |
| syn-012 | kana_long_line_stratification_fill | 补齐纯假名（无汉字）真实样本缺失的缺口（明确标注 synthetic） |

## 测量方法论

`LongLineEvalTests.swift` 直接调用生产代码里**本来就是 `internal`（非 `private`）**的度量入口，不需要开任何新口子：

- `NativeLyricsTextMeasurement.metrics(text, width:, font:, lineSpacing:)`——渲染器自己用的那套 `NSLayoutManager` 折行逻辑，逐字对照 `NativeLyricsRowMeasurement.swift` 里的孤字避让宽度 `textWidth(for:font:rowWidth:lineSpacing:)`。
- `NativeLyricsTextConstants`——24pt 半粗体主字号、4pt 行距、32/32 边距，跟渲染器读的是同一份常量。

`LyricsView.makeDisplayLyricLines` / `shouldKeepDisplayLineUnsplit` / `displayTiming` 三个是 `LyricsView`（SwiftUI View）上的 `private` 方法。项目里测这类私有 View 逻辑的既有约定（见 `NativeLyricsSurfaceSourceTests.swift`、`RapidSwitchTests.swift`）是**把源文件当文本读、断言字符串**，而不是放开访问权限。本次沿用这个约定：`EvalDisplaySegmentation` 在测试文件里逐行镜像这三个方法（同样的三处调用点、同样的 1.65s 阈值、同样的均分公式），`test_mirrorMatchesProductionSource_contractCheck` 用字符串匹配钉死镜像和生产代码不会悄悄分叉。**因此本次任务对 `Sources/` 零改动**，没有加"seam"。

### 一个意外发现：单位预算和真实折行对不上

`LyricDisplaySegmenter.estimatedVisualLineCount`（决定"这行要不要拆"的信号）用的是单位预算（`maxLineUnits=7.0`），跟真实渲染器在窄宽度下实际能塞进一行的字数不是一回事。用同一批 54 行数据对比：

- 单位预算估计值 − 真实折行数：中位数 **-1**，绝对值 p90 **3**，最小 **-6**，最大 **0**。
- **54 行里有 44 行（81%）单位预算低估了真实折行数**——也就是说,这些行的"是否要拆"判断从一开始就没触发,不是拆分算法本身切得烂，而是判断"该不该拆"的信号本身跟真实渲染脱节。

这解释了为什么 ground-truth 那 11 条真实逐字歌词（全部在窄宽度下真实折 3 行）在当前代码里连"是否要拆"的门槛都摸不到——它们只有 11-14 个汉字，远低于 21 单位预算，`estimatedVisualLineCount` 认为不需要拆，实际渲染器却因为 24pt 大字号 + 116pt 窄内容宽度把它们折成了 3 行。这是本次 eval 发现的一个可独立修的根因级问题：**拆不拆的判断依据应该换成真实测量（或至少用真实渲染宽度校准过的单位常数），而不是继续用一个跟渲染器脱节的启发式单位数**。

## 基线指标表（当前生产行为，`test_baseline_currentBehavior_printsMetricsTable` 实测输出）

按 category：

| category | n | 窄宽度下平均最大视觉行数 | 断点位置（标点/空白/脚本边界/词中间） | 翻译孤儿片段 | 仍 ≥4 视觉行 |
|---|---:|---:|---|---:|---:|
| groundTruthTiming | 11 | 2.64 | 无拆分（全部单片段） | 0 | 0 |
| real | 31 | 3.48 | 标点 0% / 空白 100% / 脚本边界 0% / 词中间 0% | 0 | 13 |
| synthetic | 12 | 5.92 | 标点 0% / 空白 87% / 脚本边界 0% / 词中间 13% | 1 | 11 |

按 script：

| script | n | 窄宽度平均最大视觉行数 | 仍 ≥4 视觉行 |
|---|---:|---:|---:|
| cjk | 17 | 3.59 | 2 |
| hangul | 5 | 2.20 | 1 |
| kana | 1 | 4.00 | 1 |
| latin | 20 | 4.55 | 17 |
| mixed:cjk+kana | 8 | 3.00 | 0 |
| mixed:cjk+latin | 1 | 9.00 | 1 |
| mixed:hangul+latin | 1 | 4.00 | 1 |
| other（阿拉伯语） | 1 | 4.00 | 1 |

- **总计 54 行里 24 行（44%）窄宽度下拆完仍然 ≥4 视觉行**——现有拆分并没有真正解决创始人报的"占满窗口"symptom，只是把一部分长行砍短了一点。
- 断点质量：line-level 那批（53 行里）没有一次断在标点上（0%），因为这批数据本身就是"折 3 行以上"的极端样本，几乎全靠软长度阈值/硬切触发，标点边界这个高优先级信号很少被用上；12% 的断点直接切在词中间（真正的硬失败，全部来自 syn-002 巨长单词和 syn-004 无标点重复短词这类无处下刀的样本）。
- 唯一的逐字歌词样本（syn-001，60 字无空格 CJK）窄宽度下最大视觉行数 **12**——因为 `hasSyllableSync` 行永远不拆，这正是创始人报告的最极端复现。

## 候选方案量化对比

三个方案都只用 harness 里已有的生产 API 模拟，没有改 `Sources/`。

### 候选 A：给逐字歌词也接上拆分（复用已存在但从未被这条路径调用的 `LyricDisplaySegmenter.wordSegments`）

`wordSegments` 早就写好了——按 ≥0.35 秒的词间停顿（`phraseBoundaryWhitespaceDuration`）切分词组，只是 `makeDisplayLyricLines` 对 `hasSyllableSync` 行走的是"永不拆"分支，从来没调用它。用它跑 syn-001（60 字逐字 CJK）：

- 窄宽度平均最大视觉行数：**5.0**（vs 当前代码的 12.0）
- 断点：0% 标点、0% 空白、**100% 词中间**——这批数据本身没有自然停顿（无空格、逐字均匀 0.2s 一个字），所以退化成硬切；真实歌词里长句通常会有换气停顿，这个 0% 结果是 syn-001 故意构造成"没有停顿点"的压力测试暴露出来的边界，不代表 A 方案在真实逐字歌词上也会 100% 硬切。
- 计时误差：中位数/p90 都是 **0.000 秒**——因为拆分直接用真实逐字时间戳当每段起止时间，不存在估计误差。

**代价**：只解决了逐字歌词"永不拆"的问题；不解决行级歌词的断点质量和翻译配对问题。

### 候选 B：只在强标点处断，不管长度预算（有标点就精确断，没有就整行不动）

- 断点质量：**100% 标点边界，0% 词中间**——`XCTAssertEqual(midWordBreaks, 0)` 断言通过，这是唯一一个"零硬失败"的方案。
- 代价立刻可见：`latin` script 平均最大视觉行数从当前代码的 4.55 涨到 **5.40**，`stillFourPlus` 从 17 涨到 16（几乎没变好，因为很多超长行本身标点很少）；`synthetic` category 平均最大视觉行数从 5.92 涨到 **8.82**——完全不受长度约束，短语没有标点就干脆不切，`syn-002`（巨长单词）、`syn-011`（韩语长句）这类行反而比现在更长。

**权衡**：断点质量最好，但完全不解决"占满窗口"的核心症状——对没有标点的长句（很多流行歌词恰恰不用标点）没有任何帮助。

### 候选 C：保留当前拆分位置，只把"均分时长"换成"按字符数比例分配时长"

在 ground-truth 子集（11 条真实逐字歌词，被强制按真实折行数拆分——因为当前单位预算根本不会触发拆分，见上面"意外发现"）上对比拆分点估计起始时间 vs 真实起始时间的误差：

| 方案 | 中位数误差 | p90 误差 | 最大误差 | n |
|---|---:|---:|---:|---:|
| 当前（均分时长） | 0.173s | 0.837s | 1.405s | 28 |
| 候选 C（按字符数比例） | 0.186s | 0.737s | 1.405s | 28 |

**如实报告**：候选 C 在这个小样本（11 首歌的 CJK 逐字句子）上**没有明显赢过均分**——中位数反而略差（0.186 vs 0.173），p90 略好（0.737 vs 0.837）。原因大概率是这批 ground-truth 句子本身字密度均匀（都是 11-14 个汉字、演唱节奏相对平稳的主歌句），均分和按字符比例在这种输入上算出来的时间点很接近。**不能就此下结论"按字符比例没用"**——这只是 11 条歌、单一风格样本量太小的结果；lyric-align 项目的"breath split"思路（字符比例定位 + 就近找真实停顿精修）大概率比纯按字符比例更稳，但这个精修步骤需要真实词间隔数据，这份 ground-truth 已经把词时间轴剥掉模拟"只有行级源"，没法在这个子集上验证"精修"这一步。

## 推荐

不替创始人拍板，摆权衡：

- **只想堵住"逐字歌词永远不拆"这个最极端的症状、改动面最小** → 候选 A（把 `wordSegments` 接进 `hasSyllableSync` 分支），风险最低，因为函数已经存在且有测试（`LyricDisplaySegmenterTests` 里已经在测 `wordSegments`），只是没被这条路径调用。
- **想要断点质量最好、宁可牺牲"是否真的变短"** → 候选 B，但要接受很多无标点长句还是会占满窗口——不能单独解决创始人的核心症状。
- **想要更准的逐句时间轴、且愿意多花一点计算** → 候选 C，但这次的小样本没能证明它比均分明显更好，需要更大的 ground-truth 样本（尤其是非 CJK、字密度不均匀的句子）才能验证。

**我会推荐的方向**：三个候选不是互斥的——A 解决"要不要拆"，C（或 lyric-align 式的"比例定位 + 真实停顿精修"）解决"拆完怎么计时"，B 的"优先在标点/停顿处断、退化到长度预算才硬切"的顺序应该保留。同时，"意外发现"里那条**必须先修**：拆不拆的判断依据要换成用真实渲染宽度校准过的信号（哪怕只是用 `NativeLyricsTextMeasurement` 实测一次，而不是继续用跟渲染器脱节的单位预算）——不然候选 A/B/C 设计得再好，很多真实需要拆的行还是摸不到触发门槛,就像这次 44/54 行、11/11 条 ground-truth 那样。

## 局限性

- 数据集偏小（54 行），且真实数据因为磁盘缓存是活文件、抓取途中被后台清理从 149 首缩到 9 首，主要来自这 9 首歌 + 2 个仓库内既有 fixture；纯韩语/纯假名"≥3 视觉行"的真实样本目前完全靠 synthetic 补位。
- 断点质量分类（标点/空白/脚本边界/词中间）用的是字符启发式定位，不是真正的分词器；CJK 场景下"词中间"的判定偏保守（把没有标点没有空格的相邻字都算作潜在硬失败），可能高估真正的硬失败率。
- Candidate C 的 ground-truth 验证样本只有 11 首同风格的歌（同一首《启程》的不同句子），不足以下"比例分配更准"或"更不准"的定论,只能如实报告"这批数据上打平"。
