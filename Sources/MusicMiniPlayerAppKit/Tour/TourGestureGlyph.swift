/**
 * [INPUT]: SwiftUI (Canvas, TimelineView); TourFeedbackChoreographer's TourFeedbackEase (the prototype's cubic-bezier).
 * [OUTPUT]: Exports TourGestureKind, TourGestureMotion (the pure timeline: the two dots and their motion
 *           trails), TourGestureGlyphFace (one drawn frame), TourGestureGlyph (self-clocked: static cards,
 *           tests) and TourDrivenGestureGlyph (clocked by the tour's own motion) — the trackpad
 *           two-finger-nudge demo inside the move step's card (proposal §8.7, prototype C.4.3).
 * [POS]: MusicMiniPlayerAppKit/Tour. Scaled from the System Settings Trackpad
 *        page reference frames (research/trackpad-demo-frames.md): outline
 *        96x72pt -> 1.15x = 110x83 on the 260pt card, two 11pt (x1.15) dots 16pt (x1.15) apart centre to
 *        centre, one 3.55s cycle (fade in -> hold -> move -> hold -> dim -> hold -> fade out -> hidden),
 *        TWO cycles, then it RESTS at the start pose at 0.31 opacity and the clock stops; hovering the glyph
 *        plays it again. While the dots slide each one drags a blurred trail (prototype `.f::after`:
 *        opacity 0 -> .45 -> 0, stretched to 1.8x behind the dot, 1.5px blur). (The first version derived the
 *        phase from the wall clock and paused itself on a cycle boundary — where the timeline is fully
 *        transparent — so after two cycles the band in the card was blank for good: founder 2026-09-29. The
 *        second put the dots 31pt apart instead of the prototype's 18.4pt and had no trails.)
 */

import SwiftUI

/// Which way the fingers move in the nudge demo: a unit vector in VIEW space (y down). The prototype's fixed
/// 30x18 diagonal is the default; the move step aims it at the corner the screen suggests (`TourCornerGuide`).
struct TourGestureHeading: Equatable {
    var dx: Double
    var dy: Double

    /// Rounded so two headings for the same pair of corners compare equal.
    init(dx: Double, dy: Double) {
        let len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
        self.dx = (dx / len * 10_000).rounded() / 10_000
        self.dy = (dy / len * 10_000).rounded() / 10_000
    }

    init(_ v: CGVector) { self.init(dx: Double(v.dx), dy: Double(v.dy)) }

    static let prototype = TourGestureHeading(dx: 30, dy: 18)
    /// Pad points the fingers travel (the prototype's `hypot(30, 18)`).
    static let travel = (30.0 * 30.0 + 18.0 * 18.0).squareRoot()
    var degrees: Double { atan2(dy, dx) * 180 / .pi }
}

enum TourGestureKind: Equatable {
    /// Push toward a corner (S5 beats 1 and 2): the fingers travel 35pt along the heading (default: the prototype's diagonal).
    case nudgeToCorner(TourGestureHeading = .prototype)
    /// Push into the edge (S5 beat 3): 36pt horizontal; `rightward` is the FINGERS' direction.
    case swipeToEdge(rightward: Bool)
}

/// The glyph's motion as a pure function of elapsed time since it (re)started.
enum TourGestureMotion {
    static let cycleDuration: TimeInterval = 3.55
    static let cycles = 2
    /// Prototype C.4.3: the demo is shown 1.15x on the 260pt card.
    static let scale: CGFloat = 1.15
    static let restOpacity = 0.31

    /// The pad (prototype `.tp .pad`: 96x72) and its two dots (11pt, at `.f.a` / `.f.b` `left`/`top`), unscaled.
    static let padSize = CGSize(width: 96, height: 72)
    static let dotDiameter: CGFloat = 11
    /// Trail: `.f::after` — same box, 1.5px blur; at the move's midpoint 45 % opaque, 1.8x long, 4px behind.
    static let trailBlur: CGFloat = 1.5
    static let trailPeakOpacity = 0.45
    static let trailStretch: CGFloat = 1.8
    static let trailShift: CGFloat = 4
    /// The nudge trail lies along the move's own diagonal (`rotate(31deg)`).
    static let nudgeAngle = 31.0

    struct Frame: Equatable {
        var dx: CGFloat
        var dy: CGFloat
        var opacity: Double
    }

    /// One dot's trail, in the dot's own frame: `rotate(angle) translateX(shift) scaleX(stretch)` about its centre.
    struct Trail: Equatable {
        var opacity: Double
        var stretch: CGFloat
        /// Along the (rotated) x axis, unscaled points.
        var shift: CGFloat
        var angleDegrees: Double

        static let none = Trail(opacity: 0, stretch: 1, shift: 0, angleDegrees: 0)
    }

