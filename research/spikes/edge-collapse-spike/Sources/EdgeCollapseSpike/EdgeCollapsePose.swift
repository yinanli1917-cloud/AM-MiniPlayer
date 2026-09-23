/**
 * [INPUT]: key pose name + current page (album / lyrics / playlist) + tuck style.
 * [OUTPUT]: EdgeCollapsePose — every on-screen channel as plain numbers;
 *           EdgeCollapsePoses — resting and in-between key poses;
 *           EdgeCollapsePlan — spring + delay per channel group;
 *           EdgeCollapseMotion — pose as a pure function of time: a chain of
 *           spring stages added on top of each other (spring superposition),
 *           so a shape can bulge, neck and then stretch in one continuous
 *           motion, and a new motion can start from any value + velocity.
 * [POS]: App-portable pure data + math; no views, no clocks.
 * [PROTOCOL]: v9 (2026-09-22). One object: glass "body" is the card, the
 *             squashed card, the stalk and the edge handle; glass "bud" is
 *             the drop that pinches off the handle and becomes the capsule.
 *             At rest only one of them is visible (the other is inside it or
 *             has zero width). The body's horizontal channel is its RIGHT
 *             edge, so a spring overshoot pushes it into the screen edge
 *             instead of pulling it off the edge.
 */

import SwiftUI
import MusicMiniPlayerCore

public struct EdgeCollapsePose: Equatable {
    public var body: CGRect
    public var bodyCornerInner: CGFloat
    public var bodyCornerEdge: CGFloat
    public var capsule: CGRect          // glass "bud"
    public var capsuleCorner: CGFloat
    public var hero: CGRect
    public var heroCorner: CGFloat
    public var heroOpacity: Double
    public var heroBlur: CGFloat
    public var panelOpacity: Double
    public var capsuleContentOpacity: Double
    public var capsuleContentBlur: CGFloat
    public var stripContentOpacity: Double
    public var dim: Double
    /// 0 = pure black fill (no glass at all), 1 = glass with the edge-side
    /// gradient. System glass can never be pure black and always has a rim,
    /// so the black states are not glass (founder 2026-09-22).
    public var glass: Double = 0
    /// The edge light (tucked): brightness 0...1 and lit length in points.
    /// Tucked is ONLY this light on the screen edge; no black body at all
    /// (founder 2026-09-22: a black tab reads as a cheap patch).
    public var glow: Double = 0
    public var glowLength: Double = 0

    public static let channelCount = 26

    public func vector() -> [Double] {
        [body.maxX, body.minY, body.width, body.height, bodyCornerInner, bodyCornerEdge,
         capsule.minX, capsule.minY, capsule.width, capsule.height, capsuleCorner,
         hero.minX, hero.minY, hero.width, hero.height, heroCorner,
         heroOpacity, heroBlur,
         panelOpacity,
         capsuleContentOpacity, capsuleContentBlur,
         stripContentOpacity,
         dim, glass, glow, glowLength].map { Double($0) }
    }

    public init(vector v: [Double]) {
        precondition(v.count == Self.channelCount)
        body = CGRect(x: v[0] - v[2], y: v[1], width: v[2], height: v[3])
        bodyCornerInner = v[4]; bodyCornerEdge = v[5]
        capsule = CGRect(x: v[6], y: v[7], width: v[8], height: v[9])
        capsuleCorner = v[10]
        hero = CGRect(x: v[11], y: v[12], width: v[13], height: v[14])
        heroCorner = v[15]
        heroOpacity = v[16]; heroBlur = v[17]
        panelOpacity = v[18]
        capsuleContentOpacity = v[19]; capsuleContentBlur = v[20]
        stripContentOpacity = v[21]
        dim = v[22]
        glass = v[23]
        glow = v[24]; glowLength = v[25]
    }

    public init(body: CGRect, bodyCornerInner: CGFloat, bodyCornerEdge: CGFloat,
                capsule: CGRect, capsuleCorner: CGFloat,
                hero: CGRect, heroCorner: CGFloat, heroOpacity: Double, heroBlur: CGFloat,
                panelOpacity: Double, capsuleContentOpacity: Double, capsuleContentBlur: CGFloat,
                stripContentOpacity: Double, dim: Double, glass: Double = 0,
                glow: Double = 0, glowLength: Double = 0) {
        self.body = body; self.bodyCornerInner = bodyCornerInner; self.bodyCornerEdge = bodyCornerEdge
        self.capsule = capsule; self.capsuleCorner = capsuleCorner
        self.hero = hero; self.heroCorner = heroCorner; self.heroOpacity = heroOpacity; self.heroBlur = heroBlur
        self.panelOpacity = panelOpacity
        self.capsuleContentOpacity = capsuleContentOpacity; self.capsuleContentBlur = capsuleContentBlur
        self.stripContentOpacity = stripContentOpacity; self.dim = dim; self.glass = glass
        self.glow = glow; self.glowLength = glowLength
    }
}

