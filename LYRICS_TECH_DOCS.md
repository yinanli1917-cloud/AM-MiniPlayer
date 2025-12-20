# nanoPod 歌词页面技术文档

## 项目概述

nanoPod 是一个 macOS 平台的 Apple Music 迷你播放器，使用 SwiftUI 构建。歌词页面是核心功能，参考了 AMLL (Apple Music Like Lyrics) 的设计理念。

**参考项目**: https://github.com/Steve-xmh/applemusic-like-lyrics

---

## 核心需求与实现路径 (避免重复犯错)

### 逐字高亮实现 - 历史错误记录

| 尝试方案 | 代码 | 失败原因 |
|---------|------|----------|
| GeometryReader in mask | `.mask(GeometryReader { geo in ... })` | GeometryReader 在 mask 内获取的尺寸错误 |
| frame(width:).clipped() | `.frame(width: w * progress).clipped()` | 改变 Text 布局，导致文字压缩/换行 |
| @State 测量宽度 | `@State var measuredWidth: CGFloat` | 异步更新导致布局闪烁 |
| ZStack + clipShape | `ZStack { Text; Text.clipShape(...) }` | 可能因 scaleEffect/offset 导致重叠 |

### 正确实现方案 (AMLL 风格)

**核心原理**: AMLL 使用 CSS `linear-gradient` mask 实现渐变高亮，mask 滑动不影响布局。

**SwiftUI 对应实现**:
```swift
// 方案 A: 使用 foregroundStyle + LinearGradient (当前采用)
Text(word.word)
    .font(.system(size: fontSize, weight: .semibold))
    .foregroundStyle(
        LinearGradient(
            stops: [
                .init(color: .white, location: max(0, progress - 0.001)),
                .init(color: .white.opacity(0.35), location: progress)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    )

// 方案 B: 使用 mask + Rectangle (备选)
Text(word.word)
    .foregroundColor(.white)
    .mask(
        Rectangle()
            .scaleEffect(x: progress, anchor: .leading)
    )
    .background(
        Text(word.word)
            .foregroundColor(.white.opacity(0.35))
    )
```

### AMLL 原始实现参考 (已扒取)

```javascript
// AMLL lyric-line.ts - mask 滑动实现
// mask 从左向右滑动，不改变布局
maskStyle = `linear-gradient(
    to right,
    rgba(0,0,0,0.85) ${leftPos * 100}%,
    rgba(0,0,0,0.25) ${(leftPos + fadeWidth) * 100}%
)`;

// 位置计算
maskPosition = clamp(
    -width,
    -width + (currentTime - startTime) * (width / duration),
    0
);

// 关键参数
fadeWidth = word.height / 2;  // 渐变宽度
bright = 0.85;                // 已唱部分不透明度
dark = 0.25;                  // 未唱部分不透明度
```

---

## 一、歌词滚动动画系统

### 1.1 滚动动画参数 (ScrollViewReader)

```swift
// 歌词行切换时的滚动动画 - 慢而柔和
.interpolatingSpring(
    mass: 2.0,      // 较大惯性，动画更从容
    stiffness: 25,  // 很软的弹簧，动画更慢
    damping: 10,    // 低阻尼，保持柔和弹性
    initialVelocity: 0
)

// 歌词行自身状态变化动画 (scale/blur/opacity)
.interpolatingSpring(
    mass: 2,
    stiffness: 100,
    damping: 25,
    initialVelocity: 0
)
```

### 1.2 歌词行视觉状态 (LyricLineView)

| 状态 | scale | blur | opacity | yOffset |
|------|-------|------|---------|---------|
| 当前行 (isCurrent) | 1.0 | 0 | 1.0 | -2 |
| 过去行 (isPast) | 0.97 | 1.0 + distance*0.8 | 0.85 | 0 |
| 未来行 | 0.97 | 1.0 + distance*0.8 | max(0.2, 1.0 - distance*0.15) | 0 |
| 滚动中 (isScrolling) | 0.92 | 0 | 1.0 | 0 |

