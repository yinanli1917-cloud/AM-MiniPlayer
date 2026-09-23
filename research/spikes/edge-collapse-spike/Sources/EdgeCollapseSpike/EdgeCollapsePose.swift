/**
 * [INPUT]: EdgeCollapseLayout.VisualLayout (card / tucked / floating).
 * [OUTPUT]: EdgeCollapsePose — every on-screen channel of the composition as
 *           plain numbers; EdgeCollapsePoses.pose(for:) — the three resting
 *           poses; EdgeCollapsePlan — which spring and delay each channel
 *           group gets per transition; EdgeCollapseMotion — pose as a pure
 *           function of time (Apple's own `Spring` math), with velocity so a
 *           transition started mid-flight continues without a jump.
 * [POS]: App-portable pure data + math; no views, no clocks.
 * [PROTOCOL]: v8 (2026-09-22). The model samples EdgeCollapseMotion once per
 *             display frame and assigns the pose without any SwiftUI
 *             animation. v7 issued ten withAnimation calls into one
 *             @Published struct per transition; the founder's recording
 *             showed holds and jumps that the plan did not contain.
 *             Stagger rule: the element that is largest on screen starts
 *             moving on the first frame; "lands last" comes from a longer
 *             spring, never from a delay on a visible element.
 */

import SwiftUI

public struct EdgeCollapsePose: Equatable {
    // Edge body (glass id "body"): the card in `.card`, the 6pt strip otherwise.
    public var body: CGRect
    public var bodyCornerInner: CGFloat
    public var bodyCornerEdge: CGFloat
    // Hover capsule (glass id "capsule"): parked inside the body when not floating.
    public var capsule: CGRect
    public var capsuleCorner: CGFloat
    // Cover image that flies between the panel, the capsule and the edge.
    public var hero: CGRect
    public var heroCorner: CGFloat
    public var heroOpacity: Double
    public var heroBlur: CGFloat
    // The real nanoPod panel (MiniPlayerView) on top of the card.
    public var panelOpacity: Double
    // Title, artist and the two buttons inside the capsule.
    public var capsuleContentOpacity: Double
    public var capsuleContentBlur: CGFloat
    // Progress fill inside the 6pt strip.
    public var stripContentOpacity: Double
    // Dimming layer on the glass (black at the screen edge).
    public var dim: Double

    public static let channelCount = 23

    public func vector() -> [Double] {
        [body.minX, body.minY, body.width, body.height, bodyCornerInner, bodyCornerEdge,
         capsule.minX, capsule.minY, capsule.width, capsule.height, capsuleCorner,
         hero.minX, hero.minY, hero.width, hero.height, heroCorner,
         heroOpacity, heroBlur,
         panelOpacity,
         capsuleContentOpacity, capsuleContentBlur,
         stripContentOpacity,
         dim].map { Double($0) }
    }

    public init(vector v: [Double]) {
        precondition(v.count == Self.channelCount)
        body = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
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
    }

    public init(body: CGRect, bodyCornerInner: CGFloat, bodyCornerEdge: CGFloat,
                capsule: CGRect, capsuleCorner: CGFloat,
                hero: CGRect, heroCorner: CGFloat, heroOpacity: Double, heroBlur: CGFloat,
                panelOpacity: Double, capsuleContentOpacity: Double, capsuleContentBlur: CGFloat,
                stripContentOpacity: Double, dim: Double) {
        self.body = body; self.bodyCornerInner = bodyCornerInner; self.bodyCornerEdge = bodyCornerEdge
        self.capsule = capsule; self.capsuleCorner = capsuleCorner
        self.hero = hero; self.heroCorner = heroCorner; self.heroOpacity = heroOpacity; self.heroBlur = heroBlur
        self.panelOpacity = panelOpacity
        self.capsuleContentOpacity = capsuleContentOpacity; self.capsuleContentBlur = capsuleContentBlur
        self.stripContentOpacity = stripContentOpacity; self.dim = dim
    }
}

/// Which spring/delay a channel follows. One group per thing the eye tracks.
public enum EdgeCollapseChannelGroup: Int, CaseIterable, Sendable {
    case body, capsule, hero, heroFade, panel, capsuleContent, stripContent, dim

    /// Channel index → group, same order as `EdgeCollapsePose.vector()`.
    public static let map: [EdgeCollapseChannelGroup] = {
        let counts: [(EdgeCollapseChannelGroup, Int)] = [
            (.body, 6), (.capsule, 5), (.hero, 5), (.heroFade, 2), (.panel, 1),
            (.capsuleContent, 2), (.stripContent, 1), (.dim, 1),
        ]
        var m: [EdgeCollapseChannelGroup] = []
        for (g, n) in counts { m.append(contentsOf: Array(repeating: g, count: n)) }
        return m
    }()
}

