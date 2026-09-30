import XCTest
@testable import MusicMiniPlayerCore

/// The pure card-placement algorithm (proposal §4.3) on a 1440×900 visible
/// frame, at all four panel corners, for both anchor kinds.
final class TourPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let cardSize = CGSize(width: 236, height: 150)

    private func panel(_ corner: ScreenCorner) -> CGRect {
        let size = CGSize(width: 250, height: 284)
        switch corner {
        case .topRight: return CGRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20, width: size.width, height: size.height)
        case .topLeft: return CGRect(x: 20, y: visible.maxY - size.height - 20, width: size.width, height: size.height)
        case .bottomRight: return CGRect(x: visible.maxX - size.width - 20, y: 20, width: size.width, height: size.height)
        case .bottomLeft: return CGRect(x: 20, y: 20, width: size.width, height: size.height)
        }
    }

    // MARK: - Side selection (toward screen center)

    func test_cardSitsOnPanelsCenterFacingSide_allFourCorners() {
        for corner in [ScreenCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let p = panel(corner)
            let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: p, panelFrame: p, visibleFrame: visible)
            let cardIsLeftOfPanel = placement.origin.x < p.minX
            switch corner {
            case .topRight, .bottomRight:
                XCTAssertTrue(cardIsLeftOfPanel, "\(corner): card must sit left of a right-half panel")
                XCTAssertEqual(placement.beakSide, .right)
            case .topLeft, .bottomLeft:
                XCTAssertFalse(cardIsLeftOfPanel, "\(corner): card must sit right of a left-half panel")
                XCTAssertEqual(placement.beakSide, .left)
            }
        }
    }

    func test_gapIsSixteenPoints_fromPanelEdge() {
        let p = panel(.topRight)
        let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: p, panelFrame: p, visibleFrame: visible)
        XCTAssertEqual(p.minX - (placement.origin.x + cardSize.width), TourPlacement.panelGap, accuracy: 0.01)
    }

    // MARK: - Anchor inside the panel (a control), not the panel edge itself

    func test_controlAnchor_cardVerticallyCentersOnAnchor_whenRoomAllows() {
        let p = panel(.topRight)
        let control = CGRect(x: p.maxX - 40, y: p.midY - 16, width: 32, height: 32)
        let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: control, panelFrame: p, visibleFrame: visible)
        XCTAssertEqual(placement.origin.y + cardSize.height / 2, control.midY, accuracy: 0.5)
    }

    // MARK: - Vertical clamp near screen top/bottom

    func test_yClampsToVisibleFrame_withEdgeInset() {
        let p = CGRect(x: 20, y: visible.maxY - 284 - 4, width: 250, height: 284) // nearly at the very top
        let control = CGRect(x: p.maxX - 40, y: p.maxY - 20, width: 32, height: 32) // anchor near the top edge
        let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: control, panelFrame: p, visibleFrame: visible)
        XCTAssertLessThanOrEqual(placement.origin.y + cardSize.height, visible.maxY - TourPlacement.edgeInset + 0.01)
    }

    func test_beakOffset_neverWithin18ptOfCardCorner() {
        let p = panel(.topRight)
        let control = CGRect(x: p.maxX - 40, y: p.maxY - 20, width: 32, height: 32) // near panel's top edge
        let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: control, panelFrame: p, visibleFrame: visible)
        XCTAssertGreaterThanOrEqual(placement.beakOffset, TourPlacement.beakCornerClamp - 0.01)
        XCTAssertLessThanOrEqual(placement.beakOffset, cardSize.height - TourPlacement.beakCornerClamp + 0.01)
    }

    // MARK: - Neither horizontal side fits → stacks above/below the panel

    func test_neitherSideFits_stacksBelowPanel() {
        let narrow = CGRect(x: 0, y: 0, width: 260, height: 900) // panel (250 wide) leaves no room either side
        let p = CGRect(x: 5, y: narrow.maxY - 284 - 20, width: 250, height: 284)
        let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: p, panelFrame: p, visibleFrame: narrow)
        XCTAssertEqual(placement.beakSide, .top)
        XCTAssertLessThanOrEqual(placement.origin.y + cardSize.height, p.minY + 0.01)
    }

    // MARK: - Tucked sliver anchor (S6)

    func test_sliverAnchor_rightEdge_cardSitsLeftOfHitRegion() {
        let hitRegion = CGRect(x: visible.maxX - 60, y: visible.midY - 40, width: 60, height: 80)
        let placement = TourPlacement.placeNearSliver(
            cardSize: cardSize, sliverEdge: .right, floatingHitRegion: hitRegion, sliverMidY: visible.midY, visibleFrame: visible
        )
        XCTAssertEqual(hitRegion.minX - (placement.origin.x + cardSize.width), TourPlacement.sliverGap, accuracy: 0.01)
        XCTAssertEqual(placement.beakSide, .right)
    }

    func test_sliverAnchor_leftEdge_cardSitsRightOfHitRegion() {
        let hitRegion = CGRect(x: 0, y: visible.midY - 40, width: 60, height: 80)
        let placement = TourPlacement.placeNearSliver(
            cardSize: cardSize, sliverEdge: .left, floatingHitRegion: hitRegion, sliverMidY: visible.midY, visibleFrame: visible
        )
        XCTAssertEqual(placement.origin.x - hitRegion.maxX, TourPlacement.sliverGap, accuracy: 0.01)
        XCTAssertEqual(placement.beakSide, .left)
    }

    // MARK: - Card never overlaps the panel or the floating hit region

    func test_cardNeverIntersectsPanelFrame() {
        for corner in [ScreenCorner.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let p = panel(corner)
            let placement = TourPlacement.placeNearPanel(cardSize: cardSize, anchor: p, panelFrame: p, visibleFrame: visible)
            let cardRect = CGRect(origin: placement.origin, size: cardSize)
            XCTAssertFalse(cardRect.intersects(p), "\(corner): card overlaps the panel")
        }
    }

    func test_cardNeverIntersectsFloatingHitRegion() {
        let hitRegion = CGRect(x: visible.maxX - 60, y: visible.midY - 40, width: 60, height: 80)
        let placement = TourPlacement.placeNearSliver(
            cardSize: cardSize, sliverEdge: .right, floatingHitRegion: hitRegion, sliverMidY: visible.midY, visibleFrame: visible
        )
        let cardRect = CGRect(origin: placement.origin, size: cardSize)
        XCTAssertFalse(cardRect.intersects(hitRegion))
    }
}