    /// Centres of the two dots at the start pose, unscaled pad points (top-left origin).
    static func dotCenters(_ kind: TourGestureKind) -> (a: CGPoint, b: CGPoint) {
        let r = dotDiameter / 2
        let (left, top): (CGFloat, CGFloat)
        switch kind {
        case .nudgeToCorner(let h):
            // The path is centred on the same point whatever its direction (the prototype's diagonal is the reference).
            let ref = TourGestureHeading.prototype, half = TourGestureHeading.travel / 2
            (left, top) = (20 + CGFloat((ref.dx - h.dx) * half), 22 + CGFloat((ref.dy - h.dy) * half))
        case .swipeToEdge(let rightward): (left, top) = (rightward ? 24 : 44, 30)
        }
        return (CGPoint(x: left + r, y: top + r), CGPoint(x: left + 16 + r, y: top + r))
    }

    static func displacement(_ kind: TourGestureKind) -> (dx: CGFloat, dy: CGFloat) {
        switch kind {
        case .nudgeToCorner(let h):
            if h == .prototype { return (30 * scale, 18 * scale) }
            return (CGFloat(h.dx * TourGestureHeading.travel) * scale, CGFloat(h.dy * TourGestureHeading.travel) * scale)
        case .swipeToEdge(let rightward): return ((rightward ? 36 : -36) * scale, 0)
        }
    }

    /// True once the two cycles have played: the clock can stop.
    static func isFinished(elapsed: TimeInterval) -> Bool { elapsed >= cycleDuration * Double(cycles) }

    /// The keyframe percentages of `tpNudge` / `tpSwipe` / `tpSwipeL` (prototype C.4.3), as fractions of the cycle:
    /// fade in -> hold -> move (`cubic-bezier(.42,0,.58,1)`) -> hold -> dim to .31 -> plateau -> fade out -> hidden.
    static let fadeInEnd = 0.127, moveStart = 0.225, moveEnd = 0.493, holdEnd = 0.592, dimEnd = 0.676, plateauEnd = 0.839, fadeOutEnd = 0.958

    /// `reduceMotion`: only the start pose, static (09-25 §8.4).
    static func frame(kind: TourGestureKind, elapsed: TimeInterval, reduceMotion: Bool) -> Frame {
        if reduceMotion || isFinished(elapsed: elapsed) || elapsed < 0 { return Frame(dx: 0, dy: 0, opacity: restOpacity) }
        let u = elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let (totalDX, totalDY) = displacement(kind)
        switch u {
        case ..<fadeInEnd: return Frame(dx: 0, dy: 0, opacity: u / fadeInEnd)
        case ..<moveStart: return Frame(dx: 0, dy: 0, opacity: 1)
        case ..<moveEnd:
            let k = CGFloat(TourFeedbackEase.io.value((u - moveStart) / (moveEnd - moveStart)))
            return Frame(dx: totalDX * k, dy: totalDY * k, opacity: 1)
        case ..<holdEnd: return Frame(dx: totalDX, dy: totalDY, opacity: 1)
        case ..<dimEnd:
            let k = (u - holdEnd) / (dimEnd - holdEnd)
            return Frame(dx: totalDX, dy: totalDY, opacity: 1 - k * (1 - restOpacity))
        case ..<plateauEnd: return Frame(dx: totalDX, dy: totalDY, opacity: restOpacity)
        case ..<fadeOutEnd:
            let k = (u - plateauEnd) / (fadeOutEnd - plateauEnd)
            return Frame(dx: totalDX, dy: totalDY, opacity: restOpacity * (1 - k))
        default: return Frame(dx: totalDX, dy: totalDY, opacity: 0)
        }
    }

    /// The trail at `elapsed` (prototype `tpTrailH` / `tpTrailHL` / `tpTrailN`, linear): nothing until the move
    /// starts (22.5 %), full at its middle (36 %), gone when it ends (49.3 %).
    static func trail(kind: TourGestureKind, elapsed: TimeInterval, reduceMotion: Bool) -> Trail {
        guard !reduceMotion, elapsed >= 0, !isFinished(elapsed: elapsed) else { return .none }
        let u = elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let k: Double
        if u <= moveStart || u >= moveEnd { return .none }
        else if u < 0.36 { k = (u - moveStart) / (0.36 - moveStart) }
        else { k = 1 - (u - 0.36) / (moveEnd - 0.36) }
        let behind: CGFloat
        let angle: Double
        switch kind {
        case .nudgeToCorner(let h): (behind, angle) = (-trailShift, h == .prototype ? nudgeAngle : h.degrees)
        case .swipeToEdge(let rightward): (behind, angle) = (rightward ? -trailShift : trailShift, 0)
        }
        return Trail(opacity: trailPeakOpacity * k, stretch: 1 + (trailStretch - 1) * CGFloat(k), shift: behind * CGFloat(k), angleDegrees: angle)
    }
}