public enum EdgeCollapsePoses {
    static var container: CGSize { EdgeCollapseTokens.containerSize }

    /// Card rect: flush with the screen edge, vertically centred.
    public static var cardRect: CGRect {
        let s = EdgeCollapseTokens.cardSize
        return CGRect(x: container.width - s.width, y: (container.height - s.height) / 2, width: s.width, height: s.height)
    }

    /// Fullscreen-cover mode: the cover fills the card width, flush top.
    public static var cardCoverRect: CGRect {
        let c = cardRect
        return CGRect(x: c.minX, y: c.minY, width: c.width, height: c.width)
    }

    /// Tucked strip: the same footprint as the app's edge-hidden panel
    /// (SnappablePanel.edgeHiddenVisibleWidth = 6pt, full panel height).
    public static var stripRect: CGRect {
        let c = cardRect
        let w = EdgeCollapseTokens.stripWidth
        return CGRect(x: container.width - w, y: c.minY, width: w, height: c.height)
    }

    /// Hover capsule: a vertical card floating a small gap off the strip.
    public static var capsuleRect: CGRect {
        let t = EdgeCollapseTokens.self
        let size = t.capsuleSize
        let maxX = stripRect.minX - t.capsuleStripGap
        return CGRect(x: maxX - size.width, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    public static var capsuleCoverRect: CGRect {
        let t = EdgeCollapseTokens.self
        let c = capsuleRect
        return CGRect(x: c.midX - t.capsuleArtwork / 2, y: c.minY + t.capsulePadding, width: t.capsuleArtwork, height: t.capsuleArtwork)
    }

    /// Where the cover disappears into the edge: a speck on the strip at the
    /// cover's own height, so it slides into the edge rather than dropping.
    public static var tuckedHeroRect: CGRect {
        let s = stripRect
        let side = EdgeCollapseTokens.stripWidth
        return CGRect(x: s.minX, y: cardCoverRect.midY - side / 2, width: side, height: side)
    }

    public static func pose(for layout: EdgeCollapseLayout.VisualLayout) -> EdgeCollapsePose {
        let t = EdgeCollapseTokens.self
        switch layout {
        case .card:
            return EdgeCollapsePose(
                body: cardRect, bodyCornerInner: t.cardCornerRadius, bodyCornerEdge: t.cardCornerRadius,
                capsule: cardRect, capsuleCorner: t.cardCornerRadius,
                hero: cardCoverRect, heroCorner: t.cardCornerRadius, heroOpacity: 1, heroBlur: 0,
                panelOpacity: 1, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 0, dim: 0)
        case .tucked:
            return EdgeCollapsePose(
                body: stripRect, bodyCornerInner: t.stripCornerRadius, bodyCornerEdge: 0,
                capsule: stripRect, capsuleCorner: t.stripCornerRadius,
                hero: tuckedHeroRect, heroCorner: t.stripCornerRadius, heroOpacity: 0, heroBlur: t.heroTuckBlur,
                panelOpacity: 0, capsuleContentOpacity: 0, capsuleContentBlur: t.contentBlur,
                stripContentOpacity: 1, dim: 1)
        case .floating:
            return EdgeCollapsePose(
                body: stripRect, bodyCornerInner: t.stripCornerRadius, bodyCornerEdge: 0,
                capsule: capsuleRect, capsuleCorner: t.capsuleCornerRadius,
                hero: capsuleCoverRect, heroCorner: t.capsuleArtworkCorner, heroOpacity: 1, heroBlur: 0,
                panelOpacity: 0, capsuleContentOpacity: 1, capsuleContentBlur: 0,
                stripContentOpacity: 0, dim: 1)
        }
    }
}

/// One spring + delay per channel group for one transition.
public struct EdgeCollapsePlan {
    public struct Step {
        public var spring: Spring
        public var delay: Double
        /// The duration the eye reads as "done" (the spring's nominal duration).
        public var nominal: Double
    }
    public var steps: [EdgeCollapseChannelGroup: Step]

    public func step(for group: EdgeCollapseChannelGroup) -> Step {
        steps[group] ?? Step(spring: Spring(duration: 0.2, bounce: 0), delay: 0, nominal: 0.2)
    }

    public static func plan(for kind: EdgeCollapseTransitionKind, bounce: EdgeCollapseBounce, tempo: EdgeCollapseTempo) -> EdgeCollapsePlan {
        let k = tempo.rawValue
        func s(_ d: Double, _ b: Double, _ delay: Double = 0) -> Step {
            Step(spring: Spring(duration: d * k, bounce: b), delay: delay * k, nominal: d * k)
        }
        let rebound = bounce == .bouncy ? 0.24 : 0.0
        switch kind {
        case .collapse:
            // The panel content goes in the first 100ms; the glass body pulls
            // into the edge with a rebound (it tucks past the edge and pops
            // back out to 6pt); the cover shrinks toward the edge from the
            // first frame on a longer spring so it lands last, and fades once
            // it is small.
            return EdgeCollapsePlan(steps: [
                .panel: s(0.10, 0),
                .dim: s(0.14, 0),
                .body: s(0.46, rebound),
                .capsule: s(0.40, 0.10),
                .hero: s(0.58, 0.12),
                .heroFade: s(0.24, 0, 0.22),
                .capsuleContent: s(0.10, 0),
                .stripContent: s(0.20, 0, 0.30),
            ])
        case .floatOut:
            // The capsule buds out of the strip on the first frame; the cover
            // grows with it on a slightly longer spring; text and buttons
            // resolve from blur once the shape has mostly arrived.
            return EdgeCollapsePlan(steps: [
                .capsule: s(0.40, 0.28),
                .hero: s(0.44, 0.28),
                .heroFade: s(0.12, 0),
                .capsuleContent: s(0.18, 0, 0.12),
                .stripContent: s(0.12, 0),
                .body: s(0.30, 0),
                .panel: s(0.10, 0),
                .dim: s(0.10, 0),
            ])
        case .retract:
            return EdgeCollapsePlan(steps: [
                .capsuleContent: s(0.08, 0),
                .capsule: s(0.32, 0.12),
                .hero: s(0.30, 0),
                .heroFade: s(0.14, 0, 0.10),
                .stripContent: s(0.18, 0, 0.20),
                .body: s(0.30, 0),
                .panel: s(0.10, 0),
                .dim: s(0.10, 0),
            ])
        case .expand:
            // The capsule and the strip grow into the card together; the
            // cover grows into the panel's cover from the first frame; the
            // real panel fades in only once the cover has arrived, so the
            // crossfade is between two identical images at the same rect.
            return EdgeCollapsePlan(steps: [
                .capsuleContent: s(0.08, 0),
                .stripContent: s(0.08, 0),
                .capsule: s(0.42, 0.18),
                .body: s(0.44, 0.14),
                .hero: s(0.42, 0.16),
                .heroFade: s(0.10, 0),
                .panel: s(0.16, 0, 0.30),
                .dim: s(0.20, 0, 0.26),
            ])
        }
    }
}

public enum EdgeCollapseTransitionKind: String, Sendable, CaseIterable {
    case collapse, floatOut, retract, expand
}

/// Pose as a pure function of time. `from`/`velocity` come from wherever the
/// previous motion was at the moment this one started.
public struct EdgeCollapseMotion {
    public let from: [Double]
    public let velocity: [Double]
    public let to: [Double]
    public let plan: EdgeCollapsePlan

    public init(from: [Double], velocity: [Double], to: [Double], plan: EdgeCollapsePlan) {
        self.from = from; self.velocity = velocity; self.to = to; self.plan = plan
    }

    /// A channel already moving when this motion starts ignores its delay,
    /// so an interrupted transition never freezes mid-air.
    private func delay(_ i: Int, _ step: EdgeCollapsePlan.Step) -> Double {
        abs(velocity[i]) > 1e-3 ? 0 : step.delay
    }

    public func sample(at t: Double) -> (value: [Double], velocity: [Double]) {
        var value = from, vel = velocity
        for i in 0..<from.count {
            let step = plan.step(for: EdgeCollapseChannelGroup.map[i])
            let tau = t - delay(i, step)
            let delta = to[i] - from[i]
            if tau <= 0 {
                value[i] = from[i]
                vel[i] = velocity[i]
                continue
            }
            value[i] = from[i] + step.spring.value(target: delta, initialVelocity: velocity[i], time: tau)
            vel[i] = step.spring.velocity(target: delta, initialVelocity: velocity[i], time: tau)
        }
        return (value, vel)
    }

    /// When the eye reads the transition as finished (state settles here).
    public var nominalDuration: Double {
        EdgeCollapseChannelGroup.allCases.map { g in
            let s = plan.step(for: g); return s.delay + s.nominal
        }.max() ?? 0
    }

    /// When every channel is within 0.1 of its target (motion stops here).
    public var settledDuration: Double {
        var longest = 0.0
        for i in 0..<from.count {
            let step = plan.step(for: EdgeCollapseChannelGroup.map[i])
            let delta = to[i] - from[i]
            guard abs(delta) > 1e-6 || abs(velocity[i]) > 1e-6 else { continue }
            let settle = step.spring.settlingDuration(target: delta, initialVelocity: velocity[i], epsilon: 0.1)
            longest = max(longest, delay(i, step) + settle)
        }
        return max(longest, nominalDuration)
    }
}
