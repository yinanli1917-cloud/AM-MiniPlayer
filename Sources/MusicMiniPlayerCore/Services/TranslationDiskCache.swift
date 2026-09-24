/**
 * [INPUT]: Foundation only — no external deps
 * [OUTPUT]: TranslationDiskCache (persistent JSON cache for ML-translated
 *           lyric lines, keyed by song identity + target language + content
 *           fingerprint), debounced persist + `flush()`
 * [POS]: Services — disk-backed cache used by LyricsService's translation
 *        pipeline (task A5, 2026-09). Modelled on Utils/MetadataDiskCache.swift.
 *
 * ---------------------------------------------------------------------------
 * Why a fingerprint, not just a song key: the SAME song key can legitimately
 * carry different lyric content over time (a better source replaces a worse
 * one, an LRC gets corrected upstream). A stale disk row applied on top of
 * NEW lyric lines would silently attach translations to the wrong text. The
 * fingerprint (first-real-line SHA256 + line count, the same identity
 * `LyricsView.lyricsWorkloadIdentity` already computes) must match before a
 * row is trusted; a mismatch is treated as a miss, never as a partial hit.
 *
 * On-disk schema (JSON, version: 1):
 *
 *     {
 *       "version": 1,
 *       "entries": {
 *         "<songKey>|<targetLanguage>": {
 *           "fingerprint": "<sha256-hex>|<lineCount>",
 *           "lines": { "0": "你好", "2": "世界" },   // index -> translated text
 *           "ts": 1733000000.0
 *         }
 *       }
 *     }
 *
 * Concurrency: all state lives behind one serial queue, mirroring
 * MetadataDiskCache. persist() is DEBOUNCED — a write marks the state dirty
 * and schedules one coalesced atomic write; `flush()` forces it synchronously.
 * ---------------------------------------------------------------------------
 */

import Foundation
import CryptoKit

// ============================================================================
// MARK: - Cache Entry
// ============================================================================

public struct TranslationCacheEntry: Codable, Equatable {
    /// "<firstRealLineSHA256>|<lineCount>" — must match the CURRENT lyrics'
    /// fingerprint before this row is trusted. See file header.
    public let fingerprint: String
    /// Line index (as String, for JSON dictionary keys) -> translated text.
    public let lines: [String: String]
    public let ts: TimeInterval

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case lines
        case ts
    }
}

private struct TranslationCacheFile: Codable {
    let version: Int
    var entries: [String: TranslationCacheEntry]
}

// ============================================================================
// MARK: - TranslationDiskCache
// ============================================================================

public final class TranslationDiskCache {

    public static let schemaVersion = 1
    /// Translations are cheap to re-derive but the on-device model call is
    /// not free; keep rows for 30 days, same horizon as MetadataDiskCache's
    /// positive tier.
    public static let ttlSeconds: TimeInterval = 30 * 86400

    private let fileURL: URL
    private let legacySeedURL: URL?
    private let persistDebounce: TimeInterval
    private let queue = DispatchQueue(label: "com.yinanli.MusicMiniPlayer.translation-disk-cache")
    private var memory: [String: TranslationCacheEntry] = [:]
    private var loaded = false
    private var dirty = false
    private var persistScheduled = false

    #if DEBUG
    /// Test probe: coalesced envelope writes that actually hit disk.
    private var diskWriteCount = 0
    public var debugDiskWriteCount: Int { queue.sync { diskWriteCount } }
    #endif

    public init(fileURL: URL, persistDebounce: TimeInterval = 1.0) {
        self.fileURL = fileURL
        self.legacySeedURL = NanoPodCacheLocation.legacySeedURL(for: fileURL, baseName: "translation_cache", schemaVersion: Self.schemaVersion)
        self.persistDebounce = persistDebounce
    }

