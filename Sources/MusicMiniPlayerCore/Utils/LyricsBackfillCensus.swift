/**
 * [INPUT]: Per-song fetch facts from LyricsService's foreground/backfill paths
 * [OUTPUT]: One JSONL line per song fetch in Application Support, for the A4
 *           data-collection phase (2026-09-11) ahead of folding the 9s
 *           authoritative backfill into the 3s budget
 *           (docs/t2-3s-budget-plan-2026-08-25.md §3).
 * [POS]: Utils; runs in the RELEASE bundle by default (unlike DebugConfig's
 *        LOCAL_DEVELOPER_BUILD probes), cheap (one line per song, never per
 *        frame), with a runtime kill switch. NEVER writes to /tmp — a stale
 *        /tmp probe file once silently re-armed per-frame probes and wrote
 *        hundreds of MB (see DebugConfig.swift). Does not log lyric text.
 * [PROTOCOL]: Classification is pure and table-testable (LyricsBackfillCensusTests);
 *             the writer is a thin append-only JSONL sink with a size cap.
 */

import Foundation

/// Backfill-census record shape + pure classifiers. Kept separate from the
/// writer so the classification logic can be unit-tested without touching
/// disk.
public enum LyricsBackfillCensus {

    /// UserDefaults key that disables all writes at runtime. Absent/false = enabled.
    public static let killSwitchKey = "NanoPodLyricsBackfillCensusDisabled"

    /// Rotate (truncate to a fresh file) once the JSONL file exceeds this —
    /// never left to grow unbounded.
    public static let maxFileSizeBytes: UInt64 = 2 * 1024 * 1024

    public enum ForegroundOutcome: String {
        case hitWord = "hit-word"
        case hitLine = "hit-line"
        case hitUnsynced = "hit-unsynced"
        case miss
        case instrumental
        case unreachable
    }

    public enum BackfillOutcome: String {
        case hitApplied = "hit-applied"
        case hitRejectedNoDemotion = "hit-rejected-no-demotion"
        case upgradedLineToWord = "upgraded-line-to-word"
        case miss
        case cancelled
        case none
    }

    /// One song fetch's settled facts. `duration`/`title`/`artist` are the
    /// pipeline's own keys (never the lyric text).
    public struct Record: Equatable {
        public let ts: Date
        public let title: String
        public let artist: String
        public let duration: TimeInterval
        public let foregroundOutcome: ForegroundOutcome
        public let foregroundMs: Int
        public let foregroundSource: String?
        public let backfillLaunched: Bool
        public let backfillOutcome: BackfillOutcome
        public let backfillMs: Int?
        public let backfillSource: String?
        public let kind: String?

        public init(
            ts: Date = Date(),
            title: String,
            artist: String,
            duration: TimeInterval,
            foregroundOutcome: ForegroundOutcome,
            foregroundMs: Int,
            foregroundSource: String?,
            backfillLaunched: Bool,
            backfillOutcome: BackfillOutcome,
            backfillMs: Int?,
            backfillSource: String?,
            kind: String?
        ) {
            self.ts = ts
            self.title = title
            self.artist = artist
            self.duration = duration
            self.foregroundOutcome = foregroundOutcome
            self.foregroundMs = foregroundMs
            self.foregroundSource = foregroundSource
            self.backfillLaunched = backfillLaunched
            self.backfillOutcome = backfillOutcome
            self.backfillMs = backfillMs
            self.backfillSource = backfillSource
            self.kind = kind
        }

        var jsonObject: [String: Any] {
            var object: [String: Any] = [
                "ts": Self.isoFormatter.string(from: ts),
                "title": title,
                "artist": artist,
                "duration": duration,
                "foregroundOutcome": foregroundOutcome.rawValue,
                "foregroundMs": foregroundMs,
                "backfillLaunched": backfillLaunched,
                "backfillOutcome": backfillOutcome.rawValue
            ]
            if let foregroundSource { object["foregroundSource"] = foregroundSource }
            if let backfillMs { object["backfillMs"] = backfillMs }
            if let backfillSource { object["backfillSource"] = backfillSource }
            if let kind { object["kind"] = kind }
            return object
        }

