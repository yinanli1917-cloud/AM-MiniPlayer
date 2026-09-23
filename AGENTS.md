# nanoPod - macOS Menu Bar Music Mini Player
Swift 5.9 + SwiftUI + ScriptingBridge + MusicKit + Apple Music API
GitHub: https://github.com/yinanli1917-cloud/AM-MiniPlayer

This project uses the global Codex harness. Before substantial work,
Codex should use `python3 scripts/codex_harness.py context` and the
active task state under `.codex/tasks/`.

_(现状 2026-09-03：全局 codex harness 已由创始人于 2026-08-17 下令停用（`~/.codex/harness-disabled*`，kyb 有案），其 bin 目录已不在，上述命令目前报 FileNotFoundError。本段是历史描述，非当前可执行指令，保留以备重新启用时对照。)_

> **Rules**: Only run `git push` when the user explicitly asks. Never use private APIs. Before handing over to the user, you must determine how to verify or test the bug fix / new feature and execute the verification; stay in the verification loop until confirmed working.
>
> **歌词验收硬标准（创始人 A 规则，2026-08-26 拍板，取代 08-25 含翻译全 3s 口径）**：原文歌词从播放到出词，所有路径（缓存命中、未命中、各歌词源、冷启动、切歌、seek）硬保证 ≤3 秒。翻译并行去取：3 秒内到就一起出，没到先出原文、翻译到了无缝补上，不打断不闪烁。准确率与性能一样都不能缺。此前 08-25 口头口径是含翻译全 3s——今为唯一权威记载，任何歌词管线改动以此为验收线。
>
> **手感类验证（创始人 2026-08-21 永久规则）**：歌词切行渐隐、滚动、动效这类手感项，自验只做代码层面——单元测试、时间戳日志、可控的假时钟、确定性回放。不用 computer use，不录屏，除非创始人自己提供录屏。自验通过后提醒创始人亲自终验，自动测试通过不能替代。全局规矩见 ~/.claude/CLAUDE.md。
>
> **先复现再修（创始人 2026-08-27 立为项目铁律）**：凡创始人报告的 bug，动手改代码前必须先在代码层面复现——假时钟、状态注入、确定性回放做出可重跑的失败用例；穷举后仍复现不了的，先加 DEBUG 埋点让日常使用自动留证，拿到证据再修。禁止只凭对现象的推测模型直接开改（前科：08-25 防振荡改动未复现创始人所报 mask bug 就动手，直到 08-27 才真复现根因是布局竞态）。「未复现」永远不许当「没问题」上报。
>
> **版本号（创始人 2026-08-27 裁定）**：现行发售线是 **v0.28**。`build_app.sh` 从 git tag `v0.*` 生成 `CFBundleShortVersionString` / `CFBundleVersion` / `BuildInfo.txt`（exact match 优先，否则最新 `v0.*`；可用 `NANOPOD_MARKETING_VERSION` 覆盖）。旧 **v2.x tags 保留为历史，不删不改、不参与版本生成**（v2.8 是旧 SwiftUI 内核命名，与 v0.28 无关）。证据：`git log` 找到 `b24b182 build: release nanoPod 0.28 beta bridge` 与 `60dcb1d`（「Future v0.x tags derive update sequence from the minor version」）；tag `v2.8` 的 subject 就是那次 0.28 beta bridge；仓库无 CHANGELOG；`Sources/MusicMiniPlayerApp/Info.plist` 与旧 `build_app.sh` 曾写死 `2.5`。搜过：`CHANGELOG*`、`git log --all --grep=v0.`、`git log --grep=0.28`、`git log --grep=版本号`、源码/注释 `v0.`。

---

## Directory Structure

