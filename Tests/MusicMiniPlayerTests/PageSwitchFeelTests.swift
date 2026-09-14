/**
 * [INPUT]: PageSwitchClockScheduler, PageSwitchClockPlan, MicroInteractionFeel.PageSwitchMode,
 *          MicroInteractionFeel.Tokens.page*
 * [OUTPUT]: Quantification-table tests for the C2 page-switch three-clock scheduler
 * [POS]: Mirrors EdgeMorphClockSchedulerTests' style — plan table, animations table
 *        for both arms and Reduce Motion, ordering invariants, token pins.
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerCore

final class PageSwitchFeelTests: XCTestCase {

    override func tearDown() {
        MicroInteractionFeel.resetTestingOverrides()
        MicroInteractionFeel.apply(channel: "reset", value: "")
        super.tearDown()
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Arm resolution / unknown values fall back to defaults
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_pageSwitchMode_unknownValuesFallBackToSplit() {
        XCTAssertEqual(MicroInteractionFeel.PageSwitchMode.resolve(from: nil), .split)
        XCTAssertEqual(MicroInteractionFeel.PageSwitchMode.resolve(from: "nope"), .split)
        XCTAssertEqual(MicroInteractionFeel.PageSwitchMode.resolve(from: "single"), .single)
        XCTAssertEqual(MicroInteractionFeel.PageSwitchMode.resolve(from: "SPLIT"), .split)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Plan table (non-reduced motion): durations equal tokens
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_plan_normal_geometryDurationMatchesToken() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertEqual(plan.geometryDuration, MicroInteractionFeel.Tokens.pageGeometryDuration, accuracy: 1e-9)
    }

    func test_plan_normal_contentLagMatchesToken() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertEqual(plan.contentLag, MicroInteractionFeel.Tokens.pageContentLag, accuracy: 1e-9)
    }

    func test_plan_normal_contentDurationMatchesToken() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertEqual(plan.contentDuration, MicroInteractionFeel.Tokens.pageContentDuration, accuracy: 1e-9)
    }

    func test_plan_normal_materialDurationMatchesToken() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertEqual(plan.materialDuration, MicroInteractionFeel.Tokens.pageMaterialDuration, accuracy: 1e-9)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Reduce Motion plan collapses to the existing 0.1 fallback
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_plan_reduceMotion_allDurations01_noLag() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: true)
        XCTAssertEqual(plan.geometryDuration, 0.1, accuracy: 1e-9)
        XCTAssertEqual(plan.contentDuration, 0.1, accuracy: 1e-9)
        XCTAssertEqual(plan.materialDuration, 0.1, accuracy: 1e-9)
        XCTAssertEqual(plan.contentLag, 0, accuracy: 1e-9)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Ordering invariants
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_ordering_contentLagIsPositiveAndLessThanGeometryDuration() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertGreaterThan(plan.contentLag, 0)
        XCTAssertLessThan(plan.contentLag, plan.geometryDuration)
    }

    func test_ordering_materialDurationWithin270to350ms() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertGreaterThanOrEqual(plan.materialDuration, 0.270)
        XCTAssertLessThanOrEqual(plan.materialDuration, 0.350)
    }

    func test_ordering_geometryDurationWithin125to150ms() {
        let plan = PageSwitchClockScheduler.plan(reduceMotion: false)
        XCTAssertGreaterThanOrEqual(plan.geometryDuration, 0.125)
        XCTAssertLessThanOrEqual(plan.geometryDuration, 0.150)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Token pins
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_tokens_pinnedValues() {
        XCTAssertEqual(MicroInteractionFeel.Tokens.pageGeometryDuration, 0.14, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pageContentLag, 0.04, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pageContentDuration, 0.16, accuracy: 1e-9)
        XCTAssertEqual(MicroInteractionFeel.Tokens.pageMaterialDuration, 0.31, accuracy: 1e-9)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - animations(arm:reduceMotion:) — both arms + Reduce Motion
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_animations_singleArm_allThreeAreTodaysSpring() {
        let anims = PageSwitchClockScheduler.animations(arm: .single, reduceMotion: false)
        let today = Animation.spring(response: 0.25, dampingFraction: 0.9)
        XCTAssertEqual(anims.geometry, today)
        XCTAssertEqual(anims.content, today)
        XCTAssertEqual(anims.material, today)
    }

    func test_animations_splitArm_useSmoothWithTokenDurations() {
        let anims = PageSwitchClockScheduler.animations(arm: .split, reduceMotion: false)
        XCTAssertEqual(anims.geometry, .smooth(duration: MicroInteractionFeel.Tokens.pageGeometryDuration))
        XCTAssertEqual(
            anims.content,
            .smooth(duration: MicroInteractionFeel.Tokens.pageContentDuration).delay(MicroInteractionFeel.Tokens.pageContentLag)
        )
        XCTAssertEqual(anims.material, .smooth(duration: MicroInteractionFeel.Tokens.pageMaterialDuration))
    }

    func test_animations_reduceMotion_winsForBothArms() {
        let fallback = Animation.linear(duration: 0.1)
        for arm in MicroInteractionFeel.PageSwitchMode.allCases {
            let anims = PageSwitchClockScheduler.animations(arm: arm, reduceMotion: true)
            XCTAssertEqual(anims.geometry, fallback, "arm=\(arm)")
            XCTAssertEqual(anims.content, fallback, "arm=\(arm)")
            XCTAssertEqual(anims.material, fallback, "arm=\(arm)")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Registry resolve/apply/reset roundtrip
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_registry_defaultIsSplit() {
        XCTAssertEqual(MicroInteractionFeel.pageSwitch, .split)
    }

    func test_registry_apply_setsSingleArm_thenResetRestoresSplit() {
        XCTAssertTrue(MicroInteractionFeel.apply(channel: "pageSwitch", value: "single"))
        MicroInteractionFeel.testingPageSwitch = nil // force reading the UserDefaults-backed path
        XCTAssertEqual(MicroInteractionFeel.PageSwitchMode.resolve(from: UserDefaults.standard.string(forKey: MicroInteractionFeel.pageSwitchDefaultsKey)), .single)
        MicroInteractionFeel.reset()
        XCTAssertNil(UserDefaults.standard.string(forKey: MicroInteractionFeel.pageSwitchDefaultsKey))
    }

    func test_registry_testingOverride_takesPrecedence() {
        MicroInteractionFeel.testingPageSwitch = .single
        XCTAssertEqual(MicroInteractionFeel.pageSwitch, .single)
        MicroInteractionFeel.testingPageSwitch = .split
        XCTAssertEqual(MicroInteractionFeel.pageSwitch, .split)
    }
}
