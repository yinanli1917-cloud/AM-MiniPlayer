# nanoPod - AI Agent 开发指南

## 项目信息

- **GitHub**: https://github.com/yinanli1917-cloud/AM-MiniPlayer
- **作者**: yinanli1917-cloud
- **邮箱**: yinanli1917@gmail.com

> **注意**: 仅在用户明确要求时才执行 git push，不要每次修改都自动推送。

## 项目概述

nanoPod 是一个 macOS 菜单栏/浮窗音乐播放器，类似 iOS PiP 风格。使用 SwiftUI + AppKit 混合开发。

## 核心技术栈

- **Swift 5.9+** / **macOS 14.0+**
- **SwiftUI** (主 UI 框架)
- **AppKit** (窗口管理、系统集成)
- **AppleScript** (控制 Music.app - 主要方式)
- **MusicKit** (辅助功能：歌词、MusicKit artwork)
- **Glur** (渐进式模糊效果)

## 长期开发原则

### 1. App Store 合规性 (最高优先级)

- **禁止使用私有 API**
- 所有权限必须在 Info.plist 和 entitlements 中正确声明
- 沙盒模式必须启用 (`com.apple.security.app-sandbox`)
- 需要的权限：
  - `com.apple.security.automation.apple-events` (控制 Music.app)
  - `com.apple.security.network.client` (MusicKit API)
  - `NSAppleEventsUsageDescription` (AppleScript 权限说明)
  - `NSAppleMusicUsageDescription` (Media Library 权限说明)

### 2. 性能优化

- 避免不必要的视图重绘
- 使用 `@State`, `@StateObject`, `@EnvironmentObject` 正确管理状态
- 动画使用 `withAnimation` 包裹，避免隐式动画
- 大图片处理使用后台线程
- 轮询间隔适当（当前 0.5s），避免过度消耗 CPU

### 3. 代码风格

- 遵循现有代码结构和命名规范
- 添加必要的中文注释说明关键逻辑
- 使用 `// MARK: -` 分隔代码区块
- 优先使用已有的库和模式

## 当前功能状态

### 已完成 ✅

1. **浮窗模式** - 可拖拽浮动窗口
2. **菜单栏模式** - 点击菜单栏图标显示 popover
3. **专辑页面** - 封面展示、hover 显示控件
4. **歌词页面** - 实时歌词同步
5. **歌单页面** - History / Up Next / Now Playing
6. **播放控制** - 播放/暂停、上下曲、进度条拖拽、shuffle/repeat
7. **matchedGeometryEffect** - 页面切换时封面动画
8. **Glur 渐进模糊** - 封面底部渐进模糊效果

### 进行中 🚧

1. **惯性拖拽四角吸附** (SnappablePanel.swift)
   - 禁用系统默认拖拽，完全自定义
   - 手动接管 mouseDragged
   - 速度采样计算惯性
   - mouseUp 时惯性投掷到最近角落
   - 弹簧动画效果

## 文件结构

```
Sources/
├── MusicMiniPlayerApp/
│   ├── MusicMiniPlayerApp.swift    # 应用入口、窗口管理
│   ├── Info.plist                  # 应用配置、权限声明
│   └── MusicMiniPlayer.entitlements # 沙盒权限
│
└── MusicMiniPlayerCore/
    ├── Services/
    │   └── MusicController.swift   # 音乐控制核心（AppleScript + MusicKit）
    │
    └── UI/
        ├── MiniPlayerView.swift    # 主视图容器
        ├── LyricsView.swift        # 歌词页面
        ├── PlaylistView.swift      # 歌单页面
        ├── SnappablePanel.swift    # 惯性拖拽窗口
        ├── SharedControls.swift    # 共享控件（进度条、按钮等）
        ├── FloatingPanel.swift     # 浮动窗口基类
        └── LiquidBackgroundView.swift # 动态背景
```

## 关键实现细节

### 1. Glur 渐进模糊