### 1.3 时间同步精度

```swift
// 歌词切换提前量（减少延迟感）
let scrollAnimationLeadTime: TimeInterval = 0.05  // 50ms

// 触发时间计算
let triggerTime = lyrics[index].startTime - scrollAnimationLeadTime
```

### 1.4 AMLL 参考参数

```typescript
// AMLL lyric-line.ts
const spring = { mass: 2, stiffness: 100, damping: 25 };
scaleAspect: 0.95  // 我们用 0.97

// 强调词条件
emphasisCriteria: { duration >= 1000ms, charCount: 1-7 }
```

### 1.5 手动滚动交互

#### 滚动状态切换
```swift
@State private var isManualScrolling: Bool = false

// 手动滚动时：
// - 暂停自动滚动（不响应 currentLineIndex 变化）
// - 歌词行视觉状态切换为 isScrolling 模式
// - 所有歌词行 blur=0, opacity=1.0, scale=0.92
```

#### 滚动时 Hover 高亮
```swift
// 手动滚动时，歌词行可 hover 显示背景
.background(
    Group {
        if isScrolling && isHovering && line.text != "⋯" {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
                .padding(.horizontal, 8)
        }
    }
)
```

#### 点击跳转
```swift
// 点击歌词行跳转到对应时间点
.onTapGesture {
    musicController.seek(to: line.startTime)
}
```

#### 自动恢复滚动
```swift
// 滚动结束后 2 秒恢复自动滚动
autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
    if !isHovering {
        showControls = false
    }
    isManualScrolling = false
}
```

#### 自动滚动逻辑
```swift
.onChange(of: lyricsService.currentLineIndex) { oldValue, newValue in
    // 只有非手动滚动状态才自动滚动
    if !isManualScrolling, let currentIndex = newValue {
        withAnimation(.interpolatingSpring(...)) {
            proxy.scrollTo(lyricsService.lyrics[currentIndex].id, anchor: .center)
        }
    }
}
```

---

## 二、前奏/间奏动画系统

### 2.1 间奏检测逻辑

```swift
// 间奏定义：两句歌词间隔 >= 5秒
let gap = nextLine.startTime - currentLine.endTime
if gap >= 5.0 && line.text != "⋯" && nextLine.text != "⋯" {
    // 显示 InterludeDotsView
}
```

### 2.2 前奏占位符处理

```swift
// 检测省略号格式
let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・"]

// 在歌词数组最前面插入前奏占位符
let loadingLine = LyricLine(text: "⋯", startTime: 0, endTime: firstRealLyricStartTime)
```

### 2.3 三点动画实现

```swift
// InterludeDotsView / PreludeDotsView 核心参数
fadeOutDuration: 0.7秒
dotsActiveDuration = totalDuration - fadeOutDuration
segmentDuration = dotsActiveDuration / 3.0  // 每点1/3

// 点亮进度 (sin缓动)
let progress = CGFloat(sin(rawProgress * .pi / 2))

// 呼吸动画
breathingFrequency: 0.8Hz  // sin(currentTime * .pi * 0.8)
breathingScale: 1.0 ± 0.06  // 只在点亮过程中应用

// 点样式
dotSize: 8pt, spacing: 6pt
baseOpacity: 0.25 → fullOpacity: 1.0
baseScale: 0.85 → fullScale: 1.0
```

---

## 三、歌词获取系统 (LyricsService)

### 3.1 数据源优先级

**中文歌曲**:
1. AMLL-TTML-DB (逐字歌词，最高质量)
2. NetEase 网易云 (YRC 逐字歌词)
3. LRCLIB (行级歌词)
4. lyrics.ovh (纯文本，无时间轴)

**英文歌曲**:
1. AMLL-TTML-DB
2. LRCLIB (英文歌匹配更准)
3. NetEase
4. lyrics.ovh

