/**
 * [INPUT]: Foundation + NanoPodCacheLocation (directory/filename scoping)
 * [OUTPUT]: PlaybackHistoryEntry (Codable model) + PlaybackHistoryStore
 *           (main-thread, capacity-bounded, debounced-persist playback history)
 * [POS]: Services — MusicController's PendingPlaybackAccumulator records a
 *        confirmed-and-qualified play here (see PendingPlaybackAccumulator.swift
 *        and MusicController's track-identity discipline); PlaylistView reads
 *        `entries` (newest first) for the History section (WT-D plan H).
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - PlaybackHistoryEntry
// ============================================================

/// One confirmed, qualified track play nanoPod actually observed. Founder
/// ruling 2026-09-13: History must be REAL playback history nanoPod
/// witnessed (any source, any shuffle state) — never Apple Music's
/// account-level "recently played", which is not what this app played.
/// "Qualified" (2026-09-25 diagnosis fix): a play only becomes a History
/// entry once PendingPlaybackAccumulator confirms it was actually listened
/// to for at least `MusicController.minimumListenSecondsForHistory` (or
/// played to a natural end shorter than that) — see PendingPlaybackAccumulator.swift.
public struct PlaybackHistoryEntry: Codable, Equatable, Identifiable {
    /// Stable identity for SwiftUI `ForEach` — index-based identity shifts
    /// every row's identity on each new insertion (entries prepend at index
    /// 0), forcing full row rebuilds and artwork-reload churn. `persistentID`
    /// may be empty for radio/stream tracks, so `startedAt` disambiguates.
    public var id: String { "\(persistentID)|\(startedAt.timeIntervalSince1970)" }

    public enum SourceKind: String, Codable, Equatable {
        case library
        case appleMusicCatalog
        case radioOrStream
        case unknown
    }

    public let persistentID: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let sourceKind: SourceKind
    public let startedAt: Date

    public init(
        persistentID: String,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        sourceKind: SourceKind,
        startedAt: Date
    ) {
        self.persistentID = persistentID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sourceKind = sourceKind
        self.startedAt = startedAt
    }

    /// Derives `sourceKind` from what MusicController already knows — no
    /// extra network/SB round trip.
    /// - "am:"-prefixed persistentID → Apple Music catalog playback.
    /// - URL track / no persistentID → radio or a network stream.
    /// - Otherwise → a local library track.
    /// Pure; shared by `make(...)` and `PlaybackHistoryStore.patchPersistentID`
    /// so a late-arriving PID is classified by the EXACT same rule a
    /// same-PID-from-the-start entry would have used — one source of truth.
    public static func deriveSourceKind(persistentID: String, isURLTrack: Bool) -> SourceKind {
        if persistentID.hasPrefix("am:") {
            return .appleMusicCatalog
        } else if isURLTrack || persistentID.isEmpty {
            return .radioOrStream
        } else {
            return .library
        }
    }

    public static func make(
        title: String,
        artist: String,
        album: String,
        persistentID: String,
        duration: TimeInterval,
        isURLTrack: Bool,
        startedAt: Date
    ) -> PlaybackHistoryEntry {
        PlaybackHistoryEntry(
            persistentID: persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            sourceKind: deriveSourceKind(persistentID: persistentID, isURLTrack: isURLTrack),
            startedAt: startedAt
        )
    }
}

// ============================================================
// MARK: - PlaybackHistoryStore
// ============================================================

/// Main-thread-only ring buffer of confirmed, qualified playback history,
/// capped at `capacity` entries (newest first), persisted to a small JSON
/// file with a debounced write. File location, clock, and the write itself
/// are injectable so tests never touch the real filesystem or a real timer.
public final class PlaybackHistoryStore {

    /// 2026-09-25 diagnosis fix (H8), raised from 50: real NSWindow-hosted
    /// PlaylistView measurement (PlaybackHistoryCapacityMeasurementTests) of
    /// average body-eval+layout cost at History row counts 50/100/200/300 —
    /// 11.2ms/12.3ms/23.6ms/32.8ms on the dev machine — put the 16.67ms
    /// (60fps) frame budget crossover at roughly row 139 by linear
    /// interpolation. Every UNRELATED @Published write already forces a full
    /// PlaylistView.body re-evaluation (PlaylistViewRenderChurnTests), so
    /// this cost multiplies by write frequency, not just History-changing
    /// events — 100 keeps a real margin under that budget (measured 12.3ms)
    /// while doubling coverage from ~30.75h to ~61.5h at the founder's
    /// observed rate. At ~196 bytes/entry (measured), 100 entries is ~19.1KB
    /// — well inside the founder's "几十 KB" 2026-09-13 ceiling. Row-level
    /// artwork fetching is unaffected by this number: RowArtworkVisibilityPolicy
    /// (page-visibility gate) + RowArtworkFetchGate (3 concurrent) +
    /// RowArtworkNegativeCache (backoff) already bound worst-case fetch
    /// activity independent of row count — see research/diagnosis-2026-09-25-history.md §3.
    public static let capacity = 100
    public static let debounceInterval: TimeInterval = 1.0

    /// Bumped whenever the persisted shape changes. v1 (2026-09-25): first
    /// version routed through `NanoPodCacheLocation` instead of a hand-rolled
    /// Application Support path — the pre-versioning "playback-history.json"
    /// is read ONCE as a migration seed (see `legacySeedURL`) so the
    /// founder's existing entries are never lost, then never written to again.
    public static let schemaVersion = 1
    private static let baseName = "playback-history"

    /// A legitimate file this large already implies thousands of entries
    /// (capacity × ~200B/entry, see H8 measurement) — well beyond that means
    /// either a stale huge file from a former higher capacity, or damage.
    /// Bounding the READ (not just the decode) before touching content is
    /// the 2026-09-25 fix for H-loading-unbounded: `load()` checks this via
    /// `FileManager.attributesOfItem` before ever calling `Data(contentsOf:)`.
    public static let maxLoadableFileBytes = 512 * 1024

    /// (delay, block) → schedule block to run after delay. Default schedules
    /// on the main queue; tests inject a synchronous capture that lets them
    /// fire (or skip) the debounce deterministically without sleeping.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    /// (data, fileURL) → persist. Default writes to disk; tests inject a
    /// capture hook instead.
    public typealias WriteHook = (Data, URL) -> Void

    public private(set) var entries: [PlaybackHistoryEntry] = []

    /// Fires exactly when `entries` actually changes (a real insert, patch,
    /// or clear — never on a no-op call). MusicController uses this to keep
    /// its `@Published playbackHistory` in sync WITHOUT reassigning on every
    /// `PendingPlaybackAccumulator.tick()` — `@Published` fires
    /// `objectWillChange` on every assignment regardless of equality, so an
    /// unconditional republish on the ~2s poll cadence would force a
    /// SwiftUI PlaylistView.body re-evaluation that often (see
    /// PlaylistViewRenderChurnTests' own finding that @EnvironmentObject
    /// invalidates the whole body on ANY @Published write).
    public var onChange: (() -> Void)?

    private let fileURL: URL
    private let legacySeedURL: URL?
    private let clock: () -> Date
    private let scheduler: Scheduler
    private let writeHook: WriteHook?
    private let debounceInterval: TimeInterval
    private var writeGeneration = 0
    /// True whenever in-memory `entries` may differ from what's on disk —
    /// lets `flush()` (called from applicationWillTerminate) skip a
    /// redundant write when nothing changed since the last one.
    private var dirty = false

    /// Default on-disk file: NanoPodCacheLocation-scoped directory
    /// (production: ~/Library/Application Support/nanoPod/playback-history.v1.json;
    /// XCTest/dev/worktree builds isolated elsewhere — see NanoPodCacheLocation).
    /// A same-directory pre-versioning "playback-history.json" is read ONCE
    /// as a migration seed (never written to) — see `legacySeedURL`.
    public static func defaultURL() -> URL {
        NanoPodCacheLocation.versionedFileURL(baseName: baseName, schemaVersion: schemaVersion)
    }

    public init(
        fileURL: URL = PlaybackHistoryStore.defaultURL(),
        clock: @escaping () -> Date = Date.init,
        debounceInterval: TimeInterval = PlaybackHistoryStore.debounceInterval,
        scheduler: @escaping Scheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        },
        writeHook: WriteHook? = nil
    ) {
        self.fileURL = fileURL
        self.legacySeedURL = NanoPodCacheLocation.legacySeedURL(for: fileURL, baseName: Self.baseName, schemaVersion: Self.schemaVersion)
        self.clock = clock
        self.debounceInterval = debounceInterval
        self.scheduler = scheduler
        self.writeHook = writeHook
        load()
    }

    // MARK: - Dedupe (pure)

    /// Whether `candidate` should be appended given the current newest entry.
    /// - Same persistentID as the immediately-preceding entry → skip (repeat
    ///   mode loop-end / seek-back re-detection re-announcing the same song).
    /// - No persistentID on both sides (radio/URL track) with the same
    ///   title+artist re-appearing within 3s → skip (stream-buffering title
    ///   jitter, not a real song change).
    /// Retained as a defensive backstop: PendingPlaybackAccumulator already
    /// keeps one continuous listen from committing twice (its own
    /// same-song-in-progress check), so in practice this should never see a
    /// true duplicate candidate — but `record()` stays safe to call directly
    /// (as every existing test already does) without relying on that upstream
    /// discipline.
    public static func shouldRecord(candidate: PlaybackHistoryEntry, last: PlaybackHistoryEntry?, now: Date) -> Bool {
        guard let last else { return true }
        if !candidate.persistentID.isEmpty, candidate.persistentID == last.persistentID {
            return false
        }
        if candidate.persistentID.isEmpty, last.persistentID.isEmpty,
           candidate.title == last.title, candidate.artist == last.artist,
           now.timeIntervalSince(last.startedAt) < 3.0 {
            return false
        }
        return true
    }

    // MARK: - Mutation

    /// Records a confirmed, qualified track play, subject to dedupe, trims to
    /// `capacity`, and schedules a debounced persist.
    public func record(_ candidate: PlaybackHistoryEntry, now: Date) {
        guard Self.shouldRecord(candidate: candidate, last: entries.first, now: now) else { return }
        entries.insert(candidate, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        scheduleWrite()
        onChange?()
    }

    /// Patches the persistentID/sourceKind of an already-recorded entry in
    /// place, matched by its exact `startedAt` (the identity token the
    /// caller — PendingPlaybackAccumulator — was given when that entry was
    /// committed). Never inserts a new row (2026-09-25 fix for H4: an SB
    /// timeout that resolves the real PID only after the entry already
    /// qualified and committed with an empty PID must not double-record).
    /// No-op if no entry with that `startedAt` and an empty `persistentID`
    /// exists — safe to call unconditionally, including for a play that was
    /// discarded (never crossed the listen threshold) or already carries a
    /// real PID.
    public func patchPersistentID(startedAt: Date, persistentID: String, isURLTrack: Bool) {
        guard let index = entries.firstIndex(where: { $0.startedAt == startedAt && $0.persistentID.isEmpty }) else { return }
        guard !persistentID.isEmpty else { return }
        let old = entries[index]
        entries[index] = PlaybackHistoryEntry(
            persistentID: persistentID,
            title: old.title,
            artist: old.artist,
            album: old.album,
            duration: old.duration,
            sourceKind: PlaybackHistoryEntry.deriveSourceKind(persistentID: persistentID, isURLTrack: isURLTrack),
            startedAt: old.startedAt
        )
        scheduleWrite()
        onChange?()
    }

    /// Clears all history (Settings → "Clear Playback History").
    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleWrite()
        onChange?()
    }

    /// Forces the pending debounced write to disk NOW — called from the
    /// app's applicationWillTerminate (2026-09-25 fix: without this, a play
    /// that crossed the listen threshold in its last second before quit
    /// could still be sitting in the 1s debounce window when the process
    /// dies, and `DispatchQueue.main.asyncAfter` work never survives that).
    /// Safe to call repeatedly — a clean store is a no-op.
    public func flush() {
        guard dirty else { return }
        performWrite()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = boundedRead(at: fileURL) ?? legacySeedURL.flatMap(boundedRead(at:)),
              let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = Array(decoded.prefix(Self.capacity))
    }

    /// Checks the file's SIZE (a metadata stat, not a read) before ever
    /// loading its bytes. 2026-09-25 fix: `load()` used to call
    /// `Data(contentsOf:)` unconditionally — a damaged or adversarial
    /// multi-megabyte file would be read into memory in full before decode
    /// even had a chance to reject it. A file over `maxLoadableFileBytes` is
    /// treated exactly like a corrupt one (empty in-memory history) WITHOUT
    /// touching its bytes or overwriting it — only a later real `record()`/
    /// `clear()` ever schedules a write, so an oversized-but-possibly-salvageable
    /// file is left on disk for manual inspection, never blindly discarded.
    private func boundedRead(at url: URL) -> Data? {
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > Self.maxLoadableFileBytes {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private func scheduleWrite() {
        dirty = true
        writeGeneration += 1
        let generation = writeGeneration
        scheduler(debounceInterval) { [weak self] in
            guard let self, self.writeGeneration == generation else { return }
            self.performWrite()
        }
    }

    private func performWrite() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        dirty = false
        if let writeHook {
            writeHook(data, fileURL)
        } else {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
