/**
 * [INPUT]: The card's rect and the screen edge (LiquidEdgeGeometry, in the
 *          stage window's top-left coordinates, always as if the edge were on
 *          the right; the left edge is a mirror applied when drawing).
 * [OUTPUT]: LiquidEdgeState + reducer (card / collapsing / tucked / floating
 *           / expanding); LiquidEdgePose — every on-screen channel as plain
 *           numbers; LiquidEdgePoses — resting and in-between key poses for a
 *           geometry; LiquidEdgePlan / LiquidEdgeMotion — pose as a pure
 *           function of time (Apple's Spring math, stages added on top of each
 *           other, launched at speed, velocity-continuous retargeting).
 * [POS]: Port of research/spikes/edge-collapse-spike (founder-approved
 *        2026-09-22) into the app. Pure data + math: no views, no clocks.
 * [PROTOCOL]: One object: "body" is the card, the squashed card, the stalk
 *             and the edge sliver; "capsule" is the drop that pinches off the
 *             sliver and becomes the capsule. At rest only one is visible.
 *             The body's horizontal channel is its edge-side x (maxX), so a
 *             spring overshoot pushes it INTO the screen edge.
 */

import SwiftUI

// MARK: - Tokens

public enum LiquidEdgeTokens {
    public static let cardCornerRadius: CGFloat = 16
    /// The tucked sliver: a little black joined to the bezel.
    public static let sliverSize = CGSize(width: 6, height: 56)
    /// Extra hover target around the sliver.
    public static let tuckedPadInward: CGFloat = 4
    public static let tuckedPadVertical: CGFloat = 6
    /// The cursor must rest this long on the sliver before the capsule comes out.
    public static let hoverDwell: Double = 0.08

    // Drop and blob
    public static let dropDiameter: CGFloat = 22
    public static let dropNeckGap: CGFloat = 0
    public static let blobDiameter: CGFloat = 84
    /// Smooth-union width between the edge body and the capsule.
    public static let liquidNeck: CGFloat = 24

    // Capsule
    public static let capsuleArtwork: CGFloat = 96
    public static let capsuleArtworkCorner: CGFloat = 14
    public static let capsulePadding: CGFloat = 12
    public static let capsuleTextHeight: CGFloat = 34
    public static let capsuleControlsHeight: CGFloat = 40
    public static let capsuleCornerRadius: CGFloat = 26
    public static let capsuleEdgeGap: CGFloat = 14
    public static var capsuleSize: CGSize {
        CGSize(width: capsuleArtwork + capsulePadding * 2,
               height: capsulePadding + capsuleArtwork + 8 + capsuleTextHeight + 4 + capsuleControlsHeight + 10)
    }
    public static let floatingHoverExitExpand: CGFloat = 14

    public static let contentBlur: CGFloat = 6

    // Edge light (progress) along the sliver.
    public static let glowLength: CGFloat = 56
    public static let glowGatheredLength: CGFloat = 22

    // Black thinning into the edge-side gradient (Siri panel look).
    public static let edgeDimOpacity: Double = 0.92
    public static let edgeDimMidOpacity: Double = 0.40
    public static let edgeDimInnerOpacity: Double = 0.12

    /// How close (pt) the card must be to a screen edge for a swipe toward it
    /// to tuck it (the snapped corner margin is 16).
    public static let edgeProximity: CGFloat = 28
    /// Room the stage window keeps around the card (shadow, sliver, bounce).
    public static let stageMargin: CGFloat = 28
}

// MARK: - State machine

public enum LiquidEdgeState: String, CaseIterable, Equatable, Sendable {
    case card, collapsing, tucked, floating, expanding

    public var layout: LiquidEdgeKeyPose {
        switch self {
        case .card, .expanding: return .card
        case .tucked, .collapsing: return .tucked
        case .floating: return .floating
        }
    }
}

public enum LiquidEdgeEvent: Equatable, Sendable {
    case collapseRequested, hoverEntered, hoverExited, expandRequested, settled
}

public enum LiquidEdgeReducer {
    public static func reduce(_ state: LiquidEdgeState, _ event: LiquidEdgeEvent) -> LiquidEdgeState {
        switch (state, event) {
        case (.card, .collapseRequested): return .collapsing
        case (.collapsing, .settled): return .tucked
        case (.tucked, .hoverEntered): return .floating
        case (.tucked, .expandRequested): return .expanding
        case (.floating, .hoverExited): return .tucked
        case (.floating, .expandRequested): return .expanding
        case (.expanding, .settled): return .card
        default: return state
        }
    }
}

// MARK: - Pose

