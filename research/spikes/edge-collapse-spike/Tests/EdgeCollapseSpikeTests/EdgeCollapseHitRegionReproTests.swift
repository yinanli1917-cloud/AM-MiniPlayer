import XCTest
@testable import EdgeCollapseSpike
import MusicMiniPlayerCore

/// Hover / click regions (founder 2026-09-20: hover flapped; 2026-09-22: the
/// tucked region fired while the cursor only passed near the edge).
final class EdgeCollapseHitRegionReproTests: XCTestCase {
    func test_floatingRegion_coversCapsule() {
        for style in EdgeCollapseTuckStyle.allCases {
            let region = EdgeCollapseLayout.hitRegion(for: .floating, style: style)
            XCTAssertTrue(region.contains(EdgeCollapsePoses.capsuleRect))
            XCTAssertTrue(region.contains(EdgeCollapsePoses.tuckedRect(style)))
        }
    }

    func test_tuckedRegion_isOnlyTheEdgeShapePlusAFewPoints() {
        for style in EdgeCollapseTuckStyle.allCases {
            let shape = EdgeCollapsePoses.tuckedRect(style)
            let region = EdgeCollapseLayout.hitRegion(for: .tucked, style: style)
            XCTAssertTrue(region.contains(shape))
            XCTAssertLessThanOrEqual(region.width - shape.width, 4)
            XCTAssertLessThanOrEqual(region.height - shape.height, 12)
            XCTAssertLessThan(region.height, 100, "\(style): a tall strip of the screen edge must not open the capsule")
        }
        XCTAssertGreaterThanOrEqual(EdgeCollapseLayout.hoverDwell, 0.1, "passing by must not open it")
    }

    func test_cardRegion_isTheCard() {
        XCTAssertEqual(EdgeCollapseLayout.hitRegion(for: .card, style: .handle), EdgeCollapsePoses.cardRect)
    }
}

final class EdgeCollapseGeometryTests: XCTestCase {
    private let container = CGRect(origin: .zero, size: EdgeCollapseTokens.containerSize)

    /// Card = the real app window: 250×316, corner 16, 16pt off the edge.
    func test_card_matchesRealApp() {
        let c = EdgeCollapsePoses.cardRect
        XCTAssertEqual(c.size, CGSize(width: 250, height: 316))
        XCTAssertEqual(container.maxX - c.maxX, 16, "SnappablePanel.cornerMargin — the card is not flush")
        XCTAssertEqual(EdgeCollapseTokens.cardCornerRadius, 16, "MiniPlayerView clip radius")
    }

    func test_tuckedShape_isShortAndFlush() {
        for style in EdgeCollapseTuckStyle.allCases {
            let r = EdgeCollapsePoses.tuckedRect(style)
            XCTAssertEqual(r.maxX, container.maxX)
            XCTAssertLessThanOrEqual(r.height, 56)
            XCTAssertLessThanOrEqual(r.width, 6)
        }
    }

    /// One object: at rest only one glass shape is visible.
    func test_atRest_onlyOneShapeVisible() {
        for style in EdgeCollapseTuckStyle.allCases {
            for page in [PlayerPage.album, .lyrics, .playlist] {
                for key in [EdgeCollapseKeyPose.card, .tucked] {
                    let p = EdgeCollapsePoses.pose(key, page: page, style: style)
                    XCTAssertTrue(p.body.insetBy(dx: -0.01, dy: -0.01).contains(p.capsule), "\(key): capsule outside body")
                }
                let f = EdgeCollapsePoses.pose(.floating, page: page, style: style)
                XCTAssertLessThanOrEqual(f.body.width, 0.01, "floating: the edge shape must be gone")
            }
        }
    }

    func test_everyKeyPose_fitsInsideWindow() {
        for key in EdgeCollapseKeyPose.allCases {
            for page in [PlayerPage.album, .playlist] {
                let p = EdgeCollapsePoses.pose(key, page: page, style: .handle)
                XCTAssertTrue(container.insetBy(dx: -0.01, dy: -0.01).contains(p.capsule), "\(key) capsule \(p.capsule)")
                XCTAssertLessThanOrEqual(p.body.maxX, container.maxX + 0.01)
            }
        }
    }
}
