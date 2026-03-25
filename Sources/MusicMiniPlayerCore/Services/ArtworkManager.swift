/**
 * [INPUT]: 依赖 MusicKit, ScriptingBridge, URLSession
 * [OUTPUT]: 封面获取/缓存管理，提供 fetchArtwork/getCachedArtwork 等方法
 * [POS]: Services/ 的封面管理器，从 MusicController 中提取
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import AppKit
import MusicKit
import os

// ============================================================================
// MARK: - ArtworkManager
// ============================================================================

public final class ArtworkManager {
    public static let shared = ArtworkManager()

    // ========================================================================
    // MARK: - Cache
    // ========================================================================

    private let cache = NSCache<NSString, NSImage>()
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "ArtworkManager")

    // ========================================================================
    // MARK: - Concurrency Control
    // ========================================================================

    /// 封面获取队列（低优先级，避免阻塞 UI）
    private let fetchQueue = DispatchQueue(
        label: "com.yinanli.MusicMiniPlayer.artworkFetch",
        qos: .utility,
        attributes: .concurrent
    )

    /// 信号量限制并发数（避免过多请求）
    private let fetchSemaphore = DispatchSemaphore(value: 3)

    // ========================================================================
    // MARK: - Init
    // ========================================================================

    private init() {
        cache.totalCostLimit = 50 * 1024 * 1024  // 50MB — sole governor, no countLimit
    }

    /// Estimate NSImage memory cost (RGBA, 4 bytes/pixel)
    private func imageCost(_ image: NSImage) -> Int {
        let rep = image.representations.first
        let w = rep?.pixelsWide ?? Int(image.size.width)
        let h = rep?.pixelsHigh ?? Int(image.size.height)
        return max(w * h * 4, 1)
    }

    // ========================================================================
    // MARK: - Public API: Cache
    // ========================================================================

    /// 同步获取缓存封面
    public func getCached(persistentID: String) -> NSImage? {
        guard !persistentID.isEmpty else { return nil }
        return cache.object(forKey: persistentID as NSString)
    }

    /// 缓存封面
    public func setCached(_ image: NSImage, persistentID: String) {
        guard !persistentID.isEmpty else { return }
        cache.setObject(image, forKey: persistentID as NSString, cost: imageCost(image))
    }

    // ========================================================================
    // MARK: - Public API: Fetch (双轨方案)
    // ========================================================================

    /// 获取封面 - 双轨方案
    /// 1. 优先 MusicKit（App Store 版）
    /// 2. 回退 iTunes Search API（开发版）
    public func fetchArtwork(title: String, artist: String, album: String) async -> NSImage? {
        // Track 1: MusicKit
        if MusicAuthorization.currentStatus == .authorized {
            if let image = await fetchViaMusicKit(title: title, artist: artist) {
                return image
            }
        }

        // Track 2: iTunes Search API
        return await fetchViaITunesAPI(title: title, artist: artist)
    }

    // ========================================================================
    // MARK: - MusicKit
    // ========================================================================

    private func fetchViaMusicKit(title: String, artist: String) async -> NSImage? {
        do {
            let searchTerm = "\(title) \(artist)"
            var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
            request.limit = 1
            let response = try await request.response()

            if let song = response.songs.first,
               let artwork = song.artwork,
               let url = artwork.url(width: 300, height: 300) {
                let (data, _) = try await URLSession.shared.data(from: url)
                return NSImage(data: data)
            }
        } catch {
            // MusicKit 失败，静默回退
        }
        return nil
    }

    // ========================================================================
    // MARK: - iTunes Search API
    // ========================================================================

    private func fetchViaITunesAPI(title: String, artist: String) async -> NSImage? {
        let strategies = [
            "\(title) \(artist)",
            "\(artist) \(title)",
            title,
            artist
        ]

        for searchTerm in strategies {
            let trimmed = searchTerm.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=5") else {
                continue
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [[String: Any]],
                      !results.isEmpty else {
                    continue
                }

                // 优先选择匹配的结果
                let artistLower = artist.lowercased()
                let titleLower = title.lowercased()

                let bestMatch = results.first { result in
                    let resultArtist = (result["artistName"] as? String)?.lowercased() ?? ""
                    let resultTrack = (result["trackName"] as? String)?.lowercased() ?? ""
                    return resultArtist.contains(artistLower) || artistLower.contains(resultArtist) ||
                           resultTrack.contains(titleLower) || titleLower.contains(resultTrack)
                } ?? results.first

                if let match = bestMatch,
                   let artworkUrlString = match["artworkUrl100"] as? String {
                    let highResUrl = artworkUrlString.replacingOccurrences(of: "100x100", with: "300x300")
                    if let artworkUrl = URL(string: highResUrl),
                       let (imageData, _) = try? await URLSession.shared.data(from: artworkUrl) {
                        return NSImage(data: imageData)
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    // ========================================================================
    // MARK: - Placeholder
    // ========================================================================

    public func createPlaceholder() -> NSImage {
        let size = NSSize(width: 300, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor.systemGray.withAlphaComponent(0.3),
            NSColor.systemGray.withAlphaComponent(0.1)
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 45)
        if let icon = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: 110, y: 110, width: 80, height: 80))
        }
        image.unlockFocus()
        return image
    }

    // ========================================================================
    // MARK: - Brightness Detection
    // ========================================================================

    /// 计算图片亮度，用于决定文字颜色
    public func isLightBackground(_ image: NSImage?) -> Bool {
        guard let img = image else { return false }
        return img.perceivedBrightness() > 0.6
    }
}