```
Sources/
├── MusicMiniPlayerApp/            - 纯净版可执行 target：只剩 main.swift（AppMain.main()）+ Info.plist + entitlements（2026-09-12 WT-E 目录切分，为纯净版/完整版两个产品做准备）
├── MusicMiniPlayerAppKit/         - App 层库 target（原 MusicMiniPlayerApp 源码整体 git mv 至此，零逻辑改动）
│   ├── MusicMiniPlayerApp.swift  - AppDelegate + window management（AppMain 与委托方法 public）
│   ├── SettingsView.swift        - Settings view (menu bar + settings window + components)
│   └── LocalizedStrings.swift    - L10n localization + UserDefaults binding helpers
├── MusicMiniPlayerCore/
│   ├── Services/
│   │   ├── MusicController.swift          - Thin facade: @Published state + notifications/polling/Timer
│   │   ├── MusicController+Artwork.swift  - Artwork extraction/fetching/caching
│   │   ├── MusicController+Playback.swift - Playback controls + volume + favorites + AppleEventCode
│   │   ├── LyricsService.swift            - Lyrics facade + cache + translation (includes TranslationService) + NWPathMonitor offline self-recovery + LyricsDisplayState machine (deep-search never demotes content) + 会话未命中备忘三集成点（确认未命中记录/抓取开始短路/forceRefresh 旁路清除）+ 行级/unsynced 必须回填且允许行→逐字热切换（P1 只禁降级）
│   │   ├── LyricsMissMemo.swift           - 会话级已确认无歌词备忘（20min TTL，纯内存不落盘，重启即清；取消/离线永不记录）
│   │   ├── MenuBarHealer.swift            - Self-heal macOS 26 ControlCenter plist at launch
│   │   ├── UpdateService.swift            - Silent GitHub Releases check + download + SHA256 verify + stage
│   │   ├── UpdateApplier.swift            - Spawn detached shell script on quit to swap bundle + relaunch
│   │   ├── MetadataWarmupSweep.swift      - 启动元数据预热：每 schema 版本一次，后台串行解析队列/最近曲目缺失行（utility QoS + 让位前台抓取 + 可整体取消，仅元数据不抓歌词）
│   │   └── Lyrics/
│   │       ├── LyricsFetcher.swift              - GAMMA pipeline orchestration + fetchAllSources + AuthoritativeBackfillBudget (回填 9s 硬上限) + DrainExitFacts（排水循环退出闭包拆分：纯项每结果只算一次，事件项留在闭包内）
│   │       ├── LyricsOriginalDeliverySLA.swift  - 原文 3s A 规则：路径天花板 + 翻译后补不闸原文（2.9/3.1 边界）
│   │       ├── LyricsSourceFetchers.swift       - 8 source fetch methods (AM/AMLL/NE/QQ/LRCLIB×2/Genius/ovh) + AppleMusicCapabilityLatch（首次 developer-token 失败后进程级跳过 MusicKit，按能力非编译开关）
│   │       ├── LyricsCandidateSelection.swift   - SearchCandidate + selectBestCandidate + artist alias + 日语读音相等门（取代 romaji 白名单）+ 包含匹配 ≥4 拉丁字符下限
│   │       ├── LyricsResultSelection.swift      - selectBest + identity consensus + validators + rescale + 写一次记忆化（token/solo/romaji/quality 每结果只算一次；单结果池统一走 solo 裁决备忘录）
│   │       ├── LyricsParser.swift               - TTML/LRC/YRC parsing
│   │       ├── LyricsScorer.swift               - Quality scoring
│   │       └── MetadataResolver.swift           - iTunes multi-region metadata + 四入口 single-flight 合流（同 key 并发咨询共享一次解析，仅去重不缓存）+ 目录别名共识桥（song-scoped 查询坍缩单一身份 = Apple 索引断言翻译标题，Dinner→三個人的晚餐）+ 行级证据戳回放（exact-title/phonetic/catalog-alias，英→CJK 缓存行不再每会话重解析）
│   ├── UI/
│   │   ├── NativeLyricsFrameStep.swift  - 呈现弹簧步长量化（整数刷新周期）
│   │   ├── MiniPlayerView.swift   - Main player view + page switching
│   │   ├── LyricsView.swift       - Lyrics display + scrolling + translation
│   │   ├── LyricsLayerRendererView.swift - Native lyrics surface + frame loop
│   │   ├── NativeLyricsRowView.swift     - Native row text/dot layer rendering
│   │   ├── NativeLyricsLayerSupport.swift - Display-link and inert-layer helpers
│   │   ├── NativeLyricsFeelParity.swift - 切行手感三对照（appear/blur/sweep），nanopod://debug/feel/<channel>/<v28|current|layer>
│   │   ├── HoverableButtons.swift - Button components + Tab Bar + corner radius utilities
│   │   ├── PlaylistView.swift     - Playlist queue + artwork loading
│   │   ├── SnappablePanel.swift   - Snappable floating panel + gestures
│   │   ├── Components/           - Reusable UI components
│   │   │   ├── SharedControls.swift   - Bottom controls
│   │   │   ├── WindowResizeHandler.swift
│   │   │   ├── ScrollDetector.swift
│   │   │   ├── ScrollingText.swift
│   │   │   ├── VisualEffectView.swift
│   │   │   ├── ProgressiveBlurView.swift
│   │   │   └── PlaylistControlButton.swift - Shared Shuffle/Repeat capsule button chrome (icon content is a @ViewBuilder param)
│   │   └── Background/           - Background views
│   │       ├── FluidGradientBackground.swift
│   │       ├── LiquidBackgroundView.swift
│   │       └── PanelBackdrop.swift   - 面板底材切换（fluid 默认 | macOS 26 原生 NSGlassEffectView 玻璃实验臂），nanopod://debug/backdrop/<style> 运行时切换
│   ├── Utils/
│   │   ├── HTTPClient.swift           - HTTP requests + retry + connection warmup + NetworkOutcomeLedger (protocol vs transport)
│   │   ├── LanguageUtils.swift        - Language detection + S/T Chinese conversion + Japanese reading (CFStringTokenizer) + two-lane romanized-title corroboration
│   │   ├── ScriptRunSegmenter.swift   - 混排行按文字系统切段（谚文/假名/泰文等脚本确定语言→显式 source；拉丁/汉字→source nil），翻译后按序拼回（09-20）
│   │   ├── MatchingUtils.swift        - Matching score utilities
│   │   ├── DebugLogger.swift          - Debug logging
│   │   ├── E2EEventLog.swift          - 真 app 端到端冒烟：NANOPOD_E2E=1 才写 JSONL 事件 + status 快照（生产默认无 I/O）
│   │   ├── NSImage+AverageColor.swift - Color extraction + brightness sampling
│   │   ├── MetadataDiskCache.swift    - Persistent metadata cache（CN/多区域两层独立字典 + 防抖落盘 + flush + v8 行级 evidence 戳）
│   │   ├── SBTimeoutRunner.swift      - ScriptingBridge timeout wrapper
│   │   ├── DebugConfig.swift          - Debug configuration + NANOPOD_PROBES 每帧探针总闸（默认关；/tmp 旧探针文件会静默重新武装探针，曾写出数百 MB 挂机）
│   │   ├── WindowAnimationCensus.swift - 缺陷5仪器：全窗口层树动画普查（挂着的 CAAnimation + NSVisualEffectView 清单），nanopod://debug/animsweep 按需一次性 dump，永不每帧
│   │   ├── NanoPodCacheLocation.swift  - 缓存目录/文件名归属仲裁：production|testRun|isolated|override 四态 + schema 版本化文件名，防止非生产进程读写创始人真实缓存、防止双 schema 互相冲刷
│   │   └── AppleScriptRunner.swift    - Music.app osascript execution + parsing
│   ├── Models/
│   │   ├── LyricModels.swift          - Lyrics data structures + shared constants
│   │   ├── LyricsSourceProfile.swift  - Typed source registry: 8 providers + declared trait profiles
│   │   └── MusicQueueProvenance.swift - Queue provenance model
│   └── Shaders/blur.metal
└── LyricsVerifier/                - 歌词管线 CLI 测试工具
    ├── main.swift                 - CLI 入口 (run/check/library/benchmark + DEBUG-only --network-only)
    ├── TestRunner.swift           - 测试编排 + JSON 输出
    ├── TestCases.swift            - 用例加载 + AM 资料库 (osascript)
    ├── BenchmarkCases.swift       - 全球基准测试数据模型 + 加载器
    └── BenchmarkValidator.swift   - 基准测试五层验证（翻译泄漏/语言一致性/源翻译/ML翻译/时间轴）

Tests/MusicMiniPlayerTests/         - 999 个单元测试（2026-08-27 `swift test` 实测；2026-08-26 为 985）
    ├── LyricsParserTests.swift    - TTML/LRC/YRC 解析测试
    ├── JapaneseReadingTests.swift - 日语读音判定（8 对旧白名单 fixture + 前缀扩展负例 + 长音折叠 + fail-closed + 包含下限）
    ├── MetadataDiskCacheTierTests.swift - 元数据缓存层隔离（CN/多区域互不覆盖）+ CN 证据元组往返 + v6 schema 冲洗 + 防抖合并写
    ├── LyricsSelectionMemoizationTests.swift - 选择记忆化：token/solo/排水事实/romaji/quality 各算一次 + 钉死值等值 + duration 键安全 + 单结果池 chokepoint
    ├── LyricsScorerTests.swift    - 评分算法 + 边界值测试
    ├── LyricsSourceProfileTests.swift - 类型化源注册表 oracle 等值测试（旧硬编码阶梯字面量）
    ├── MatchingUtilsTests.swift   - 匹配评分 + 权重验证
    ├── NetworkOutcomeLedgerTests.swift - 网络结果分类表 + 负面裁决配额 + task-local default-allow + MusicKit 配置失败 indeterminate 钉死
    ├── AuthoritativeBackfillBudgetTests.swift - 回填预算算术（9s 哨兵 ≥ 最长链 7.7s）+ 并行别名发现合并顺序 oracle + marker-only 证据窗口
    ├── ResolverSingleFlightTests.swift - 解析器 single-flight：同 key 并发咨询只执行一次解析体 + 异 key 不合流 + awaiter 取消不杀共享任务
    ├── MetadataWarmupTests.swift  - 预热扫描：每 schema 版本一次 + 有行即跳过 + 让位前台 + 取消不盖戳（全 seam 注入，零网络）
    ├── AppleMusicCapabilityLatchTests.swift - AM 能力闩锁：developer-token 失败武装一次 + 瞬态/账户态错误不武装 + reset 测试缝
    ├── LyricsMissMemoTests.swift  - 会话未命中备忘：TTL 命中/过期剪枝 + 裁决载荷往返 + clear + 记录门（取消/离线拒绝）
    ├── NativeLyricsBlurEconomyTests.swift - 模糊经济：settled 模糊行光栅化（backing scale）+ 活跃行豁免 + 加载点动画否决 + reuse 清除 + blur 阶跃（setTarget/quickRetarget 即达且立即 settled）
    ├── NativeLyricsDimBaseContinuityTests.swift - 暗底亮度连续性（缺陷3第二根源）：切行任一帧有效亮度=行opacity×基层opacity×attr alpha 钉死 0.35 等于非活跃档 + 翻译基底同治 + 手动滚动 0.6 档 + reuse 复位 + 防抖
    ├── WindowAnimationCensusTests.swift - 动画普查契约：隐藏层/mask 层上的无限动画可被发现 + 安静树报零 + effect view 清单 + 格式化输出
    ├── NativeLyricsLoopIdleTests.swift - 呈现 loop 空闲裁决：暂停+间奏必须放行停摆（缺陷5根因）+ 播放中间奏保活 + 未settled运动不分播放态 + appear 窗不分播放态
    └── NativeLyricsImplicitAnimationTests.swift - 隐式动画卫生（窗口托管 + 事务提交才能复现）
    └── PanelBackdropStyleTests.swift - 面板底材开关：未知/缺省值必须回落 fluid（实验不改默认外观）
    └── PlaybackClockTrustTests.swift - 慢 SB 读时钟信任：漂移小于读延迟不确定度必须压制（钉死 2026-07-17 实测振荡值），大漂移（seek/晚发现换歌）仍落地
    └── RowArtworkStoreTests.swift - 行封面分层存储：内存→磁盘(Apple 层→web 层)→single-flight 网络；按来源分层落盘；终败不缓存可重试
    └── TrackIdentityDisciplineTests.swift - 轨道身份纪律：PID 权威三门（同曲通知不换歌/未知 PID 不单独断言/Apple 图已应用丢迟到结果）+ 歌词同曲 PID 锚 + 中毒显示态必可自愈
    └── NativeLyricsEmphasisPartitionTests.swift - 全强调行退化：整行皆强调则全不强调（空 base+sweep 分区缺陷，Billie Jean 副歌类 0.8% 行）
    └── NativeLyricsInactiveBaseRestoreTests.swift - 去活路径必须还原整行基底文本（layer A/B 臂仍会 nil；默认 v2.8 dim 整行保留）
    └── NativeLyricsPauseFreezeTests.swift - 假时钟暂停注入：逐字进度必须冻结，不许升整行
    └── NativeLyricsActiveLineSpacingTests.swift - 激活前后行高/字距/基线快照（中英）+ v2.8 leading scale
    └── NativeLyricsFeelParityTests.swift - 切行手感三对照（appear 窗 / blur 阶跃 / Canvas vs CALayer dim）量化表 + nanopod://debug/feel/
    └── RadioDurationlessMatchingTests.swift - 电台时长未知匹配：duration=0 是缺失信号非完美信号，标题+艺人双强制；已知时长门槛不变
    └── TranslationWritebackTests.swift - 翻译单发布回写：纯合并函数一次赋值（曾逐行改 @Published 数组多次重渲）
    └── LyricsOriginalDeliverySLATests.swift - 原文 3s A 规则：十条路径天花板 + 2.9/3.1 边界 + 准确率降级阶梯 + 前台窗口 clip
    └── LyricsWordLevelPriorityTests.swift - 逐字优先（池内 syllable 必须赢行级）+ 回填不因行级 cancel + 行→逐字热切换
    └── NativeLyricsMaskExhaustiveHandoffTests.swift - 假时钟穷举切行 mask（零几何/appear 窗/远跳/中段 seek）+ v2.8 visual spring damping 20
    └── LyricsLateTranslationInsertTests.swift - 翻译后补热插入：只改译文、词轴/displayState 不动；托管 surface 3.1s sidecar 不重建 semantic
    └── RadioTrackChangeDebounceTests.swift - 电台换歌确认：无 PID 身份需连续两次一致读数才触发管线（缓冲期标题瞬态不再刷新页面）
    └── NativeLyricsLineLevelIdleCostTests.swift - 行级切行后 loop 必须在 2.1s 内可停摆 + runtimeConfiguration 行高累计记忆化命中计数（09-20）
    └── NativeLyricsMaskTraceEconomyTests.swift - mask trace 探针：空闲 tick 只出 tick_summary，切行/卡顿才出单条 tick
    └── NativeLyricsBackgroundRowTests.swift - 和声从属行：0.8× 字号、低一档亮度、不放大、不模糊焦点、主行几何不变（09-20）
    └── LyricsImplausibleDensitySelectionTests（LyricsSelectionTests.swift 内）- 真抓取件：NetEase 坏时间轴（朗读速率不合理）不得靠 ±12 翻盘 LRCLIB
    └── ScriptRunSegmenterTests.swift - 混排切段/拼回纯函数
    └── NativeLyricsIncomingRowGeometryTests.swift - 切行窗口入场/出场行墨迹几何（含行自身 transform 映射）：折行行跨 CATextLayer→位图切换零跳动；两套文本引擎根因钉死（09-21）
    └── NativeLyricsDeferredDeactivationBrightnessTests.swift - 出场行延迟去活期间有效亮度逐帧连续，finalize 不得弹亮
    └── NativeLyricsFrameStepTests.swift - 弹簧步长按整数刷新周期量化
    └── NativeLyricsOrphanAvoidanceTests.swift - CJK/短拉丁孤字折行：仅当尾巴≤2字且放宽 24pt 能少一行时放宽容器宽度
    └── NativeLyricsWordFloatGateTests.swift - 入场行逐字上浮从本行波浪触发帧起算
    └── NativeLyricsHandoffClockTests.swift - 切行确定性时钟门：注入播放钟+墙钟锁步驱动真 surface（debugNowOverride/debugTick/debugPlaybackClockDateProvider），钉死上一行位移/opacity/亮层同帧退场（边界后 +150ms 错峰）；复现旧红测试=0.8s appear 窗内切行被冻结、余晖先暗的 harness 伪影

scripts/fix_menubar.py             - macOS 26 ControlCenter menu bar database fix
scripts/e2e_smoke.sh               - 真 app 端到端冒烟（构建→启动→osascript 驱 Music→JSONL 断言；跑前静音、跑完恢复）

docs/lyrics_test_cases.json        - 82 条预定义歌词测试用例（`LyricsVerifier run` 全量跑）
docs/lyrics_benchmark_cases.json   - 100 首全球基准测试（10 语言区域 × 10 首）
docs/defect-recordings/            - 缺陷录屏逐帧证据归档（含 NOTES.md 分析）
postmortem/001~006                 - 已知 bug 根因 + 解决方案

research/references/               - 竞品动效研究（competitor motion studies）：录屏 + perceive-animation 逐帧拆解 spec
```