/// Which spring/delay a channel follows.
public enum EdgeCollapseChannelGroup: Int, CaseIterable, Sendable {
    // Geometry is split per axis so a shape can change its proportions
    // (round first, then tall) within ONE spring per channel.
    case bodyH, bodyV, bodyCorner
    case capsuleH, capsuleV, capsuleCorner
    case hero, heroFade, panel, capsuleContent, stripContent, dim, material, glow

    /// Channel index → group, same order as `EdgeCollapsePose.vector()`:
    /// body maxX, minY, width, height, cornerInner, cornerEdge;
    /// capsule minX, minY, width, height, corner; hero ×5; heroOpacity,
    /// heroBlur; panel; capsule content ×2; strip; dim; glass; glow ×2.
    public static let map: [EdgeCollapseChannelGroup] = [
        .bodyH, .bodyV, .bodyH, .bodyV, .bodyCorner, .bodyCorner,
        .capsuleH, .capsuleV, .capsuleH, .capsuleV, .capsuleCorner,
        .hero, .hero, .hero, .hero, .hero,
        .heroFade, .heroFade,
        .panel,
        .capsuleContent, .capsuleContent,
        .stripContent,
        .dim,
        .material,
        .glow, .glow,
    ]

    /// Geometry groups (the ones whose speed the eye follows).
    public static let geometry: [EdgeCollapseChannelGroup] = [.bodyH, .bodyV, .capsuleH, .capsuleV]
}

/// Resting states and the in-between shapes the references show.
public enum EdgeCollapseKeyPose: String, CaseIterable, Sendable {
    case card, tucked, floating
    /// Collapse, ref1: height goes first while width stays wide.
    case squash
    /// Collapse, ref1: a stalk narrower than both ends, right at the edge.
    case stalk
    /// Hover, ref4: the handle bulges and a small drop necks out of it.
    case drop
    /// Hover / expand, ref1: a round blob, rounder than both ends.
    case blob
    /// Expand, ref1: the capsule bulges round before stretching into the card.
    case expandBlob
}

public enum EdgeCollapsePoses {
    static var t: EdgeCollapseTokens.Type { EdgeCollapseTokens.self }
    static var edge: CGFloat { t.containerSize.width }
    static var midY: CGFloat { t.containerSize.height / 2 }

    // MARK: Rects

