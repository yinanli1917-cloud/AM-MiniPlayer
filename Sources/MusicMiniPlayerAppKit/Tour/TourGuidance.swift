/**
 * [INPUT]: AppKit, QuartzCore (via TourFeedbackTicker / TourFrameDriver); TourGuidanceMotion
 *          (the pure motion), TourGuidanceStore (card / demo clock / overlay, three observable objects), TourCardWindow / TourHaloWindow, TourOverlayRegion.
 * [OUTPUT]: Exports TourGuidance — the live shell around `TourGuidanceMotion`:
 *           owns the clock and the display-link ticker, applies each frame to
 *           the card window's frame + alpha, the overlay window (sized to what it draws, parked when
 *           it draws nothing) and the two SwiftUI stores (card / overlay, each published only when
 *           its own part of the frame changed).
 * [POS]: MusicMiniPlayerAppKit/Tour. Same split as TourCompletionFeedback /
 *        TourFeedbackChoreographer: the motion is testable with a fake clock,
 *        this class is the thin part that touches windows. The ticker only
 *        runs while something moves or a hint is running, so a tour resting on
 *        a card costs nothing (spec C.8 "空闲成本"). Per frame it does no SwiftUI work
 *        that the frame did not ask for: a frame in which only the ring breathes never
 *        re-evaluates the card, a frame in which only the card travels never redraws the ring.
 */

import AppKit
import MusicMiniPlayerCore

@MainActor
final class TourGuidance {
    private(set) var motion: TourGuidanceMotion
    let store = TourGuidanceStore()

    private let clock: () -> TimeInterval
    private let reduceMotionProvider: () -> Bool
    private let autoTick: Bool
    private let ticker = TourFeedbackTicker()
    private var lastClock: TimeInterval = 0
    private(set) weak var cardWindow: TourCardWindow?
    private(set) weak var overlayWindow: TourHaloWindow?
    private(set) var lastFrame: TourGuidanceFrame = .idle
    /// The screen the overlay may cover (the panel's screen).
    var screenFrame: () -> CGRect = { NSScreen.main?.frame ?? .zero }
    /// Ticks the ticker has run (a cost seam: idle must not tick).
    private(set) var tickCount = 0
    /// How long the overlay may draw nothing before its window is ordered out.
    static let overlayParkDelay: TimeInterval = 0.3
    private var overlayEmptySince: TimeInterval?
    /// Overlay window resizes (a cost seam: a ring hopping between controls must not resize per frame).
    private(set) var overlayResizeCount = 0

    init(clock: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         autoTick: Bool = true) {
        self.clock = clock
        self.reduceMotionProvider = reduceMotion
        self.autoTick = autoTick
        motion = TourGuidanceMotion(reduceMotion: reduceMotion())
        store.driven = true
        ticker.onTick = { [weak self] in self?.tick() }
    }

    func attach(card: TourCardWindow?, overlay: TourHaloWindow?) {
        cardWindow = card
        overlayWindow = overlay
    }

    /// Called before every motion command: the user may have flipped Reduce Motion.
    func syncReduceMotion() {
        let rm = reduceMotionProvider()
        if rm != motion.reduceMotion { motion.reduceMotion = rm }
    }

    /// Applies the current frame now and keeps the ticker alive while there is motion.
    func kick() {
        if !ticker.isRunning { lastClock = clock() }
        apply()
        if motion.isAnimating, autoTick { ticker.start() }
    }

    /// Ticker entry.
    private func tick() {
        tickCount += 1
        let now = clock()
        let dt = min(max(now - lastClock, 0), 0.1)
        lastClock = now
        #if DEBUG
        let began = CACurrentMediaTime()
        #endif
        motion.advance(by: dt)
        apply()
        #if DEBUG
        TourPerfProbe.tick("guidance", interval: dt, apply: CACurrentMediaTime() - began)
        #endif
        if !motion.isAnimating { ticker.stop() }
    }

    /// Test entry: step like the prototype's `__proto.advance(seconds)`.
    func advance(by seconds: TimeInterval) {
        motion.advance(by: seconds)
        apply()
    }

    func stop() {
        ticker.stop()
    }

