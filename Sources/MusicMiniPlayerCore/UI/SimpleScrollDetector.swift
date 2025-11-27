import SwiftUI
import AppKit

// MARK: - Simple but Reliable Scroll Detector

struct SimpleScrollDetector: NSViewRepresentable {
    let onScrollStarted: () -> Void
    let onScrollEnded: () -> Void

    func makeNSView(context: Context) -> ScrollDetectingView {
        let view = ScrollDetectingView()
        view.onScrollStarted = onScrollStarted
        view.onScrollEnded = onScrollEnded
        return view
    }

    func updateNSView(_ nsView: ScrollDetectingView, context: Context) {
        // No updates needed
    }
}

class ScrollDetectingView: NSView {
    var onScrollStarted: (() -> Void)?
    var onScrollEnded: (() -> Void)?

    private var scrollTimer: Timer?
    private var isScrolling = false
    private var lastScrollTime: Date = Date()

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        print("🔄 SCROLL WHEEL EVENT - deltaY: \(event.scrollingDeltaY)")

        // Detect scroll start
        if !isScrolling {
            isScrolling = true
            print("📜 SCROLL DETECTED - Started!")
            onScrollStarted?()
        }

        // Reset timer for scroll end detection
        scrollTimer?.invalidate()
        lastScrollTime = Date()

        scrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }

            self.isScrolling = false
            print("📜 SCROLL DETECTED - Ended!")
            self.onScrollEnded?()
            self.scrollTimer = nil
        }

        // CRITICAL: Forward to parent to maintain scrolling
        if let parent = self.superview as? NSScrollView {
            parent.scrollWheel(with: event)
        }
    }

    deinit {
        scrollTimer?.invalidate()
    }
}

// MARK: - Convenience Extension

extension View {
    func simpleScrollDetection(
        onScrollStarted: @escaping () -> Void,
        onScrollEnded: @escaping () -> Void
    ) -> some View {
        self.overlay(
            SimpleScrollDetector(
                onScrollStarted: onScrollStarted,
                onScrollEnded: onScrollEnded
            )
            .allowsHitTesting(false)
        )
    }
}