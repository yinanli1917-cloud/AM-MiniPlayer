/**
 * [INPUT]: MusicMiniPlayerCore MusicController.shouldRereadPlaybackModes / mergedPlaybackModes
 * [OUTPUT]: Unit tests for shuffle/repeat re-read scheduling and merge policy
 * [POS]: Test module. Pins the 2026-09-12 real-machine finding: toggling shuffle/repeat
 *        in Music.app fires com.apple.Music.playerInfo, but the userInfo never carries
 *        Shuffle/Repeat keys — only a dedicated ScriptingBridge re-read notices the
 *        change, so notification-triggered scheduling must coalesce (not spam SB) and
 *        the merge must only report a change when values actually differ.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PlaybackModeFreshnessTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - shouldRereadPlaybackModes
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_firstNotification_withNoPriorReread_schedules() {
        XCTAssertTrue(MusicController.shouldRereadPlaybackModes(
            notificationName: "com.apple.Music.playerInfo",
            lastRereadAt: nil,
            now: Date(),
            minInterval: 0.3
        ))
    }

    func test_secondNotification_withinMinInterval_coalesces() {
        let base = Date()
        XCTAssertFalse(MusicController.shouldRereadPlaybackModes(
            notificationName: "com.apple.Music.playerInfo",
            lastRereadAt: base,
            now: base.addingTimeInterval(0.1),
            minInterval: 0.3
        ))
    }

    func test_notification_afterMinIntervalElapsed_schedulesAgain() {
        let base = Date()
        XCTAssertTrue(MusicController.shouldRereadPlaybackModes(
            notificationName: "com.apple.Music.playerInfo",
            lastRereadAt: base,
            now: base.addingTimeInterval(0.35),
            minInterval: 0.3
        ))
    }

    func test_notification_justOverMinInterval_schedules() {
        let base = Date()
        XCTAssertTrue(MusicController.shouldRereadPlaybackModes(
            notificationName: "com.apple.Music.playerInfo",
            lastRereadAt: base,
            now: base.addingTimeInterval(0.301),
            minInterval: 0.3
        ))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - shouldApplyPlaybackModesRead (optimistic-update window)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_readWithinOptimisticWindow_isSkipped() {
        let tap = Date()
        XCTAssertFalse(MusicController.shouldApplyPlaybackModesRead(
            lastUserActionTime: tap,
            now: tap.addingTimeInterval(0.5),
            lockDuration: 1.5
        ))
    }

    func test_readAfterOptimisticWindow_isApplied() {
        let tap = Date()
        XCTAssertTrue(MusicController.shouldApplyPlaybackModesRead(
            lastUserActionTime: tap,
            now: tap.addingTimeInterval(1.6),
            lockDuration: 1.5
        ))
    }

    func test_readWithNoRecentUserAction_isApplied() {
        XCTAssertTrue(MusicController.shouldApplyPlaybackModesRead(
            lastUserActionTime: .distantPast,
            now: Date(),
            lockDuration: 1.5
        ))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - mergedPlaybackModes
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_merge_identicalValues_reportsUnchanged() {
        let result = MusicController.mergedPlaybackModes(
            current: (shuffle: true, repeat: 1),
            read: (shuffle: true, repeat: 1)
        )
        XCTAssertFalse(result.changed)
    }

    func test_merge_shuffleDiffers_reportsChangedWithReadValue() {
        let result = MusicController.mergedPlaybackModes(
            current: (shuffle: false, repeat: 0),
            read: (shuffle: true, repeat: 0)
        )
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.value.shuffle)
        XCTAssertEqual(result.value.repeat, 0)
    }

    func test_merge_repeatDiffers_reportsChangedWithReadValue() {
        let result = MusicController.mergedPlaybackModes(
            current: (shuffle: false, repeat: 0),
            read: (shuffle: false, repeat: 2)
        )
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.value.repeat, 2)
    }

    func test_merge_bothDiffer_reportsChanged() {
        let result = MusicController.mergedPlaybackModes(
            current: (shuffle: false, repeat: 0),
            read: (shuffle: true, repeat: 1)
        )
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.value.shuffle)
        XCTAssertEqual(result.value.repeat, 1)
    }
}
