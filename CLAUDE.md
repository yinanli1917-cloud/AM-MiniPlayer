# nanoPod - macOS Menu Bar Music Mini Player
Swift 5.9 + SwiftUI + ScriptingBridge + MusicKit + Apple Music API
GitHub: https://github.com/yinanli1917-cloud/AM-MiniPlayer

> **Rules**: Only run `git push` when the user explicitly asks. Never use private APIs. Before handing over to the user, you must determine how to verify or test the bug fix / new feature and execute the verification; stay in the verification loop until confirmed working.

---

## Directory Structure

```
Sources/
├── MusicMiniPlayerApp/
│   ├── MusicMiniPlayerApp.swift  - AppDelegate + window management
│   ├── SettingsView.swift        - Settings view (menu bar + settings window + components)
│   └── LocalizedStrings.swift    - L10n localization + UserDefaults binding helpers
├── MusicMiniPlayerCore/
│   ├── Services/
│   │   ├── MusicController.swift          - Thin facade: @Published state + notifications/polling/Timer
│   │   ├── MusicController+Artwork.swift  - Artwork extraction/fetching/caching
│   │   ├── MusicController+Playback.swift - Playback controls + volume + favorites + AppleEventCode
│   │   ├── LyricsService.swift            - Lyrics facade + cache + translation (includes TranslationService) + NWPathMonitor offline self-recovery + LyricsDisplayState machine (deep-search never demotes content) + 会话未命中备忘三集成点（确认未命中记录/抓取开始短路/forceRefresh 旁路清除）
│   │   ├── LyricsMissMemo.swift           - 会话级已确认无歌词备忘（20min TTL，纯内存不落盘，重启即清；取消/离线永不记录）
│   │   ├── MenuBarHealer.swift            - Self-heal macOS 26 ControlCenter plist at launch
│   │   ├── UpdateService.swift            - Silent GitHub Releases check + download + SHA256 verify + stage
│   │   ├── UpdateApplier.swift            - Spawn detached shell script on quit to swap bundle + relaunch
│   │   ├── MetadataWarmupSweep.swift      - 启动元数据预热：每 schema 版本一次，后台串行解析队列/最近曲目缺失行（utility QoS + 让位前台抓取 + 可整体取消，仅元数据不抓歌词）
│   │   └── Lyrics/
│   │       ├── LyricsFetcher.swift              - GAMMA pipeline orchestration + fetchAllSources + AuthoritativeBackfillBudget (回填 9s 硬上限) + DrainExitFacts（排水循环退出闭包拆分：纯项每结果只算一次，事件项留在闭包内）
│   │       ├── LyricsSourceFetchers.swift       - 8 source fetch methods (AM/AMLL/NE/QQ/LRCLIB×2/Genius/ovh) + AppleMusicCapabilityLatch（首次 developer-token 失败后进程级跳过 MusicKit，按能力非编译开关）
│   │       ├── LyricsCandidateSelection.swift   - SearchCandidate + selectBestCandidate + artist alias + 日语读音相等门（取代 romaji 白名单）+ 包含匹配 ≥4 拉丁字符下限
│   │       ├── LyricsResultSelection.swift      - selectBest + identity consensus + validators + rescale + 写一次记忆化（token/solo/romaji/quality 每结果只算一次；单结果池统一走 solo 裁决备忘录）
│   │       ├── LyricsParser.swift               - TTML/LRC/YRC parsing
│   │       ├── LyricsScorer.swift               - Quality scoring
│   │       └── MetadataResolver.swift           - iTunes multi-region metadata + 四入口 single-flight 合流（同 key 并发咨询共享一次解析，仅去重不缓存）+ 目录别名共识桥（song-scoped 查询坍缩单一身份 = Apple 索引断言翻译标题，Dinner→三個人的晚餐）+ 行级证据戳回放（exact-title/phonetic/catalog-alias，英→CJK 缓存行不再每会话重解析）
│   ├── UI/
│   │   ├── MiniPlayerView.swift   - Main player view + page switching
│   │   ├── LyricsView.swift       - Lyrics display + scrolling + translation
│   │   ├── LyricsLayerRendererView.swift - Native lyrics surface + frame loop
│   │   ├── NativeLyricsRowView.swift     - Native row text/dot layer rendering
│   │   ├── NativeLyricsLayerSupport.swift - Display-link and inert-layer helpers
│   │   ├── HoverableButtons.swift - Button components + Tab Bar + corner radius utilities
│   │   ├── PlaylistView.swift     - Playlist queue + artwork loading
│   │   ├── SnappablePanel.swift   - Snappable floating panel + gestures
│   │   ├── Components/           - Reusable UI components
│   │   │   ├── SharedControls.swift   - Bottom controls
│   │   │   ├── WindowResizeHandler.swift
│   │   │   ├── ScrollDetector.swift
│   │   │   ├── ScrollingText.swift
│   │   │   ├── VisualEffectView.swift
│   │   │   └── ProgressiveBlurView.swift
│   │   └── Background/           - Background views
│   │       ├── FluidGradientBackground.swift
│   │       ├── LiquidBackgroundView.swift
│   │       └── PanelBackdrop.swift   - 面板底材切换（fluid 默认 | macOS 26 原生 NSGlassEffectView 玻璃实验臂），nanopod://debug/backdrop/<style> 运行时切换
│   ├── Utils/
│   │   ├── HTTPClient.swift           - HTTP requests + retry + connection warmup + NetworkOutcomeLedger (protocol vs transport)
│   │   ├── LanguageUtils.swift        - Language detection + S/T Chinese conversion + Japanese reading (CFStringTokenizer) + two-lane romanized-title corroboration
│   │   ├── MatchingUtils.swift        - Matching score utilities
│   │   ├── DebugLogger.swift          - Debug logging
│   │   ├── NSImage+AverageColor.swift - Color extraction + brightness sampling
│   │   ├── MetadataDiskCache.swift    - Persistent metadata cache（CN/多区域两层独立字典 + 防抖落盘 + flush + v8 行级 evidence 戳）
│   │   ├── SBTimeoutRunner.swift      - ScriptingBridge timeout wrapper
│   │   ├── DebugConfig.swift          - Debug configuration + NANOPOD_PROBES 每帧探针总闸（默认关；/tmp 旧探针文件会静默重新武装探针，曾写出数百 MB 挂机）
│   │   ├── WindowAnimationCensus.swift - 缺陷5仪器：全窗口层树动画普查（挂着的 CAAnimation + NSVisualEffectView 清单），nanopod://debug/animsweep 按需一次性 dump，永不每帧
│   │   └── AppleScriptRunner.swift    - Music.app osascript execution + parsing
│   ├── Models/
│   │   ├── LyricModels.swift          - Lyrics data structures + shared constants
│   │   ├── LyricsSourceProfile.swift  - Typed source registry: 8 providers + declared trait profiles
│   │   └── MusicQueueProvenance.swift - Queue provenance model
│   └── Shaders/blur.metal
└── LyricsVerifier/                - 歌词管线 CLI 测试工具
    ├── main.swift                 - CLI 入口 (run/check/library/benchmark)
    ├── TestRunner.swift           - 测试编排 + JSON 输出
    ├── TestCases.swift            - 用例加载 + AM 资料库 (osascript)
    ├── BenchmarkCases.swift       - 全球基准测试数据模型 + 加载器
    └── BenchmarkValidator.swift   - 基准测试五层验证（翻译泄漏/语言一致性/源翻译/ML翻译/时间轴）

Tests/MusicMiniPlayerTests/         - 665 个单元测试
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
    └── NativeLyricsInactiveBaseRestoreTests.swift - 去活路径必须还原整行基底文本（活跃级联置 nil 后隐藏字形层导致整行消失）
    └── RadioDurationlessMatchingTests.swift - 电台时长未知匹配：duration=0 是缺失信号非完美信号，标题+艺人双强制；已知时长门槛不变
    └── RadioTrackChangeDebounceTests.swift - 电台换歌确认：无 PID 身份需连续两次一致读数才触发管线（缓冲期标题瞬态不再刷新页面）

scripts/fix_menubar.py             - macOS 26 ControlCenter menu bar database fix

docs/lyrics_test_cases.json        - 15 条预定义歌词测试用例
docs/lyrics_benchmark_cases.json   - 100 首全球基准测试（10 语言区域 × 10 首）
docs/defect-recordings/            - 缺陷录屏逐帧证据归档（含 NOTES.md 分析）
postmortem/001~006                 - 已知 bug 根因 + 解决方案
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
  ✅ Blur economy: rasterize settled non-active blurred rows (`applyRasterizationPolicy` + `refreshRasterization` in NativeLyricsRowView; dot-animation veto; backing-scale rasterizationScale) + blur is a stepped depth cue (snaps in setTarget/quickRetarget so blur-only retargets settle instantly and stay rasterized through handoffs); guarded by NativeLyricsBlurEconomyTests
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
swift test                            # 77 unit tests (Parser/Scorer/Matching)
swift run LyricsVerifier run          # Run 15 lyrics regression tests
swift run LyricsVerifier check "Song" "Artist" duration  # Test a single song
swift run LyricsVerifier library --recent 20                              # AM 资料库测试
swift run LyricsVerifier benchmark                                       # 100 首全球基准测试
swift run LyricsVerifier benchmark --region ko                           # 按区域筛选 (en/ko/ja/zh/es/hi/fr/pt/th/ar)
swift run LyricsVerifier benchmark --no-local-translation                # 跳过本地 ML 翻译验证
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
