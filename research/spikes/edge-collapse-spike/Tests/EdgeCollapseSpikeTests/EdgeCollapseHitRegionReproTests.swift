import XCTest
@testable import EdgeCollapseSpike

/// Repro (founder recording 2026-09-20 22:41): hover flapped between float-out
/// and retract because the hover region (64pt wide) did not cover the capsule
/// drawn on screen (148pt wide). The region must cover everything drawn.
final class EdgeCollapseHitRegionReproTests: XCTestCase {
    func test_floatingHitRegion_coversCapsuleAndStrip() {
        let pose = EdgeCollapsePoses.pose(for: .floating)
        let region = EdgeCollapseLayout.hitRegion(for: .floating)
        XCTAssertTrue(region.contains(pose.capsule), "capsule \(pose.capsule) outside \(region)")
        XCTAssertTrue(region.contains(pose.body), "strip \(pose.body) outside \(region)")
    }

    func test_tuckedHitRegion_coversStrip_andStaysNarrow() {
        let pose = EdgeCollapsePoses.pose(for: .tucked)
        let region = EdgeCollapseLayout.hitRegion(for: .tucked)
        XCTAssertTrue(region.contains(pose.body))
        XCTAssertLessThanOrEqual(region.width, 20, "tucked must not block clicks on the screen content next to the edge")
    }

    func test_cardHitRegion_isTheCard() {
        XCTAssertEqual(EdgeCollapseLayout.hitRegion(for: .card), EdgeCollapsePoses.cardRect)
    }
}

/// Tucked footprint = the app's own edge-hidden panel (founder 2026-09-22).
final class EdgeCollapseGeometryTests: XCTestCase {
    private let container = CGRect(origin: .zero, size: EdgeCollapseTokens.containerSize)

    func test_tuckedStrip_matchesAppEdgeFootprint() {
        let strip = EdgeCollapsePoses.pose(for: .tucked).body
        XCTAssertEqual(strip.width, 6, "SnappablePanel.edgeHiddenVisibleWidth")
        XCTAssertEqual(strip.height, EdgeCollapseTokens.cardSize.height)
        XCTAssertEqual(strip.maxX, container.maxX, "flush with the screen edge")
    }

    func test_capsuleAndStrip_separateAtRest() {
        let pose = EdgeCollapsePoses.pose(for: .floating)
        let gap = pose.body.minX - pose.capsule.maxX
        XCTAssertGreaterThan(gap, EdgeCollapseTokens.containerSpacing, "gap must exceed container spacing or they blend at rest")
    }

    func test_everyPose_fitsInsideWindow() {
        for layout in [EdgeCollapseLayout.VisualLayout.card, .tucked, .floating] {
            let p = EdgeCollapsePoses.pose(for: layout)
            for r in [p.body, p.capsule, p.hero] {
                XCTAssertTrue(container.insetBy(dx: -0.01, dy: -0.01).contains(r), "\(layout): \(r)")
            }
        }
    }
}
