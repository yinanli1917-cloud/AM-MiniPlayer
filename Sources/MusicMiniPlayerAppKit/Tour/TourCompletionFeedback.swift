/**
 * [INPUT]: SwiftUI, AppKit, QuartzCore (CADisplayLink); MusicMiniPlayerCore's
 *          TourHaptic; TourFeedbackChoreographer (the state machine),
 *          TourFeedbackViews (what draws a frame), TourCelebrationWindow
 *          (the click-through overlay window class).
 * [OUTPUT]: Exports TourCompletionFeedback (the ONE entry point:
 *           `begin(_:onSwapDue:)`, plus `cardDidSwap()` / `cancel()`),
 *           TourSparkOverlay (the click-through FX window: sparks, halos,
 *           confetti) and the system-haptic hook.
 * [POS]: MusicMiniPlayerAppKit/Tour. The "you just finished a step" feedback
 *        (spec docs/design/2026-09-29-motion-prototype/spec.md §B): a
 *        multi-state choreography (anticipate, draw, grow, sparks, settle,
 *        handoff; for the last step seal, disc, confetti). This class is the
 *        thin live shell around the pure `TourFeedbackChoreographer`: it owns
 *        the clock, the display-link ticker, the haptics and the FX window,
 *        and republishes the choreographer's frame for the views. The rest of
 *        the tour only calls `begin(_:)` and embeds `TourFeedbackRing` /
 *        `TourFeedbackBeatDot` / `TourFeedbackBeatRow`.
 *
 * Coordinates (fix of 2026-09-29, kept): the FX field is built in WINDOW-LOCAL,
 * y-down coordinates from the ring / card rectangles the controller passes in
 * screen space; particles are never given screen coordinates.
 */

