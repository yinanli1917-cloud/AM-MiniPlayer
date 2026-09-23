/**
 * [INPUT]: transition kind, where it starts (tucked / floating), current page,
 *          tuck style, bounce, tempo.
 * [OUTPUT]: EdgeCollapseChoreography.stages(...) — the key poses a transition
 *           passes through and the springs of each stage.
 * [POS]: App-portable pure data.
 * [PROTOCOL]: Stage timings follow the references (research/references/
 *             edge-collapse): ref1 collapse = height first, then a stalk
 *             narrower than both ends, then absorbed (~200ms of shape);
 *             ref1 expand = a round blob rounder than both ends, then
 *             stretch; ref4 = grow a neck, then pinch off a round drop.
 *             Content without a counterpart leaves first and arrives last.
 */

import Foundation
import MusicMiniPlayerCore

public enum EdgeCollapseChoreography {
    typealias S = EdgeCollapsePlan.Step
    typealias Stage = EdgeCollapseMotion.Stage
    typealias G = EdgeCollapseChannelGroup
    /// Collapse axis rates: the only pair (swept) where height halves first
    /// AND a narrow, still-tall stalk appears on the way to the edge.
    static let collapseHeightDuration = 0.32
    static let collapseWidthDuration = 0.44

    /// v13 (2026-09-22). Every geometry channel moves on ONE spring per
    /// transition, launched at speed (pure exponential ease-out: fastest on
    /// the first frame, never re-accelerates). The shape story comes from
    /// the axes running at different rates, not from chained stages:
    /// - drop out: width fast, height 1.7× slower → it appears as a round
    ///   drop, swells round, then stretches tall into the capsule;
    /// - collapse: height fast, width slow → height goes first, then a
    ///   narrow stalk is absorbed into the edge (ref1);
    /// - expand: width faster than height → rounder than both ends on the
    ///   way (ref1's bulge), then the card.
    /// Only non-geometry channels (edge body bulge, light, corners, opacity)
    /// may take a second stage or a delay. v12's chained geometry stages
    /// kicked the drop a second time (founder: "卡一下顿一下").
    public static func stages(kind: EdgeCollapseTransitionKind, fromTucked: Bool, page: PlayerPage,
                              style: EdgeCollapseTuckStyle, bounce: EdgeCollapseBounce,
                              tempo: EdgeCollapseTempo) -> [EdgeCollapseMotion.Stage] {
        let k = tempo.rawValue
        func s(_ d: Double, _ b: Double = 0, _ delay: Double = 0, impulse: Double? = nil) -> S {
            var step = EdgeCollapsePlan.step(d, b, delay: delay, tempo: tempo)
            step.impulse = impulse
            return step
        }
        func pose(_ p: EdgeCollapseKeyPose) -> EdgeCollapsePose { EdgeCollapsePoses.pose(p, page: page, style: style) }
        func stage(_ at: Double, _ to: EdgeCollapsePose, _ steps: [G: S], impulse: Double) -> Stage {
            Stage(start: at * k, to: to.vector(), plan: EdgeCollapsePlan(steps, fallback: s(0.2)), impulse: impulse)
        }
        let cardEnd = EdgeCollapsePoses.cardFromCapsule(page: page, style: style)

        switch kind {
        case .collapse:
            let tucked = pose(.tucked)
            // Corners round up first (the squash), then settle to the sliver.
            let first = tucked.taking([.bodyCorner], from: pose(.squash))
            var list = [
                stage(0, first, [.bodyV: s(Self.collapseHeightDuration), .bodyH: s(Self.collapseWidthDuration),
                                 .capsuleH: s(0.40), .capsuleV: s(0.22),
                                 .bodyCorner: s(0.12), .panel: s(0.12, 0, 0.05), .material: s(0.16, 0, 0.03),
                                 .dim: s(0.10), .hero: s(0.3), .heroFade: s(0.2),
                                 .glow: s(0.30, 0, 0.34), .stripContent: s(0.16, 0, 0.34)], impulse: 1),
                stage(0.10, tucked, [.bodyCorner: s(0.30)], impulse: 0),
            ]
            if bounce == .bouncy {
                // Landing (founder 2026-09-22), like the Dynamic Island taking
                // something in: as it arrives, the sliver dives into the edge
                // (and gets a little taller), then pops back out and settles.
                var dive = tucked
                let r = tucked.body
                dive.body = CGRect(x: r.maxX - 0.5, y: r.midY - r.height * 0.6, width: 0.5, height: r.height * 1.2)
                list.append(stage(0.24, dive, [.bodyH: s(0.14), .bodyV: s(0.14)], impulse: 0))
                list.append(stage(0.33, tucked, [.bodyH: s(0.38, 0.40), .bodyV: s(0.38, 0.30)], impulse: 0))
            }
            return list
        case .floatOut:
            let floating = pose(.floating)
            // The edge body swells as the drop leaves it, then goes back in;
            // the light gathers where the drop comes out, then goes out.
            let first = floating.taking([.bodyH, .bodyV, .bodyCorner, .glow], from: pose(.drop))
            return [
                stage(0, first, [.capsuleH: s(0.36, 0, 0, impulse: 0.35), .capsuleV: s(0.60, 0, 0, impulse: 0.35), .capsuleCorner: s(0.16),
                                 .hero: s(0.46), .heroFade: s(0.22, 0, 0.06),
                                 .bodyH: s(0.16), .bodyV: s(0.16), .bodyCorner: s(0.16),
                                 .glow: s(0.16), .stripContent: s(0.08),
                                 .capsuleContent: s(0.18, 0, 0.24), .material: s(0.30, 0, 0.12)], impulse: 1),
                // The sliver drains into the drop before the neck breaks
                // (founder: a stub stayed at the edge after it, dimpling the
                // capsule — the "sticky hitch").
                stage(0.04, floating, [.bodyH: s(0.13), .bodyV: s(0.16), .bodyCorner: s(0.13), .glow: s(0.12)], impulse: 0),
            ]
        case .retract:
            let tucked = pose(.tucked)
            // The capsule shrinks as one rounded drop toward the sliver's
            // centre (not out through the screen edge); the sliver swells at
            // once to take it in, they merge, and it settles with a small
            // rebound. v13 let the capsule vanish into the edge and only then
            // popped the edge body out — two events, read as a hitch.
            let first = tucked.taking([.bodyH, .bodyV, .bodyCorner], from: pose(.drop))
            let land = bounce == .bouncy ? 0.30 : 0
            return [
                stage(0, first, [.capsuleH: s(0.34), .capsuleV: s(0.34), .capsuleCorner: s(0.12),
                                 .hero: s(0.30), .heroFade: s(0.14),
                                 .capsuleContent: s(0.08), .material: s(0.12),
                                 .bodyH: s(0.22), .bodyV: s(0.22), .bodyCorner: s(0.22),
                                 .glow: s(0.28, 0, 0.18), .stripContent: s(0.16, 0, 0.18)], impulse: 1),
                stage(0.16, tucked, [.bodyH: s(0.34, land), .bodyV: s(0.34, land * 0.7), .bodyCorner: s(0.30)], impulse: 0),
            ]
        case .expand:
            // Width faster than height: rounder than both ends on the way.
            // Corners swell into a blob first, then settle to the card's.
            // The real panel is revealed in place inside the liquid.
            let blobCorner = cardEnd.taking([.capsuleCorner], from: pose(.expandBlob))
            return [
                stage(0, blobCorner, [.capsuleH: s(0.30), .capsuleV: s(0.52), .capsuleCorner: s(0.12),
                                      .bodyH: s(0.18), .bodyV: s(0.18), .bodyCorner: s(0.18),
                                      .glow: s(0.12), .stripContent: s(0.06),
                                      .capsuleContent: s(0.08), .heroFade: s(0.10), .hero: s(0.3),
                                      .panel: s(0.10, 0, fromTucked ? 0.04 : 0), .material: s(0.14)], impulse: 1),
                stage(0.07, cardEnd, [.capsuleCorner: s(0.32)], impulse: 0),
            ]
        }
    }

    /// Interrupted mid-flight: one direct stage from the current value and
    /// velocity to the new resting pose.
    public static func direct(to: [Double], tempo: EdgeCollapseTempo) -> [EdgeCollapseMotion.Stage] {
        func s(_ d: Double, _ b: Double = 0) -> EdgeCollapsePlan.Step { EdgeCollapsePlan.step(d, b, delay: 0, tempo: tempo) }
        return [Stage(start: 0, to: to, plan: EdgeCollapsePlan(
            [.capsuleContent: s(0.14), .stripContent: s(0.14), .panel: s(0.16)],
            fallback: s(0.32)))]
    }
}
