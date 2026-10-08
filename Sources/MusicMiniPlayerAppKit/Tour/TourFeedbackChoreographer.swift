/**
 * [INPUT]: Foundation only (no SwiftUI, no AppKit, no real clock, no window).
 *          MusicMiniPlayerCore's TourHaptic.
 * [OUTPUT]: Exports TourFeedbackChoreographer (the "you finished it" state
 *           machine: cue table, retargetable springs, particles), the value
 *           types it produces (TourFeedbackFrame, TourFXSnapshot) and the
 *           inputs it takes (TourFeedbackEvent, TourFXGeometry), plus the
 *           seeded/system random sources and easing helpers.
 * [POS]: MusicMiniPlayerAppKit/Tour. A line-for-line port of the motion
 *        prototype's section B (docs/design/2026-09-29-motion-prototype/
 *        prototype.html + spec.md §B): one `Val` per animated property,
 *        each either a tween (cubic-bezier) or a spring that can be
 *        RETARGETED mid-flight without losing velocity; a cue list keyed on
 *        the sequence clock; `interrupt()` fast-forwards state cues and drops
 *        decoration. The same numbers, the same order of operations, the same
 *        random-call order, so a fake clock stepped exactly like the
 *        prototype's `__proto.advance()` reproduces the prototype frame for
 *        frame (that is how the comparison sheets were made).
 *
 * The celebration moment (spec §B.10, founder 2026-10-01): with `celebrationEnabled` a ring-growing completion turns the
 * CARD into the celebration canvas. Two more values (`blur`: the content blurs, dims and shrinks a hair; `lift`: the ring
 * grows from its corner to the card's centre) ride on B.2 / B.3 exactly as they are: the same cues, the same numbers, the
 * same handoff `H` (760 / 1050 ms). The ring flies back as the handoff starts and the blur lets go AFTER the next content
 * has swapped in, so what the unblur reveals is the next step.
 *
 * The choreographer never draws. Views read `makeFrame()` / `makeFXSnapshot()`.
 */

