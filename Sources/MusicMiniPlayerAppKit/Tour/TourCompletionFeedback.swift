/**
 * [INPUT]: SwiftUI, AppKit, QuartzCore (CACurrentMediaTime); MusicMiniPlayerCore's
 *          TourMotionPolicy tokens; TourCardStyle's palette; the particle engine
 *          in TourCelebrationView.swift.
 * [OUTPUT]: Exports TourCompletionFeedback (the ONE entry point: `begin(_:)`),
 *           its Event / Frame value types, TourFeedbackTimeline (pure: event +
 *           elapsed seconds -> Frame), TourFeedbackCurves, and the two views
 *           that render a Frame: TourFeedbackRing, TourFeedbackBeatDot
 *           (+ TourSparkOverlay, the click-through spark window).
 * [POS]: MusicMiniPlayerAppKit/Tour. The "you just finished a step" feedback
 *        (proposal §8.1/§8.2): ring grows, number becomes a check, beat dot
 *        turns into a solid check, sparks. DESIGNED TO BE REPLACED WHOLESALE
 *        (founder 2026-09-29: a dedicated motion design for this moment is
 *        coming): everything the animation needs — state machine, timing,
 *        the ring and dot drawing, the spark window — lives in THIS file;
 *        the rest of the tour only calls `begin(_:)` and embeds
 *        `TourFeedbackRing` / `TourFeedbackBeatDot`. Swap the file, keep the
 *        three names, nothing else changes.
 *
 * Why a pure timeline: the first version rebuilt the whole card (new
 * NSHostingController) on every completion, so nothing could animate between
 * two states, and its sparks were positioned in screen coordinates inside a
 * window-local canvas (invisible). Here the animation is a function
 * `Frame = f(event, elapsed)`; a fake clock can drive it in tests, and the
 * SAME frame is what the views draw.
 */

