# nanoPod - macOS 菜单栏音乐迷你播放器
Swift 5.9 + SwiftUI + ScriptingBridge + MusicKit + Apple Music API
GitHub: https://github.com/yinanli1917-cloud/AM-MiniPlayer

> **规则**：仅在用户明确要求时执行 git push。禁止使用私有 API。

---

## 目录结构

```
Sources/
├── MusicMiniPlayerApp/
│   ├── MusicMiniPlayerApp.swift  - AppDelegate + 窗口管理
│   ├── SettingsView.swift        - 设置视图（菜单栏 + 设置窗口 + 组件）
│   └── LocalizedStrings.swift    - L10n 本地化 + UserDefaults 绑定 helper
├── MusicMiniPlayerCore/
│   ├── Services/
│   │   ├── MusicController.swift          - 薄门面：@Published 状态 + 通知/轮询/Timer
│   │   ├── MusicController+Artwork.swift  - 封面提取/获取/缓存
│   │   ├── MusicController+Playback.swift - 播放控制 + 音量 + 收藏 + AppleEventCode
│   │   ├── LyricsService.swift            - 歌词门面 + 缓存 + 翻译
│   │   └── Lyrics/
│   │       ├── LyricsFetcher.swift    - 7源并行获取 + 统一匹配
│   │       ├── LyricsParser.swift     - TTML/LRC/YRC 解析
│   │       ├── LyricsScorer.swift     - 质量评分
│   │       └── MetadataResolver.swift - iTunes 多区域元信息
│   ├── UI/
│   │   ├── MiniPlayerView.swift   - 主播放器视图 + 页面切换
│   │   ├── LyricsView.swift       - 歌词显示 + 滚动 + 翻译
│   │   ├── LyricLineView.swift    - 歌词行/间奏动画/翻译修饰器
│   │   ├── HoverableButtons.swift - 按钮组件 + Tab Bar + 圆角工具
│   │   ├── PlaylistView.swift     - 歌单队列 + 封面加载
│   │   ├── SnappablePanel.swift   - 可吸附浮窗 + 手势
│   │   ├── Components/           - 可复用 UI 组件
│   │   │   ├── SharedControls.swift   - 底部控件
│   │   │   ├── WindowResizeHandler.swift
│   │   │   ├── ScrollDetector.swift
│   │   │   ├── ScrollingText.swift
│   │   │   ├── VisualEffectView.swift
│   │   │   ├── ProgressiveBlurView.swift
│   │   │   ├── FloatingPanel.swift
│   │   │   └── FloatingWindowModifier.swift
│   │   └── Background/           - 背景视图
│   │       ├── FluidGradientBackground.swift
│   │       └── LiquidBackgroundView.swift
│   ├── Utils/
│   │   ├── Extensions.swift
│   │   ├── HTTPClient.swift       - 统一 HTTP 请求 (GET/POST)
│   │   ├── LanguageUtils.swift    - 语言检测 + 简繁转换
│   │   ├── MatchingUtils.swift    - 匹配评分
│   │   ├── DebugLogger.swift      - 调试日志
│   │   └── AppleScriptRunner.swift - Music.app osascript 执行 + 解析（无状态）
│   ├── Models/LyricModels.swift   - 歌词数据结构 + 共享常量
│   └── Shaders/blur.metal
└── LyricsVerifier/                - 歌词管线 CLI 测试工具
    ├── main.swift                 - CLI 入口 (run/check/library)
    ├── TestRunner.swift           - 测试编排 + JSON 输出
    └── TestCases.swift            - 用例加载 + AM 资料库 (osascript)

Tests/MusicMiniPlayerTests/         - 77 个单元测试
    ├── LyricsParserTests.swift    - TTML/LRC/YRC 解析测试
    ├── LyricsScorerTests.swift    - 评分算法 + 边界值测试
    └── MatchingUtilsTests.swift   - 匹配评分 + 权重验证

docs/lyrics_test_cases.json        - 15 条预定义歌词测试用例
postmortem/001~006                 - 已知 bug 根因 + 解决方案
```

## 关键技术决策