/// One drawn frame of the glyph: the pad outline, the two dots and their trails.
///
/// Plain SwiftUI shapes, deliberately NOT a `Canvas`: a Canvas is its own render layer, and one inside the card's
/// glass made every card update (each panel move, each fade frame) redraw it through a synchronous WindowServer
/// round trip (`RBLayer display` -> `SLSAcceleratorForDisplayNumber`, up to ~100 ms on the main thread while the
/// panel was being dragged — measured, 2026-09-29). The dots are cheap views; the trail exists only while it is visible.
struct TourGestureGlyphFace: View {
    var kind: TourGestureKind
    /// nil = at rest (or Reduce Motion): the start pose at 0.31, no trails.
    var elapsed: TimeInterval?
    var reduceMotion: Bool
    /// Off only in the tests that compare a frame with and without its trail.
    var showTrail = true

    typealias M = TourGestureMotion
    static let size = CGSize(width: M.padSize.width * M.scale, height: M.padSize.height * M.scale)
    private static let blue = Color(red: 0x6B / 255, green: 0x9C / 255, blue: 0xFD / 255)

    var body: some View {
        let f = M.frame(kind: kind, elapsed: elapsed ?? .infinity, reduceMotion: reduceMotion)
        let trail = (showTrail ? elapsed : nil).map { M.trail(kind: kind, elapsed: $0, reduceMotion: reduceMotion) } ?? .none
        let s = M.scale
        let centers = M.dotCenters(kind)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8 * s, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1.5)
            dot(at: CGPoint(x: centers.a.x * s + f.dx, y: centers.a.y * s + f.dy), opacity: f.opacity, trail: trail)
            dot(at: CGPoint(x: centers.b.x * s + f.dx, y: centers.b.y * s + f.dy), opacity: f.opacity, trail: trail)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        // The demo re-aims (a new corner is suggested, or the edge beat begins) with a short ease, not a jump.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: kind)
        .accessibilityHidden(true)
    }

    /// One finger: its trail (CSS `.f::after`: `rotate(a) translateX(shift) scaleX(stretch)` about the dot's centre, blurred)
    /// under the dot, both inside the dot's own opacity.
    @ViewBuilder
    private func dot(at center: CGPoint, opacity: Double, trail: M.Trail) -> some View {
        let s = M.scale
        let d = M.dotDiameter * s
        ZStack {
            if trail.opacity > 0.001 {
                Circle().fill(Self.blue)
                    .frame(width: d, height: d)
                    .scaleEffect(x: trail.stretch, y: 1)
                    .offset(x: trail.shift * s)
                    .rotationEffect(.degrees(trail.angleDegrees))
                    .blur(radius: M.trailBlur * s)
                    .opacity(trail.opacity)
            }
            Circle().fill(Self.blue).frame(width: d, height: d)
        }
        .opacity(opacity)
        .position(x: center.x, y: center.y)
    }
}

/// The glyph clocked by the tour's own motion (one display link for the whole tour): `elapsed` is the
/// guidance frame's `glyphElapsed`. Hovering it after it has come to rest plays it again.
struct TourDrivenGestureGlyph: View {
    var kind: TourGestureKind
    @ObservedObject var clock: TourGlyphClock
    var reduceMotion: Bool
    var onReplay: (() -> Void)?

    var body: some View {
        TourGestureGlyphFace(kind: kind, elapsed: clock.elapsed, reduceMotion: reduceMotion)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering, clock.elapsed == nil, !reduceMotion else { return }
                onReplay?()
            }
    }
}

/// The self-clocked glyph (static cards and tests): a wall-clock timeline that ends after two cycles.
struct TourGestureGlyph: View {
    var kind: TourGestureKind
    var reduceMotion: Bool

    @State private var startedAt: Date
    @State private var finished: Bool

    /// `startedAt` is a test seam (a glyph that started 10 s ago is already at rest).
    init(kind: TourGestureKind, reduceMotion: Bool, startedAt: Date = Date()) {
        self.kind = kind
        self.reduceMotion = reduceMotion
        _startedAt = State(initialValue: startedAt)
        _finished = State(initialValue: TourGestureMotion.isFinished(elapsed: Date().timeIntervalSince(startedAt)))
    }

    var body: some View {
        Group {
            if reduceMotion || finished {
                TourGestureGlyphFace(kind: kind, elapsed: nil, reduceMotion: reduceMotion)
            } else {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    TourGestureGlyphFace(kind: kind, elapsed: elapsed, reduceMotion: false)
                        .onChange(of: TourGestureMotion.isFinished(elapsed: elapsed)) { _, done in
                            if done { finished = true }
                        }
                }
            }
        }
        .frame(width: TourGestureGlyphFace.size.width, height: TourGestureGlyphFace.size.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            // Hovering the glyph plays it again once it has rested.
            guard hovering, finished, !reduceMotion else { return }
            startedAt = Date()
            finished = false
        }
        .onChange(of: kind) { _, _ in
            // A new demo (the step moved from "corner" to "edge"): play it from the top.
            startedAt = Date()
            finished = false
        }
        .accessibilityHidden(true)
    }
}
