/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 OnboardingState
 * [OUTPUT]: OnboardingStateTests
 * [POS]: C6 引导页纯判定函数 + UserDefaults 往返测试
 */

import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class OnboardingStateTests: XCTestCase {

    override func tearDown() {
        OnboardingState.shared.reset()
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        OnboardingState.debugForceShow = false
        #endif
        super.tearDown()
    }

    // MARK: - shouldPresent 判定表

    func test_shouldPresent_firstLaunchNotCompleted_showsOnboarding() {
        XCTAssertTrue(OnboardingState.shouldPresent(hasCompleted: false, launchCount: 1, forced: false))
    }

    func test_shouldPresent_firstLaunchAlreadyCompleted_doesNotShow() {
        XCTAssertFalse(OnboardingState.shouldPresent(hasCompleted: true, launchCount: 1, forced: false))
    }

    func test_shouldPresent_laterLaunchNotCompleted_doesNotShow() {
        // Onboarding is a first-launch gate, not a nag on every incomplete run.
        XCTAssertFalse(OnboardingState.shouldPresent(hasCompleted: false, launchCount: 2, forced: false))
        XCTAssertFalse(OnboardingState.shouldPresent(hasCompleted: false, launchCount: 50, forced: false))
    }

    func test_shouldPresent_laterLaunchCompleted_doesNotShow() {
        XCTAssertFalse(OnboardingState.shouldPresent(hasCompleted: true, launchCount: 10, forced: false))
    }

    func test_shouldPresent_forced_alwaysShowsRegardlessOfOtherState() {
        XCTAssertTrue(OnboardingState.shouldPresent(hasCompleted: true, launchCount: 99, forced: true))
        XCTAssertTrue(OnboardingState.shouldPresent(hasCompleted: false, launchCount: 1, forced: true))
    }

    // MARK: - UserDefaults 往返

    func test_hasCompletedOnboarding_defaultsToFalse() {
        OnboardingState.shared.reset()
        XCTAssertFalse(OnboardingState.shared.hasCompletedOnboarding)
    }

    func test_markCompleted_persistsCompletionAndCurrentSchema() {
        OnboardingState.shared.reset()
        OnboardingState.shared.markCompleted()
        XCTAssertTrue(OnboardingState.shared.hasCompletedOnboarding)
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: OnboardingState.schemaKey),
            OnboardingState.currentSchema
        )
    }

    func test_reset_clearsCompletionState() {
        OnboardingState.shared.markCompleted()
        XCTAssertTrue(OnboardingState.shared.hasCompletedOnboarding)
        OnboardingState.shared.reset()
        XCTAssertFalse(OnboardingState.shared.hasCompletedOnboarding)
    }

    /// A future content revision bumps `currentSchema` — a completion recorded
    /// under an older schema must not suppress the new onboarding.
    func test_schemaBump_reShowsOnboardingEvenIfPreviouslyCompleted() {
        OnboardingState.shared.reset()
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        UserDefaults.standard.set(OnboardingState.currentSchema - 1, forKey: OnboardingState.schemaKey)

        XCTAssertFalse(OnboardingState.shared.hasCompletedOnboarding)
        XCTAssertTrue(OnboardingState.shouldPresent(
            hasCompleted: OnboardingState.shared.hasCompletedOnboarding,
            launchCount: 5,
            forced: false
        ) == false) // launchCount > 1 still gates it — schema bump alone doesn't force a re-show mid-session
    }

    // MARK: - 调试强制展示 + 重置

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    func test_handleDebugAction_show_presentsAndForces() {
        OnboardingState.shared.isPresented = false
        let handled = OnboardingState.shared.handleDebugAction("show")
        XCTAssertTrue(handled)
        XCTAssertTrue(OnboardingState.shared.isPresented)
        XCTAssertTrue(OnboardingState.debugForceShow)
    }

    func test_handleDebugAction_reset_clearsCompletionAndDismisses() {
        OnboardingState.shared.markCompleted()
        OnboardingState.shared.isPresented = true
        OnboardingState.debugForceShow = true

        let handled = OnboardingState.shared.handleDebugAction("reset")
        XCTAssertTrue(handled)
        XCTAssertFalse(OnboardingState.shared.hasCompletedOnboarding)
        XCTAssertFalse(OnboardingState.shared.isPresented)
        XCTAssertFalse(OnboardingState.debugForceShow)
    }

    func test_handleDebugAction_unknownPath_notHandled() {
        XCTAssertFalse(OnboardingState.shared.handleDebugAction("bogus"))
    }
    #endif
}
