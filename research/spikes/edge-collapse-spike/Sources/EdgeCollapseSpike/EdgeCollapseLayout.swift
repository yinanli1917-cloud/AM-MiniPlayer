/**
 * [INPUT]: EdgePresentation + tuck style.
 * [OUTPUT]: visualLayout(for:) and hitRegion(for:style:) — the hover / click
 *           region, derived from the SAME poses the view draws.
 * [POS]: Pure geometry, app-portable.
 * [PROTOCOL]: Tucked region = the edge shape plus a few points, nothing
 *             more (founder 2026-09-22: v8's 16×316 region fired while the
 *             cursor merely passed by the edge). Hover also needs a dwell
 *             (EdgeCollapseTokens.hoverDwell) before the capsule comes out.
 */

import CoreGraphics

public enum EdgeCollapseLayout {

    public enum VisualLayout: Equatable, Sendable {
        case card, tucked, floating
    }

    public static func visualLayout(for state: EdgePresentation) -> VisualLayout {
        switch state {
        case .card, .expanding: return .card
        case .tucked, .collapsing: return .tucked
        case .floating: return .floating
        }
    }

    /// Seconds the cursor must rest on the tucked shape before it opens.
    public static let hoverDwell: Double = 0.12
    static let tuckedPadInward: CGFloat = 4
    static let tuckedPadVertical: CGFloat = 6

    public static func tuckedRegion(style: EdgeCollapseTuckStyle) -> CGRect {
        // The edge light: the last few points of the screen, over its length.
        let edge = EdgeCollapseTokens.containerSize.width
        let len = EdgeCollapseTokens.glowLength
        let r = CGRect(x: edge - EdgeCollapseTokens.handleSize.width, y: EdgeCollapseTokens.containerSize.height / 2 - len / 2,
                       width: EdgeCollapseTokens.handleSize.width, height: len)
        return CGRect(x: r.minX - tuckedPadInward, y: r.minY - tuckedPadVertical,
                      width: r.width + tuckedPadInward, height: r.height + tuckedPadVertical * 2)
    }

    public static func hitRegion(for state: EdgePresentation, style: EdgeCollapseTuckStyle) -> CGRect {
        let container = CGRect(origin: .zero, size: EdgeCollapseTokens.containerSize)
        switch visualLayout(for: state) {
        case .card:
            return EdgeCollapsePoses.cardRect
        case .tucked:
            return tuckedRegion(style: style)
        case .floating:
            let u = tuckedRegion(style: style).union(EdgeCollapsePoses.capsuleRect)
            let pad = EdgeCollapseTokens.floatingHoverExitExpand
            return u.insetBy(dx: -pad, dy: -pad).intersection(container)
        }
    }
}