## Key Technical Decisions

### Artwork Fetching (Dual-Track)
- MusicKit: App Store builds, requires developer signing + entitlement
- iTunes Search API: Dev builds, public REST, no authorization needed

### Thread Safety
- `scriptingBridgeQueue` (high priority): Track changes, state updates
- `artworkFetchQueue` (low priority): Playlist artwork prefetching
- ⚠️ ScriptingBridge must only be called on `scriptingBridgeQueue` — calling from main thread will crash

### Lyrics Source Architecture (8 Parallel Sources + Quality Scoring)

Typed registry: `LyricsSource` + per-source trait profile in `Models/LyricsSourceProfile.swift` — bonuses, admission floors, mirror group, and risk checks are declared per case (compiler-enforced, no string comparisons). Oracle-equality tests in `LyricsSourceProfileTests` pin these values to the legacy ladders.

| Source | Bonus | Notes |
|--------|-------|-------|
| AppleMusic | +12 | First-party TTML via MusicKit |
| AMLL-TTML-DB | +10 | Word-level timestamps, community DB |
| NetEase | +8 | Chinese primary, YRC + translation |
| QQ Music | +6 | Chinese secondary, supports translation |
| LRCLIB | +3 | Exact match (/get) |
| LRCLIB-Search | +2 | Fuzzy search (/search), same library as LRCLIB |
| Genius | +1 | Plain text scrape, unsynced |
| lyrics.ovh | -2 | Plain text fallback, unsynced |

