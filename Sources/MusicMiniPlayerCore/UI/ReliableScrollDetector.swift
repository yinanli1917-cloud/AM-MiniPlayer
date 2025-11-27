import SwiftUI
import AppKit

// MARK: - Modern Scroll Detector for Music Mini Player

struct ReliableScrollDetector: View {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    @State private var scrollEndTimer: Timer?
    @State private var isCurrentlyScrolling = false
    @State private var lastScrollTime: Date = Date()

    var body: some View {
        if #available(macOS 14.0, *) {
            // Use modern onScrollPhaseChange for macOS 14+
            Color.clear
                .onScrollPhaseChange { oldPhase, newPhase in
                    print("🔍 Scroll phase change: \(oldPhase) -> \(newPhase)")

                    switch newPhase {
                    case .tracking, .interacting:
                        handleScrollStart()
                    case .idle, .decelerating, .animating:
                        scheduleScrollEnd()
                    @unknown default:
                        break
                    }
                }
        } else {
            // Fallback to enhanced geometry-based detection for older versions
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        lastScrollTime = Date()
                    }
                    .onChange(of: geometry.frame(in: .named("scrollSpace")).minY) { oldValue, newValue in
                        handleGeometryScrollChange(oldValue: oldValue, newValue: newValue)
                    }
            }
            .preference(
                key: ScrollOffsetKey.self,
                value: 0 // Dummy value - we'll detect changes in onChange
            )
        }
    }

    private func handleScrollStart() {
        if !isCurrentlyScrolling {
            isCurrentlyScrolling = true
            print("📜 Scroll started!")
            onScrollStarted()
        }
        resetScrollEndTimer()
    }

    private func handleGeometryScrollChange(oldValue: CGFloat, newValue: CGFloat) {
        let currentTime = Date()
        let timeSinceLastScroll = currentTime.timeIntervalSince(lastScrollTime)
        let scrollDelta = abs(newValue - oldValue)

        // Debounce to ~60fps and only respond to actual scrolling
        if timeSinceLastScroll > 0.016 && scrollDelta > 0.5 {
            print("🔍 Geometry scroll detection - delta: \(scrollDelta)")
            handleScrollStart()
            lastScrollTime = currentTime
        }
    }

    private func resetScrollEndTimer() {
        scrollEndTimer?.invalidate()
        scrollEndTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            handleScrollEnd()
        }
    }

    private func scheduleScrollEnd() {
        // Additional delay to ensure scroll has truly stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            handleScrollEnd()
        }
    }

    private func handleScrollEnd() {
        if isCurrentlyScrolling {
            isCurrentlyScrolling = false
            print("📜 Scroll ended!")
            onScrollEnded()
        }
        scrollEndTimer?.invalidate()
        scrollEndTimer = nil
    }
}

// MARK: - Supporting Types

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Alternative NSView-based Detector (for older macOS versions)

struct AppKitScrollDetector: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let detectorView = ScrollEventDetectorView()
        detectorView.onScrollStarted = onScrollStarted
        detectorView.onScrollEnded = onScrollEnded
        return detectorView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let detectorView = nsView as? ScrollEventDetectorView {
            detectorView.onScrollStarted = onScrollStarted
            detectorView.onScrollEnded = onScrollEnded
        }
    }
}

class ScrollEventDetectorView: NSView {
    var onScrollStarted: (() -> Void)?
    var onScrollEnded: (() -> Void)?

    private var scrollTimer: Timer?
    private var isScrolling = false
    private let scrollEndDelay: TimeInterval = 2.0

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never intercept mouse events - pass them through
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Detect scroll start
        if !isScrolling {
            isScrolling = true
            onScrollStarted?()
        }

        // Reset scroll end timer
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: scrollEndDelay, repeats: false) { [weak self] _ in
            self?.handleScrollEnd()
        }

        // Important: Pass the event to the next responder
        // Don't call super.scrollWheel as it might not forward properly
        if let nextResponder = self.nextResponder {
            nextResponder.scrollWheel(with: event)
        }
    }

    private func handleScrollEnd() {
        isScrolling = false
        onScrollEnded?()
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    deinit {
        scrollTimer?.invalidate()
    }
}

// MARK: - Integration Helper

extension View {
    func reliableScrollDetection(
        onScrollStarted: @escaping () -> Void,
        onScrollEnded: @escaping () -> Void
    ) -> some View {
        if #available(macOS 13.0, *) {
            return self.overlay(
                ReliableScrollDetector(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded
                )
                .allowsHitTesting(false)
            )
        } else {
            return self.overlay(
                AppKitScrollDetector(
                    onScrollStarted: onScrollStarted,
                    onScrollEnded: onScrollEnded
                )
                .allowsHitTesting(false)
            )
        }
    }
}