import SwiftUI
import AppKit

// MARK: - Scroll Event Monitor (Works with any ScrollView)
// 🔑 使用全局事件监听 + 防抖节流确保稳定性

struct ScrollEventMonitor: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                ScrollEventRepresentable(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded,
                    onScrollWithVelocity: nil,
                    onScrollOffsetChanged: nil,
                    isEnabled: true
                )
            )
    }
}

// MARK: - Scroll Event Monitor with Velocity (for Playlist/Lyrics acceleration detection)

struct ScrollEventMonitorWithVelocity: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void
    let onScrollWithVelocity: (CGFloat, CGFloat) -> Void  // (deltaY, velocity) - positive = scroll down (content up)
    let onScrollOffsetChanged: ((CGFloat) -> Void)?
    var isEnabled: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                ScrollEventRepresentable(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded,
                    onScrollWithVelocity: onScrollWithVelocity,
                    onScrollOffsetChanged: onScrollOffsetChanged,
                    isEnabled: isEnabled
                )
            )
    }
}

struct ScrollEventRepresentable: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void
    let onScrollWithVelocity: ((CGFloat, CGFloat) -> Void)?
    let onScrollOffsetChanged: ((CGFloat) -> Void)?
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var isScrolling = false
        var scrollTimer: Timer?
        var lastScrollTime: CFTimeInterval = 0
        var accumulatedDeltaY: CGFloat = 0
        var eventMonitor: Any?

        // 防抖
        var lastCallbackTime: CFTimeInterval = 0
        let callbackThrottleInterval: CFTimeInterval = 0.025  // 40fps节流，减少回调频率
    }

    class EventMonitorView: NSView {
        var onScrollStarted: (() -> Void)?
        var onScrollEnded: (() -> Void)?
        var onScrollWithVelocity: ((CGFloat, CGFloat) -> Void)?
        var onScrollOffsetChanged: ((CGFloat) -> Void)?
        weak var coordinator: Coordinator?
        var isEnabled: Bool = true

        private let scrollEndDelay: TimeInterval = 0.2  // 200ms检测滚动结束

        func setupEventMonitor() {
            guard coordinator?.eventMonitor == nil else { return }

            // 🔑 使用全局事件监听器捕获滚动事件
            coordinator?.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event  // 不消费事件
            }
        }

        func removeEventMonitor() {
            if let monitor = coordinator?.eventMonitor {
                NSEvent.removeMonitor(monitor)
                coordinator?.eventMonitor = nil
            }
        }

        private func handleScrollEvent(_ event: NSEvent) {
            guard let coordinator = coordinator else { return }
            guard isEnabled else { return }

            // 检查事件是否发生在当前窗口内
            guard let window = self.window, event.window == window else { return }

            let currentTime = CACurrentMediaTime()
            let deltaY = event.scrollingDeltaY

            // 忽略极小的滚动量
            if abs(deltaY) < 0.5 {
                return
            }

            // 计算速度 (delta per second)
            var velocity: CGFloat = 0
            if coordinator.lastScrollTime > 0 {
                let timeDelta = currentTime - coordinator.lastScrollTime
                if timeDelta > 0 && timeDelta < 0.5 {
                    velocity = deltaY / CGFloat(timeDelta)
                }
            }

            coordinator.lastScrollTime = currentTime
            coordinator.accumulatedDeltaY += deltaY

            // 检测滚动开始
            if !coordinator.isScrolling {
                coordinator.isScrolling = true
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollStarted?()
                }
            }

            // 🔑 节流回调
            let shouldCallback = (currentTime - coordinator.lastCallbackTime) >= coordinator.callbackThrottleInterval

            if shouldCallback {
                coordinator.lastCallbackTime = currentTime

                if let callback = onScrollWithVelocity {
                    DispatchQueue.main.async {
                        callback(deltaY, velocity)
                    }
                }

                if let offsetCallback = onScrollOffsetChanged {
                    let offset = coordinator.accumulatedDeltaY
                    DispatchQueue.main.async {
                        offsetCallback(offset)
                    }
                }
            }

            // 重置结束定时器
            coordinator.scrollTimer?.invalidate()
            coordinator.scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
                self?.handleScrollEnd()
            }
        }

        private func handleScrollEnd() {
            guard let coordinator = coordinator else { return }

            if coordinator.isScrolling {
                coordinator.isScrolling = false
                coordinator.lastScrollTime = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollEnded?()
                }
            }
            coordinator.scrollTimer?.invalidate()
            coordinator.scrollTimer = nil
        }

        deinit {
            removeEventMonitor()
            coordinator?.scrollTimer?.invalidate()
        }
    }

    func makeNSView(context: Context) -> EventMonitorView {
        let view = EventMonitorView()
        view.onScrollStarted = onScrollStarted
        view.onScrollEnded = onScrollEnded
        view.onScrollWithVelocity = onScrollWithVelocity
        view.onScrollOffsetChanged = onScrollOffsetChanged
        view.coordinator = context.coordinator
        view.isEnabled = isEnabled
        view.setupEventMonitor()
        return view
    }

    func updateNSView(_ nsView: EventMonitorView, context: Context) {
        nsView.onScrollStarted = onScrollStarted
        nsView.onScrollEnded = onScrollEnded
        nsView.onScrollWithVelocity = onScrollWithVelocity
        nsView.onScrollOffsetChanged = onScrollOffsetChanged
        nsView.isEnabled = isEnabled

        if isEnabled && context.coordinator.eventMonitor == nil {
            nsView.setupEventMonitor()
        } else if !isEnabled {
            nsView.removeEventMonitor()
        }
    }
}

