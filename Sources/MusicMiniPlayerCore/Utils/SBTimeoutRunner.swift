/**
 * [INPUT]: Foundation only
 * [OUTPUT]: `SBTimeoutRunner.run(timeout:_:)` — execute a blocking block with
 *           a hard deadline, returning nil on timeout.
 * [POS]: Utils/ — shared guard for ScriptingBridge calls that may hang on
 *        radio URL tracks (currentTrack metadata IPC can block indefinitely).
 *
 * Why this exists:
 * -----------------
 * Music.app's ScriptingBridge reads (currentTrack, persistentID, duration)
 * can block 2–5 s or effectively forever when the currently playing item is
 * a radio URL track mid-buffering. The enclosing serial queue
 * (scriptingBridgeQueue / artworkQueue) then serializes every subsequent
 * poll, artwork fetch, and backfill behind that one stuck call.
 *
 * SBTimeoutRunner bounds the wait:
 *   - Dispatch `block` onto a private serial queue for the selected lane.
 *   - Wait on a semaphore with `timeout`.
 *   - On timeout, return nil. The underlying call keeps running on its own
 *     thread and will eventually finish (or be killed by Music.app); it just
 *     no longer blocks the caller. The serial queue avoids concurrent Apple
 *     Event calls against the same ScriptingBridge proxy.
 *
 * Lanes are intentionally explicit: different SBApplication proxies can use
 * different lanes, so a slow playlist/artwork metadata read does not starve the
 * lightweight playback-position lane that keeps lyrics aligned.
 */

import Foundation

public enum SBTimeoutRunner {
    private final class TimeoutState<T>: @unchecked Sendable {
        let lock = NSLock()
        var result: T?
        var signaled = false
        var canceled = false
    }

    private static let defaultLane = "shared"
    private static let queuesLock = NSLock()
    private static var workerQueues: [String: DispatchQueue] = [
        defaultLane: DispatchQueue(label: "com.nanoPod.sbTimeout.worker.shared", qos: .utility)
    ]

    /// Dedicated SERIAL worker queue for bounded SB calls.
    ///
    /// ⚠️ Must be SERIAL, not concurrent:
    /// ScriptingBridge's AppleEvent dispatch (AECreateAppleEvent /
    /// AEProcessMessage / AESendMessage) is NOT thread-safe when multiple
    /// threads call into the same SBApplication instance. Concurrent calls
    /// corrupt internal AE state and crash with EXC_BAD_ACCESS /
    /// "possible pointer authentication failure" — confirmed in two
    /// production crash logs on 2026-04-23 (both faulting on this queue).
    ///
    /// The timeout semantic still protects callers: `run()` returns `nil`
    /// after its deadline even if the block is still executing. The block
    /// keeps running on this lane and completes later, but NEW callers
    /// submitted to the same lane during that hang get queued — they do NOT
    /// race into concurrent AE dispatch.
    ///
    /// Trade-off: when one block is hung, subsequent calls wait behind it on
    /// that lane. Independent SBApplication proxies should use distinct lanes
    /// so heavyweight metadata work cannot starve lightweight position polling.
    private static func workerQueue(for lane: String) -> DispatchQueue {
        let normalizedLane = lane.isEmpty ? defaultLane : lane
        queuesLock.lock()
        defer { queuesLock.unlock() }
        if let queue = workerQueues[normalizedLane] {
            return queue
        }
        let sanitized = normalizedLane
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "." || character == "-" || character == "_"
                    ? character
                    : "-"
            }
        let queue = DispatchQueue(
            label: "com.nanoPod.sbTimeout.worker.\(String(sanitized))",
            qos: .utility
        )
        workerQueues[normalizedLane] = queue
        return queue
    }

    /// Execute `block` with a wall-clock deadline. Returns the block's value
    /// on success, or nil on timeout.
    ///
    /// 🔑 Drop-on-timeout: when the caller times out, the queued block is
    /// flagged canceled. Once the workerQueue eventually picks the block up,
    /// it skips the SB call entirely and signals immediately. This is what
    /// keeps the serial workerQueue from spending many seconds draining
    /// stale work after a single Music.app IPC hang resolves — without it,
    /// every queued poll/artwork fetch behind the hang would still execute
    /// its now-pointless AE round-trip, blocking real-time UI updates.
    ///
    /// Note: the FIRST hung block (the one currently mid-AE) cannot be
    /// canceled — Apple Events have no abort. It keeps running until
    /// Music.app responds. But every subsequent queued block exits cleanly.
    public static func run<T>(
        timeout: TimeInterval,
        lane: String = "shared",
        _ block: @escaping () -> T?
    ) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let state = TimeoutState<T>()
        let workerQueue = workerQueue(for: lane)

        workerQueue.async {
            // Skip the SB call entirely if the caller already gave up.
            state.lock.lock()
            let skip = state.canceled
            state.lock.unlock()
            if skip { return }

            let value = block()
            state.lock.lock()
            if !state.signaled {
                state.result = value
                state.signaled = true
                sem.signal()
            }
            state.lock.unlock()
        }

        let waitResult = sem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            state.lock.lock()
            // `signaled` flips true here so a late worker can't write `result`.
            // `canceled` flips true so blocks still queued behind us skip outright.
            let late = state.signaled
            state.signaled = true
            state.canceled = true
            let result = state.result
            state.lock.unlock()
            return late ? result : nil
        }
        state.lock.lock()
        let result = state.result
        state.lock.unlock()
        return result
    }
}
