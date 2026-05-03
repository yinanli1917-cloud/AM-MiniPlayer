# 动画性能优化

## 核心原则

### 1. animation modifier 放容器，不放每行
```swift
// ✅ 正确: 一次性应用到容器
ZStack {
    ForEach(lyrics) { line in
        LyricLine(line)
    }
}
.animation(.interpolatingSpring(...), value: currentIndex)

// ❌ 错误: 每行都计算动画 (N 倍开销)
ForEach(lyrics) { line in
    LyricLine(line)
        .animation(.interpolatingSpring(...), value: currentIndex)
}
```

### 2. 手动 offset 优于 ScrollView
```swift
// ✅ 高性能: 单个 offset 变换
VStack {
    ForEach(items) { item in
        ItemView(item)
    }
}
.offset(y: -scrollOffset)

// ❌ 性能问题: ScrollView + scrollTo 动画不可控
ScrollViewReader { proxy in
    ScrollView {
        // ...
    }
}
```

### 3. 减少状态更新频率
```swift
// ✅ 节流更新
if abs(newTime - lastUpdateTime) > 0.1 {  // 100ms 阈值
    currentTime = newTime
    lastUpdateTime = newTime
}

// ❌ 每帧都更新
currentTime = newTime  // 可能 60fps
```

## 避免不必要的重绘

### 使用 EquatableView
```swift
struct LyricLine: View, Equatable {
    let text: String
    let isActive: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.isActive == rhs.isActive
    }
}

// 使用
EquatableView(content: LyricLine(text: line.text, isActive: isActive))
```

### 提取不变部分
```swift
// ✅ 静态部分提取
struct StaticBackground: View {
    var body: some View {
        // 不依赖任何 @State
    }
}

struct DynamicContent: View {
    @State var value: Int
    var body: some View {
        // 只有这部分重绘
    }
}
```

## 调试日志对性能的影响

```swift
// ❌ Release 构建中的文件 I/O
func debugLog(_ message: String) {
    let data = message.data(using: .utf8)!
    FileHandle.standardError.write(data)  // 每次调用都是 I/O
}

// ✅ 条件编译
func debugLog(_ message: String) {
    #if DEBUG
    fputs(message + "\n", stderr)
    #endif
}
```

## 图层优化

### drawingGroup
```swift
// 复杂视图扁平化为单个图层
ComplexView()
    .drawingGroup()
```

### 使用场景
- 大量叠加的半透明元素
- 复杂的渐变和模糊效果
- 粒子效果

### 注意
- 会消耗额外显存
- 某些效果 (如 blur) 可能表现不同

## GPU vs CPU 动画

### GPU 友好 (推荐)
- opacity
- scale
- rotation
- offset/position

### CPU 密集 (谨慎使用)
- blur (尤其是大半径)
- 实时阴影
- 路径变形
- 文字布局变化

## 性能检测

### Instruments
1. Time Profiler - 找 CPU 热点
2. Core Animation - 检测离屏渲染
3. Allocations - 检测内存抖动

### 运行时检测
```swift
// 打印帧率
CADisplayLink 回调中计算 FPS
```
