/**
 * [INPUT]: Foundation only (no SwiftUI, no AppKit, no real clock, no window).
 *          MusicMiniPlayerCore's TourCardSide / TourRingMode.
 *          TourFeedbackChoreographer's TourFeedbackValue / TourSequenceClock /
 *          TourFeedbackEase (the same retargetable tween+spring value the
 *          completion feedback is built from).
 * [OUTPUT]: Exports TourCardPose, TourRingGeometry, TourGuidanceFrame and
 *           TourGuidanceMotion — the pure state machine behind prototype
 *           section C: card appear / disappear (C.2), the step-to-step move
 *           with beak re-aim and height spring (C.3), the highlight ring's
 *           appear / breathe / jump / press-now pulse (C.4.1), the ghost
 *           cursor (C.4.2) and the panel-edge glow.
 * [POS]: MusicMiniPlayerAppKit/Tour. Never draws and never touches a window:
 *        `TourGuidance` (the live shell) steps it from a display link and
 *        applies `makeFrame()` to the card window, the overlay window and the
 *        SwiftUI stores. Every number is the prototype's; a fake clock stepped
 *        like `__proto.advance()` reproduces the prototype frame for frame
 *        (`TourGuidanceMotionTests`).
 */

import Foundation
import CoreGraphics
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Value types
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Where the card window wants to be, in SCREEN space (AppKit, y up). `top` is
/// the window's MAX y — the height springs while the top edge (and the beak,
/// which is measured from it) stays put.
struct TourCardPose: Equatable {
    var x: Double
    var top: Double
    var width: Double
    var height: Double
    var beakSide: TourCardSide
    /// Distance from the top edge to the beak tip (y-down, TourBubbleShape's convention).
    var beakOffset: Double

    var beakTip: CGPoint {
        let y = top - beakOffset
        switch beakSide {
        case .right: return CGPoint(x: x + width, y: y)
        case .left: return CGPoint(x: x, y: y)
        case .top: return CGPoint(x: x + beakOffset, y: top)
        case .bottom: return CGPoint(x: x + beakOffset, y: top - height)
        }
    }
}

/// The ring's rect in screen space (centre + size).
struct TourRingGeometry: Equatable {
    var cx: Double, cy: Double, w: Double, h: Double
    var corner: Double

    var rect: CGRect { CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h) }
}

/// Everything the live shell needs at one instant.
struct TourGuidanceFrame: Equatable {
    // Card window
    var cardVisible = false
    var cardX = 0.0
    var cardTop = 0.0
    var cardWidth = 272.0
    var cardHeight = 0.0
    var cardBeakSide: TourCardSide = .right
    var cardBeakOffset = 0.0
    /// 0...1: the drawn beak's protrusion (it shrinks to nothing and grows on
    /// the other side when the card re-aims across the panel).
    var beakScale = 1.0
    var cardOpacity = 1.0
    var cardScale = 1.0
    /// Points the card sits off its resting spot, toward its anchor.
    var cardApproach = 0.0
    var contentOpacity: [Double] = [1, 1, 1]
    var contentOffsetY: [Double] = [0, 0, 0]
    /// The move step's trackpad demo: how present it is (0 = not in the card, 1 = fully in;
    /// springs with the card's height so the band and the bubble grow together).
    var glyphPresence = 0.0
    /// Seconds into the demo's cycle, nil = no cycle is running (it rests at its start pose).
    var glyphElapsed: Double?

    // Ring
    var ringVisible = false
    var ring = TourRingGeometry(cx: 0, cy: 0, w: 40, h: 40, corner: 20)
    var ringOpacity = 1.0
    var ringScale = 1.0
    /// The press-now pulse (1 -> 1.14 -> 1).
    var ringPulse = 1.0
    var ringDashed = false
    /// Breathing phase 0...1 (0 = rest).
    var breath = 0.0
    /// Sonar ripples: progress 0...1 of every ripple currently alive.
    var ripples: [Double] = []

    // Ghost cursor (screen space) + panel glow
    var ghostVisible = false
    var ghost = CGPoint.zero
    var ghostOpacity = 0.0
    /// The "you're hovering here" ripple under the parked ghost: progress 0...1, nil = none.
    var ghostRipple: Double?
    var panelGlow = 0.0

    static let idle = TourGuidanceFrame()
}