import SwiftUI
import AppKit
import QuartzCore
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Curves
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourFeedbackCurves {
    /// CSS `cubic-bezier(x1, y1, x2, y2)` (§8.1 ring fill: `.2,.8,.2,1`).
    static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        func axis(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            let v = axis(x1, x2, t)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return axis(y1, y2, t)
    }

    /// Impulse response of an under-damped spring, peak-normalized: 0 ->
    /// 1 (at the first peak) -> a decaying wobble. `spring(response, damping)`
    /// semantics as SwiftUI: omega = 2*pi/response.
    static func pulse(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = min(max(damping, 0.05), 0.99)
        let a = zeta * omega
        let b = omega * (1 - zeta * zeta).squareRoot()
        let peakT = atan(b / a) / b
        let norm = exp(-a * peakT) * sin(b * peakT)
        return exp(-a * t) * sin(b * t) / norm
    }

    /// Step response of the same spring: 0 -> overshoots 1 -> settles at 1.
    static func spring(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = min(max(damping, 0.05), 0.99)
        let a = zeta * omega
        let b = omega * (1 - zeta * zeta).squareRoot()
        return 1 - exp(-a * t) * (cos(b * t) + (a / b) * sin(b * t))
    }

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Event / Frame
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// What just happened, in the tour's own terms.
struct TourFeedbackEvent: Equatable {
    /// Steps completed before / after (0...total). Equal = a beat only.
    var ringFrom: Int
    var ringTo: Int
    var total: Int = 7
    /// Beat dots (indices on the CURRENT card) that just turned solid.
    var beatIndices: [Int] = []
    /// The last segment: the ring reaches a full circle and pulses (§8.2).
    var closesRing: Bool = false
    /// Screen point (AppKit, y up) the sparks fly out from; nil = no sparks.
    var sparkOriginOnScreen: CGPoint?

    var growsRing: Bool { ringTo > ringFrom || closesRing }
}

struct TourFeedbackBeatFrame: Equatable {
    /// 0 = hollow outline, 1 = solid accent with the white check.
    var fill: CGFloat
    var scale: CGFloat
}

/// Everything the views draw at one instant. `.rest` = "draw the card's
/// static model" (nothing is animating).
struct TourFeedbackFrame: Equatable {
    /// Ring arc as a 0...1 fraction; nil = use the card's static progress.
    var ringProgress: CGFloat?
    var ringLineWidth: CGFloat
    var ringScale: CGFloat
    /// The step number's opacity / the check's opacity+scale inside the ring.
    var numberOpacity: CGFloat
    var checkOpacity: CGFloat
    var checkScale: CGFloat
    var beats: [Int: TourFeedbackBeatFrame]

    static let rest = TourFeedbackFrame(
        ringProgress: nil, ringLineWidth: TourMotionPolicy.Tokens.ringLineWidth, ringScale: 1,
        numberOpacity: 1, checkOpacity: 0, checkScale: 1, beats: [:]
    )
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Timeline (pure)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Simple first version of §8.1/§8.2 (the final motion design replaces this
/// struct). All times are seconds since `begin`.
struct TourFeedbackTimeline {
    var event: TourFeedbackEvent
    var reduceMotion: Bool

    typealias T = TourMotionPolicy.Tokens

    static let ringStart = 0.05
    static let numberFadeStart = 0.10
    static let numberFadeDuration = 0.20
    static let checkStart = 0.18
    static let checkDuration = 0.30
    static let beatFillDuration = 0.20
    /// §8.2: the closing pulse fires when the round cap meets the start.
    static let closingPulseAt = 0.60

    /// When the frame goes back to `.rest`. A step's ring shows its check
    /// until the next card lands (`stepCompletionFeedback` = 1.0s), so the
    /// timeline outlives it slightly and the store ends it on card swap.
    var duration: Double {
        if event.growsRing { return T.stepCompletionFeedback + 0.05 }
        return 0.6
    }

    private var ringDuration: Double { reduceMotion ? 0.30 : T.ringFillDuration }

    func frame(at t: Double) -> TourFeedbackFrame {
        guard t >= 0, t < duration else { return .rest }
        var f = TourFeedbackFrame.rest

        // Beat dots: fill 0->1 (ease-out), scale pop 1->1.22->1 (spring .28/.60).
        for index in event.beatIndices {
            let fill = TourFeedbackCurves.cubicBezier(0.2, 0.8, 0.2, 1, at: t / Self.beatFillDuration)
            let scale = reduceMotion ? 1 : 1 + 0.22 * TourFeedbackCurves.pulse(t, response: T.beatCheckResponse, damping: T.beatCheckDamping)
            f.beats[index] = TourFeedbackBeatFrame(fill: CGFloat(fill), scale: CGFloat(scale))
        }

        guard event.growsRing else { return f }

        // Ring arc: from/total -> to/total over 0.6s (linear 0.3s under
        // Reduce Motion), starting at ringStart.
        let from = Double(event.ringFrom) / Double(event.total)
        let to = event.closesRing ? 1.0 : Double(event.ringTo) / Double(event.total)
        let k = TourFeedbackCurves.clamp01((t - Self.ringStart) / ringDuration)
        let eased = reduceMotion ? k : TourFeedbackCurves.cubicBezier(0.2, 0.8, 0.2, 1, at: k)
        f.ringProgress = CGFloat(from + (to - from) * eased)

        // Line width breathes 5.5 -> 6.5 -> 5.5 (spring .30/.60), once.
        if !reduceMotion {
            let breath = TourFeedbackCurves.pulse(t - Self.ringStart, response: 0.30, damping: 0.60)
            f.ringLineWidth = T.ringLineWidth + CGFloat(1.0 * breath)
        }

        // Closing pulse (§8.2): scale 1->1.08->1, width 5.5->7->5.5.
        if event.closesRing, !reduceMotion, t > Self.closingPulseAt {
            let p = TourFeedbackCurves.pulse(t - Self.closingPulseAt, response: T.ringPulseResponse, damping: T.ringPulseDamping)
            f.ringScale = 1 + CGFloat(0.08 * p)
            f.ringLineWidth = T.ringLineWidth + CGFloat(1.5 * p)
        }

        // Number -> check.
        f.numberOpacity = CGFloat(1 - TourFeedbackCurves.clamp01((t - Self.numberFadeStart) / Self.numberFadeDuration))
        let c = t - Self.checkStart
        f.checkOpacity = CGFloat(TourFeedbackCurves.clamp01(c / 0.12))
        f.checkScale = reduceMotion ? 1 : CGFloat(0.6 + 0.4 * TourFeedbackCurves.spring(c, response: Self.checkDuration, damping: 0.55))
        return f
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - The entry point (state machine + ticker)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
final class TourCompletionFeedback: ObservableObject {
    @Published private(set) var frame: TourFeedbackFrame = .rest
    /// True while a completion is on screen (its "done" state included).
    private(set) var isActive = false
    private(set) var lastEvent: TourFeedbackEvent?

    private let clock: () -> TimeInterval
    private let reduceMotion: () -> Bool
    private let autoTick: Bool
    private var startedAt: TimeInterval = 0
    private var timeline: TourFeedbackTimeline?
    private var timer: Timer?
    private let sparks: TourSparkOverlay

    /// `autoTick: false` = the caller (a test) drives time via `advance(to:)`.
    init(clock: @escaping () -> TimeInterval = { CACurrentMediaTime() },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         autoTick: Bool = true,
         sparks: TourSparkOverlay? = nil) {
        self.clock = clock
        self.reduceMotion = reduceMotion
        self.autoTick = autoTick
        self.sparks = sparks ?? TourSparkOverlay()
    }

    /// THE entry point: start the "you finished it" feedback.
    func begin(_ event: TourFeedbackEvent) {
        let rm = reduceMotion()
        timeline = TourFeedbackTimeline(event: event, reduceMotion: rm)
        lastEvent = event
        startedAt = clock()
        isActive = true
        frame = timeline!.frame(at: 0)
        if let origin = event.sparkOriginOnScreen, !rm {
            sparks.play(from: origin)
        }
        if autoTick { startTicker() }
    }

    /// Ticker / test entry: move the animation to absolute clock time `t`.
    func advance(to t: TimeInterval) {
        guard let timeline else { return }
        let elapsed = t - startedAt
        if elapsed >= timeline.duration {
            cancel()
        } else {
            frame = timeline.frame(at: elapsed)
        }
    }

    /// Ends the feedback immediately (next card landed / tour torn down).
    func cancel() {
        timer?.invalidate(); timer = nil
        timeline = nil
        isActive = false
        frame = .rest
        sparks.stop()
    }

    private func startTicker() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(to: self?.clock() ?? 0) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var debugSparkOverlay: TourSparkOverlay { sparks }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Views (draw a Frame)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The continuous progress ring (§4.7): outer diameter 28, line 5.5, round
/// cap, 12 o'clock clockwise. Centerline radius is FIXED at (28-5.5)/2 so the
/// breathing line width grows the stroke outward/inward around one circle,
/// exactly like the storyboard's SVG.
struct TourFeedbackRing: View {
    var completed: Int
    var total: Int = 7
    /// A finished ring (the finale): full circle with the check inside.
    var closed: Bool = false
    var stepLabel: String = ""
    var palette: TourCardPalette
    @ObservedObject var feedback: TourCompletionFeedback

    private var diameter: CGFloat { TourMotionPolicy.Tokens.ringOuterDiameter }
    private var baseLine: CGFloat { TourMotionPolicy.Tokens.ringLineWidth }

    var body: some View {
        let f = feedback.frame
        let staticProgress: CGFloat = closed ? 1 : (total > 0 ? CGFloat(completed) / CGFloat(total) : 0)
        let progress = f.ringProgress ?? staticProgress
        let radius = (diameter - baseLine) / 2
        // The static closed ring shows the check; a step's ring shows it only
        // once the feedback has swapped the number out.
        let checkOpacity = closed && f.ringProgress == nil ? 1 : f.checkOpacity
        let numberOpacity = closed && f.ringProgress == nil ? 0 : f.numberOpacity

        ZStack {
            Circle()
                .stroke(palette.ringTrack, lineWidth: f.ringLineWidth)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .trim(from: 0, to: max(progress, 0.0001))
                .stroke(palette.accent, style: StrokeStyle(lineWidth: f.ringLineWidth, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .rotationEffect(.degrees(-90))
                .opacity(progress > 0 ? 1 : 0)
            Text(stepLabel)
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .tracking(-0.2)
                .foregroundStyle(palette.accentInk)
                .opacity(numberOpacity)
                .offset(y: (1 - numberOpacity) * -6)
            TourCheckGlyph(color: palette.accent, lineWidth: 2.6)
                .frame(width: 12, height: 12)
                .scaleEffect(f.checkScale * (0.6 + 0.4 * checkOpacity))
                .opacity(checkOpacity)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(f.ringScale)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(closed ? "已完成" : "第 \(stepLabel) 步，共 \(total) 步")
    }
}

/// The 14pt beat circle: outline -> solid accent with a white check.
struct TourFeedbackBeatDot: View {
    var index: Int
    var checked: Bool
    var palette: TourCardPalette
    @ObservedObject var feedback: TourCompletionFeedback

    var body: some View {
        let beat = feedback.frame.beats[index]
        let fill = beat?.fill ?? (checked ? 1 : 0)
        let size = TourCardMetrics.beatDot
        ZStack {
            Circle().strokeBorder(palette.track.opacity(1) , lineWidth: 1.5)
                .opacity(1 - fill)
            Circle().strokeBorder(palette.accent, lineWidth: 1.5).opacity(fill)
            Circle().fill(palette.accent).opacity(fill)
            TourCheckGlyph(color: .white, lineWidth: 2.6)
                .frame(width: 8, height: 8)
                .opacity(fill)
        }
        .frame(width: size, height: size)
        .scaleEffect(beat?.scale ?? 1)
    }
}

/// A round-capped check mark path (storyboard `G.check` / `checkS`).
struct TourCheckGlyph: View {
    var color: Color
    var lineWidth: CGFloat
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                p.move(to: CGPoint(x: w * 0.10, y: h * 0.54))
                p.addLine(to: CGPoint(x: w * 0.40, y: h * 0.84))
                p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.22))
            }
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * geo.size.width / 12, lineCap: .round, lineJoin: .round))
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Sparks (click-through overlay window)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// 16 sparks from the ring's center (§8.1). The particles fly outside the
/// card, so they get their own transparent click-through window. The field
/// is built in WINDOW-LOCAL, y-down coordinates (the first version fed
/// screen coordinates to a window-local canvas: nothing was ever visible).
@MainActor
final class TourSparkOverlay {
    static let radius: CGFloat = 96

    private(set) var window: TourCelebrationWindow?
    private(set) var field: TourParticleField?
    private(set) var originInWindow: CGPoint?
    private var hideWork: DispatchWorkItem?

    /// `birth` is on the `Date().timeIntervalSinceReferenceDate` base that the
    /// live `TourSparkView` reads (tests render at `birth + dt` explicitly).
    private(set) var birth: TimeInterval = 0

    func play(from screenPoint: CGPoint) {
        let frame = NSRect(x: screenPoint.x - Self.radius, y: screenPoint.y - Self.radius,
                           width: Self.radius * 2, height: Self.radius * 2)
        let local = CGPoint(x: Self.radius, y: Self.radius)
        birth = Date().timeIntervalSinceReferenceDate
        let field = TourParticleField.sparks(origin: local, at: birth)
        self.field = field
        originInWindow = local
        let window = self.window ?? TourCelebrationWindow()
        self.window = window
        window.contentView = TourHostingView(rootView: TourSparkView(field: field, startTime: birth))
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TourMotionPolicy.Tokens.sparkLifetime + 0.1, execute: work)
    }

    func stop() {
        hideWork?.cancel(); hideWork = nil
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        field = nil
    }
}

/// Renders a spark field at a given time (`now` nil = live clock). Sparks:
/// 60% accent pink, 40% white (§4.7).
struct TourSparkView: View {
    let field: TourParticleField
    let startTime: TimeInterval
    var now: TimeInterval?
    var palette: TourCardPalette = .light

    var body: some View {
        if let now {
            canvas(at: now)
        } else {
            TimelineView(.animation) { timeline in
                canvas(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func canvas(at time: TimeInterval) -> some View {
        Canvas { context, _ in
            let current = field.advanced(to: time, drag: 0.88)
            for p in current.particles {
                let alpha = current.opacity(of: p, at: time, fadeFraction: 0.4)
                guard alpha > 0 else { continue }
                var gc = context
                gc.opacity = alpha
                let rect = CGRect(x: p.x - p.size / 2, y: p.y - p.size / 2, width: p.size, height: p.size)
                gc.fill(Path(ellipseIn: rect), with: .color(p.colorIsAccent ? palette.accent : .white))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
