/**
 * [INPUT]: MusicMiniPlayerCore JumpToPendingState
 * [OUTPUT]: Unit tests for the row-level jump-to-tap feedback state machine
 *           (D1: pending after tap, resolved on confirm, cleared on failure or
 *           4.0s timeout) — fake clock throughout, no sleeps.
 * [POS]: Test module. Pure model only — no SwiftUI, no ScriptingBridge.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class JumpToPendingStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Pending after tap
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_isPending_immediatelyAfterTap_isTrue() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertTrue(state.isPending(currentPersistentID: nil, now: t0))
        XCTAssertTrue(state.isPending(currentPersistentID: "B", now: t0))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Resolved when currentPersistentID matches
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_isPending_currentPersistentIDMatches_isFalse() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertFalse(state.isPending(currentPersistentID: "A", now: t0))
    }

    func test_rowLevelIsPending_matchesOnlyThatRowsID() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertTrue(JumpToPendingState.isPending(for: "A", current: state, currentPersistentID: nil, now: t0))
        XCTAssertFalse(JumpToPendingState.isPending(for: "B", current: state, currentPersistentID: nil, now: t0))
        XCTAssertFalse(JumpToPendingState.isPending(for: "A", current: nil, currentPersistentID: nil, now: t0))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Cleared by failure
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_clearingOnFailure_matchingID_clearsToNil() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertNil(JumpToPendingState.clearingOnFailure(current: state, failedID: "A"))
    }

    func test_clearingOnFailure_nonMatchingID_leavesUnchanged() {
        // A late failure callback for a jump that was already superseded (the
        // user tapped a different row) must not clobber the newer pending state.
        let state = JumpToPendingState(persistentID: "B", startedAt: t0)
        XCTAssertEqual(JumpToPendingState.clearingOnFailure(current: state, failedID: "A"), state)
    }

    func test_clearingOnFailure_alreadyNil_staysNil() {
        XCTAssertNil(JumpToPendingState.clearingOnFailure(current: nil, failedID: "A"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Cleared after 4.0s timeout (fake clock, still pending at 3.9s)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_isPending_at3_9Seconds_stillTrue() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertTrue(state.isPending(currentPersistentID: nil, now: t0.addingTimeInterval(3.9)))
    }

    func test_isPending_at4_0Seconds_isFalse() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertFalse(state.isPending(currentPersistentID: nil, now: t0.addingTimeInterval(4.0)))
    }

    func test_isPending_wellPastTimeout_isFalse() {
        let state = JumpToPendingState(persistentID: "A", startedAt: t0)
        XCTAssertFalse(state.isPending(currentPersistentID: nil, now: t0.addingTimeInterval(30)))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Tapping another row replaces the pending target
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_tappingAnotherRow_replacesPendingTarget() {
        var pending: JumpToPendingState? = JumpToPendingState(persistentID: "A", startedAt: t0)
        pending = JumpToPendingState(persistentID: "B", startedAt: t0.addingTimeInterval(1))

        XCTAssertEqual(pending?.persistentID, "B")
        XCTAssertFalse(JumpToPendingState.isPending(for: "A", current: pending, currentPersistentID: nil, now: t0.addingTimeInterval(1)))
        XCTAssertTrue(JumpToPendingState.isPending(for: "B", current: pending, currentPersistentID: nil, now: t0.addingTimeInterval(1)))
    }
}
