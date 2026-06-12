/**
 * [INPUT]: Foundation only — no external deps
 * [OUTPUT]: MetadataDiskCache (persistent JSON cache for resolved metadata,
 *           tier-separated: localized `get/set` + Chinese `getChinese/setChinese`,
 *           debounced persist + `flush()`)
 * [POS]: Utils — disk-backed cache used by MetadataResolver
 *
 * ---------------------------------------------------------------------------
 * On-disk schema (human-readable JSON, version: 6):
 *
 *     {
 *       "version": 6,
 *       "entries": {                       // localized tier (multi-region + album-scoped)
 *         "<sha256-hex-key>": {
 *           "resolved_title": "プラスティック・ラヴ",
 *           "resolved_artist": "竹内まりや",
 *           "region": "jp",
 *           "ts": 1733000000.0,
 *           "source": "metadata-cache-v1",
 *           "duration_diff": 0.42
 *         },
 *         ...
 *       },
 *       "cn_entries": { ... same row shape, region always "CN" ... }
 *     }
 *
 * Tier separation: the CN resolver (`fetchChineseMetadata`) and the localized
 * resolver (`fetchLocalizedMetadata` / album-scoped) cache into DISJOINT
 * dictionaries. The dual-wave pinyin path resolves the SAME `(title, artist,
 * duration)` through BOTH tiers; in a single keyspace each tier's write would
 * overwrite the other's row, so every replay would refire the other tier's
 * full network wave. Separate dictionaries make cross-tier overwrite
 * structurally impossible — each tier replays only rows it produced.
 *
 * `duration_diff` is the REAL measured duration gap (seconds) that admitted
 * the row. Cached claims must carry the evidence that admitted them — replay
 * returns this value so duration-keyed guards (postmortem 006) scrutinize
 * cached rows exactly like fresh results, instead of being bypassed by a
 * fabricated perfect match.
 *
 * Key derivation: SHA256 of "normalized_title|normalized_artist|int_duration".
 * Normalization: lowercase + collapse internal whitespace + strip ASCII punct.
 *
 * Concurrency: all state lives behind one serial queue. persist() is
 * DEBOUNCED — a set marks the state dirty and schedules a single coalesced
 * atomic write (`persistDebounce` seconds later) on the SAME serial queue,
 * so there is no second synchronization domain. `flush()` forces the pending
 * write synchronously; the app calls it from applicationWillTerminate and
 * deinit calls it as a safety net for short-lived instances.
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
    /// Measured duration gap (seconds) that admitted this row at write time.
    /// Optional only for decode tolerance — every writer stores a value.
    /// Replay must return this REAL evidence, never a fabricated 0.
    public let durationDiff: Double?

    enum CodingKeys: String, CodingKey {
        case resolvedTitle  = "resolved_title"
        case resolvedArtist = "resolved_artist"
        case region
        case ts
        case source
        case durationDiff   = "duration_diff"
    }
}

// ============================================================================
// MARK: - Cache File Envelope
// ============================================================================

private struct MetadataCacheFile: Codable {
    let version: Int
    var entries: [String: MetadataCacheEntry]
    /// CN-tier rows. Optional for decode tolerance only — see the tier
    /// separation note in the file header.
    var cnEntries: [String: MetadataCacheEntry]?

    enum CodingKeys: String, CodingKey {
        case version
        case entries
        case cnEntries = "cn_entries"
    }
}

// ============================================================================
// MARK: - MetadataDiskCache
// ============================================================================

public final class MetadataDiskCache {

    /// v7: romanized→CJK corroboration learned Japanese readings (review
    /// #11 — the romaji whitelist is gone). Rows admitted or rejected under
    /// pinyin-only corroboration must flush; the bump invalidates them all
    /// once and the cache self-heals as songs resolve again.
    /// (v6: CN-tier rows split into `cn_entries`, preflightExact removed.)
    public static let schemaVersion = 7
    public static let ttlSeconds: TimeInterval = 30 * 86400  // 30 days

    private let fileURL: URL
    private let persistDebounce: TimeInterval
    private let queue = DispatchQueue(label: "com.yinanli.MusicMiniPlayer.metadata-disk-cache")
    private var memory: [String: MetadataCacheEntry] = [:]     // localized tier
    private var cnMemory: [String: MetadataCacheEntry] = [:]   // CN tier
    private var loaded = false
    private var dirty = false
    private var persistScheduled = false

    #if DEBUG
    /// Test probe: coalesced envelope writes that actually hit the disk.
    /// Compiled out of release builds — zero cost.
    private var diskWriteCount = 0
    public var debugDiskWriteCount: Int { queue.sync { diskWriteCount } }
    #endif

    public init(fileURL: URL, persistDebounce: TimeInterval = 1.0) {
        self.fileURL = fileURL
        self.persistDebounce = persistDebounce
    }

    deinit {
        // Safety net for short-lived instances (tests, tools). The app
        // singleton never deinits — applicationWillTerminate flushes it.
        flush()
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
    // MARK: - Localized Tier API (multi-region + album-scoped rows)
    // ------------------------------------------------------------------------

    public func get(title: String, artist: String, duration: TimeInterval) -> MetadataCacheEntry? {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            return liveEntry(key, in: &memory)
        }
    }

    /// `durationDiff` is mandatory: cached claims must carry the evidence
    /// that admitted them, so the writer is forced to pass the real measured
    /// gap instead of letting replay fabricate one.
    public func set(title: String, artist: String, duration: TimeInterval,
                    resolvedTitle: String, resolvedArtist: String, region: String,
                    durationDiff: Double) {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        let entry = Self.makeEntry(resolvedTitle: resolvedTitle, resolvedArtist: resolvedArtist,
                                   region: region, durationDiff: durationDiff)
        queue.sync {
            ensureLoaded()
            memory[key] = entry
            scheduleDebouncedPersist()
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - CN Tier API (fetchChineseMetadata rows)
    // ------------------------------------------------------------------------

    public func getChinese(title: String, artist: String, duration: TimeInterval) -> MetadataCacheEntry? {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            return liveEntry(key, in: &cnMemory)
        }
    }

    /// CN rows always carry region "CN" — the tier IS the region, so the
    /// writer does not pass one.
    public func setChinese(title: String, artist: String, duration: TimeInterval,
                           resolvedTitle: String, resolvedArtist: String,
                           durationDiff: Double) {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        let entry = Self.makeEntry(resolvedTitle: resolvedTitle, resolvedArtist: resolvedArtist,
                                   region: "CN", durationDiff: durationDiff)
        queue.sync {
            ensureLoaded()
            cnMemory[key] = entry
            scheduleDebouncedPersist()
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - File Introspection
    // ------------------------------------------------------------------------

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

    /// Total row count across BOTH tiers.
    public var entryCount: Int {
        queue.sync {
            ensureLoaded()
            return memory.count + cnMemory.count
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - Loading / Persistence
    // ------------------------------------------------------------------------

    /// Forces the pending debounced write to disk NOW. Called from the app's
    /// applicationWillTerminate and from deinit; safe to call repeatedly —
    /// a clean cache is a no-op.
    public func flush() {
        queue.sync {
            guard dirty else { return }
            persistNow()
        }
    }

    /// TTL-checked read; expired rows are dropped in place.
    /// Must be called inside `queue`.
    private func liveEntry(_ key: String, in store: inout [String: MetadataCacheEntry]) -> MetadataCacheEntry? {
        guard let entry = store[key] else { return nil }
        if Date().timeIntervalSince1970 - entry.ts > Self.ttlSeconds {
            store.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    private static func makeEntry(resolvedTitle: String, resolvedArtist: String,
                                  region: String, durationDiff: Double) -> MetadataCacheEntry {
        MetadataCacheEntry(
            resolvedTitle: resolvedTitle,
            resolvedArtist: resolvedArtist,
            region: region,
            ts: Date().timeIntervalSince1970,
            source: "metadata-cache-v1",
            durationDiff: durationDiff
        )
    }

    /// Must be called inside `queue`.
    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let envelope = try? JSONDecoder().decode(MetadataCacheFile.self, from: data) else { return }
        guard envelope.version == Self.schemaVersion else {
            // Schema mismatch → treat the file as empty, will overwrite on next persist
            return
        }
        memory = envelope.entries
        cnMemory = envelope.cnEntries ?? [:]
    }

    /// Marks the state dirty and arms ONE coalesced write `persistDebounce`
    /// seconds out. Re-entrant sets inside the window ride the armed timer.
    /// Must be called inside `queue`; the timer block also runs on `queue`,
    /// so every flag and dictionary access stays on one serial discipline.
    private func scheduleDebouncedPersist() {
        dirty = true
        if persistScheduled { return }
        persistScheduled = true
        queue.asyncAfter(deadline: .now() + persistDebounce) { [weak self] in
            guard let self = self else { return }
            self.persistScheduled = false
            if self.dirty { self.persistNow() }
        }
    }

    /// Must be called inside `queue`.
    private func persistNow() {
        dirty = false
        #if DEBUG
        diskWriteCount += 1
        #endif
        let envelope = MetadataCacheFile(version: Self.schemaVersion, entries: memory, cnEntries: cnMemory)
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
