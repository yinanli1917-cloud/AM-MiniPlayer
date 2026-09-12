import XCTest
@testable import MusicMiniPlayerCore

/// Pins the Shuffle/Repeat rebound-spring arm resolution and the analytic
/// overshoot quantification used to justify swapping the underdamped legacy
/// rebound (ζ=0.55, ~13% overshoot) for the critically-damped one (ζ=1.0, 0%).
final class ShuffleRepeatFeelTests: XCTestCase {

    // MARK: - resolve() table

    func test_resolve_legacy055_notReduceMotion_returnsUnderdampedReboundSpring() {
        let style = ShuffleRepeatStyle.resolve(arm: .legacy055, reduceMotion: false)
        XCTAssertNotNil(style.trigger)
        XCTAssertNotNil(style.rebound)
    }

    func test_resolve_critical_notReduceMotion_returnsCriticallyDampedReboundSpring() {
        let style = ShuffleRepeatStyle.resolve(arm: .critical, reduceMotion: false)
        XCTAssertNotNil(style.trigger)
        XCTAssertNotNil(style.rebound)
    }

    func test_resolve_legacy055_reduceMotion_returnsNilBoth() {
        let style = ShuffleRepeatStyle.resolve(arm: .legacy055, reduceMotion: true)
        XCTAssertNil(style.trigger)
        XCTAssertNil(style.rebound)
    }

    func test_resolve_critical_reduceMotion_returnsNilBoth() {
        let style = ShuffleRepeatStyle.resolve(arm: .critical, reduceMotion: true)
        XCTAssertNil(style.trigger)
        XCTAssertNil(style.rebound)
    }

    // MARK: - overshoot() quantification

    func test_overshoot_legacyDamping055_isApproximatelyThirteenPercent() {
        let value = ShuffleRepeatStyle.overshoot(response: 0.35, dampingFraction: 0.55)
        XCTAssertEqual(value, 0.126, accuracy: 0.01)
    }

    func test_overshoot_criticalDamping100_isZero() {
        let value = ShuffleRepeatStyle.overshoot(
            response: MicroInteractionFeel.Tokens.shuffleReboundResponse,
            dampingFraction: MicroInteractionFeel.Tokens.shuffleReboundDamping
        )
        XCTAssertEqual(value, 0, accuracy: 0.0001)
    }

    func test_overshoot_overdamped_isZero() {
        let value = ShuffleRepeatStyle.overshoot(response: 0.35, dampingFraction: 1.5)
        XCTAssertEqual(value, 0, accuracy: 0.0001)
    }

    func test_overshoot_criticalArmBeatsLegacyArm() {
        let legacy = ShuffleRepeatStyle.overshoot(response: 0.35, dampingFraction: 0.55)
        let critical = ShuffleRepeatStyle.overshoot(
            response: MicroInteractionFeel.Tokens.shuffleReboundResponse,
            dampingFraction: MicroInteractionFeel.Tokens.shuffleReboundDamping
        )
        XCTAssertLessThan(critical, legacy)
    }

    // MARK: - Token pins (do not restate numeric values elsewhere)

    func test_tokens_shuffleReboundResponse_isPinnedToPointThree() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.shuffleReboundResponse, 0.30, accuracy: 0.0001)
    }

    func test_tokens_shuffleReboundDamping_isPinnedToOne() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.shuffleReboundDamping, 1.0, accuracy: 0.0001)
    }
}
