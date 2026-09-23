# 系统语言选择器弹窗 + 分段翻译（2026-09-22）

两个阶段：Phase 1 消灭 macOS 系统翻译语言选择器（language picker）弹窗；Phase 2 让 Plan A（2026-09-22 长行拆分）产出的每个 display piece 都有自己的翻译，覆盖之前"翻译只挂第一段"的过渡方案。

---

## Phase 1：language picker 弹窗

### 根因

`LyricsService.silentSystemTranslationConfiguration()`（LyricsService.swift ~2260 行）本来就会算出一个 source language（用 `systemTranslationSourceLanguage(for:)`，对最多 12 行样本跑 `NLLanguageRecognizer`），而且还会拿这个结果去 gate（算不出来就直接跳过翻译，不报错）——但算完之后，实际返回给 `TranslationSession.Configuration` 的 `source` 参数写死是 `nil`：

```swift
return TranslationSession.Configuration(source: nil, target: targetLanguage)
```

`source: nil` 意味着 Apple 的 Translation framework 每一批（batch）请求都要自己重新 auto-detect 源语言。对于能识别的内容没问题；但只要某一批文本它识别不出来置信的语言——短行、混排、罗马音日语、拟声词（vocable）——就会弹出系统级的"选择语言"对话框，打断用户，而且这是**系统 UI**，app 层完全拦不住。`.claude/rules/banned-patterns.md` 里记录的历史教训（`TranslationSession.Configuration(source: detectLanguage())` 把短句英文误判成丹麦语/斯洛伐克语）正是当初把 `source` 改回 `nil` 的原因——但那次修的是"用错误的置信度识别单行短句"，不是"完全不给 source"，两者被合并成了同一个坑,这次要把两者分开处理。

`Sources/MusicMiniPlayerCore/UI/LyricsView.swift` 里还有第二处隐患：`TranslationTaskHostCore.activeConfig` 在真正的 per-song config 还没解析出来前，用一个 bootstrap 占位值 `Configuration(target: Locale.Language(identifier: "zh-Hans"))`（不写 `source` 参数，等价于 `nil`）绑定 `.translationTask`。这个 session 理论上不会真的被用来翻译（`performSystemTranslation` 有自己的 `showTranslation`/`lyrics` 门槛），但既然规则是"app 里任何一个 Configuration 都不能是隐式/显式的 `source: nil`"，这处占位值也要有个显式 source。

### 设计

新文件 `Sources/MusicMiniPlayerCore/Services/LyricsTranslationSourceDetection.swift`：`songLevelSource(eligibleLineTexts:supportedLanguageCodes:) -> Locale.Language?`，按优先级：

1. **脚本判定优先**（`ScriptRunSegmenter` 已有的硬 Unicode 区间事实，不是统计猜测）：全曲文本里只要出现假名（kana）就判 `ja`（假名是 CJK 里唯一能排除中文歧义的信号）；Han 字符占比 >40%（沿用 `lyricsArePredominantlyChinese` 现成阈值）时按已有的简繁体证据（`LanguageUtils.containsTraditionalOnlyChars`/`containsSimplifiedOnlyChars`）判 `zh-Hans`/`zh-Hant`；谚文/泰文/阿拉伯文/西里尔文/天城文（Devanagari）等脚本，只要该脚本覆盖全曲字母数 ≥60%,直接判定对应语言。
2. **兜底才用 `NLLanguageRecognizer`**：整曲样本（不是旧代码的 12 行截断）跑一次识别，`languageConstraints` 限制在 Translation framework 实际支持的语言集合（`SupportedTranslationLanguagesMemo`,一次进程生命周期内 memo 住 `LanguageAvailability().supportedLanguages`）,要求 confidence ≥0.35 且领先第二名 ≥0.15（margin,防止"英语 0.40 vs 丹麦语 0.38"这种历史教训复现）。
3. 两步都判不出来 → 返回 `nil`,调用方**直接跳过翻译**（沉默失败,不弹窗,不再退回 `source: nil` auto-detect）。

配套一个行级门（`lineIsConsistent(_:withSongSource:)`）：一行如果自己的确定性脚本（走 `ScriptRunSegmenter`）和整曲判定的 source 冲突（比如整曲是日语,这一行整句是韩语）,就不送进这个固定 source 的 session;纯数字/emoji/空白（没有任何字母）也不送;剩下的（拉丁/汉字歧义内容,大多数行）照常搭这趟车。`LyricsService.performSystemTranslation` 在拿到待翻译行列表后用这个门过滤一遍。

