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

---

## 结果（2026-09-22，创始人选定方案 A 后实装）

创始人在候选 A/B/C 之间选了 **A**（并给出了比原始候选 A 更完整的规格：真实折行触发 + 优先级断点 + 逐字精确计时 + 行级按字符比例计时 + 翻译只挂第一段）。已在本 worktree 落地，`git rebase main` 已完成（对齐了 legibility/blank-page/artwork 三批 main 上的修复，无冲突）。

### 改动范围（严格限定在"display-line construction layer"，未碰渲染器）

- `Sources/MusicMiniPlayerCore/UI/LyricDisplayLineMeasurement.swift`（新文件）——只读调用 `NativeLyricsTextMeasurement`/`NativeLyricsRowMeasurement`/`NativeLyricsTextConstants`（渲染器自己的 NSLayoutManager 配方），暴露 `visualLineCount(for:rowWidth:isBackground:)`，不修改、不驱动渲染器状态。
- `Sources/MusicMiniPlayerCore/UI/LyricDisplaySegmenter.swift`——新增 `realWrapPieces`（行级文本，优先级断点：强标点＞弱标点＞脚本边界＞空白＞纯紧凑文字系统字符边界，孤儿片段兜底合并）、`realWrapWordPieces`（逐字歌词，"就近找最大停顿"断点，lyric-align 式）、`proportionalTiming`（按字符数比例分配时长 + 时长过短兜底合并邻居）。**旧的 `segments`/`balancedSegments`/`wordSegments`/`estimatedVisualLineCount` 等单位预算函数原样保留、零改动**——它们现在是生产代码里的死代码（没有任何调用点），但删除它们、连带删除/改写它们各自的 `LyricDisplaySegmenterTests` 用例超出了这次任务"只做拆分决策改动"的范围，留作后续清理（见下方"待办"）。
- `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`——`makeDisplayLyricLines` 重写为调用上述新函数；`shouldKeepDisplayLineUnsplit`/`displayTiming` 保留原名，改造成薄封装（前者变成纯粹的 `pieceCount <= 1` 判断，后者转发到 `LyricDisplaySegmenter.proportionalTiming`）；新增歌词列宽度状态（`CacheState.segmentationRowWidth`，默认 250 即首启动窗口宽度）+ `updateLyricsSegmentationWidthIfNeeded`（首次拿到真实宽度立即生效不防抖，之后每次宽度变化走 150ms 防抖再重建，同款生成计数器防抖模式已在文件里用过——`scheduleTranslationSessionConfigUpdate`）+ `refreshDisplayLineCache(forceRebuild:)` 新增旁路参数，让宽度变化能绕开原有的"内容没变就跳过"去重门。`isBackground` 行现在显式排在 `makeDisplayLyricLines` 最前面，和 prelude/纯音乐提示一样永不拆分（规格第 6 条）。

### 实装中发现并修的两个 bug（先复现再修，均已用假数据钉死）

1. **脚本边界候选把词内标点也当断点**：`Don't let one mistake keep us apart` 在 250pt 下被切成 `Don'` / `t let one mistake keep us apart`——撇号被判定成"拉丁→其它符号→拉丁"两次脚本切换,抢在空白断点之前命中,直接切进单词内部,违反规格"永不切进拉丁词内部"的硬性要求。根因：`ScriptClass.other`（涵盖所有标点/符号）被当成一个独立"文字系统",任何字符转入/转出 `.other` 都被判定为脚本边界。修复：脚本边界只在**两侧都是**紧凑文字系统或拉丁字母/数字时才算数,`.other` 两侧的转换一律不算。已用 `acceptance_a`/`acceptance_b` 两个测试钉死（改动前会复现,改动后绿）。
2. **数据集本身的时间轴 bug**：`syn-001`（60 字无空格逐字 CJK 合成用例）行级 `startTime/endTime` 写成 100–112 秒,但其 `words` 数组的真实时间戳是 0–12 秒——旧代码从不使用逐字歌词的 words 时间戳做拆分,这个不一致从未被发现;Plan A 一上来就用 words 的真实时间戳算 timing,立刻被 `acceptance_d`（逐字计时误差必须为 0）测出来。已修正 fixture 里的 `startTime`/`endTime` 为 0.0/12.0（与 words 对齐）。