    /// A tour that ended leaves nothing behind: the motion starts from rest next time.
    func reset() {
        motion = TourGuidanceMotion(reduceMotion: reduceMotionProvider())
        store.card = .hidden
        store.glyphClock.elapsed = nil
        store.overlay = .hidden
        store.overlayFrame = .zero
        store.panelFrame = .zero
        lastFrame = .idle
        overlayResizeCount = 0
    }

    // MARK: Apply

    private func apply() {
        let f = motion.makeFrame()
        lastFrame = f
        // Published only when its own part changed: SwiftUI re-evaluates a store's observers on every set.
        var card = TourCardVisual(f)
        // The demo's clock ticks every frame; it goes to the demo alone, so the card's own view stays put.
        if f.glyphElapsed != store.glyphClock.elapsed { store.glyphClock.elapsed = f.glyphElapsed }
        card.glyphElapsed = nil
        if card != store.card { store.card = card }
        let overlayVisual = TourOverlayVisual(f)
        if overlayVisual != store.overlay { store.overlay = overlayVisual }
        if let window = cardWindow { applyCard(f, to: window) }
        if let overlay = overlayWindow { applyOverlay(overlayVisual, to: overlay) }
    }

    private func applyCard(_ f: TourGuidanceFrame, to window: TourCardWindow) {
        guard f.cardVisible else {
            if window.isVisible {
                window.orderOut(nil)
                #if DEBUG
                TourPerfProbe.mark("card orderOut")
                #endif
            }
            return
        }
        var x = f.cardX, y = f.cardTop - f.cardHeight
        switch f.cardBeakSide {
        case .right: x += f.cardApproach
        case .left: x -= f.cardApproach
        case .top: y += f.cardApproach
        case .bottom: y -= f.cardApproach
        }
        let target = NSRect(x: x, y: y, width: max(f.cardWidth, 1), height: max(f.cardHeight, 1))
        if window.frame != target {
            window.setFrame(target, display: false)
            #if DEBUG
            TourPerfProbe.bump(.cardSetFrame)
            #endif
        }
        let alpha = CGFloat(min(max(f.cardOpacity, 0), 1))
        if window.alphaValue != alpha { window.alphaValue = alpha }
        let ignores = f.cardOpacity < 0.05
        if window.ignoresMouseEvents != ignores { window.ignoresMouseEvents = ignores }
        if !window.isVisible {
            window.orderFront(nil)
            #if DEBUG
            TourPerfProbe.mark("card orderFront")
            #endif
        }
    }

    /// The overlay window covers only what is drawn (ring + its glow, ghost cursor, panel-edge glow) and is
    /// parked while nothing is: a full-screen transparent window re-rendered every frame was ~59 MB of backing
    /// store on a 2560x1440 Retina screen, redrawn 60-120 times a second for a glow that fills 5% of it.
    private func applyOverlay(_ visual: TourOverlayVisual, to window: TourHaloWindow) {
        let panel = store.panelFrame
        guard visual.hasContent, let needed = TourOverlayRegion.needed(for: visual, panel: panel) else {
            guard window.isVisible else { return }
            // Park it once nothing has been drawn for a beat — or at once when no more frames are coming to decide it
            // later. (The panel-edge glow touches zero at every breath; ordering the window out and in per breath is
            // work for nothing and a flicker risk.)
            let now = clock()
            let since = overlayEmptySince ?? now
            overlayEmptySince = since
            if !motion.isAnimating || now - since >= Self.overlayParkDelay {
                window.orderOut(nil)
                overlayEmptySince = nil
                #if DEBUG
                TourPerfProbe.mark("overlay orderOut")
                #endif
            }
            return
        }
        overlayEmptySince = nil
        let screen = screenFrame()
        let target = TourOverlayRegion.windowFrame(current: window.isVisible ? window.frame : .zero, needed: needed,
                                                   panel: panel, screen: screen.isEmpty ? needed : screen)
        if window.frame != target {
            window.setFrame(target, display: false)
            overlayResizeCount += 1
            #if DEBUG
            TourPerfProbe.bump(.overlaySetFrame)
            #endif
        }
        if store.overlayFrame != target { store.overlayFrame = target }
        if !window.isVisible {
            window.orderFront(nil)
            #if DEBUG
            TourPerfProbe.mark("overlay orderFront")
            #endif
        }
    }
}
