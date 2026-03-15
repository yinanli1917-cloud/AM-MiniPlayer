# 禁止使用的设计模式

## PlaylistView 严禁的结构

### 1. 严禁：割裂式渐变模糊 Header
```swift
// ❌ 绝对禁止
VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
    .mask(LinearGradient(...))
```
这种渐变模糊 header 会造成视觉割裂，与背景不融合。

### 2. 严禁：单一连续滚动列表（非"日"字结构）
```swift
// ❌ 绝对禁止
ScrollView {
    LazyVStack(pinnedViews: [.sectionHeaders]) {
        Section { History列表 } header: { "History" }
        NowPlayingCard()
        Section { UpNext列表 } header: { "Up Next" }
    }
}
```
这不是"日"字内嵌结构，而是一个普通的长列表。Section 的 pinnedViews 会给 header 添加系统背景色。

### 3. 严禁：页面顺序/offset 搞反
```swift
// ❌ 绝对禁止 - 把 Page 0 放上面，Page 1 放下面，然后用 offset 切换
VStack {
    Page0_History      // 在上面
    Page1_NowPlaying   // 在下面
}
.offset(y: pageIndex == 0 ? 0 : -height)  // 默认显示 Page 1 时会把整个往上移
```
正确做法：Page 1（默认页）放上面，Page 0 放下面，然后切换到 Page 0 时向上 offset。

### 4. 严禁：嵌套 ScrollView（外层包内层）
```swift
// ❌ 绝对禁止
ScrollView {
    VStack {
        ScrollView { /* History 歌单 */ }  // 内嵌 ScrollView
        NowPlayingCard()
        ScrollView { /* Up Next 歌单 */ }  // 内嵌 ScrollView
    }
}
```
外层 ScrollView 包裹内层 ScrollView 会导致滚动冲突。

### 5. 严禁：静态 ZStack 分层布局
```swift
// ❌ 绝对禁止
ZStack {
    Layer1: Background
    Layer2: History区域（固定位置）
    Layer3: NowPlaying（固定位置）
    Layer4: UpNext区域（固定位置）
}
```
这种静态分层无法滚动，不符合"日"字结构的交互需求。

### 6. 严禁：Section 内重复 NowPlayingCard
```swift
// ❌ 绝对禁止
Section1 {
    Header
    歌单
    NowPlayingCard()  // 重复1
}
Section2 {
    NowPlayingCard()  // 重复2
    Header
    歌单
}
```
NowPlayingCard 应该只有一个实例。

### 8. 严禁：Sticky Header 使用 VisualEffectView 背景
```swift
// ❌ 绝对禁止
.overlay(alignment: .top) {
    sectionHeader(title: "History")
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
        )
}
```
Sticky header 必须是纯文字+透明背景，不能有任何模糊效果。

### 9. 严禁：外层 ScrollView 嵌套内层 ScrollView（滚动冲突）
```swift
// ❌ 绝对禁止
ScrollView {  // 外层
    VStack {
        ScrollView { /* 内嵌列表 */ }  // 内层
    }
}
```
这会导致滚动事件冲突，内层 ScrollView 无法正常工作。

### 7. 严禁：两页容器没有限制高度
```swift
// ❌ 绝对禁止 - 内层 VStack 没有被限制高度，会撑开容器
VStack {
    VStack {  // 总高度 2*availableHeight，但没有限制
        Page1.frame(height: availableHeight)
        Page0.frame(height: availableHeight)
    }
    .offset(y: ...)
    Spacer()
}
.frame(height: totalHeight)
.clipped()  // clipped 只是视觉裁剪，不改变布局
```
正确做法：用 ZStack + .frame(height: availableHeight) 限制分页容器只显示一页的高度。

### 11. 严禁：VStack + offset 分页时 ZStack 对齐方式搞错
```swift
// ❌ 绝对禁止 - ZStack(alignment: .top) 会导致分页容器从顶部开始
// 当 offset=-availableHeight 时，Page 1 内容会被截断
ZStack(alignment: .top) {
    Background
    VStack {
        Page0.frame(height: availableHeight)
        Page1.frame(height: availableHeight)
    }
    .offset(y: pageIndex == 0 ? 0 : -availableHeight)
    .frame(height: availableHeight)
    .clipped()
}
```
**问题**：ZStack alignment: .top 时，分页 VStack 从顶部开始。offset=-availableHeight 会把 VStack 往上移，但 .clipped() 只能看到顶部 availableHeight 的内容。此时看到的是 Page 1 的**底部**而不是顶部！

