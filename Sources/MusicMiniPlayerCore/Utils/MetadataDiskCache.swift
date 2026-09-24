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
 * write synchronously; the app calls it from applicationWillTerminate. deinit
 * persists a dirty state directly (no queue hop) as a safety net for
 * short-lived instances.
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
    /// Admission-evidence kind for localized rows ("exact-title" / "phonetic"
    /// / "catalog-alias"). Stamped rows replay without re-deriving script
    /// heuristics; nil (CN tier, decode tolerance) stays heuristic-gated.
    public let evidence: String?

    enum CodingKeys: String, CodingKey {
        case resolvedTitle  = "resolved_title"
        case resolvedArtist = "resolved_artist"
        case region
        case ts
        case source
        case durationDiff   = "duration_diff"
        case evidence
    }
}

#if DEBUG
extension MetadataDiskCache {
    public func get(title: String, artist: String, duration: TimeInterval, policy: LyricsCachePolicy) -> MetadataCacheEntry? {
        LyricsCachePolicyContext.$current.withValue(policy) {
            get(title: title, artist: artist, duration: duration)
        }
    }

    public func set(title: String, artist: String, duration: TimeInterval,
                    resolvedTitle: String, resolvedArtist: String, region: String,
                    durationDiff: Double, policy: LyricsCachePolicy) {
        LyricsCachePolicyContext.$current.withValue(policy) {
            set(title: title, artist: artist, duration: duration,
                resolvedTitle: resolvedTitle, resolvedArtist: resolvedArtist,
                region: region, durationDiff: durationDiff)
        }
    }

    public func getChinese(title: String, artist: String, duration: TimeInterval, policy: LyricsCachePolicy) -> MetadataCacheEntry? {
        LyricsCachePolicyContext.$current.withValue(policy) {
            getChinese(title: title, artist: artist, duration: duration)
        }
    }

    public func setChinese(title: String, artist: String, duration: TimeInterval,
                           resolvedTitle: String, resolvedArtist: String,
                           durationDiff: Double, policy: LyricsCachePolicy) {
        LyricsCachePolicyContext.$current.withValue(policy) {
            setChinese(title: title, artist: artist, duration: duration,
                       resolvedTitle: resolvedTitle, resolvedArtist: resolvedArtist,
                       durationDiff: durationDiff)
        }
    }
}
#endif

// ============================================================================
// MARK: - Cache File Envelope
// ============================================================================

/// Negative-evidence row: "this exact (title, artist, duration[, album]) query
/// came back empty" — no resolved title/artist to carry, just a timestamp for
/// TTL expiry. Shields repeat cold starts from re-running a search that is
/// already known to be fruitless (A2: negative-evidence cache).
public struct MetadataNegativeEntry: Codable, Equatable {
    public let ts: TimeInterval

    enum CodingKeys: String, CodingKey {
        case ts
    }
}

private struct MetadataCacheFile: Codable {
    let version: Int
    var entries: [String: MetadataCacheEntry]
    /// CN-tier rows. Optional for decode tolerance only — see the tier
    /// separation note in the file header.
    var cnEntries: [String: MetadataCacheEntry]?
    /// Negative-evidence rows, one dictionary per tier. Optional for decode
    /// tolerance — files written before v9 simply have none.
    var negativeEntries: [String: MetadataNegativeEntry]?
    var negativeCnEntries: [String: MetadataNegativeEntry]?
    var negativeAlbumEntries: [String: MetadataNegativeEntry]?

    enum CodingKeys: String, CodingKey {
        case version
        case entries
        case cnEntries = "cn_entries"
        case negativeEntries = "negative_entries"
        case negativeCnEntries = "negative_cn_entries"
        case negativeAlbumEntries = "negative_album_entries"
    }
}

// ============================================================================
// MARK: - MetadataDiskCache
// ============================================================================

public final class MetadataDiskCache {