**正确用法**：
- Glur 是直接应用在图片上的 modifier，不是叠加层
- `radius` 必须是固定值，不能动态变化（会导致图片消失）
- 通过 opacity 切换显示/隐藏

```swift
Image(nsImage: artwork)
    .glur(radius: 16.0, offset: 0.5, interpolation: 0.35, direction: .down)
    .opacity(shouldShow ? 1 : 0)
```

**不能用于**：
- Tab 栏遮罩（用 VisualEffectView + LinearGradient mask）
- 进度条遮罩（用 VisualEffectView + LinearGradient mask）

### 2. 惯性拖拽 (SnappablePanel)

**核心逻辑**：
1. 重写 `sendEvent(_:)` 拦截鼠标事件
2. `mouseDown`: 检查是否应该传递给子视图（按钮等），记录初始位置
3. `mouseDragged`: 超过最小距离后移动窗口，记录速度采样
4. `mouseUp`: 计算加权平均速度，根据惯性投射落点选择最近角落，弹簧动画

**区分点击和拖拽**：
- `minimumDragDistance = 3`
- 未超过阈值时正常传递事件给子视图

### 3. 权限问题排查

如果无法连接 Music.app，按顺序检查：

1. **重置权限缓存**：
   ```bash
   tccutil reset AppleEvents com.yinanli.MusicMiniPlayer
   tccutil reset MediaLibrary com.yinanli.MusicMiniPlayer
   ```

2. **检查系统偏好设置**：
   - 隐私与安全性 → 自动化 → nanoPod → Music.app ✅
   - 隐私与安全性 → 媒体与 Apple Music → nanoPod ✅

3. **重新构建并运行**：
   ```bash
   swift build && cp -f .build/debug/MusicMiniPlayer nanoPod.app/Contents/MacOS/nanoPod && open nanoPod.app
   ```

4. **查看日志**：
   ```bash
   log stream --predicate 'subsystem == "com.yinanli.MusicMiniPlayer"' --level debug
   ```

## 构建命令

```bash
# 开发构建
swift build

# 复制到 app bundle 并重新签名（必须！否则权限会失效）
cp -f .build/debug/MusicMiniPlayer nanoPod.app/Contents/MacOS/nanoPod && \
codesign --force --deep --sign - nanoPod.app && \
touch nanoPod.app && \
open nanoPod.app

# 清理构建
swift package clean
```

**重要**：
- 复制二进制文件后必须 `codesign --force --deep --sign -` 重新签名
- 否则 Info.plist 不会绑定到签名，导致 AppleScript 权限失效
- `touch nanoPod.app` 更新时间戳，确保 macOS 重新加载

## 注意事项

1. **不要修改** `nanoPod.app/Contents/Info.plist` - 它会被构建脚本覆盖
2. **entitlements 文件**目前未被 swift build 使用（需要 Xcode 或手动 codesign）
3. 调试版本没有代码签名，权限可能有问题
4. 如果遇到权限问题，先尝试 `tccutil reset`

### 4. 惯性拖拽 + 四角吸附 + 贴边隐藏 (SnappablePanel)

**核心功能**：
1. **惯性拖拽** - 拖拽时记录速度，释放后根据速度计算投射落点
2. **四角吸附** - 根据投射落点所在象限选择最近的屏幕角落
3. **弹簧动画** - 使用高 stiffness (280) + damping (22) 实现快速但平滑的动画
4. **贴边隐藏** - 拖到屏幕左/右边缘可隐藏，只露出 20px
5. **双指拖拽** - 只在专辑页面生效，歌词/歌单页面不响应
6. **进度条保护** - 底部 100px 控件区域不触发窗口拖拽

**关键实现**：
- 使用 120Hz Timer 实现流畅弹簧动画
- `currentPageProvider` 回调判断当前页面
- `isInBottomControlsArea` 保护进度条交互

## 待办功能

- [ ] 更真实的弹簧动画（当前使用贝塞尔曲线近似）
- [ ] 多显示器支持优化
- [ ] 窗口位置记忆
- [ ] 键盘快捷键