// MARK: - Easy Integration Extensions

enum ScrollDetectionMethod {
    case eventMonitor        // Most compatible
}

extension View {
    func workingScrollDetection(
        onScrollStarted: @escaping () -> Void,
        onScrollEnded: @escaping () -> Void,
        method: ScrollDetectionMethod = .eventMonitor
    ) -> some View {
        self.modifier(ScrollEventMonitor(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded))
    }

    /// 带速度检测的滚动检测（用于歌单页面加速度控制逻辑）
    func scrollDetectionWithVelocity(
        onScrollStarted: @escaping () -> Void,
        onScrollEnded: @escaping () -> Void,
        onScrollWithVelocity: @escaping (CGFloat, CGFloat) -> Void,
        onScrollOffsetChanged: ((CGFloat) -> Void)? = nil,
        isEnabled: Bool = true  // 🔑 启用/禁用开关
    ) -> some View {
        self.modifier(ScrollEventMonitorWithVelocity(
            onScrollStarted: onScrollStarted,
            onScrollEnded: onScrollEnded,
            onScrollWithVelocity: onScrollWithVelocity,
            onScrollOffsetChanged: onScrollOffsetChanged,
            isEnabled: isEnabled
        ))
    }

    /// 🔑 简单的滚轮事件监听（用于歌词手动滚动）
    func onScrollWheel(_ handler: @escaping (CGFloat) -> Void) -> some View {
        self.background(
            ScrollWheelEventView(onScroll: handler)
        )
    }
}

// MARK: - Simple Scroll Wheel Event View (使用全局事件监听)

struct ScrollWheelEventView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var eventMonitor: Any?
    }

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.coordinator = context.coordinator
        view.setupEventMonitor()
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }

    class ScrollWheelNSView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        weak var coordinator: Coordinator?

        func setupEventMonitor() {
            guard coordinator?.eventMonitor == nil else { return }

            // 🔑 使用全局事件监听器捕获滚动事件
            coordinator?.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event  // 不消费事件
            }
        }

        func removeEventMonitor() {
            if let monitor = coordinator?.eventMonitor {
                NSEvent.removeMonitor(monitor)
                coordinator?.eventMonitor = nil
            }
        }

        private func handleScrollEvent(_ event: NSEvent) {
            // 检查事件是否发生在当前窗口内
            guard let window = self.window, event.window == window else { return }

            let deltaY = event.scrollingDeltaY

            // 忽略极小的滚动量
            if abs(deltaY) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.onScroll?(deltaY)
                }
            }
        }

        deinit {
            removeEventMonitor()
        }
    }
}
