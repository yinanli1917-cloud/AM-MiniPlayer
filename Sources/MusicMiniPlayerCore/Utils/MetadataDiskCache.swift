/**
 * [INPUT]: Foundation only — no external deps
 * [OUTPUT]: MetadataDiskCache (persistent JSON cache for resolved metadata)
 * [POS]: Utils — disk-backed cache used by MetadataResolver / LyricsPrewarmer
 *
 * ---------------------------------------------------------------------------
 * On-disk schema (human-readable JSON, version: 1):
 *
 *     {
 *       "version": 1,
 *       "entries": {
 *         "<sha256-hex-key>": {
 *           "resolved_title": "プラスティック・ラヴ",
 *           "resolved_artist": "竹内まりや",
 *           "region": "jp",
 *           "ts": 1733000000.0,
 *           "source": "metadata-cache-v1"
 *         },
 *         ...
 *       }
 *     }
 *
 * Key derivation: SHA256 of "normalized_title|normalized_artist|int_duration".
 * Normalization: lowercase + collapse internal whitespace + strip ASCII punct.
 *
 * Concurrency: all reads and writes happen on a single serial queue. The
 * on-disk file is updated atomically (write to a sibling temp file then
 * `rename(2)`). This file targets <250 lines per the project rule.
 * ---------------------------------------------------------------------------
 */

import Foundation
import CryptoKit

// ============================================================================
// MARK: - Cache Entry
// ============================================================================

public struct MetadataCacheEntry: Codable, Equatable {
    public let resolvedTitle: String
    public let resolvedArtist: String
    public let region: String
    public let ts: TimeInterval
    public let source: String

    enum CodingKeys: String, CodingKey {
        case resolvedTitle  = "resolved_title"
        case resolvedArtist = "resolved_artist"
        case region
        case ts
        case source
    }
}

// ============================================================================
// MARK: - Cache File Envelope
// ============================================================================

private struct MetadataCacheFile: Codable {
    let version: Int
    var entries: [String: MetadataCacheEntry]
    /// Preflight exact-original-match flags: true means iTunes confirmed the
    /// ORIGINAL `(title, artist, ~duration)` as a direct match in some region.
    /// Keyed the same way as `entries`. Stored separately so the schema
    /// stays minimal — entries only carry resolved metadata.
    var preflightExact: [String: PreflightEntry]?
}

public struct PreflightEntry: Codable, Equatable {
    public let isExact: Bool
    public let ts: TimeInterval
}

// ============================================================================
// MARK: - MetadataDiskCache
// ============================================================================

public final class MetadataDiskCache {

    public static let schemaVersion = 1
    public static let ttlSeconds: TimeInterval = 30 * 86400  // 30 days

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.yinanli.MusicMiniPlayer.metadata-disk-cache")
    private var memory: [String: MetadataCacheEntry] = [:]
    private var preflight: [String: PreflightEntry] = [:]
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location: ~/Library/Application Support/nanoPod/metadata_cache.json
    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("nanoPod", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata_cache.json")
    }

    // ------------------------------------------------------------------------
    // MARK: - Public API
    // ------------------------------------------------------------------------

    public func get(title: String, artist: String, duration: TimeInterval) -> MetadataCacheEntry? {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            guard let entry = memory[key] else { return nil }
            if Date().timeIntervalSince1970 - entry.ts > Self.ttlSeconds {
                memory.removeValue(forKey: key)
                return nil
            }
            return entry
        }
    }

    public func set(title: String, artist: String, duration: TimeInterval,
                    resolvedTitle: String, resolvedArtist: String, region: String) {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        let entry = MetadataCacheEntry(
            resolvedTitle: resolvedTitle,
            resolvedArtist: resolvedArtist,
            region: region,
            ts: Date().timeIntervalSince1970,
            source: "metadata-cache-v1"
        )
        queue.sync {
            ensureLoaded()
            memory[key] = entry
            persist()
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - Preflight Cache API
    // ------------------------------------------------------------------------

    /// Returns the cached preflight exact-match flag, or nil if not cached
    /// or expired. Preflight flags use the same TTL as metadata entries.
    public func getPreflightExact(title: String, artist: String, duration: TimeInterval) -> Bool? {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            guard let entry = preflight[key] else { return nil }
            if Date().timeIntervalSince1970 - entry.ts > Self.ttlSeconds {
                preflight.removeValue(forKey: key)
                return nil
            }
            return entry.isExact
        }
    }

    public func setPreflightExact(title: String, artist: String, duration: TimeInterval, isExact: Bool) {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        let entry = PreflightEntry(isExact: isExact, ts: Date().timeIntervalSince1970)
        queue.sync {
            ensureLoaded()
            preflight[key] = entry
            persist()
        }
    }

    /// `mtime` of the on-disk cache file (or nil if not yet written).
    public func fileModificationDate() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.modificationDate] as? Date
    }

    /// File size in bytes (0 if file does not exist).
    public func fileSizeBytes() -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attrs?[.size] as? Int) ?? 0
    }

    public var entryCount: Int {
        queue.sync {
            ensureLoaded()
            return memory.count
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - Loading / Persistence (must be called inside queue)
    // ------------------------------------------------------------------------

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let envelope = try? JSONDecoder().decode(MetadataCacheFile.self, from: data) else { return }
        guard envelope.version == Self.schemaVersion else {
            // Schema mismatch → treat the file as empty, will overwrite on next set()
            return
        }
        memory = envelope.entries
        preflight = envelope.preflightExact ?? [:]
    }

    private func persist() {
        let envelope = MetadataCacheFile(version: Self.schemaVersion, entries: memory, preflightExact: preflight)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return }

        // Atomic write: temp + rename. Foundation's Data.write(.atomic) does
        // exactly this; we reaffirm it for clarity.
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Parent directory may not exist yet — try to create it once.
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - Key Derivation
    // ------------------------------------------------------------------------

    public static func cacheKey(title: String, artist: String, duration: TimeInterval) -> String {
        let nt = normalize(title)
        let na = normalize(artist)
        let raw = "\(nt)|\(na)|\(Int(duration))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Lowercase + collapse internal whitespace + drop ASCII punctuation.
    /// Mirrors LanguageUtils.normalizeArtistName for ASCII inputs but keeps
    /// non-ASCII (CJK) characters untouched.
    public static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        var lastWasSpace = false
        for ch in lowered {
            if ch.isWhitespace {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            // Strip ASCII punctuation only — preserve CJK characters and digits
            if ch.isASCII && ch.isPunctuation {
                continue
            }
            out.append(ch)
            lastWasSpace = false
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
