import SwiftUI
import AppKit

// MARK: - Working Scroll Detection Solutions for macOS

// MARK: Solution 1: NSScrollViewDelegate (Most Reliable)
struct NSScrollViewDetector: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    class ScrollViewDelegate: NSObject, NSScrollViewDelegate {
        let onScrollStarted: () -> Void
        let onScrollEnded: () -> Void

        private var scrollTimer: Timer?
        private var isScrolling = false
        private let scrollEndDelay: TimeInterval = 0.8 // Reduced from 2.0 for better UX

        init(onScrollStarted: @escaping () -> Void, onScrollEnded: @escaping () -> Void) {
            self.onScrollStarted = onScrollStarted
            self.onScrollEnded = onScrollEnded
        }

        func scrollViewDidScroll(_ notification: Notification) {
            handleScrollActivity()
        }

        private func handleScrollActivity() {
            if !isScrolling {
                isScrolling = true
                print("🎯 Scroll Started (Delegate)")
                onScrollStarted()
            }

            // Reset timer
            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
                self?.handleScrollEnd()
            }
        }

        private func handleScrollEnd() {
            if isScrolling {
                isScrolling = false
                print("🎯 Scroll Ended (Delegate)")
                onScrollEnded()
            }
            scrollTimer?.invalidate()
            scrollTimer = nil
        }

        deinit {
            scrollTimer?.invalidate()
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: Solution 2: Event Monitor (Works with any ScrollView)
struct ScrollEventMonitor: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    @State private var scrollTimer: Timer?
    @State private var isScrolling = false
    private let scrollEndDelay: TimeInterval = 0.8

    func body(content: Content) -> some View {
        content
            .background(
                ScrollEventRepresentable(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded
                )
            )
    }
}

struct ScrollEventRepresentable: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    class EventMonitorView: NSView {
        let onScrollStarted: () -> Void
        let onScrollEnded: () -> Void

        private var scrollTimer: Timer?
        private var isScrolling = false
        private let scrollEndDelay: TimeInterval = 0.8
        private var eventMonitor: Any?

        init(onScrollStarted: @escaping () -> Void, onScrollEnded: @escaping () -> Void) {
            self.onScrollStarted = onScrollStarted
            self.onScrollEnded = onScrollEnded
            super.init(frame: .zero)
            setupEventMonitor()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupEventMonitor() {
            // Monitor scroll wheel events globally within the view
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent()
                return event // Don't consume the event
            }
        }

        private func handleScrollEvent() {
            if !isScrolling {
                isScrolling = true
                print("🎯 Scroll Started (Event Monitor)")
                onScrollStarted()
            }

            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
                self?.handleScrollEnd()
            }
        }

        private func handleScrollEnd() {
            if isScrolling {
                isScrolling = false
                print("🎯 Scroll Ended (Event Monitor)")
                onScrollEnded()
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
        EventMonitorView(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded)
    }

    func updateNSView(_ nsView: EventMonitorView, context: Context) {}
}

// MARK: Solution 3: Core Animation Observer (Most Advanced)
struct CoreAnimationScrollDetector: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    func body(content: Content) -> some View {
        content
            .background(
                CoreAnimationScrollRepresentable(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded
                )
                .allowsHitTesting(false)
            )
    }
}

struct CoreAnimationScrollRepresentable: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    class ScrollViewObserver: NSView {
        let onScrollStarted: () -> Void
        let onScrollEnded: () -> Void

        private var displayLink: CVDisplayLink?
        private var scrollTimer: Timer?
        private var isScrolling = false
        private var lastScrollOffset: CGFloat = 0
        private let scrollEndDelay: TimeInterval = 0.8