    /// v9: adds negative-evidence rows (one dictionary per tier — localized,
    /// CN, album-scoped) so a confirmed-empty query is not re-run on every
    /// cold start (A2). Positive resolutions always overwrite a negative row
    /// for the same key.
    /// v8: localized rows carry the admission-evidence kind (`evidence`),
    /// and the romanized→CJK tier accepts Apple-index catalog aliases
    /// (title-query consensus). Rows written under uniqueness-fallback or
    /// heuristic-only admission must flush once; the cache self-heals.
    /// (v7: Japanese-reading corroboration replaced the romaji whitelist.
    ///  v6: CN-tier rows split into `cn_entries`, preflightExact removed.)
    public static let schemaVersion = 9
    public static let ttlSeconds: TimeInterval = 30 * 86400  // 30 days
    /// TTL for negative-evidence rows — matches the lyrics availability
    /// "verdict" TTL (24h) used elsewhere in the lyrics pipeline
    /// (CachedLyricsItem's non-"no lyrics" expiry, LyricsFetcher's 24h
    /// availability-verdict cache). Shorter than the 30-day positive TTL:
    /// an empty metadata search is much cheaper to re-check than a full
    /// lyrics fetch, and catalogs change more often than song identity.
    public static let negativeTTLSeconds: TimeInterval = 86400  // 24h