/// `aimBeak`: the card stays put, only the beak tip moves, clamped to the straight edge.
final class TourPlacementAimBeakTests: XCTestCase {
    private let base = TourCardPlacement(origin: CGPoint(x: 100, y: 200), beakSide: .right, beakOffset: 120)

    func test_aimsAtTheTarget_cardDoesNotMove() {
        let p = TourPlacement.aimBeak(base, atMidY: 230, cardHeight: 240)
        XCTAssertEqual(p.origin, base.origin)
        XCTAssertEqual(p.beakSide, .right)
        XCTAssertEqual(p.beakOffset, 30, accuracy: 0.001, "tip 30pt above the card's bottom edge")
    }

    func test_clampsAwayFromTheCorners() {
        XCTAssertEqual(TourPlacement.aimBeak(base, atMidY: 10, cardHeight: 240).beakOffset, TourPlacement.beakCornerClamp, accuracy: 0.001)
        XCTAssertEqual(TourPlacement.aimBeak(base, atMidY: 900, cardHeight: 240).beakOffset, 240 - TourPlacement.beakCornerClamp, accuracy: 0.001)
    }

    func test_verticalBeaksAreUntouched() {
        let top = TourCardPlacement(origin: .zero, beakSide: .top, beakOffset: 118)
        XCTAssertEqual(TourPlacement.aimBeak(top, atMidY: 500, cardHeight: 100), top)
    }
}
