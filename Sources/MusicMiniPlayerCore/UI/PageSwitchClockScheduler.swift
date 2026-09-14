/**
 * [INPUT]: Reduce Motion flag, MicroInteractionFeel.PageSwitchMode arm,
 *          MicroInteractionFeel.Tokens.page*
 * [OUTPUT]: PageSwitchClockPlan (pure value) + PageSwitchClockScheduler.plan/animations
 * [POS]: C2 三页切换三时钟 — splits the single page-switch
 *        `.spring(response: 0.25, dampingFraction: 0.9)` in MiniPlayerView into
 *        three independently-clocked steps: geometry (matchedGeometryEffect hero
 *        move + page offset), content (incoming page's textual/control opacity,
 *        lagging geometry slightly), material (PanelBackdrop/page-overlay material
 *        crossfade). Mirrors EdgeMorphClockScheduler's pure-scheduler pattern.
 * [PROTOCOL]: 变更时更新此头部
 */

import SwiftUI

/// Pure timing plan for one page switch. Durations only (no absolute
/// timestamps needed here — unlike EdgeMorphClockScheduler, callers apply
/// these directly as `Animation` durations via `withAnimation`/`.animation`,
/// there is no AppKit pre-seed hook to anchor against).
public struct PageSwitchClockPlan: Equatable {
    public let geometryDuration: TimeInterval
    public let contentLag: TimeInterval
    public let contentDuration: TimeInterval
    public let materialDuration: TimeInterval

    public init(
        geometryDuration: TimeInterval,
        contentLag: TimeInterval,
        contentDuration: TimeInterval,
        materialDuration: TimeInterval
    ) {
        self.geometryDuration = geometryDuration
        self.contentLag = contentLag
        self.contentDuration = contentDuration
        self.materialDuration = materialDuration
    }
}

/// Pure scheduler: turns Reduce Motion into a `PageSwitchClockPlan`, and turns
/// the plan + arm into the `Animation` values the geometry/content/material
/// channels should run. No SwiftUI/AppKit state is read here — everything is
/// a function of its inputs.
public enum PageSwitchClockScheduler {
    /// - Note: Reduce Motion always collapses to the existing linear(0.1)
    ///   fallback for every channel, exactly matching today's behaviour at
    ///   every current call site.
    public static func plan(reduceMotion: Bool) -> PageSwitchClockPlan {
        if reduceMotion {
            return PageSwitchClockPlan(
                geometryDuration: 0.1,
                contentLag: 0,
                contentDuration: 0.1,
                materialDuration: 0.1
            )
        }
        let tokens = MicroInteractionFeel.Tokens.self
        return PageSwitchClockPlan(
            geometryDuration: tokens.pageGeometryDuration,
            contentLag: tokens.pageContentLag,
            contentDuration: tokens.pageContentDuration,
            materialDuration: tokens.pageMaterialDuration
        )
    }

    /// The `Animation` values for the geometry/content/material channels.
    /// `.single` arm (and Reduce Motion, regardless of arm) reproduces
    /// today's byte-identical `.spring(response: 0.25, dampingFraction: 0.9)`
    /// (or the existing `.linear(duration: 0.1)` Reduce Motion fallback) on
    /// all three channels — every current call site keeps that exact value.
    public static func animations(
        arm: MicroInteractionFeel.PageSwitchMode,
        reduceMotion: Bool
    ) -> (geometry: Animation, content: Animation, material: Animation) {
        if reduceMotion {
            let fallback = Animation.linear(duration: 0.1)
            return (fallback, fallback, fallback)
        }
        guard arm == .split else {
            let today = Animation.spring(response: 0.25, dampingFraction: 0.9)
            return (today, today, today)
        }
        let plan = plan(reduceMotion: reduceMotion)
        return (
            .smooth(duration: plan.geometryDuration),
            .smooth(duration: plan.contentDuration).delay(plan.contentLag),
            .smooth(duration: plan.materialDuration)
        )
    }
}