import Foundation
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Easing (prototype `E`, `springPos`)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourFeedbackEase {
    case out, `in`, io, lin, ease

    func value(_ t: Double) -> Double {
        switch self {
        case .out: return Self.bezier(0.2, 0.8, 0.2, 1, t)
        case .in: return Self.bezier(0.4, 0, 1, 1, t)
        case .io: return Self.bezier(0.42, 0, 0.58, 1, t)
        case .ease: return Self.bezier(0.25, 0.1, 0.25, 1, t)
        case .lin: return min(max(t, 0), 1)
        }
    }

    /// The prototype's 22-step bisection on x(u), y read at the last midpoint.
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, u = t
        for _ in 0..<22 {
            u = (lo + hi) / 2
            let x = 3 * pow(1 - u, 2) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            if x < t { lo = u } else { hi = u }
        }
        return 3 * pow(1 - u, 2) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Celebration tokens (spec §B.10)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourCelebrationTokens {
    /// The big ring's outer diameter, points (the card's ring is 28).
    static let ringDiameter = 80.0
    static var ringZoom: Double { ringDiameter / 28 }
    /// The shock-wave halos stay inside a short card: 2x, not the ring's 2.86x.
    static let haloZoom = 2.0
    /// Content blur radius, points, at `blur == 1`.
    static let blurRadius = 10.0
    /// Content opacity is `1 - dim * blur`; the quiet variants (Reduce Transparency / Reduce Motion) dim harder instead of blurring.
    static let dim = 0.38
    static let dimQuiet = 0.55
    /// Content scale is `1 - (1 - contentScale) * blur`.
    static let contentScale = 0.98
    static let fadeIn = 0.18
    /// The ring's take-off spring.
    static let liftSpringDuration = 0.4
    static let liftSpringBounce = 0.18
    /// After the content swap the blur lets go over this long; the ring flies home over `liftOut` from the handoff.
    static let release = 0.26
    static let liftOut = 0.34
    static let reducedIn = 0.12
    static let reducedOut = 0.16
    /// A click on the card starts the handoff this soon.
    static let earlyHandoff = 0.02
    /// The card's own ring sits at (body width - `slotInsetX`, `slotInsetY`): padding + the ring's radius (TourCardMetrics:
    /// the app's padding is 14, the prototype's CSS 16).
    static let ringRadius = 14.0
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Random
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

protocol TourFeedbackRandom: AnyObject {
    /// Uniform in [0, 1).
    func next() -> Double
}

final class TourSystemRandom: TourFeedbackRandom {
    func next() -> Double { Double.random(in: 0..<1) }
}

/// mulberry32 — the same generator the comparison script installs as
/// `Math.random` in the prototype, so both sides draw identical particles.
final class TourSeededRandom: TourFeedbackRandom {
    private var state: UInt32
    /// How many numbers were drawn (lets a test compare consumption with the prototype's).
    private(set) var draws = 0
    init(seed: UInt32) { state = seed }
    func next() -> Double {
        draws += 1
        state = state &+ 0x6D2B79F5
        var t = state
        t = (t ^ (t >> 15)) &* (1 | t)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Animated value (prototype `Val`)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourSequenceClock {
    var now: Double = 0
}

/// One animated property. `to(...)` REPLACES whatever it was doing; a spring
/// keeps position and velocity across the retarget (spec §B.4 rule 1).
final class TourFeedbackValue {
    private enum Motion {
        case tween(from: Double, to: Double, t0: Double, d: Double, ease: TourFeedbackEase, started: Bool)
        case spring(to: Double, t0: Double, dur: Double, z: Double)
    }

    private unowned let clock: TourSequenceClock
    private var motion: Motion?
    private(set) var v: Double
    private(set) var vel: Double = 0

    init(_ initial: Double, clock: TourSequenceClock) {
        v = initial
        self.clock = clock
    }

    var isActive: Bool { motion != nil }

    func set(_ x: Double) { v = x; vel = 0; motion = nil }

    @discardableResult
    func to(_ target: Double, dur: Double = 0.3, ease: TourFeedbackEase = .out, delay: Double = 0) -> TourFeedbackValue {
        motion = .tween(from: v, to: target, t0: clock.now + delay, d: dur, ease: ease, started: false)
        return self
    }

    /// `Spring(duration:bounce:)`: omega = 2*pi/duration, zeta = 1 - bounce.
    @discardableResult
    func to(_ target: Double, springDuration: Double, bounce: Double, delay: Double = 0) -> TourFeedbackValue {
        motion = .spring(to: target, t0: clock.now + delay, dur: springDuration, z: 1 - min(max(bounce, 0), 0.95))
        return self
    }

    func step(_ dt: Double) {
        guard let m = motion else { return }
        switch m {
        case .tween(let from0, let target, let t0, let d, let ease, let started):
            if clock.now < t0 { return }
            var from = from0
            if !started { from = v }
            let p = min(max((clock.now - t0) / d, 0), 1)
            v = from + (target - from) * ease.value(p)
            if p >= 1 { v = target; motion = nil } else {
                motion = .tween(from: from, to: target, t0: t0, d: d, ease: ease, started: true)
            }
        case .spring(let target, let t0, let dur, let z):
            if clock.now < t0 { return }
            let w = 2 * Double.pi / dur, k = w * w, c = 2 * z * w
            var left = dt
            let h = 1.0 / 240.0
            while left > 1e-9 {
                let s = min(h, left)
                let a = -k * (v - target) - c * vel
                vel += a * s
                v += vel * s
                left -= s
            }
            if abs(v - target) < 1e-4 && abs(vel) < 1e-3 { v = target; vel = 0; motion = nil }
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Inputs
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// What just happened, in the tour's own terms.
struct TourFeedbackEvent: Equatable {
    /// Steps completed before / after (0...total). Equal = a beat only.
    var ringFrom: Int
    var ringTo: Int
    var total: Int = TourStep.orderedSteps.count
    /// Beat dots (indices on the CURRENT card) that just turned solid.
    var beatIndices: [Int] = []
    /// The last segment: the ring closes into a solid disc (spec §B.3).
    var closesRing: Bool = false
    /// Confetti (the finale).
    var confetti: Bool = false
    /// Sparks at the arc head (ordinary steps; the closing seal has none).
    var sparks: Bool = true
    /// The controller swaps the card content after this sequence (next step
    /// card or the finale card); the choreographer runs the handoff around it.
    var handsOff: Bool = false
    /// Screen points / rects (AppKit, y up) the FX window is built around.
    var ringCenterOnScreen: CGPoint?
    var cardFrameOnScreen: CGRect?

    var growsRing: Bool { ringTo > ringFrom || closesRing }
}

/// Where the particles live: the FX window's own coordinate space (y down).
struct TourFXGeometry: Equatable {
    var ringCenter: CGPoint
    var cardTop: Double
    var cardCenterX: Double
    /// The prototype sizes everything by the stage zoom (card is shown 1.55x);
    /// in the app the card is 1x.
    var zoom: Double = 1
    /// Confetti's own scale (celebration: the ring is 2.86x, the confetti stays 1x); nil = `zoom` with the ring's live pop.
    var confettiZoom: Double?
    /// The shock-wave halo's own scale (celebration: 2x, so the circle stays inside the card's height); nil = `zoom`.
    var haloZoom: Double?
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Outputs
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TourFeedbackBeatFrame: Equatable {
    /// Solid-disc radius as a 0...1 fraction of 6.9pt.
    var fill: Double
    /// Check-stroke draw progress, 0...1.
    var draw: Double
    var scale: Double
    /// 0 = ink text colour, 1 = muted (the row turns secondary once done).
    var textMix: Double
}

/// Everything the views draw at one instant. `.rest` = "draw the card's
/// static model" (nothing is animating).
struct TourFeedbackFrame: Equatable {
    var isActive = false
    /// Ring arc in STEPS (0...total); nil = use the card's static progress.
    var ringProgress: Double?
    /// Ring speed in steps/s (drives the comet highlight).
    var ringVelocity = 0.0
    var ringLineWidth = 5.5
    var ringScale = 1.0
    var numberOpacity = 1.0
    var numberScale = 1.0
    var numberOffsetY = 0.0
    var checkDraw = 0.0
    var checkScale = 0.6
    /// Solid centre disc radius as a 0...1.05 fraction of the 11.25pt path radius.
    var disc = 0.0
    /// White flash on the closing ring, 0...1.
    var seal = 0.0
    /// Whole-card bounce (finale), points, negative = up.
    var cardOffsetY = 0.0
    /// Title / body / everything-below opacity + offset (handoff).
    var contentOpacity: [Double] = [1, 1, 1]
    var contentOffsetY: [Double] = [0, 0, 0]
    /// Celebration moment (spec §B.10): 0...1, how far the card's content is blurred / dimmed / shrunk, and how far the ring
    /// has flown from its corner to the card's centre (and grown to 80 pt).
    var blur = 0.0
    var lift = 0.0
    /// Reduce Transparency / Reduce Motion: dim instead of blur, no scale.
    var celebrationQuiet = false
    /// True while the card is the celebration canvas (blur or lift not yet back at 0).
    var isCelebrating: Bool { blur > 0.002 || lift > 0.002 }
    var beats: [Int: TourFeedbackBeatFrame] = [:]
    /// Bumps each time the card content was swapped under the sequence.
    var swapGeneration = 0

    static let rest = TourFeedbackFrame()
}

enum TourFXColor: Equatable { case accent, soft, gold, violet, mint, white }

struct TourFXParticle: Equatable {
    enum Kind { case spark, confetti }
    var kind: Kind
    var x: Double, y: Double, vx: Double, vy: Double
    var life: Double, age: Double
    var r = 0.0              // spark radius
    var w = 0.0, h = 0.0     // confetti box
    var shape = 0, rot = 0.0, vr = 0.0
    var color: TourFXColor
    var damp = 0.88, gravity = 0.0
}

struct TourFXHalo: Equatable {
    var x: Double, y: Double, z: Double
    var age: Double, life: Double
}

struct TourFXSnapshot: Equatable {
    var particles: [TourFXParticle] = []
    var halos: [TourFXHalo] = []
    var isEmpty: Bool { particles.isEmpty && halos.isEmpty }
    static let empty = TourFXSnapshot()
}

enum TourFeedbackPhase: String, Equatable {
    case idle, anticipate, draw, grow, sparks, settle, handoff, seal, confetti
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Choreographer
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourFeedbackChoreographer {
    typealias Ease = TourFeedbackEase

    private struct Cue {
        var id = 0
        var at: Double
        var essential: Bool
        var tag: String?
        var fn: (Bool) -> Void
    }

    private final class BeatValues {
        let fill: TourFeedbackValue, scale: TourFeedbackValue, draw: TourFeedbackValue, text: TourFeedbackValue
        init(clock: TourSequenceClock) {
            fill = TourFeedbackValue(0, clock: clock)
            scale = TourFeedbackValue(1, clock: clock)
            draw = TourFeedbackValue(0, clock: clock)
            text = TourFeedbackValue(0, clock: clock)
        }
        var all: [TourFeedbackValue] { [fill, scale, draw, text] }
    }

    // Configuration -------------------------------------------------------
    var reduceMotion: Bool
    var geometry: TourFXGeometry?
    /// Called at the frame the old content has faded out and the controller
    /// must swap the card. nil = swap immediately (comparison harness).
    var onSwapDue: (() -> Void)?
    /// Fires at the start of the handoff (spec C.3 "H"): the old content is about
    /// to fade, the ring and the card should start their own transition. Called
    /// once per handoff, before the content starts fading.
    var onHandoffStart: (() -> Void)?
    /// A controller owns the card swap (it will call `cardDidSwap()` itself, its own
    /// timer being the fallback). false = the comparison harness, which swaps at once.
    var ownsSwap = false
    var haptic: (TourHaptic) -> Void
    /// Spec §B.10: ring-growing completions turn the card into the celebration canvas (the shell turns this on; the comparison
    /// harness leaves it off and keeps the prototype's B.2 / B.3 frames).
    var celebrationEnabled = false
    /// Reduce Transparency: dim instead of blur (read by the shell at each `begin`).
    var reduceTransparency = false
    /// This sequence celebrates (decided at `begin`).
    private(set) var celebrating = false
    /// A new celebration is about to follow the one being interrupted: the interrupted one must not let go.
    private var keepCelebration = false
    private let random: TourFeedbackRandom

    // Clock / cues --------------------------------------------------------
    private let clock = TourSequenceClock()
    private var cues: [Cue] = []
    private(set) var now: Double { get { clock.now } set { clock.now = newValue } }

    // Sequence state ------------------------------------------------------
    private(set) var busy = false
    private(set) var finished = false
    private(set) var phase: TourFeedbackPhase = .idle
    private(set) var swapGeneration = 0
    private var combo = 0
    private var lastCompletionWall = -99.0
    private var seqStart = 0.0
    private var closingRunning = false
    private var ringEngaged = false
    private var swapPending = false     // a handoff is scheduled and not yet swapped
    private var awaitingSwap = false    // fade-out done, controller has to swap
    private var swapFin = false
    private(set) var event: TourFeedbackEvent?
    /// (ms since sequence start, phase) — test/diagnostic log.
    private(set) var phaseLog: [(ms: Int, phase: TourFeedbackPhase)] = []
    /// (ms since sequence start, haptic).
    private(set) var hapticLog: [(ms: Int, kind: TourHaptic)] = []

    // Values --------------------------------------------------------------
    private let ring: TourFeedbackValue, ringScale: TourFeedbackValue, ringW: TourFeedbackValue
    private let numOp: TourFeedbackValue, numScale: TourFeedbackValue, numY: TourFeedbackValue
    private let chkDraw: TourFeedbackValue, chkScale: TourFeedbackValue
    private let disc: TourFeedbackValue, seal: TourFeedbackValue, cardY: TourFeedbackValue
    private let blur: TourFeedbackValue, lift: TourFeedbackValue
    private let contentOp: [TourFeedbackValue], contentY: [TourFeedbackValue]
    private var beats: [Int: BeatValues] = [:]

    private var particles: [TourFXParticle] = []
    private var halos: [TourFXHalo] = []

    static let restLineWidth = 5.5
    static let ringPathRadius = 11.25

    init(reduceMotion: Bool = false, random: TourFeedbackRandom = TourSystemRandom(),
         haptic: @escaping (TourHaptic) -> Void = { _ in }) {
        self.reduceMotion = reduceMotion
        self.random = random
        self.haptic = haptic
        let c = clock
        ring = TourFeedbackValue(0, clock: c)
        ringScale = TourFeedbackValue(1, clock: c)
        ringW = TourFeedbackValue(Self.restLineWidth, clock: c)
        numOp = TourFeedbackValue(1, clock: c)
        numScale = TourFeedbackValue(1, clock: c)
        numY = TourFeedbackValue(0, clock: c)
        chkDraw = TourFeedbackValue(0, clock: c)
        chkScale = TourFeedbackValue(0.6, clock: c)
        disc = TourFeedbackValue(0, clock: c)
        seal = TourFeedbackValue(0, clock: c)
        cardY = TourFeedbackValue(0, clock: c)
        blur = TourFeedbackValue(0, clock: c)
        lift = TourFeedbackValue(0, clock: c)
        contentOp = (0..<3).map { _ in TourFeedbackValue(1, clock: c) }
        contentY = (0..<3).map { _ in TourFeedbackValue(0, clock: c) }
    }

    // MARK: Queries

    var isActive: Bool {
        busy || !cues.isEmpty || awaitingSwap || !particles.isEmpty || !halos.isEmpty
            || allValues.contains { $0.isActive }
    }

    /// The controller still has to swap the card under a running sequence.
    var expectsSwap: Bool { isActive && (swapPending || awaitingSwap) }

    /// The sequence is the ring-closing one (not interruptible, spec §B.4-4).
    var isClosing: Bool { busy && closingRunning }

    private var allValues: [TourFeedbackValue] {
        [ring, ringScale, ringW, numOp, numScale, numY, chkDraw, chkScale, disc, seal, cardY, blur, lift]
            + contentOp + contentY + beats.values.flatMap(\.all)
    }

    // MARK: Cue plumbing

    private var nextCueId = 0

    private func cue(_ at: Double, essential: Bool = true, tag: String? = nil, _ fn: @escaping (Bool) -> Void) {
        nextCueId += 1
        cues.append(Cue(id: nextCueId, at: now + at, essential: essential, tag: tag, fn: fn))
    }

    private func enter(_ p: TourFeedbackPhase) {
        phase = p
        phaseLog.append((Int(((now - seqStart) * 1000).rounded()), p))
    }

    private func fireHaptic(_ kind: TourHaptic) {
        hapticLog.append((Int(((now - seqStart) * 1000).rounded()), kind))
        haptic(kind)
    }

    // MARK: Entry

    /// Starts the feedback for `event`. `wallNow` is the caller's clock (only
    /// used for the 4-second combo window). Returns false when ignored.
    @discardableResult
    func begin(_ event: TourFeedbackEvent, wallNow: Double) -> Bool {
        if finished { return false }
        if busy && closingRunning { return false }          // §B.4-4
        keepCelebration = celebrationEnabled && event.growsRing
        if busy { interrupt() }
        keepCelebration = false

        self.event = event
        phaseLog = []
        hapticLog = []
        seqStart = now
        let rm = reduceMotion
        let stag = 0.07

        // Beats first: they exist for the beat-only case too.
        let remaining = event.beatIndices
        for i in remaining where beats[i] == nil { beats[i] = BeatValues(clock: clock) }

        if !event.growsRing {
            // Beat only (§B.2 last paragraph): dot + haptic, no ring, no sparks.
            // (the prototype's beat button presses the dot at once, not one frame later)
            for (n, i) in remaining.enumerated() {
                if n == 0 { beatCheck(i) } else { cue(Double(n) * stag) { [unowned self] _ in self.beatCheck(i) } }
            }
            if rm { cue(0, essential: false) { [unowned self] _ in self.fireHaptic(.levelChange) } }
            else { cue(0.06, essential: false) { [unowned self] _ in self.fireHaptic(.levelChange) } }
            return true
        }

        let chain = wallNow - lastCompletionWall < 4.0
        combo = chain ? min(combo + 1, 3) : 0
        lastCompletionWall = wallNow

        busy = true
        closingRunning = event.closesRing
        celebrating = celebrationEnabled
        if celebrating { startCelebration() }
        let wasEngaged = ringEngaged
        ringEngaged = true
        // A fresh burst starts the ring where the card says it is; an
        // interrupted burst keeps position AND velocity (spec §B.4-1).
        if !wasEngaged { ring.set(Double(event.ringFrom)) }
        for (n, i) in remaining.enumerated() { cue(Double(n) * stag) { [unowned self] _ in self.beatCheck(i) } }
        let t0 = max(0, Double(remaining.count - 1) * stag)
        runRing(event: event, t0: t0)
        return true
    }
    // MARK: Beats (prototype `beatCheck`)

    private func beatCheck(_ i: Int) {
        guard let b = beats[i] else { return }
        b.text.to(1, dur: 0.2, ease: .ease)                                   // row text -> muted, 0.2s
        if reduceMotion { b.fill.set(1); b.draw.set(1); b.scale.set(1); return }
        b.scale.to(0.88, dur: 0.06, ease: .out)                               // anticipate: press down
        cue(0.06) { _ in
            b.scale.to(1.22, dur: 0.09, ease: .out)
            b.fill.to(1, dur: 0.14, ease: .out)
            b.draw.to(1, dur: 0.26, ease: .out)
        }
        cue(0.15) { _ in b.scale.to(1, springDuration: 0.30, bounce: 0.42) }  // spring back
    }

    // MARK: Ring sequence (prototype `runRing`)

    private func runRing(event: TourFeedbackEvent, t0: Double) {
        let target = Double(event.ringTo)
        let total = Double(event.total)
        let last = event.closesRing
        if reduceMotion { return runRingReduced(event: event, t0: t0) }

        cue(t0) { [unowned self] _ in
            self.enter(.anticipate)
            self.ringScale.to(0.95, dur: 0.06, ease: .out)
            self.numOp.to(0.6, dur: 0.06, ease: .out)
        }
        cue(t0 + 0.06, essential: false) { [unowned self] _ in self.enter(.draw); self.fireHaptic(.levelChange) }
        cue(t0 + 0.06) { [unowned self] _ in
            self.enter(.grow)
            self.ring.to(target, springDuration: 0.6, bounce: 0)
            self.ringW.to(6.5, dur: 0.15, ease: .out)
            self.ringScale.to(1.07, dur: 0.18, ease: .out)
        }
        cue(t0 + 0.24) { [unowned self] _ in self.ringScale.to(1, springDuration: 0.45, bounce: 0.35) }
        let tChk = last ? 0.5 : 0.34
        cue(t0 + tChk) { [unowned self] _ in
            self.numOp.to(0, dur: 0.14, ease: .in)
            self.numScale.to(0.5, dur: 0.14, ease: .in)
            self.chkDraw.to(1, dur: 0.28, ease: .out, delay: 0.08)
            self.chkScale.set(0.6)
            self.chkScale.to(1.15, dur: 0.16, ease: .out, delay: 0.08)
            self.cue(0.26) { [unowned self] _ in self.chkScale.to(1, springDuration: 0.32, bounce: 0.45) }
        }

        if !last {
            if event.sparks {
                cue(t0 + 0.38, essential: false) { [unowned self] _ in
                    self.enter(.sparks)
                    self.spawnSparks(16 + self.combo * 4, progress: target / total)
                    self.spawnHalo()
                }
            }
            cue(t0 + 0.66) { [unowned self] _ in self.enter(.settle); self.ringW.to(5.5, dur: 0.2, ease: .out) }
            if event.confetti {
                cue(t0 + 0.68, essential: false) { [unowned self] _ in
                    self.enter(.confetti)
                    self.spawnConfetti(72)
                    self.spawnHalo()
                }
            }
            if event.handsOff {
                swapPending = true; swapFin = false
                cue(t0 + 0.76, tag: "handoff") { [unowned self] ff in self.handoff(fin: false, ff: ff) }
                cue(t0 + 1.1, tag: "finish") { [unowned self] _ in self.finishBusy() }
            } else {
                cue(t0 + 0.86, tag: "settleOut") { [unowned self] _ in self.revertCheckToNumber(); self.releaseCelebration() }
                cue(t0 + 1.1, tag: "finish") { [unowned self] _ in self.finishBusy() }
            }
        } else {
            cue(t0 + 0.60) { [unowned self] _ in
                self.enter(.seal)
                self.fireHaptic(.alignment)
                self.ringScale.set(1.08)
                self.ringScale.to(1, springDuration: 0.5, bounce: 0.38)
                self.ringW.to(7, dur: 0.12, ease: .out)
                self.cue(0.12) { [unowned self] _ in self.ringW.to(5.5, dur: 0.22, ease: .out) }
                self.seal.set(1)
                self.seal.to(0, dur: 0.35, ease: .out)
            }
            cue(t0 + 0.64) { [unowned self] _ in self.disc.to(1, springDuration: 0.4, bounce: 0.25) }
            if event.confetti {
                cue(t0 + 0.68, essential: false) { [unowned self] _ in
                    self.enter(.confetti)
                    self.spawnConfetti(72)
                    self.spawnHalo()
                    self.spawnHalo(delay: 0.12)
                    self.cardY.set(-4)
                    self.cardY.to(0, springDuration: 0.4, bounce: 0.3)
                }
            } else {
                cue(t0 + 0.68, essential: false) { [unowned self] _ in self.spawnHalo() }
            }
            if event.handsOff {
                swapPending = true; swapFin = true
                cue(t0 + 1.05, tag: "handoff") { [unowned self] ff in self.enter(.settle); self.handoff(fin: true, ff: ff) }
                cue(t0 + 1.5, tag: "finish") { [unowned self] _ in self.finishBusy(finished: true) }
            } else {
                cue(t0 + 1.05, tag: "settleOut") { [unowned self] _ in self.enter(.settle); self.releaseCelebration() }
                cue(t0 + 1.1, tag: "finish") { [unowned self] _ in self.finishBusy(finished: true) }
            }
        }
    }

    /// Spec §B.7 — no scale, no width change, no comet, no particles; linear
    /// fill, opacity swaps, haptics kept.
    private func runRingReduced(event: TourFeedbackEvent, t0: Double) {
        let target = Double(event.ringTo)
        let last = event.closesRing
        cue(t0) { [unowned self] _ in
            self.enter(.draw)
            self.fireHaptic(last ? .alignment : .levelChange)
            self.ring.to(target, dur: 0.3, ease: .lin)
            self.numOp.to(0, dur: 0.16, ease: .lin)
            self.chkScale.set(1)
            // On the big ring the check is simply there (a static check, spec §B.10), not drawn.
            if self.celebrating { self.chkDraw.set(1) } else { self.chkDraw.to(1, dur: 0.16, ease: .lin) }
        }
        if last {
            cue(t0 + 0.3) { [unowned self] _ in
                self.enter(.seal)
                self.seal.set(1)
                self.seal.to(0, dur: 0.35, ease: .lin)
                self.disc.to(1, dur: 0.2, ease: .lin)
            }
        }
        let swapAt = t0 + (last ? 0.7 : 0.5)
        if event.handsOff {
            swapPending = true; swapFin = last
            cue(swapAt, tag: "handoff") { [unowned self] ff in self.handoff(fin: last, ff: ff) }
        } else {
            cue(swapAt, tag: "settleOut") { [unowned self] _ in self.revertCheckToNumber(); self.releaseCelebration() }
        }
        cue(t0 + (last ? 0.95 : 0.8), tag: "finish") { [unowned self] _ in self.finishBusy(finished: last) }
    }

    private func finishBusy(finished done: Bool = false) {
        busy = false
        closingRunning = false
        celebrating = false
        if done { finished = true }
        enter(.idle)
    }

    /// No card swap follows (a step finished out of order): the check goes
    /// back to the step number so the ring does not keep a stale check.
    private func revertCheckToNumber() {
        chkDraw.to(0, dur: 0.2, ease: .in)
        numOp.to(1, dur: 0.2, ease: .out)
        numScale.to(1, dur: 0.2, ease: .out)
        numY.to(0, dur: 0.2, ease: .out)
    }

    // MARK: Handoff (prototype `handoff`)

    private func handoff(fin: Bool, ff: Bool) {
        enter(.handoff)
        // The ring flies back to its corner as the old content fades; the blur waits for the swap (`swapBody`).
        if !keepCelebration, !ff, lift.v > 0.002 || lift.isActive { lift.to(0, dur: reduceMotion ? TourCelebrationTokens.reducedOut : TourCelebrationTokens.liftOut, ease: reduceMotion ? .lin : .io) }
        onHandoffStart?()
        // Fast-forwarded while a controller owns the swap: its own timer
        // delivers the swap and the old content stays visible until then.
        // Without an owner (comparison harness) the prototype's behavior
        // stands: the handoff runs normally (its `ff` argument is ignored there).
        if ff && (ownsSwap || onSwapDue != nil) { return }
        let outD = reduceMotion ? 0.12 : 0.14
        contentOp.forEach { $0.to(0, dur: outD, ease: reduceMotion ? .lin : .in) }
        if !fin && !reduceMotion { chkScale.to(0.7, dur: 0.14, ease: .in) }
        cue(outD, tag: "handoff") { [unowned self] _ in self.requestSwap() }
    }

    private func requestSwap() {
        swapPending = false
        awaitingSwap = true
        // Safety: if the controller never swaps, bring the content back.
        cue(0.5, tag: "swapTimeout") { [unowned self] _ in
            if self.awaitingSwap { self.awaitingSwap = false; self.swapBody(fin: self.swapFin) }
        }
        if let onSwapDue { onSwapDue() } else if !ownsSwap { cardDidSwap() }
    }

    /// The controller swapped the card content. Run the "new content in" half.
    func cardDidSwap() {
        guard swapPending || awaitingSwap else { return }
        cues.removeAll { $0.tag == "handoff" || $0.tag == "swapTimeout" }
        awaitingSwap = false
        swapPending = false
        swapBody(fin: swapFin)
    }

    /// Prototype `swap`: new number rolls in (or stays empty on the final
    /// card), the three content blocks stagger in.
    private func swapBody(fin: Bool) {
        swapGeneration += 1
        // The next content is in, still under the blur: let the blur go, so what it reveals is the next step.
        if !keepCelebration, blur.v > 0.002 || blur.isActive {
            blur.to(0, dur: reduceMotion ? TourCelebrationTokens.reducedOut : TourCelebrationTokens.release, ease: reduceMotion ? .lin : .io)
            if lift.v > 0.002 || lift.isActive, !lift.isActive { lift.to(0, dur: reduceMotion ? TourCelebrationTokens.reducedOut : TourCelebrationTokens.liftOut, ease: reduceMotion ? .lin : .io) }
        }
        // The dots animated so far belong to the card that just left.
        beats.removeAll()
        let quick = reduceMotion
        if !fin {
            chkDraw.set(0)
            if quick { numOp.set(1); numScale.set(1); numY.set(0) } else {
                numOp.set(0); numScale.set(0.8); numY.set(6)
                numOp.to(1, dur: 0.22, ease: .out)
                numScale.to(1, dur: 0.22, ease: .out)
                numY.to(0, dur: 0.22, ease: .out)
            }
        } else {
            numOp.set(0)
        }
        for i in 0..<3 {
            if reduceMotion {
                // §B.7: the whole card fades back in, 0.16s linear, no offset.
                contentOp[i].set(0); contentY[i].set(0)
                contentOp[i].to(1, dur: 0.16, ease: .lin)
            } else {
                contentOp[i].set(0); contentY[i].set(6)
                contentOp[i].to(1, dur: 0.18, ease: .out, delay: Double(i) * 0.04)
                contentY[i].to(0, dur: 0.18, ease: .out, delay: Double(i) * 0.04)
            }
        }
    }

    // MARK: Interrupt (spec §B.4)

    /// Fast-forward state cues, drop decoration, keep the ring's speed.
    func interrupt() {
        let list = Self.ordered(cues)
        cues.removeAll()
        for c in list where c.essential { runCueFF(c) }
        busy = false
        closingRunning = false
        ringW.to(5.5, dur: 0.1, ease: .out)
        // While the controller still owes a card swap the ring is showing its
        // check, not the number: leave the number alone (else both overlap).
        if !swapPending { numOp.set(1); numScale.set(1); numY.set(0) }
        ringScale.to(1, springDuration: 0.3, bounce: 0)
        // Particles already in flight are left to die on their own (§B.4-2:
        // only cues that have not happened yet are dropped).
    }

    /// Stable order by fire time (ties keep insertion order).
    private static func ordered(_ list: [Cue]) -> [Cue] {
        list.enumerated().sorted { a, b in a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset }.map(\.element)
    }

    /// Runs a cue now; sub-cues it registers run right after (essential only).
    private func runCueFF(_ c: Cue) {
        let startId = nextCueId + 1
        c.fn(true)
        let kids = cues.filter { $0.id >= startId }
        cues.removeAll { $0.id >= startId }
        for k in Self.ordered(kids) where k.essential { runCueFF(k) }
    }

    // MARK: Celebration (spec §B.10)

    private func startCelebration() {
        let rm = reduceMotion
        blur.to(1, dur: rm ? TourCelebrationTokens.reducedIn : TourCelebrationTokens.fadeIn, ease: rm ? .lin : .out)
        if rm { lift.to(1, dur: TourCelebrationTokens.reducedIn, ease: .lin) }
        else { lift.to(1, springDuration: TourCelebrationTokens.liftSpringDuration, bounce: TourCelebrationTokens.liftSpringBounce) }
    }

    /// A sequence with no card swap to wait for (a step finished out of order): ring and blur let go together.
    private func releaseCelebration() {
        guard blur.v > 0.002 || blur.isActive || lift.v > 0.002 || lift.isActive else { return }
        let rm = reduceMotion
        blur.to(0, dur: rm ? TourCelebrationTokens.reducedOut : TourCelebrationTokens.release, ease: rm ? .lin : .io)
        lift.to(0, dur: rm ? TourCelebrationTokens.reducedOut : TourCelebrationTokens.liftOut, ease: rm ? .lin : .io)
    }

    /// A click on the card ends the moment early (spec §B.10): the handoff starts right away instead of at its planned time and
    /// the decoration that has not happened yet (sparks, confetti) is dropped. The ring flying home, the blur letting go and
    /// the next content fading in follow as usual.
    func endCelebrationEarly() {
        guard celebrating, busy else { return }
        let moved: Set<String> = ["handoff", "settleOut", "finish"]
        if let planned = cues.filter({ moved.contains($0.tag ?? "") }).map(\.at).min() {
            let delta = (now + TourCelebrationTokens.earlyHandoff) - planned
            if delta < 0 { for i in cues.indices where moved.contains(cues[i].tag ?? "") { cues[i].at += delta } }
        }
        cues.removeAll { !$0.essential && $0.at > now }
    }

    func reduceMotionChanged(to value: Bool) {
        guard value != reduceMotion else { return }
        if busy { interrupt() }
        reduceMotion = value
    }

    // MARK: FX spawning (prototype `spawnSparks/Halo/Confetti`)

    private func colors(_ list: [TourFXColor], _ i: Int) -> TourFXColor { list[i % list.count] }

    private func spawnSparks(_ n: Int, progress: Double) {
        guard !reduceMotion, let g = geometry else { return }
        let z = g.zoom * ringScale.v   // the prototype measures the LIVE ring, pop scale included
        let ang = -Double.pi / 2 + 2 * Double.pi * progress
        let rr = Self.ringPathRadius * z
        let hx = Double(g.ringCenter.x) + cos(ang) * rr, hy = Double(g.ringCenter.y) + sin(ang) * rr
        let cols: [TourFXColor] = [.accent, .accent, .soft, .gold]
        for i in 0..<n {
            let a = ang + (random.next() - 0.5) * Double.pi * 1.7
            let sp = (90 + random.next() * 60) * z * 1.0
            let r = (2 + random.next() * 1.5) * z * 0.8
            particles.append(TourFXParticle(kind: .spark, x: hx, y: hy, vx: cos(a) * sp, vy: sin(a) * sp,
                                            life: 0.55, age: 0, r: r, color: colors(cols, i), damp: 0.88))
        }
    }

    private func spawnHalo(delay: Double = 0) {
        guard !reduceMotion, let g = geometry else { return }
        let z = (g.haloZoom ?? g.zoom) * ringScale.v   // the prototype measures the LIVE ring, pop scale included
        halos.append(TourFXHalo(x: Double(g.ringCenter.x), y: Double(g.ringCenter.y), z: z, age: -delay, life: 0.5))
    }

    private func spawnConfetti(_ n: Int) {
        guard !reduceMotion, let g = geometry else { return }
        // (celebration: the card did not grow, the confetti keeps its 1x scale while the sparks follow the big ring)
        let z = g.confettiZoom ?? (g.zoom * ringScale.v)   // the prototype measures the LIVE ring, pop scale included
        let cols: [TourFXColor] = [.accent, .gold, .violet, .mint, .soft, .white]
        for i in 0..<n {
            let a = -Double.pi / 2 + (random.next() - 0.5) * (Double.pi / 3)
            let sp = (220 + random.next() * 100) * z * 0.8
            let x = g.cardCenterX + (random.next() - 0.5) * 120 * z
            let w = (5 + random.next() * 2) * z * 0.8
            let h = (7 + random.next() * 4) * z * 0.8
            let rot = random.next() * 6.28
            let vr = (random.next() - 0.5) * 5
            particles.append(TourFXParticle(kind: .confetti, x: x, y: g.cardTop + 8, vx: cos(a) * sp, vy: sin(a) * sp,
                                            life: 1.8, age: 0, w: w, h: h, shape: i % 3, rot: rot, vr: vr,
                                            color: colors(cols, i), damp: 0.985, gravity: 360 * z * 0.8))
        }
    }

    private func stepFX(_ dt: Double) {
        var alive: [TourFXParticle] = []
        alive.reserveCapacity(particles.count)
        for var p in particles {
            p.age += dt
            guard p.age < p.life else { continue }
            let f = pow(p.damp, dt * 60)
            if p.kind == .spark {
                p.vx *= f; p.vy *= f
                p.x += p.vx * dt; p.y += p.vy * dt
            } else {
                p.vy += p.gravity * dt
                p.vx *= f; p.vy *= f
                p.x += p.vx * dt; p.y += p.vy * dt
                p.rot += p.vr * dt
            }
            alive.append(p)
        }
        particles = alive
        halos = halos.compactMap { h in
            var h = h
            h.age += dt
            return h.age < h.life ? h : nil
        }
    }

    // MARK: Stepping

    /// One simulation step of `dt` seconds (prototype `users[0]`).
    func step(_ dt: Double) {
        now += dt
        var guardCount = 0
        while guardCount < 200 {
            guardCount += 1
            guard let idx = cues.indices.filter({ cues[$0].at <= now + 1e-9 }).min(by: { cues[$0].at < cues[$1].at }) else { break }
            let due = cues.remove(at: idx)
            due.fn(false)
        }
        for v in allValues { v.step(dt) }
        stepFX(dt)
        if !isActive { settleToRest() }
    }

    /// Advances by `seconds` in steps of at most `maxStep` (the prototype's
    /// `advance()` uses 1/60).
    func advance(by seconds: Double, maxStep: Double = 1.0 / 60.0) {
        var t = 0.0
        while t < seconds - 1e-9 {
            let d = min(maxStep, seconds - t)
            step(d)
            t += d
        }
    }

    /// Everything finished: hand the views back to the card's static model.
    private func settleToRest() {
        if ringEngaged || !beats.isEmpty {
            ringEngaged = false
            beats.removeAll()
        }
        swapPending = false
        awaitingSwap = false
        if phase != .idle { phase = .idle }
    }

    /// Full reset (card gone / tour torn down). Keeps configuration.
    func reset() {
        cues.removeAll(); particles.removeAll(); halos.removeAll(); beats.removeAll()
        busy = false; finished = false; closingRunning = false; ringEngaged = false
        swapPending = false; awaitingSwap = false; combo = 0; lastCompletionWall = -99
        ring.set(0); ringScale.set(1); ringW.set(Self.restLineWidth)
        numOp.set(1); numScale.set(1); numY.set(0)
        chkDraw.set(0); chkScale.set(0.6); disc.set(0); seal.set(0); cardY.set(0); blur.set(0); lift.set(0)
        celebrating = false
        contentOp.forEach { $0.set(1) }; contentY.forEach { $0.set(0) }
        phase = .idle
        event = nil
    }

    // MARK: Output

    func makeFrame() -> TourFeedbackFrame {
        guard isActive || ringEngaged || !beats.isEmpty else { return .rest }
        var f = TourFeedbackFrame()
        f.isActive = true
        if ringEngaged {
            f.ringProgress = ring.v
            f.ringVelocity = abs(ring.vel)
            f.ringLineWidth = ringW.v
            f.ringScale = ringScale.v
            f.numberOpacity = min(max(numOp.v, 0), 1)
            f.numberScale = numScale.v
            f.numberOffsetY = numY.v
            f.checkDraw = min(max(chkDraw.v, 0), 1)
            f.checkScale = chkScale.v
            f.disc = min(max(disc.v, 0), 1.05)
            f.seal = seal.v
            f.cardOffsetY = cardY.v
            f.blur = min(max(blur.v, 0), 1)
            f.lift = lift.v
            f.celebrationQuiet = reduceMotion || reduceTransparency
            f.contentOpacity = contentOp.map { min(max($0.v, 0), 1) }
            f.contentOffsetY = contentY.map(\.v)
        }
        for (i, b) in beats {
            f.beats[i] = TourFeedbackBeatFrame(fill: min(max(b.fill.v, 0), 1), draw: min(max(b.draw.v, 0), 1),
                                               scale: b.scale.v, textMix: min(max(b.text.v, 0), 1))
        }
        f.swapGeneration = swapGeneration
        return f
    }

    func makeFXSnapshot() -> TourFXSnapshot {
        TourFXSnapshot(particles: particles, halos: halos)
    }
}
