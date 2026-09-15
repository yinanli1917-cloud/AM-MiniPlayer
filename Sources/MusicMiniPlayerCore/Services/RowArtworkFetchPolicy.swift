/**
 * [INPUT]: Foundation only (Date, NSLock) — no other module dependencies
 * [OUTPUT]: RowArtworkVisibilityPolicy (pure), RowArtworkFetchGate (bounded
 *           concurrency semaphore), RowArtworkNegativeCache (session-scoped
 *           exponential-backoff failure memo)
 * [POS]: Pure-logic sub-module of Services — PlaylistItemRowCompact
 *        (UI/PlaylistView.swift) is the sole caller: gates when a row may
 *        fetch its own artwork, bounds how many rows fetch at once, and
 *        remembers terminal failures so a hopeless persistentID isn't
 *        re-scanned on every remount.
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - Row Artwork Visibility Policy (pure)
// ============================================================

/// Whether a playlist row is ALLOWED to start fetching its own artwork right
/// now. Pinned by the 2026-09-15 artwork-storm postmortem: `PlaylistView` is
/// permanently mounted behind the Lyrics/Album pages (banned-patterns.md —
/// destroying the ScrollView on page switch loses scroll position), and its
/// History/Up Next rows are a plain (non-lazy) `VStack` (banned-patterns.md —
/// `Section + LazyVStack` recurses on macOS 26 Liquid Glass). Combined, EVERY
/// row used to fetch the instant it mounted regardless of page — including
/// the moment `playbackHistory` jumps from empty to its full persisted list
/// (up to 50 entries) on the first confirmed track change after launch. This
/// policy is the single choke point: a row may only fetch while the Playlist
/// page is the one on screen.
public enum RowArtworkVisibilityPolicy {
    public static func shouldFetch(currentPage: PlayerPage) -> Bool {
        currentPage == .playlist
    }
}

// ============================================================
// MARK: - Row Artwork Source Gate (pure)
// ============================================================

/// Whether a row's last-resort ScriptingBridge persistentID scan is even
/// worth attempting. Only `.library` qualifies: a radio/stream row has no
/// local identity at all, and an Apple Music CATALOG ("am:"-prefixed) row's
/// id was never in `currentPlaylist` or the local library either — both scan
/// forever and never find anything. `.unknown` is treated the same as
/// non-library: an unconfirmed source is not evidence the scan can succeed.
public enum RowArtworkSourceGate {
    public static func allowsScriptingBridgeLookup(sourceKind: PlaybackHistoryEntry.SourceKind) -> Bool {
        sourceKind == .library
    }
}

// ============================================================
// MARK: - Row Artwork Fetch Gate (bounded concurrency)
// ============================================================

/// Caps how many playlist rows may have an artwork resolution in flight at
/// once. Before this gate, every row eagerly mounted at the same visibility
/// transition serialized on `MusicController.artworkQueue` (ScriptingBridge)
/// or fired independent unbounded network requests (the metadata-keyed
/// RowArtworkStore path) — a 13-row burst measured ~12s of continuous serial
/// ScriptingBridge activity (2026-09-15 repro log). A small NSLock + FIFO
/// waiter queue rather than an actor: `release()` must be callable
/// synchronously from a `defer` (async `defer` bodies can't `await`), and
/// Swift's `defer` still runs on every exit path — including after
/// cooperative cancellation — since none of the awaited calls here throw
/// `CancellationError`.
public final class RowArtworkFetchGate: @unchecked Sendable {
    public static let defaultLimit = 3

    private let limit: Int
    private let lock = NSLock()
    private var current = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int = RowArtworkFetchGate.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Suspends until a slot is free, then holds it. Always pair with
    /// `release()` (typically via `defer`) on every path, including early
    /// returns from cache hits found AFTER acquiring — callers should
    /// acquire only once they know a fetch is actually needed.
    public func acquire() async {
        let acquiredImmediately: Bool = lock.withLock {
            if current < limit {
                current += 1
                return true
            }
            return false
        }
        guard !acquiredImmediately else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if current < limit {
                    current += 1
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    /// Releases a held slot, handing it directly to the oldest waiter if any.
    public func release() {
        lock.withLock {
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.resume()
            } else {
                current = max(0, current - 1)
            }
        }
    }

    /// Test/diagnostic seam: slots currently held.
    public func currentCountForTesting() -> Int {
        lock.withLock { current }
    }
}

// ============================================================
// MARK: - Row Artwork Negative Cache (session-scoped backoff)
// ============================================================

/// Remembers a row artwork key's terminal failures for the lifetime of this
/// process, with exponential backoff — so a track that will never resolve
/// (removed from the library, a catalog-only stream) doesn't get re-scanned
/// on every remount (page revisit, row reorder), but a transient rate-limit
/// or network blip still retries within minutes rather than being wedged
/// blank forever. Replaces the old unconditional "sleep 8s, retry once"
/// baked into the row itself.
public final class RowArtworkNegativeCache: @unchecked Sendable {
    public struct Entry: Equatable {
        var failureCount: Int
        var nextRetryAt: Date
    }

    public static let baseBackoff: TimeInterval = 5
    public static let maxBackoff: TimeInterval = 300

    /// Pure: backoff duration for the Nth consecutive failure (1-indexed).
    /// 1→5s, 2→10s, 3→20s, ... capped at `maxBackoff`.
    public static func backoff(forFailureCount count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        let exponent = Double(count - 1)
        return min(maxBackoff, baseBackoff * pow(2, exponent))
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Whether `key` is still inside its backoff window and should be
    /// skipped without attempting any tier.
    public func shouldSkip(key: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let entry = entries[key] else { return false }
            return now < entry.nextRetryAt
        }
    }

    /// Records a terminal failure (all tiers exhausted) and schedules the
    /// next allowed attempt via exponential backoff.
    public func recordFailure(key: String, now: Date = Date()) {
        lock.withLock {
            let count = (entries[key]?.failureCount ?? 0) + 1
            entries[key] = Entry(failureCount: count, nextRetryAt: now.addingTimeInterval(Self.backoff(forFailureCount: count)))
        }
    }

    /// Clears a key's failure history — call on a successful resolution so a
    /// later transient miss starts backoff fresh instead of compounding.
    public func recordSuccess(key: String) {
        lock.withLock { entries.removeValue(forKey: key) }
    }

    /// Test seam: raw entry for a key.
    public func entryForTesting(key: String) -> Entry? {
        lock.withLock { entries[key] }
    }
}
