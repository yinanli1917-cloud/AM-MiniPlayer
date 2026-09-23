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

    public static func stages(kind: EdgeCollapseTransitionKind, fromTucked: Bool, page: PlayerPage,
                              style: EdgeCollapseTuckStyle, bounce: EdgeCollapseBounce,
                              tempo: EdgeCollapseTempo) -> [EdgeCollapseMotion.Stage] {
        let k = tempo.rawValue
        func s(_ d: Double, _ b: Double, _ delay: Double = 0) -> S { EdgeCollapsePlan.step(d, b, delay: delay, tempo: tempo) }
        func pose(_ p: EdgeCollapseKeyPose) -> [Double] { EdgeCollapsePoses.pose(p, page: page, style: style).vector() }
        func stage(_ at: Double, _ to: [Double], _ steps: [EdgeCollapseChannelGroup: S]) -> Stage {
            Stage(start: at * k, to: to, plan: EdgeCollapsePlan(steps, fallback: s(0.2, 0)))
        }
        let landBounce = bounce == .bouncy ? 0.32 : 0.05
        let cardEnd = EdgeCollapsePoses.cardFromCapsule(page: page, style: style).vector()

        // Stages hand over while the previous one is still accelerating, so
        // the whole transition is one push: speed rises once, peaks once and
        // falls (LiquidContinuityTests). v11 handed over after the previous
        // stage had nearly stopped: fast → slow → kicked fast again, the
        // hitch the founder felt as the drop came out and went back.
        // Intermediate stages have no bounce; only the landing may bounce.
        switch kind {
        case .collapse:
            return [
                // Panel content goes first; the card loses height while width stays wide.
                stage(0, pose(.squash), [.panel: s(0.08, 0), .dim: s(0.10, 0), .body: s(0.26, 0),
                                         .capsule: s(0.26, 0), .hero: s(0.28, 0), .heroFade: s(0.2, 0),
                                         .material: s(0.14, 0)]),
                // Width pinches into a stalk narrower than both ends; black by now (ref1).
                stage(0.04, pose(.stalk), [.body: s(0.30, 0), .capsule: s(0.30, 0),
                                           .hero: s(0.30, 0), .heroFade: s(0.18, 0), .material: s(0.16, 0)]),
                // Absorbed into the edge; Bouncy overshoots into the edge and settles.
                stage(0.09, pose(.tucked), [.body: s(0.40, landBounce), .capsule: s(0.36, 0),
                                            .hero: s(0.34, 0), .heroFade: s(0.16, 0),
                                            .stripContent: s(0.16, 0, 0.18)]),
            ]
        case .floatOut:
            return [
                // The handle bulges; a small drop necks out of it (ref4).
                stage(0, pose(.drop), [.body: s(0.28, 0), .capsule: s(0.28, 0), .hero: s(0.28, 0),
                                       .heroFade: s(0.12, 0), .stripContent: s(0.08, 0)]),
                // It pinches off and swells into a round blob; the handle goes back into the edge.
                stage(0.04, pose(.blob), [.capsule: s(0.30, 0), .body: s(0.28, 0), .hero: s(0.30, 0),
                                          .heroFade: s(0.12, 0)]),
                // The blob stretches into the capsule; glass comes in; text resolves from blur last.
                stage(0.12, pose(.floating), [.capsule: s(0.42, 0.20), .hero: s(0.42, 0.18),
                                              .capsuleContent: s(0.18, 0, 0.18), .material: s(0.26, 0, 0.10)]),
            ]
        case .retract:
            return [
                stage(0, pose(.blob), [.capsuleContent: s(0.08, 0), .capsule: s(0.26, 0), .hero: s(0.26, 0),
                                       .material: s(0.12, 0)]),
                // The edge shape comes back out, bulged, and the drop necks onto it.
                stage(0.04, pose(.drop), [.capsule: s(0.28, 0), .body: s(0.28, 0),
                                          .hero: s(0.26, 0), .heroFade: s(0.12, 0)]),
                // The drop is absorbed; the handle settles.
                stage(0.09, pose(.tucked), [.capsule: s(0.32, 0), .body: s(0.34, 0.10), .hero: s(0.28, 0),
                                            .heroFade: s(0.14, 0), .stripContent: s(0.16, 0, 0.12)]),
            ]
        case .expand:
            var list: [Stage] = []
            var t0 = 0.0
            if fromTucked {
                list.append(stage(0, pose(.drop), [.body: s(0.22, 0), .capsule: s(0.22, 0), .hero: s(0.22, 0),
                                                   .heroFade: s(0.1, 0), .stripContent: s(0.06, 0)]))
                t0 = 0.035
            }
            // Bulge round first (ref1), bigger than the capsule, rounder than the card.
            list.append(stage(t0, pose(.expandBlob), [.capsuleContent: s(0.08, 0), .capsule: s(0.30, 0),
                                                      .body: s(0.20, 0), .hero: s(0.30, 0),
                                                      .heroFade: s(0.12, 0), .material: s(0.14, 0)]))
            // Stretch into the card. Only the capsule grows (one outline); the
            // real panel fades in only after the cover has landed.
            list.append(stage(t0 + 0.05, cardEnd, [.capsule: s(0.44, 0.14), .hero: s(0.44, 0.10),
                                                   .panel: s(0.16, 0, 0.32), .heroFade: s(0.12, 0)]))
            return list
        }
    }

    /// Interrupted mid-flight: one direct stage from the current value and
    /// velocity to the new resting pose (no detour through key poses).
    public static func direct(to: [Double], tempo: EdgeCollapseTempo) -> [EdgeCollapseMotion.Stage] {
        func s(_ d: Double, _ b: Double, _ delay: Double = 0) -> EdgeCollapsePlan.Step { EdgeCollapsePlan.step(d, b, delay: delay, tempo: tempo) }
        return [Stage(start: 0, to: to, plan: EdgeCollapsePlan(
            [.capsuleContent: s(0.14, 0), .stripContent: s(0.14, 0), .panel: s(0.16, 0)],
            fallback: s(0.32, 0.15)))]
    }
}