```swift
let isChinese = containsChineseCharacters(title) || containsChineseCharacters(artist)
```

### 3.2 歌词格式支持

#### LRC 格式 (行级歌词)
```
[mm:ss.xx]歌词文本
[00:15.50]这是第一句歌词
```

#### TTML 格式 (AMLL，支持逐字)
```xml
<p begin="00:01.737" end="00:06.722">
  <span begin="00:01.737" end="00:02.175">沈</span>
  <span begin="00:02.175" end="00:02.592">む</span>
</p>
```

#### YRC 格式 (NetEase 逐字歌词)
```
[行开始ms,行持续ms](字开始ms,字持续ms,0)字(字开始ms,字持续ms,0)字
[600,5040](600,470,0)有(1070,470,0)些(1540,510,0)话
```

### 3.3 数据模型

```swift
public struct LyricWord: Identifiable, Equatable {
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    func progress(at time: TimeInterval) -> Double  // 0.0 - 1.0
}

public struct LyricLine: Identifiable, Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let words: [LyricWord]  // 逐字时间信息
    var hasSyllableSync: Bool { !words.isEmpty }
}
```

### 3.4 元信息过滤

```swift
// 跳过元信息行
let metadataPatterns = [
    "作词", "作曲", "编曲", "制作", "混音", "录音",
    "母带", "监制", "出品", "发行", "词：", "曲："
]

// firstRealLyricIndex 记录第一句真正歌词的位置
```

### 3.5 缓存系统

```swift
// NSCache 内存缓存
lyricsCache.countLimit = 50  // 最多50首
lyricsCache.totalCostLimit = 10 * 1024 * 1024  // 10MB

// 缓存有效期
isExpired: Date().timeIntervalSince(timestamp) > 86400  // 24小时
```

### 3.6 AMLL 镜像源

```swift
let amllMirrorBaseURLs = [
    ("jsDelivr", "https://cdn.jsdelivr.net/gh/Steve-xmh/amll-ttml-db@main/"),
    ("GitHub", "https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/"),
    ("ghproxy", "https://ghproxy.com/https://raw.githubusercontent.com/Steve-xmh/amll-ttml-db/main/")
]

// 支持的平台
let amllPlatforms = ["ncm-lyrics", "am-lyrics", "qq-lyrics", "spotify-lyrics"]
```

### 3.7 NetEase 匹配逻辑

```swift
// 繁简转换
CFStringTransform(mutableString, nil, "Traditional-Simplified", false)

// 匹配优先级（以时长为基准）
// 1. 时长差 < 1秒 且 (标题匹配 或 艺术家匹配)
// 2. 时长差 < 2秒 且 艺术家匹配
// 3. 时长差 < 1秒 (纯时长匹配)
// 4. 时长差 < 3秒 且 标题匹配

// 跳过时长差 > 5秒的结果
```

### 3.8 Apple Music Catalog ID 查询

```swift
// 通过 iTunes Search API 获取 trackId
// URL: https://itunes.apple.com/search?term=\(searchTerm)&entity=song&limit=10
// 用于直接查询 AMLL am-lyrics 目录
```

---

## 四、滚动检测系统 (ScrollDetector)

### 4.1 实现方式

```swift
// 使用 NSEvent.addLocalMonitorForEvents 全局监听
NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
    handleScrollEvent(event)
    return event
}
```

### 4.2 速度计算

```swift
// 计算滚动速度 (delta per second)
let timeDelta = currentTime - lastScrollTime
let velocity = deltaY / CGFloat(timeDelta)

// 节流回调 (40fps)
let callbackThrottleInterval: CFTimeInterval = 0.025

// 滚动结束检测延迟
let scrollEndDelay: TimeInterval = 0.2  // 200ms
```

### 4.3 控件显示状态机