### 验收结果（`LongLineEvalTests`，7 个测试全绿，180pt 与 250pt 都测）

| 验收点 | 结果 |
|---|---|
| (a) 每段 ≤2 视觉行,除非不可再拆的单 token 或时长驱动的合并 | ✅ `test_acceptance_a`（无违规） |
| (b) 零处切进词内部 | ✅ `test_acceptance_b`（`midWord` 恒为 0） |
| (c) 翻译整体挂第一段,其余段不带翻译 | ✅ `test_acceptance_c` |
| (d) 逐字歌词拆分后计时误差为 0 | ✅ `test_acceptance_d`（syn-001 + 11 条 ground-truth 用真实 trueWords 重建逐字行,共同验证） |
| (e) 没有片段短于 1.2s 下限,除非整行本来就更短 | ✅ `test_acceptance_e` |
| (f) 打印 before/after 指标表 | ✅ `test_beforeAfterComparison_printsMetricsTable` |

Before/after 汇总（180pt,54 行数据集,`test_beforeAfterComparison_printsMetricsTable` 实测输出）：

| 指标 | BEFORE（旧：单位预算触发 + 均分时长） | AFTER（Plan A：真实折行触发 + 优先级断点 + 比例计时） |
|---|---:|---:|
| 窄宽度平均最大视觉行数 | 3.870 | **2.630** |
| 仍 ≥4 视觉行的行数 | 24/54（44%） | **6/54（11%）** |
| 断点=词中间硬失败占比 | 12% | **0%** |
| 断点=标点/空白/脚本边界占比 | 88%（几乎全是"软长度阈值恰好命中空白",标点 0%） | 7% 标点 + 70% 空白 + 3% 脚本边界 + 20% 紧凑文字系统字符边界（合计 100% 非硬失败） |

250pt（首启动默认宽度,长行候选本来就少）：平均最大视觉行数 3.870→3.333,仍 ≥4 行 24/54→11/54——改善幅度比 180pt 小,印证了研究笔记前半部分的发现："占满窗口"这个症状主要在窄宽度下暴露,但 Plan A 在两个宽度下都是净改善,没有以窄换宽的取舍。

Ground-truth 子集（11 条真实逐字歌词,180pt）行级计时误差,BEFORE 用"按真实折行数强制拆分 + 均分"（旧单位预算在这批短行上根本不触发拆分,只能这样对照）,AFTER 用 Plan A 完整链路（真实折行触发 + 比例计时,且这批线现在会被真正拆分,不用再强制）：

| | 中位数误差 | p90 误差 | 参与打分的片段数 |
|---|---:|---:|---:|
| BEFORE | 0.173s | 0.837s | 28 |
| AFTER | **0.142s** | 0.934s | 15 |

中位数变好,p90 略差；参与打分的片段数从 28 降到 15,因为 Plan A 下有些行现在整句只拆成 2 段（比研究笔记里"强制按真实折行数拆到 3 段"更保守）,可比片段变少,这个对比口径上不完全对等,只作为方向性参考,不作为唯一验收依据——(a)-(e) 的硬性断言才是验收线。

### 已更新的既有测试（Plan A 主动改变了它们断言的行为,逐一列出）

