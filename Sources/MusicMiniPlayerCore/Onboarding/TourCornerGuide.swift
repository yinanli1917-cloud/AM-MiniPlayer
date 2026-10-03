/**
 * [INPUT]: CoreGraphics; ScreenCorner (SnappablePanel.swift).
 * [OUTPUT]: Exports TourCornerGuide — the pure answers behind the move step's direction cues: which corner to suggest
 *           next, which way the panel travels to get there, which way the FINGERS must move for it (natural scrolling on
 *           or off), and which screen edge is nearest.
 * [POS]: MusicMiniPlayerCore/Onboarding. The trackpad demo in the card and the emphasised snap-target mark on screen
 *        both read these, so they cannot disagree. No AppKit: takes plain values.
 */

import CoreGraphics

public enum TourCornerGuide {
    /// The corner whose landing frame is nearest to `point` (ties: `ScreenCorner.allCases` order).
    public static func nearestCorner(to point: CGPoint, frames: [ScreenCorner: CGRect]) -> ScreenCorner? {
        ScreenCorner.allCases.filter { frames[$0] != nil }.min { distance(point, frames[$0]!) < distance(point, frames[$1]!) }
    }

    /// The suggested corner: the nearest one to where the panel is that it has not visited yet (ties: `allCases` order).
    public static func target(from current: ScreenCorner, visited: Set<ScreenCorner>, frames: [ScreenCorner: CGRect]) -> ScreenCorner? {
        guard let origin = frames[current] else { return nil }
        let center = CGPoint(x: origin.midX, y: origin.midY)
        return ScreenCorner.allCases
            .filter { !visited.contains($0) && $0 != current && frames[$0] != nil }
            .min { distance(center, frames[$0]!) < distance(center, frames[$1]!) }
    }

    /// Unit vector from `from` to `to` in screen space (y up); nil when they coincide.
    public static func heading(from: CGPoint, to: CGPoint) -> CGVector? {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = (dx * dx + dy * dy).squareRoot()
        return len > 0.5 ? CGVector(dx: dx / len, dy: dy / len) : nil
    }

    /// How the FINGERS move on the trackpad for the panel to travel along `panelHeading` (screen space, y up), as a unit
    /// vector in VIEW space (y down, what the demo draws). The panel adds `scrollingDeltaX` and subtracts `scrollingDeltaY`
    /// (SnappablePanel.handleScrollDrag): with natural scrolling the fingers and the panel move together; with it off the
    /// system reports both deltas negated, so the fingers move the opposite way.
    public static func fingerHeading(panelHeading: CGVector, naturalScrolling: Bool) -> CGVector {
        let sign: CGFloat = naturalScrolling ? 1 : -1
        return CGVector(dx: panelHeading.dx * sign, dy: -panelHeading.dy * sign)
    }

    /// The panel is nearer the right edge of the visible frame than the left.
    public static func nearestEdgeIsRight(panelMidX: CGFloat, visibleMidX: CGFloat) -> Bool { panelMidX > visibleMidX }

    /// The fingers move rightward for the panel to travel `panelRightward`.
    public static func fingerRightward(panelRightward: Bool, naturalScrolling: Bool) -> Bool {
        naturalScrolling ? panelRightward : !panelRightward
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(p.x - r.midX, p.y - r.midY)
    }
}
