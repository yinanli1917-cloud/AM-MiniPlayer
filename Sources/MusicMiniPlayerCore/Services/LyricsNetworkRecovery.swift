import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Silent offline→online recovery — the NWPathMonitor decision, extracted.
//
// LyricsService parks a fetch that never heard from any server on the
// `.networkUnreachable` terminal (a statement about the NETWORK, not the
// song). NWPathMonitor is a passive observer: only an offline→online
// TRANSITION re-issues the fetch, and only while that terminal is still
// showing. The first callback is the current state, not a transition;
// repeated `.satisfied` reports are no-ops (no oscillation). Offline
// never memos a miss — `LyricsService.shouldRecordTerminalMiss` already
// gates that; these helpers pin the path-latch and retry-keying.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
enum LyricsNetworkRecoveryPolicy {
    /// First callback (`wasSatisfied == nil`) is state, not a transition.
    /// Only `false → true` fires recovery.
    static func shouldFireRecovery(wasSatisfied: Bool?, isSatisfied: Bool) -> Bool {
        isSatisfied && wasSatisfied == false
    }

    /// Re-fetch only while the current track is parked on the offline
    /// terminal. Any other state (lyrics shown, genuine miss, still
    /// searching) needs no recovery. Empty title = no identity to retry.
    static func shouldRetryFetch(displayState: LyricsDisplayState, currentSongTitle: String) -> Bool {
        displayState == .networkUnreachable && !currentSongTitle.isEmpty
    }
}

/// Serial latch of the last observed path. `note` returns whether this
/// report is an offline→online transition. Tests drive this directly;
/// LyricsService holds one instance, mutated only on its monitor queue.
final class LyricsNetworkPathLatch {
    private(set) var lastSatisfied: Bool?

    @discardableResult
    func note(isSatisfied: Bool) -> Bool {
        let was = lastSatisfied
        lastSatisfied = isSatisfied
        return LyricsNetworkRecoveryPolicy.shouldFireRecovery(
            wasSatisfied: was,
            isSatisfied: isSatisfied
        )
    }
}
