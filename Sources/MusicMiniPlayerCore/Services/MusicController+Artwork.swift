/**
 * [INPUT]: 依赖 MusicController 的属性（musicApp, artworkCache, scriptingBridgeQueue 等）
 * [OUTPUT]: 导出封面提取/获取/缓存能力
 * [POS]: MusicController 的封面管理分片
 */

import Foundation
@preconcurrency import ScriptingBridge
import SwiftUI
import MusicKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Artwork Extraction Helper
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension MusicController {

    /// 从 ScriptingBridge track 对象提取封面图片
    /// 🔑 复用于队列遍历和单独封面获取，避免重复代码
    func extractArtwork(from track: NSObject) -> NSImage? {
        guard let artworks = track.value(forKey: "artworks") as? SBElementArray,
              artworks.count > 0,
              let artwork = artworks.object(at: 0) as? NSObject else {
            return nil
        }
        // 尝试 data 属性（Tuneful 方式）
        if let image = artwork.value(forKey: "data") as? NSImage {
            return image
        }
        // 尝试 rawData 属性
        if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty,
           let image = NSImage(data: rawData) {
            return image
        }
        return nil
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Artwork Management (ScriptingBridge > MusicKit > Placeholder)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 🔑 设置封面并自动计算亮度
    func setArtwork(_ image: NSImage?) {
        self.currentArtwork = image
        artworkFetchingForKey = nil  // 🔑 清除去重标志，允许后续获取
        // 计算亮度，阈值 0.6 以上视为浅色背景
        if let img = image {
            let brightness = img.perceivedBrightness()
            self.isLightBackground = brightness > 0.6
        } else {
            self.isLightBackground = false
        }
    }

    /// 判断封面回调是否仍对应当前播放曲目
    /// persistentID 非空时用 ID 比对；电台等无 ID 场景用 title 比对
    func isStillCurrentTrack(persistentID: String, title: String) -> Bool {
        if !persistentID.isEmpty {
            return currentPersistentID == persistentID
        }
        return currentTrackTitle == title
    }

    func fetchArtwork(for title: String, artist: String, album: String, persistentID: String) {
        logToFile("🎨 fetchArtwork: \(title) - \(artist)")

        // Check cache first（空 persistentID 跳过缓存）
        if !persistentID.isEmpty, let cached = artworkCache.object(forKey: persistentID as NSString) {
            logToFile("🎨 Cache HIT")
            self.setArtwork(cached)
            return
        }

        // 🔑 去重：防止通知路径和轮询路径同时触发
        let fetchKey = persistentID.isEmpty ? "title:\(title)" : "id:\(persistentID)"
        guard artworkFetchingForKey != fetchKey else {
            logToFile("🎨 Already fetching for \(fetchKey), skipping")
            return
        }
        artworkFetchingForKey = fetchKey

        // 🔑 递增封面代数，让旧任务自动跳过
        artworkFetchGeneration += 1
        let generation = artworkFetchGeneration

        logToFile("🎨 Cache MISS, starting sequential fetch (SB first, API fallback)...")

        // 🔑 串行优先级策略：优先 ScriptingBridge（与系统一致），失败才用 API
        scriptingBridgeQueue.async { [weak self] in
            guard let self = self,
                  let app = self.musicApp,
                  app.isRunning else {
                DispatchQueue.main.async { [weak self] in self?.artworkFetchingForKey = nil }
                return
            }

            // 🔑 代数检查：SB 队列堆积时旧任务直接跳过
            guard self.artworkFetchGeneration == generation else {
                self.logToFile("🎨 [SB] stale gen \(generation) vs \(self.artworkFetchGeneration), skipping")
                DispatchQueue.main.async { [weak self] in self?.artworkFetchingForKey = nil }
                return
            }

            self.logToFile("🎨 [SB] Starting ScriptingBridge fetch...")
            if let image = self.getArtworkImageFromApp(app) {
                self.logToFile("🎨 [SB] SUCCESS! Got image \(image.size)")
                DispatchQueue.main.async {
                    self.applyArtworkIfCurrent(image, persistentID: persistentID, title: title)
                }
            } else {
                self.logToFile("🎨 [SB] No embedded artwork, falling back to API...")
                Task {
                    if let mkArtwork = await self.fetchMusicKitArtwork(title: title, artist: artist, album: album) {
                        self.logToFile("🎨 [API] SUCCESS! Got image \(mkArtwork.size)")
                        await self.applyArtworkIfCurrent(mkArtwork, persistentID: persistentID, title: title)
                    } else {
                        self.logToFile("🎨 [API] No artwork found, setting placeholder + scheduling retry")
                        await MainActor.run {
                            if self.isStillCurrentTrack(persistentID: persistentID, title: title) {
                                self.setArtwork(self.createPlaceholder())
                            }
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self.retryArtworkFetch(persistentID: persistentID, title: title, artist: artist, album: album, generation: generation)
                    }
                }
            }
        }
    }


    /// 从 SBApplication 获取当前播放曲目的封面图片
    /// 🔑 复用 extractArtwork 避免重复代码
    func getArtworkImageFromApp(_ app: SBApplication) -> NSImage? {
        guard let track = app.value(forKey: "currentTrack") as? NSObject else { return nil }
        return extractArtwork(from: track)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Artwork Fetching (双轨方案: MusicKit + iTunes Search API)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 获取封面图片 - 双轨方案
    /// 1. 优先尝试 MusicKit（App Store 版本，需要开发者签名）
    /// 2. 回退到 iTunes Search API（开发版本，公开 API 无需签名）
    public func fetchMusicKitArtwork(title: String, artist: String, album: String) async -> NSImage? {
        guard !isPreview else { return nil }

        // Track 1: MusicKit (App Store 正式版)
        if MusicAuthorization.currentStatus == .authorized {
            if let image = await fetchArtworkViaMusicKit(title: title, artist: artist, album: album) {
                return image
            }
        }

        // Track 2: iTunes Search API (开发版回退)
        return await fetchArtworkViaITunesAPI(title: title, artist: artist, album: album)
    }

    /// MusicKit 方式获取封面（需要开发者签名 + entitlement）
    /// 🔑 优先匹配同专辑版本，避免返回不同版本的封面
    private func fetchArtworkViaMusicKit(title: String, artist: String, album: String) async -> NSImage? {
        do {
            let searchTerm = "\(title) \(artist)"
            var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
            request.limit = 10
            let response = try await request.response()

            // 优先选同专辑版本
            let albumLower = album.lowercased()
            let bestSong = response.songs.first { song in
                song.albumTitle?.lowercased() == albumLower
            } ?? response.songs.first

            if let song = bestSong,
               let artwork = song.artwork,
               let url = artwork.url(width: 300, height: 300) {
                DebugLogger.log("Artwork", "🎨 [MusicKit] 命中: '\(song.title)' album='\(song.albumTitle ?? "nil")' (目标album='\(album)')")
                let (data, _) = try await URLSession.shared.data(from: url)
                return NSImage(data: data)
            }
        } catch {
            // MusicKit 失败（未签名/无 entitlement），静默回退
        }
        return nil
    }

    /// iTunes Search API 方式获取封面（公开 API，无需授权）
    /// 🔑 优先匹配同专辑版本，避免返回不同版本的封面
    private func fetchArtworkViaITunesAPI(title: String, artist: String, album: String) async -> NSImage? {
        // 多级搜索策略
        let searchStrategies = [
            "\(title) \(artist)",           // 1. title + artist（最精确）
            "\(artist) \(title)",           // 2. artist + title（顺序调换）
            title                           // 3. 只用 title
        ]

        let artistLower = artist.lowercased()
        let titleLower = title.lowercased()
        let albumLower = album.lowercased()

        for searchTerm in searchStrategies {
            let trimmed = searchTerm.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let encodedTerm = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&media=music&entity=song&limit=15") else {
                continue
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   !results.isEmpty {

                    // 🔑 三级优先匹配：album+artist > artist > 首条
                    let bestMatch: [String: Any]? = results.first { r in
                        let rArtist = (r["artistName"] as? String)?.lowercased() ?? ""
                        let rAlbum = (r["collectionName"] as? String)?.lowercased() ?? ""
                        return rAlbum == albumLower
                            && (rArtist.contains(artistLower) || artistLower.contains(rArtist))
                    } ?? results.first { r in
                        let rArtist = (r["artistName"] as? String)?.lowercased() ?? ""
                        let rTrack = (r["trackName"] as? String)?.lowercased() ?? ""
                        return (rArtist.contains(artistLower) || artistLower.contains(rArtist))
                            && (rTrack.contains(titleLower) || titleLower.contains(rTrack))
                    } ?? results.first

                    if let match = bestMatch,
                       let artworkUrlString = match["artworkUrl100"] as? String {
                        let highResUrl = artworkUrlString.replacingOccurrences(of: "100x100", with: "300x300")
                        if let artworkUrl = URL(string: highResUrl),
                           let (imageData, _) = try? await URLSession.shared.data(from: artworkUrl) {
                            let matchAlbum = (match["collectionName"] as? String) ?? "nil"
                            DebugLogger.log("Artwork", "🎨 [iTunes API] 命中: album='\(matchAlbum)' (目标='\(album)') via '\(searchTerm)'")
                            return NSImage(data: imageData)
                        }
                    }
                }
            } catch {
                // 继续尝试下一个策略
            }
        }

        DebugLogger.log("Artwork", "🎨 [iTunes API] 全部策略失败: '\(title)' by '\(artist)'")
        return nil
    }

    // 🔑 同步获取缓存中的封面（供 UI 层直接使用）
    // 如果缓存命中立即返回，避免 async 开销
    public func getCachedArtwork(persistentID: String) -> NSImage? {
        guard !persistentID.isEmpty else { return nil }
        return artworkCache.object(forKey: persistentID as NSString)
    }

    /// 封面获取成功后统一处理：验证当前歌曲 → 设置封面 → 缓存
    @MainActor
    func applyArtworkIfCurrent(_ image: NSImage, persistentID: String, title: String) {
        guard isStillCurrentTrack(persistentID: persistentID, title: title) else { return }
        setArtwork(image)
        if !persistentID.isEmpty {
            artworkCache.setObject(image, forKey: persistentID as NSString, cost: Self.imageCacheCost(image))
        }
    }

    /// 延迟重试封面获取（电台首歌特殊处理）
    /// Music.app 刚开始播放电台时，封面数据可能尚未加载完成
    func retryArtworkFetch(persistentID: String, title: String, artist: String, album: String, generation: Int? = nil) async {
        guard await MainActor.run(body: { isStillCurrentTrack(persistentID: persistentID, title: title) }) else { return }
        if let gen = generation {
            let current = await MainActor.run { artworkFetchGeneration }
            guard gen == current else {
                debugPrint("⏭️ [retryArtworkFetch] stale gen \(gen) vs \(current), skipping\n")
                return
            }
        }

        debugPrint("🔄 [retryArtworkFetch] Retrying for \(title)...\n")

        // 1. 先尝试 ScriptingBridge
        let sbImage: NSImage? = await withCheckedContinuation { continuation in
            scriptingBridgeQueue.async { [weak self] in
                guard let self = self, let app = self.musicApp, app.isRunning else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.getArtworkImageFromApp(app))
            }
        }

        if let image = sbImage {
            await applyArtworkIfCurrent(image, persistentID: persistentID, title: title)
            debugPrint("✅ [retryArtworkFetch] ScriptingBridge retry success\n")
            return
        }

        // 2. ScriptingBridge 仍然失败，再试网络 API
        if let mkArtwork = await fetchMusicKitArtwork(title: title, artist: artist, album: album) {
            await applyArtworkIfCurrent(mkArtwork, persistentID: persistentID, title: title)
            debugPrint("✅ [retryArtworkFetch] API retry success\n")
        } else {
            debugPrint("⚠️ [retryArtworkFetch] All retries failed for \(title)\n")
        }
    }

    // Fetch artwork by persistentID using ScriptingBridge (for playlist items)
    public func fetchArtworkByPersistentID(persistentID: String) async -> NSImage? {
        guard !isPreview, !persistentID.isEmpty, let app = musicApp, app.isRunning else {
            return nil
        }

        // 先检查缓存
        if let cached = artworkCache.object(forKey: persistentID as NSString) {
            return cached
        }

        // 🔑 必须用 scriptingBridgeQueue — SB 不是线程安全的，双队列并发会 PAC crash
        let image: NSImage? = await withCheckedContinuation { continuation in
            scriptingBridgeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = self.getArtworkImageByPersistentID(app, persistentID: persistentID)
                continuation.resume(returning: result)
            }
        }

        // 缓存结果
        if let image = image {
            artworkCache.setObject(image, forKey: persistentID as NSString, cost: Self.imageCacheCost(image))
        }

        return image
    }

    /// 从 SBApplication 获取指定 persistentID 的封面
    private func getArtworkImageByPersistentID(_ app: SBApplication, persistentID: String) -> NSImage? {
        let startTime = CFAbsoluteTimeGetCurrent()

        // 1. 先在 currentPlaylist 中查找（限制搜索范围为前 100 首，因为 Up Next 只显示 10 首）
        if let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
           let tracks = playlist.value(forKey: "tracks") as? SBElementArray {

            // 🔑 只遍历前 100 首（Up Next 只显示当前歌曲后的 10 首）
            let searchLimit = min(tracks.count, 100)
            for i in 0..<searchLimit {
                if let track = tracks.object(at: i) as? NSObject,
                   let trackID = track.value(forKey: "persistentID") as? String,
                   trackID == persistentID {
                    if let image = extractArtwork(from: track) {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        debugPrint("✅ [getArtworkByPersistentID] Found at index \(i) in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
                        return image
                    }
                }
            }
        }

        // 2. 如果在当前播放列表的前 100 首中没找到，尝试用 NSPredicate 在 library 中查找
        let predicate = NSPredicate(format: "persistentID == %@", persistentID)
        if let sources = app.value(forKey: "sources") as? SBElementArray, sources.count > 0,
           let source = sources.object(at: 0) as? NSObject,
           let libraryPlaylists = source.value(forKey: "libraryPlaylists") as? SBElementArray,
           libraryPlaylists.count > 0,
           let libraryPlaylist = libraryPlaylists.object(at: 0) as? NSObject,
           let tracks = libraryPlaylist.value(forKey: "tracks") as? SBElementArray {

            // 🔑 使用 NSPredicate 过滤（这个在 library 中效率更高）
            if let filteredTracks = tracks.filtered(using: predicate) as? SBElementArray,
               filteredTracks.count > 0,
               let track = filteredTracks.object(at: 0) as? NSObject {
                if let image = extractArtwork(from: track) {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    debugPrint("✅ [getArtworkByPersistentID] Found in library in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
                    return image
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        debugPrint("⚠️ [getArtworkByPersistentID] Not found in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
        return nil
    }

    func createPlaceholder() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [NSColor.systemGray.withAlphaComponent(0.3), NSColor.systemGray.withAlphaComponent(0.1)])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        if let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: 110, y: 110, width: 80, height: 80))
        }
        image.unlockFocus()
        return image
    }
}
