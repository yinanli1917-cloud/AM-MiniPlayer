import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Pure-helper table for HoverCapsuleStyle.resolve — the hover highlight
// fill behind hoverable buttons (HoverableButtons.swift). `.off` arm must
// render exactly as before (opacity 0, no animation). `.capsule` arm fades
// in/out over MicroInteractionFeel.Tokens.hoverCapsuleDuration, and snaps
// (nil animation) under Reduce Motion.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class HoverCapsuleFeelTests: XCTestCase {

    func test_offArm_alwaysZeroOpacity_regardlessOfHoverOrReduceMotion() {
        let hoveringNoReduce = HoverCapsuleStyle.resolve(arm: .off, isHovering: true, reduceMotion: false)
        XCTAssertEqual(hoveringNoReduce.opacity, 0)

        let hoveringReduce = HoverCapsuleStyle.resolve(arm: .off, isHovering: true, reduceMotion: true)
        XCTAssertEqual(hoveringReduce.opacity, 0)

        let notHovering = HoverCapsuleStyle.resolve(arm: .off, isHovering: false, reduceMotion: false)
        XCTAssertEqual(notHovering.opacity, 0)
    }

    func test_capsuleArm_hoverOpacityMatchesToken() {
        let hovering = HoverCapsuleStyle.resolve(arm: .capsule, isHovering: true, reduceMotion: false)
        XCTAssertEqual(hovering.opacity, MicroInteractionFeel.Tokens.hoverCapsuleOpacity, accuracy: 0.0001)
    }

    func test_capsuleArm_notHovering_isZeroOpacity() {
        let notHovering = HoverCapsuleStyle.resolve(arm: .capsule, isHovering: false, reduceMotion: false)
        XCTAssertEqual(notHovering.opacity, 0)
    }

    func test_reduceMotion_snapsWithNilAnimation() {
        let result = HoverCapsuleStyle.resolve(arm: .capsule, isHovering: true, reduceMotion: true)
        XCTAssertNil(result.animation)
    }

    func test_nonReduceMotion_capsuleArm_hasNonNilAnimation() {
        let result = HoverCapsuleStyle.resolve(arm: .capsule, isHovering: true, reduceMotion: false)
        XCTAssertNotNil(result.animation)
    }

    func test_tokenPin_durationAndOpacity() {
        // Pin the numeric tokens this helper reads from MicroInteractionFeel —
        // do not restate raw numbers at call sites.
        XCTAssertEqual(MicroInteractionFeel.Tokens.hoverCapsuleDuration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(MicroInteractionFeel.Tokens.hoverCapsuleOpacity, 0.12, accuracy: 0.0001)
    }
}
