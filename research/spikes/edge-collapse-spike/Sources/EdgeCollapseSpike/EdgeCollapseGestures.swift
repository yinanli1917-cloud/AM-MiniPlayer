/**
 * [INPUT]: two-finger scroll deltas with timestamps; presentation + settings.
 * [OUTPUT]: EdgeCollapseSwipe — the collapse follows the fingers 1:1 and the
 *           release decides by projected momentum (Apple, Designing Fluid
 *           Interfaces: track continuously, hand off velocity, project where
 *           the gesture is going). EdgeCollapseAutoPeek — whether a track
 *           change shows the capsule briefly.
 * [POS]: Pure logic, app-portable; no views, no clocks of its own.
 * [PROTOCOL]: v12 (2026-09-22). v11 fired a canned collapse once the swipe
 *             passed 40pt: nothing moved while the fingers moved.
 */

import Foundation

public struct EdgeCollapseSwipe {
    /// Finger travel (pt, toward the edge) that drives the tracked range.
    public static let fullDistance: Double = 160
    /// How far into the collapse motion the fingers drive (seconds of the
    /// motion's own timeline): the squash and the start of the stalk. The
    /// landing stage starts at 0.09s, so a release rebuilds it freely.
    public static let trackedTime: Double = 0.08
    /// Commit when the projected travel passes this share of fullDistance.
    public static let commitShare: Double = 0.4
    /// Apple's projection, snappy variant: d = 0.99.
    public static let decelerationRate: Double = 0.99

    public private(set) var distance: Double = 0
    private var samples: [(t: Double, d: Double)] = []
    private var decided = false
    public private(set) var isHorizontal = true

    public init() {}

    /// Returns false once the gesture turned out to be a vertical scroll.
    @discardableResult
    public mutating func add(dx: Double, dy: Double, at t: Double) -> Bool {
        if !decided, abs(dx) + abs(dy) > 2 {
            decided = true
            isHorizontal = abs(dx) >= abs(dy)
        }
        guard isHorizontal else { return false }
        distance += dx
        samples.append((t, distance))
        samples.removeAll { t - $0.t > 0.08 }
        return true
    }

    /// 0...1, with a soft resistance past the end (rubber band).
    public var progress: Double {
        let raw = max(distance, 0) / Self.fullDistance
        guard raw > 1 else { return raw }
        let over = raw - 1
        return 1 + over * 0.15 / (0.15 + over)
    }

    /// Finger speed toward the edge, pt/s, over the last ~80ms.
    public var velocity: Double {
        guard let a = samples.first, let b = samples.last, b.t - a.t > 0.004 else { return 0 }
        return (b.d - a.d) / (b.t - a.t)
    }

    public var projectedDistance: Double {
        let d = Self.decelerationRate
        return distance + (velocity / 1000) * d / (1 - d)
    }

    public var commits: Bool { isHorizontal && projectedDistance >= Self.commitShare * Self.fullDistance }

    /// Motion time the fingers are at.
    public var trackedMotionTime: Double { min(progress, 1.02) * Self.trackedTime }

    /// A flick carries momentum, so the landing may bounce; a slow drag lands still.
    public var landingIsBouncy: Bool { velocity > 600 }
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
