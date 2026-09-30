/**
 * [INPUT]: AppKit, QuartzCore (via TourFeedbackTicker); TourGuidanceMotion
 *          (the pure motion), TourGuidanceStore, TourCardWindow / TourHaloWindow.
 * [OUTPUT]: Exports TourGuidance — the live shell around `TourGuidanceMotion`:
 *           owns the clock and the display-link ticker, applies each frame to
 *           the card window's frame + alpha, the overlay window and the
 *           SwiftUI store.
 * [POS]: MusicMiniPlayerAppKit/Tour. Same split as TourCompletionFeedback /
 *        TourFeedbackChoreographer: the motion is testable with a fake clock,
 *        this class is the thin part that touches windows. The ticker only
 *        runs while something moves or a hint is running, so a tour resting on
 *        a card costs nothing (spec C.8 "空闲成本").
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
    /// Ticks the ticker has run (a cost seam: idle must not tick).
    private(set) var tickCount = 0

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
        store.frame = .idle
        store.overlayFrame = .zero
        store.panelFrame = .zero
        lastFrame = .idle
    }

    // MARK: Apply

    private func apply() {
        let f = motion.makeFrame()
        lastFrame = f
        store.frame = f
        if let window = cardWindow { applyCard(f, to: window) }
        if let overlay = overlayWindow, store.overlayFrame != overlay.frame { store.overlayFrame = overlay.frame }
    }

    private func applyCard(_ f: TourGuidanceFrame, to window: TourCardWindow) {
        guard f.cardVisible else {
            if window.isVisible { window.orderOut(nil) }
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
        window.alphaValue = CGFloat(min(max(f.cardOpacity, 0), 1))
        window.ignoresMouseEvents = f.cardOpacity < 0.05
        if !window.isVisible { window.orderFront(nil) }
    }
}
