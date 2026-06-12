/**
 * [INPUT]: Foundation only (Date, NSLock) — no other module dependencies
 * [OUTPUT]: LyricsMissMemo<Payload> — session-scoped TTL memo of confirmed no-lyrics verdicts
 * [POS]: Pure-logic sub-module of Services — LyricsService calls it at three
 *        integration points: record on a confirmed terminal miss, short-circuit
 *        on fetch start, clear on user-initiated forceRefresh retry
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - Lyrics Miss Memo (session-scoped, in-memory only)
// ============================================================

/// Remembers, for the lifetime of this process, which songs reached a
/// CONFIRMED no-lyrics terminal — so replaying one answers instantly instead
/// of re-running the full multi-source sweep (~14s) the session already
/// completed minutes earlier.
///
/// Scope rules (latency-regression item E):
/// - In-memory ONLY: never persisted, so a relaunch always searches again.
///   The 24h disk verdicts have a much higher evidence bar (album-matched
///   availability markers + transport quorum + unclipped sweep); this memo
///   deliberately sits below it as a pure session-UX layer.
/// - Short TTL (default 20 min): providers add catalogs all the time — a
///   session is not allowed to conclude "no lyrics" forever.
/// - The CALLER gates what counts as confirmed (completed search, not
///   cancelled, not offline — see LyricsService.shouldRecordTerminalMiss);
///   the memo itself only handles keyed TTL storage.
/// - Generic payload: the service stores its TerminalMissVerdict so an
///   instrumental terminal replays as "Instrumental track", not generic.
final class LyricsMissMemo<Payload> {

    /// Seconds a confirmed miss stays answerable. Fixed at init.
    let ttl: TimeInterval

    // NSLock for safety across actor boundaries; all current callers sit on
    // the main actor, so contention is effectively zero.
    private let lock = NSLock()
    private var entries: [String: (payload: Payload, recordedAt: Date)] = [:]

    init(ttl: TimeInterval = 1200) {
        self.ttl = ttl
    }

    /// Record a confirmed miss. `now` is injectable for tests only.
    /// Re-recording restarts the TTL window. Expired entries are pruned
    /// here so a long session cannot accumulate stale keys.
    func record(_ payload: Payload, forKey key: String, at now: Date = Date()) {
        lock.withLock {
            entries = entries.filter { now.timeIntervalSince($0.value.recordedAt) < ttl }
            entries[key] = (payload, now)
        }
    }

    /// The confirmed verdict for this song, or nil when none was recorded
    /// or the TTL elapsed (expired entries are pruned on sight — TTL expiry
    /// means the next fetch really searches).
    func confirmedMiss(forKey key: String, at now: Date = Date()) -> Payload? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            guard now.timeIntervalSince(entry.recordedAt) < ttl else {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry.payload
        }
    }

    /// Drop one song's verdict — the forceRefresh retry path calls this so
    /// a user-initiated retry always really searches.
    func clear(forKey key: String) {
        lock.withLock { _ = entries.removeValue(forKey: key) }
    }
}
