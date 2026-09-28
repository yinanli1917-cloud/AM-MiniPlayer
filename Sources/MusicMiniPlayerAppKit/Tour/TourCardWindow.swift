/**
 * [INPUT]: AppKit; MusicMiniPlayerCore's SnappablePanel (for the level it
 *          orders above).
 * [OUTPUT]: Exports TourCardWindow, TourHaloWindow — the two nonactivating
 *           overlay panels the tour draws in (proposal §4.1/§4.5).
 * [POS]: MusicMiniPlayerAppKit/Tour. Configuration copied from the approved
 *        precedent `LiquidEdgeStageWindow` (MusicMiniPlayerCore/UI/LiquidEdge/
 *        LiquidEdgeStageView.swift) — canBecomeKey/Main false, borderless +
 *        nonactivatingPanel, floating, transient collection behavior.
 */

import AppKit

/// The card: `canBecomeKey = false` so it never steals focus or activates
/// the app (§4.1's "不成为 key window，不抢焦点"); `ignoresMouseEvents = false`
/// because its buttons/links must be clickable.
final class TourCardWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        // §4.6: glass shadows itself; the NSVisualEffectView fallback arm
        // turns this back on (TourCardView sets it via hasShadow below).
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }
}

/// The highlight halo/pill overlay (§4.5): purely decorative, so it passes
/// every click straight through to whatever is under it.
final class TourHaloWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
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

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }
}
