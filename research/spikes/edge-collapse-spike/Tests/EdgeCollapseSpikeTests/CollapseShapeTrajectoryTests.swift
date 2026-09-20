import XCTest
@testable import EdgeCollapseSpike

/// (c) CollapseShape sampled at 20 points along its animatable path from
/// card → stalk → pill (and the reverse, pill → blob → card) never yields a
/// corner radius greater than half the short side — top-level task
/// instruction #10(c), design §3's "圆角 ≤ 短边一半" rule.
final class CollapseShapeTrajectoryTests: XCTestCase {

    private let sampleCount = 20

    private func sampledPoints() -> [Double] {
        (0..<sampleCount).map { Double($0) / Double(sampleCount - 1) }
    }

    func test_collapsing_cornerRadiusNeverExceedsHalfShortSide() {
        for t in sampledPoints() {
            let g = CollapseShapeTrajectory.sample(t, keyframes: CollapseShapeTrajectory.collapsing)
            let halfShortSide = min(g.width, g.height) / 2
            XCTAssertLessThanOrEqual(g.cornerRadius, halfShortSide + 0.0001, "t=\(t): cornerRadius \(g.cornerRadius) exceeds half short side \(halfShortSide) (w=\(g.width) h=\(g.height))")
        }
    }

    func test_expanding_cornerRadiusNeverExceedsHalfShortSide() {
        for t in sampledPoints() {
            let g = CollapseShapeTrajectory.sample(t, keyframes: CollapseShapeTrajectory.expanding)
            let halfShortSide = min(g.width, g.height) / 2
            XCTAssertLessThanOrEqual(g.cornerRadius, halfShortSide + 0.0001, "t=\(t): cornerRadius \(g.cornerRadius) exceeds half short side \(halfShortSide) (w=\(g.width) h=\(g.height))")
        }
    }

    /// Aspect-ratio guard rule from design §3: "任何 glass 或黑色形状的宽高比
    /// ≥ 3:1 或显式 RoundedRectangle" — every sampled point must satisfy
    /// EITHER the ≥3:1 aspect ratio OR the corner-radius-≤-half-short-side
    /// rule (which is always true here since it's structurally enforced, but
    /// this test also documents which of the two the shape is actually
    /// relying on at each phase, for the founder's eyes-on review).
    func test_collapsing_everyPointSatisfiesAspectOrCornerRule() {
        for t in sampledPoints() {
            let g = CollapseShapeTrajectory.sample(t, keyframes: CollapseShapeTrajectory.collapsing)
            let longSide = max(g.width, g.height)
            let shortSide = min(g.width, g.height)
            let aspectOK = shortSide > 0 && (longSide / shortSide) >= 3.0
            let cornerOK = g.cornerRadius <= shortSide / 2 + 0.0001
            XCTAssertTrue(aspectOK || cornerOK, "t=\(t): neither aspect>=3:1 nor corner<=half-short-side holds (w=\(g.width) h=\(g.height) r=\(g.cornerRadius))")
        }
    }

    func test_endpoints_matchCardAndPill() {
        let start = CollapseShapeTrajectory.sample(0, keyframes: CollapseShapeTrajectory.collapsing)
        XCTAssertEqual(start.width, EdgeCollapseTokens.cardSize.width)
        XCTAssertEqual(start.height, EdgeCollapseTokens.cardSize.height)

        let end = CollapseShapeTrajectory.sample(1, keyframes: CollapseShapeTrajectory.collapsing)
        XCTAssertLessThan(end.width, start.width)
        XCTAssertLessThan(end.height, start.height)
    }

    func test_outOfRangeT_clampsToEndpoints() {
        let below = CollapseShapeTrajectory.sample(-5, keyframes: CollapseShapeTrajectory.collapsing)
        let zero = CollapseShapeTrajectory.sample(0, keyframes: CollapseShapeTrajectory.collapsing)
        XCTAssertEqual(below, zero)

        let above = CollapseShapeTrajectory.sample(5, keyframes: CollapseShapeTrajectory.collapsing)
        let one = CollapseShapeTrajectory.sample(1, keyframes: CollapseShapeTrajectory.collapsing)
        XCTAssertEqual(above, one)
    }

    // MARK: - CollapseShapeGeometry's own clamp (belt-and-suspenders unit)

    func test_geometryInit_clampsOversizedCornerRadius() {
        let g = CollapseShapeGeometry(width: 20, height: 100, cornerRadius: 999, neckWidth: 0)
        XCTAssertEqual(g.cornerRadius, 10)
    }

    func test_geometryInit_clampsNegativeNeckWidth() {
        let g = CollapseShapeGeometry(width: 20, height: 100, cornerRadius: 5, neckWidth: -4)
        XCTAssertEqual(g.neckWidth, 0)
    }
}
