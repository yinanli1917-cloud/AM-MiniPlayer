import SwiftUI
import AppKit

// MARK: - Scroll Event Monitor (Works with any ScrollView)
// 🔑 重新设计：使用视图层级内的事件捕获，避免全局监听导致的抖动

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
                    onScrollOffsetChanged: nil
                )
            )
    }
}

// MARK: - Scroll Event Monitor with Velocity (for Playlist acceleration detection)

struct ScrollEventMonitorWithVelocity: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void
    let onScrollWithVelocity: (CGFloat, CGFloat) -> Void  // (deltaY, velocity) - positive = scroll down (content up)
    let onScrollOffsetChanged: ((CGFloat) -> Void)?
    var isEnabled: Bool = true  // 🔑 启用/禁用开关

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
    var isEnabled: Bool = true  // 🔑 启用/禁用开关

    class Coordinator {
        var isScrolling = false
        var scrollTimer: Timer?
        var lastScrollTime: CFTimeInterval = 0
        var accumulatedDeltaY: CGFloat = 0

        // 🔑 防抖：记录上次回调时间，避免频繁触发
        var lastCallbackTime: CFTimeInterval = 0
        let callbackThrottleInterval: CFTimeInterval = 0.016  // ~60fps
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class EventMonitorView: NSView {
        var onScrollStarted: (() -> Void)?
        var onScrollEnded: (() -> Void)?
        var onScrollWithVelocity: ((CGFloat, CGFloat) -> Void)?
        var onScrollOffsetChanged: ((CGFloat) -> Void)?
        weak var coordinator: Coordinator?
        var isEnabled: Bool = true  // 🔑 启用/禁用开关

        private let scrollEndDelay: TimeInterval = 0.15  // 🔑 缩短到150ms，更快响应结束

        override var acceptsFirstResponder: Bool { true }

        // 🔑 关键：重写scrollWheel方法，在视图层级内捕获事件
        override func scrollWheel(with event: NSEvent) {
            super.scrollWheel(with: event)
            // 🔑 只有启用时才处理滚动事件
            if isEnabled {
                handleScrollEvent(event)
            }
        }

        private func handleScrollEvent(_ event: NSEvent) {
            guard let coordinator = coordinator else { return }
            guard isEnabled else { return }  // 🔑 二次检查

            let currentTime = CACurrentMediaTime()
            let deltaY = event.scrollingDeltaY

            // 🔑 检查滚动相位（macOS trackpad支持）
            let phase = event.phase
            let momentumPhase = event.momentumPhase

            // 忽略极小的滚动量（减少噪音）
            if abs(deltaY) < 0.1 && phase == [] && momentumPhase == [] {
                return
            }

            // 计算速度 (delta per second)
            var velocity: CGFloat = 0
            if coordinator.lastScrollTime > 0 {
                let timeDelta = currentTime - coordinator.lastScrollTime
                if timeDelta > 0 && timeDelta < 0.3 {
                    velocity = deltaY / CGFloat(timeDelta)
                }
            }

            coordinator.lastScrollTime = currentTime
            coordinator.accumulatedDeltaY += deltaY

            // 🔑 检测滚动开始
            if !coordinator.isScrolling {
                coordinator.isScrolling = true
                DispatchQueue.main.async { [weak self] in
                    self?.onScrollStarted?()
                }
            }

            // 🔑 节流回调，避免每帧都触发导致抖动
            let shouldCallback = (currentTime - coordinator.lastCallbackTime) >= coordinator.callbackThrottleInterval

            if shouldCallback {
                coordinator.lastCallbackTime = currentTime

                // 回调速度信息
                if let callback = onScrollWithVelocity {
                    DispatchQueue.main.async {
                        callback(deltaY, velocity)
                    }
                }

                // 回调滚动偏移量
                if let offsetCallback = onScrollOffsetChanged {
                    let offset = coordinator.accumulatedDeltaY
                    DispatchQueue.main.async {
                        offsetCallback(offset)
                    }
                }
            }

            // 🔑 使用相位检测结束，或者fallback到定时器
            if phase == .ended || momentumPhase == .ended {
                // 相位结束，延迟一小段时间后触发结束
                coordinator.scrollTimer?.invalidate()
                coordinator.scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                    self?.handleScrollEnd()
                }
            } else {
                // 没有相位信息，使用定时器检测结束
                coordinator.scrollTimer?.invalidate()
                coordinator.scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
                    self?.handleScrollEnd()
                }
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
        return view
    }

    func updateNSView(_ nsView: EventMonitorView, context: Context) {
        nsView.onScrollStarted = onScrollStarted
        nsView.onScrollEnded = onScrollEnded
        nsView.onScrollWithVelocity = onScrollWithVelocity
        nsView.onScrollOffsetChanged = onScrollOffsetChanged
        nsView.coordinator = context.coordinator
        nsView.isEnabled = isEnabled  // 🔑 更新启用状态
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
}
