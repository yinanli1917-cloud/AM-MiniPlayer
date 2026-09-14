/**
 * [INPUT]: Foundation only — no other module dependencies
 * [OUTPUT]: PlaybackHistoryEntry (Codable model) + PlaybackHistoryStore
 *           (main-thread, capacity-50, debounced-persist playback history)
 * [POS]: Services — MusicController records a confirmed track change here
 *        (see MusicController.swift track-identity discipline); PlaylistView
 *        reads `entries` (newest first) for the History section (WT-D plan H).
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - PlaybackHistoryEntry
// ============================================================

/// One confirmed track change nanoPod actually observed. Founder ruling
/// 2026-09-13: History must be REAL playback history nanoPod witnessed (any
/// source, any shuffle state) — never Apple Music's account-level "recently
/// played", which is not what this app played.
public struct PlaybackHistoryEntry: Codable, Equatable {
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

    /// Derives `sourceKind` from what MusicController already knows at the
    /// confirmed-track-change point — no extra network/SB round trip.
    /// - "am:"-prefixed persistentID → Apple Music catalog playback.
    /// - URL track / no persistentID → radio or a network stream.
    /// - Otherwise → a local library track.
    public static func make(
        title: String,
        artist: String,
        album: String,
        persistentID: String,
        duration: TimeInterval,
        isURLTrack: Bool,
        startedAt: Date
    ) -> PlaybackHistoryEntry {
        let sourceKind: SourceKind
        if persistentID.hasPrefix("am:") {
            sourceKind = .appleMusicCatalog
        } else if isURLTrack || persistentID.isEmpty {
            sourceKind = .radioOrStream
        } else {
            sourceKind = .library
        }
        return PlaybackHistoryEntry(
            persistentID: persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            sourceKind: sourceKind,
            startedAt: startedAt
        )
    }
}

// ============================================================
// MARK: - PlaybackHistoryStore
// ============================================================

/// Main-thread-only ring buffer of confirmed playback history, capped at
/// `capacity` entries (newest first), persisted to a small JSON file with a
/// debounced write. Directory, clock, and the write itself are injectable so
/// tests never touch the real filesystem or a real timer.
public final class PlaybackHistoryStore {

    public static let capacity = 50
    public static let debounceInterval: TimeInterval = 1.0

    /// (delay, block) → schedule block to run after delay. Default schedules
    /// on the main queue; tests inject a synchronous capture that lets them
    /// fire (or skip) the debounce deterministically without sleeping.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    /// (data, fileURL) → persist. Default writes to disk; tests inject a
    /// capture hook instead.
    public typealias WriteHook = (Data, URL) -> Void

    public private(set) var entries: [PlaybackHistoryEntry] = []

    private let directoryURL: URL
    private let fileURL: URL
    private let clock: () -> Date
    private let scheduler: Scheduler
    private let writeHook: WriteHook?
    private let debounceInterval: TimeInterval
    private var writeGeneration = 0

    /// Default on-disk location: ~/Library/Application Support/nanoPod/playback-history.json
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("nanoPod", isDirectory: true)
    }

    public init(
        directory: URL = PlaybackHistoryStore.defaultDirectory,
        clock: @escaping () -> Date = Date.init,
        debounceInterval: TimeInterval = PlaybackHistoryStore.debounceInterval,
        scheduler: @escaping Scheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
        },
        writeHook: WriteHook? = nil
    ) {
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent("playback-history.json", isDirectory: false)
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

    /// Records a confirmed track change, subject to dedupe, trims to
    /// `capacity`, and schedules a debounced persist.
    public func record(_ candidate: PlaybackHistoryEntry, now: Date) {
        guard Self.shouldRecord(candidate: candidate, last: entries.first, now: now) else { return }
        entries.insert(candidate, at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        scheduleWrite()
    }

    /// Clears all history (Settings → "Clear Playback History").
    public func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleWrite()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = Array(decoded.prefix(Self.capacity))
    }

    private func scheduleWrite() {
        writeGeneration += 1
        let generation = writeGeneration
        scheduler(debounceInterval) { [weak self] in
            guard let self, self.writeGeneration == generation else { return }
            self.performWrite()
        }
    }

    private func performWrite() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        if let writeHook {
            writeHook(data, fileURL)
        } else {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
