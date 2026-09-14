/**
 * [INPUT]: EdgeMorphClockScheduler, EdgeMorphClockPlan, MicroInteractionFeel.Tokens
 * [OUTPUT]: Quantification-table tests for the C1 three-clock scheduler
 * [POS]: research/c1-edge-morph-design-2026-09-12.md §8/§9 commit 3 — mirrors
 *        NativeLyricsFeelParityTests' quantified-table style: given t0, assert
 *        absolute timestamps against token values.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class EdgeMorphClockSchedulerTests: XCTestCase {

    private let t0: CFTimeInterval = 100.0

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Normal plan: absolute timestamps equal t0 + tokens
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_plan_normal_preSeedStartsAtT0() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertEqual(plan.preSeedStart, t0)
    }

    func test_plan_normal_contentStartsAtContentLagMin() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertEqual(plan.contentStart, t0 + MicroInteractionFeel.Tokens.edgeMorphContentLagMin, accuracy: 1e-9)
    }

    func test_plan_normal_materialStartsAtContentLagMin() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertEqual(plan.materialStart, t0 + MicroInteractionFeel.Tokens.edgeMorphContentLagMin, accuracy: 1e-9)
    }

    func test_plan_normal_contentDurationMatchesToken() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertEqual(plan.contentDuration, MicroInteractionFeel.Tokens.edgeMorphContentDuration, accuracy: 1e-9)
    }

    func test_plan_normal_materialDurationMatchesSettleToken() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertEqual(plan.materialDuration, MicroInteractionFeel.Tokens.edgeMorphMaterialSettle, accuracy: 1e-9)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Reduce Motion plan: all starts collapse to t0, 0.15 both
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_plan_reduceMotion_allStartsEqualT0() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: true)
        XCTAssertEqual(plan.preSeedStart, t0)
        XCTAssertEqual(plan.contentStart, t0)
        XCTAssertEqual(plan.materialStart, t0)
    }

    func test_plan_reduceMotion_durationsAre015() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: true)
        XCTAssertEqual(plan.contentDuration, 0.15, accuracy: 1e-9)
        XCTAssertEqual(plan.materialDuration, 0.15, accuracy: 1e-9)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Ordering invariants
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_ordering_preSeedNeverStartsAfterContentOrMaterial() {
        for reduceMotion in [false, true] {
            let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: reduceMotion)
            XCTAssertLessThanOrEqual(plan.preSeedStart, plan.contentStart)
            XCTAssertLessThanOrEqual(plan.preSeedStart, plan.materialStart)
        }
    }

    func test_ordering_materialEndIsAtOrAfterContentEnd() {
        for reduceMotion in [false, true] {
            let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: reduceMotion)
            let contentEnd = plan.contentStart + plan.contentDuration
            let materialEnd = plan.materialStart + plan.materialDuration
            XCTAssertGreaterThanOrEqual(materialEnd, contentEnd)
        }
    }

    func test_ordering_contentDurationWithinGeometryClassRange() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertGreaterThanOrEqual(plan.contentDuration, 0.125)
        XCTAssertLessThanOrEqual(plan.contentDuration, 0.15)
    }

    func test_ordering_materialDurationWithinSettleRange() {
        let plan = EdgeMorphClockScheduler.plan(t0: t0, reduceMotion: false)
        XCTAssertGreaterThanOrEqual(plan.materialDuration, 0.27)
        XCTAssertLessThanOrEqual(plan.materialDuration, 0.35)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Token pins
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_tokens_pinnedValues() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.edgeMorphPreSeedLead, 0.02, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.edgeMorphContentLagMin, 0.02, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.edgeMorphContentLagMax, 0.08, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.edgeMorphMaterialSettle, 0.31, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.edgeMorphContentDuration, 0.14, accuracy: 1e-9)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - animations(reduceMotion:) branch selection
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_animations_reduceMotion_bothLinear015() {
        let anims = EdgeMorphClockScheduler.animations(reduceMotion: true)
        XCTAssertEqual(anims.content, .linear(duration: 0.15))
        XCTAssertEqual(anims.material, .linear(duration: 0.15))
    }

    func test_animations_normal_useSmoothWithTokenDurations() {
        let anims = EdgeMorphClockScheduler.animations(reduceMotion: false)
        XCTAssertEqual(anims.content, .smooth(duration: MicroInteractionFeel.Tokens.edgeMorphContentDuration))
        XCTAssertEqual(anims.material, .smooth(duration: MicroInteractionFeel.Tokens.edgeMorphMaterialSettle))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Generation-counter cancel logic
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_shouldApply_sameGeneration_true() {
        XCTAssertTrue(EdgeMorphClockScheduler.shouldApply(generation: 1, current: 1))
    }

    func test_shouldApply_staleGeneration_false() {
        XCTAssertFalse(EdgeMorphClockScheduler.shouldApply(generation: 1, current: 2))
        XCTAssertFalse(EdgeMorphClockScheduler.shouldApply(generation: 0, current: 5))
    }

    func test_shouldApply_futureGenerationNeverObserved_stillFalseWhenMismatched() {
        // A scheduled step should never see a "future" generation relative to
        // its own capture, but the comparison is symmetric equality — any
        // mismatch is treated as stale, not just "behind".
        XCTAssertFalse(EdgeMorphClockScheduler.shouldApply(generation: 3, current: 2))
    }
}
