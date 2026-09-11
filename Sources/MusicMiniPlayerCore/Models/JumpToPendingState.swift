/**
 * [INPUT]: 无外部依赖（Foundation only）
 * [OUTPUT]: JumpToPendingState（点行跳曲后的等待态纯模型）
 * [POS]: Models/ 纯数据 + 纯决策，供 PlaylistView 的行级 pending 指示器使用；
 *        不含 SwiftUI/AppKit，可脱离渲染单测。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Tracks one "jump to this track" tap until it resolves (currentPersistentID
/// catches up), fails (AppleScript/MusicKit completion reports failure), or
/// times out — whichever comes first. No SwiftUI, no Date() calls inside;
/// every decision takes `now`/the outcome as an explicit input so it can be
/// driven by a fake clock in tests.
public struct JumpToPendingState: Equatable {
    public let persistentID: String
    public let startedAt: Date

    /// How long a jump can stay "pending" before the UI gives up waiting and
    /// reverts silently (no error toast — see D1 spec).
    public static let timeout: TimeInterval = 4.0

    public init(persistentID: String, startedAt: Date) {
        self.persistentID = persistentID
        self.startedAt = startedAt
    }

    /// Is this jump still in flight, given the controller's current track and
    /// the current time? False once `currentPersistentID` matches (resolved)
    /// or once `timeout` has elapsed (gave up).
    public func isPending(currentPersistentID: String?, now: Date) -> Bool {
        guard persistentID != currentPersistentID else { return false }
        return now.timeIntervalSince(startedAt) < Self.timeout
    }

    /// Row-level convenience: is `id`'s row showing the pending indicator right now?
    public static func isPending(for id: String, current: JumpToPendingState?, currentPersistentID: String?, now: Date) -> Bool {
        guard let current, current.persistentID == id else { return false }
        return current.isPending(currentPersistentID: currentPersistentID, now: now)
    }

    /// Pure state transition for a failed jump attempt: clears `current` only if
    /// it was still tracking `failedID` (a late failure callback for an already
    /// superseded/resolved jump must not clobber whatever is pending now).
    public static func clearingOnFailure(current: JumpToPendingState?, failedID: String) -> JumpToPendingState? {
        guard let current, current.persistentID == failedID else { return current }
        return nil
    }
}
