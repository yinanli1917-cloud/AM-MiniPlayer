# nanoPod - macOS 菜单栏音乐迷你播放器
Swift 5.9 + SwiftUI + ScriptingBridge + MusicKit + Apple Music API
GitHub: https://github.com/yinanli1917-cloud/AM-MiniPlayer

> **规则**：仅在用户明确要求时执行 git push。禁止使用私有 API。

---

## 目录结构

```
Sources/
├── MusicMiniPlayerApp/
│   └── MusicMiniPlayerApp.swift  - AppDelegate + 窗口管理 + 设置界面
└── MusicMiniPlayerCore/
    ├── Services/
    │   ├── MusicController.swift  - 播放控制 + 状态管理 + 封面获取
    │   ├── LyricsService.swift    - 歌词搜索 + 解析 + 缓存
    │   └── MusicBridge.swift      - ScriptingBridge 桥接
    ├── UI/
    │   ├── MiniPlayerView.swift   - 主播放器视图 + 页面切换
    │   ├── LyricsView.swift       - 歌词显示 + 滚动 + 翻译
    │   ├── PlaylistView.swift     - 歌单队列 + 封面加载
    │   ├── SnappablePanel.swift   - 可吸附浮窗 + 手势
    │   ├── WindowResizeHandler.swift
    │   └── ScrollDetector.swift
    ├── Utils/Extensions.swift
    └── Shaders/blur.metal

.claude/rules/banned-patterns.md   - PlaylistView 严禁代码模式
postmortem/001~004                 - 已知 bug 根因 + 解决方案
docs/                              - 参考文档（歌词技术文档、测试用例）
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

### 性能陷阱（已验证，永远不要重蹈）

- ❌ `Section + LazyVStack + ForEach` → macOS 26 Liquid Glass 下指数级递归（SubgraphList.applyNodes 223次）
  ✅ 用 `VStack` 替代，Header 作为第一个子元素
- ❌ `.hudWindow` 材质 → Liquid Glass 下过曝
  ✅ 用 `.underWindowBackground` 替代
- 完整记录见 `postmortem/` 和 `.claude/rules/banned-patterns.md`

## 构建命令

```bash
./build_app.sh   # 构建 + 签名 → nanoPod.app
swift build      # 仅构建（快速验证）
open nanoPod.app # 启动
```

配置文件：`Package.swift`、`build_app.sh`、`Resources/AppIcon.icns`

## Postmortem 工作流

```
/postmortem check         # 发布前检查（必做）
/postmortem create <hash> # bug fix 后立即记录
/postmortem onboarding    # 分析历史 commits
```

已有 postmortem：001（Section递归）、002（页面切换状态）、003（封面并发）、004（歌词间距）

## Compact Instructions

压缩时**保留**：当前任务状态 · 关键技术决策 · 已知陷阱 · 重要文件路径
压缩时**丢弃**：详细解释过程 · 失败的尝试 · 已完成的讨论历史

---

[PROTOCOL]: 架构变更时更新此文档