**正确理解**：
- VStack 总高度 = 2 * availableHeight
- Page 0 占据 y: 0 到 availableHeight
- Page 1 占据 y: availableHeight 到 2*availableHeight
- offset=-availableHeight 后，Page 1 移动到 y: 0 到 availableHeight
- 但如果 ZStack 是 .top 对齐，clipped 窗口也在 y: 0 到 availableHeight
- 所以显示的是移动后 Page 1 的正确位置 ✓

**真正的问题**：如果还是显示错误，检查分页容器的 .frame(height:) 是否正确应用，以及 clipped() 是否生效。

### 12. 严禁：移除 matchedGeometryEffect
```swift
// ❌ 绝对禁止移除 matchedGeometryEffect
// 这是跨页面动画（如专辑封面）必需的，不能因为分页问题而删除
```

### 13. 严禁：使用 controlsReservedHeight 预留空白
```swift
// ❌ 绝对禁止 - 预留高度会导致页面出现空白区域
let controlsReservedHeight: CGFloat = 100
let availableHeight = geometry.size.height - controlsReservedHeight  // 导致空白
```
**问题**：底部控件是独立层叠加在内容上的，不需要预留高度。预留高度会导致页面底部出现空白。

### 14. 严禁：ZStack + opacity 切换（生硬无过渡）
```swift
// ❌ 绝对禁止 - opacity 切换没有滑动效果，非常生硬
ZStack {
    Page0.opacity(pageIndex == 0 ? 1 : 0)
    Page1.opacity(pageIndex == 1 ? 1 : 0)
}
```
**问题**：opacity 切换是淡入淡出，没有滑动过渡效果，用户体验差。应该用 offset 滑动切换。

### 15. 严禁：VStack + offset + clipped 实现分页（SwiftUI 根本不支持）
```swift
// ❌ 绝对禁止 - SwiftUI 的 clipped() 只是视觉裁剪，不改变布局
// 两个页面的内容会混在一起显示
VStack(spacing: 0) {
    Page0.frame(height: availableHeight)
    Page1.frame(height: availableHeight)
}
.offset(y: pageIndex == 0 ? 0 : -availableHeight)
.frame(height: availableHeight)
.clipped()  // 这个不起作用！
```
**问题**：SwiftUI 的 clipped() 只是视觉裁剪，不会真正隐藏内容。VStack + offset 方案在 SwiftUI 中**根本无法实现分页**，两个页面的内容会混在一起。

**已经尝试过的失败方案**：
1. VStack + offset（无 clipped）- 两页都可见
2. VStack + offset + clipped - clipped 不起作用，内容混合
3. ZStack + opacity - 生硬，matchedGeometryEffect 残留
4. 条件渲染 - ScrollView 被销毁重建

**必须使用其他方案**：如 NSViewRepresentable 包装 NSPageController，或者使用 TabView。

### 16. 严禁：分页容器覆盖底部控件的交互区域
```swift
// ❌ 绝对禁止 - 分页容器占满整个高度会遮挡底部控件
VStack(spacing: 0) {
    Page0.frame(height: geometry.size.height)  // 占满整个高度
    Page1.frame(height: geometry.size.height)
}
```
**问题**：底部控件虽然是叠加层，但如果分页容器占满整个高度且在底部控件之上（ZStack 顺序），会遮挡控件的点击。分页容器应该有正确的 allowsHitTesting 或者在 ZStack 中的正确顺序。

### 10. 严禁：用条件渲染切换页面内容
```swift
// ❌ 绝对禁止
if currentSection == 1 {
    ScrollView { /* Up Next */ }
} else {
    ScrollView { /* History */ }
```
条件渲染会导致 ScrollView 被销毁重建，滚动位置丢失，不是真正的页面切换。

---

## 正确的"日"字结构