    private let fileURL: URL
    private let legacySeedURL: URL?
    private let persistDebounce: TimeInterval
    private let queue = DispatchQueue(label: "com.yinanli.MusicMiniPlayer.metadata-disk-cache")
    private var memory: [String: MetadataCacheEntry] = [:]     // localized tier
    private var cnMemory: [String: MetadataCacheEntry] = [:]   // CN tier
    private var negativeMemory: [String: MetadataNegativeEntry] = [:]        // localized tier negatives
    private var negativeCnMemory: [String: MetadataNegativeEntry] = [:]      // CN tier negatives
    private var negativeAlbumMemory: [String: MetadataNegativeEntry] = [:]   // album-scoped tier negatives
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
        self.legacySeedURL = NanoPodCacheLocation.legacySeedURL(for: fileURL, baseName: "metadata_cache", schemaVersion: Self.schemaVersion)
        self.persistDebounce = persistDebounce
    }

    deinit {
        // Safety net for short-lived instances (tests, tools). The app
        // singleton never deinits — applicationWillTerminate flushes it.
        // Never hop onto `queue` here: the last release can land INSIDE one of
        // our own queue closures (they promote `[weak self]` to strong), and a
        // queue.sync onto the queue we are already running on traps. No hop is
        // needed either — deinit only runs once no closure holds `self` (weak
        // captures are already nil), so this is the sole accessor of state.
        if dirty { persistNow() }
    }

    /// Default location: NanoPodCacheLocation-scoped directory (production:
    /// ~/Library/Application Support/nanoPod/metadata_cache.v<schema>.json;
    /// XCTest/dev/worktree builds isolated elsewhere — see
    /// NanoPodCacheLocation). A same-version pre-versioning
    /// "metadata_cache.json" is read once as a seed (never written to).
    public static func defaultURL() -> URL {
        NanoPodCacheLocation.versionedFileURL(baseName: "metadata_cache", schemaVersion: schemaVersion)
    }

    // ------------------------------------------------------------------------
    // MARK: - Localized Tier API (multi-region + album-scoped rows)
    // ------------------------------------------------------------------------

    public func get(title: String, artist: String, duration: TimeInterval) -> MetadataCacheEntry? {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsReads else {
            effectivePolicy.recordRead(.metadata, bypassed: true)
            return nil
        }
        effectivePolicy.recordRead(.metadata, bypassed: false)
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            return liveEntry(key, in: &memory)
        }
    }

    /// `durationDiff` is mandatory: cached claims must carry the evidence
    /// that admitted them, so the writer is forced to pass the real measured
    /// gap instead of letting replay fabricate one. `evidence` stamps the
    /// admission kind; unstamped rows stay heuristic-gated at replay.
    public func set(title: String, artist: String, duration: TimeInterval,
                    resolvedTitle: String, resolvedArtist: String, region: String,
                    durationDiff: Double, evidence: String? = nil) {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else {
            effectivePolicy.recordWrite(.metadata, bypassed: true)
            return
        }
        effectivePolicy.recordWrite(.metadata, bypassed: false)
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        let entry = Self.makeEntry(resolvedTitle: resolvedTitle, resolvedArtist: resolvedArtist,
                                   region: region, durationDiff: durationDiff, evidence: evidence)
        queue.sync {
            ensureLoaded()
            memory[key] = entry
            // Positive resolutions always overwrite a stale negative row.
            negativeMemory.removeValue(forKey: key)
            scheduleDebouncedPersist()
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - Negative-Evidence API (A2)
    // ------------------------------------------------------------------------
    //
    // One dictionary per tier, mirroring the positive tiers' key derivation
    // exactly so a negative row shields precisely the query it was learned
    // from. A hit within `negativeTTLSeconds` means "skip the network,
    // this exact query is already known to be fruitless." Cancellation must
    // never write a negative row — only a completed, quorum-trustworthy
    // empty result does (call sites decide that; this cache only stores).

    /// Localized-tier negative check.
    public func getNegative(title: String, artist: String, duration: TimeInterval) -> Bool {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsReads else { return false }
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            return liveNegative(key, in: &negativeMemory)
        }
    }

    public func setNegative(title: String, artist: String, duration: TimeInterval) {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else { return }
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        queue.sync {
            ensureLoaded()
            // Never shadow a positive row that already answers this query.
            guard memory[key] == nil else { return }
            negativeMemory[key] = MetadataNegativeEntry(ts: Date().timeIntervalSince1970)
            scheduleDebouncedPersist()
        }
    }

    /// Positive localized resolutions overwrite a stale negative row via
    /// `set(...)`; this clears it directly (no positive row available yet),
    /// e.g. a user-initiated retry that must not be short-circuited by a
    /// negative row within its 24h TTL.
    public func clearNegative(title: String, artist: String, duration: TimeInterval) {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        queue.sync {
            ensureLoaded()
            negativeMemory.removeValue(forKey: key)
        }
    }

    /// CN-tier negative check.
    public func getNegativeChinese(title: String, artist: String, duration: TimeInterval) -> Bool {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsReads else { return false }
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        return queue.sync {
            ensureLoaded()
            return liveNegative(key, in: &negativeCnMemory)
        }
    }

    public func setNegativeChinese(title: String, artist: String, duration: TimeInterval) {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else { return }
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        queue.sync {
            ensureLoaded()
            guard cnMemory[key] == nil else { return }
            negativeCnMemory[key] = MetadataNegativeEntry(ts: Date().timeIntervalSince1970)
            scheduleDebouncedPersist()
        }
    }

    /// Clears a CN-tier negative row directly (mirrors `clearNegative`).
    public func clearNegativeChinese(title: String, artist: String, duration: TimeInterval) {
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        queue.sync {
            ensureLoaded()
            negativeCnMemory.removeValue(forKey: key)
        }
    }

    /// Album-scoped-tier negative check. Keyed like the album-scoped
    /// single-flight key (title|artist|duration|album) — distinct from the
    /// localized tier's key, since an album-scoped miss says nothing about
    /// a plain title/artist/duration lookup and vice versa.
    public func getNegativeAlbumScoped(title: String, artist: String, duration: TimeInterval, album: String) -> Bool {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsReads else { return false }
        #endif
        let key = Self.albumScopedCacheKey(title: title, artist: artist, duration: duration, album: album)
        return queue.sync {
            ensureLoaded()
            return liveNegative(key, in: &negativeAlbumMemory)
        }
    }

    /// Positive album-scoped resolutions overwrite a stale negative row.
    public func clearNegativeAlbumScoped(title: String, artist: String, duration: TimeInterval, album: String) {
        let key = Self.albumScopedCacheKey(title: title, artist: artist, duration: duration, album: album)
        queue.sync {
            ensureLoaded()
            negativeAlbumMemory.removeValue(forKey: key)
        }
    }

    public func setNegativeAlbumScoped(title: String, artist: String, duration: TimeInterval, album: String) {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else { return }
        #endif
        let key = Self.albumScopedCacheKey(title: title, artist: artist, duration: duration, album: album)
        queue.sync {
            ensureLoaded()
            negativeAlbumMemory[key] = MetadataNegativeEntry(ts: Date().timeIntervalSince1970)
            scheduleDebouncedPersist()
        }
    }

    /// TTL-checked negative read; expired rows are dropped in place.
    /// Must be called inside `queue`.
    private func liveNegative(_ key: String, in store: inout [String: MetadataNegativeEntry]) -> Bool {
        guard let entry = store[key] else { return false }
        if Date().timeIntervalSince1970 - entry.ts > Self.negativeTTLSeconds {
            store.removeValue(forKey: key)
            return false
        }
        return true
    }

    /// Clears negative rows across ALL tiers for a song's keys: localized,
    /// CN, and (when `album` is non-empty) album-scoped. Used by the retry
    /// (forceRefresh) path so a metadata miss recorded within the 24h TTL
    /// never short-circuits a user-initiated re-fetch (commit 6cef712 added
    /// the negative-evidence rows; retry only cleared LyricsMissMemo, not
    /// these).
    public func clearNegatives(title: String, artist: String, duration: TimeInterval, album: String) {
        clearNegative(title: title, artist: artist, duration: duration)
        clearNegativeChinese(title: title, artist: artist, duration: duration)
        if !album.isEmpty {
            clearNegativeAlbumScoped(title: title, artist: artist, duration: duration, album: album)
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - CN Tier API (fetchChineseMetadata rows)
    // ------------------------------------------------------------------------

    public func getChinese(title: String, artist: String, duration: TimeInterval) -> MetadataCacheEntry? {
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsReads else {
            effectivePolicy.recordRead(.metadata, bypassed: true)
            return nil
        }
        effectivePolicy.recordRead(.metadata, bypassed: false)
        #endif
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
        #if DEBUG
        let effectivePolicy = LyricsCachePolicyContext.current
        guard effectivePolicy.allowsWrites else {
            effectivePolicy.recordWrite(.metadata, bypassed: true)
            return
        }
        effectivePolicy.recordWrite(.metadata, bypassed: false)
        #endif
        let key = Self.cacheKey(title: title, artist: artist, duration: duration)
        let entry = Self.makeEntry(resolvedTitle: resolvedTitle, resolvedArtist: resolvedArtist,
                                   region: "CN", durationDiff: durationDiff)
        queue.sync {
            ensureLoaded()
            cnMemory[key] = entry
            negativeCnMemory.removeValue(forKey: key)
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
    /// applicationWillTerminate; safe to call repeatedly —
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
                                  region: String, durationDiff: Double,
                                  evidence: String? = nil) -> MetadataCacheEntry {
        MetadataCacheEntry(
            resolvedTitle: resolvedTitle,
            resolvedArtist: resolvedArtist,
            region: region,
            ts: Date().timeIntervalSince1970,
            source: "metadata-cache-v1",
            durationDiff: durationDiff,
            evidence: evidence
        )
    }

    /// Must be called inside `queue`.
    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        var data = try? Data(contentsOf: fileURL)
        if data == nil, let legacySeedURL {
            data = try? Data(contentsOf: legacySeedURL)
        }
        guard let data else { return }
        guard let envelope = try? JSONDecoder().decode(MetadataCacheFile.self, from: data) else { return }
        guard envelope.version == Self.schemaVersion else {
            // Schema mismatch → treat as empty. Only reachable via an injected
            // path or a legacy seed; persist writes this version's own file,
            // so another schema's file is never overwritten.
            return
        }
        memory = envelope.entries
        cnMemory = envelope.cnEntries ?? [:]
        negativeMemory = envelope.negativeEntries ?? [:]
        negativeCnMemory = envelope.negativeCnEntries ?? [:]
        negativeAlbumMemory = envelope.negativeAlbumEntries ?? [:]
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

    /// Must be called inside `queue` (or from deinit, which is exclusive).
    private func persistNow() {
        dirty = false
        #if DEBUG
        diskWriteCount += 1
        #endif
        let envelope = MetadataCacheFile(
            version: Self.schemaVersion,
            entries: memory,
            cnEntries: cnMemory,
            negativeEntries: negativeMemory,
            negativeCnEntries: negativeCnMemory,
            negativeAlbumEntries: negativeAlbumMemory
        )
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

    /// Album-scoped negative-tier key — same idiom as `cacheKey` plus the
    /// normalized album, mirroring `MetadataResolver.singleFlightKey`'s
    /// album-aware form so the negative row shields exactly the query it
    /// was learned from.
    public static func albumScopedCacheKey(title: String, artist: String, duration: TimeInterval, album: String) -> String {
        let nt = normalize(title)
        let na = normalize(artist)
        let nAlbum = normalize(album)
        let raw = "\(nt)|\(na)|\(Int(duration))|\(nAlbum)"
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
