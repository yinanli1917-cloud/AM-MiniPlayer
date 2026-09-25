/**
 * [INPUT]: PlaybackHistoryStore/PlaybackHistoryEntry (Services), DebugLogger (Utils)
 * [OUTPUT]: Exports PendingPlaybackAccumulator (stateful, main-thread-only) +
 *           its pure decision functions (PendingPlay, totalListenedSeconds,
 *           qualifiesForHistory, isSameSong) — all directly unit-testable
 *           with fake clocks, no MusicController/ScriptingBridge needed.
 * [POS]: Services — MusicController owns exactly one instance. Both
 *        confirmed-track-change call sites (handleTrackChange's notification
 *        path, applySnapshot's snapshot path) call `beginPendingPlay` instead
 *        of recording directly; `updatePersistentID` is called wherever a
 *        persistentID resolves later (SB completion, PID-refill poll);
 *        `tick` rides MusicController's EXISTING snapshot-poll cadence (no
 *        new timer) to accumulate listened time and commit the instant the
 *        threshold is crossed, not just on the next track change.
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - PendingPlay (pure value type)
// ============================================================

/// One track's provisional listen, tracked from the moment a track change is
/// confirmed until it either qualifies for History (commits) or is
/// superseded by a genuinely different next play (discarded, never committed).
///
/// 2026-09-25 diagnosis fix — this type exists to solve three findings from
/// research/diagnosis-2026-09-25-history.md at once:
/// - H1 (display hid every past play of the current song, not just the
///   current row): once a play only enters History at qualification time,
///   "the row for THIS play" is structurally `entries.first` — no PID-wide
///   filter needed (see PlaybackHistoryDisplayPolicy).
/// - H3 (a rapid double-skip could drop the first track's History row
///   entirely, because the SB persistentID read for it lost a race and the
///   notification path bailed before ever recording): `beginPendingPlay` is
///   called BEFORE the SB read starts, so the play is already being tracked
///   (and, if it's a `minimumListenSeconds == 0` config, may already be
///   committed) by the time any SB mismatch could cause a bail.
/// - H4 (an SB persistentID timeout misclassified a library track as
///   radio/stream, then a later successful read recorded it a second time):
///   the persistentID is patched onto the SAME pending/committed play by
///   `updatePersistentID`, never inserted as a new row.
public struct PendingPlay: Equatable {
    public let title: String
    public let artist: String
    public let album: String
    public var duration: TimeInterval
    public var persistentID: String
    public let isURLTrack: Bool
    /// Also this play's identity token: PlaybackHistoryStore.patchPersistentID
    /// and PendingPlaybackAccumulator.updatePersistentID both key off exact
    /// equality with this value, not off title/artist (which two different
    /// plays of the same song legitimately share).
    public let startedAt: Date
    /// Wall-clock seconds accumulated from COMPLETED playing segments —
    /// excludes whatever segment is currently in progress, if any (see
    /// `playingSegmentStartedAt`). Paused time is never added here.
    public var accumulatedPlayingSeconds: TimeInterval
    /// Non-nil exactly while this play is the actively-playing track: the
    /// moment the CURRENT (still in-progress) playing segment began. Mirrors
    /// the existing `playbackClockBaseDate`/`playbackClockIsPlaying` idiom
    /// (MusicController.swift) rather than inventing a new timing model.
    public var playingSegmentStartedAt: Date?
    public var hasCommitted: Bool

    public init(
        title: String, artist: String, album: String, duration: TimeInterval,
        persistentID: String, isURLTrack: Bool, startedAt: Date,
        accumulatedPlayingSeconds: TimeInterval = 0,
        playingSegmentStartedAt: Date? = nil,
        hasCommitted: Bool = false
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.persistentID = persistentID
        self.isURLTrack = isURLTrack
        self.startedAt = startedAt
        self.accumulatedPlayingSeconds = accumulatedPlayingSeconds
        self.playingSegmentStartedAt = playingSegmentStartedAt
        self.hasCommitted = hasCommitted
    }
}

// ============================================================
// MARK: - Pure decision functions
// ============================================================

public enum PendingPlaybackRules {

    /// Total listened seconds as of `now`, folding in whatever playing
    /// segment is currently in progress. Pure — mirrors
    /// MusicController.lyricRenderTime(at:)'s "base + elapsed-while-playing"
    /// shape so this is trivially fake-clock-testable and never depends on
    /// wall-clock reads happening at call time.
    public static func totalListenedSeconds(_ play: PendingPlay, at now: Date) -> TimeInterval {
        guard let segmentStart = play.playingSegmentStartedAt else { return play.accumulatedPlayingSeconds }
        return play.accumulatedPlayingSeconds + max(0, now.timeIntervalSince(segmentStart))
    }

    /// Whether `listenedSeconds` of ACTUAL playing time (pauses excluded)
    /// qualifies a play for History.
    /// - `minimumListenSeconds <= 0` → old behavior, every confirmed change
    ///   qualifies immediately (the founder's documented 0 = opt-out value).
    /// - Otherwise → must reach `minimumListenSeconds`, OR the track's own
    ///   `duration` if that's shorter (a track shorter than the threshold
    ///   that played to its natural end must still count — "播到自然结束
    ///   （很短的曲子）" in the phase-1 diagnosis). `duration <= 0` (unknown,
    ///   e.g. some radio streams) skips that comparison — only the flat
    ///   threshold applies.
    public static func qualifiesForHistory(listenedSeconds: TimeInterval, duration: TimeInterval, minimumListenSeconds: TimeInterval) -> Bool {
        guard minimumListenSeconds > 0 else { return true }
        let effectiveThreshold = duration > 0 ? min(minimumListenSeconds, duration) : minimumListenSeconds
        return listenedSeconds >= effectiveThreshold
    }

    /// Whether a newly-confirmed track change is really just a REDUNDANT
    /// re-detection of the song already being tracked (the notification path
    /// and the snapshot/poll path both confirming the same still-playing
    /// song, or a snapshot re-detecting a song whose History row it already
    /// committed moments ago — the real 2026-09-25 02:03:55 "Roses" capture
    /// in the phase-1 diagnosis is exactly this shape). PID is authoritative
    /// when both sides have one; otherwise title+artist decide (mirrors
    /// MusicController.notificationIndicatesTrackChange's own PID-authority
    /// rule, applied one layer earlier).
    public static func isSameSong(_ play: PendingPlay, title: String, artist: String, persistentID: String) -> Bool {
        if !persistentID.isEmpty, !play.persistentID.isEmpty {
            return persistentID == play.persistentID
        }
        return title == play.title && artist == play.artist
    }
}

// ============================================================
// MARK: - PendingPlaybackAccumulator (stateful, main-thread-only)
// ============================================================

/// Owns exactly one in-flight `PendingPlay` at a time. Main-thread-only,
/// matching PlaybackHistoryStore and every existing MusicController call
/// site this wires into.
public final class PendingPlaybackAccumulator {

    private let store: PlaybackHistoryStore
    private let clock: () -> Date
    public var minimumListenSeconds: TimeInterval
    public private(set) var current: PendingPlay?

    public init(
        store: PlaybackHistoryStore,
        minimumListenSeconds: TimeInterval,
        clock: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.minimumListenSeconds = minimumListenSeconds
        self.clock = clock
    }

    /// Call at EVERY confirmed track change, on BOTH paths — for the
    /// notification path, call this BEFORE the async ScriptingBridge
    /// persistentID read starts (see the H3 note on `PendingPlay` above).
    /// `persistentID` may be "" when not yet known; `updatePersistentID`
    /// fills it in later.
    public func beginPendingPlay(
        title: String, artist: String, album: String, duration: TimeInterval,
        persistentID: String, isURLTrack: Bool, isPlaying: Bool, now: Date? = nil
    ) {
        let now = now ?? clock()

        if let existing = current, PendingPlaybackRules.isSameSong(existing, title: title, artist: artist, persistentID: persistentID) {
            // Redundant re-detection of the song already being tracked — keep
            // accumulating on the SAME pending play. Restarting here would
            // both throw away progress toward the threshold AND risk a
            // second History row for one continuous listen.
            DebugLogger.log("History", "skip (redundant re-detection of in-flight play): \(title) - \(artist)")
            return
        }

        // Finalize the OUTGOING play's bookkeeping through THIS exact instant
        // before deciding its fate. `totalListenedSeconds` is a pure function
        // of the play's stored fields + `now`, so this correctly catches a
        // play that crossed the threshold between its last `tick()` and this
        // supersession (e.g. the notification path, which has no tick of its
        // own between two rapid confirmed changes) — it must still commit,
        // never be discarded on stale state.
        if current != nil {
            checkAndCommit(now: now)
        }
        if let outgoing = current, !outgoing.hasCommitted {
            let listened = PendingPlaybackRules.totalListenedSeconds(outgoing, at: now)
            DebugLogger.log("History", "discard (listened \(String(format: "%.1f", listened))s, under \(minimumListenSeconds)s threshold): \(outgoing.title) - \(outgoing.artist)")
        }

        DebugLogger.log("History", "begin pending play: \(title) - \(artist) pid='\(persistentID)'")
        current = PendingPlay(
            title: title, artist: artist, album: album, duration: duration,
            persistentID: persistentID, isURLTrack: isURLTrack, startedAt: now,
            playingSegmentStartedAt: isPlaying ? now : nil
        )
        checkAndCommit(now: now)
    }

    /// Call whenever a persistentID resolves after the play began (SB
    /// completion, a background PID-refill poll). `startedAt` MUST be the
    /// exact `now` value `beginPendingPlay` used for this play — safe to
    /// call for a superseded or already-committed play; both branches below
    /// are no-ops in that case. `refreshedDuration` (SB's own duration read
    /// is more authoritative than the notification's) updates the STILL-PENDING
    /// play's duration too when provided and positive — it does not retroactively
    /// touch an already-committed entry's persisted duration.
    public func updatePersistentID(startedAt: Date, persistentID: String, isURLTrack: Bool, refreshedDuration: TimeInterval? = nil, now: Date? = nil) {
        guard !persistentID.isEmpty else { return }
        let now = now ?? clock()

        if var play = current, play.startedAt == startedAt, play.persistentID.isEmpty {
            DebugLogger.log("History", "patch pending PID: \(play.title) - \(play.artist) pid='\(persistentID)'")
            play.persistentID = persistentID
            if let refreshedDuration, refreshedDuration > 0 {
                play.duration = refreshedDuration
            }
            current = play
            checkAndCommit(now: now)
        }
        // Idempotent regardless of the branch above: if that play already
        // committed with an empty PID (minimumListenSeconds == 0, or a very
        // slow SB read), the store itself still needs the patch. If it never
        // qualified (discarded already), this is a harmless no-op.
        store.patchPersistentID(startedAt: startedAt, persistentID: persistentID, isURLTrack: isURLTrack)
    }

    /// Convenience for call sites that don't have the pending play's exact
    /// `startedAt` identity token in scope but are structurally guaranteed —
    /// by their OWN caller-side gate (e.g. "this snapshot is NOT a track
    /// change") — to be talking about whatever play IS currently pending
    /// (MusicController's "PID refill recovery" branch in applySnapshot).
    /// No-ops when there is no current pending play.
    public func updateCurrentPersistentIDIfPending(persistentID: String, isURLTrack: Bool, now: Date? = nil) {
        guard let startedAt = current?.startedAt else { return }
        updatePersistentID(startedAt: startedAt, persistentID: persistentID, isURLTrack: isURLTrack, now: now)
    }

    /// Call from MusicController's EXISTING snapshot-poll cadence (no new
    /// timer) — accumulates listened time (paused time excluded) and commits
    /// the instant the threshold is crossed, so the entry lands in History
    /// even if the app quits mid-song rather than waiting for the next track
    /// change.
    public func tick(isPlaying: Bool, now: Date? = nil) {
        guard var play = current, !play.hasCommitted else { return }
        let now = now ?? clock()
        if let segmentStart = play.playingSegmentStartedAt {
            play.accumulatedPlayingSeconds += max(0, now.timeIntervalSince(segmentStart))
        }
        play.playingSegmentStartedAt = isPlaying ? now : nil
        current = play
        checkAndCommit(now: now)
    }

    /// Called from applicationWillTerminate: folds the in-progress segment
    /// (if any) up through `now` one last time and commits if that crosses
    /// the threshold — belt-and-suspenders alongside the regular `tick`
    /// cadence for the last few seconds before quit. Does NOT grant any
    /// unlistened time; a play that hasn't reached the threshold yet is
    /// still correctly left uncommitted (and is lost on quit, same as it
    /// always was for anything below the threshold — this only protects a
    /// play that crossed the line moments before quitting).
    public func flushForAppTermination(now: Date? = nil) {
        guard let play = current else { return }
        tick(isPlaying: play.playingSegmentStartedAt != nil, now: now ?? clock())
    }

    /// Settings → "Clear Playback History": an in-flight play must not
    /// resurrect an entry into the store the user just asked to wipe.
    public func reset() {
        current = nil
    }

    private func checkAndCommit(now: Date) {
        guard let play = current, !play.hasCommitted else { return }
        let listened = PendingPlaybackRules.totalListenedSeconds(play, at: now)
        guard PendingPlaybackRules.qualifiesForHistory(listenedSeconds: listened, duration: play.duration, minimumListenSeconds: minimumListenSeconds) else { return }
        let entry = PlaybackHistoryEntry.make(
            title: play.title, artist: play.artist, album: play.album,
            persistentID: play.persistentID, duration: play.duration,
            isURLTrack: play.isURLTrack, startedAt: play.startedAt
        )
        DebugLogger.log("History", "commit (listened \(String(format: "%.1f", listened))s): \(play.title) - \(play.artist) pid='\(play.persistentID)'")
        store.record(entry, now: now)
        var committed = play
        committed.hasCommitted = true
        current = committed
    }
}
