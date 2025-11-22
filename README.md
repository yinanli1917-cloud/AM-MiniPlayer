# Music Mini Player for macOS

一个精美的 macOS 菜单栏音乐播放器，带有歌词显示和流畅动画。

## ✨ 特性

- 🎵 **菜单栏迷你播放器** - 占用空间小，随时可用
- 🎨 **动态背景** - 根据专辑封面自动提取颜色
- 📝 **歌词显示** - 支持时间同步的歌词滚动
- 🎭 **3D 翻转动画** - 优雅的页面切换效果
- 📋 **播放列表** - 查看播放历史和队列
- ⚡ **流畅动画** - 细腻的过渡效果

## 🚀 快速开始

### 方法一：直接使用 .app（推荐）

1. 打开应用：
   ```bash
   open MusicMiniPlayer.app
   ```

2. 应用会出现在菜单栏，点击音乐图标即可使用

### 方法二：从源码构建

1. 构建并创建 .app：
   ```bash
   ./build_app.sh
   ```

2. 启动应用：
   ```bash
   open MusicMiniPlayer.app
   ```

## 📖 使用说明

### 页面切换

- **专辑页** → **歌词页**：点击左下角的对话气泡图标 💬
- **专辑页** → **播放列表**：点击右下角的列表图标 📋
- **返回专辑页**：在任何页面点击相应图标即可返回

### 控制操作

- **播放/暂停**：点击中央播放按钮
- **上一曲/下一曲**：点击左右箭头
- **进度控制**：鼠标悬停在进度条上会变粗，可拖动调整
- **查看歌词**：切换到歌词页，歌词会自动同步滚动

## 🎵 歌词功能

### 歌词来源

应用会自动从以下来源获取歌词：
1. **LRCLIB** - 优先，支持时间同步
2. **lyrics.ovh** - 备选，纯文本歌词

### 歌词同步

- 歌词提前 600ms 开始动画
- 滚动和模糊效果完全同步
- 当前行高亮显示，其他行渐进模糊

## 🛠 技术栈

- **Swift** - 核心语言
- **SwiftUI** - UI 框架
- **MusicKit** - 音乐播放控制
- **ScriptingBridge** - Music.app 集成

## 📝 开发说明

### 项目结构

```
MusicMiniPlayer/
├── Sources/
│   ├── MusicMiniPlayerApp/      # 主应用
│   └── MusicMiniPlayerCore/     # 核心功能
│       ├── Services/            # 服务层
│       │   ├── MusicController.swift
│       │   ├── LyricsService.swift
│       │   └── NSImage+AverageColor.swift
│       └── UI/                  # UI 组件
│           ├── MiniPlayerView.swift
│           ├── LyricsView.swift
│           ├── PlaylistView.swift
│           └── LiquidBackgroundView.swift
├── Package.swift
└── build_app.sh                 # 构建脚本
```

### 构建命令

```bash
# Debug 构建
swift build

# Release 构建
swift build -c release

# 创建 .app 包
./build_app.sh
```

## 🎨 动画参数

- **歌词切换**：600ms easeInOut
- **页面翻转**：600ms spring (response: 0.6, damping: 0.8)
- **进度条放大**：1.05x scale on hover
- **控制显示**：300ms blur fade + 50ms delay

## 📄 许可证

MIT License

## 🙏 致谢

- 使用 LRCLIB 和 lyrics.ovh 提供的免费歌词 API
- 灵感来自 Apple Music 的设计语言
