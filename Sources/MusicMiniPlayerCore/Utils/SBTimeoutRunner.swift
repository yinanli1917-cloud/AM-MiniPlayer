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
 *   - Dispatch `block` onto a private concurrent queue.
 *   - Wait on a semaphore with `timeout`.
 *   - On timeout, return nil. The underlying call keeps running on its own
 *     thread and will eventually finish (or be killed by Music.app); it just
 *     no longer blocks the caller. The concurrent queue + thread pool bounds
 *     the resource cost.
 *
 * This complements — does not replace — the queue heartbeat recovery in
 * MusicController (recreates the queue after 5 s of silence). Timeout is
 * fine-grained; heartbeat is a backstop.
 */

import Foundation

public enum SBTimeoutRunner {
    /// Dedicated concurrent worker pool for bounded SB calls.
    /// `.utility` QoS: these are user-visible but not interactive; a stuck
    /// worker won't steal cycles from the main thread.
    ///
    /// Concurrent is intentional — tests assume multiple callers run in
    /// parallel without one hung block stalling another. Any SB-level
    /// serialization (to prevent LaunchServices races) must be applied at
    /// the caller site, not here.
    private static let workerQueue = DispatchQueue(
        label: "com.nanoPod.sbTimeout.worker",
        qos: .utility,
        attributes: .concurrent
    )

    /// Execute `block` with a wall-clock deadline. Returns the block's value
    /// on success, or nil on timeout.
    ///
    /// Important: the block keeps running in the background if it exceeds
    /// `timeout`. Any side effects it performs AFTER the timeout are silently
    /// discarded from the caller's perspective, but caller must tolerate
    /// those side effects happening late (e.g., a later log line).
    public static func run<T>(timeout: TimeInterval, _ block: @escaping () -> T?) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        var signaled = false
        let lock = NSLock()

        workerQueue.async {
            let value = block()
            lock.lock()
            if !signaled {
                result = value
                signaled = true
                sem.signal()
            }
            lock.unlock()
        }

        let waitResult = sem.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            lock.lock()
            // Mark signaled so the late worker won't touch `result` (already nil).
            let late = signaled
            signaled = true
            lock.unlock()
            return late ? result : nil
        }
        return result
    }
}
