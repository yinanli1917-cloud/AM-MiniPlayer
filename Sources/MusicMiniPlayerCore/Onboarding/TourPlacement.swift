/**
 * [INPUT]: CoreGraphics (CGRect/CGPoint/CGSize) only.
 * [OUTPUT]: Exports TourCardSide, TourCardPlacement, TourPlacement — the pure
 *           placement algorithm from proposal §4.3.
 * [POS]: MusicMiniPlayerCore/Onboarding. No AppKit, no window — takes and
 *        returns plain geometry so `TourPlacementTests` can exhaustively
 *        table-test corners/screens/anchors, and so `TourHaloWindow`/
 *        `TourCardWindow` (AppKit) only ever need to read the result.
 */

import CoreGraphics

/// Which edge of the CARD the beak/arrow is drawn on — always the edge
/// facing back at whatever it's anchored to.
public enum TourCardSide: Equatable, Sendable {
    case left, right, top, bottom
}

public struct TourCardPlacement: Equatable, Sendable {
    public let origin: CGPoint
    public let beakSide: TourCardSide
    /// Distance from the card's top edge to the beak's tip, along the beak
    /// edge — always clamped away from the corners (§4.3: `clamp(…, 18, h−18)`).
    public let beakOffset: CGFloat

    public init(origin: CGPoint, beakSide: TourCardSide, beakOffset: CGFloat) {
        self.origin = origin
        self.beakSide = beakSide
        self.beakOffset = beakOffset
    }
}

public enum TourPlacement {
    /// §4.3: card sits 16pt outside a panel-anchored control or the panel edge.
    public static let panelGap: CGFloat = 16
    /// §4.3: card sits 20pt outside the tucked sliver's floating hit region.
    public static let sliverGap: CGFloat = 20
    /// §4.3: vertical clamp margin off the visible frame's top/bottom.
    public static let edgeInset: CGFloat = 8
    /// §4.3: beak never sits within 18pt of the card's own top/bottom corner.
    public static let beakCornerClamp: CGFloat = 18

    /// Which side of `panelFrame` faces the screen's center — the side the
    /// card is placed on by default (§4.3: "side = 面板朝屏幕中心的一侧").
    public static func sideFacingCenter(panelFrame: CGRect, visibleFrame: CGRect) -> TourCardSide {
        panelFrame.midX < visibleFrame.midX ? .right : .left
    }

    /// Places a card next to a control inside the panel, or next to the
    /// panel's own edge (`anchor == panelFrame` for the S0/S5/S7 "面板边"
    /// case). Tries the side facing center first, then the other side, then
    /// stacks above/below the panel if NEITHER horizontal side fits — the
    /// fallback §4.3 only names in passing ("都放不下放面板上下方").
    public static func placeNearPanel(cardSize: CGSize, anchor: CGRect, panelFrame: CGRect, visibleFrame: CGRect) -> TourCardPlacement {
        let preferred = sideFacingCenter(panelFrame: panelFrame, visibleFrame: visibleFrame)
        if let p = horizontal(preferred, cardSize: cardSize, anchor: anchor, panelFrame: panelFrame, visibleFrame: visibleFrame) {
            return p
        }
        let other: TourCardSide = preferred == .right ? .left : .right
        if let p = horizontal(other, cardSize: cardSize, anchor: anchor, panelFrame: panelFrame, visibleFrame: visibleFrame) {
            return p
        }
        return vertical(cardSize: cardSize, anchor: anchor, panelFrame: panelFrame, visibleFrame: visibleFrame)
    }

    /// Places a card next to the tucked sliver (S6's `anchor == .sliver`).
    /// `sliverEdge` is whichever screen edge the sliver is currently on
    /// (`.left`/`.right` — from `LiquidEdgeController`'s `side`).
    public static func placeNearSliver(
        cardSize: CGSize,
        sliverEdge: TourCardSide,
        floatingHitRegion: CGRect,
        sliverMidY: CGFloat,
        visibleFrame: CGRect
    ) -> TourCardPlacement {
        let x: CGFloat
        let beakSide: TourCardSide
        switch sliverEdge {
        case .right:
            x = floatingHitRegion.minX - sliverGap - cardSize.width
            beakSide = .right
        default:
            x = floatingHitRegion.maxX + sliverGap
            beakSide = .left
        }
        let y = clampedY(midY: sliverMidY, cardHeight: cardSize.height, visibleFrame: visibleFrame)
        let beakOffset = clampedBeakOffset(midY: sliverMidY, y: y, cardHeight: cardSize.height)
        return TourCardPlacement(origin: CGPoint(x: x, y: y), beakSide: beakSide, beakOffset: beakOffset)
    }

    // MARK: - Internals

    private static func horizontal(
        _ side: TourCardSide, cardSize: CGSize, anchor: CGRect, panelFrame: CGRect, visibleFrame: CGRect
    ) -> TourCardPlacement? {
        let x: CGFloat
        let beakSide: TourCardSide
        switch side {
        case .right:
            x = panelFrame.maxX + panelGap
            beakSide = .left
        case .left:
            x = panelFrame.minX - panelGap - cardSize.width
            beakSide = .right
        default:
            return nil
        }
        guard x >= visibleFrame.minX, x + cardSize.width <= visibleFrame.maxX else { return nil }
        let y = clampedY(midY: anchor.midY, cardHeight: cardSize.height, visibleFrame: visibleFrame)
        let beakOffset = clampedBeakOffset(midY: anchor.midY, y: y, cardHeight: cardSize.height)
        return TourCardPlacement(origin: CGPoint(x: x, y: y), beakSide: beakSide, beakOffset: beakOffset)
    }

    private static func vertical(cardSize: CGSize, anchor: CGRect, panelFrame: CGRect, visibleFrame: CGRect) -> TourCardPlacement {
        let x = min(max(anchor.midX - cardSize.width / 2, visibleFrame.minX + edgeInset), visibleFrame.maxX - edgeInset - cardSize.width)
        let below = panelFrame.minY - panelGap - cardSize.height
        if below >= visibleFrame.minY {
            return TourCardPlacement(origin: CGPoint(x: x, y: below), beakSide: .top, beakOffset: cardSize.width / 2)
        }
        let above = panelFrame.maxY + panelGap
        return TourCardPlacement(origin: CGPoint(x: x, y: above), beakSide: .bottom, beakOffset: cardSize.width / 2)
    }

    private static func clampedY(midY: CGFloat, cardHeight: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let raw = midY - cardHeight / 2
        let lower = visibleFrame.minY + edgeInset
        let upper = visibleFrame.maxY - edgeInset - cardHeight
        guard upper >= lower else { return lower }
        return min(max(raw, lower), upper)
    }

    private static func clampedBeakOffset(midY: CGFloat, y: CGFloat, cardHeight: CGFloat) -> CGFloat {
        let raw = midY - y
        let lower = beakCornerClamp
        let upper = max(cardHeight - beakCornerClamp, lower)
        return min(max(raw, lower), upper)
    }
}