public struct LiquidEdgePose: Equatable {
    public var body: CGRect
    public var bodyCornerInner: CGFloat
    public var bodyCornerEdge: CGFloat
    public var capsule: CGRect
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
    /// 0 = pure black fill (no glass), 1 = glass with the edge-side gradient.
    public var glass: Double = 0
    /// Edge light (tucked): brightness 0...1 and lit length.
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
        dim = v[22]; glass = v[23]
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

    /// This pose with the channels of `groups` taken from `other`.
    public func taking(_ groups: Set<LiquidEdgeChannelGroup>, from other: LiquidEdgePose) -> LiquidEdgePose {
        var v = vector()
        let o = other.vector()
        for i in v.indices where groups.contains(LiquidEdgeChannelGroup.map[i]) { v[i] = o[i] }
        return LiquidEdgePose(vector: v)
    }
}

/// Which spring/delay a channel follows. Geometry is split per axis so one
/// spring per channel can change a shape's proportions (round, then tall).
public enum LiquidEdgeChannelGroup: Int, CaseIterable, Sendable {
    case bodyH, bodyV, bodyCorner
    case capsuleH, capsuleV, capsuleCorner
    case hero, heroFade, panel, capsuleContent, stripContent, dim, material, glow

    public static let map: [LiquidEdgeChannelGroup] = [
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
}

/// Resting states and the in-between shapes the references show.
public enum LiquidEdgeKeyPose: String, CaseIterable, Sendable {
    case card, tucked, floating
    case squash, stalk, drop, blob, expandBlob
}

// MARK: - Geometry

/// Where things are, in the stage window's top-left coordinates, as if the
/// screen edge were on the right.
public struct LiquidEdgeGeometry: Equatable, Sendable {
    public var card: CGRect
    public var edgeX: CGFloat
    public init(card: CGRect, edgeX: CGFloat) { self.card = card; self.edgeX = edgeX }

    /// The prototype's layout (a 250x316 card 16pt off the edge in a 320x360
    /// stage) — used by tests, whose numbers were tuned on it.
    public static let reference = LiquidEdgeGeometry(card: CGRect(x: 54, y: 22, width: 250, height: 316), edgeX: 320)
}

public struct LiquidEdgePoses {
    public let g: LiquidEdgeGeometry
    public init(_ g: LiquidEdgeGeometry) { self.g = g }

    typealias T = LiquidEdgeTokens
    var edge: CGFloat { g.edgeX }
    var midY: CGFloat { g.card.midY }

    public var cardRect: CGRect { g.card }