Matching weights: Duration (40%) + Title (35%) + Artist (25%), threshold >= 50
Multi-region metadata: Auto-detects Japanese/Korean/Thai/Vietnamese characters, queries corresponding iTunes regional API
Pure ASCII input: Parallel queries to CN + inferred region (JP/KR), CN CJK title takes priority

### Performance Traps (Verified — Never Repeat)

- ❌ `Section + LazyVStack + ForEach` → Exponential recursion on macOS 26 Liquid Glass (SubgraphList.applyNodes 223x)
  ✅ Use `VStack` instead, with Header as the first child element
- ❌ `.hudWindow` material → Overexposure under Liquid Glass
  ✅ Use `.underWindowBackground` instead
- ❌ `romanized→CJK` using `resultHasCJK` (includes artist) → ASCII→ASCII title replacement slips through
  ✅ Use `resultTitleHasCJK` (title-only check) → Prevents "Moon Style Love"→"milk tea" mismatch
- ❌ romanized→CJK resolver (multi-region AND album-scoped) accepting a CJK result on artist/album+duration ONLY → wrong song: same/featured-artist ("Er Shi Sui De Lang Man"→大嘴巴 "Funky那個女孩", Δ0.17 vs 0.50) OR sibling album track ("Er Shi Sui De Lang Man"→蓝心湄 "快节奏" on album 二十岁的浪漫, Δ0.27 vs 0.50). Poison persists in lyrics_cache.json + served via canUseImmediateDiskLyrics
  ✅ Title-corroboration: candidate `LanguageUtils.toLatinLower` (pinyin/romaji) must match the romanized input; applied in selectBestRegionCandidate, multi-region merge, AND resolveAlbumScopedMetadata; graceful fallback when none corroborate; bump LyricsDiskCache.schemaVersion to flush poisoned rows
