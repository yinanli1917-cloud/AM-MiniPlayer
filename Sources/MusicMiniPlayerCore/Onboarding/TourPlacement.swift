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
    /// Distance from the card's BOTTOM edge (screen space, y up) to the
    /// beak's tip along a left/right beak edge (from the LEFT edge for a
    /// top/bottom beak) — always clamped away from the corners (§4.3:
    /// `clamp(…, 18, h−18)`). SwiftUI's TourBubbleShape measures from the
    /// TOP, so the view layer flips it (`TourCardPlacement.beakOffsetFromTop`).
    public let beakOffset: CGFloat

    public init(origin: CGPoint, beakSide: TourCardSide, beakOffset: CGFloat) {
        self.origin = origin
        self.beakSide = beakSide
        self.beakOffset = beakOffset
    }

    /// The offset in the top-left, y-down convention the bubble shape uses.
    public func beakOffsetFromTop(cardHeight: CGFloat) -> CGFloat {
        switch beakSide {
        case .left, .right: return cardHeight - beakOffset
        case .top, .bottom: return beakOffset
        }
    }
}

public enum TourPlacement {
    /// §4.3: card sits 16pt outside a panel-anchored control or the panel edge.
    public static let panelGap: CGFloat = 16
    /// §4.3: card sits 20pt outside the tucked sliver's floating hit region.
    public static let sliverGap: CGFloat = 20
    /// §4.3: vertical clamp margin off the visible frame's top/bottom.
    /// Also the panel's own 16pt corner margin: a tall card (the move step's) must not
    /// touch the menu bar (8pt did — founder 2026-09-29).
    public static let edgeInset: CGFloat = 16
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
    /// `preferring`: a side the caller wants first (the output menu sits at the panel's right, so its card
    /// stands on the left); it still falls back to the other side, then above/below, when it does not fit.
    public static func placeNearPanel(cardSize: CGSize, anchor: CGRect, panelFrame: CGRect, visibleFrame: CGRect,
                                      preferring side: TourCardSide? = nil) -> TourCardPlacement {
        let preferred = (side == .left || side == .right) ? side! : sideFacingCenter(panelFrame: panelFrame, visibleFrame: visibleFrame)
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

    /// Places a card by ANOTHER app's window (the player app the Music beat opened): outside the window's
    /// edge that faces the panel, else outside the far edge, else inside the window's top-left region.
    /// Always on `visibleFrame`, never over `panelFrame`; the beak points at the window (outside cards: at
    /// its edge, centred on the window; the inside card: out through the window's left edge, near the top).
    /// nil = nowhere fits, the caller keeps the card beside the panel.
    public static func placeNearWindow(cardSize: CGSize, window: CGRect, panelFrame: CGRect, visibleFrame: CGRect) -> TourCardPlacement? {
        let clearOfPanel = panelFrame.insetBy(dx: -8, dy: -8)
        func fits(_ p: TourCardPlacement) -> Bool {
            let rect = CGRect(origin: p.origin, size: cardSize)
            return visibleFrame.contains(rect) && !rect.intersects(clearOfPanel)
        }
        let y = clampedY(midY: window.midY, cardHeight: cardSize.height, visibleFrame: visibleFrame)
        let beakOffset = clampedBeakOffset(midY: window.midY, y: y, cardHeight: cardSize.height)
        let panelIsLeft = panelFrame.midX < window.midX
        // (A card on the window's LEFT edge points its beak right, at the window.)
        func outside(onLeft: Bool) -> TourCardPlacement {
            onLeft
                ? TourCardPlacement(origin: CGPoint(x: window.minX - panelGap - cardSize.width, y: y), beakSide: .right, beakOffset: beakOffset)
                : TourCardPlacement(origin: CGPoint(x: window.maxX + panelGap, y: y), beakSide: .left, beakOffset: beakOffset)
        }
        for onLeft in [panelIsLeft, !panelIsLeft] {
            let p = outside(onLeft: onLeft)
            if fits(p) { return p }
        }
        // Inside, top-left: below the title bar, a little in from the edge; the beak leans out through the left edge.
        let insideTop = min(window.maxY - windowTopInset, visibleFrame.maxY - edgeInset)
        let insideY = max(insideTop - cardSize.height, visibleFrame.minY + edgeInset)
        let inside = TourCardPlacement(origin: CGPoint(x: window.minX + windowInsideInset, y: insideY), beakSide: .left,
                                       beakOffset: clampedBeakOffset(midY: insideY + cardSize.height - beakCornerClamp * 1.5, y: insideY, cardHeight: cardSize.height))
        return fits(inside) ? inside : nil
    }

    /// Inside a window: how far down from its top edge (clear of the title bar) and in from its left edge.
    public static let windowTopInset: CGFloat = 56
    public static let windowInsideInset: CGFloat = 20

    /// Re-aims a left/right beak at `midY` (a control the card is not centred on, e.g. the ring's
    /// target while the card stands beside the whole panel), clamped to the card's straight edge.
    /// The card itself does not move. Top/bottom beaks keep their offset.
    public static func aimBeak(_ placement: TourCardPlacement, atMidY midY: CGFloat, cardHeight: CGFloat) -> TourCardPlacement {
        switch placement.beakSide {
        case .left, .right:
            return TourCardPlacement(origin: placement.origin, beakSide: placement.beakSide,
                                     beakOffset: clampedBeakOffset(midY: midY, y: placement.origin.y, cardHeight: cardHeight))
        case .top, .bottom:
            return placement
        }
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
