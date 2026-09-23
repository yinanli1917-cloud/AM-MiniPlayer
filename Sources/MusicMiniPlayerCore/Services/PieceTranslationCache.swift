/**
 * [INPUT]: Foundation only.
 * [OUTPUT]: Exports PieceTranslationCache -- a thread-safe, IN-MEMORY-ONLY
 *           (never persisted to disk, unlike the whole-line translation disk
 *           cache) map of (piece text, source language code, target language
 *           code) -> translated text.
 * [POS]: Services -- read synchronously by LyricsView.makeDisplayLyricLines
 *        (LyricPieceTranslation's tier 2) and written by
 *        LyricsService.performPendingPieceTranslations after an async
 *        per-piece on-device translation pass. A width-driven re-split that
 *        reproduces the same piece text reuses the cached translation
 *        instead of re-issuing a Translation-framework request.
 *
 * In-memory only is a deliberate choice, not an oversight: split pieces are
 * re-derived every session from the current window width (Plan A,
 * 2026-09-22), so there is nothing stable to key a disk entry on across app
 * launches, and pieces are cheap enough to re-translate once per song.
 */

import Foundation

public final class PieceTranslationCache {
    public static let shared = PieceTranslationCache()

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    private static func key(text: String, source: String, target: String) -> String {
        "\(source)|\(target)|\(text)"
    }

    public func translation(for text: String, source: String, target: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[Self.key(text: text, source: source, target: target)]
    }

    public func store(_ translation: String, for text: String, source: String, target: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[Self.key(text: text, source: source, target: target)] = translation
    }

    #if DEBUG
    public func debugReset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    public var debugCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
    #endif
}
