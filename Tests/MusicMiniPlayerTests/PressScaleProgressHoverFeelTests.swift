import XCTest
import SwiftUI
@testable import MusicMiniPlayerCore

final class PressScaleProgressHoverFeelTests: XCTestCase {

    // MARK: - PressScaleStyle

    func test_pressScale_unified_pressed_returnsTokenScaleWithAnimation() {
        let resolved = PressScaleStyle.resolve(
            arm: .unified,
            isPressed: true,
            reduceMotion: false,
            legacy: (scale: 0.86, animation: .interpolatingSpring(mass: 0.75, stiffness: 560, damping: 22))
        )
        XCTAssertEqual(resolved.scale, CGFloat(MicroInteractionFeel.Tokens.pressScaleFactor))
        XCTAssertEqual(resolved.scale, 0.92)
        XCTAssertNotNil(resolved.animation)
    }

    func test_pressScale_unified_released_returnsOneWithAnimation() {
        let resolved = PressScaleStyle.resolve(
            arm: .unified,
            isPressed: false,
            reduceMotion: false,
            legacy: (scale: 0.86, animation: .interpolatingSpring(mass: 0.75, stiffness: 560, damping: 22))
        )
        XCTAssertEqual(resolved.scale, 1.0)
        XCTAssertNotNil(resolved.animation)
    }

    func test_pressScale_legacy_pressed_passesThroughGivenValues() {
        let legacyAnimation = Animation.interpolatingSpring(mass: 1.0, stiffness: 400, damping: 28)
        let resolved = PressScaleStyle.resolve(
            arm: .legacy,
            isPressed: true,
            reduceMotion: false,
            legacy: (scale: 0.90, animation: legacyAnimation)
        )
        XCTAssertEqual(resolved.scale, 0.90)
        XCTAssertNotNil(resolved.animation)
    }

    func test_pressScale_legacy_released_returnsOneWithLegacyAnimation() {
        let legacyAnimation = Animation.spring(response: 0.1, dampingFraction: 0.7)
        let resolved = PressScaleStyle.resolve(
            arm: .legacy,
            isPressed: false,
            reduceMotion: false,
            legacy: (scale: 0.93, animation: legacyAnimation)
        )
        XCTAssertEqual(resolved.scale, 1.0)
        XCTAssertNotNil(resolved.animation)
    }

    func test_pressScale_reduceMotion_alwaysReturnsOneAndNilAnimation_unifiedArm() {
        let resolved = PressScaleStyle.resolve(
            arm: .unified,
            isPressed: true,
            reduceMotion: true,
            legacy: (scale: 0.86, animation: .interpolatingSpring(mass: 0.75, stiffness: 560, damping: 22))
        )
        XCTAssertEqual(resolved.scale, 1.0)
        XCTAssertNil(resolved.animation)
    }

    func test_pressScale_reduceMotion_alwaysReturnsOneAndNilAnimation_legacyArm() {
        let resolved = PressScaleStyle.resolve(
            arm: .legacy,
            isPressed: true,
            reduceMotion: true,
            legacy: (scale: 0.93, animation: .spring(response: 0.1, dampingFraction: 0.7))
        )
        XCTAssertEqual(resolved.scale, 1.0)
        XCTAssertNil(resolved.animation)
    }

    // MARK: - ProgressHoverStyle

    func test_progressHover_legacy_pinnedTo025EaseInEaseOut() {
        let resolved = ProgressHoverStyle.resolve(arm: .legacy)
        XCTAssertEqual(resolved.duration, 0.25, accuracy: 0.0001)
        XCTAssertEqual(resolved.timing, .easeInEaseOut)
    }

    func test_progressHover_tuned_pinnedToTokenDurationEaseOut() {
        let resolved = ProgressHoverStyle.resolve(arm: .tuned)
        XCTAssertEqual(resolved.duration, MicroInteractionFeel.Tokens.progressHoverDuration, accuracy: 0.0001)
        XCTAssertEqual(resolved.duration, 0.16, accuracy: 0.0001)
        XCTAssertEqual(resolved.timing, .easeOut)
    }

    // MARK: - Token pins (guard against silent renumbering)

    func test_tokenPins() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.pressScaleFactor, 0.92, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pressSpringResponse, 0.18, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pressSpringDamping, 1.0, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.progressHoverDuration, 0.16, accuracy: 0.0001)
    }
}
