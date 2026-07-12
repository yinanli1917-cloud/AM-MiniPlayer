# Project Instructions

This project uses the global Codex harness. Before substantial work,
Codex should use `python3 scripts/codex_harness.py context` and the
active task state under `.codex/tasks/`.

## Migrated Project Notes

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
│   │   ├── LyricsService.swift            - Lyrics facade + cache + translation (includes TranslationService)
│   │   ├── MenuBarHealer.swift            - Self-heal macOS 26 ControlCenter plist at launch
│   │   ├── UpdateService.swift            - Silent GitHub Releases check + download + SHA256 verify + stage
│   │   ├── UpdateApplier.swift            - Spawn detached shell script on quit to swap bundle + relaunch
│   │   └── Lyrics/
│   │       ├── LyricsFetcher.swift              - GAMMA orchestration + 2.70s OS wall-clock foreground deadline + bounded authoritative backfill
│   │       ├── LyricsSourceFetchers.swift       - 7 source fetch methods (AMLL/NE/QQ/LRCLIB/Genius/AM/ovh)
│   │       ├── LyricsCandidateSelection.swift   - SearchCandidate + selectBestCandidate + artist alias
│   │       ├── LyricsResultSelection.swift      - selectBest + identity consensus + validators + rescale
│   │       ├── LyricsParser.swift               - TTML/LRC/YRC parsing
│   │       ├── LyricsScorer.swift               - Quality scoring
│   │       └── MetadataResolver.swift           - iTunes multi-region metadata + song-scoped exact-first waves + single-flight
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
│   │       └── LiquidBackgroundView.swift
│   ├── Utils/
│   │   ├── HTTPClient.swift           - HTTP requests + retry + connection warmup
│   │   ├── LanguageUtils.swift        - Language detection + S/T Chinese conversion
│   │   ├── MatchingUtils.swift        - Matching score utilities
│   │   ├── DebugLogger.swift          - Debug logging
│   │   ├── NSImage+AverageColor.swift - Color extraction + brightness sampling
│   │   ├── MetadataDiskCache.swift    - Persistent metadata cache
│   │   ├── SBTimeoutRunner.swift      - ScriptingBridge timeout wrapper
│   │   ├── DebugConfig.swift          - Debug configuration
│   │   └── AppleScriptRunner.swift    - Music.app osascript execution + parsing
│   ├── Models/LyricModels.swift   - Lyrics data structures + shared constants
│   └── Shaders/blur.metal
└── LyricsVerifier/                - 歌词管线 CLI 测试工具
    ├── main.swift                 - CLI 入口 (run/check/library/benchmark + DEBUG-only --network-only)
    ├── TestRunner.swift           - 测试编排 + JSON 输出
    ├── TestCases.swift            - 用例加载 + AM 资料库 (osascript)
    ├── BenchmarkCases.swift       - 全球基准测试数据模型 + 加载器
    └── BenchmarkValidator.swift   - 基准测试五层验证（翻译泄漏/语言一致性/源翻译/ML翻译/时间轴）

Tests/MusicMiniPlayerTests/         - 148 个单元测试
    ├── LyricsParserTests.swift    - TTML/LRC/YRC 解析测试
    ├── LyricsScorerTests.swift    - 评分算法 + 边界值测试
    └── MatchingUtilsTests.swift   - 匹配评分 + 权重验证

scripts/fix_menubar.py             - macOS 26 ControlCenter menu bar database fix

docs/lyrics_test_cases.json        - 15 条预定义歌词测试用例
docs/lyrics_benchmark_cases.json   - 100 首全球基准测试（10 语言区域 × 10 首）
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

### Lyrics Source Architecture (7 Parallel Sources + Quality Scoring)

| Source | Bonus | Notes |
|--------|-------|-------|
| AMLL-TTML-DB | +10 | Word-level timestamps |
| NetEase | +8 | Chinese primary, YRC + translation |
| QQ Music | +6 | Chinese secondary, supports translation |
| SimpMusic | +5 | Global, YouTube Music community |
| LRCLIB | +3 | Exact match |
| LRCLIB-Search | +2 | Fuzzy search |
| lyrics.ovh | +0 | Plain text fallback |

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
swift run LyricsVerifier run --network-only  # Developer/verifier cache-isolated diagnostic (not in release app)
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
