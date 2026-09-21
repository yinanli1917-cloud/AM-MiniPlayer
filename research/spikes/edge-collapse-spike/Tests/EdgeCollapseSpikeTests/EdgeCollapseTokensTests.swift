import XCTest
@testable import EdgeCollapseSpike

/// (b) `EdgeCollapseTokens.scaled` tempo scaling + the animation table's raw
/// duration/bounce constants match top-level task instruction #2 exactly —
/// top-level task instruction #10(b).
final class EdgeCollapseTokensTests: XCTestCase {

    // MARK: - Tempo scales durations, never bounce fractions

    func test_scaled_appliesTempoMultiplier() {
        XCTAssertEqual(EdgeCollapseTokens.scaled(0.32, tempo: .normal), 0.32, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.scaled(0.32, tempo: .slow), 0.48, accuracy: 0.0001)
    }

    func test_scaled_isLinearInTempo_forEveryBaseDuration() {
        let durations: [TimeInterval] = [
            EdgeCollapseTokens.collapseSettleDuration,
            EdgeCollapseTokens.collapseBouncyDuration,
            EdgeCollapseTokens.floatingOutDuration,
            EdgeCollapseTokens.floatingRetractDuration,
            EdgeCollapseTokens.expandDuration,
            EdgeCollapseTokens.reduceMotionCrossfadeDuration,
        ]
        for d in durations {
            let normal = EdgeCollapseTokens.scaled(d, tempo: .normal)
            let slow = EdgeCollapseTokens.scaled(d, tempo: .slow)
            XCTAssertEqual(slow, normal * 1.5, accuracy: 0.0001, "duration \(d) did not scale linearly with tempo")
        }
    }

    // MARK: - Animation table pins the exact numbers from top-level task instruction #2

    func test_collapseSettle_matchesAppleMeasuredEaseOut() {
        XCTAssertEqual(EdgeCollapseTokens.collapseSettleDuration, 0.32, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.collapseSettleBounce, 0.0, accuracy: 0.0001)
    }

    func test_collapseBouncy() {
        XCTAssertEqual(EdgeCollapseTokens.collapseBouncyDuration, 0.36, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.collapseBouncyBounce, 0.28, accuracy: 0.0001)
    }

    func test_floatingOut() {
        XCTAssertEqual(EdgeCollapseTokens.floatingOutDuration, 0.24, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.floatingOutBounce, 0.15, accuracy: 0.0001)
    }

    func test_floatingRetract() {
        XCTAssertEqual(EdgeCollapseTokens.floatingRetractDuration, 0.20, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.floatingRetractBounce, 0.0, accuracy: 0.0001)
    }

    func test_expand() {
        XCTAssertEqual(EdgeCollapseTokens.expandDuration, 0.36, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.expandBounce, 0.12, accuracy: 0.0001)
    }

    func test_reduceMotionCrossfade() {
        XCTAssertEqual(EdgeCollapseTokens.reduceMotionCrossfadeDuration, 0.18, accuracy: 0.0001)
    }

    // MARK: - Container spacing default (top-level task instruction #1)

    func test_containerSpacing_defaultsTo24() {
        XCTAssertEqual(EdgeCollapseTokens.containerSpacing, 24, accuracy: 0.0001)
    }

    // MARK: - Window is fixed (top-level task instruction #3)

    func test_containerSize_is320x360() {
        XCTAssertEqual(EdgeCollapseTokens.containerSize.width, 320, accuracy: 0.0001)
        XCTAssertEqual(EdgeCollapseTokens.containerSize.height, 360, accuracy: 0.0001)
    }
}