- ❌ `isLikelyEnglishArtist` with "word=English" heuristic → False positives on EPO/JADOES
  ✅ Use only high-confidence signals (known list + English affixes), safety backed by `resultTitleHasCJK`
- ❌ `TranslationSession.Configuration(source: detectLanguage())` → NLLanguageRecognizer misclassifies English as Danish/Slovak → unsupported pair → instant failure → dots flash then vanish
  ✅ Always use `source: nil`, let Apple's Translation framework auto-detect
- ❌ Genius/lyrics.ovh skip timing penalties (duration/coverage/gap) → inflated scores (~46) beat synced sources (~39)
  ✅ `selectBest` prefers synced sources with score >= 30 over unsynced; romaji penalty applies to all unsynced sources
- ❌ P4 (artist-only match) without title guard → Same-artist collisions when durations align (NewJeans "How Sweet" 191s → "Supernatural" 191s)
  ✅ P4 requires token overlap or CJK title — blocks coincidental duration-only matches
- ❌ QQ Music timestamps used raw → Consistently ~0.4s late (verified across 614 lines, 16 songs, median +0.42s vs NetEase)
  ✅ `qqTimeOffset = 0.4` applied via `applyTimeOffset` (same pattern as NetEase 0.7s)
- ❌ Dynamic `setActivationPolicy(.regular↔.accessory)` in FloatingWindowDelegate → macOS 26 destroys NSStatusItem visibility on every toggle
  ✅ Use `LSUIElement=true` in Info.plist, only change activation policy in `updateDockVisibility()`
