import SwiftUI
import AppKit

public struct FloatingWindowModifier: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content
            .background(WindowAccessor())
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // Slight delay to ensure window is attached
            if let window = view.window {
                window.level = .floating
                window.styleMask = [.borderless, .fullSizeContentView]
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = true
                window.isMovableByWindowBackground = true
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
            } else {
                print("DEBUG: WindowAccessor failed to find window")
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

public extension View {
    func floatingWindow() -> some View {
        self.modifier(FloatingWindowModifier())
    }
}
