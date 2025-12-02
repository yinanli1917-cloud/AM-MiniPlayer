import SwiftUI
import AppKit

// MARK: - Scroll Event Monitor (Works with any ScrollView)

struct ScrollEventMonitor: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                ScrollEventRepresentable(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded,
                    onScrollWithVelocity: nil
                )
            )
    }
}

// MARK: - Scroll Event Monitor with Velocity (for Playlist acceleration detection)

struct ScrollEventMonitorWithVelocity: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void
    let onScrollWithVelocity: (CGFloat, CGFloat) -> Void  // (deltaY, velocity) - positive = scroll down (content up)

    func body(content: Content) -> some View {
        content
            .background(
                ScrollEventRepresentable(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded,
                    onScrollWithVelocity: onScrollWithVelocity
                )
            )
    }
}

struct ScrollEventRepresentable: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void
    let onScrollWithVelocity: ((CGFloat, CGFloat) -> Void)?

    class EventMonitorView: NSView {
        let onScrollStarted: () -> Void
        let onScrollEnded: () -> Void
        let onScrollWithVelocity: ((CGFloat, CGFloat) -> Void)?

        private var scrollTimer: Timer?
        private var isScrolling = false
        private let scrollEndDelay: TimeInterval = 0.8
        private var eventMonitor: Any?

        // 速度检测
        private var lastScrollTime: CFTimeInterval = 0
        private var lastDeltaY: CGFloat = 0
        private var accumulatedDeltaY: CGFloat = 0

        init(onScrollStarted: @escaping () -> Void, onScrollEnded: @escaping () -> Void, onScrollWithVelocity: ((CGFloat, CGFloat) -> Void)?) {
            self.onScrollStarted = onScrollStarted
            self.onScrollEnded = onScrollEnded
            self.onScrollWithVelocity = onScrollWithVelocity
            super.init(frame: .zero)
            setupEventMonitor()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupEventMonitor() {
            // Monitor scroll wheel events globally within the view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event // Don't consume the event
            }
        }

        private func handleScrollEvent(_ event: NSEvent) {
            let currentTime = CACurrentMediaTime()
            let deltaY = event.scrollingDeltaY

            // 计算速度 (delta per second)
            var velocity: CGFloat = 0
            if lastScrollTime > 0 {
                let timeDelta = currentTime - lastScrollTime
                if timeDelta > 0 && timeDelta < 0.5 {  // 忽略太长的间隔
                    velocity = deltaY / CGFloat(timeDelta)
                }
            }

            lastScrollTime = currentTime
            lastDeltaY = deltaY
            accumulatedDeltaY += deltaY

            if !isScrolling {
                isScrolling = true
                accumulatedDeltaY = deltaY
                DispatchQueue.main.async {
                    self.onScrollStarted()
                }
            }

            // 回调速度信息
            if let callback = onScrollWithVelocity {
                DispatchQueue.main.async {
                    callback(deltaY, velocity)
                }
            }

            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
                self?.handleScrollEnd()
            }
        }

        private func handleScrollEnd() {
            if isScrolling {
                isScrolling = false
                accumulatedDeltaY = 0
                lastScrollTime = 0
                DispatchQueue.main.async {
                    self.onScrollEnded()
                }
            }
            scrollTimer?.invalidate()
            scrollTimer = nil
        }

        deinit {
            scrollTimer?.invalidate()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeNSView(context: Context) -> EventMonitorView {
        EventMonitorView(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded, onScrollWithVelocity: onScrollWithVelocity)
    }

    func updateNSView(_ nsView: EventMonitorView, context: Context) {}
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
        onScrollWithVelocity: @escaping (CGFloat, CGFloat) -> Void
    ) -> some View {
        self.modifier(ScrollEventMonitorWithVelocity(
            onScrollStarted: onScrollStarted,
            onScrollEnded: onScrollEnded,
            onScrollWithVelocity: onScrollWithVelocity
        ))
    }
}
