/**
 * [INPUT]: EdgeCollapseTransitionKind (which of the 4 animated moves is
 *          running), Bool reduceMotion, EdgeCollapseTempo
 * [OUTPUT]: EdgeCollapseClockPlan (pure value: geometry/hero/material/goo
 *           clock start+duration, relative to t0) via
 *           EdgeCollapseClockScheduler.plan(kind:reduceMotion:tempo:)
 * [POS]: Standalone spike for research/edge-collapse-redesign-2026-09-19.md §7.
 *        Mirrors Sources/MusicMiniPlayerCore/UI/EdgeMorphClockScheduler.swift's
 *        shape (pure scheduler, no AppKit/SwiftUI state read) but with a 4th
 *        clock (goo) and one plan per transition kind instead of a single
 *        show/hide boolean. App-portable — no spike-only dependencies.
 * [PROTOCOL]: Update alongside design doc §7's timing table.
 */

import Foundation

/// The four animated moves in design §2: `collapsing` (card→tucked),
/// `floatingOut`/`floatingRetract` (tucked↔floating, asymmetric durations
/// per §7.2), and `expanding` (floating/tucked→card). `tucked` itself and
/// settled `card`/`floating` are NOT transitions — nothing is scheduled for
/// them.
public enum EdgeCollapseTransitionKind: Equatable, Sendable {
    case collapsing
    case floatingOut
    case floatingRetract
    case expanding
}

/// One clock's timing, relative to the transition's t0. `duration == 0`
/// means "instant" (used by the Reduce Motion geometry clock, which snaps
/// the frame rather than animating it).
public struct EdgeCollapseClock: Equatable, Sendable {
    public let start: TimeInterval
    public let duration: TimeInterval

    public init(start: TimeInterval, duration: TimeInterval) {
        self.start = start
        self.duration = duration
    }

    public var settle: TimeInterval { start + duration }
}

/// A transition's full plan. `hero` is `nil` for the two floating moves —
/// design §7.2 only fades the artwork dot in/out, it never runs the
/// matchedGeometryEffect hero flight (that's exclusive to collapsing/
/// expanding, design §7.1/§7.3). `goo` is `nil` for `expanding` — the
/// metaball Canvas is only mounted for the collapsing 200–320ms window and
/// the two floating moves (design §8).
public struct EdgeCollapseClockPlan: Equatable, Sendable {
    public let kind: EdgeCollapseTransitionKind
    public let geometry: EdgeCollapseClock
    public let hero: EdgeCollapseClock?
    public let material: EdgeCollapseClock
    public let goo: EdgeCollapseClock?
    /// Total wall-clock length of the transition, INCLUDING the trailing
    /// (collapsing) or leading (expanding/floatingOut) instantaneous window
    /// frame snap that design §3 keeps outside the four animated clocks
    /// ("Frame changes ONLY at settled boundaries").
    public let totalDuration: TimeInterval

    public init(
        kind: EdgeCollapseTransitionKind,
        geometry: EdgeCollapseClock,
        hero: EdgeCollapseClock?,
        material: EdgeCollapseClock,
        goo: EdgeCollapseClock?,
        totalDuration: TimeInterval
    ) {
        self.kind = kind
        self.geometry = geometry
        self.hero = hero
        self.material = material
        self.goo = goo
        self.totalDuration = totalDuration
    }
}

public enum EdgeCollapseClockScheduler {
    /// Pure function: transition kind + Reduce Motion + tempo → plan.
    /// Reduce Motion (design §8) collapses every transition to the SAME
    /// shape: only the material (opacity) clock is populated: hero and goo
    /// are `nil`, and geometry has `duration == 0` (the frame/shape snaps
    /// instead of animating) — "plan 只含 opacity 通道".
    public static func plan(
        kind: EdgeCollapseTransitionKind,
        reduceMotion: Bool,
        tempo: EdgeCollapseTempo
    ) -> EdgeCollapseClockPlan {
        if reduceMotion {
            let duration = EdgeCollapseTokens.scaled(EdgeCollapseTokens.reduceMotionCrossfadeDuration, tempo: tempo)
            return EdgeCollapseClockPlan(
                kind: kind,
                geometry: EdgeCollapseClock(start: 0, duration: 0),
                hero: nil,
                material: EdgeCollapseClock(start: 0, duration: duration),
                goo: nil,
                totalDuration: duration
            )
        }

        let t = EdgeCollapseTokens.self
        func s(_ d: TimeInterval) -> TimeInterval { t.scaled(d, tempo: tempo) }

        switch kind {
        case .collapsing:
            // Geometry covers the shape choreography (height collapse →
            // width snap → stalk→pill → translate-and-bridge), settling when
            // the goo phase ends at 320ms — the window-frame snap to 8×96
            // (320–460ms) is deliberately outside this clock (see totalDuration).
            let geometryDuration = s(t.collapseGooPhaseEnd)
            let heroStart = s(t.collapseHeroStart)
            let heroDuration = s(t.collapseHeroSettle) - heroStart
            let materialDuration = s(t.collapseBlackOverlayDuration)
            let gooStart = s(t.collapseGooPhaseStart)
            let gooDuration = s(t.collapseGooPhaseEnd) - gooStart
            return EdgeCollapseClockPlan(
                kind: kind,
                geometry: EdgeCollapseClock(start: 0, duration: geometryDuration),
                hero: EdgeCollapseClock(start: heroStart, duration: heroDuration),
                material: EdgeCollapseClock(start: 0, duration: materialDuration),
                goo: EdgeCollapseClock(start: gooStart, duration: gooDuration),
                totalDuration: s(t.collapseTotalDuration)
            )

        case .expanding:
            let geometryDuration = s(t.expandCardSettlePhaseEnd)
            let heroDuration = s(t.expandHeroSettle)
            let materialStart = s(t.expandBlackOverlayStart)
            let materialDuration = geometryDuration - materialStart
            return EdgeCollapseClockPlan(
                kind: kind,
                geometry: EdgeCollapseClock(start: 0, duration: geometryDuration),
                hero: EdgeCollapseClock(start: 0, duration: heroDuration),
                material: EdgeCollapseClock(start: materialStart, duration: materialDuration),
                goo: nil,
                totalDuration: s(t.expandTotalDuration)
            )

        case .floatingOut:
            let geometryDuration = s(t.floatingSettlePhaseEnd)
            let gooDuration = s(t.floatingNeckBreak)
            return EdgeCollapseClockPlan(
                kind: kind,
                geometry: EdgeCollapseClock(start: 0, duration: geometryDuration),
                hero: nil,
                material: EdgeCollapseClock(start: 0, duration: geometryDuration),
                goo: EdgeCollapseClock(start: 0, duration: gooDuration),
                totalDuration: s(t.floatingOutDuration)
            )

        case .floatingRetract:
            let duration = s(t.floatingRetractDuration)
            return EdgeCollapseClockPlan(
                kind: kind,
                geometry: EdgeCollapseClock(start: 0, duration: duration),
                hero: nil,
                material: EdgeCollapseClock(start: 0, duration: duration),
                goo: EdgeCollapseClock(start: 0, duration: duration),
                totalDuration: duration
            )
        }
    }

    /// Generation-counter cancel logic for deferred `asyncAfter` steps —
    /// identical contract to `EdgeMorphClockScheduler.shouldApply`. A caller
    /// captures `generation` when it schedules a step; the step only applies
    /// if no newer transition has started since.
    public static func shouldApply(generation: Int, current: Int) -> Bool {
        generation == current
    }
}