    public static var cardRect: CGRect {
        let s = t.cardSize
        return CGRect(x: edge - t.cardEdgeMargin - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
    }

    public static func tuckedRect(_ style: EdgeCollapseTuckStyle) -> CGRect {
        let s = t.handleSize
        return CGRect(x: edge - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
    }

    /// The tucked shape bulged (rounder) while the drop squeezes out.
    static func bulgedRect(_ style: EdgeCollapseTuckStyle) -> CGRect {
        let r = tuckedRect(style)
        let w = r.width + 6, h = r.height * 0.72
        return CGRect(x: edge - w, y: midY - h / 2, width: w, height: h)
    }

    public static var capsuleRect: CGRect {
        let s = t.capsuleSize
        return CGRect(x: edge - t.capsuleEdgeGap - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
    }

    public static var capsuleCoverRect: CGRect {
        let c = capsuleRect
        return CGRect(x: c.midX - t.capsuleArtwork / 2, y: c.minY + t.capsulePadding, width: t.capsuleArtwork, height: t.capsuleArtwork)
    }

    static func dropRect(_ style: EdgeCollapseTuckStyle) -> CGRect {
        let d = t.dropDiameter
        let maxX = bulgedRect(style).minX - t.dropNeckGap
        return CGRect(x: maxX - d, y: midY - d / 2, width: d, height: d)
    }

    static var blobRect: CGRect {
        let d = t.blobDiameter
        return CGRect(x: capsuleRect.midX - d / 2, y: midY - d / 2, width: d, height: d)
    }

    static var expandBlobRect: CGRect {
        let d: CGFloat = 196
        let cx = (capsuleRect.midX + cardRect.midX) / 2
        return CGRect(x: cx - d / 2, y: midY - d / 2, width: d, height: d)
    }

    static var squashRect: CGRect {
        let c = cardRect
        let w = c.width * 0.92, h = c.height * 0.46
        return CGRect(x: c.maxX + 2 - w, y: midY - h / 2, width: w, height: h)
    }

    static func stalkRect(_ style: EdgeCollapseTuckStyle) -> CGRect {
        let w: CGFloat = 16
        let h = tuckedRect(style).height * 1.6
        return CGRect(x: edge - 6 - w, y: midY - h / 2, width: w, height: h)
    }

    /// Where the cover sits in the real panel on each page.
    public static func cardHero(_ page: PlayerPage) -> (rect: CGRect, corner: CGFloat, blur: CGFloat) {
        let c = cardRect
        switch page {
        case .album:
            return (CGRect(x: c.minX, y: c.minY, width: c.width, height: c.width), t.cardCornerRadius, 0)
        case .playlist:
            // MiniPlayerView playlist page: min(w*0.18, 60), 12+12 in, 36+8+12 down.
            let s = min(c.width * 0.18, 60)
            return (CGRect(x: c.minX + 24, y: c.minY + 56, width: s, height: s), 6, 0)
        case .lyrics:
            // No cover on the lyrics page: the cover fills the card, blurred —
            // it becomes the page's own artwork-coloured background.
            let s = max(c.width, c.height)
            return (CGRect(x: c.midX - s / 2, y: c.midY - s / 2, width: s, height: s), 0, t.lyricsBackdropBlur)
        }
    }

    /// The two parts of the one liquid outline for a pose. A body near the
    /// screen edge is extended past it, continuously with its distance to the
    /// edge, so at the edge it has no right-hand corners and joins the bezel.
    /// (v11 switched the extension on at maxX >= edge - 0.5: the corners
    /// snapped from round to flat at that frame.)
    public static func liquidParts(_ p: EdgeCollapsePose) -> [LiquidPart] {
        var b = p.body
        let visible = min(max(b.width, 0), max(b.height, 0))
        if b.width > 0 {
            let reach: CGFloat = 12
            let w = min(max((b.maxX - (edge - reach)) / reach, 0), 1)
            b.size.width += w * (p.bodyCornerInner + 6)
        }
        return [LiquidPart(rect: b, radius: p.bodyCornerInner, size: visible),
                LiquidPart(rect: p.capsule, radius: p.capsuleCorner)]
    }

    /// A cover square centred in `r`, inset.
    static func coverIn(_ r: CGRect, inset: CGFloat) -> CGRect {
        let s = max(min(r.width, r.height) - inset * 2, 0)
        return CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s)
    }

    /// Fill `r` with a square cover (aspect fill).
    static func coverFill(_ r: CGRect) -> CGRect {
        let s = max(r.width, r.height)
        return CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s)
    }

    static func tuckedHero(_ style: EdgeCollapseTuckStyle) -> (rect: CGRect, opacity: Double) {
        let r = tuckedRect(style)
        return (CGRect(x: r.midX - 3, y: r.midY - 3, width: 6, height: 6), 0)
    }

    // MARK: Poses

    public static func pose(_ key: EdgeCollapseKeyPose, page: PlayerPage, style: EdgeCollapseTuckStyle) -> EdgeCollapsePose {
        let card = cardRect
        let tucked = tuckedRect(style)
        let parked = { (r: CGRect) in CGRect(x: r.midX - 1, y: r.midY - 1, width: 2, height: 2) }
        // Gone = drained into the drop: no width AND almost no height, so no
        // stub is left at the edge after the neck breaks.
        let gone = CGRect(x: edge, y: midY - 4, width: 0, height: 8)
        // The flying cover belongs to the capsule only. The real panel never
        // migrates: it stays where it is and the liquid reveals or covers it
        // (founder 2026-09-22: expanding should BE the panel, not move text).
        let capCover = capsuleCoverRect
        switch key {
        case .card:
            return EdgeCollapsePose(
                body: card, bodyCornerInner: t.cardCornerRadius, bodyCornerEdge: t.cardCornerRadius,
                capsule: parked(card), capsuleCorner: 1,
                hero: capCover, heroCorner: t.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 0, glass: 1)
        case .squash:
            // The panel is still there, now seen through the squashed liquid.
            let r = squashRect
            return EdgeCollapsePose(
                body: r, bodyCornerInner: 44, bodyCornerEdge: 36,
                capsule: parked(r), capsuleCorner: 1,
                hero: capCover, heroCorner: t.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 1, glass: 0.4)
        case .stalk:
            let r = stalkRect(style)
            return EdgeCollapsePose(
                body: r, bodyCornerInner: r.width / 2, bodyCornerEdge: r.width / 2,
                capsule: parked(r), capsuleCorner: 1,
                hero: capCover, heroCorner: t.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 1)
        case .tucked:
            // A thin black sliver joined to the bezel, so you can tell
            // something is there; the light runs along its inner edge.
            let d = dropRect(style)
            return EdgeCollapsePose(
                body: tucked, bodyCornerInner: tucked.width / 2, bodyCornerEdge: 0,
                capsule: CGRect(x: tucked.midX, y: midY, width: 0, height: 0), capsuleCorner: 100,
                hero: coverIn(d, inset: 6), heroCorner: 8, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 1, dim: 1, glow: 1, glowLength: Double(t.glowLength))
        case .drop:
            let b = bulgedRect(style)
            let d = dropRect(style)
            return EdgeCollapsePose(
                body: b, bodyCornerInner: b.width / 2, bodyCornerEdge: 0,
                capsule: d, capsuleCorner: d.width / 2,
                hero: coverIn(d, inset: 6), heroCorner: 8, heroOpacity: 0, heroBlur: 2,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 1, glow: 1, glowLength: Double(t.glowGatheredLength))
        case .blob:
            let r = blobRect
            return EdgeCollapsePose(
                body: gone, bodyCornerInner: 0, bodyCornerEdge: 0,
                capsule: r, capsuleCorner: r.width / 2,
                hero: coverIn(r, inset: 12), heroCorner: 16, heroOpacity: 1, heroBlur: 1,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 1)
        case .floating:
            return EdgeCollapsePose(
                body: gone, bodyCornerInner: 0, bodyCornerEdge: 0,
                capsule: capsuleRect, capsuleCorner: t.capsuleCornerRadius,
                hero: capCover, heroCorner: t.capsuleArtworkCorner, heroOpacity: 1, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 1, capsuleContentBlur: 0,
                stripContentOpacity: 0, dim: 1, glass: 1)
        case .expandBlob:
            // Bulging round, the liquid already shows the real panel inside
            // it; the capsule's cover and text fade where they are.
            let r = expandBlobRect
            return EdgeCollapsePose(
                body: gone, bodyCornerInner: 0, bodyCornerEdge: 0,
                capsule: r, capsuleCorner: r.width / 2,
                hero: capCover, heroCorner: t.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 1, glass: 1)
        }
    }

    /// End of an expand: the capsule IS the card; the edge body stays gone
    /// (growing it from the edge at the same time drew a second outline).
    /// Once the opaque panel covers it, the model swaps to the resting card
    /// pose in one frame (identical silhouette, hidden under the panel).
    static func cardFromCapsule(page: PlayerPage, style: EdgeCollapseTuckStyle) -> EdgeCollapsePose {
        var p = pose(.card, page: page, style: style)
        let tucked = tuckedRect(style)
        p.body = CGRect(x: edge, y: tucked.minY, width: 0, height: tucked.height * 0.6)
        p.bodyCornerInner = 0; p.bodyCornerEdge = 0
        p.capsule = cardRect
        p.capsuleCorner = t.cardCornerRadius
        return p
    }
}

extension EdgeCollapsePose {
    /// This pose with the channels of `groups` taken from `other`.
    public func taking(_ groups: Set<EdgeCollapseChannelGroup>, from other: EdgeCollapsePose) -> EdgeCollapsePose {
        var v = vector()
        let o = other.vector()
        for i in v.indices where groups.contains(EdgeCollapseChannelGroup.map[i]) { v[i] = o[i] }
        return EdgeCollapsePose(vector: v)
    }
}

/// One spring + delay per channel group.
public struct EdgeCollapsePlan {
    public struct Step {
        public var spring: Spring
        public var delay: Double
        public var nominal: Double
        /// Overrides the stage's launch for this group (stage 0 only).
        public var impulse: Double? = nil
    }
    public var steps: [EdgeCollapseChannelGroup: Step]
    public var fallback: Step