`silentSystemTranslationConfiguration` 和 `activeConfig` 占位值都改成传显式、非 `nil` 的 `source`。新增一条源码扫描测试（`TranslationConfigurationSourceScanTests`,读取整个 `Sources/` 目录,剥掉注释后正则找每一处 `TranslationSession.Configuration(...)`,断言每处都带非 `nil` 的 `source:`）钉死这条规矩——手动往 Sources 里塞一个 `source: nil` 的探针函数验证过这条测试真的会抓到违规（抓到后已移除探针）。

### Eval

数据集来源：仓库里已有的真实歌词（`Tests/MusicMiniPlayerTests/Fixtures/long_line_eval.json`,按它自带的 `song.key` 分组还原出"整曲"样本,覆盖英语 14 行/简体中文 11+4 行/日语（汉字+假名混排）8 行/韩语+英语混排 5 行）,加上本次任务自己写的、明确标注 synthetic 的短句（西班牙语/法语/葡萄牙语/印地语/泰语/阿拉伯语/繁体中文/罗马音日语/短促口语化英语——每一句都是自己编的、非版权歌词）。西语系（es/fr/pt/hi/th/ar/zh-Hant）和"罗马音日语""历史上误判丹麦语/斯洛伐克语"这两类真实数据集完全缺失,只能靠 synthetic 补位（和 `research/long-line-eval-2026-09-22.md` 自己承认"synthetic stratification fill"的做法一致）。

`LyricsTranslationSourceDetectionTests.test_songLevelSource_accuracyTable` 实测输出（14 曲,13 判对,1 主动跳过,0 判错）：

| 曲目 | 预期 | 实际 | 判定 |
|---|---|---|---|
| real cache-003（英语,14 行） | en | en | 对 |
| real fixture-qicheng（简体中文,11 行） | zh | zh-Hans | 对 |
| real cache-001（日语汉字+假名,8 行） | ja | ja | 对 |
| real fixture-newjeans-howsweet（韩语+英语混排,5 行） | ko | ko | 对 |
| real cache-005（简体中文,4 行） | zh | zh-Hans | 对 |
| synthetic-es | es | es | 对 |
| synthetic-fr | fr | fr | 对 |
| synthetic-pt | pt | pt | 对（见下方"过程中发现的 bug"） |
| synthetic-hi | hi | hi | 对 |
| synthetic-th | th | th | 对 |
| synthetic-ar | ar | ar | 对 |
| synthetic-zh-Hant | zh | zh-Hant | 对 |
| synthetic-romanized-ja | 无标准答案（见下） | nil | 跳过 |
| synthetic-short-colloquial-en | en | en | 对 |

**过程中发现并修的 bug**：第一轮跑 synthetic-pt（葡萄牙语）稳定被判成西班牙语——排查发现 `fallbackSupportedLanguageCodes` 只列了 `pt-BR`/`pt-PT`,没列裸的 `pt`。`NLLanguageRecognizer.languageConstraints` 是按主语言子标签（primary subtag）分桶的,只给区域变体等于把葡萄牙语整个排除出候选集,识别器只能矮子里拔将军选西班牙语。补上 `pt` 之后立刻转对——这条也写进了 `LyricsTranslationSourceDetection.swift` 的代码注释里,防止以后有人"精简"这个集合的时候把裸语言码删掉。

**罗马音日语（诚实的已知局限）**：罗马音本质是拉丁字母,`ScriptRunSegmenter` 的脚本判定和 `NLLanguageRecognizer` 都没有能力从纯拉丁字母文本里认出"这其实是日语的罗马转写"——这需要词典/语言模型,不是脚本事实。安全行为是**沉默跳过**（不猜、不弹窗）,实测确实如此（返回 `nil`）。这是本模块设计上就接受的边界,不算判错。

**行级"跳过多少行"统计**（`test_lineIsConsistent_skipCountsPerSong_printed` 实测）：13 个能判定出 source 的曲目里,每一首的每一行全部落在"一致"范围内（0 行被行级门拦下）——因为这批数据集本身每首歌语言单一,没有夹杂真正冲突脚本的行;`fixture-newjeans-howsweet`（真实的韩语+英语混排曲）也全数通过,证明行级门不会误伤"歌曲本来就该混着播"的正常内容。行级门在单元测试里另外用构造的冲突样本（日语曲夹一句纯韩语）验证了它确实会拦。

### Eval 追加：创始人真实缓存全量核查（2026-09-23，创始人复审要求）

