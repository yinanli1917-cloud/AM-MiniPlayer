/**
 * [INPUT]: EdgeCollapseAppModel (state + layout to hit-test against), NSScreen.main
 * [OUTPUT]: EdgeCollapsePanel (borderless, non-activating, transparent NSPanel,
 *           FIXED 320×360, right edge pinned to the screen's right edge,
 *           vertically centered — never resized) + EdgeGestureHostingView
 *           (two-finger scroll → collapse, NSTrackingArea hover → floating,
 *           `hitTest` click-through outside the active layout's hit region).
 * [POS]: Standalone spike app layer. Panel replication follows
 *        research/spikes/glass-morph-spike/main.swift's `makePanel` +
 *        Sources/MusicMiniPlayerCore/UI/SnappablePanel.swift's panel style.
 * [PROTOCOL]: Top-level task instruction #3: "WINDOW NEVER CHANGES SIZE
 *             during or between transitions" — this file must never call
 *             `setFrame`/`setContentSize` again after the initial launch
 *             placement. Transparent areas pass mouse events through via
 *             `hitTest` returning `nil`, NOT via `ignoresMouseEvents`
 *             toggling (verified below).
 */

import AppKit
import SwiftUI

/// Borderless, non-activating, transparent panel — cannot become key/main so
/// it never steals focus from Music.app or the founder's active window, same
/// contract as `SnappablePanel`/the glass-morph-spike's `SpikePanel`.
final class EdgeCollapsePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Places the fixed `EdgeCollapseTokens.containerSize` panel with its right
/// edge flush to the main screen's right edge, vertically centered —
/// top-level task instruction #3. Computed ONCE at launch; the panel is
/// never moved or resized afterward (contrast the old
/// `EdgeCollapsePanel.setPresentationFrame`, which resized the window at
/// every settle boundary — deleted along with the state-sized window model).
func pinnedPanelFrame(screen: NSScreen?) -> NSRect {
    let size = EdgeCollapseTokens.containerSize
    let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else { return NSRect(origin: .zero, size: size) }
    let x = screen.frame.maxX - size.width
    var y = screen.frame.midY - size.height / 2
    y = min(max(y, screen.visibleFrame.minY), screen.visibleFrame.maxY - size.height)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
}

/// Replicates the transparent/floating panel setup from the glass-morph-spike
/// and `SnappablePanel`.
func makeEdgeCollapsePanel() -> EdgeCollapsePanel {
    let frame = pinnedPanelFrame(screen: NSScreen.main)
    let panel = EdgeCollapsePanel(
        contentRect: frame,
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
    // Click-through for transparent regions is done via the hosting view's
    // own `hitTest` (below), not by toggling this — verified: an NSWindow
    // with a clear backgroundColor still routes ALL events within its frame
    // to its view hierarchy by default; only an explicit `hitTest` override
    // that returns `nil` outside the active hit-region lets events fall
    // through to whatever's behind the panel.
    panel.ignoresMouseEvents = false
    panel.acceptsMouseMovedEvents = true
    panel.setFrame(frame, display: false)
    return panel
}

/// Hosts the SwiftUI root view. Three responsibilities, all top-level task
/// instruction #3:
/// 1. Two-finger horizontal scroll → collapse (only from `.card`).
/// 2. `NSTrackingArea` over the CURRENT active hit-region (tucked stalk's
///    16pt-padded hit box, or floating's 12pt-padded union) → hover enter/exit.
/// 3. `hitTest` returns `nil` outside that same active hit-region, so clicks
///    on the window's otherwise-transparent 320×360 canvas pass through to
///    whatever's behind the panel.
final class EdgeGestureHostingView<Content: View>: NSHostingView<Content> {
    var onHorizontalSwipeToEdge: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Supplies the CURRENT active hit-region in this view's own local
    /// coordinate space (top-left origin — `NSHostingView.isFlipped` is
    /// `true`, matching `EdgeCollapseLayout`'s SwiftUI-style coordinates
    /// directly, no Y-flip math needed here).
    var activeHitRegionProvider: (() -> CGRect)?

    private var trackingArea: NSTrackingArea?

    /// Called by `EdgeCollapseAppModel` whenever presentation/variant/track
    /// changes the active hit-region — `NSTrackingArea` doesn't auto-update
    /// from SwiftUI state changes, only from AppKit layout passes.
    func refreshHitRegion() {
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let rect = activeHitRegionProvider?() ?? .zero
        guard rect.width > 0, rect.height > 0 else { trackingArea = nil; return }
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let rect = activeHitRegionProvider?() ?? .zero
        return rect.contains(local) ? super.hitTest(point) : nil
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    /// Only the `.ended` phase with a dominant, RIGHTWARD horizontal delta
    /// counts (top-level task instruction #6: "check direction this time:
    /// rightward" — v1 only checked magnitude via `abs`, which would also
    /// fire on a leftward swipe; this panel docks at the RIGHT edge, so only
    /// a swipe toward that edge should collapse). Convention: positive
    /// `scrollingDeltaX` is treated as "toward the right edge" — documented
    /// here since AppKit's natural-scrolling sign convention is otherwise
    /// easy to get backwards.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase == .ended,
              event.scrollingDeltaX > 2,
              abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event)
            return
        }
        onHorizontalSwipeToEdge?()
    }
}