    public init(_ steps: [EdgeCollapseChannelGroup: Step], fallback: Step) {
        self.steps = steps; self.fallback = fallback
    }

    public func step(for group: EdgeCollapseChannelGroup) -> Step { steps[group] ?? fallback }

    public static func step(_ d: Double, _ b: Double, delay: Double = 0, tempo: EdgeCollapseTempo) -> Step {
        let k = tempo.rawValue
        return Step(spring: Spring(duration: d * k, bounce: b), delay: delay * k, nominal: d * k)
    }
}

public enum EdgeCollapseTransitionKind: String, Sendable, CaseIterable {
    case collapse, floatOut, retract, expand
}

/// A chain of spring stages. Stage k starts at `start` and moves every
/// channel by (its target − the previous stage's target); the stages add up,
/// so the path bends through each key pose without stopping at it.
public struct EdgeCollapseMotion {
    public struct Stage {
        public var start: Double
        public var to: [Double]
        public var plan: EdgeCollapsePlan
        /// Stage 0 only: launch at speed instead of from rest. 1 = initial
        /// velocity ω·Δ, which turns a critically damped spring into a pure
        /// exponential ease-out: fastest on the first frame, no overshoot.
        /// A spring from rest eases IN first (~3% moved after 16ms), which
        /// read as a delay (founder 2026-09-22).
        public var impulse: Double = 0
        public init(start: Double, to: [Double], plan: EdgeCollapsePlan, impulse: Double = 0) {
            self.start = start; self.to = to; self.plan = plan; self.impulse = impulse
        }
    }
    public let from: [Double]
    public let velocity: [Double]
    public let stages: [Stage]

