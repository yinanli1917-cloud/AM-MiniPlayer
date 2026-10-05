/**
 * [INPUT]: CoreGraphics; ScreenCorner and Edge (SnappablePanel.swift, plain values); LiquidEdgeTokens (the tucked sliver's size).
 * [OUTPUT]: Exports TourCornerGuide, TourMoveBeat, TourMoveSuggestion — the pure answers behind the move step's direction
 *           cues: which corner to suggest next (the nearest unvisited one, then the diagonal opposite), which way the
 *           panel travels to get there, where it starts and lands (the ghost's path), which way the FINGERS must move for
 *           it (natural scrolling on or off), and which tuckable screen edge is nearest.
 * [POS]: MusicMiniPlayerCore/Onboarding. The trackpad demo in the card, the on-screen ghost of the panel and the
 *        emphasised snap-target mark all read `TourMoveSuggestion`, so they cannot disagree. No AppKit: takes plain values.
 */

import CoreGraphics

/// The move step's three required moves, in order (2026-10-03: corner -> across the diagonal -> the edge).
public enum TourMoveBeat: Int, CaseIterable, Sendable {
    case corner = 0, diagonal = 1, edge = 2
}

/// One suggested move: where the ghost of the panel starts and lands, which way the panel travels, and what is emphasised.
/// The single source for the card's trackpad demo (`fingerHeading`), the ghost's path (`from` -> `to`) and the emphasised
/// snap-target mark (`targetCorner`): they are derived here, once, and cannot disagree.
public struct TourMoveSuggestion: Equatable, Sendable {
    public var beat: TourMoveBeat
    /// The corner to land in (nil for the edge beat).
    public var targetCorner: ScreenCorner?
    /// The edge to slide into (nil for the corner beats).
    public var edgeIsRight: Bool?
    /// The panel's frame now (screen space, y up).
    public var from: CGRect
    /// Where the panel lands: the corner's landing frame, or the tucked sliver at the edge.
    public var to: CGRect
    /// Unit vector of the PANEL's travel (screen space, y up).
    public var panelHeading: CGVector

    public init(beat: TourMoveBeat, targetCorner: ScreenCorner?, edgeIsRight: Bool?, from: CGRect, to: CGRect, panelHeading: CGVector) {
        self.beat = beat
        self.targetCorner = targetCorner
        self.edgeIsRight = edgeIsRight
        self.from = from
        self.to = to
        self.panelHeading = panelHeading
    }

    /// Same move, same identity: a replay is wanted when this changes.
    public var key: String {
        switch beat {
        case .corner, .diagonal: return "\(beat)-\(targetCorner.map { "\($0)" } ?? "-")"
        case .edge: return "edge-\(edgeIsRight == true ? "right" : "left")"
        }
    }

    /// How the FINGERS move for this move, a unit vector in view space (y down).
    public func fingerHeading(naturalScrolling: Bool) -> CGVector {
        TourCornerGuide.fingerHeading(panelHeading: panelHeading, naturalScrolling: naturalScrolling)
    }

    /// The fingers move rightward (edge beat).
    public func fingerRightward(naturalScrolling: Bool) -> Bool {
        TourCornerGuide.fingerRightward(panelRightward: edgeIsRight == true, naturalScrolling: naturalScrolling)
    }
}

extension ScreenCorner {
    /// The corner across the diagonal.
    public var opposite: ScreenCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
}

public enum TourCornerGuide {
    /// The suggested move for `beat`, or nil when the geometry gives no direction.
    /// - `current`: the corner the panel sits in (nil = between corners: the nearest one stands in).
    /// - `visited`: corners the corner beat should not suggest again (the start corner and any landed in).
    /// - `frames`: the four landing frames; `screenFrame`: the whole screen (the sliver is joined to its bezel).
    /// - `tuckableEdges`: the edges the panel can tuck into right now; the edge beat suggests the nearest of them.
    public static func suggestion(beat: TourMoveBeat, panelFrame: CGRect, current: ScreenCorner?, visited: Set<ScreenCorner>,
                                  frames: [ScreenCorner: CGRect], screenFrame: CGRect, visibleMidX: CGFloat,
                                  tuckableEdges: Set<SnappablePanel.Edge>) -> TourMoveSuggestion? {
        let center = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        switch beat {
        case .corner, .diagonal:
            guard frames.count == ScreenCorner.allCases.count,
                  let from = current ?? nearestCorner(to: center, frames: frames) else { return nil }
            let goal: ScreenCorner? = beat == .corner ? target(from: from, visited: visited, frames: frames) : from.opposite
            guard let goal, let rect = frames[goal],
                  let heading = heading(from: center, to: CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
            return TourMoveSuggestion(beat: beat, targetCorner: goal, edgeIsRight: nil, from: panelFrame, to: rect, panelHeading: heading)
        case .edge:
            guard let right = nearestTuckableEdgeIsRight(panelMidX: center.x, visibleMidX: visibleMidX, tuckableEdges: tuckableEdges) else { return nil }
            let size = LiquidEdgeTokens.sliverSize
            let sliver = CGRect(x: right ? screenFrame.maxX - size.width : screenFrame.minX, y: center.y - size.height / 2,
                                width: size.width, height: size.height)
            return TourMoveSuggestion(beat: .edge, targetCorner: nil, edgeIsRight: right, from: panelFrame, to: sliver,
                                      panelHeading: CGVector(dx: right ? 1 : -1, dy: 0))
        }
    }

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

    /// The nearest edge that CAN tuck (`SnappablePanel.tuckableEdges`: Stage Manager keeps the left one): true = right.
    /// With both allowed it is the nearest; with one, that one; with none, nil.
    public static func nearestTuckableEdgeIsRight(panelMidX: CGFloat, visibleMidX: CGFloat, tuckableEdges: Set<SnappablePanel.Edge>) -> Bool? {
        let left = tuckableEdges.contains(.left), right = tuckableEdges.contains(.right)
        if left && right { return nearestEdgeIsRight(panelMidX: panelMidX, visibleMidX: visibleMidX) }
        if right { return true }
        if left { return false }
        return nil
    }

    /// The fingers move rightward for the panel to travel `panelRightward`.
    public static func fingerRightward(panelRightward: Bool, naturalScrolling: Bool) -> Bool {
        naturalScrolling ? panelRightward : !panelRightward
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(p.x - r.midX, p.y - r.midY)
    }
}