```swift
@State private var isManualScrolling: Bool = false
@State private var scrollLocked: Bool = false  // 快速滚动锁定
@State private var hasTriggeredSlowScroll: Bool = false
@State private var lastVelocity: CGFloat = 0

let velocityThreshold: CGFloat = 800

// 规则：
// 快速滚动 (>= 800): 隐藏控件，锁定本轮
// 慢速下滑 (< 800, deltaY > 0): 显示控件（仅本轮一次）
// 滚动结束: 2秒后隐藏（若鼠标不在窗口内）
```

### 4.4 鼠标 Hover 交互

```swift
.onHover { hovering in
    isHovering = hovering
    if !hovering {
        // 鼠标离开 → 总是隐藏控件
        showControls = false
    } else if !isManualScrolling {
        // 非滚动时鼠标进入 → 显示控件
        showControls = true
    }
}
```

---

## 五、底部控件系统

### 5.1 架构设计

```
┌─────────────────────────────────────┐
│           LyricsView                │
│  ┌───────────────────────────────┐  │
│  │       ScrollView (歌词)        │  │
│  │  ┌─────────────────────────┐  │  │
│  │  │    LyricLineView...     │  │  │  ← 歌词显示逻辑（独立）
│  │  └─────────────────────────┘  │  │
│  └───────────────────────────────┘  │
│  ┌───────────────────────────────┐  │
│  │   controlBar (overlay)        │  │  ← 控件显示逻辑（独立）
│  │  ┌─────────────────────────┐  │  │
│  │  │  VisualEffectView 模糊   │  │  │
│  │  │  SharedBottomControls   │  │  │  ← 共享控件组件
│  │  └─────────────────────────┘  │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

**关键点**:
- `SharedBottomControls` 是独立组件，LyricsView 和 PlaylistView 共用
- `controlBar` 只负责模糊背景 + 包装 SharedBottomControls
- 歌词显示逻辑 (`LyricLineView`) 和控件逻辑完全解耦
- 未来重构歌词样式（如 AMLL 逐字高亮）**不影响控件系统**

### 5.2 SharedBottomControls 组件

```swift
// 位置: SharedControls.swift
struct SharedBottomControls: View {
    @Binding var currentPage: PlayerPage
    @Binding var isHovering: Bool
    @Binding var showControls: Bool
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?
    var onControlsHoverChanged: ((Bool) -> Void)?  // 可选回调

    // 包含:
    // - 进度条 (progressBar)
    // - 时间显示
    // - 音质标签
    // - 播放控制按钮
    // - 页面导航按钮
}
```

### 5.3 VisualEffectView 模糊实现

```swift
VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
    .frame(height: 120)
    .mask(
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.3), location: 0.15),
                .init(color: .black.opacity(0.6), location: 0.3),
                .init(color: .black, location: 0.5),
                .init(color: .black, location: 1.0)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    )
```

### 5.4 设计决策

- **材质**: `.hudWindow` - 系统级半透明模糊，不割裂
- **高度**: 120pt - 覆盖进度条区域
- **渐变遮罩**: 从 0.5 location 开始完全不透明
- **避免**: `.ultraThinMaterial`（割裂感）、颜色叠加

---

## 六、性能优化

### 6.1 已实现

```swift
// 绘制组优化 - 60fps 动画
.drawingGroup()

// 防止竞态条件
currentFetchTask?.cancel()  // 取消旧请求
guard self.currentSongID == expectedSongID else { return }  // 验证 songID
```

### 6.2 推荐优化

- 歌词行使用 `Equatable` 避免不必要重绘
- 长歌词考虑 `LazyVStack` 虚拟列表
- 逐字高亮使用 `CADisplayLink` 驱动

---

## 七、UI 组件规格

### 7.1 歌词文字

```swift
.font(.system(size: 24, weight: .semibold))
// 不使用 .rounded，让中文使用苹方字体
```

### 7.2 布局间距

```swift
lyricsSpacing: 20pt      // 歌词行间距
horizontalPadding: 32pt  // 歌词水平内边距
topSpacer: 160pt         // 顶部留白
bottomSpacer: 100pt      // 底部留白
```

### 7.3 控件按钮尺寸

```swift
// 播放控制
previousNext: 17pt, playPause: 21pt
buttonFrame: 30x30pt

