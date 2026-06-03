/**
 * [INPUT]: Foundation + CryptoKit
 * [OUTPUT]: LyricsDiskCache (persistent JSON cache for verified synced lyrics)
 * [POS]: Utils — keeps slow-but-correct synced source results off the interactive path; schema version invalidates rows when identity gates change
 */

import Foundation
import CryptoKit

public struct LyricsDiskCacheEntry: Codable, Equatable {
    public let source: String
    public let syncedLyrics: String
    public let lines: [CachedLyricLine]?
    public let kind: LyricsKind?
    public let ts: TimeInterval
    public let duration: TimeInterval
    public let album: String?
    public let matchedDurationDiff: TimeInterval?
}

public struct CachedLyricLine: Codable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let words: [CachedLyricWord]
    public let translation: String?
}

public struct CachedLyricWord: Codable, Equatable {
    public let word: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
}

private struct LyricsDiskCacheFile: Codable {
    let version: Int
    var entries: [String: LyricsDiskCacheEntry]
}

public final class LyricsDiskCache {
    public static let schemaVersion = 26
    public static let ttlSeconds: TimeInterval = 30 * 86400
    public static let unavailableTTLSeconds: TimeInterval = 24 * 3600
    public static let defaultMaxEntryCount = 450

    private let fileURL: URL
    private let maxEntryCount: Int
    private let queue = DispatchQueue(label: "com.yinanli.MusicMiniPlayer.lyrics-disk-cache")
    private var memory: [String: LyricsDiskCacheEntry] = [:]
    private var loaded = false

    public init(fileURL: URL = LyricsDiskCache.defaultURL(), maxEntryCount: Int = LyricsDiskCache.defaultMaxEntryCount) {
        self.fileURL = fileURL
        self.maxEntryCount = max(1, maxEntryCount)
    }

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("nanoPod", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lyrics_cache.json")
    }

    public func get(title: String, artist: String, duration: TimeInterval, album: String = "") -> LyricsDiskCacheEntry? {
        candidates(title: title, artist: artist, duration: duration, album: album).first
    }

    public func candidates(title: String, artist: String, duration: TimeInterval, album: String = "") -> [LyricsDiskCacheEntry] {
        let keys = Self.cacheKeys(title: title, artist: artist, duration: duration, album: album)
        return queue.sync {
            ensureLoaded()
            var changed = pruneMemoryIfNeeded()
            var entries: [LyricsDiskCacheEntry] = []
            for key in keys {
                guard let entry = memory[key] else { continue }
                let ttl = entry.kind == .unavailable ? Self.unavailableTTLSeconds : Self.ttlSeconds
                if Date().timeIntervalSince1970 - entry.ts > ttl {
                    memory.removeValue(forKey: key)
                    changed = true
                    continue
                }
                entries.append(entry)
            }
            if changed {
                persist()
            }
            return entries
        }
    }

    public func set(title: String, artist: String, duration: TimeInterval, album: String = "", source: String, syncedLyrics: String, matchedDurationDiff: TimeInterval?) {
        let entry = LyricsDiskCacheEntry(
            source: source,
            syncedLyrics: syncedLyrics,
            lines: nil,
            kind: .synced,
            ts: Date().timeIntervalSince1970,
            duration: duration,
            album: album.isEmpty ? nil : album,
            matchedDurationDiff: matchedDurationDiff
        )
        setEntry(entry, title: title, artist: artist, duration: duration, album: album)
    }

    public func set(title: String, artist: String, duration: TimeInterval, album: String = "", source: String, lines: [LyricLine], matchedDurationDiff: TimeInterval?) {
        let cachedLines = LyricsWordRepair.repair(lines: lines).map { line in
            CachedLyricLine(
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                words: line.words.map { CachedLyricWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) },
                translation: line.translation
            )
        }
        let entry = LyricsDiskCacheEntry(
            source: source,
            syncedLyrics: "",
            lines: cachedLines,
            kind: .synced,
            ts: Date().timeIntervalSince1970,
            duration: duration,
            album: album.isEmpty ? nil : album,
            matchedDurationDiff: matchedDurationDiff
        )
        setEntry(entry, title: title, artist: artist, duration: duration, album: album)
    }

    public func setAvailability(
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String = "",
        source: String,
        kind: LyricsKind,
        lines: [LyricLine],
        matchedDurationDiff: TimeInterval?
    ) {
        guard kind == .instrumental || kind == .unavailable else { return }
        let cachedLines = LyricsWordRepair.repair(lines: lines).map { line in
            CachedLyricLine(
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                words: line.words.map { CachedLyricWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) },
                translation: line.translation
            )
        }
        let entry = LyricsDiskCacheEntry(
            source: source,
            syncedLyrics: "",
            lines: cachedLines,
            kind: kind,
            ts: Date().timeIntervalSince1970,
            duration: duration,
            album: album.isEmpty ? nil : album,
            matchedDurationDiff: matchedDurationDiff
        )
        setEntry(entry, title: title, artist: artist, duration: duration, album: album)
    }

    public static func lyricLines(from cached: [CachedLyricLine]) -> [LyricLine] {
        LyricsWordRepair.repair(lines: cached.map { line in
            LyricLine(
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                words: line.words.map { LyricWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) },
                translation: line.translation
            )
        })
    }

    private func setEntry(_ entry: LyricsDiskCacheEntry, title: String, artist: String, duration: TimeInterval, album: String) {
        let keys = Self.cacheKeys(title: title, artist: artist, duration: duration, album: album)
        queue.sync {
            ensureLoaded()
            for key in keys {
                memory[key] = entry
            }
            _ = pruneMemoryIfNeeded()
            persist()
        }
    }

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(LyricsDiskCacheFile.self, from: data),
              envelope.version == Self.schemaVersion else { return }
        memory = envelope.entries
        if pruneMemoryIfNeeded() {
            persist()
        }
    }

    @discardableResult
    private func pruneMemoryIfNeeded(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let before = memory.count
        memory = memory.filter { _, entry in
            let ttl = entry.kind == .unavailable ? Self.unavailableTTLSeconds : Self.ttlSeconds
            return now - entry.ts <= ttl
        }

        if memory.count > maxEntryCount {
            let overflow = memory.count - maxEntryCount
            let oldestKeys = memory.keys.sorted { lhs, rhs in
                let lhsTimestamp = memory[lhs]?.ts ?? 0
                let rhsTimestamp = memory[rhs]?.ts ?? 0
                if lhsTimestamp == rhsTimestamp {
                    return lhs < rhs
                }
                return lhsTimestamp < rhsTimestamp
            }.prefix(overflow)

            for key in oldestKeys {
                memory.removeValue(forKey: key)
            }
        }

        return memory.count != before
    }

    func entryCountForTesting() -> Int {
        queue.sync {
            ensureLoaded()
            return memory.count
        }
    }

    private func persist() {
        let envelope = LyricsDiskCacheFile(version: Self.schemaVersion, entries: memory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    public static func cacheKeys(title: String, artist: String, duration: TimeInterval, album: String = "") -> [String] {
        let nt = MetadataDiskCache.normalize(title)
        let na = MetadataDiskCache.normalize(artist)
        let nalb = MetadataDiskCache.normalize(album)
        let rounded = Int(duration.rounded())
        return [rounded - 1, rounded, rounded + 1].map { d in
            let raw = "\(nt)|\(na)|\(nalb)|\(d)"
            let digest = SHA256.hash(data: Data(raw.utf8))
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        }
    }
}