import SwiftUI
import AppKit
import QuartzCore
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Ticker
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// One callback per display refresh (display link, macOS 14+); a 60 Hz timer
/// when there is no screen (headless).
@MainActor
final class TourFeedbackTicker: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    var onTick: (() -> Void)?
    var isRunning: Bool { link != nil || timer != nil }

    func start() {
        guard link == nil, timer == nil else { return }
        if let screen = NSScreen.main {
            let l = screen.displayLink(target: self, selector: #selector(fire))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onTick?() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }

    @objc private func fire() { onTick?() }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - The entry point
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
final class TourCompletionFeedback: ObservableObject {
    @Published private(set) var frame: TourFeedbackFrame = .rest
    @Published private(set) var fx: TourFXSnapshot = .empty
    /// True while a completion is on screen (its "done" state included).
    private(set) var isActive = false
    private(set) var lastEvent: TourFeedbackEvent?
    /// The finale card bounce: the controller moves the real window by this many
    /// points (negative = up) — the window moves, so nothing clips at its edge.
    var applyCardOffset: ((CGFloat) -> Void)?
    /// Spec C.3 "H": the handoff to the next card starts (see the choreographer).
    var onHandoffStart: (() -> Void)? {
        get { choreographer.onHandoffStart }
        set { choreographer.onHandoffStart = newValue }
    }

    let choreographer: TourFeedbackChoreographer
    private let clock: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private let autoTick: Bool
    private var lastClock: TimeInterval = 0
    private var lastCardOffset: CGFloat = 0
    #if DEBUG
    private var lastTickWall: TimeInterval = 0
    #endif
    private let ticker = TourFeedbackTicker()
    private let sparks: TourSparkOverlay

    /// `autoTick: false` = the caller (a test) drives time via `advance(to:)`.
    init(clock: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         autoTick: Bool = true,
         sparks: TourSparkOverlay? = nil,
         haptic: @escaping (TourHaptic) -> Void = TourCompletionFeedback.performSystemHaptic,
         random: TourFeedbackRandom = TourSystemRandom()) {
        self.clock = clock
        self.reduceMotion = reduceMotion
        self.autoTick = autoTick
        self.sparks = sparks ?? TourSparkOverlay()
        self.choreographer = TourFeedbackChoreographer(reduceMotion: reduceMotion(), random: random, haptic: haptic)
        self.choreographer.ownsSwap = true
        ticker.onTick = { [weak self] in
            guard let self else { return }
            #if DEBUG
            let began = CACurrentMediaTime()
            let interval = began - self.lastTickWall
            self.lastTickWall = began
            #endif
            self.advance(to: self.clock())
            #if DEBUG
            TourPerfProbe.tick("feedback", interval: interval, apply: CACurrentMediaTime() - began)
            #endif
        }
    }

    /// Spec §B.8: `.levelChange` on the check landing, `.alignment` on the
    /// seal; fresh `defaultPerformer` each time; nothing when there is no
    /// trackpad (the system swallows it).
    nonisolated static func performSystemHaptic(_ kind: TourHaptic) {
        let pattern: NSHapticFeedbackManager.FeedbackPattern = (kind == .alignment) ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .drawCompleted)
    }

    /// Test entry: step the choreographer exactly like the prototype's
    /// `__proto.advance(seconds)` (chunks of 1/60) and republish.
    func advance(by seconds: TimeInterval) {
        choreographer.advance(by: seconds)
        if !choreographer.isActive { finishSequence() } else { publish() }
    }

    /// The card content has to be swapped under a running sequence.
    var expectsSwap: Bool { choreographer.expectsSwap }

    /// THE entry point: start the "you finished it" feedback. `onSwapDue` is
    /// called at the frame the old content has faded out; the caller then
    /// swaps the card and calls `cardDidSwap()` (directly or from its own
    /// swap path).
    func begin(_ event: TourFeedbackEvent, onSwapDue: (() -> Void)? = nil) {
        if isActive { advance(to: clock()) }   // catch the running sequence up to "now" first
        let rm = reduceMotion()
        if !choreographer.busy { choreographer.reduceMotion = rm } else { choreographer.reduceMotionChanged(to: rm) }
        lastEvent = event
        lastClock = clock()
        choreographer.onSwapDue = onSwapDue
        guard choreographer.begin(event, wallNow: lastClock) else { return }
        // (particles spawn at their cues, later: the geometry only has to be there by then)
        if !rm, event.growsRing, let ring = event.ringCenterOnScreen {
            choreographer.geometry = sparks.prepare(
                ringCenter: ring, cardBody: event.cardFrameOnScreen,
                wantsConfetti: event.confetti, feedback: self)
        } else {
            choreographer.geometry = nil
        }
        isActive = true
        publish()
        if autoTick { ticker.start() }
    }

    /// Ticker / test entry: move the animation to absolute clock time `t`.
    func advance(to t: TimeInterval) {
        guard isActive else { return }
        var remaining = min(max(t - lastClock, 0), 0.5)
        lastClock = t
        choreographer.reduceMotionChanged(to: reduceMotion())
        // Steps of at most one 60 Hz frame (a hair over, so a 60 Hz tick is one
        // step) keep the cue clock and the spring integration deterministic.
        while remaining > 1e-9 {
            let d = min(remaining, 1.0 / 60.0 + 0.0005)
            choreographer.step(d)
            remaining -= d
        }
        if !choreographer.isActive {
            finishSequence()
        } else {
            publish()
        }
    }

    /// The controller swapped the card content under the running sequence.
    func cardDidSwap() {
        choreographer.cardDidSwap()
        publish()
    }

    /// Ends the feedback immediately (next card landed / tour torn down).
    func cancel() {
        ticker.stop()
        choreographer.reset()
        choreographer.onSwapDue = nil
        choreographer.geometry = nil
        isActive = false
        frame = .rest
        fx = .empty
        sparks.stop()
        emitCardOffset(0)
    }

    private func finishSequence() {
        ticker.stop()
        isActive = false
        choreographer.onSwapDue = nil
        frame = .rest
        fx = .empty
        sparks.stop()
        emitCardOffset(0)
    }

    private func publish() {
        let f = choreographer.makeFrame()
        if f != frame { frame = f }
        let snapshot = choreographer.makeFXSnapshot()
        if snapshot != fx { fx = snapshot }
        emitCardOffset(CGFloat(f.cardOffsetY))
    }

    private func emitCardOffset(_ dy: CGFloat) {
        guard dy != lastCardOffset else { return }
        lastCardOffset = dy
        applyCardOffset?(dy)
    }

    var debugSparkOverlay: TourSparkOverlay { sparks }
    /// Raises the FX window above a card window that was just re-ordered.
    func raiseOverlay() { sparks.raise() }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - FX window (sparks, halos, confetti)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The particles fly outside the card, so they get their own transparent
/// click-through window (`TourCelebrationWindow`). Small (ring +- 64pt) for
/// sparks and halos; large (card +- 260pt wide, 220pt above, 460pt below)
/// when confetti launches from the card's top edge and falls.
@MainActor
final class TourSparkOverlay {
    static let sparkRadius: CGFloat = 64

    private(set) var window: TourCelebrationWindow?
    private(set) var originInWindow: CGPoint?
    private(set) var frameOnScreen: CGRect?

    /// Positions the window and returns the FX geometry in its local space.
    func prepare(ringCenter: CGPoint, cardBody: CGRect?, wantsConfetti: Bool, feedback: TourCompletionFeedback) -> TourFXGeometry {
        let rect: CGRect
        if wantsConfetti, let body = cardBody {
            rect = CGRect(x: body.minX - 260, y: body.minY - 460, width: body.width + 520, height: body.height + 460 + 220)
        } else {
            rect = CGRect(x: ringCenter.x - Self.sparkRadius, y: ringCenter.y - Self.sparkRadius,
                          width: Self.sparkRadius * 2, height: Self.sparkRadius * 2)
        }
        let local = CGPoint(x: ringCenter.x - rect.minX, y: rect.maxY - ringCenter.y)
        let window = self.window ?? TourCelebrationWindow()
        self.window = window
        // (An NSWindow is never without a content view: a fresh one holds a plain NSView, so the old
        // `contentView == nil` test never installed the hosting view and the FX window stayed empty.)
        if !(window.contentView is TourHostingView<TourFXHost>) {
            window.contentView = TourHostingView(rootView: TourFXHost(feedback: feedback))
        }
        window.setFrame(rect, display: true)
        window.orderFront(nil)
        frameOnScreen = rect
        originInWindow = local
        let cardTop = cardBody.map { Double(rect.maxY - $0.maxY) } ?? Double(local.y)
        let cardCenterX = cardBody.map { Double($0.midX - rect.minX) } ?? Double(local.x)
        return TourFXGeometry(ringCenter: local, cardTop: cardTop, cardCenterX: cardCenterX, zoom: 1)
    }

    func raise() { window?.orderFront(nil) }

    func stop() {
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        originInWindow = nil
        frameOnScreen = nil
    }
}
