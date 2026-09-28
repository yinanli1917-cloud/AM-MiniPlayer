import XCTest
@testable import MusicMiniPlayerCore

/// Reduce Motion resolution table (§8.4) and the raw §8.5 token values —
/// numbers only, no view/window involved.
final class TourMotionPolicyTests: XCTestCase {
    func test_normalMotion_everythingAnimates() {
        let spec = TourMotionPolicy.resolve(reduceMotion: false)
        XCTAssertTrue(spec.cardMovesAlongPath)
        XCTAssertTrue(spec.particlesEnabled)
        XCTAssertTrue(spec.haloPulses)
        XCTAssertTrue(spec.gestureGlyphAnimates)
        XCTAssertTrue(spec.ringPulseOnFinale)
        XCTAssertFalse(spec.ringFillLinear)
        XCTAssertEqual(spec.cardPresentDuration, TourMotionPolicy.Tokens.cardPresentResponse)
    }

    func test_reduceMotion_positionAndScaleFade_particlesOff_hapticsStay() {
        let spec = TourMotionPolicy.resolve(reduceMotion: true)
        XCTAssertFalse(spec.cardMovesAlongPath, "§8.4: 一切位移与缩放 → 淡化")
        XCTAssertFalse(spec.particlesEnabled, "§8.4: 粒子不放")
        XCTAssertTrue(spec.hapticsEnabled, "§8.4: 触觉保留")
        XCTAssertTrue(spec.ringFillLinear, "§8.4: 环填充线性")
        XCTAssertFalse(spec.haloPulses)
        XCTAssertFalse(spec.gestureGlyphAnimates, "§8.4: 手势示意静止在起点态")
        XCTAssertEqual(spec.cardPresentDuration, 0.16)
    }

    func test_tokens_matchProposalSection8Point5() {
        XCTAssertEqual(TourMotionPolicy.Tokens.ringOuterDiameter, 28)
        XCTAssertEqual(TourMotionPolicy.Tokens.ringLineWidth, 5.5)
        XCTAssertEqual(TourMotionPolicy.Tokens.ringFillDuration, 0.60)
        XCTAssertEqual(TourMotionPolicy.Tokens.sparkCount, 16)
        XCTAssertEqual(TourMotionPolicy.Tokens.sparkLifetime, 0.55)
        XCTAssertEqual(TourMotionPolicy.Tokens.confettiCount, 72)
        XCTAssertEqual(TourMotionPolicy.Tokens.confettiLifetime, 1.8)
        XCTAssertEqual(TourMotionPolicy.Tokens.confettiGravity, 360)
        XCTAssertEqual(TourMotionPolicy.Tokens.finaleAutoDismiss, 8.0)
    }
}
