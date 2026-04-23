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
    /// keeps running on this queue and completes later (or gets killed by
    /// the 5s heartbeat-recovery in MusicController), but NEW callers
    /// submitted during that hang get queued — they do NOT race into
    /// concurrent AE dispatch.
    ///
    /// Trade-off: when one block is hung, subsequent calls wait behind it
    /// on this queue. Each caller's own timeout limits its wait. The
    /// queue-heartbeat backstop in MusicController recreates the queue
    /// (and the shared SBApplication) after 5 s of silence.
    private static let workerQueue = DispatchQueue(
        label: "com.nanoPod.sbTimeout.worker",
        qos: .utility
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
