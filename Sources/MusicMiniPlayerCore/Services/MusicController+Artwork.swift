/**
 * [INPUT]: 依赖 MusicController 的属性（musicApp, artworkCache, scriptingBridgeQueue 等）
 * [OUTPUT]: 导出封面提取/获取/缓存能力
 * [POS]: MusicController 的封面管理分片
 */

import Foundation
import CryptoKit
@preconcurrency import ScriptingBridge
import SwiftUI
import MusicKit
import ObjCSupport

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Artwork Extraction Helper
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension MusicController {
    static let retainedArtworkPlaceholderGraceNanoseconds: UInt64 = 1_200_000_000

    /// 从 ScriptingBridge track 对象提取封面图片
    /// 🔑 复用于队列遍历和单独封面获取，避免重复代码
    /// 🔑 ObjC shield: Music.app 可在读取过程中变更 currentTrack / artworks，
    /// 触发 NSInternalInconsistencyException —— Swift 无法捕获，需 OBJCCatch。
    func extractArtwork(from track: NSObject) -> NSImage? {
        var result: NSImage?
        let ex = OBJCCatch {
            guard let artworks = track.value(forKey: "artworks") as? SBElementArray,
                  artworks.count > 0,
                  let artwork = artworks.object(at: 0) as? NSObject else {
                return
            }
            if let image = artwork.value(forKey: "data") as? NSImage {
                result = image
                return
            }
            if let rawData = artwork.value(forKey: "rawData") as? Data, !rawData.isEmpty,
               let image = NSImage(data: rawData) {
                result = image
            }
        }
        if let ex {
            DebugLogger.log("Artwork", "⚠️ [extractArtwork] NSException: \(ex.name.rawValue) — \(ex.reason ?? "nil")")
            return nil
        }
        return result
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Artwork Management (ScriptingBridge > MusicKit > Placeholder)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 🔑 设置封面并自动计算亮度
    func setArtwork(_ image: NSImage?, isPlaceholder: Bool = false) {
        self.currentArtwork = image
        self.currentArtworkIsPlaceholder = image == nil ? false : isPlaceholder
        if let img = image {
            let metrics = img.artworkBrightnessRegions()
            self.artworkLuminance = metrics.overall
            self.topLeftArtworkLuminance = metrics.topLeft
            self.topRightArtworkLuminance = metrics.topRight
        } else {
            self.artworkLuminance = 0.5
            self.topLeftArtworkLuminance = 0.5
            self.topRightArtworkLuminance = 0.5
        }
    }

    /// 统一缓存键 — 仅为非空 persistentID 返回 key。
    /// 🔑 Radio/URL tracks deliberately return nil (uncached):
    /// Apple Music radio metadata can reuse titles across different songs
    /// (station branding, transient cross-fade labels), so caching under
    /// "radio:title|artist" causes STALE artwork on subsequent tracks with the
    /// same reported title. Always re-fetch radio artwork fresh — the API hit
    /// is <1s via Deezer and SBTimeoutRunner bounds any slow SB fallback.
    func artworkCacheKey(persistentID: String, title: String, artist: String) -> NSString? {
        guard !currentTrackIsURLTrack else { return nil }
        guard !persistentID.isEmpty else { return nil }
        return persistentID as NSString
    }

    /// Secondary cache key for the notification path, before ScriptingBridge
    /// backfills persistentID. Require album as disambiguation so Apple Music
    /// subscription URL tracks can still hit cache without reviving the old
    /// radio title/artist stale-artwork bug.
    func artworkMetadataCacheKey(title: String, artist: String, album: String) -> NSString? {
        let t = Self.normalizeForArtworkMatching(title)
        let a = Self.normalizeForArtworkMatching(artist)
        let al = Self.normalizeForArtworkMatching(album)
        guard !t.isEmpty, !a.isEmpty, !al.isEmpty else { return nil }
        return "meta:\(t)|\(a)|\(al)" as NSString
    }

    func preloadArtwork(for tracks: [(title: String, artist: String, album: String, persistentID: String, duration: TimeInterval)]) {
        let candidates = tracks.prefix(4).compactMap { track -> (title: String, artist: String, album: String, persistentID: String)? in
            guard !track.title.isEmpty, !track.artist.isEmpty else { return nil }
            guard !isArtworkAlreadyCached(
                persistentID: track.persistentID,
                title: track.title,
                artist: track.artist,
                album: track.album
            ) else {
                return nil
            }
            return (track.title, track.artist, track.album, track.persistentID)
        }
        guard !candidates.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            for candidate in candidates {
                guard let self, !Task.isCancelled else { return }
                guard let result = await self.fetchArtworkResult(
                    title: candidate.title,
                    artist: candidate.artist,
                    album: candidate.album
                ) else { continue }
                self.cacheArtwork(
                    result.image,
                    persistentID: candidate.persistentID,
                    title: candidate.title,
                    artist: candidate.artist,
                    album: candidate.album,
                    persistToDisk: result.source.isAppleAuthoritative
                )
            }
        }
    }

    private func isArtworkAlreadyCached(persistentID: String, title: String, artist: String, album: String) -> Bool {
        let keys = artworkCacheKeys(persistentID: persistentID, title: title, artist: artist, album: album)
        return keys.contains { key in
            artworkCache.object(forKey: key) != nil || getDiskCachedArtwork(for: key) != nil
        }
    }

    /// 判断封面回调是否仍对应当前播放曲目。
    /// persistentID 非空时用 ID 比对；电台等无 ID 场景必须同时比对 title/artist，
    /// 避免 radio/station metadata 复用标题时把旧封面应用到新歌。
    func isStillCurrentTrack(persistentID: String, title: String, artist: String) -> Bool {
        if !persistentID.isEmpty {
            return currentPersistentID == persistentID
        }
        return currentTrackTitle == title && currentArtist == artist
    }

    func hasAppliedRealArtwork(for generation: Int) -> Bool {
        currentArtwork != nil && appliedArtworkGeneration == generation && !currentArtworkIsPlaceholder
    }

    /// 🔑 generation 由调用方提供（handleTrackChange / applySnapshot 各自 incrementGeneration）
    /// 不再内部递增 — 修复了双递增导致 handleTrackChange SB 块永远 stale 的 bug
    /// 🔑 去重统一依赖 generation + Task cancellation：
    ///    - `artworkAPITask?.cancel()` 避免 API pileup；
    ///    - `artworkFetchGeneration` gate 在 API/SB 回调里拒绝过期结果。
    ///    没有独立的 fetching-key 标志（它是 stale-state 滋生源）。
    func fetchArtwork(for title: String, artist: String, album: String, persistentID: String, generation: Int) {
        logToFile("🎨 fetchArtwork: \(title) - \(artist) gen=\(generation)")

        // Check cache first — radio tracks use "radio:title|artist" stable key
        let cacheKey = artworkCacheKey(persistentID: persistentID, title: title, artist: artist)
        let metadataKey = artworkMetadataCacheKey(title: title, artist: artist, album: album)
        let trackContext = diagnosticsArtworkTrack(title: title, artist: artist, album: album, persistentID: persistentID)
        let heldPreviousArtwork = currentArtwork != nil
            && !currentArtworkIsPlaceholder
            && !hasAppliedRealArtwork(for: generation)
        recordDiagnosticsArtworkFetchStarted(
            track: trackContext,
            generation: generation,
            persistentIDPresent: !persistentID.isEmpty,
            metadataCacheEligible: metadataKey != nil,
            heldPreviousArtwork: heldPreviousArtwork
        )
        if let key = cacheKey, let cached = artworkCache.object(forKey: key) {
            logToFile("🎨 Cache HIT (\(key))")
            let applyStart = CFAbsoluteTimeGetCurrent()
            self.setArtwork(cached)
            self.appliedArtworkGeneration = generation
            recordDiagnosticsArtworkApplied(
                track: trackContext,
                generation: generation,
                source: "cache.persistentID",
                applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
            )
            return
        }
        if let key = cacheKey, let cached = getDiskCachedArtwork(for: key) {
            logToFile("🎨 Disk cache HIT (\(key))")
            artworkCache.setObject(cached, forKey: key, cost: Self.imageCacheCost(cached))
            let applyStart = CFAbsoluteTimeGetCurrent()
            self.setArtwork(cached)
            self.appliedArtworkGeneration = generation
            recordDiagnosticsArtworkApplied(
                track: trackContext,
                generation: generation,
                source: "cache.disk.persistentID",
                applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
            )
            return
        }
        if let key = metadataKey, let cached = artworkCache.object(forKey: key) {
            logToFile("🎨 Metadata cache HIT (\(key))")
            let applyStart = CFAbsoluteTimeGetCurrent()
            self.setArtwork(cached)
            self.appliedArtworkGeneration = generation
            recordDiagnosticsArtworkApplied(
                track: trackContext,
                generation: generation,
                source: "cache.metadata",
                applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
            )
            return
        }
        if let key = metadataKey, let cached = getDiskCachedArtwork(for: key) {
            logToFile("🎨 Metadata disk cache HIT (\(key))")
            artworkCache.setObject(cached, forKey: key, cost: Self.imageCacheCost(cached))
            let applyStart = CFAbsoluteTimeGetCurrent()
            self.setArtwork(cached)
            self.appliedArtworkGeneration = generation
            recordDiagnosticsArtworkApplied(
                track: trackContext,
                generation: generation,
                source: "cache.disk.metadata",
                applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
            )
            return
        }

        logToFile("🎨 Cache MISS, starting concurrent fetch (SB + API in parallel)...")
        if heldPreviousArtwork {
            logToFile("🎨 Cache MISS, retaining previous artwork until replacement is ready")
        }
        recordDiagnosticsArtworkCacheMiss(
            track: trackContext,
            generation: generation,
            heldPreviousArtwork: heldPreviousArtwork
        )
        if !heldPreviousArtwork {
            let applyStart = CFAbsoluteTimeGetCurrent()
            setArtwork(createPlaceholder(), isPlaceholder: true)
            appliedArtworkGeneration = generation
            recordDiagnosticsArtworkPlaceholderShown(
                track: trackContext,
                generation: generation,
                reason: "initial",
                applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
            )
        } else {
            // Keep the old real cover visible while bounded fetch/retry lanes run.
            // A timer-driven placeholder here caused a visible black/empty flash
            // moments before a valid web/Apple fallback arrived.
        }

        // ━━━ Path 0: Music.app UI cache — exact local cover, may arrive after the notification ━━━
        Task { [weak self] in
            guard let self else { return }
            guard let image = await self.withArtworkTimeout(seconds: 1.6, operation: {
                await PlaybackSessionArtworkFetcher.fetchArtwork(title: title, artist: artist, album: album)
            }) else { return }
            await MainActor.run {
                self.applyArtworkIfCurrent(
                    image,
                    persistentID: persistentID,
                    title: title,
                    artist: artist,
                    album: album,
                    generation: generation,
                    source: .playbackSession
                )
            }
        }

        // ━━━ Path 1: API fetch — starts immediately, no SB queue dependency ━━━
        // API is provisional — if SB already applied for this generation, API result is discarded.
        // 🔑 Cancel previous API task to prevent pileup during rapid switching.
        artworkAPITask?.cancel()
        artworkAPITask = Task { [weak self] in
            guard let self else { return }
            if let result = await self.fetchArtworkResult(title: title, artist: artist, album: album) {
                self.logToFile("🎨 [API] SUCCESS! Got \(result.source) image \(result.image.size)")
                await MainActor.run {
                    self.applyArtworkIfCurrent(result.image, persistentID: persistentID, title: title, artist: artist, album: album, generation: generation, source: result.source)
                }
            } else {
                guard !Task.isCancelled else { return }
                self.logToFile("🎨 [API] No artwork found, scheduling retry (placeholder deferred)")
                // 🔑 Placeholder deferred — during rapid switching, the API task for
                // an in-between track gets cancelled before completing. We must NOT
                // flash the music-note placeholder in those cases. The placeholder
                // is only valid IF (a) we're still the current generation after the
                // short retry wait AND (b) no other artwork has been applied since AND (c)
                // there's no existing artwork to display. Drop on cancellation.
                let retryDelay: UInt64 = heldPreviousArtwork
                    ? Self.retainedArtworkPlaceholderGraceNanoseconds
                    : 250_000_000
                try? await Task.sleep(nanoseconds: retryDelay)
                guard !Task.isCancelled else { return }
                await self.retryArtworkFetch(persistentID: persistentID, title: title, artist: artist, album: album, generation: generation)
                // After retry returns, if still nothing, fall back to placeholder.
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.artworkFetchGeneration == generation else { return }
                    if self.isStillCurrentTrack(persistentID: persistentID, title: title, artist: artist)
                        && !self.hasAppliedRealArtwork(for: generation) {
                        self.applyArtworkPlaceholder(
                            track: trackContext,
                            generation: generation,
                            reason: "fetchFailed"
                        )
                    }
                }
            }
        }

        // ━━━ Path 2: SB fetch — authoritative source, always overrides API ━━━
        // 🔑 Do NOT replace artworkApp/artworkQueue on hang — that triggers ARC
        // dealloc of SBApplication while Apple Event replies are still pending,
        // causing EXC_BAD_ACCESS in AEProcessMessage → pthread_mutex_lock on a
        // freed callback table. (Verified from crash reports 2026-04-18.)
        // SBTimeoutRunner inside getArtworkImageFromApp releases the CALLER
        // from a hung IPC without deallocating the SBApplication; the stuck AE
        // call leaks one thread until Music.app eventually replies — bounded
        // and safe.
        artworkQueue.async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.lastArtworkQueueHeartbeat = Date() } }

            guard let app = self.artworkApp ?? self.musicApp,
                  app.isRunning else { return }
            guard self.artworkFetchGeneration == generation else {
                self.logToFile("🎨 [SB] stale gen \(generation) vs \(self.artworkFetchGeneration), skipping")
                self.recordDiagnosticsArtworkDropped(
                    track: trackContext,
                    generation: generation,
                    source: ArtworkSource.sb.diagnosticName,
                    reason: "generationMismatchBeforeFetch"
                )
                return
            }

            self.logToFile("🎨 [SB] Starting ScriptingBridge fetch...")
            if let image = self.getArtworkImageFromApp(app) {
                self.logToFile("🎨 [SB] SUCCESS! Got image \(image.size)")
                DispatchQueue.main.async {
                    self.applyArtworkIfCurrent(image, persistentID: persistentID, title: title, artist: artist, album: album, generation: generation, source: .sb)
                }
            }
        }
    }


    /// 从 SBApplication 获取当前播放曲目的封面图片
    /// 🔑 复用 extractArtwork 避免重复代码
    /// 🔑 Radio URL tracks may hang `currentTrack` IPC indefinitely. A 1.5s hard
    /// timeout releases the caller so artworkQueue drains other requests promptly;
    /// the existing 5s heartbeat remains as a queue-recovery backstop.
    func getArtworkImageFromApp(_ app: SBApplication) -> NSImage? {
        return SBTimeoutRunner.run(timeout: 1.5, lane: "artwork") { [weak self] in
            guard let self else { return nil }
            guard let track = app.value(forKey: "currentTrack") as? NSObject else { return nil }
            return self.extractArtwork(from: track)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Artwork Fetching (双轨方案: MusicKit + iTunes Search API)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// 获取封面图片 - 双轨方案
    /// 1. 优先尝试 MusicKit（App Store 版本，需要开发者签名）
    /// 2. 回退到 iTunes Search API（开发版本，公开 API 无需签名）
    public func fetchMusicKitArtwork(title: String, artist: String, album: String) async -> NSImage? {
        await fetchArtworkResult(title: title, artist: artist, album: album)?.image
    }

    private struct ArtworkFetchResult {
        let image: NSImage
        let source: ArtworkSource
    }

    private func fetchArtworkResult(title: String, artist: String, album: String) async -> ArtworkFetchResult? {
        guard !isPreview else { return nil }

        // 🔑 The user's library is mostly Apple Music subscription tracks, which
        // present as URL tracks via ScriptingBridge — `count of artworks` is 0,
        // so SB-based extraction structurally cannot work. We must use network
        // APIs. Race them in parallel — under rapid switching the LAST track's
        // fetch must complete fast, and sequential chains (MusicKit→NetEase→
        // Deezer→iTunes) accumulated up to ~2s before yielding. Parallel race
        // returns within the FASTEST source's round-trip (~300-700ms typical).
        //
        // Source priority: Apple catalog artwork should win when it arrives
        // promptly, because the UI must match Music.app/Apple Music. Keep web
        // results as an instant fallback, but give Apple a tiny grace period
        // after the first web hit so the common "Apple was just behind Deezer"
        // race does not permanently cache inconsistent covers.

        enum ArtworkRaceEvent {
            case image(NSImage, ArtworkSource)
            case appleGraceExpired
        }

        return await withTaskGroup(of: ArtworkRaceEvent?.self) { group in
            if MusicAuthorization.currentStatus == .authorized {
                group.addTask {
                    if let img = await self.withArtworkTimeout(seconds: 1.2, operation: {
                        await self.fetchArtworkViaMusicKit(title: title, artist: artist, album: album)
                    }) { return .image(img, .musicKit) }
                    return nil
                }
            }
            group.addTask {
                if let img = await self.withArtworkTimeout(seconds: 1.4, operation: {
                    await self.fetchArtworkViaITunesAPI(title: title, artist: artist, album: album)
                }) { return .image(img, .iTunes) }
                return nil
            }
            group.addTask {
                if let img = await self.withArtworkTimeout(seconds: 1.2, operation: {
                    await self.fetchArtworkViaNetEase(title: title, artist: artist, album: album)
                }) { return .image(img, .web) }
                return nil
            }
            group.addTask {
                if let img = await self.withArtworkTimeout(seconds: 1.2, operation: {
                    await self.fetchArtworkViaDeezer(title: title, artist: artist)
                }) { return .image(img, .web) }
                return nil
            }

            var webFallback: NSImage?
            var graceStarted = false

            for await event in group {
                guard let event else { continue }
                switch event {
                case .image(_, .sb):
                    continue

                case let .image(image, source) where source.isAppleAuthoritative:
                    group.cancelAll()
                    return ArtworkFetchResult(image: image, source: source)

                case let .image(image, .web):
                    if webFallback == nil {
                        webFallback = image
                    }
                    if !graceStarted {
                        graceStarted = true
                        group.addTask {
                            // Keep a short Apple grace window for cover fidelity, but
                            // do not hold a proven web fallback long enough for the
                            // switch to feel one track late.
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            return .appleGraceExpired
                        }
                    }

                case .appleGraceExpired:
                    if let webFallback {
                        group.cancelAll()
                        return ArtworkFetchResult(image: webFallback, source: .web)
                    }

                default:
                    continue
                }
            }

            if let webFallback {
                return ArtworkFetchResult(image: webFallback, source: .web)
            }
            return nil
        }
    }

    private func withArtworkTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let box = ArtworkContinuationBox(continuation)
            let worker = Task { await operation() }
            Task {
                let value = await worker.value
                box.resume(value)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                worker.cancel()
                box.resume(nil)
            }
        }
    }

    /// Normalize a string for cross-script artwork matching:
    ///   - lowercased
    ///   - whitespace trimmed
    ///   - traditional → simplified (so 愛 ≡ 爱)
    /// Cheap, allocation-light, and good enough for "did NetEase return our song?".
    static func normalizeForArtworkMatching(_ s: String) -> String {
        let trimmed = LanguageUtils.normalizeTrackName(LanguageUtils.normalizeUnicode(s))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return LanguageUtils.toSimplifiedChinese(trimmed)
    }

    struct ArtworkMatchScore {
        let title: Int
        let artist: Int
        let album: Int

        var total: Int { title + artist + album }
        var isReliable: Bool {
            (title > 0 && (artist > 0 || album > 0)) || (artist > 0 && album > 0)
        }
    }

    static func scoreArtworkCandidate(
        title inputTitle: String,
        artist inputArtist: String,
        album inputAlbum: String,
        candidateTitle: String,
        candidateArtist: String,
        candidateAlbum: String
    ) -> ArtworkMatchScore {
        let titleScore = artworkTextScore(inputTitle, candidateTitle, exact: 4, partial: 2)
        let artistScore = artworkTextScore(inputArtist, candidateArtist, exact: 3, partial: 1)
        let albumScore = artworkTextScore(inputAlbum, candidateAlbum, exact: 3, partial: 2)
        return ArtworkMatchScore(title: titleScore, artist: artistScore, album: albumScore)
    }

    private static func artworkTextScore(_ input: String, _ result: String, exact: Int, partial: Int) -> Int {
        let lhs = normalizeForArtworkMatching(input)
        let rhs = normalizeForArtworkMatching(result)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return exact }
        if lhs.contains(rhs) || rhs.contains(lhs) { return partial }

        let lhsLatin = LanguageUtils.toLatinLower(lhs)
        let rhsLatin = LanguageUtils.toLatinLower(rhs)
        guard lhsLatin.count >= 3, rhsLatin.count >= 3 else { return 0 }
        if lhsLatin == rhsLatin { return partial }
        if lhsLatin.contains(rhsLatin) || rhsLatin.contains(lhsLatin) { return max(partial - 1, 0) }
        return 0
    }

    /// NetEase Cloud Music — single-call cloudsearch returns album picUrl. Best
    /// CJK-track coverage available; also returns hits for many Western tracks.
    /// Match priority: title+artist+album > title+artist > first result.
    private func fetchArtworkViaNetEase(title: String, artist: String, album: String) async -> NSImage? {
        let query = "\(title) \(artist)"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://music.163.com/api/cloudsearch/pc?s=\(encoded)&type=1&limit=10") else {
            return nil
        }

        var req = URLRequest(url: searchURL, timeoutInterval: 2.0)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  !songs.isEmpty else {
                return nil
            }

            // Match preference uses CJK-aware title comparison so 愛你不是兩三天 ↔ 爱你不是两三天
            // resolve to the same song. Self.normalizeForArtworkMatching handles trad/simp.
            let scored = songs.map { song -> (song: [String: Any], score: ArtworkMatchScore) in
                let sTitle = (song["name"] as? String) ?? ""
                let sArtist = ((song["ar"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
                let sAlbum = ((song["al"] as? [String: Any])?["name"] as? String) ?? ""
                return (song, Self.scoreArtworkCandidate(
                    title: title, artist: artist, album: album,
                    candidateTitle: sTitle, candidateArtist: sArtist, candidateAlbum: sAlbum
                ))
            }
            guard let best = scored.filter({ $0.score.isReliable })
                .max(by: { $0.score.total < $1.score.total })?.song else {
                return nil
            }
            guard let al = best["al"] as? [String: Any],
                  let picStr = al["picUrl"] as? String,
                  let picURL = URL(string: picStr.replacingOccurrences(of: "http://", with: "https://")) else {
                return nil
            }

            // NetEase param `?param=300y300` requests a 300×300 crop — same size as our
            // other API sources, keeps cache cost predictable.
            let sizedURL = URL(string: picURL.absoluteString + "?param=300y300") ?? picURL
            let (imageData, _) = try await HTTPClient.getData(url: sizedURL, timeout: 1.0, retry: false)
            DebugLogger.log("Artwork", "🎨 [NetEase] 命中: '\(best["name"] ?? "?")' al='\((best["al"] as? [String: Any])?["name"] ?? "?")'")
            return NSImage(data: imageData)
        } catch {
            return nil
        }
    }

    /// Deezer API — free, no auth, reliable artwork source
    private func fetchArtworkViaDeezer(title: String, artist: String) async -> NSImage? {
        let query = "artist:\"\(artist)\" track:\"\(title)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=5") else {
            return nil
        }

        do {
            let (data, _) = try await HTTPClient.getData(url: url, timeout: 1.0, retry: false)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["data"] as? [[String: Any]],
                  !results.isEmpty else {
                return nil
            }

            let scored = results.map { r -> (result: [String: Any], score: ArtworkMatchScore) in
                let rArtist = (r["artist"] as? [String: Any])?["name"] as? String ?? ""
                let rTitle = (r["title"] as? String) ?? ""
                let rAlbum = (r["album"] as? [String: Any])?["title"] as? String ?? ""
                return (r, Self.scoreArtworkCandidate(
                    title: title, artist: artist, album: "",
                    candidateTitle: rTitle, candidateArtist: rArtist, candidateAlbum: rAlbum
                ))
            }
            guard let match = scored.filter({ $0.score.isReliable })
                .max(by: { $0.score.total < $1.score.total })?.result,
                  let album = match["album"] as? [String: Any],
                  let coverUrl = album["cover_big"] as? String,  // 500x500
                  let imageUrl = URL(string: coverUrl) else {
                return nil
            }

            let (imageData, _) = try await HTTPClient.getData(url: imageUrl, timeout: 1.0, retry: false)
            DebugLogger.log("Artwork", "🎨 [Deezer] 命中: '\(match["title"] ?? "?")' by '\((match["artist"] as? [String: Any])?["name"] ?? "?")'")
            return NSImage(data: imageData)
        } catch {
            return nil
        }
    }

    /// MusicKit 方式获取封面（需要开发者签名 + entitlement）
    /// 🔑 优先匹配同专辑版本，避免返回不同版本的封面
    private func fetchArtworkViaMusicKit(title: String, artist: String, album: String) async -> NSImage? {
        do {
            let searchTerm = "\(title) \(artist)"
            var request = MusicCatalogSearchRequest(term: searchTerm, types: [Song.self])
            request.limit = 10
            let response = try await request.response()

            let bestSong = response.songs
                .map { song -> (song: Song, score: ArtworkMatchScore) in
                    (song, Self.scoreArtworkCandidate(
                        title: title, artist: artist, album: album,
                        candidateTitle: song.title,
                        candidateArtist: song.artistName,
                        candidateAlbum: song.albumTitle ?? ""
                    ))
                }
                .filter { $0.score.isReliable }
                .max(by: { $0.score.total < $1.score.total })?.song

            if let song = bestSong,
               let artwork = song.artwork,
               let url = artwork.url(width: 300, height: 300) {
                DebugLogger.log("Artwork", "🎨 [MusicKit] 命中: '\(song.title)' album='\(song.albumTitle ?? "nil")' (目标album='\(album)')")
                let (data, _) = try await HTTPClient.getData(url: url, timeout: 1.0, retry: false)
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

        for searchTerm in searchStrategies {
            let trimmed = searchTerm.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let encodedTerm = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&media=music&entity=song&limit=15") else {
                continue
            }

            do {
                let (data, _) = try await HTTPClient.getData(url: url, headers: [:], timeout: 1.0, retry: false)

                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["results"] as? [[String: Any]],
                   !results.isEmpty {

                    let bestMatch: [String: Any]? = results
                        .map { r -> (result: [String: Any], score: ArtworkMatchScore) in
                            let rArtist = r["artistName"] as? String ?? ""
                            let rAlbum = r["collectionName"] as? String ?? ""
                            let rTrack = r["trackName"] as? String ?? ""
                            return (r, Self.scoreArtworkCandidate(
                                title: title, artist: artist, album: album,
                                candidateTitle: rTrack, candidateArtist: rArtist, candidateAlbum: rAlbum
                            ))
                        }
                        .filter { $0.score.isReliable }
                        .max(by: { $0.score.total < $1.score.total })?.result

                    if let match = bestMatch,
                       let artworkUrlString = match["artworkUrl100"] as? String {
                        let highResUrl = artworkUrlString.replacingOccurrences(of: "100x100", with: "300x300")
                        if let artworkUrl = URL(string: highResUrl),
                           let (imageData, _) = try? await HTTPClient.getData(url: artworkUrl, timeout: 1.0, retry: false) {
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

    private func getDiskCachedArtwork(for key: NSString) -> NSImage? {
        for url in artworkDiskCacheURLs(for: key) {
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) else {
                continue
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return image
        }
        return nil
    }

    private func storeDiskCachedArtwork(_ image: NSImage, for key: NSString) {
        guard let data = encodedArtworkDiskCacheData(from: image),
              let url = artworkDiskCacheWriteURL(for: key) else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                pruneArtworkDiskCache(in: directory)
            } catch {
                DebugLogger.log("Artwork", "🎨 [DiskCache] write failed: \(error.localizedDescription)")
            }
        }
    }

    private func artworkDiskCacheWriteURL(for key: NSString) -> URL? {
        artworkDiskCacheURL(for: key, fileExtension: "jpg")
    }

    private func artworkDiskCacheURLs(for key: NSString) -> [URL] {
        [
            artworkDiskCacheURL(for: key, fileExtension: "jpg"),
            artworkDiskCacheURL(for: key, fileExtension: "tiff")
        ].compactMap { $0 }
    }

    private func artworkDiskCacheURL(for key: NSString, fileExtension: String) -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let digest = SHA256.hash(data: Data((key as String).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return appSupport
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("ArtworkCache", isDirectory: true)
            .appendingPathComponent("\(digest).\(fileExtension)")
    }

    private func artworkCacheKeys(
        persistentID: String,
        title: String,
        artist: String,
        album: String
    ) -> [NSString] {
        var keys: [NSString] = []
        if let key = artworkCacheKey(persistentID: persistentID, title: title, artist: artist) {
            keys.append(key)
        }
        if let key = artworkMetadataCacheKey(title: title, artist: artist, album: album),
           !keys.contains(key) {
            keys.append(key)
        }
        return keys
    }

    private func cacheArtwork(
        _ image: NSImage,
        persistentID: String,
        title: String,
        artist: String,
        album: String,
        persistToDisk: Bool
    ) {
        for key in artworkCacheKeys(persistentID: persistentID, title: title, artist: artist, album: album) {
            artworkCache.setObject(image, forKey: key, cost: Self.imageCacheCost(image))
            if persistToDisk {
                storeDiskCachedArtwork(image, for: key)
            }
        }
    }

    enum ArtworkSource {
        case sb, playbackSession, musicKit, iTunes, web

        var isAppleAuthoritative: Bool {
            switch self {
            case .sb, .playbackSession, .musicKit, .iTunes: return true
            case .web: return false
            }
        }

        var diagnosticName: String {
            switch self {
            case .sb: return "scriptingBridge"
            case .playbackSession: return "apple.playbackSession"
            case .musicKit: return "apple.musicKit"
            case .iTunes: return "apple.iTunes"
            case .web: return "web"
            }
        }
    }

    private func diagnosticsArtworkTrack(
        title: String,
        artist: String,
        album: String,
        persistentID: String
    ) -> DiagnosticTrackContext {
        let sameCurrentTrack = title == currentTrackTitle && artist == currentArtist
        return DiagnosticTrackContext(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            persistentID: persistentID.isEmpty && sameCurrentTrack ? currentPersistentID : persistentID,
            playbackTime: currentTime,
            trackClass: currentTrackClass.isEmpty ? nil : currentTrackClass,
            playlistName: currentPlaylistName.isEmpty ? nil : currentPlaylistName,
            playbackContext: diagnosticsTrackContext().playbackContext,
            playerPage: String(describing: currentPage)
        )
    }

    private func recordDiagnosticsArtworkFetchStarted(
        track: DiagnosticTrackContext,
        generation: Int,
        persistentIDPresent: Bool,
        metadataCacheEligible: Bool,
        heldPreviousArtwork: Bool
    ) {
        Task { @MainActor in
            DiagnosticsService.shared.recordArtworkFetchStarted(
                track: track,
                generation: generation,
                persistentIDPresent: persistentIDPresent,
                metadataCacheEligible: metadataCacheEligible,
                heldPreviousArtwork: heldPreviousArtwork
            )
        }
    }

    private func recordDiagnosticsArtworkCacheMiss(
        track: DiagnosticTrackContext,
        generation: Int,
        heldPreviousArtwork: Bool
    ) {
        Task { @MainActor in
            DiagnosticsService.shared.recordArtworkCacheMiss(
                track: track,
                generation: generation,
                heldPreviousArtwork: heldPreviousArtwork
            )
        }
    }

    private func recordDiagnosticsArtworkApplied(
        track: DiagnosticTrackContext,
        generation: Int,
        source: String,
        applyMilliseconds: Double
    ) {
        Task { @MainActor in
            DiagnosticsService.shared.recordArtworkApplied(
                track: track,
                generation: generation,
                source: source,
                applyMilliseconds: applyMilliseconds
            )
        }
    }

    private func recordDiagnosticsArtworkPlaceholderShown(
        track: DiagnosticTrackContext,
        generation: Int,
        reason: String,
        applyMilliseconds: Double
    ) {
        Task { @MainActor in
            DiagnosticsService.shared.recordArtworkPlaceholderShown(
                track: track,
                generation: generation,
                reason: reason,
                applyMilliseconds: applyMilliseconds
            )
        }
    }

    private func recordDiagnosticsArtworkDropped(
        track: DiagnosticTrackContext,
        generation: Int,
        source: String,
        reason: String
    ) {
        Task { @MainActor in
            DiagnosticsService.shared.recordArtworkDropped(
                track: track,
                generation: generation,
                source: source,
                reason: reason
            )
        }
    }

    @MainActor
    private func applyArtworkPlaceholder(
        track: DiagnosticTrackContext,
        generation: Int,
        reason: String
    ) {
        let applyStart = CFAbsoluteTimeGetCurrent()
        setArtwork(createPlaceholder(), isPlaceholder: true)
        appliedArtworkGeneration = generation
        recordDiagnosticsArtworkPlaceholderShown(
            track: track,
            generation: generation,
            reason: reason,
            applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
        )
    }

    /// 封面获取成功后统一处理：验证当前歌曲 → 源优先级 → 设置封面 → 缓存
    /// 🔑 SB / Apple playback-session/catalog artwork are authoritative.
    /// Web artwork is provisional and must not poison the cache with a different
    /// release/crop when Apple Music is merely slower.
    @MainActor
    func applyArtworkIfCurrent(_ image: NSImage, persistentID: String, title: String, artist: String, album: String, generation: Int, source: ArtworkSource) {
        let track = diagnosticsArtworkTrack(title: title, artist: artist, album: album, persistentID: persistentID)
        guard isStillCurrentTrack(persistentID: persistentID, title: title, artist: artist) else {
            recordDiagnosticsArtworkDropped(
                track: track,
                generation: generation,
                source: source.diagnosticName,
                reason: "trackMismatch"
            )
            return
        }
        guard artworkFetchGeneration == generation else {
            recordDiagnosticsArtworkDropped(
                track: track,
                generation: generation,
                source: source.diagnosticName,
                reason: "generationMismatch"
            )
            return
        }

        // ScriptingBridge is the exact Music.app current-track image when it is available.
        if source != .sb && sbAppliedForGeneration == generation {
            logToFile("🎨 [\(source)] SB already applied for gen \(generation), discarding later result")
            recordDiagnosticsArtworkDropped(
                track: track,
                generation: generation,
                source: source.diagnosticName,
                reason: "authoritativeArtworkAlreadyApplied"
            )
            return
        }

        let applyStart = CFAbsoluteTimeGetCurrent()
        setArtwork(image)
        appliedArtworkGeneration = generation
        if source.isAppleAuthoritative { sbAppliedForGeneration = generation }
        recordDiagnosticsArtworkApplied(
            track: track,
            generation: generation,
            source: source.diagnosticName,
            applyMilliseconds: (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
        )

        cacheArtwork(
            image,
            persistentID: persistentID,
            title: title,
            artist: artist,
            album: album,
            persistToDisk: source.isAppleAuthoritative
        )
    }

    /// 延迟重试封面获取（电台首歌特殊处理）
    /// Music.app 刚开始播放电台时，封面数据可能尚未加载完成
    /// 🔑 不再使用 withCheckedContinuation + artworkQueue — 如果 SB 卡死，continuation
    /// 永远不会 resume，Task 永远挂起。初始 fetchArtwork 已经并行尝试了 SB，
    /// 重试只走 API（不阻塞、不挂起）。
    func retryArtworkFetch(persistentID: String, title: String, artist: String, album: String, generation: Int) async {
        guard await MainActor.run(body: { isStillCurrentTrack(persistentID: persistentID, title: title, artist: artist) }) else { return }
        let current = await MainActor.run { artworkFetchGeneration }
        guard generation == current else {
            debugPrint("⏭️ [retryArtworkFetch] stale gen \(generation) vs \(current), skipping\n")
            return
        }

        debugPrint("🔄 [retryArtworkFetch] Retrying API for \(title)...\n")

        if let result = await fetchArtworkResult(title: title, artist: artist, album: album) {
            await applyArtworkIfCurrent(result.image, persistentID: persistentID, title: title, artist: artist, album: album, generation: generation, source: result.source)
            debugPrint("✅ [retryArtworkFetch] API retry success\n")
        } else {
            debugPrint("⚠️ [retryArtworkFetch] API retry failed for \(title)\n")
        }
    }

    // Fetch artwork by persistentID using ScriptingBridge (for playlist items)
    public func fetchArtworkByPersistentID(persistentID: String) async -> NSImage? {
        guard !isPreview, !persistentID.isEmpty else { return nil }

        // 先检查缓存
        if let cached = artworkCache.object(forKey: persistentID as NSString) {
            return cached
        }

        // 🔑 Use dedicated artworkQueue — separate SB instance, won't block position polls
        let controller = WeakSendableReference(self)
        let image: NSImage? = await withCheckedContinuation { continuation in
            artworkQueue.async {
                guard let self = controller.value,
                      let app = self.artworkApp ?? self.musicApp,
                      app.isRunning else {
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
    /// 🔑 Must be called on artworkQueue. Generation check prevents iterating stale
    /// SBElementArray objects after track change — same pattern as getUpNextTracksFromApp.
    private func getArtworkImageByPersistentID(_ app: SBApplication, persistentID: String) -> NSImage? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let gen = artworkFetchGeneration  // Snapshot generation at start

        // 🔑 Hard timeout: full playlist scans can hang when Music.app is
        // transitioning playlists. Without this, the enclosing serial queue
        // backs up and (previously) tripped the now-removed heartbeat
        // recreation that crashed in AEProcessMessage.
        return SBTimeoutRunner.run(timeout: 3.0, lane: "artwork") { [weak self] () -> NSImage? in
            guard let self else { return nil }
            var result: NSImage?

            // 🔑 ObjC shield: SBElementArray iteration can crash with NSException when
            // Music.app mutates the array mid-loop (rapid track switching, playlist edit).
            // Swift cannot catch NSException — OBJCCatch converts it to a nil return.
            let ex = OBJCCatch {

            // 1. currentPlaylist 前 100 首
            if let playlist = app.value(forKey: "currentPlaylist") as? NSObject,
               let tracks = playlist.value(forKey: "tracks") as? SBElementArray {
                let searchLimit = min(tracks.count, 100)
                for i in 0..<searchLimit {
                    guard self.artworkFetchGeneration == gen else {
                        debugPrint("⚠️ [getArtworkByPersistentID] Generation changed (\(gen) → \(self.artworkFetchGeneration)), aborting\n")
                        return
                    }
                    if let track = tracks.object(at: i) as? NSObject,
                       let trackID = track.value(forKey: "persistentID") as? String,
                       trackID == persistentID {
                        if let image = self.extractArtwork(from: track) {
                            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                            debugPrint("✅ [getArtworkByPersistentID] Found at index \(i) in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
                            result = image
                            return
                        }
                    }
                }
            }

            // 2. library 回退
            let predicate = NSPredicate(format: "persistentID == %@", persistentID)
            if let sources = app.value(forKey: "sources") as? SBElementArray, sources.count > 0,
               let source = sources.object(at: 0) as? NSObject,
               let libraryPlaylists = source.value(forKey: "libraryPlaylists") as? SBElementArray,
               libraryPlaylists.count > 0,
               let libraryPlaylist = libraryPlaylists.object(at: 0) as? NSObject,
               let tracks = libraryPlaylist.value(forKey: "tracks") as? SBElementArray {
                if let filteredTracks = tracks.filtered(using: predicate) as? SBElementArray,
                   filteredTracks.count > 0,
                   let track = filteredTracks.object(at: 0) as? NSObject {
                    if let image = self.extractArtwork(from: track) {
                        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                        debugPrint("✅ [getArtworkByPersistentID] Found in library in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
                        result = image
                        return
                    }
                }
            }
        }

            if let ex {
                DebugLogger.log("Artwork", "⚠️ [getArtworkByPersistentID] NSException swallowed: \(ex.name.rawValue) — \(ex.reason ?? "nil")")
                return nil
            }

            if result == nil {
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                debugPrint("⚠️ [getArtworkByPersistentID] Not found in \(String(format: "%.0f", elapsed))ms: \(persistentID.prefix(8))...\n")
            }
            return result
        }
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

private final class ArtworkContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<NSImage?, Never>

    init(_ continuation: CheckedContinuation<NSImage?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: NSImage?) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}

func encodedArtworkDiskCacheData(from image: NSImage, compressionFactor: CGFloat = 0.82) -> Data? {
    var rect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        return image.tiffRepresentation
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionFactor])
        ?? image.tiffRepresentation
}

func pruneArtworkDiskCache(
    in directory: URL,
    maxBytes: Int = 24 * 1024 * 1024,
    targetBytes: Int = 20 * 1024 * 1024,
    maxFiles: Int = 96
) {
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    let cacheFiles = files.filter { ["jpg", "jpeg", "png", "tiff"].contains($0.pathExtension.lowercased()) }
    let records: [(url: URL, modifiedAt: Date, bytes: Int)] = cacheFiles.map { url in
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (
            url,
            values?.contentModificationDate ?? .distantPast,
            values?.fileSize ?? 0
        )
    }

    let totalBytes = records.reduce(0) { $0 + $1.bytes }
    guard records.count > maxFiles || totalBytes > maxBytes else { return }

    var keptBytes = 0
    var keptCount = 0
    let sorted = records.sorted { lhs, rhs in
        if lhs.modifiedAt == rhs.modifiedAt {
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }
        return lhs.modifiedAt > rhs.modifiedAt
    }

    for record in sorted {
        if keptCount < maxFiles, keptBytes + record.bytes <= targetBytes {
            keptCount += 1
            keptBytes += record.bytes
        } else {
            try? FileManager.default.removeItem(at: record.url)
        }
    }
}
