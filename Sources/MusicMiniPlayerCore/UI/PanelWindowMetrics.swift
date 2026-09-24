/**
 * [INPUT]: The panel's SwiftUI root view.
 * [OUTPUT]: PanelWindowMetrics — the floating panel window's size rules and
 *           the content view that hosts the panel.
 * [POS]: Floating panel window (MusicMiniPlayerApp.createFloatingWindow).
 * [PROTOCOL]: Founder 2026-09-23: the window is exactly the panel. It used
 *   to be 32pt taller: a titled window whose title-bar safe area the panel
 *   never drew into, so the top 32pt was an invisible strip (snap margins
 *   were 48pt at top corners and the liquid edge landed on the strip).
 *   Every page was tuned inside that layout — a 32pt top safe area that
 *   full-bleed views (backdrop, full-screen cover) extend into and the
 *   panel clips away. To keep every page pixel-identical, the hosting view
 *   keeps that exact geometry: it stays 32pt taller than the window,
 *   reaching above its top edge, and the 32pt safe area is declared in
 *   SwiftUI instead of coming from the title bar. Pinned by
 *   PanelWindowLayoutParityTests.
 */

import AppKit
import SwiftUI

public enum PanelWindowMetrics {
    /// The panel at its default size (it used to be the lower 250x284 of a
    /// 250x316 window).
    public static let defaultSize = NSSize(width: 250, height: 284)
    public static let minWidth: CGFloat = 180
    public static let maxWidth: CGFloat = 400
    /// The window keeps the panel's proportions when resized.
    public static var aspectRatio: NSSize { defaultSize }
    public static var minSize: NSSize { size(forWidth: minWidth) }
    public static var maxSize: NSSize { size(forWidth: maxWidth) }

    public static func size(forWidth width: CGFloat) -> NSSize {
        NSSize(width: width, height: width * defaultSize.height / defaultSize.width)
    }

    /// The top safe area every page was tuned inside (the old title bar).
    public static let tunedTopSafeArea: CGFloat = 32
    public static let cornerRadius: CGFloat = 16

    /// The window's content view: a plain container the size of the window,
    /// holding the hosting view 32pt taller than it (the extra reaches above
    /// the window's top edge and is never on screen).
    @MainActor
    public static func makeContentView<Content: View>(root: Content) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: defaultSize))
        container.wantsLayer = true
        container.autoresizesSubviews = true

        let host = NSHostingView(rootView: root.safeAreaPadding(.top, tunedTopSafeArea))
        // The title bar's own safe area would add another 32pt on top of ours.
        host.safeAreaRegions = []
        host.frame = NSRect(x: 0, y: 0, width: defaultSize.width, height: defaultSize.height + tunedTopSafeArea)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.cornerRadius = cornerRadius
        host.layer?.masksToBounds = true
        container.addSubview(host)
        return container
    }
}
