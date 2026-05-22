import Foundation
import AppKit
import Compression
import SQLite3

enum PlaybackSessionArtworkFetcher {
    private static let maxArchives = 8
    private static let fileQueue = DispatchQueue(
        label: "com.nanopod.playback-session-artwork",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let urlCacheLock = NSLock()
    private static let urlCacheTTL: TimeInterval = 10 * 60
    private static var urlCache: [String: (timestamp: Date, url: URL)] = [:]

    static func fetchArtwork(title: String, artist: String, album: String) async -> NSImage? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Music/PlaybackSessions")
        guard let url = await latestArtworkURLPolling(
            title: title,
            artist: artist,
            album: album,
            root: root,
            retryFor: 1.2,
            pollInterval: 0.08
        ) else {
            DebugLogger.log("Artwork", "🎨 [PlaybackSession] no matching artwork URL for '\(title)' by '\(artist)'")
            return nil
        }
        DebugLogger.log("Artwork", "🎨 [PlaybackSession] Music UI artwork URL hit: \(url.absoluteString)")
        guard !Task.isCancelled else { return nil }
        do {
            let (data, _) = try await HTTPClient.getData(url: url, timeout: 0.9, retry: false)
            DebugLogger.log("Artwork", "🎨 [PlaybackSession] original Music artwork: \(url.absoluteString)")
            return NSImage(data: data)
        } catch {
            DebugLogger.log("Artwork", "🎨 [PlaybackSession] original Music artwork failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func latestArtworkURL(title: String, artist: String, album: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Music/PlaybackSessions")
        return latestArtworkURL(title: title, artist: artist, album: album, root: root)
    }

    static func latestArtworkURLPolling(
        title: String,
        artist: String,
        album: String,
        root: URL,
        retryFor: TimeInterval,
        pollInterval: TimeInterval
    ) async -> URL? {
        let deadline = Date().addingTimeInterval(max(0, retryFor))
        let interval = max(0.02, pollInterval)

        while !Task.isCancelled {
            if let url = await latestArtworkURLOnFileQueue(title: title, artist: artist, album: album, root: root) {
                return url
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            let sleepSeconds = min(interval, remaining)
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
        }
        return nil
    }

    private static func latestArtworkURLOnFileQueue(title: String, artist: String, album: String, root: URL) async -> URL? {
        return await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume(returning: latestArtworkURL(title: title, artist: artist, album: album, root: root))
            }
        }
    }

    static func latestArtworkURL(title: String, artist: String, album: String, root: URL) -> URL? {
        let key = urlCacheKey(title: title, artist: artist, album: album, root: root)
        if let cached = cachedURL(for: key) {
            return cached
        }

        guard let archives = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sorted = archives
            .filter { $0.pathExtension == "playbackSessionArchive" }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
            .prefix(maxArchives)

        for archive in sorted {
            let candidates = [
                archive.appendingPathComponent("contentItem.protobuf.gz"),
                archive.appendingPathComponent("itemPayload.opackCoder.gz")
            ]
            for file in candidates {
                guard let text = decompressedText(at: file),
                      textMatches(text, title: title, artist: artist, album: album),
                      let url = firstAppleArtworkURL(in: text) else { continue }
                storeCachedURL(url, for: key)
                return url
            }
        }
        return nil
    }