创始人复审后指出：14 首（5 首真实 + 9 首自撰）样本太小,不足以信"0 判错";而且没有验证新加的行级门会不会反而**降低**翻译覆盖率。创始人把一份只读的真实缓存快照拷进了 worktree（`.eval-local/lyrics_cache.json` + `.eval-local/translation_cache.json`,已加入 `.gitignore`,新测试 `RealCacheTranslationCoverageEvalTests` 在这个目录不存在时直接 `XCTSkip`,不进 CI、不碰真实路径）。

用项目自己的 `LyricsDiskCacheEntry`/`CachedLyricLine`/`TranslationCacheEntry` 类型解码（顶层 `{version, entries}` 信封结构体是 `private` 的,在测试文件里按各自文件头注释里写明的形状本地重声明,字段本身不是秘密）。24 条原始缓存条目按 `cacheKeys()` 的多 key 去重后是 **8 首不重复的真实歌曲**——这就是创始人这份快照里"每一首歌"的全部,已经全量跑过,不是抽样。

**全量结果表**（`test_realCacheSourceDetectionAndCoverageEval` 实测输出）：

| # | 来源/专辑 | 判定方法 | 判定语言 | 置信度 | 总行数 | 旧逻辑发送数 | 新逻辑发送数 | 被行级门拦下 |
|---:|---|---|---|---:|---:|---:|---:|---:|
| 1 | NetEase / Make Way for Dionne Warwick | recognizer | en | 1.00 | 30 | 30 | 30 | 0 |
| 2 | LRCLIB-Search / The Essential Billie Holiday | recognizer | en | 1.00 | 15 | 15 | 15 | 0 |
| 3 | LRCLIB / Sinatra The Musical: His Way | recognizer | en | 1.00 | 35 | 35 | 35 | 0 |
| 4 | NetEase / La Vie En Rose (Deluxe Edition) | recognizer | en | 0.94 | 14 | 14 | 14 | 0 |
| 5 | NetEase / Just Call Me Penny | kana | ja | 1.00 | 22 | 22 | 22 | 0 |
| 6 | NetEase / TWILIGHT ZONE | kana | ja | 1.00 | 19 | 19 | 19 | 0 |
| 7 | QQ / 一生也在等... | hanDominance | zh-Hans | 1.00 | 47 | 47 | 47 | 0 |
| 8 | LRCLIB-Search / Dear Uranus | hanDominance | zh-Hant | 1.00 | 42 | 42 | 42 | 0 |

**总覆盖率：旧 224 行 → 新 224 行,保留 100.0%,0 首歌覆盖率下降 >10%,0 处行级门误伤。**

**Fingerprint 交叉核查**（翻译快照 `translation_cache.json` 共 25 条记录,按内容指纹——`firstRealLineSHA256|lineCount`,与 `TranslationDiskCache` 自己判定"这条缓存翻译是否还适用于当前歌词"用的同一把 key——和这 8 首歌逐一比对）：**0 条命中**。也就是说这份翻译快照里的 25 条记录,没有一条对应这份歌词快照里的这 8 首歌——两份快照抓取时覆盖的是创始人真实曲库的不同子集,不是"核查没发现问题",是"这次核查没有可核对的重叠数据"。如实报告,没有伪造一个"命中"来凑数。

**没有发现需要通用修复的问题**——0 判错、0 覆盖率下降、0 语言对分歧,所以本轮没有新的代码改动。**诚实的局限**：这 8 首真实歌曲全部是单一脚本占优（4 首纯英文、2 首日文带假名、2 首中文）,没有一首是混排曲（比如更早那批用 NewJeans 真实歌词做的混排验证不在这份快照里）——行级门在"确定性脚本冲突"场景下的效果,这份真实数据没有机会验证到,只能靠此前的单元测试（构造的日语曲夹韩语行）和 NewJeans fixture 佐证。

### 已知局限

- 罗马音（romanized）内容天生无法用脚本或 NLLanguageRecognizer 可靠识别源语言,見上。
- Eval 数据集（含创始人真实缓存全量核查）目前只覆盖英/中/日/韩四种语言家族的真实数据,且真实数据里没有混排曲样本;西语系/印地语/泰语/阿拉伯语/繁体中文全靠自撰 synthetic 短句补位,不是真实歌词,准确率数字在更大规模、更多语系的真实数据上可能有偏差。
- 行级一致性门只按"确定性脚本冲突"过滤,无法识别"同一脚本、不同语言"的混排（比如拉丁字母写的西班牙语句子夹进英语曲——两边都是 `.unknown`,会被送进同一个 session,翻译出来可能是错的,但这属于翻译准确率问题,不是本次修的弹窗问题）。

