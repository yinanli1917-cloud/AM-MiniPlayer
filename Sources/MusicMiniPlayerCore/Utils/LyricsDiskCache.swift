/**
 * [INPUT]: Foundation + CryptoKit
 * [OUTPUT]: LyricsDiskCache (persistent JSON cache for verified synced lyrics)
 * [POS]: Utils — keeps slow-but-correct synced source results off the interactive path
 */

import Foundation
import CryptoKit

public struct LyricsDiskCacheEntry: Codable, Equatable {
    public let source: String
    public let syncedLyrics: String
    public let lines: [CachedLyricLine]?
    public let ts: TimeInterval
    public let duration: TimeInterval
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
    public static let schemaVersion = 2
    public static let ttlSeconds: TimeInterval = 30 * 86400

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.yinanli.MusicMiniPlayer.lyrics-disk-cache")
    private var memory: [String: LyricsDiskCacheEntry] = [:]
    private var loaded = false

    public init(fileURL: URL = LyricsDiskCache.defaultURL()) {
        self.fileURL = fileURL
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

    public func get(title: String, artist: String, duration: TimeInterval) -> LyricsDiskCacheEntry? {
        let keys = Self.cacheKeys(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            for key in keys {
                guard let entry = memory[key] else { continue }
                if Date().timeIntervalSince1970 - entry.ts > Self.ttlSeconds {
                    memory.removeValue(forKey: key)
                    continue
                }
                return entry
            }
            return nil
        }
    }

    public func set(title: String, artist: String, duration: TimeInterval, source: String, syncedLyrics: String, matchedDurationDiff: TimeInterval?) {
        let entry = LyricsDiskCacheEntry(
            source: source,
            syncedLyrics: syncedLyrics,
            lines: nil,
            ts: Date().timeIntervalSince1970,
            duration: duration,
            matchedDurationDiff: matchedDurationDiff
        )
        setEntry(entry, title: title, artist: artist, duration: duration)
    }

    public func set(title: String, artist: String, duration: TimeInterval, source: String, lines: [LyricLine], matchedDurationDiff: TimeInterval?) {
        let cachedLines = lines.map { line in
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
            ts: Date().timeIntervalSince1970,
            duration: duration,
            matchedDurationDiff: matchedDurationDiff
        )
        setEntry(entry, title: title, artist: artist, duration: duration)
    }

    public static func lyricLines(from cached: [CachedLyricLine]) -> [LyricLine] {
        cached.map { line in
            LyricLine(
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                words: line.words.map { LyricWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) },
                translation: line.translation
            )
        }
    }

    private func setEntry(_ entry: LyricsDiskCacheEntry, title: String, artist: String, duration: TimeInterval) {
        let keys = Self.cacheKeys(title: title, artist: artist, duration: duration)
        queue.sync {
            ensureLoaded()
            for key in keys {
                memory[key] = entry
            }
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

    private static func cacheKeys(title: String, artist: String, duration: TimeInterval) -> [String] {
        let nt = MetadataDiskCache.normalize(title)
        let na = MetadataDiskCache.normalize(artist)
        let rounded = Int(duration.rounded())
        return [rounded - 1, rounded, rounded + 1].map { d in
            let raw = "\(nt)|\(na)|\(d)"
            let digest = SHA256.hash(data: Data(raw.utf8))
            return digest.compactMap { String(format: "%02x", $0) }.joined()
        }
    }
}