### 完整结构图
```
┌─────────────────────────┐  ← 外框顶部 = History Header（日字外框）
│  History Header         │  ← 纯文字，透明背景
│  ┌───────────────────┐  │
│  │   History 歌单    │  │  ← 上面的"口"（固定高度，内嵌独立滚动）
│  └───────────────────┘  │
├─────────────────────────┤  ← 中间"一横" = Now Playing Card（默认锚点）
│      Now Playing Card   │
│      [Shuffle] [Repeat] │
├─────────────────────────┤
│  Up Next Header         │  ← 纯文字，透明背景
│  ┌───────────────────┐  │
│  │   Up Next 歌单    │  │  ← 下面的"口"（固定高度，内嵌独立滚动）
│  └───────────────────┘  │
└─────────────────────────┘  ← 外框底部（屏幕边缘）
```

### 层级关系
1. **Layer 1: LiquidBackgroundView** - 唯一的统一背景
2. **Layer 2: 日字框架** - History Header + History歌单 + Now Playing Card + Up Next Header + Up Next歌单
3. **Layer 3: SharedBottomControls** - 底部控件，独立层，不影响日字布局

### 交互逻辑（触控板方向）
1. **默认锚定**：Now Playing Card 在视口顶部
2. **触控板往下滑**（deltaY > 0，内容往上移）→ 看到 History（在 Now Playing 上面）
3. **触控板往上滑**（deltaY < 0，内容往下移）→ 看到 Up Next（在 Now Playing 下面）
4. **History 和 Up Next 歌单**：各自是固定高度的内嵌 ScrollView，独立滚动
5. **Header 样式**：纯文字，透明背景，无模糊效果

### 关键实现
- **不用外层 ScrollView**（避免嵌套滚动冲突）
- 用 VStack + offset 实现页面切换
- History 歌单和 Up Next 歌单是**固定高度的内嵌 ScrollView**，各自独立滚动
- 用 onScrollWheel 检测滚动方向来切换页面（当内嵌列表滚动到边界时）
- Header 是日字外框的一部分，纯文字透明背景

### 页面切换逻辑
```swift
// ✅ 正确做法：三页结构
VStack(spacing: 0) {
    // Page 0: History（在最上面）
    VStack { History Header + History ScrollView }
        .frame(height: availableHeight)

    // Page 1: Now Playing + Up Next（默认页，在中间）
    VStack { Now Playing Card + Up Next Header + Up Next ScrollView }
        .frame(height: availableHeight)
}
.offset(y: currentPage == 0 ? 0 : -availableHeight)  // 默认显示 Page 1
```

注意：VStack 中 Page 0 在上，Page 1 在下。默认 offset=-availableHeight 显示 Page 1。

### 17. 严禁：NSHostingView + alphaValue 分页（matchedGeometryEffect 会飘）
```swift
// ❌ 绝对禁止 - 两个 NSHostingView 同时存在会导致 matchedGeometryEffect 混乱
let page0Host = NSHostingView(rootView: page0Content())
let page1Host = NSHostingView(rootView: page1Content())
// 用 alphaValue 切换可见性
page0Host.alphaValue = pageIndex == 0 ? 1.0 : 0.0
page1Host.alphaValue = pageIndex == 1 ? 1.0 : 0.0
```
**问题**：
1. 两个 NSHostingView 各有独立的 SwiftUI 渲染树，matchedGeometryEffect 无法跨越
2. 封面图片会"飘"到错误的页面
3. alphaValue 切换依然是生硬的淡入淡出

### 18. 严禁：Page 1 中 Up Next 没有吸顶功能
```swift
// ❌ 绝对禁止 - Up Next header 不吸顶，滚动时会被滚走
VStack(spacing: 0) {
    nowPlayingCard(...)
    sectionHeader(title: "Up Next")  // 这个会被滚走！
    ScrollView { ... }
}
```
**问题**：Up Next header 必须在列表滚动时吸顶（固定在 Now Playing Card 下方），只有 header 吸顶后才能继续滚动列表内容。

