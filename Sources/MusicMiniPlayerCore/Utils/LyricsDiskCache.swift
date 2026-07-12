/**
 * [INPUT]: Foundation + CryptoKit
 * [OUTPUT]: LyricsDiskCache (persistent JSON cache for verified synced lyrics)
 * [POS]: Utils — keeps slow-but-correct synced source results off the interactive path; schema version invalidates rows when identity gates change
 */

import Foundation
import CryptoKit

#if DEBUG
// Developer/verifier-only cache isolation. The release app product does not
// compile these types or the network-only string into MusicMiniPlayerCore.
public enum LyricsCacheStore: String, Codable, Sendable {
    case lyrics
    case metadata
}

extension LyricsDiskCache {
    public func get(title: String, artist: String, duration: TimeInterval, album: String = "", policy: LyricsCachePolicy) -> LyricsDiskCacheEntry? {
        LyricsCachePolicyContext.$current.withValue(policy) {
            get(title: title, artist: artist, duration: duration, album: album)
        }
    }

    public func candidates(title: String, artist: String, duration: TimeInterval, album: String = "", policy: LyricsCachePolicy) -> [LyricsDiskCacheEntry] {
        LyricsCachePolicyContext.$current.withValue(policy) {
            candidates(title: title, artist: artist, duration: duration, album: album)
        }
    }

    public func set(title: String, artist: String, duration: TimeInterval, album: String = "", source: String, syncedLyrics: String, matchedDurationDiff: TimeInterval?, policy: LyricsCachePolicy) {
        LyricsCachePolicyContext.$current.withValue(policy) {
            set(title: title, artist: artist, duration: duration, album: album, source: source, syncedLyrics: syncedLyrics, matchedDurationDiff: matchedDurationDiff)
        }
    }

    public func set(title: String, artist: String, duration: TimeInterval, album: String = "", source: String, lines: [LyricLine], matchedDurationDiff: TimeInterval?, policy: LyricsCachePolicy) {
        LyricsCachePolicyContext.$current.withValue(policy) {
            set(title: title, artist: artist, duration: duration, album: album, source: source, lines: lines, matchedDurationDiff: matchedDurationDiff)
        }
    }

    public func setAvailability(title: String, artist: String, duration: TimeInterval, album: String = "", source: String, kind: LyricsKind, lines: [LyricLine], matchedDurationDiff: TimeInterval?, policy: LyricsCachePolicy) {
        LyricsCachePolicyContext.$current.withValue(policy) {
            setAvailability(title: title, artist: artist, duration: duration, album: album, source: source, kind: kind, lines: lines, matchedDurationDiff: matchedDurationDiff)
        }
    }
}

public enum LyricsCacheMode: String, Codable, Sendable {
    case normal
    case networkOnly = "network-only"
}

public struct LyricsCacheDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let mode: LyricsCacheMode
    public let lyricReads: Int
    public let lyricReadBypasses: Int
    public let lyricWrites: Int
    public let lyricWriteBypasses: Int
    public let metadataReads: Int
    public let metadataReadBypasses: Int
    public let metadataWrites: Int
    public let metadataWriteBypasses: Int
}

public final class LyricsCacheDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (lyricReads: 0, lyricReadBypasses: 0, lyricWrites: 0, lyricWriteBypasses: 0,
                          metadataReads: 0, metadataReadBypasses: 0, metadataWrites: 0, metadataWriteBypasses: 0)

    public init() {}

    fileprivate func recordRead(_ store: LyricsCacheStore, bypassed: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch (store, bypassed) {
        case (.lyrics, false): counts.lyricReads += 1
        case (.lyrics, true): counts.lyricReadBypasses += 1
        case (.metadata, false): counts.metadataReads += 1
        case (.metadata, true): counts.metadataReadBypasses += 1
        }
    }

    fileprivate func recordWrite(_ store: LyricsCacheStore, bypassed: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch (store, bypassed) {
        case (.lyrics, false): counts.lyricWrites += 1
        case (.lyrics, true): counts.lyricWriteBypasses += 1
        case (.metadata, false): counts.metadataWrites += 1
        case (.metadata, true): counts.metadataWriteBypasses += 1
        }
    }

    public func snapshot(mode: LyricsCacheMode) -> LyricsCacheDiagnosticsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return LyricsCacheDiagnosticsSnapshot(
            mode: mode,
            lyricReads: counts.lyricReads,
            lyricReadBypasses: counts.lyricReadBypasses,
            lyricWrites: counts.lyricWrites,
            lyricWriteBypasses: counts.lyricWriteBypasses,
            metadataReads: counts.metadataReads,
            metadataReadBypasses: counts.metadataReadBypasses,
            metadataWrites: counts.metadataWrites,
            metadataWriteBypasses: counts.metadataWriteBypasses
        )
    }
}

public struct LyricsCachePolicy: Sendable {
    public let mode: LyricsCacheMode
    public let diagnostics: LyricsCacheDiagnostics?

    public init(mode: LyricsCacheMode = .normal, diagnostics: LyricsCacheDiagnostics? = nil) {
        self.mode = mode
        self.diagnostics = diagnostics
    }

    public static let normal = LyricsCachePolicy()

    public static func networkOnly(diagnostics: LyricsCacheDiagnostics? = nil) -> LyricsCachePolicy {
        LyricsCachePolicy(mode: .networkOnly, diagnostics: diagnostics)
    }

    public var allowsReads: Bool { mode == .normal }
    public var allowsWrites: Bool { mode == .normal }
}

public enum LyricsCachePolicyContext {
    @TaskLocal public static var current = LyricsCachePolicy.normal
}

extension LyricsCachePolicy {
    func recordRead(_ store: LyricsCacheStore, bypassed: Bool) {
        diagnostics?.recordRead(store, bypassed: bypassed)
    }

    func recordWrite(_ store: LyricsCacheStore, bypassed: Bool) {
        diagnostics?.recordWrite(store, bypassed: bypassed)
    }
}
#endif

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
    // 30: provider-level unavailable markers are retryable evidence, not
    // durable no-lyrics verdicts. Invalidate schema 29 rows that could force
    // a false miss until manual refresh.
    public static let schemaVersion = 30
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
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsReads else {
            effectivePolicy.recordRead(.lyrics, bypassed: true)
            return []
        }
        effectivePolicy.recordRead(.lyrics, bypassed: false)
        #endif
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
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else {
            effectivePolicy.recordWrite(.lyrics, bypassed: true)
            return
        }
        effectivePolicy.recordWrite(.lyrics, bypassed: false)
        #endif
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
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else {
            effectivePolicy.recordWrite(.lyrics, bypassed: true)
            return
        }
        effectivePolicy.recordWrite(.lyrics, bypassed: false)
        #endif
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
        guard kind == .instrumental else { return }
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else {
            effectivePolicy.recordWrite(.lyrics, bypassed: true)
            return
        }
        effectivePolicy.recordWrite(.lyrics, bypassed: false)
        #endif
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