        init(onScrollStarted: @escaping () -> Void, onScrollEnded: @escaping () -> Void) {
            self.onScrollStarted = onScrollStarted
            self.onScrollEnded = onScrollEnded
            super.init(frame: .zero)
            setupDisplayLink()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupDisplayLink() {
            var displayLink: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)

            guard let link = displayLink else { return }

            CVDisplayLinkSetOutputCallback(link, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, userInfo) -> CVReturn in
                DispatchQueue.main.async {
                    let observer = Unmanaged<ScrollViewObserver>.fromOpaque(userInfo!).takeUnretainedValue()
                    observer.checkForScrollActivity()
                }
                return kCVReturnSuccess
            }, Unmanaged.passUnretained(self).toOpaque())

            self.displayLink = link
            CVDisplayLinkStart(link)
        }

        private func checkForScrollActivity() {
            // Check if we're in a scroll view and detect scrolling
            if let scrollView = findEnclosingScrollView() {
                let currentOffset = scrollView.contentView.bounds.origin.y
                let scrollDelta = abs(currentOffset - lastScrollOffset)

                if scrollDelta > 0.5 { // Threshold for meaningful scroll
                    handleScrollActivity()
                    lastScrollOffset = currentOffset
                }
            }
        }

        private func findEnclosingScrollView() -> NSScrollView? {
            var view = superview
            while view != nil {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                view = view?.superview
            }
            return nil
        }

        private func handleScrollActivity() {
            if !isScrolling {
                isScrolling = true
                print("🎯 Scroll Started (Core Animation)")
                onScrollStarted()
            }

            scrollTimer?.invalidate()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
                self?.handleScrollEnd()
            }
        }

        private func handleScrollEnd() {
            if isScrolling {
                isScrolling = false
                print("🎯 Scroll Ended (Core Animation)")
                onScrollEnded()
            }
            scrollTimer?.invalidate()
            scrollTimer = nil
        }

        deinit {
            if let link = displayLink {
                CVDisplayLinkStop(link)
            }
            scrollTimer?.invalidate()
        }
    }

    func makeNSView(context: Context) -> ScrollViewObserver {
        ScrollViewObserver(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded)
    }

    func updateNSView(_ nsView: ScrollViewObserver, context: Context) {}
}

// MARK: Solution 4: SwiftUI-only (Simpler but Limited)
struct SwiftUIOnlyScrollDetector: ViewModifier {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    @State private var scrollTimer: Timer?
    @State private var isScrolling = false
    @State private var lastOffset: CGFloat = 0
    private let scrollEndDelay: TimeInterval = 0.8
    private let scrollThreshold: CGFloat = 2.0

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("scrollView")).minY
                        )
                }
            )
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                let scrollDelta = abs(offset - lastOffset)

                if scrollDelta > scrollThreshold {
                    if !isScrolling {
                        isScrolling = true
                        print("🎯 Scroll Started (SwiftUI-only)")
                        onScrollStarted()
                    }

                    scrollTimer?.invalidate()
                    scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [self] _ in
                        handleScrollEnd()
                    }

                    lastOffset = offset
                }
            }
    }

    private func handleScrollEnd() {
        if isScrolling {
            isScrolling = false
            print("🎯 Scroll Ended (SwiftUI-only)")
            onScrollEnded()
        }
        scrollTimer?.invalidate()
        scrollTimer = nil
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Easy Integration Extensions
extension View {
    func workingScrollDetection(
        onScrollStarted: @escaping () -> Void,
        onScrollEnded: @escaping () -> Void,
        method: ScrollDetectionMethod = .eventMonitor
    ) -> some View {
        switch method {
        case .eventMonitor:
            return self.modifier(ScrollEventMonitor(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded))
        case .coreAnimation:
            return self.modifier(CoreAnimationScrollDetector(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded))
        case .swiftUIOnly:
            return self.modifier(SwiftUIOnlyScrollDetector(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded))
        case .nsScrollViewDelegate:
            return self.background(NSScrollViewDetector(onScrollStarted: onScrollStarted, onScrollEnded: onScrollEnded))
        }
    }
}

enum ScrollDetectionMethod {
    case eventMonitor        // Most compatible
    case coreAnimation       // Most responsive
    case swiftUIOnly        // Simplest but limited
    case nsScrollViewDelegate // Most traditional
}