    public var tuckedRect: CGRect {
        let s = T.sliverSize
        return CGRect(x: edge - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
    }

    var bulgedRect: CGRect {
        let r = tuckedRect
        let w = r.width + 6, h = r.height * 0.72
        return CGRect(x: edge - w, y: midY - h / 2, width: w, height: h)
    }

    public var capsuleRect: CGRect {
        let s = T.capsuleSize
        return CGRect(x: edge - T.capsuleEdgeGap - s.width, y: midY - s.height / 2, width: s.width, height: s.height)
    }

    public var capsuleCoverRect: CGRect {
        let c = capsuleRect
        return CGRect(x: c.midX - T.capsuleArtwork / 2, y: c.minY + T.capsulePadding, width: T.capsuleArtwork, height: T.capsuleArtwork)
    }

    var dropRect: CGRect {
        let d = T.dropDiameter
        let maxX = bulgedRect.minX - T.dropNeckGap
        return CGRect(x: maxX - d, y: midY - d / 2, width: d, height: d)
    }

    var blobRect: CGRect {
        let d = T.blobDiameter
        return CGRect(x: capsuleRect.midX - d / 2, y: midY - d / 2, width: d, height: d)
    }

    var expandBlobRect: CGRect {
        let d = min(196, g.card.width * 0.8)
        let cx = (capsuleRect.midX + g.card.midX) / 2
        return CGRect(x: cx - d / 2, y: midY - d / 2, width: d, height: d)
    }

    var squashRect: CGRect {
        let c = g.card
        let w = c.width * 0.92, h = c.height * 0.46
        return CGRect(x: c.maxX + 2 - w, y: midY - h / 2, width: w, height: h)
    }

    var stalkRect: CGRect {
        let w: CGFloat = 16
        let h = tuckedRect.height * 1.6
        return CGRect(x: edge - 6 - w, y: midY - h / 2, width: w, height: h)
    }

    /// The two parts of the one liquid outline. A body near the screen edge
    /// is extended past it (continuously with its distance to the edge), so
    /// at the edge it has no edge-side corners and joins the bezel.
    public func liquidParts(_ p: LiquidEdgePose) -> [LiquidPart] {
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

    /// Horizontal span of the black-to-gradient fill: always the body's own
    /// rect (on the screen edge even at zero width) plus the capsule, so the
    /// dark end never jumps when the sliver drains away.
    public func fillSpan(_ p: LiquidEdgePose) -> (minX: CGFloat, maxX: CGFloat) {
        let b = p.body
        var lo = b.maxX - max(b.width, 0), hi = b.maxX
        if p.capsule.width > 0 { lo = min(lo, p.capsule.minX); hi = max(hi, p.capsule.maxX) }
        return (lo, min(hi, edge))
    }

    static func coverIn(_ r: CGRect, inset: CGFloat) -> CGRect {
        let s = max(min(r.width, r.height) - inset * 2, 0)
        return CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s)
    }

    public func pose(_ key: LiquidEdgeKeyPose) -> LiquidEdgePose {
        let card = g.card
        let tucked = tuckedRect
        let parked = { (r: CGRect) in CGRect(x: r.midX - 1, y: r.midY - 1, width: 2, height: 2) }
        // Gone = drained into the drop: no width and almost no height.
        let gone = CGRect(x: edge, y: midY - 4, width: 0, height: 8)
        // The flying cover belongs to the capsule only; the real panel never
        // migrates — the liquid reveals or covers it in place.
        let capCover = capsuleCoverRect
        switch key {
        case .card:
            return LiquidEdgePose(
                body: card, bodyCornerInner: T.cardCornerRadius, bodyCornerEdge: T.cardCornerRadius,
                capsule: parked(card), capsuleCorner: 1,
                hero: capCover, heroCorner: T.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 0, dim: 0, glass: 1)
        case .squash:
            let r = squashRect
            return LiquidEdgePose(
                body: r, bodyCornerInner: 44, bodyCornerEdge: 36,
                capsule: parked(r), capsuleCorner: 1,
                hero: capCover, heroCorner: T.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 0, dim: 1, glass: 0.4)
        case .stalk:
            let r = stalkRect
            return LiquidEdgePose(
                body: r, bodyCornerInner: r.width / 2, bodyCornerEdge: r.width / 2,
                capsule: parked(r), capsuleCorner: 1,
                hero: capCover, heroCorner: T.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 0, dim: 1)
        case .tucked:
            let d = dropRect
            return LiquidEdgePose(
                body: tucked, bodyCornerInner: tucked.width / 2, bodyCornerEdge: 0,
                capsule: CGRect(x: tucked.midX, y: midY, width: 0, height: 0), capsuleCorner: 100,
                hero: Self.coverIn(d, inset: 6), heroCorner: 8, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 1, dim: 1, glow: 1, glowLength: Double(T.glowLength))
        case .drop:
            let b = bulgedRect
            let d = dropRect
            return LiquidEdgePose(
                body: b, bodyCornerInner: b.width / 2, bodyCornerEdge: 0,
                capsule: d, capsuleCorner: d.width / 2,
                hero: Self.coverIn(d, inset: 6), heroCorner: 8, heroOpacity: 0, heroBlur: 2,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 0, dim: 1, glow: 1, glowLength: Double(T.glowGatheredLength))
        case .blob:
            let r = blobRect
            return LiquidEdgePose(
                body: gone, bodyCornerInner: 0, bodyCornerEdge: 0,
                capsule: r, capsuleCorner: r.width / 2,
                hero: Self.coverIn(r, inset: 12), heroCorner: 16, heroOpacity: 1, heroBlur: 1,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 0, dim: 1)
        case .floating:
            return LiquidEdgePose(
                body: gone, bodyCornerInner: 0, bodyCornerEdge: 0,
                capsule: capsuleRect, capsuleCorner: T.capsuleCornerRadius,
                hero: capCover, heroCorner: T.capsuleArtworkCorner, heroOpacity: 1, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 1, capsuleContentBlur: 0,
                stripContentOpacity: 0, dim: 1, glass: 1)
        case .expandBlob:
            let r = expandBlobRect
            return LiquidEdgePose(
                body: gone, bodyCornerInner: 0, bodyCornerEdge: 0,
                capsule: r, capsuleCorner: r.width / 2,
                hero: capCover, heroCorner: T.capsuleArtworkCorner, heroOpacity: 0, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: T.contentBlur,
                stripContentOpacity: 0, dim: 1, glass: 1)
        }
    }

    /// End of an expand: the capsule IS the card; the edge body stays gone.
    /// Once the opaque panel covers it, the controller swaps to the resting
    /// card pose (same silhouette, hidden under the panel).
    public var cardFromCapsule: LiquidEdgePose {
        var p = pose(.card)
        p.body = CGRect(x: edge, y: tuckedRect.minY, width: 0, height: tuckedRect.height * 0.6)
        p.bodyCornerInner = 0; p.bodyCornerEdge = 0
        p.capsule = g.card
        p.capsuleCorner = T.cardCornerRadius
        return p
    }

    // MARK: Hit regions

    public func tuckedRegion() -> CGRect {
        let len = T.glowLength
        let r = CGRect(x: edge - T.sliverSize.width, y: midY - len / 2, width: T.sliverSize.width, height: len)
        return CGRect(x: r.minX - T.tuckedPadInward, y: r.minY - T.tuckedPadVertical,
                      width: r.width + T.tuckedPadInward, height: r.height + T.tuckedPadVertical * 2)
    }

    public func hitRegion(for state: LiquidEdgeState) -> CGRect {
        switch state.layout {
        case .tucked: return tuckedRegion()
        case .floating:
            let u = tuckedRegion().union(capsuleRect)
            let pad = T.floatingHoverExitExpand
            return u.insetBy(dx: -pad, dy: -pad)
        default: return g.card
        }
    }
}

// MARK: - Motion

public struct LiquidEdgePlan {
    public struct Step {
        public var spring: Spring
        public var delay: Double
        public var nominal: Double
        /// Overrides the stage's launch for this group (stage 0 only).
        public var impulse: Double? = nil
    }
    public var steps: [LiquidEdgeChannelGroup: Step]
    public var fallback: Step