/// The part of a frame the card's SwiftUI content draws from. The card's WINDOW (position, size, alpha) is
/// driven straight from the frame; this is only what changes the card's own pixels, so a frame in which the
/// card merely travels (or only the ring breathes) leaves it Equal and the card view is not re-evaluated.
struct TourCardVisual: Equatable {
    var cardVisible = false
    var cardHeight = 0.0
    var cardBeakSide: TourCardSide = .right
    var cardBeakOffset = 0.0
    var beakScale = 1.0
    var cardScale = 1.0
    var contentOpacity: [Double] = [1, 1, 1]
    var contentOffsetY: [Double] = [0, 0, 0]
    var glyphPresence = 0.0
    var glyphElapsed: Double?

    static let hidden = TourCardVisual()

    init() {}

    init(_ f: TourGuidanceFrame) {
        cardVisible = f.cardVisible
        cardHeight = f.cardHeight
        cardBeakSide = f.cardBeakSide
        cardBeakOffset = f.cardBeakOffset
        beakScale = f.beakScale
        cardScale = f.cardScale
        contentOpacity = f.contentOpacity
        contentOffsetY = f.contentOffsetY
        glyphPresence = f.glyphPresence
        glyphElapsed = f.glyphElapsed
    }
}

/// What the ring / ghost-cursor / panel-glow overlay draws. Equal frames are not redrawn.
struct TourOverlayVisual: Equatable {
    var ringVisible = false
    var ring = TourRingGeometry(cx: 0, cy: 0, w: 40, h: 40, corner: 20)
    var ringOpacity = 1.0
    var ringScale = 1.0
    var ringPulse = 1.0
    var ringDashed = false
    var breath = 0.0
    var ripples: [Double] = []
    var ghostVisible = false
    var ghost = CGPoint.zero
    var ghostOpacity = 0.0
    var ghostRipple: Double?
    var panelGlow = 0.0

    static let hidden = TourOverlayVisual()

    init() {}

    init(_ f: TourGuidanceFrame) {
        ringVisible = f.ringVisible
        ring = f.ring
        ringOpacity = f.ringOpacity
        ringScale = f.ringScale
        ringPulse = f.ringPulse
        ringDashed = f.ringDashed
        breath = f.breath
        ripples = f.ripples
        ghostVisible = f.ghostVisible
        ghost = f.ghost
        ghostOpacity = f.ghostOpacity
        ghostRipple = f.ghostRipple
        panelGlow = f.panelGlow
    }

