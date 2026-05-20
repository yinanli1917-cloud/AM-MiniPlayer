import Foundation
import AppKit
import Compression
import SQLite3

enum PlaybackSessionArtworkFetcher {
    private static let maxArchives = 8

    static func fetchArtwork(title: String, artist: String, album: String) async -> NSImage? {
        guard let url = latestArtworkURL(title: title, artist: artist, album: album) else { return nil }
        if let cached = cachedArtworkData(for: url),
           let image = NSImage(data: cached) {
            DebugLogger.log("Artwork", "🎨 [PlaybackSession] Music UI cache hit: \(url.absoluteString)")
            return image
        }
        do {
            let (data, _) = try await HTTPClient.getData(url: url, timeout: 1.0, retry: false)
            DebugLogger.log("Artwork", "🎨 [PlaybackSession] original Music artwork: \(url.absoluteString)")
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    static func latestArtworkURL(title: String, artist: String, album: String) -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Music/PlaybackSessions")
        return latestArtworkURL(title: title, artist: artist, album: album, root: root)
    }

    static func latestArtworkURL(title: String, artist: String, album: String, root: URL) -> URL? {
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
                return url
            }
        }
        return nil
    }

    private static func decompressedText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let inflated = gunzip(data) else { return nil }
        return String(decoding: inflated, as: UTF8.self)
    }

    private static func textMatches(_ text: String, title: String, artist: String, album: String) -> Bool {
        let normalizedText = normalize(text)
        let normalizedTitle = normalize(title)
        let normalizedArtist = normalize(artist)
        let normalizedAlbum = normalize(album)

        guard !normalizedTitle.isEmpty, normalizedText.contains(normalizedTitle) else { return false }
        if !normalizedArtist.isEmpty, normalizedText.contains(normalizedArtist) { return true }
        if !normalizedAlbum.isEmpty, normalizedText.contains(normalizedAlbum) { return true }
        return false
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
