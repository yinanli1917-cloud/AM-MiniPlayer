import SwiftUI
import AppKit

// MARK: - Scroll Detector Background View

struct ScrollDetectorBackground: NSViewRepresentable {
    let onScrollDetected: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollDetectorBackgroundNSView()
        view.onScrollDetected = onScrollDetected
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let detectorView = nsView as? ScrollDetectorBackgroundNSView {
            detectorView.onScrollDetected = onScrollDetected
        }
    }
}

class ScrollDetectorBackgroundNSView: NSView {
    var onScrollDetected: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollDetected?()
        super.scrollWheel(with: event)
    }
}