### 封面获取（双轨）
- MusicKit：App Store 版，需要开发者签名 + entitlement
- iTunes Search API：开发版，公开 REST，无需授权

### 线程安全
- `scriptingBridgeQueue`（高优先级）：切歌、状态更新
- `artworkFetchQueue`（低优先级）：歌单封面预加载
- ⚠️ ScriptingBridge 只能在 scriptingBridgeQueue 调用，主线程调用会崩溃

### 歌词源架构（7个并行 + 质量评分）

| 源 | 加分 | 特点 |
|----|------|------|
| AMLL-TTML-DB | +10 | 逐字时间轴 |
| NetEase 网易云 | +8 | 中文首选，YRC + 翻译 |
| QQ Music | +6 | 中文次选，支持翻译 |
| SimpMusic | +5 | 全球化，YouTube Music 社区 |
| LRCLIB | +3 | 精确匹配 |
| LRCLIB-Search | +2 | 模糊搜索 |
| lyrics.ovh | +0 | 纯文本备选 |

匹配权重：时长(40%) + 标题(35%) + 艺术家(25%)，阈值 >= 50
多区域元信息：自动检测日/韩/泰/越字符，查询对应 iTunes 区域 API
纯 ASCII 输入：并行查 CN + 推断区域（JP/KR），CN CJK 标题优先

### 性能陷阱（已验证，永远不要重蹈）

- ❌ `Section + LazyVStack + ForEach` → macOS 26 Liquid Glass 下指数级递归（SubgraphList.applyNodes 223次）
  ✅ 用 `VStack` 替代，Header 作为第一个子元素
- ❌ `.hudWindow` 材质 → Liquid Glass 下过曝
  ✅ 用 `.underWindowBackground` 替代
- ❌ `romanized→CJK` 用 `resultHasCJK`（含 artist）→ ASCII→ASCII 标题替换被放行
  ✅ 用 `resultTitleHasCJK`（只检查标题）→ 杜绝 "Moon Style Love"→"milk tea" 错配
- ❌ `isLikelyEnglishArtist` 用"单词=英文"启发式 → 误杀 EPO/JADOES
  ✅ 只用高置信度信号（已知列表 + 英文词缀），安全性靠 `resultTitleHasCJK` 保障
- 完整记录见 `postmortem/` 和 `.claude/rules/banned-patterns.md`

### 匹配算法（统一 SearchCandidate）

NetEase/QQ 共用 `SearchCandidate<ID>` + `selectBestCandidate()` 优先级链：
- P1: 标题+艺术家+时长<3s → P2: 标题+艺术家+时长<20s → P3: 仅标题+时长<1s → P4: 仅艺术家+时长<1s
- `isTitleMatch()` / `isArtistMatch()` 统一处理简繁体 + CJK
- original + resolved 双标题匹配（MetadataResolver 翻译后仍保留原始标题）

## 构建命令

```bash
./build_app.sh                        # 构建 + 签名 → nanoPod.app
swift build                           # 仅构建（快速验证）
open nanoPod.app                      # 启动
swift test                            # 77 个单元测试（Parser/Scorer/Matching）
swift run LyricsVerifier run          # 跑 15 条歌词回归测试
swift run LyricsVerifier check "歌名" "艺术家" 秒数  # 测试单首歌
swift run LyricsVerifier library --recent 20         # AM 资料库测试
```

配置文件：`Package.swift`、`build_app.sh`、`Resources/AppIcon.icns`

## Postmortem 工作流

```
/postmortem check         # 发布前检查（必做）
/postmortem create <hash> # bug fix 后立即记录
/postmortem onboarding    # 分析历史 commits
```

已有 postmortem：001（Section递归）、002（页面切换状态）、003（封面并发）、004（歌词间距）、005（MetadataResolver 批量回归）、006（romanized→CJK 误配）

## Compact Instructions

压缩时**保留**：当前任务状态 · 关键技术决策 · 已知陷阱 · 重要文件路径
压缩时**丢弃**：详细解释过程 · 失败的尝试 · 已完成的讨论历史

---

[PROTOCOL]: 架构变更时更新此文档