    public init(_ steps: [LiquidEdgeChannelGroup: Step], fallback: Step) {
        self.steps = steps; self.fallback = fallback
    }

    public func step(for group: LiquidEdgeChannelGroup) -> Step { steps[group] ?? fallback }

    public static func step(_ d: Double, _ b: Double, delay: Double = 0, impulse: Double? = nil) -> Step {
        Step(spring: Spring(duration: d, bounce: b), delay: delay, nominal: d, impulse: impulse)
    }
}

public enum LiquidEdgeTransition: String, Sendable, CaseIterable {
    case collapse, floatOut, retract, expand
}

/// A chain of spring stages added on top of each other: stage k starts at
/// `start` and moves every channel by (its target - the previous target).
public struct LiquidEdgeMotion {
    public struct Stage {
        public var start: Double
        public var to: [Double]
        public var plan: LiquidEdgePlan
        /// Stage 0 only: launch at speed. 1 = initial velocity w*delta, which
        /// makes a critically damped spring a pure exponential ease-out —
        /// fastest on the first frame, no overshoot (a spring from rest eases
        /// IN first and reads as a delay).
        public var impulse: Double = 0
        public init(start: Double, to: [Double], plan: LiquidEdgePlan, impulse: Double = 0) {
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

    private func delta(_ k: Int, _ i: Int) -> Double {
        stages[k].to[i] - (k == 0 ? from[i] : stages[k - 1].to[i])
    }

    private func delay(_ k: Int, _ i: Int, _ step: LiquidEdgePlan.Step) -> Double {
        k == 0 && abs(velocity[i]) > 1e-3 ? 0 : step.delay
    }

    private func v0(_ k: Int, _ i: Int, _ step: LiquidEdgePlan.Step) -> Double {
        guard k == 0 else { return 0 }
        if abs(velocity[i]) > 1e-9 { return velocity[i] }
        let launch = step.impulse ?? stages[0].impulse
        guard launch > 0, step.delay == 0, step.nominal > 0 else { return 0 }
        return launch * (2 * Double.pi / step.nominal) * delta(0, i)
    }

    public func sample(at t: Double) -> (value: [Double], velocity: [Double]) {
        var value = from, vel = Array(repeating: 0.0, count: from.count)
        for i in 0..<from.count {
            let g = LiquidEdgeChannelGroup.map[i]
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

    /// When the eye reads the transition as finished (the state settles here).
    public var nominalDuration: Double {
        var longest = 0.0
        for k in stages.indices {
            for g in LiquidEdgeChannelGroup.allCases {
                let moves = LiquidEdgeChannelGroup.map.indices.contains { LiquidEdgeChannelGroup.map[$0] == g && abs(delta(k, $0)) > 1e-6 }
                guard moves else { continue }
                let s = stages[k].plan.step(for: g)
                longest = max(longest, stages[k].start + s.delay + s.nominal)
            }
        }
        return longest
    }

    /// When every channel is within 0.1 of its target (the motion stops).
    public var settledDuration: Double {
        var longest = nominalDuration
        for k in stages.indices {
            for i in 0..<from.count {
                let d = delta(k, i)
                let step = stages[k].plan.step(for: LiquidEdgeChannelGroup.map[i])
                let v0 = self.v0(k, i, step)
                guard abs(d) > 1e-6 || abs(v0) > 1e-6 else { continue }
                let settle = step.spring.settlingDuration(target: d, initialVelocity: v0, epsilon: 0.1)
                longest = max(longest, stages[k].start + delay(k, i, step) + settle)
            }
        }
        return longest
    }
}