### 正确的 Page 1 结构
```swift
// ✅ 正确做法：Up Next header 吸顶
ZStack(alignment: .top) {
    ScrollView {
        VStack(spacing: 0) {
            // 顶部垫片（为 Now Playing Card 留空）
            Color.clear.frame(height: nowPlayingCardHeight)
            // 歌单列表（每行带 .visualEffect 实现滚动模糊）
            ForEach(tracks) { track in
                SongRow(track)
                    .modifier(ScrollFadeEffect(headerHeight: stickyHeaderY))
            }
        }
    }
    .coordinateSpace(name: "scroll")

    // Now Playing Card（固定在顶部）
    VStack(spacing: 0) {
        nowPlayingCard(...)
        sectionHeader(title: "Up Next")  // 吸顶 header
    }
}
```

### 19. 严禁：没有实现 Gemini 的 Per-View Progressive Blur
```swift
// ❌ 绝对禁止 - 没有让歌单行自己模糊
ForEach(tracks) { track in
    SongRow(track)  // 没有 .visualEffect modifier
}
```
**问题**：歌单行滚动到 header 区域时应该自己变模糊+淡出，而不是用遮罩层。

**正确做法（Gemini 方案）**：
```swift
struct ScrollFadeEffect: ViewModifier {
    let headerHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .visualEffect { content, geometryProxy in
                let frame = geometryProxy.frame(in: .named("scroll"))
                let minY = frame.minY
                let progress = max(0, min(1, 1 - (minY / headerHeight)))

                return content
                    .blur(radius: progress * 10)
                    .opacity(1 - (progress * 0.5))
            }
    }
}
```
这样 header 区域完全透明，背景完美透传，无色差。

### 20. 严禁：没有正确 anchor 到 Now Playing
```swift
// ❌ 绝对禁止 - scrollTo 不够，需要确保真正锚定
scrollProxy.scrollTo("nowPlayingAnchor", anchor: .top)
// 这只是滚动过去，但没有 snap 效果
```
**问题**：需要用 `scrollTargetBehavior(.viewAligned)` 实现 snap scroll，确保默认稳定锚定在 Now Playing。

### 21. 严禁：没有 Snap Scroll
```swift
// ❌ 绝对禁止 - 普通 ScrollView 没有 snap 效果
ScrollView {
    LazyVStack { ... }
}
```
**正确做法**：
```swift
ScrollView {
    LazyVStack { ... }
        .scrollTargetLayout()
}
.scrollTargetBehavior(.viewAligned)
```

### 22. 严禁：History 和 Up Next 没有 Sticky Header
```swift
// ❌ 绝对禁止 - header 跟着内容滚动，不吸顶
LazyVStack {
    sectionHeader("History")  // 会被滚走
    ForEach(tracks) { ... }
}
```
**正确做法**：用 `LazyVStack(pinnedViews: [.sectionHeaders])` 或者用 ZStack overlay 实现吸顶。

### 23. 严禁：歌单行没有在 header 下模糊
```swift
// ❌ 绝对禁止 - modifier 没有生效或 coordinateSpace 名字不对
ForEach(tracks) { track in
    SongRow(track)
        .modifier(ScrollFadeEffect(headerHeight: height))
}
// 但是 coordinateSpace 没有设置，或者 headerHeight 计算错误
```
**问题**：
1. `.coordinateSpace(name: "scroll")` 必须设置在 ScrollView 内部的内容上
2. `headerHeight` 必须是正确的吸顶区域高度
3. `.visualEffect` 必须能正确获取 frame

---

## PlaylistView 正确需求总结

### 结构
1. **单页 ScrollView** - History + Now Playing + Up Next 在同一个滚动视图
2. **默认锚定到 Now Playing** - 启动时 snap 到 Now Playing Section
3. **History 在上方** - 触控板下滑才能看到
4. **Up Next 在下方** - Now Playing 下面

### 交互
1. **Snap Scroll** - 用 `scrollTargetBehavior(.viewAligned)` 实现
2. **Sticky Header** - History 和 Up Next 的 header 要吸顶
3. **Header 完全透明** - 不用材质/遮罩，背景完美透传

### Gemini 模糊方案
1. 歌单行滚动到 header 区域时**自己模糊+淡出**
2. Header 区域物理上是透明的
3. 用 `.visualEffect` + `.coordinateSpace` 实现