    private static func cachedArtworkDataOnFileQueue(for artworkURL: URL) async -> Data? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.Music/MusicUIArtworkCache")
        return await withCheckedContinuation { continuation in
            fileQueue.async {
                continuation.resume(returning: cachedArtworkData(for: artworkURL, cacheRoot: root))
            }
        }
    }

    private static func urlCacheKey(title: String, artist: String, album: String, root: URL) -> String {
        [
            root.path,
            normalize(title),
            normalize(artist),
            normalize(album)
        ].joined(separator: "|")
    }

    private static func cachedURL(for key: String) -> URL? {
        urlCacheLock.lock()
        defer { urlCacheLock.unlock() }
        guard let cached = urlCache[key] else { return nil }
        guard Date().timeIntervalSince(cached.timestamp) <= urlCacheTTL else {
            urlCache.removeValue(forKey: key)
            return nil
        }
        return cached.url
    }

    private static func storeCachedURL(_ url: URL, for key: String) {
        urlCacheLock.lock()
        urlCache[key] = (Date(), url)
        if urlCache.count > 128 {
            let sorted = urlCache.sorted { $0.value.timestamp < $1.value.timestamp }
            for (oldKey, _) in sorted.prefix(urlCache.count - 96) {
                urlCache.removeValue(forKey: oldKey)
            }
        }
        urlCacheLock.unlock()
    }

    private static func decompressedText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let inflated = gunzip(data) else { return nil }
        return String(decoding: inflated, as: UTF8.self)
    }

    static func textMatches(_ text: String, title: String, artist: String, album: String) -> Bool {
        guard textContainsPlaybackField(text, title) else { return false }
        if textContainsPlaybackField(text, artist) { return true }
        if textContainsPlaybackField(text, album) { return true }
        if latinizedFieldTokensMatch(text, field: artist) { return true }
        if latinizedFieldTokensMatch(text, field: album) { return true }
        return false
    }

    private static func textContainsPlaybackField(_ text: String, _ field: String) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if text.range(of: trimmed, options: options) != nil { return true }

        let simplified = LanguageUtils.toSimplifiedChinese(trimmed)
        if simplified != trimmed,
           text.range(of: simplified, options: options) != nil {
            return true
        }
        let encodedFields = [trimmed, simplified]
            .filter { !$0.isEmpty }
            .compactMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }
        if encodedFields.contains(where: { encoded in
            text.range(of: encoded, options: [.caseInsensitive]) != nil
        }) {
            return true
        }
        return false
    }

    private static func latinizedFieldTokensMatch(_ text: String, field: String) -> Bool {
        let tokens = latinSearchTokens(for: field)
        guard !tokens.isEmpty else { return false }
        let boundedText = text.count > 120_000 ? String(text.prefix(120_000)) : text
        let latinText = LanguageUtils.toLatinLower(LanguageUtils.toSimplifiedChinese(boundedText))
        let compactText = latinText.filter { $0.isLetter || $0.isNumber }
        guard !latinText.isEmpty || !compactText.isEmpty else { return false }
        return tokens.allSatisfy { token in
            latinText.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || compactText.contains(token)
        }
    }

    private static func latinSearchTokens(for field: String) -> [String] {
        let rawTokens = LanguageUtils.normalizeUnicode(field)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
        if rawTokens.count >= 2 {
            return rawTokens
        }

        let latin = LanguageUtils.toLatinLower(LanguageUtils.toSimplifiedChinese(field))
        return latin.count >= 3 ? [latin] : []
    }

    private static func normalize(_ value: String) -> String {
        LanguageUtils.toSimplifiedChinese(
            LanguageUtils.normalizeTrackName(LanguageUtils.normalizeUnicode(value))
                .lowercased()
        )
    }

    static func firstAppleArtworkURL(in text: String) -> URL? {
        let normalizedText = text.replacingOccurrences(of: "\\/", with: "/")
        let pattern = #"https://is\d-ssl\.mzstatic\.com/image/thumb/[^"'\s]+?(?:\{w\}x\{h\}[a-z]*\.\{f\}|[0-9]+x[0-9]+[a-z]*\.(?:jpg|jpeg|png|heic|webp))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        guard let match = regex.firstMatch(in: normalizedText, range: range),
              let matchRange = Range(match.range, in: normalizedText) else { return nil }
        var raw = String(normalizedText[matchRange])
        while raw.hasPrefix("https:///") {
            raw = "https://" + raw.dropFirst("https:///".count)
        }
        raw = raw
            .replacingOccurrences(of: "{w}", with: "800")
            .replacingOccurrences(of: "{h}", with: "800")
            .replacingOccurrences(of: "{c}", with: "bb")
            .replacingOccurrences(of: "{f}", with: "jpg")
        return URL(string: raw)
    }

    static func cachedArtworkData(for artworkURL: URL) -> Data? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.Music/MusicUIArtworkCache")
        return cachedArtworkData(for: artworkURL, cacheRoot: root)
    }

    static func cachedArtworkData(for artworkURL: URL, cacheRoot: URL) -> Data? {
        let dbURL = cacheRoot.appendingPathComponent("Cache.db")
        let dataRoot = cacheRoot.appendingPathComponent("fsCachedData")
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT d.isDataOnFS, d.receiver_data
        FROM cfurl_cache_response r
        JOIN cfurl_cache_receiver_data d ON r.entry_ID = d.entry_ID
        WHERE r.request_key = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, artworkURL.absoluteString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let isDataOnFS = sqlite3_column_int(statement, 0) != 0
        guard let bytes = sqlite3_column_blob(statement, 1) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 1))
        guard count > 0 else { return nil }
        let rowData = Data(bytes: bytes, count: count)

        if isDataOnFS {
            guard let fileName = String(data: rowData, encoding: .utf8),
                  !fileName.isEmpty else { return nil }
            return try? Data(contentsOf: dataRoot.appendingPathComponent(fileName))
        }
        return rowData
    }

    private static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else { return nil }
        var index = 10
        let flags = data[3]

        if flags & 0x04 != 0 {
            guard index + 2 <= data.count else { return nil }
            let xlen = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2 + xlen
        }
        if flags & 0x08 != 0 {
            while index < data.count && data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {
            while index < data.count && data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < data.count - 8 else { return nil }

        var capacity = max(data.count * 8, 64 * 1024)
        for _ in 0..<6 {
            var output = Data(count: capacity)
            let decoded = output.withUnsafeMutableBytes { dstBuffer in
                data.withUnsafeBytes { srcBuffer in
                    guard let dst = dstBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let srcBase = srcBuffer.baseAddress else { return 0 }
                    let src = srcBase.advanced(by: index).assumingMemoryBound(to: UInt8.self)
                    return compression_decode_buffer(
                        dst,
                        capacity,
                        src,
                        data.count - 8 - index,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0 {
                output.count = decoded
                return output
            }
            capacity *= 2
        }
        return nil
    }
}
