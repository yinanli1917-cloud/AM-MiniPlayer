/**
 * [INPUT]: AppKit; TourCardStore/TourCardRoot/TourHostingView (the card's content).
 * [OUTPUT]: Exports TourCardWindow (owns its content + size), TourHaloWindow — the two nonactivating
 *           overlay panels the tour draws in (proposal §4.1/§4.5).
 * [POS]: MusicMiniPlayerAppKit/Tour. Configuration copied from the approved
 *        precedent `LiquidEdgeStageWindow` (MusicMiniPlayerCore/UI/LiquidEdge/
 *        LiquidEdgeStageView.swift) — canBecomeKey/Main false, borderless +
 *        nonactivatingPanel, floating, transient collection behavior.
 */

import AppKit

extension NSWindow.Level {
    /// One step above `.floating`, where the panel lives. The tour's windows
    /// (card, ring overlay, FX) must stay above the panel even after the tour
    /// raises the panel to the front (item 9: another app's floating window
    /// was in front of the panel), so they never depend on ordering alone.
    static let tourOverlay = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
}

/// The card: `canBecomeKey = false` so it never steals focus or activates
/// the app (§4.1's "不成为 key window，不抢焦点"); `ignoresMouseEvents = false`
/// because its buttons/links must be clickable.
///
/// The window is only a transparent frame around the bubble: no background,
/// no border, and NO window-level clipping decisions of its own. The bubble
/// (body + beak, ONE `TourBubbleShape`) is the only thing drawn — the glass
/// (macOS 26) or the masked `NSVisualEffectView` (14/15) lives inside that
/// shape, so every pixel outside it is alpha 0. The window OWNS its size: it
/// re-measures its content whenever the content says its size changed
/// (`refitToContent`), because a size measured once and cached is exactly what
/// clipped the card on the founder's Mac (2026-09-29).
final class TourCardWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// The controller places this window exactly (LiquidEdgeStageWindow's precedent): AppKit must not nudge it back
    /// under the menu bar, or every frame would find it "not where it was put" and put it again.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The size/position the window is heading for (the controller's frame,
    /// possibly mid-animation). `refitToContent` compares against THIS, never
    /// against an in-flight animation frame.
    private(set) var targetFrame: NSRect = .zero
    /// True when `TourGuidance` owns the frame every tick (position AND height):
    /// the content-size refit must not fight the height spring.
    var isDriven = false
    /// Driven windows report a content-size change here instead of refitting
    /// themselves: the controller re-measures and springs the height.
    var onContentSizeChanged: (() -> Void)?

    init(store: TourCardStore) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .tourOverlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        // §4.6: glass draws its own shadow inside the shape; the
        // NSVisualEffectView fallback arm turns the window shadow on (it
        // follows the masked shape, see `TourVibrancyView`).
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false

        let host = TourHostingView(rootView: TourCardRoot(store: store))
        host.onContentSizeInvalidated = { [weak self] in self?.refitToContent() }
        contentView = host
    }

    /// What the card's content needs right now (width includes the beak).
    var contentFittingSize: CGSize { contentView?.fittingSize ?? .zero }

    /// Moves/resizes the window to `frame` (the controller's placement).
    func place(_ frame: NSRect, animated: Bool, duration: TimeInterval = 0, timing: CAMediaTimingFunction? = nil) {
        targetFrame = frame
        #if DEBUG
        if self.frame != frame { TourCardTrace.frameWrite("window.place", old: self.frame, new: frame, "animated=\(animated)") }
        #endif
        if animated, isVisible, self.frame != frame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                if let timing { context.timingFunction = timing }
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
        }
    }

    /// Re-measures the content and, if it no longer fits the window it was
    /// placed in, resizes the window to it, keeping the TOP edge (the beak
    /// offset is measured from it). A no-op when the sizes already agree,
    /// which is every normal controller-driven change.
    func refitToContent() {
        if isDriven { onContentSizeChanged?(); return }
        let need = contentFittingSize
        guard need.width > 0, need.height > 0 else { return }
        let basis = targetFrame.isEmpty ? frame : targetFrame
        guard abs(need.width - basis.width) > 0.5 || abs(need.height - basis.height) > 0.5 else { return }
        let current = frame
        let next = NSRect(x: current.minX, y: current.maxY - need.height, width: need.width, height: need.height)
        targetFrame = NSRect(x: basis.minX, y: basis.maxY - need.height, width: need.width, height: need.height)
        #if DEBUG
        TourCardTrace.frameWrite("window.refitToContent", old: current, new: next)
        #endif
        setFrame(next, display: true)
    }
}

/// The highlight halo/pill overlay (§4.5): purely decorative, so it passes
/// every click straight through to whatever is under it.
final class TourHaloWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .tourOverlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}

/// The confetti/spark overlay (§8.2): also click-through, sized generously
/// around the panel so particles have room to fly.
final class TourCelebrationWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .tourOverlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}
