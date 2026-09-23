/**
 * [INPUT]: two-finger scroll deltas with timestamps; presentation + settings.
 * [OUTPUT]: EdgeCollapseSwipe — a two-finger swipe triggers at once:
 *           right on the panel collapses, left on the capsule or sliver
 *           expands. EdgeCollapseAutoPeek — whether a track change shows the
 *           capsule briefly.
 * [POS]: Pure logic, app-portable; no views, no clocks of its own.
 * [PROTOCOL]: v12 (2026-09-22). v11 fired a canned collapse once the swipe
 *             passed 40pt: nothing moved while the fingers moved.
 */

import Foundation

public struct EdgeCollapseSwipe {
    /// Two-finger horizontal travel (pt) that triggers at once (founder
    /// 2026-09-22: a swipe must just DO it; following the fingers showed the
    /// half-squashed panel and gave the illusion away).
    public static let triggerDistance: Double = 10

    public enum Action: Equatable { case collapse, expand }

    public private(set) var distance: Double = 0
    private var decided = false
    public private(set) var isHorizontal = true
    public private(set) var fired = false

    public init() {}

    /// Feed one scroll delta (positive dx = toward the right screen edge).
    /// Returns the action to run, once per gesture: rightward on the panel
    /// collapses; leftward on the capsule or the edge sliver expands.
    public mutating func add(dx: Double, dy: Double, presentation: EdgePresentation) -> Action? {
        if !decided, abs(dx) + abs(dy) > 2 {
            decided = true
            isHorizontal = abs(dx) >= abs(dy)
        }
        guard isHorizontal, !fired else { return nil }
        distance += dx
        if distance > Self.triggerDistance, presentation == .card { fired = true; return .collapse }
        if distance < -Self.triggerDistance, presentation == .tucked || presentation == .floating { fired = true; return .expand }
        return nil
    }
}

public enum EdgeCollapseAutoPeek {
    /// Seconds the capsule stays out after a track change.
    public static let holdSeconds: Double = 2.5

    /// Show the capsule on a track change only when tucked, enabled, the
    /// user is not already hovering, and the player does not already post
    /// its own song-change notification (no double announcement).
    public static func shouldPeek(presentation: EdgePresentation, enabled: Bool,
                                  playerAlreadyNotifies: Bool, hovering: Bool) -> Bool {
        presentation == .tucked && enabled && !playerAlreadyNotifies && !hovering
    }
}