---

## Phase 2：分段翻译

### 设计

Plan A（同日早些时候落地,`research/long-line-eval-2026-09-22.md`）把过长的一行拆成多个 display piece,但翻译当时只给第一段（`translation: segmentIndex == 0 ? line.translation : nil`）——这条规则的措辞还留在 `docs/lyrics-ux-contract.md` §E 里（"every chunk gets translation"更早的版本,后被 Plan A 实装时改成了"只挂第一段",两版都不是创始人这次的最终决定）。创始人 2026-09-22 的决定：**每一段都要有自己的翻译**,按三级优先：

1. **Clause 对齐**（`LyricPieceTranslation.clauseAlignedTranslations`）：原文恰好在标点（强/弱分句符）处切开,且译文按自己的标点切出来的 clause 数量恰好和切片数一致 → 按顺序配对。**纯位置配对,不做任何语义理解**,所以加了一条保守的"长度序信号"防线：把原文各段和译文各 clause 分别按长度排序算出排名（rank permutation）,两边排名不一致就拒绝配对——这是创始人举的例子（英文 "I'll wait for you," / "until the end of time" → 中文 "直到时间尽头，我都会等你",clause 数量对得上但顺序是反的）能被这条防线挡住的直接原因。
2. **逐段缓存翻译**（tier 2）：`PieceTranslationCache`（纯内存,不落盘——分段本身就是运行时按窗口宽度现算的,没有跨进程持久化的意义）按 (段文本, source, target) 记忆化;`LyricsService.performPendingPieceTranslations` 复用已经在跑的 `serveTranslationRequests` session（不开第二个 `.translationTask`）,对还没翻过的段批量调用 `ChunkedTranslationRunner.run`,落盘到缓存后 `pieceTranslationVersion` 自增,`LyricsView` 监听这个版本号触发 `refreshDisplayLineCache(forceRebuild: true)`——因为只是换了翻译文本、没换行的 `id`,这条路径复用的正是既有的"翻译热替换不重建/不闪烁" sidecar 机制（`configureSignature` 里已经把每行 translation 文本哈希进签名,`LyricsLateTranslationInsertTests` 钉死的那条通路）。
3. **兜底**：以上两条都拿不到时,整行译文挂在第一段（旧行为保留,但只作为过渡态,不是稳态）,其余段先留空,等异步 tier 2 补上。

### Eval

`LyricPieceTranslationTests`（16 个单元/eval 测试,纯函数,不需要真的调用 Translation framework——用一个假字典当 tier 2 缓存）+ 新增数据集 `Tests/MusicMiniPlayerTests/Fixtures/piece_translation_eval.json`（14 条用例）。

**这次任务对"扩展 long-line 数据集"的理解**：没有直接往 `Tests/MusicMiniPlayerTests/Fixtures/long_line_eval.json` 里加字段——那份 54 行数据集的形状被 `LongLineEvalTests` 自己的 `test_mirrorMatchesProductionSource_contractCheck` 和 (a)-(f) 验收测试钉死,而这次要测的是"原文切片 + 译文 + 期望的 tier"这种全新形状的行,硬塞进去要么破坏既有钉死测试,要么加一堆这些测试用不到的字段。改用一个独立文件,在这里写明这个假设。

`test_extendedDataset_tierDistributionAndInvariants` 实测输出：

| tier | 条数 |
|---|---:|
| clauseAligned | 7（含 unsplit-line 场景之外的真正多段配对样本 3 条：pt-010/pt-013/pt-014） |
| fallbackFirstPiece | 10 |
| none | 10 |
| perPieceCache | 3 |

硬性验收指标：mid-clause cuts = **0**（每一个非空译文都能对应到"整段 clause""整段缓存值""整行 fallback"三者之一,逐条断言过,不是启发式判断"看起来像不像被切断"）;"第一段没有翻译"的情况 = **0**（只要整行有译文,第一段永远至少拿到 fallback）。

**Tier-1 抽样人工核对**（打印出来的配对,创始人可以直接读）：

```
pt-013: Hi,=>嗨， | this is a much longer trailing piece...=>这是一段长得多的后半部分...
pt-014: Hi,=>嗨， | this is a medium length piece here,=>这是中等长度的一段， | and this final piece...=>而这最后一段是三段里最长的一段...
pt-010: Bailamos toda la noche,=>We danced all night long, | hasta que salga el sol=>until the sun came up
```

三条配对肉眼看都是对的。

### 过程中发现的第二个诚实局限：长度序防线比预想的更保守