    public var to: [Double] { stages.last?.to ?? from }

    public init(from: [Double], velocity: [Double], stages: [Stage]) {
        self.from = from; self.velocity = velocity; self.stages = stages
    }

    public init(from: [Double], velocity: [Double], to: [Double], plan: EdgeCollapsePlan) {
        self.init(from: from, velocity: velocity, stages: [Stage(start: 0, to: to, plan: plan)])
    }

    private func delta(_ k: Int, _ i: Int) -> Double {
        stages[k].to[i] - (k == 0 ? from[i] : stages[k - 1].to[i])
    }

    /// Initial velocity of channel i in stage k: carried over on stage 0, or
    /// launched by the stage's impulse (undelayed channels only).
    private func v0(_ k: Int, _ i: Int, _ step: EdgeCollapsePlan.Step) -> Double {
        guard k == 0 else { return 0 }
        if abs(velocity[i]) > 1e-9 { return velocity[i] }
        let launch = step.impulse ?? stages[0].impulse
        guard launch > 0, step.delay == 0, step.nominal > 0 else { return 0 }
        return launch * (2 * Double.pi / step.nominal) * delta(0, i)
    }

    /// Stage 0 channels already moving skip their delay (no mid-air freeze).
    private func delay(_ k: Int, _ i: Int, _ step: EdgeCollapsePlan.Step) -> Double {
        k == 0 && abs(velocity[i]) > 1e-3 ? 0 : step.delay
    }

    public func sample(at t: Double) -> (value: [Double], velocity: [Double]) {
        var value = from, vel = Array(repeating: 0.0, count: from.count)
        for i in 0..<from.count {
            let g = EdgeCollapseChannelGroup.map[i]
            var v = 0.0
            for k in stages.indices {
                let step = stages[k].plan.step(for: g)
                let v0 = self.v0(k, i, step)
                let d = delta(k, i)
                let tau = t - stages[k].start - delay(k, i, step)
                if tau <= 0 {
                    if k == 0 { v += velocity[i] }
                    continue
                }
                value[i] += step.spring.value(target: d, initialVelocity: v0, time: tau)
                v += step.spring.velocity(target: d, initialVelocity: v0, time: tau)
            }
            vel[i] = v
        }
        return (value, vel)
    }

    /// When the eye reads the transition as finished (state settles here).
    public var nominalDuration: Double {
        var longest = 0.0
        for k in stages.indices {
            for g in EdgeCollapseChannelGroup.allCases {
                let moves = EdgeCollapseChannelGroup.map.indices.contains { EdgeCollapseChannelGroup.map[$0] == g && abs(delta(k, $0)) > 1e-6 }
                guard moves else { continue }
                let s = stages[k].plan.step(for: g)
                longest = max(longest, stages[k].start + s.delay + s.nominal)
            }
        }
        return longest
    }

    /// When every channel is within 0.1 of its target (motion stops here).
    public var settledDuration: Double {
        var longest = nominalDuration
        for k in stages.indices {
            for i in 0..<from.count {
                let d = delta(k, i)
                let step = stages[k].plan.step(for: EdgeCollapseChannelGroup.map[i])
                let v0 = self.v0(k, i, step)
                guard abs(d) > 1e-6 || abs(v0) > 1e-6 else { continue }
                let settle = step.spring.settlingDuration(target: d, initialVelocity: v0, epsilon: 0.1)
                longest = max(longest, stages[k].start + delay(k, i, step) + settle)
            }
        }
        return longest
    }
}