    deinit {
        // Never hop onto `queue` here: the last release can land INSIDE one of
        // our own queue closures (they promote `[weak self]` to strong), and a
        // queue.sync onto the queue we are already running on traps. No hop is
        // needed either — deinit only runs once no closure holds `self` (weak
        // captures are already nil), so this is the sole accessor of state.
        if dirty { persistNow() }
    }

    /// Default location: NanoPodCacheLocation-scoped directory (production:
    /// ~/Library/Application Support/nanoPod/translation_cache.v<schema>.json;
    /// XCTest/dev/worktree builds isolated elsewhere — see
    /// NanoPodCacheLocation). A same-version pre-versioning
    /// "translation_cache.json" is read once as a seed (never written to).
    public static func defaultURL() -> URL {
        NanoPodCacheLocation.versionedFileURL(baseName: "translation_cache", schemaVersion: schemaVersion)
    }

    // ------------------------------------------------------------------------
    // MARK: - Public API
    // ------------------------------------------------------------------------

    /// Returns persisted translations for (songKey, targetLanguage) ONLY when
    /// the stored fingerprint matches `fingerprint` exactly. A mismatch (or
    /// no row, or expired row) returns nil — never a partial/stale merge.
    public func get(songKey: String, targetLanguage: String, fingerprint: String) -> [Int: String]? {
        let key = Self.cacheKey(songKey: songKey, targetLanguage: targetLanguage)
        return queue.sync {
            ensureLoaded()
            guard let entry = memory[key] else { return nil }
            if Date().timeIntervalSince1970 - entry.ts > Self.ttlSeconds {
                memory.removeValue(forKey: key)
                return nil
            }
            guard entry.fingerprint == fingerprint else { return nil }
            var result: [Int: String] = [:]
            for (indexString, text) in entry.lines {
                if let index = Int(indexString) {
                    result[index] = text
                }
            }
            return result
        }
    }

    /// Merges `lines` (index -> translated text) into the persisted row for
    /// (songKey, targetLanguage, fingerprint). Overwrites any row carrying a
    /// different (stale) fingerprint rather than merging into it.
    public func set(songKey: String, targetLanguage: String, fingerprint: String, lines: [Int: String]) {
        guard !lines.isEmpty else { return }
        let key = Self.cacheKey(songKey: songKey, targetLanguage: targetLanguage)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.ensureLoaded()
            var stored: [String: String]
            if let existing = self.memory[key], existing.fingerprint == fingerprint {
                stored = existing.lines
            } else {
                stored = [:]
            }
            for (index, text) in lines {
                stored[String(index)] = text
            }
            self.memory[key] = TranslationCacheEntry(
                fingerprint: fingerprint,
                lines: stored,
                ts: Date().timeIntervalSince1970
            )
            self.scheduleDebouncedPersist()
        }
    }

    /// Forces the pending debounced write to disk NOW. Safe to call repeatedly.
    public func flush() {
        queue.sync {
            guard dirty else { return }
            persistNow()
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - Internals
    // ------------------------------------------------------------------------

    /// Must be called inside `queue`.
    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        var data = try? Data(contentsOf: fileURL)
        if data == nil, let legacySeedURL {
            data = try? Data(contentsOf: legacySeedURL)
        }
        guard let data else { return }
        guard let envelope = try? JSONDecoder().decode(TranslationCacheFile.self, from: data) else { return }
        guard envelope.version == Self.schemaVersion else { return }
        memory = envelope.entries
    }

    /// Must be called inside `queue`.
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
        let envelope = TranslationCacheFile(version: Self.schemaVersion, entries: memory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    public static func cacheKey(songKey: String, targetLanguage: String) -> String {
        let raw = "\(songKey)|\(targetLanguage)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Content fingerprint: must match `LyricsView.lyricsWorkloadIdentity`'s
    /// `firstRealLineSHA256` derivation for callers to share identity.
    public static func fingerprint(firstRealLineSHA256: String?, lineCount: Int) -> String {
        "\(firstRealLineSHA256 ?? "")|\(lineCount)"
    }
}