- `Tests/MusicMiniPlayerTests/NativeLyricsSurfaceSourceTests.swift` 的 `testSplitDisplayLinesDoNotDuplicateFallbackTranslationAcrossSegments` → 改名 `testSplitDisplayLinesAttachFullTranslationToFirstPieceOnly`：旧断言是"未匹配的翻译段留空,不许重复整段翻译"（哪怕改了名字这条依然部分成立）,新断言是规格第 5 条更强的版本——翻译只挂第一段,其余段永远是 `nil`,不管是逐字还是行级拆分路径。
- `Tests/MusicMiniPlayerTests/RapidSwitchTests.swift` 的 `testWordLevelLyricsBypassDisplayChunking` → 改名 `testWordLevelLyricsSplitViaRealWrapWithExactWordTiming`：旧断言是"逐字歌词永远不拆、不许用 `wordSegments`"——这正是创始人报告的症状本身,规格第 3 条明确要求反过来。新断言：逐字歌词现在走 `realWrapWordPieces`（不是 `wordSegments`,后者是给别的调用点设计的、只按首个 ≥0.35s 停顿硬切、不测真实折行、也不找"就近平衡点"）,且每段计时必须来自该组真实 `LyricWord` 时间戳,不能是估算值。
- `LyricDisplaySegmenterTests.swift`：**零改动**。它测的 `segments`/`balancedSegments`/`wordSegments`/`estimatedVisualLineCount` 等旧函数原样保留、没有被调用点改变行为,29 个用例全部原样通过。

### 安全核查

`~/Library/Application Support/nanoPod/` 目录下全部 101 个文件（含 `lyrics_cache.json`）的 mtime + 文件大小,在本次任务全部 `swift test`/`swift build` 调用前后逐字节比对（`stat -f "%N %m %z"` 排序后 diff）：**零差异**。没有测试读写这个目录,也没有产生网络流量（所有新增/改动测试只读本仓库内的 `Fixtures/long_line_eval.json`,调用的都是纯函数）。

### 渲染器相关担忧：无需改动,但有两处预先存在的、与本任务无关的失败

`Tests/MusicMiniPlayerTests/NativeLyricsSurfaceSourceTests.swift` 里的 `testNativeLyricsLayoutInsetsMatchV28SwiftUIRenderer` 和 `testNativeSurfaceDoesNotHostSwiftUIRowViews` 两个测试在**我改动之前的 `main`（rebase 后、Plan A 改动之前）就已经失败**——用 `git stash` 把我的改动完全移出后重跑,失败现象和失败行号完全一致。两个测试都只读取 `NativeLyricsLayerRendererView.swift`/`NativeLyricsLayerSupport.swift`/`NativeLyricsRowView.swift` 的源码文本（我完全没有碰过这几个文件）,失败原因与 Plan A 无关,是 main 分支上先前某次改动遗留的问题。按任务要求"如果 Plan A 好像需要改渲染器,停下汇报"——这两个失败**不是** Plan A 引出的,不需要为了这次任务去碰渲染器文件；已如实记录,建议开一个独立任务查一下 main 上这两个测试从哪次提交开始红的。

### 待办 / 值得单独立项的点

1. **`docs/lyrics-ux-contract.md` §E 有一行和 Plan A 的新行为直接冲突**："🔴 长行分段 display-only；CJK 从不重新分词；≈8 词短语保持一个单元；不做孤字平衡式补丁；**每个分段都要有翻译**" ——最后一条"每个分段都要有翻译"是旧设计（也是这次 eval 任务原本要推翻的"翻译被硬切"问题的另一种表述）,创始人选定的规格第 5 条明确改成"翻译整体只挂第一段,其余段不带"。这次任务只被要求"读"这份契约文档,没被要求改它；没有动这一行,但这是一处需要创始人或后续任务显式更新的文档-代码不一致,先在这里标出来。
2. **旧的单位预算函数（`segments`/`balancedSegments`/`wordSegments`/`estimatedVisualLineCount`/`displayUnits` 等）现在是生产代码里的死代码**,只被自己的测试用到,没有任何生产调用点。保留是这次任务刻意的保守选择（避免不必要的测试改动、超出"只改拆分决策层"的范围）；建议 Plan A 上线并经过创始人肉眼终验后,单独开一个任务清理这批死代码 + 对应测试。