- ❌ Bundle ID change (MusicMiniPlayer→nanoPod) leaves stale `menuItemLocations` in ControlCenter's `trackedApplications` → status item placed at x=-1 (off-screen)
  ✅ Run `scripts/fix_menubar.py` to clean stale entries; build_app.sh runs it automatically
- ❌ Bare CALayer sublayers in layer-backed NSViews → EVERY property change implicitly animates 0.25s; NSView.layout() frame assignments escape call-site CATransaction wraps → translation drifts in from top-left, reflow ghosts, sweep/dot smear
  ✅ Layer-level kill: `.lyricsInert()` on every renderer-created layer (NativeLyricsInertLayerDelegate) + ImplicitAnimLeak runtime auditor (LOCAL_DEVELOPER_BUILD, ~4Hz) + NativeLyricsImplicitAnimationTests (must host in NSWindow + CATransaction.flush between phases or the bug is unreproducible)
- ❌ SwiftUI `onChange(currentTrackTitle)` runs AFTER body → first post-track-change render feeds the native surface NEW identity + OLD cachedLayerRows = one-frame stale-rows flash
  ✅ `cachedLayerRowsTrackKey` identity gate: rows cached for another track render as `[]`
- ❌ Resident CIGaussianBlur on static lyric rows → the compositor re-evaluates every resident filter each frame it recomposites the surface; during the active line's word sweep the ~12-25 static blurred rows billed WindowServer +38 CPU points on M1 while the app itself stayed cheap (~10%)
  ✅ Blur economy: rasterize settled non-active blurred rows (`applyRasterizationPolicy` + `refreshRasterization` in NativeLyricsRowView; dot-animation veto; backing-scale rasterizationScale) + blur is a stepped depth cue (snaps in setTarget/quickRetarget so blur-only retargets settle instantly and stay rasterized through handoffs); guarded by NativeLyricsBlurEconomyTests. v2.8 springed blur is the `nanopod://debug/feel/blur/v28` A/B arm.
