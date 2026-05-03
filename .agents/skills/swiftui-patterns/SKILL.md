---
name: swiftui-patterns
description: |
  SwiftUI macOS 专用模式。仅限 macOS 特有 API：NSViewRepresentable 包装
  AppKit 视图、NSStatusItem 菜单栏、窗口管理（无标题栏/浮窗/位置记忆）、
  右键菜单、Coordinator 模式、条件编译。不涉及通用 SwiftUI 架构或 iOS 内容。
allowed-tools: Read, Grep
---

# SwiftUI macOS 常用模式

## 状态管理

### @State vs @StateObject vs @ObservedObject
```swift
// @State - 值类型，视图私有
@State private var isExpanded = false

// @StateObject - 引用类型，视图创建并拥有
@StateObject private var viewModel = ViewModel()

// @ObservedObject - 引用类型，外部传入
@ObservedObject var viewModel: ViewModel
```

### 状态提升
```swift
// 父视图持有状态，通过 Binding 传递
struct ParentView: View {
    @State private var value: Int = 0

    var body: some View {
        ChildView(value: $value)
    }
}

struct ChildView: View {
    @Binding var value: Int
}
```

## 布局模式

### GeometryReader
```swift
GeometryReader { geometry in
    // geometry.size - 可用空间
    // geometry.safeAreaInsets - 安全区域
    // geometry.frame(in: .global) - 全局坐标
}
```

### 自适应布局
```swift
// 根据窗口大小调整
GeometryReader { geometry in
    if geometry.size.width > 600 {
        HStack { ... }  // 宽屏：水平布局
    } else {
        VStack { ... }  // 窄屏：垂直布局
    }
}
```

## 手势处理

### 组合手势
```swift
let dragAndTap = DragGesture()
    .simultaneously(with: TapGesture())
```

### 优先级
```swift
// 内层优先
innerView.gesture(tapGesture)
outerView.gesture(dragGesture)

// 外层优先
outerView.highPriorityGesture(dragGesture)
```

### Hover 效果
```swift
@State private var isHovering = false

view
    .onHover { hovering in
        withAnimation { isHovering = hovering }
    }
    .scaleEffect(isHovering ? 1.1 : 1.0)
```

## 窗口管理

### 无标题栏窗口
```swift
// AppDelegate 或 App 入口
window.styleMask = [.borderless, .fullSizeContentView]
window.isMovableByWindowBackground = true
window.backgroundColor = .clear
window.level = .floating
```

### 窗口位置记忆
```swift
// 保存
let frame = window.frame
UserDefaults.standard.set(NSStringFromRect(frame), forKey: "windowFrame")

// 恢复
if let frameString = UserDefaults.standard.string(forKey: "windowFrame"),
   let frame = NSRectFromString(frameString) as NSRect? {
    window.setFrame(frame, display: true)
}
```

## 菜单栏应用

### NSStatusItem
```swift
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.image = NSImage(named: "MenuBarIcon")
statusItem.menu = buildMenu()
```

### 右键菜单
```swift
view.contextMenu {
    Button("选项 1") { ... }
    Divider()
    Button("选项 2") { ... }
}
```

## NSViewRepresentable

### 包装 AppKit 视图
```swift
struct AppKitView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 更新视图
    }
}
```

### Coordinator 模式
```swift
struct AppKitView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, SomeDelegate {
        var parent: AppKitView
        init(_ parent: AppKitView) { self.parent = parent }
    }
}
```

## 条件编译

### 平台检查
```swift
#if os(macOS)
// macOS 专用代码
#elseif os(iOS)
// iOS 专用代码
#endif
```

### 版本检查
```swift
if #available(macOS 13.0, *) {
    // macOS 13+ 专用
} else {
    // 兼容旧版本
}
```
