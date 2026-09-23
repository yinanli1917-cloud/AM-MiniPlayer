/**
 * [INPUT]: EdgePresentation.
 * [OUTPUT]: visualLayout(for:) (5 states → 3 resting layouts) and
 *           hitRegion(for:) — the hover/click region, derived from the SAME
 *           poses the view draws.
 * [POS]: Pure geometry, app-portable.
 * [PROTOCOL]: v7 kept a second, stale set of floating rects for hit-testing
 *             (64pt wide vs a 148pt capsule on screen); the cursor on the
 *             capsule's left half counted as "left", so hover flapped
 *             (EdgeCollapseHitRegionReproTests). Never derive hit regions
 *             from anything but EdgeCollapsePoses.
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

    public static func hitRegion(for state: EdgePresentation) -> CGRect {
        let container = CGRect(origin: .zero, size: EdgeCollapseTokens.containerSize)
        switch visualLayout(for: state) {
        case .card:
            return EdgeCollapsePoses.cardRect
        case .tucked:
            let s = EdgeCollapsePoses.stripRect
            let pad = EdgeCollapseTokens.tuckedHoverExpand
            return CGRect(x: s.minX - pad, y: s.minY, width: s.width + pad, height: s.height)
        case .floating:
            let u = EdgeCollapsePoses.stripRect.union(EdgeCollapsePoses.capsuleRect)
            let pad = EdgeCollapseTokens.floatingHoverExitExpand
            return u.insetBy(dx: -pad, dy: -pad).intersection(container)
        }
    }
}