- ❌ 激活行把 dim 基底从整行 CATextLayer 改铺成 per-glyph 并一起 float → 中文换行行距/字距跳变
  ✅ v2.8 Canvas 模型：dim 整行保留、只让亮层 float；`nanopod://debug/feel/sweep/layer` 对照旧路径
- ❌ 文本 isActive 绑 `isPlaying` → 暂停把逐字进度打成 1（整行全亮）
  ✅ 暂停只冻播放钟；当前行保持 text-active；`NativeLyricsPauseFreezeTests`
- ❌ actool "success" (`partial_info.plist` exists) skipping `Resources/AppIcon.icns` → Finder/Dock 无图标
  ✅ 先拷 icns，再尝试 actool 出 Assets.car；bundle 内没有 `AppIcon.icns` 则拒绝交付
- ❌ 行级 LRCLIB 命中就 cancelAll 前台/回填 → 逐字源被剪掉；P1 一律冻结显示 → 行级永远升不了逐字
  ✅ 预算内到手的逐字优先；行级/unsynced 必须 launch 回填（含 AMLL/AM）；只允许升级热切换、禁止降级
- ❌ 排查完把 `NanoPodMaskTraceEnabled` 留在 ~/Library/Preferences/com.yinanli.nanoPod.plist → 120Hz 每帧拼 JSON 写盘，行级歌曲 CPU 40%（09-20 第三次探针当元凶）
  ✅ 探针武装判定缓存一次；空闲 tick 只聚合出 tick_summary；排查完必须 `defaults write … NanoPodMaskTraceEnabled -bool NO`
