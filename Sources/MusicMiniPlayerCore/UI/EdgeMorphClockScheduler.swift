/**
 * [INPUT]: CFTimeInterval t0 (the moment `onGeometryMorphWillStart` fires,
 *          which IS the pre-seed moment on the AppKit side), reduceMotion flag,
 *          MicroInteractionFeel.Tokens.edgeMorph*
 * [OUTPUT]: EdgeMorphClockPlan (pure value) + EdgeMorphClockScheduler.plan/animations
 *           + EdgeMorphClockScheduler.shouldApply (generation-counter cancel logic)
 * [POS]: C1 贴边形变设计 §4/§9 commit 3 — replaces the ad-hoc single withAnimation
 *        in EdgeMorphHost with three independently-clocked steps: pre-seed
 *        (mount at opacity 0), content (identity switch), material (glass
 *        opacity settle).
 * [PROTOCOL]: 变更时更新此头部，然后检查 research/c1-edge-morph-design-2026-09-12.md §4/§9
 */

import SwiftUI
import QuartzCore

/// Pure timing plan for one edge-morph transition, anchored at `t0` — the
/// wall-clock moment the AppKit geometry spring is told to start
/// (`onGeometryMorphWillStart`). All fields are absolute `CFTimeInterval`
/// timestamps/durations, never relative offsets, so callers can schedule
/// directly off `CACurrentMediaTime()` without re-deriving arithmetic.
public struct EdgeMorphClockPlan: Equatable {
    public let preSeedStart: CFTimeInterval
    public let contentStart: CFTimeInterval
    public let contentDuration: TimeInterval
    public let materialStart: CFTimeInterval
    public let materialDuration: TimeInterval

    public init(
        preSeedStart: CFTimeInterval,
        contentStart: CFTimeInterval,
        contentDuration: TimeInterval,
        materialStart: CFTimeInterval,
        materialDuration: TimeInterval
    ) {
        self.preSeedStart = preSeedStart
        self.contentStart = contentStart
        self.contentDuration = contentDuration
        self.materialStart = materialStart
        self.materialDuration = materialDuration
    }
}

/// Pure scheduler: turns `t0` + Reduce Motion into an `EdgeMorphClockPlan`,
/// and turns a plan into the `Animation` values the content/material clocks
/// should run. No AppKit/SwiftUI state is read here — everything is a
/// function of its inputs, mirroring `NativeLyricsFeelParityTests`' quantified
/// table style.
public enum EdgeMorphClockScheduler {
    /// - Note: the AppKit hook (`onGeometryMorphWillStart`) already fires at
    ///   the intent point — i.e. `t0` IS the pre-seed moment, not a future
    ///   one. So `preSeedStart == t0` and geometry itself starts at
    ///   `t0 + edgeMorphPreSeedLead` from the SwiftUI side's point of view
    ///   (the "target pre-seeded ~20ms before geometry" framing in design §4).
    ///   Content and material both start after `edgeMorphContentLagMin`
    ///   because the pill's identity switch and its material fade-in are the
    ///   two things that must wait for geometry to be visibly under way.
    public static func plan(t0: CFTimeInterval, reduceMotion: Bool) -> EdgeMorphClockPlan {
        let tokens = MicroInteractionFeel.Tokens.self
        if reduceMotion {
            return EdgeMorphClockPlan(
                preSeedStart: t0,
                contentStart: t0,
                contentDuration: 0.15,
                materialStart: t0,
                materialDuration: 0.15
            )
        }

        return EdgeMorphClockPlan(
            preSeedStart: t0,
            contentStart: t0 + tokens.edgeMorphContentLagMin,
            contentDuration: tokens.edgeMorphContentDuration,
            materialStart: t0 + tokens.edgeMorphContentLagMin,
            materialDuration: tokens.edgeMorphMaterialSettle
        )
    }

    /// The `Animation` values the content-identity switch and the material
    /// opacity settle should run under, given the current Reduce Motion
    /// setting. Kept separate from `plan(t0:reduceMotion:)` because
    /// `Animation` is not `Equatable` and shouldn't live on the pure plan
    /// value the tests pin.
    public static func animations(reduceMotion: Bool) -> (content: Animation, material: Animation) {
        if reduceMotion {
            return (.linear(duration: 0.15), .linear(duration: 0.15))
        }
        let tokens = MicroInteractionFeel.Tokens.self
        return (
            .smooth(duration: tokens.edgeMorphContentDuration),
            .smooth(duration: tokens.edgeMorphMaterialSettle)
        )
    }

    /// Generation-counter cancel logic for the deferred content/material
    /// steps: a scheduled step captures the generation at schedule time and,
    /// when its `asyncAfter`/`Task.sleep` fires, must only apply if the
    /// generation is still current. A rapid reverse (hide→restore before the
    /// lag elapses) bumps the generation and the stale step becomes a no-op.
    public static func shouldApply(generation: Int, current: Int) -> Bool {
        generation == current
    }
}
