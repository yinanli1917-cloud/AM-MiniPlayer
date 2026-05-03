# 过渡动画最佳实践

## matchedGeometryEffect

### 基本用法
```swift
@Namespace var namespace

// 源视图
Image(artwork)
    .matchedGeometryEffect(id: "cover", in: namespace)

// 目标视图
Image(artwork)
    .matchedGeometryEffect(id: "cover", in: namespace)
```

### 注意事项
- 两个视图必须同时存在于视图树中 (用 opacity 隐藏，不要条件渲染)
- id 必须唯一且一致
- 在同一个 Namespace 中
- 动画由 withAnimation 或 .animation 触发

### 常见问题
```swift
// ❌ 条件渲染会破坏动画
if showDetail {
    DetailView().matchedGeometryEffect(id: "cover", in: namespace)
} else {
    ThumbnailView().matchedGeometryEffect(id: "cover", in: namespace)
}

// ✅ 使用 opacity + zIndex
ZStack {
    ThumbnailView()
        .matchedGeometryEffect(id: "cover", in: namespace)
        .opacity(showDetail ? 0 : 1)
    DetailView()
        .matchedGeometryEffect(id: "cover", in: namespace)
        .opacity(showDetail ? 1 : 0)
}
```

## transition modifier

### 内置过渡
```swift
.transition(.opacity)                    // 淡入淡出
.transition(.scale)                      // 缩放
.transition(.slide)                      // 滑入滑出
.transition(.move(edge: .bottom))        // 从边缘移入
.transition(.asymmetric(insertion: .scale, removal: .opacity))
```

### 组合过渡
```swift
.transition(.opacity.combined(with: .scale))
.transition(.opacity.combined(with: .move(edge: .bottom)))
```

### 自定义过渡
```swift
extension AnyTransition {
    static var slideAndFade: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }
}
```

## withAnimation vs .animation

### withAnimation
```swift
// 明确控制哪些状态变化需要动画
withAnimation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5)) {
    showDetail = true
    selectedIndex = newIndex
}
```

### .animation modifier
```swift
// 响应特定值变化自动动画
.animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5), value: selectedIndex)
```

### 选择原则
- **withAnimation**: 用户触发的动作 (点击、拖拽结束)
- **.animation**: 状态变化的响应 (数据更新、计算属性变化)

## 页面切换动画

### 推荐模式
```swift
ZStack {
    PageA()
        .offset(x: currentPage == 0 ? 0 : -UIScreen.main.bounds.width)
        .opacity(currentPage == 0 ? 1 : 0)

    PageB()
        .offset(x: currentPage == 1 ? 0 : UIScreen.main.bounds.width)
        .opacity(currentPage == 1 ? 1 : 0)
}
.animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5), value: currentPage)
```

### 避免模式
- VStack + offset + clipped (不工作)
- 条件渲染 (破坏动画连续性)
- ScrollView + scrollTo (无法精确控制)