写 eval 用例时先造了两条"看起来该判定为 clauseAligned"的普通例子（pt-001：英文 "When the rain falls down," / "I will still be here" → 中文 "当雨落下时，我依然在这里等你";pt-002：三段版本）,实测**都被拒绝了,落到 fallback**——不是 bug,是长度序防线的真实代价。原因：中文比英文"信息密度"高很多,同样的意思,英文段落哪个更长和译文对应的 Chinese clause 哪个更长,不是必然同向——pt-001 里英文第一段（26 字符）比第二段（21 字符）长,但翻译成中文后第一个 clause（6 字符）反而比第二个（8 字符）短,纯粹是这句话的自然翻译结果,不是乱序,但长度排名一对比就"看起来像"乱序。

权衡过后**保留了保守判定**（宁可错杀,不可放过）：一次误拒的代价只是退到"整行译文挂第一段"这个本来就正确、只是不够精细的兜底;而一次误判配对的代价是**把明显错的翻译摆在用户眼前**,这个代价严重得多。所以 pt-001/pt-002 保留在数据集里,标注成"诚实的局限"用例,`expectedTier` 改成了 `fallbackFirstPiece`;新增 pt-013/pt-014 用足够悬殊的长度差（几倍关系,不是 20% 上下的正常翻译波动能反转的)来演示这条防线在"差距够大"时确实能放行。这条规则的**真实代价**：日常歌词里长度接近的两段（最常见的 comma-split 场景）大概率会被这条防线判定为"存疑",退回 tier 2/3,tier 1 实际触发率会比"只看 clause 数量"更低——这是有意的取舍,写在 `LyricPieceTranslation.swift` 的 `lengthRankPermutation` 注释里。

### 已知局限（汇总）

- Tier 1 的长度序防线是纯启发式,不理解语义;对"数量匹配但顺序反了"的真实案例（创始人给的例子）有效,但对"数量匹配、顺序没反、只是翻译长度波动"的正常情况也会误伤——保守优先,详见上一节。
- Tier 1/2/3 全部依赖 Phase 1 解析出的 source language；如果 Phase 1 判定不出 source（比如歌曲整体是罗马音日语这类已知局限）,tier 2 异步翻译直接不触发,只剩 tier 3 兜底。
- 本次 eval 全部用假缓存字典代替真实 Translation framework 调用（任务本身允许,"pipeline 逻辑不需要真的调用 Translation framework"）;`performPendingPieceTranslations` 到真实 session 的接线（复用现有 `serveTranslationRequests` 循环）在真机上还没有肉眼终验,按项目规矩需要创始人亲自终验（手感类之外的功能性改动,自验到代码层面为止）。

---

## 安全核查

本任务运行环境是一个 git worktree 隔离的会话,沙盒规则硬性禁止任何触碰 worktree 之外路径的命令（包括 `~/Library/Application Support/nanoPod/`——`ls`/`stat`/`find` 单独尝试均被拒绝,报错"a worktree-isolated agent's git operations must target its own worktree"）,因此**没有能力**按字面要求生成该目录的 mtime+size 前后对比清单。改用静态核查代替：所有新增/改动的测试文件（`LyricsTranslationSourceDetectionTests.swift`/`TranslationConfigurationSourceScanTests.swift`/`LyricPieceTranslationTests.swift`/`RealCacheTranslationCoverageEvalTests.swift`）逐一 grep 过 `Application Support`/`FileManager.default.url`/`NSHomeDirectory` 等字样,**零命中**——它们只读仓库内的 `Fixtures/*.json`（以及创始人手动拷进 worktree 的 `.eval-local/*.json` 只读快照）和调用纯函数（`LyricsTranslationSourceDetection`/`LyricPieceTranslation`）,新增的 `PieceTranslationCache`（见其文件头注释）明确设计成纯内存、不落盘。没有一次 `swift test`/`swift build` 触发网络请求（`LyricsTranslationSourceDetection` 只用 `NaturalLanguage` 框架的 `NLLanguageRecognizer`,离线、设备端、非 Translation framework）。

**`.eval-local/` 处理**（创始人 2026-09-23 提供的真实缓存只读快照）：已加入 `.gitignore`（第一时间做的,在读取快照内容之前）;`RealCacheTranslationCoverageEvalTests` 只 `Data(contentsOf:)` 读取这两个 JSON 文件,整个测试文件里没有任何写入调用;目录不存在时 `XCTSkip`,不会进 CI、也不会因为这份本地快照缺失而报红。`git status`/`git log` 复核过,`.eval-local/` 从未出现在任何一次 `git add`/`git commit` 里。
