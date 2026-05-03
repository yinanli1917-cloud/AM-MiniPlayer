---
name: swiftui-silky-animation
description: |
  SwiftUI 丝滑动画参数参考。用于调整动画、Spring 参数、interpolatingSpring、
  过渡效果、matchedGeometryEffect、transition、波浪动画、逐字高亮、
  blur、opacity、scale 等视觉效果。包含 AMLL 参数和 Apple 原生动画最佳实践。
allowed-tools: Read
---

# SwiftUI 丝滑动画

## Spring 参数速查表

| 效果 | mass | stiffness | damping | 用途 |
|------|------|-----------|---------|------|
| 位置动画 (AMLL PosY) | 1 | 100 | 16.5 | 歌词滚动、元素移动 |
| 缩放动画 (AMLL Scale) | 1 | 100 | 16.5 | hover 放大缩小 |
| 模糊/透明度 (AMLL) | 1 | 100 | 20 | 淡入淡出、模糊过渡 |
| 快速响应 | 1 | 400 | 28 | 即时反馈、peek 动画 |
| 弹性感 | 2 | 100 | 25 | 有弹性的移动 |
| 四角吸附 | - | 280 | 22 | 窗口吸附动画 |

## SwiftUI 代码

```swift
// AMLL 风格位置动画
.interpolatingSpring(mass: 1, stiffness: 100, damping: 16.5, initialVelocity: 0)

// AMLL 风格视觉动画 (blur/opacity)
.interpolatingSpring(mass: 1, stiffness: 100, damping: 20, initialVelocity: 0)

// 快速响应
.interpolatingSpring(mass: 1, stiffness: 400, damping: 28, initialVelocity: 0)
```

## 最佳实践

### animation modifier 放容器不放每行
```swift
// ✅ 正确: animation 放在容器上
ZStack { ... }
    .animation(.interpolatingSpring(...), value: currentIndex)

// ❌ 错误: animation 放在每行上（性能差）
ForEach(items) { item in
    ItemView(item)
        .animation(.interpolatingSpring(...), value: currentIndex)
}
```

### withAnimation vs animation modifier
- `withAnimation`: 包裹状态变化，明确触发动画
- `.animation`: 响应 value 变化，自动触发

### matchedGeometryEffect 跨页面
```swift
@Namespace var namespace

// 源
Image(artwork)
    .matchedGeometryEffect(id: "cover", in: namespace)

// 目标
Image(artwork)
    .matchedGeometryEffect(id: "cover", in: namespace)
```

## 详细参考

- [SPRING_PARAMS.md](SPRING_PARAMS.md) - 完整 Spring 参数表
- [TRANSITIONS.md](TRANSITIONS.md) - 过渡动画最佳实践
- [PERFORMANCE.md](PERFORMANCE.md) - 动画性能优化