        static let isoFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter
        }()
    }

    /// Outcome of `applyFetchedLyricsIfCurrent` relevant to census classification.
    /// `notCurrent` covers both "song changed before apply" and an explicit
    /// cancellation — from the census's point of view both mean the backfill
    /// never got to influence what's on screen.
    public enum ApplyVerdict: Equatable {
        case notCurrent
        case rejectedNoDemotion
        case replaced(upgradedLineToWord: Bool)
    }

    /// Classify the foreground outcome for a HIT result (bestResult present).
    /// Miss / instrumental / unreachable are classified directly at the call
    /// site (they come from branches that never reach this helper).
    public static func classifyForegroundHitOutcome(
        kind: LyricsKind,
        hasWordLevel: Bool
    ) -> ForegroundOutcome {
        switch kind {
        case .synced:
            return hasWordLevel ? .hitWord : .hitLine
        case .unsynced:
            return .hitUnsynced
        case .instrumental:
            return .instrumental
        case .unavailable:
            return .miss
        }
    }

    /// Classify what the backfill actually delivered, using the pipeline's
    /// OWN no-demotion verdict (`shouldReplaceDisplayedLyrics`, surfaced via
    /// `ApplyVerdict`) rather than re-deriving it here.
    public static func classifyBackfillOutcome(
        launched: Bool,
        cancelled: Bool,
        fetchFoundLyrics: Bool,
        applyVerdict: ApplyVerdict?
    ) -> BackfillOutcome {
        guard launched else { return .none }
        if cancelled { return .cancelled }
        guard fetchFoundLyrics else { return .miss }
        switch applyVerdict {
        case .none, .notCurrent:
            return .cancelled
        case .rejectedNoDemotion:
            return .hitRejectedNoDemotion
        case .replaced(let upgradedLineToWord):
            return upgradedLineToWord ? .upgradedLineToWord : .hitApplied
        }
    }
}

/// Append-only JSONL writer for `LyricsBackfillCensus.Record`. One line per
/// song fetch (deduped by `fetchID` so a second settle for the same fetch is
/// a no-op), off the main thread, with a size cap and a runtime kill switch.
public final class LyricsBackfillCensusWriter {

    public static let shared = LyricsBackfillCensusWriter(fileURL: LyricsBackfillCensusWriter.defaultFileURL())

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.nanopod.lyrics-backfill-census", qos: .utility)
    private var settledFetchIDs = Set<String>()
    private let isEnabledOverride: (() -> Bool)?

    public init(fileURL: URL, isEnabledOverride: (() -> Bool)? = nil) {
        self.fileURL = fileURL
        self.isEnabledOverride = isEnabledOverride
    }

    public static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("lyrics-backfill-census.jsonl")
    }

    public var isEnabled: Bool {
        if let isEnabledOverride { return isEnabledOverride() }
        return !UserDefaults.standard.bool(forKey: LyricsBackfillCensus.killSwitchKey)
    }

    /// Record one settled fetch. Safe to call from any thread/actor; the
    /// actual file I/O happens on `queue`. A second call with the same
    /// `fetchID` is a no-op (one line per song).
    public func record(_ record: LyricsBackfillCensus.Record, fetchID: String) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            guard self.settledFetchIDs.insert(fetchID).inserted else { return }
            self.append(record)
        }
    }

    /// Test seam: forget dedupe state so the same fetchID can be recorded again.
    public func resetForTesting() {
        queue.sync { settledFetchIDs.removeAll() }
    }

    private func append(_ record: LyricsBackfillCensus.Record) {
        let object = record.jsonObject
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }

        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? UInt64,
           size > LyricsBackfillCensus.maxFileSizeBytes {
            try? FileManager.default.removeItem(at: fileURL)
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: lineData)
    }
}
