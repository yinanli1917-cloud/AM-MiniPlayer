/**
 * [INPUT]: EdgeCollapseAppModel (state + geometry to render), NSScreen.main
 * [OUTPUT]: EdgeCollapsePanel (borderless, non-activating, transparent NSPanel
 *           docked at the right screen edge) + EdgeGestureHostingView (two-
 *           finger scroll → collapse gesture capture)
 * [POS]: Standalone spike app layer. Panel replication follows
 *        research/spikes/glass-morph-spike/main.swift's `makePanel` +
 *        Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift's panel style
 *        (borderless/nonactivating/floating/canJoinAllSpaces/fullScreenAuxiliary).
 * [PROTOCOL]: Frame changes only happen via `setPresentationFrame` — never
 *             call `setFrame` directly elsewhere, so every frame change stays
 *             logged (design §9).
 */

import AppKit
import SwiftUI

/// Borderless, non-activating, transparent panel — cannot become key/main so
/// it never steals focus from Music.app or the founder's active window, same
/// contract as `SnappablePanel`/the glass-morph-spike's `SpikePanel`.
final class EdgeCollapsePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Fixed vertical center, captured the first time a frame is set — every
    /// subsequent size change (card/tucked/floating) keeps this Y so the
    /// panel visually stays "docked" at one spot on the edge (design §3:
    /// "纵向对齐卡片原中心并夹在屏幕内").
    private var verticalCenterY: CGFloat?

    /// Computes the frame for a given content size, keeping the right edge
    /// flush to the screen's right edge and the vertical center fixed.
    func frame(forContentSize size: CGSize) -> NSRect {
        let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return NSRect(origin: .zero, size: size) }
        if verticalCenterY == nil {
            verticalCenterY = screen.frame.midY
        }
        let centerY = verticalCenterY ?? screen.frame.midY
        let x = screen.frame.maxX - size.width
        var y = centerY - size.height / 2
        // Keep the whole panel on-screen vertically.
        y = min(max(y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The ONLY sanctioned way to change this panel's frame — design §3:
    /// "Frame changes ONLY at settled boundaries... During an animation keep
    /// the larger frame and draw inside it." Callers pass `animated: false`
    /// always in this spike (the frame itself never animates; the CONTENT
    /// drawn inside it does).
    func setPresentationFrame(_ rect: NSRect, animated: Bool) {
        setFrame(rect, display: true, animate: animated)
    }
}

/// Replicates the transparent/floating panel setup from the glass-morph-spike
/// and `SnappablePanel`, but with `ignoresMouseEvents = false` — this spike
/// needs real scroll/hover/click input, unlike the earlier render/morph probe.
func makeEdgeCollapsePanel(initialContentSize: CGSize) -> EdgeCollapsePanel {
    let panel = EdgeCollapsePanel(
        contentRect: NSRect(origin: .zero, size: initialContentSize),
        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    panel.ignoresMouseEvents = false
    panel.acceptsMouseMovedEvents = true
    panel.setFrame(panel.frame(forContentSize: initialContentSize), display: false)
    return panel
}

/// Hosts the SwiftUI root view and intercepts two-finger horizontal scroll
/// (design §4: "双指横滑向边...→ collapse 到该边"). Only the `.ended` phase
/// with a dominant horizontal delta counts, so a vertical lyrics/list scroll
/// (irrelevant here — this spike has no such content) or an in-progress
/// scroll never fires early.
final class EdgeGestureHostingView<Content: View>: NSHostingView<Content> {
    var onHorizontalSwipeToEdge: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .ended,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
              abs(event.scrollingDeltaX) > 2 else {
            super.scrollWheel(with: event)
            return
        }
        onHorizontalSwipeToEdge?()
    }
}