// 导航按钮
navigationIcon: 15pt
buttonFrame: 26x26pt
```

---

## 八、待完善功能 (参考 AMLL)

### 8.1 逐字高亮动画

已支持数据模型 `LyricWord`，当前实现：

```swift
// 使用 LinearGradient foregroundStyle
Text(word.word)
    .foregroundStyle(
        LinearGradient(
            stops: [
                .init(color: .white, location: max(0, progress - 0.001)),
                .init(color: .white.opacity(0.35), location: progress)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    )
```

### 8.2 强调词效果

```typescript
// AMLL 条件
if (duration >= 1000ms && charCount 1-7) {
    // 放大 1.05-1.1x + 上移 -0.05em
}
```

### 8.3 背景律动

```typescript
// 随节拍动效
backgroundPulse: {
    beatDetection: true,
    scaleRange: [1.0, 1.02],
    blurRange: [0, 5]
}
```

---

## 九、文件结构

```
Sources/MusicMiniPlayerCore/
├── UI/
│   ├── LyricsView.swift          # 歌词页面主视图
│   │   ├── LyricLineView         # 单行歌词组件
│   │   ├── SyllableSyncTextView  # 逐字高亮容器
│   │   ├── SyllableWordView      # 单个字高亮
│   │   ├── InterludeDotsView     # 间奏三点动画
│   │   ├── PreludeDotsView       # 前奏三点动画
│   │   └── controlBar            # 底部控件
│   ├── PlaylistView.swift        # 歌单页面
│   ├── MiniPlayerView.swift      # 主播放器视图
│   ├── SharedControls.swift      # 共享底部控件
│   ├── ScrollDetector.swift      # 滚动检测扩展
│   └── VisualEffectView.swift    # NSVisualEffectView 包装
├── Services/
│   ├── LyricsService.swift       # 歌词获取/解析/缓存
│   │   ├── fetchFromAMLLTTMLDB   # AMLL 歌词源
│   │   ├── fetchFromNetEase      # 网易云歌词源
│   │   ├── fetchFromLRCLIB       # LRCLIB 歌词源
│   │   ├── parseTTML             # TTML 解析
│   │   ├── parseYRC              # YRC 逐字歌词解析
│   │   └── parseLRC              # LRC 解析
│   └── MusicController.swift     # Apple Music 控制
└── Models/
    └── (LyricLine/LyricWord 在 LyricsService.swift 中定义)
```

---

## 十、编译与运行

```bash
# 编译 Release 版本
swift build -c release

# 复制到 app bundle
cp .build/release/MusicMiniPlayer nanoPod.app/Contents/MacOS/nanoPod

# 运行
open nanoPod.app

# 查看调试日志
cat /tmp/nanopod_lyrics_debug.log
```

---

## 十一、调试技巧

### 11.1 歌词调试日志

```swift
// 输出位置
/tmp/nanopod_lyrics_debug.log

// 包含信息
- 歌词获取流程
- 数据源选择
- 时间轴切换
```

### 11.2 滚动调试

```swift
// LyricsView 内置调试窗口
@State private var showDebugWindow: Bool = false
// 显示滚动速度、状态变化等信息
```

---

## 十二、问题排查清单

如果逐字高亮看起来不对：

1. 检查 `words` 数组是否填充：`line.hasSyllableSync` 应为 true
2. 检查字时间：每个 `LyricWord` 应有有效的 `startTime` 和 `endTime`
3. 检查进度计算：`word.progress(at: currentTime)` 应返回 0.0-1.0
4. 检查 Text 的 font 设置是否一致
5. 检查是否有 scale/offset 动画冲突