    /// Something is on screen (the overlay window can be parked otherwise).
    var hasContent: Bool {
        (panelGlow > 0.003) || (ringVisible && ringOpacity > 0.003) || (ghostVisible && ghostOpacity > 0.003)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Constants (prototype C)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourGuidanceTokens {
    // C.2 card appear / disappear
    static let appearScale = 0.94
    static let appearApproach = 10.0
    static let appearOpacityDuration = 0.14
    static let appearSpring: (duration: Double, bounce: Double) = (0.36, 0.14)
    static let contentBaseDelay = 0.06
    static let contentStagger = 0.04
    static let contentDuration = 0.18
    static let contentRise = 6.0
    static let disappearDuration = 0.16
    static let disappearScale = 0.97
    static let disappearApproach = 6.0
    // C.3 move
    static let moveStartDelay = 0.04
    static let moveSpring: (duration: Double, bounce: Double) = (0.5, 0.14)
    static let heightSpring: (duration: Double, bounce: Double) = (0.4, 0.15)
    static let heightDelay = 0.1
    static let beakSpring: (duration: Double, bounce: Double) = (0.42, 0.15)
    static let beakOutDuration = 0.1
    static let beakSwapAt = 0.12
    static let beakInDuration = 0.16
    // Move-step trackpad demo (founder 2026-09-29: only on the beat that asks for the gesture)
    /// The band grows with the card's own height spring, so bubble and band move as one.
    static let glyphSpring: (duration: Double, bounce: Double) = heightSpring
    static let glyphOutDuration = 0.16
    /// The demo's own 0->1 fade would double the band's; it starts once the band is mostly in.
    static let glyphCycleDelay = 0.12
    // C.4.1 ring
    /// Founder 2026-09-29: the ring eases in from a little smaller, not from a bigger halo.
    static let ringAppearScale = 0.85
    static let ringAppearSpring: (duration: Double, bounce: Double) = (0.5, 0.25)
    static let ringAppearFade = 0.2
    static let ringJumpSpring: (duration: Double, bounce: Double) = (0.42, 0.15)
    static let ringJumpFade = 0.15
    static let ringHintOpacity = 0.7
    static let ringHideDuration = 0.14
    static let ringModeFade = 0.18
    /// The soft "look here" pulse starts shortly after the ring has landed.
    static let breathDelay = 0.4
    static let breathPeriod = 2.4
    static let breathCycles = 3.0
    /// Sonar ripple: expands 1.0 -> 1.35 and fades .5 -> 0 over 1.6s, ease-out.
    static let rippleDuration = 1.6
    static let rippleScale = 0.35
    static let rippleAlpha = 0.5
    static let pulseUp = 1.14
    // C.4.2 ghost cursor
    static let ghostDelay = 0.6
    static let ghostCycle = 3.4
    static let ghostCycles = 2
    static let ghostArc = 34.0
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Motion
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourGuidanceMotion {
    typealias T = TourGuidanceTokens

    let clock = TourSequenceClock()
    var reduceMotion: Bool

    // Card values
    private let cx: TourFeedbackValue
    private let ctop: TourFeedbackValue
    private let ch: TourFeedbackValue
    private let bOff: TourFeedbackValue
    private let bScale: TourFeedbackValue
    private let cop: TourFeedbackValue
    private let csc: TourFeedbackValue
    private let capp: TourFeedbackValue
    private let contentOp: [TourFeedbackValue]
    private let contentY: [TourFeedbackValue]
    private let glyph: TourFeedbackValue
    private var glyphStart: Double?
    private(set) var glyphWanted = false
    private var cardWidth = 272.0
    private var beakSide: TourCardSide = .right
    private(set) var cardVisible = false
    /// The pose the card is heading for (springs still in flight included).
    private(set) var targetPose: TourCardPose?

    // Ring values
    private let hx: TourFeedbackValue
    private let hy: TourFeedbackValue
    private let hw: TourFeedbackValue
    private let hh: TourFeedbackValue
    private let hop: TourFeedbackValue
    private let hsc: TourFeedbackValue
    private let hpulse: TourFeedbackValue
    private var ringCorner = 20.0
    private(set) var ringMode: TourRingMode = .hint
    private(set) var ringVisible = false
    private var breathStart: Double?

    // Hints
    private var ghostStart: Double?
    private var ghostTarget: CGPoint = .zero
    private var glowStart: Double?
    private var glowCycles = T.breathCycles
    private var glowFollowsBreath = false

    private struct Cue { var at: Double; var essential: Bool; var fn: () -> Void }
    private var cues: [Cue] = []

    init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
        let c = clock
        cx = TourFeedbackValue(0, clock: c); ctop = TourFeedbackValue(0, clock: c); ch = TourFeedbackValue(0, clock: c)
        bOff = TourFeedbackValue(40, clock: c); bScale = TourFeedbackValue(1, clock: c)
        cop = TourFeedbackValue(0, clock: c); csc = TourFeedbackValue(1, clock: c); capp = TourFeedbackValue(0, clock: c)
        contentOp = (0..<3).map { _ in TourFeedbackValue(1, clock: c) }
        contentY = (0..<3).map { _ in TourFeedbackValue(0, clock: c) }
        glyph = TourFeedbackValue(0, clock: c)
        hx = TourFeedbackValue(0, clock: c); hy = TourFeedbackValue(0, clock: c)
        hw = TourFeedbackValue(40, clock: c); hh = TourFeedbackValue(40, clock: c)
        hop = TourFeedbackValue(0, clock: c); hsc = TourFeedbackValue(1, clock: c); hpulse = TourFeedbackValue(1, clock: c)
    }

    // MARK: Clock

    var now: Double { clock.now }

    /// True while anything still moves or a hint is still running — the shell
    /// keeps its display link alive only while this holds (zero idle cost).
    var isAnimating: Bool {
        let values: [TourFeedbackValue] = [cx, ctop, ch, bOff, bScale, cop, csc, capp, glyph, hx, hy, hw, hh, hop, hsc, hpulse] + contentOp + contentY
        if values.contains(where: { $0.isActive }) { return true }
        if glyphIsRunning { return true }
        if !cues.isEmpty { return true }
        if ghostStart != nil || breathStart != nil { return true }
        if glowStart != nil { return true }
        return false
    }

    func step(_ dt: Double) {
        clock.now += dt
        let all: [TourFeedbackValue] = [cx, ctop, ch, bOff, bScale, cop, csc, capp, glyph, hx, hy, hw, hh, hop, hsc, hpulse] + contentOp + contentY
        all.forEach { $0.step(dt) }
        // Cues, in time order (a cue may register more cues).
        var guardCount = 0
        while let i = cues.indices.filter({ cues[$0].at <= clock.now + 1e-9 }).min(by: { cues[$0].at < cues[$1].at }), guardCount < 64 {
            let cue = cues.remove(at: i)
            cue.fn()
            guardCount += 1
        }
        if let s = breathStart, clock.now - s - T.breathDelay >= T.breathCycles * T.breathPeriod + T.rippleDuration { breathStart = nil }
        if let g = ghostStart, clock.now - g >= Double(T.ghostCycles) * T.ghostCycle { ghostStart = nil }
        if let g = glowStart, clock.now - g - (glowFollowsBreath ? T.breathDelay : 0) >= glowCycles * T.breathPeriod { glowStart = nil }
    }

    /// Test/shell entry: advance in frames of at most 1/60 s (a hair over, so a
    /// 60 Hz tick is one step — the completion feedback steps the same way).
    func advance(by seconds: Double, maxStep: Double = 1.0 / 60.0) {
        var left = seconds
        while left > 1e-9 {
            let d = min(left, maxStep + 0.0005)
            step(d)
            left -= d
        }
    }

    private func cue(_ delay: Double, essential: Bool = true, _ fn: @escaping () -> Void) {
        cues.append(Cue(at: clock.now + delay, essential: essential, fn: fn))
    }

    /// Runs `fn` once `delay` seconds of MOTION time have passed. The controller
    /// hangs the content swap and the ring's late re-appearance on this, so they
    /// stay in step with the springs (and with a fake clock in tests).
    func schedule(after delay: Double, _ fn: @escaping () -> Void) {
        cue(delay, fn)
    }

    /// The body text changes under a resting card (C.5.3): the old text fades
    /// out in 0.1 s (ease-in), `swap` runs, the new text fades in in 0.16 s.
    func crossfadeBody(swap: @escaping () -> Void) {
        if reduceMotion { swap(); return }
        contentOp[1].to(0, dur: 0.1, ease: .in)
        cue(0.1) { [unowned self] in
            swap()
            contentOp[1].to(1, dur: 0.16, ease: .out)
        }
    }

    // MARK: Card (C.2, C.3)

    /// The card window's pose right now (springs included).
    var currentCardPose: TourCardPose {
        TourCardPose(x: cx.v, top: ctop.v, width: cardWidth, height: ch.v, beakSide: beakSide, beakOffset: bOff.v)
    }

    private func setPose(_ p: TourCardPose) {
        cx.set(p.x); ctop.set(p.top); ch.set(p.height); bOff.set(p.beakOffset)
        cardWidth = p.width
        beakSide = p.beakSide
        bScale.set(1)
    }

    /// First appearance (and re-appearance after the card yielded): the card is
    /// placed at once, then grows from its beak tip (C.2).
    func presentCard(at pose: TourCardPose) {
        setPose(pose)
        targetPose = pose
        cardVisible = true
        cues.removeAll { !$0.essential }
        if reduceMotion {
            csc.set(1); capp.set(0)
            contentOp.forEach { $0.set(1) }; contentY.forEach { $0.set(0) }
            cop.set(0); cop.to(1, dur: 0.16, ease: .lin)
            return
        }
        cop.set(0); csc.set(T.appearScale); capp.set(T.appearApproach)
        cop.to(1, dur: T.appearOpacityDuration, ease: .out)
        csc.to(1, springDuration: T.appearSpring.duration, bounce: T.appearSpring.bounce)
        capp.to(0, springDuration: T.appearSpring.duration, bounce: T.appearSpring.bounce)
        for i in 0..<3 {
            let delay = T.contentBaseDelay + Double(i) * T.contentStagger
            contentOp[i].set(0); contentY[i].set(T.contentRise)
            contentOp[i].to(1, dur: T.contentDuration, ease: .out, delay: delay)
            contentY[i].to(0, dur: T.contentDuration, ease: .out, delay: delay)
        }
    }

    /// Disappear (C.2): 0.16 s ease-in, scale .97, toward the anchor.
    func dismissCard(approach: Double = T.disappearApproach) {
        guard cardVisible else { return }
        cardVisible = false
        if reduceMotion { cop.to(0, dur: 0.12, ease: .lin); return }
        cop.to(0, dur: T.disappearDuration, ease: .in)
        csc.to(T.disappearScale, dur: T.disappearDuration, ease: .in)
        capp.to(approach, dur: T.disappearDuration, ease: .in)
    }

    /// Step-to-step move (C.3): x/y springs continue from the current velocity
    /// (a retarget never zeroes it), the height springs 0.1 s later, the beak
    /// re-aims, and across the panel the beak shrinks away and grows back on
    /// the other side.
    func moveCard(to pose: TourCardPose, delay: Double = T.moveStartDelay) {
        cardVisible = true
        targetPose = pose
        if reduceMotion {
            // Fade out, jump, fade in (C.7): no travel.
            cop.to(0, dur: 0.12, ease: .lin)
            cue(0.14) { [unowned self] in
                setPose(pose)
                cop.to(1, dur: 0.16, ease: .lin)
            }
            return
        }
        cardWidth = pose.width
        cx.to(pose.x, springDuration: T.moveSpring.duration, bounce: T.moveSpring.bounce, delay: delay)
        ctop.to(pose.top, springDuration: T.moveSpring.duration, bounce: T.moveSpring.bounce, delay: delay)
        ch.to(pose.height, springDuration: T.heightSpring.duration, bounce: T.heightSpring.bounce, delay: delay + T.heightDelay)
        bOff.to(pose.beakOffset, springDuration: T.beakSpring.duration, bounce: T.beakSpring.bounce, delay: delay)
        if pose.beakSide != beakSide {
            bScale.to(0, dur: T.beakOutDuration, ease: .in, delay: delay)
            cue(delay + T.beakSwapAt) { [unowned self] in
                beakSide = pose.beakSide
                bScale.to(1, dur: T.beakInDuration, ease: .out)
            }
        }
    }

    /// The body text changed line count (C.5.3): height, top and beak re-settle
    /// on the SAME anchor.
    func relayoutCard(to pose: TourCardPose) {
        targetPose = pose
        if reduceMotion { setPose(pose); return }
        ch.to(pose.height, springDuration: T.heightSpring.duration, bounce: T.heightSpring.bounce)
        ctop.to(pose.top, springDuration: T.heightSpring.duration, bounce: T.heightSpring.bounce)
        bOff.to(pose.beakOffset, springDuration: T.heightSpring.duration, bounce: T.heightSpring.bounce)
    }

    /// Content blocks: fade out (C.3 "H") and stagger back in after the swap.
    func fadeContentOut(duration: Double = 0.14) {
        contentOp.forEach { $0.to(0, dur: reduceMotion ? 0.12 : duration, ease: reduceMotion ? .lin : .in) }
    }

    func staggerContentIn() {
        for i in 0..<3 {
            if reduceMotion {
                contentOp[i].set(0); contentY[i].set(0)
                contentOp[i].to(1, dur: 0.16, ease: .lin)
            } else {
                let delay = Double(i) * T.contentStagger
                contentOp[i].set(0); contentY[i].set(T.contentRise)
                contentOp[i].to(1, dur: T.contentDuration, ease: .out, delay: delay)
                contentY[i].to(0, dur: T.contentDuration, ease: .out, delay: delay)
            }
        }
    }

    // MARK: Trackpad demo (move step)

    /// The demo is in the card while `present`. `animated: false` puts it there at once (the card is appearing,
    /// or a new card's content is swapping in); animated, it grows on the card's height spring.
    /// `restart` plays the cycle again from the top (a new demo, or a hover replay).
    func setGlyph(present: Bool, animated: Bool = true, restart: Bool = false) {
        if present {
            let already = glyphWanted
            glyphWanted = true
            if reduceMotion || !animated {
                glyph.set(1)
                glyphStart = reduceMotion ? nil : clock.now + T.glyphCycleDelay
            } else if !already {
                glyph.to(1, springDuration: T.glyphSpring.duration, bounce: T.glyphSpring.bounce)
                glyphStart = clock.now + T.glyphCycleDelay
            } else if restart {
                glyphStart = clock.now
            }
        } else {
            glyphWanted = false
            glyphStart = nil
            if reduceMotion || !animated { glyph.set(0) }
            else { glyph.to(0, springDuration: T.glyphSpring.duration, bounce: T.glyphSpring.bounce) }
        }
    }

    /// Hover replay: the cycle starts over.
    func replayGlyph() {
        guard glyphWanted, !reduceMotion else { return }
        glyphStart = clock.now
    }

    private var glyphIsRunning: Bool {
        guard let g = glyphStart else { return false }
        return clock.now - g < Double(TourGestureMotion.cycles) * TourGestureMotion.cycleDuration
    }

    // MARK: Ring (C.4.1)

    private func ringOpacityTarget(_ mode: TourRingMode) -> Double { mode == .hint ? T.ringHintOpacity : 1 }

    private func apply(_ g: TourRingGeometry, animated: Bool) {
        ringCorner = g.corner
        if animated {
            let s = T.ringJumpSpring
            hx.to(g.cx, springDuration: s.duration, bounce: s.bounce)
            hy.to(g.cy, springDuration: s.duration, bounce: s.bounce)
            hw.to(g.w, springDuration: s.duration, bounce: s.bounce)
            hh.to(g.h, springDuration: s.duration, bounce: s.bounce)
        } else {
            hx.set(g.cx); hy.set(g.cy); hw.set(g.w); hh.set(g.h)
        }
    }

    /// Shows the ring on `g`. First appearance: in place, eases in from 0.85
    /// (scale + opacity) and starts the soft pulse. Already visible: jumps
    /// there on the four position/size springs, then pulses again.
    func showRing(_ g: TourRingGeometry, mode: TourRingMode) {
        ringMode = mode
        let wasVisible = ringVisible && hop.v > 0.02
        ringVisible = true
        if !wasVisible || reduceMotion {
            apply(g, animated: false)
            hpulse.set(1)
            if reduceMotion {
                hsc.set(1); hop.set(0)
                hop.to(ringOpacityTarget(mode), dur: 0.16, ease: .lin)
                breathStart = nil
            } else {
                hsc.set(T.ringAppearScale); hop.set(0)
                hop.to(ringOpacityTarget(mode), dur: T.ringAppearFade, ease: .out)
                hsc.to(1, springDuration: T.ringAppearSpring.duration, bounce: T.ringAppearSpring.bounce)
                breathStart = clock.now
            }
        } else {
            apply(g, animated: true)
            hop.to(ringOpacityTarget(mode), dur: T.ringJumpFade, ease: .out)
            breathStart = clock.now
        }
    }

    /// The target moved (the panel was dragged, the layout settled): follow it
    /// on the jump spring without restarting the pulse.
    func retargetRing(_ g: TourRingGeometry) {
        guard ringVisible else { return }
        apply(g, animated: !reduceMotion)
    }

    /// Hint <-> press-now (C.4.1): dashed/0.7 vs solid/1; entering press-now
    /// gives one pulse and restarts the breathing.
    func setRingMode(_ mode: TourRingMode) {
        guard mode != ringMode else { return }
        ringMode = mode
        guard ringVisible else { return }
        hop.to(ringOpacityTarget(mode), dur: reduceMotion ? 0.16 : T.ringModeFade, ease: reduceMotion ? .lin : .out)
        if mode == .pressNow, !reduceMotion {
            hpulse.set(1)
            hpulse.to(T.pulseUp, dur: 0.12, ease: .out)
            cue(0.12) { [unowned self] in hpulse.to(1, springDuration: 0.5, bounce: 0.3) }
            breathStart = clock.now
        }
    }

    /// One press-now style pulse without changing anything else (a beat row
    /// was hovered on a step with a single control).
    func pulseRing() {
        guard ringVisible, !reduceMotion else { return }
        hpulse.set(1)
        hpulse.to(T.pulseUp, dur: 0.12, ease: .out)
        cue(0.12) { [unowned self] in hpulse.to(1, springDuration: 0.5, bounce: 0.3) }
    }

    func hideRing() {
        guard ringVisible else { return }
        ringVisible = false
        breathStart = nil
        hop.to(0, dur: reduceMotion ? 0.12 : T.ringHideDuration, ease: reduceMotion ? .lin : .in)
    }

    /// A beat row is hovered: the ring temporarily points at that beat's control.
    func peekRing(_ g: TourRingGeometry) {
        guard ringVisible else { return }
        apply(g, animated: !reduceMotion)
    }

    // MARK: Hints (C.4.2)

    /// Ghost cursor: floats from the card's beak to `target` twice; panel-edge
    /// glow breathes with the ring. Both stop in `stopHint()` — the same frame
    /// the mouse enters the panel.
    func startHover(target: CGPoint) {
        guard !reduceMotion else { return }
        ghostTarget = target
        ghostStart = clock.now + T.ghostDelay
        glowStart = clock.now
        glowFollowsBreath = true
        glowCycles = T.breathCycles
    }

    /// The move step's invitation: only the soft glow, three cycles.
    func startGestureGlow() {
        guard !reduceMotion else { return }
        ghostStart = nil
        glowStart = clock.now
        glowFollowsBreath = false
        glowCycles = T.breathCycles
    }

    func stopHint() {
        ghostStart = nil
        glowStart = nil
    }

    var hintRunning: Bool { ghostStart != nil || glowStart != nil }

    // MARK: Frame

    func makeFrame() -> TourGuidanceFrame {
        var f = TourGuidanceFrame()
        f.cardVisible = cardVisible || cop.v > 0.003
        f.cardX = cx.v; f.cardTop = ctop.v; f.cardHeight = ch.v; f.cardWidth = cardWidth
        f.cardBeakSide = beakSide; f.cardBeakOffset = bOff.v
        f.beakScale = bScale.v
        f.cardOpacity = cop.v; f.cardScale = csc.v
        f.cardApproach = capp.v
        f.contentOpacity = contentOp.map { $0.v }
        f.contentOffsetY = contentY.map { $0.v }
        f.glyphPresence = glyph.v
        if let g = glyphStart, glyphIsRunning { f.glyphElapsed = max(clock.now - g, 0) }

        f.ringVisible = ringVisible || hop.v > 0.003
        f.ring = TourRingGeometry(cx: hx.v, cy: hy.v, w: hw.v, h: hh.v, corner: ringCorner)
        f.ringOpacity = hop.v; f.ringScale = hsc.v; f.ringPulse = hpulse.v
        f.ringDashed = ringMode == .hint

        // Breathing + sonar ripples
        if let s = breathStart, !reduceMotion {
            let u = clock.now - s - T.breathDelay
            if u >= 0 {
                let p = u / T.breathPeriod
                if p < T.breathCycles { f.breath = 0.5 - 0.5 * cos(2 * Double.pi * p) }
                for c in 0..<Int(T.breathCycles) {
                    let ru = u - Double(c) * T.breathPeriod
                    if ru >= 0, ru < T.rippleDuration { f.ripples.append(ru / T.rippleDuration) }
                }
            }
        }

        // Ghost cursor
        if let g = ghostStart, !reduceMotion {
            let u = clock.now - g
            if u >= 0 {
                let c = Int(u / T.ghostCycle)
                if c < T.ghostCycles {
                    let t = u - Double(c) * T.ghostCycle
                    let start = currentCardPose.beakTip
                    let p = TourFeedbackEase.io.value(min(max((t - 0.25) / 0.9, 0), 1))
                    let mx = (start.x + ghostTarget.x) / 2
                    let my = (start.y + ghostTarget.y) / 2 + T.ghostArc   // screen y is up: "arch upward"
                    let x = (1 - p) * (1 - p) * start.x + 2 * (1 - p) * p * mx + p * p * ghostTarget.x
                    let y = (1 - p) * (1 - p) * start.y + 2 * (1 - p) * p * my + p * p * ghostTarget.y
                    let fadeIn = min(max(t / 0.2, 0), 1)
                    let fadeOut = 1 - min(max((t - 2.05) / 0.3, 0), 1)
                    f.ghostVisible = true
                    f.ghost = CGPoint(x: x, y: y)
                    f.ghostOpacity = fadeIn * fadeOut * 0.92
                    let rp = (t - 1.2) / 0.55
                    f.ghostRipple = (rp > 0 && rp < 1) ? rp : nil
                }
            }
        }

        // Panel-edge glow
        if let g = glowStart, !reduceMotion {
            let u = clock.now - g - (glowFollowsBreath ? T.breathDelay : 0)
            if u >= 0 {
                let p = u / T.breathPeriod
                if p < glowCycles { f.panelGlow = 0.5 - 0.5 * cos(2 * Double.pi * p) }
            }
        }
        return f
    }
}