- ❌ 「人工整理源优先 ±12」只看头/尾/大空洞 → NetEase 副歌 1.7s 塞 5 行照样翻盘 LRCLIB
  ✅ 朗读速率合理性（>40 拉丁当量字符/秒 且窗口 <0.6s）计入时间轴完整性缺陷，取消容差；H07 用例 `maxImplausibleDenseLines: 0`
- ❌ 混排行整行 `source: nil` 自动检测 → 只译主脚本，韩文段残留
  ✅ ScriptRunSegmenter 按脚本切段，谚文段显式 ko 源（脚本判定，非识别器猜测）
- ❌ 和声只靠「整行括号」文本启发式，TTML x-bg 被解析器丢弃
  ✅ `LyricLine.isBackground` 数据模型字段，三路识别（x-bg / 整行括号 / 行首尾括号拆分），渲染为主行从属行（LyricsDiskCache schemaVersion 31）
- ❌ 非生产进程（XCTest/LyricsVerifier/worktree 或 spike 构建）用默认构造共享 ~/Library/Application Support/nanoPod 缓存 + 版本不匹配时加载即丢弃、下次持久化直接覆盖对方 schema 的文件（09-22 一个 spike 跑 lyrics schema 30 把 app 的 schema 31 歌词缓存冲刷掉）
  ✅ `NanoPodCacheLocation` 四态归属仲裁（production|testRun|isolated|override）+ schema 版本化文件名，旧版本文件只读作一次性 seed 不回写
- Full records in `postmortem/` and `.claude/rules/banned-patterns.md`

### Matching Algorithm (Unified SearchCandidate)

NetEase/QQ share `SearchCandidate<ID>` + `selectBestCandidate()` priority chain:
- P1: Title + Artist + Duration < 3s → P2: Title + Artist + Duration < 20s → P3: Title-only + Duration < 1s → P4: Artist-only + Duration < 0.5s + title token overlap or CJK
- `isTitleMatch()` / `isArtistMatch()` handle Simplified/Traditional Chinese + CJK uniformly
- Dual-title matching with original + resolved (MetadataResolver preserves original title after translation)

## Build Commands

```bash
./build_app.sh                        # Build + sign → nanoPod.app
swift build                           # Build only (quick validation)
open nanoPod.app                      # Launch
swift test                            # 999 unit tests (needs DEVELOPER_DIR=/Applications/Xcode.app; CLT has no XCTest)
swift run LyricsVerifier run          # Run the 82 predefined lyrics regression cases (network; provider weather applies)
swift run LyricsVerifier run --network-only  # Developer/verifier cache-isolated diagnostic (not in release app)
swift run LyricsVerifier check "Song" "Artist" duration  # Test a single song
swift run LyricsVerifier library --recent 20                              # AM 资料库测试
swift run LyricsVerifier benchmark                                       # 100 首全球基准测试
swift run LyricsVerifier benchmark --region ko                           # 按区域筛选 (en/ko/ja/zh/es/hi/fr/pt/th/ar)
swift run LyricsVerifier benchmark --no-local-translation                # 跳过本地 ML 翻译验证
./scripts/e2e_smoke.sh            # 真 app 端到端冒烟（静音+恢复；断言 JSONL，不看屏幕）
```

Config files: `Package.swift`, `build_app.sh`, `Resources/AppIcon.icns`

## Postmortem Workflow

```
/postmortem check         # Pre-release check (mandatory)
/postmortem create <hash> # Record immediately after bug fix
/postmortem onboarding    # Analyze historical commits
```

Existing postmortems: 001 (Section recursion), 002 (Page switch state), 003 (Artwork concurrency), 004 (Lyrics spacing), 005 (MetadataResolver batch regression), 006 (romanized→CJK mismatch), 007 (Chinese translation leak trilogy), 008 (Translation dots flash + Genius score inflation)

## Compact Instructions

**Keep**: Task state · Technical decisions · Known pitfalls · Important file paths
**Drop**: Detailed explanations · Failed attempts · Completed discussions

---

[PROTOCOL]: Update this document on architecture changes
