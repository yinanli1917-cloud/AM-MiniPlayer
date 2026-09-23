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
// MARK: - Row Artwork Store
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Playlist-row artwork tiers: memory → disk (Apple tier, then web tier) →
/// single-flighted network fetch. Before this store, row-fetched artwork was
/// never cached (every row recreation refetched the network), duplicate
/// concurrent fetches raced the same key, and web-sourced art vanished on
/// memory eviction because only Apple-authoritative results reached disk.
/// Web results persist under a separate tier key so the main-page path
/// (which prefers Apple art via the grace-window race) never reads them.
@MainActor
public final class RowArtworkStore {
    public typealias FetchResult = (image: NSImage, appleAuthoritative: Bool)

    private let memoryRead: (NSString) -> NSImage?
    private let memoryWrite: (NSImage, NSString) -> Void
    private let diskRead: (NSString) -> NSImage?
    private let diskWrite: (NSImage, NSString) -> Void
    private let fetch: (String, String, String) async -> FetchResult?
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]

    public init(
        memoryRead: @escaping (NSString) -> NSImage?,
        memoryWrite: @escaping (NSImage, NSString) -> Void,
        diskRead: @escaping (NSString) -> NSImage?,
        diskWrite: @escaping (NSImage, NSString) -> Void,
        fetch: @escaping (String, String, String) async -> FetchResult?
    ) {
        self.memoryRead = memoryRead
        self.memoryWrite = memoryWrite
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.fetch = fetch
    }

    public static func webTierKey(_ key: NSString) -> NSString {
        "web|\(key)" as NSString
    }

    public func artwork(title: String, artist: String, album: String, key: NSString) async -> NSImage? {
        if let hit = memoryRead(key) { return hit }
        if let disk = diskRead(key) ?? diskRead(Self.webTierKey(key)) {
            memoryWrite(disk, key)
            return disk
        }
        if let running = inFlight[key] {
            return await running.value
        }
        // Unstructured on purpose (same idiom as MetadataResolver.SingleFlight):
        // an awaiting row's cancellation must never kill the fetch other rows
        // depend on, and a zero-awaiter completion still warms the caches.
        let task = Task<NSImage?, Never> { [memoryWrite, diskWrite, fetch] in
            guard let result = await fetch(title, artist, album) else { return nil }
            memoryWrite(result.image, key)
            diskWrite(result.image, result.appleAuthoritative ? key : Self.webTierKey(key))
            return result.image
        }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }
}

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
                    album: candidate.album,
                    priority: .background
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
        if !isPreview {
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
        }

        // ━━━ Path 1: API fetch — starts immediately, no SB queue dependency ━━━
        // API is provisional — if SB already applied for this generation, API result is discarded.
        // 🔑 Cancel previous API task to prevent pileup during rapid switching.
        artworkAPITask?.cancel()
        artworkAPITask = Task { [weak self] in
            guard let self else { return }
            if let result = await self.fetchArtworkResult(title: title, artist: artist, album: album, priority: .nowPlaying) {
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
                // 🔑 2026-09-22 proactive budget: the retry-after-miss is
                // skipped outright only while the circuit breaker is open —
                // now-playing already got its one storefront in the initial
                // attempt above and gets nothing else while the host is
                // actively rejecting us, so there's no point spending a
                // whole extra NetEase/Deezer/MusicKit race on a retry too.
                // A merely-empty token bucket is NOT a reason to skip the
                // retry anymore (2026-09-22 sixth round): the round function
                // itself now WAITS (bounded, abandonable) for the next
                // token instead of failing immediately, so "0 tokens right
                // now" no longer reliably predicts "this retry can't work".
                let breakerOpen = Self.ArtworkITunesCircuitBreaker.shared.isOpen()
                if breakerOpen {
                    self.logToFile("🎨 [API] retry skipped (circuit breaker open)")
                } else {
                    await self.retryArtworkFetch(persistentID: persistentID, title: title, artist: artist, album: album, generation: generation)
                }
                // After retry returns (or was skipped), if still nothing, fall back to placeholder.
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
        if !isPreview {
            artworkQueue.async { [weak self] in
                guard let self = self else { return }
                defer { DispatchQueue.main.async { self.lastArtworkQueueHeartbeat = Date() } }

                // NEVER fall back to musicApp — accessing the same SBApplication from two
                // queues concurrently corrupts AppleEvent state (EXC_BAD_ACCESS crash).
                let app: SBApplication
                if let existing = self.artworkApp {
                    app = existing
                } else if let fresh = SBApplication(bundleIdentifier: "com.apple.Music") {
                    self.artworkApp = fresh
                    app = fresh
                } else {
                    return
                }
                guard app.isRunning else { return }
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
                } else {
                    // 🔑 Structurally expected for streamed/radio tracks: `artworks.count == 0`
                    // for a URL track, so extractArtwork returns nil with no exception. This
                    // branch used to be silent (research/diagnosis-2026-09-22-radio-artwork.md
                    // Mode A2) — log it so a real SB timeout/crash is distinguishable from the
                    // normal "no embedded artwork" case in day-to-day captures.
                    self.logToFile("🎨 [SB] no image (0 artworks or timeout)")
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
    @MainActor
    public func fetchMusicKitArtwork(title: String, artist: String, album: String) async -> NSImage? {
        guard let key = artworkMetadataCacheKey(title: title, artist: artist, album: album) else {
            return await fetchArtworkResult(title: title, artist: artist, album: album, priority: .background)?.image
        }
        return await rowArtworkStore.artwork(title: title, artist: artist, album: album, key: key)
    }

    @MainActor
    func makeRowArtworkStore() -> RowArtworkStore {
        RowArtworkStore(
            memoryRead: { [unowned self] key in artworkCache.object(forKey: key) },
            memoryWrite: { [unowned self] image, key in
                artworkCache.setObject(image, forKey: key, cost: Self.imageCacheCost(image))
            },
            diskRead: { [unowned self] key in getDiskCachedArtwork(for: key) },
            diskWrite: { [unowned self] image, key in storeDiskCachedArtwork(image, for: key) },
            fetch: { [weak self] title, artist, album in
                guard let self,
                      let result = await self.fetchArtworkResult(title: title, artist: artist, album: album, priority: .background) else {
                    return nil
                }
                return (result.image, result.source.isAppleAuthoritative)
            }
        )
    }

    private struct ArtworkFetchResult {
        let image: NSImage
        let source: ArtworkSource
    }

    /// `priority` is required (never defaulted) — see `ArtworkFetchPriority`.
    /// `fetchArtwork`'s now-playing path and `retryArtworkFetch` pass
    /// `.nowPlaying`; `preloadArtwork` and every playlist-row path
    /// (`makeRowArtworkStore`, `fetchMusicKitArtwork`) pass `.background`.
    private func fetchArtworkResult(title: String, artist: String, album: String, priority: ArtworkFetchPriority) async -> ArtworkFetchResult? {
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
                // nowPlaying: 3 storefronts race in parallel per round
                // (1.6s each, artworkITunesStorefrontTimeout) and round 2
                // (bracket-stripped title) only runs when round 1 is
                // unreliable everywhere — worst case ~3.2s of sequential
                // rounds WHEN TOKENS ARE AVAILABLE. 2026-09-22 sixth round:
                // when a round finds 0 tokens it now WAITS up to
                // artworkTokenWaitMaxSeconds (12s) instead of failing
                // immediately, so the outer ceiling for now-playing must
                // cover round1's wait + round2's wait + normal processing
                // (12+12+~3.2 ≈ 27.2s) — otherwise this very timeout would
                // cancel the wait (via Task.isCancelled, which
                // ArtworkTokenWaiter.live treats as "superseded") before a
                // token ever has a chance to arrive, silently neutering the
                // fix. background never waits (unchanged), so it stays
                // bounded well under either ceiling on the common path.
                let iTunesRaceTimeout: TimeInterval = priority == .nowPlaying
                    ? (2 * MusicController.artworkTokenWaitMaxSeconds + 3.2)
                    : 3.6
                if let img = await self.withArtworkTimeout(seconds: iTunesRaceTimeout, operation: {
                    await Self.fetchArtworkViaITunesAPI(title: title, artist: artist, album: album, priority: priority)
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - iTunes multi-storefront artwork (2026-09-22 radio content-gap fix)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // research/diagnosis-2026-09-22-radio-artwork.md found 10 "content gap"
    // radio tracks (up to 330s each with no real cover) whose iTunes search
    // never once passed a `country` param — which silently defaults to the
    // US storefront. `itunes.apple.com/search?country=CN` returns ZERO
    // results by design (Apple does not serve a CN storefront through this
    // API), and real curl testing (research/spec-2026-09-22-radio-artwork-
    // storefronts.md) showed every one of these tracks IS indexed under the
    // exact same English title+artist in the JP/TW/HK storefronts. Fix:
    // query a small fixed set of storefronts in parallel and keep the best
    // reliable match across all of them.

    /// One iTunes Search API storefront to query. `lang` asks non-US stores
    /// to answer in English so scoring still lines up against the (usually
    /// English) radio-reported title/artist — US already answers in English.
    struct ArtworkStorefront: Equatable {
        let country: String
        let lang: String?
    }

    /// Deliberately small and fixed — NOT a full storefront sweep. iTunes
    /// rate-limits after ~20-30 rapid requests (observed: non-JSON replies),
    /// and every radio-metadata example that failed under a bare US query
    /// (Gatsby Woman/Kingo Hamada, Who Are You?/Fujimaru Yoshino, Starlight
    /// Ballet/Piper, SHYNESS BOY/Anri, Misty/Johnny Mathis) resolved under
    /// JP or TW.
    ///
    /// HK dropped 2026-09-22 (coordinator review of that day's probes):
    /// TW and HK returned IDENTICAL rows for every track that was checked
    /// against both — Gatsby Woman, Who Are You?, Misty, Ripples, Starlight
    /// Ballet, Jellyfish. HK never contributed a match TW didn't already
    /// have, so it was pure extra request volume against a host with a
    /// tight, real rate limit (observed ~20-30 requests/~2 minutes, with a
    /// block lasting 20+ minutes and also taking down MetadataResolver's
    /// iTunes-backed lyrics metadata calls) — cutting it directly reduces
    /// worst-case fan-out from 4 to 3 storefronts per round with no loss of
    /// coverage seen so far.
    static let artworkITunesStorefronts: [ArtworkStorefront] = [
        ArtworkStorefront(country: "US", lang: nil),
        ArtworkStorefront(country: "JP", lang: "en_us"),
        ArtworkStorefront(country: "TW", lang: "en_us"),
    ]

    /// Per-storefront request timeout. Storefronts race in PARALLEL, so this
    /// is one round's wall-clock cost, not a sum — raised from the old 1.0s
    /// single-storefront timeout because round trips to itunes.apple.com
    /// from mainland China routinely exceed 1s.
    static let artworkITunesStorefrontTimeout: TimeInterval = 1.6

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Priority-aware fan-out + host-level circuit breaker (2026-09-22 follow-up)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Code review on the multi-storefront fix above found a regression: this
    // SAME `fetchArtworkResult` also serves playlist ROW artwork
    // (`makeRowArtworkStore`'s fetch closure, PlaylistView's
    // `fetchMusicKitArtwork` call) and `preloadArtwork`'s queue lookahead.
    // Every row used to cost ~1 iTunes request; now it fans out 4 in
    // PARALLEL. A cold ~20-row playlist can burst 80+ simultaneous requests,
    // and iTunes Search rate-limits (observed today: non-JSON rejections
    // after ~25 requests/minute) — a row storm can starve the now-playing
    // fetch and MetadataResolver's own iTunes-backed lyrics metadata calls.
    // Fix: thread an explicit priority through every call site (never
    // guessed from call stack), and trip a shared circuit breaker the
    // moment iTunes' own rate-limit signal appears.

    /// Explicit intent for an iTunes artwork fetch — set by the CALLER
    /// (`fetchArtwork` for now-playing, `preloadArtwork`/`makeRowArtworkStore`/
    /// `fetchMusicKitArtwork` for background), never inferred.
    enum ArtworkFetchPriority: CustomStringConvertible {
        /// The visible now-playing track. Worth the extra request volume —
        /// it's one track at a time, and the user is looking at it. Keeps
        /// the full parallel storefront fan-out.
        case nowPlaying
        /// Playlist rows / queue preload — potentially dozens of these fire
        /// close together. Storefronts are queried SEQUENTIALLY, stopping at
        /// the first reliable hit, so a row costs 1 in-flight iTunes request
        /// at a time (matching the pre-fix request profile on the common
        /// "first storefront has it" path) instead of 4 simultaneous ones.
        case background

        var description: String {
            switch self {
            case .nowPlaying: return "nowPlaying"
            case .background: return "background"
            }
        }
    }

    /// Host-level circuit breaker for itunes.apple.com artwork searches.
    /// Trips on iTunes' own rate-limit tell (HTTP 403/429, or a non-JSON
    /// body on an otherwise-successful response — research: "连续二三十次
    /// 请求后 iTunes 开始拒绝（返回非 JSON）"). While open, BACKGROUND
    /// fetches skip iTunes entirely; NOW-PLAYING still gets one storefront
    /// so the visible track keeps some chance at real art. Mirrors
    /// `RowArtworkNegativeCache`'s NSLock + injectable `now:` pattern
    /// (`RowArtworkFetchPolicy.swift`) so it's unit-testable with a fake
    /// clock — never a real sleep.
    final class ArtworkITunesCircuitBreaker: @unchecked Sendable {
        /// Long enough that a real rate-limit burst actually backs off,
        /// short enough that one transient rejection doesn't blind the app
        /// for the rest of the listening session.
        static let openDuration: TimeInterval = 45

        /// Process-wide default — every production call site shares this
        /// instance, since the rate limit is a property of the HOST, not of
        /// any one call site. Tests construct their own instance instead of
        /// touching this one, so test runs never leak breaker state into
        /// each other.
        static let shared = ArtworkITunesCircuitBreaker()

        private let lock = NSLock()
        private var openUntil: Date?

        init() {}

        func isOpen(now: Date = Date()) -> Bool {
            lock.withLock {
                guard let openUntil else { return false }
                return now < openUntil
            }
        }

        /// Trips (or extends) the breaker. Returns `true` only on the
        /// closed→open TRANSITION so callers log once per outage, not once
        /// per rate-limited request inside it.
        @discardableResult
        func trip(now: Date = Date()) -> Bool {
            lock.withLock {
                let wasOpen = openUntil.map { now < $0 } ?? false
                openUntil = now.addingTimeInterval(Self.openDuration)
                return !wasOpen
            }
        }

        /// Test seam.
        func openUntilForTesting() -> Date? {
            lock.withLock { openUntil }
        }
    }

    /// Shared token bucket for EVERY artwork-path itunes.apple.com request —
    /// storefront searches AND artwork image downloads alike — across BOTH
    /// priorities. The circuit breaker (above) is reactive: it only engages
    /// after iTunes has already rejected something. This is the proactive
    /// half: 2026-09-22 coordinator review found that even a clean run with
    /// no rejections yet — 5 radio-track skips in 30s, everything hitting on
    /// round 1 — already cost ~25 iTunes requests, against an observed
    /// ~20-30-requests-per-~2-minutes limit whose block lasts 20+ minutes
    /// and also takes down MetadataResolver's iTunes-backed lyrics metadata
    /// calls.
    ///
    /// Capacity/refill are chosen so the math ITSELF guarantees the
    /// coordinator's ≤12-requests-per-any-60s-window target, for ANY demand
    /// pattern whatsoever — not just the specific scenarios that happen to
    /// be tested. For a token bucket starting a window with a full charge,
    /// the maximum tokens obtainable across that window is `capacity +
    /// refillPerMinute` (the initial burst plus everything that regenerates
    /// during the window) — this is a hard mathematical ceiling, true
    /// regardless of how many priorities/consumers share the bucket or how
    /// their demand is shaped. `capacity 6 + refillPerMinute 6` → ceiling
    /// `12`, exactly the target, with zero slack to spare (the first tuning
    /// — capacity 8 + refill 12/min — had ceiling 20, which is why two
    /// sustained-demand scenarios exceeded 12 in the earlier round; see
    /// research/spec-2026-09-22-radio-artwork-storefronts.md "结果补充
    /// （四轮/五轮）" for both derivations). 6/min is also half the observed
    /// ~20-30-per-~2-minutes (~10-15/min) limit, leaving headroom for
    /// MetadataResolver, which is not yet wired to this bucket (follow-up,
    /// see spec).
    ///
    /// Same NSLock + injectable-`now:` shape as `ArtworkITunesCircuitBreaker`
    /// and `RowArtworkNegativeCache` — no real sleeps in tests.
    final class ArtworkITunesTokenBucket: @unchecked Sendable {
        /// Max instantaneous burst. See the capacity+refill=ceiling
        /// derivation above — this number is load-bearing for the ≤12/60s
        /// guarantee, not just a convenient round number.
        static let capacity: Double = 6
        /// Refill rate. 6/min = 1 token per 10s. Paired with `capacity`
        /// above so `capacity + refillPerMinute == 12` — the hard ceiling
        /// for requests in any 60-second window, by construction.
        static let refillPerMinute: Double = 6
        /// Tokens `.background` (playlist rows/preload) must always leave
        /// behind for `.nowPlaying` — a row storm must never starve the
        /// visible track's own cover.
        static let reserveForNowPlaying: Int = 3

        static let shared = ArtworkITunesTokenBucket()

        private let lock = NSLock()
        private var tokens: Double
        private var lastRefill: Date
        private let effectiveCapacity: Double

        /// `capacity` overrides the production default — ONLY for tests that
        /// are exercising something other than the budget itself (priority/
        /// breaker behavior predating this bucket) and want an effectively
        /// unlimited supply so token exhaustion never interferes. Budget
        /// tests (ArtworkTokenBucketBudgetTests) always use the default.
        init(now: Date = Date(), capacity: Double? = nil) {
            self.effectiveCapacity = capacity ?? Self.capacity
            self.tokens = self.effectiveCapacity
            self.lastRefill = now
        }

        private func refillLocked(now: Date) {
            let elapsed = now.timeIntervalSince(lastRefill)
            guard elapsed > 0 else { return }
            let perSecond = Self.refillPerMinute / 60.0
            tokens = min(effectiveCapacity, tokens + elapsed * perSecond)
            lastRefill = now
        }

        /// Whole tokens available right now, after refilling to `now`.
        /// Read-only — does not consume anything.
        func available(now: Date = Date()) -> Int {
            lock.withLock {
                refillLocked(now: now)
                return Int(tokens.rounded(.down))
            }
        }

        /// Atomically takes up to `maxCount` whole tokens — never more than
        /// are actually available — and returns how many it took. One
        /// locked read-and-consume operation, so concurrent callers sharing
        /// this bucket (now-playing + every playlist row) can't race a
        /// separate "check" against a separate "consume". Used for
        /// now-playing's fan-out width: `width = reserve(upTo:
        /// storefronts.count)` IS "min(storefront count, available tokens,
        /// at least 1 if any token)" — `upTo` is always ≥1 (storefront
        /// count), so the result is 0 only when there truly are 0 tokens.
        func reserve(upTo maxCount: Int, now: Date = Date()) -> Int {
            guard maxCount > 0 else { return 0 }
            return lock.withLock {
                refillLocked(now: now)
                let whole = Int(tokens.rounded(.down))
                let taken = min(maxCount, whole)
                tokens -= Double(taken)
                return taken
            }
        }

        /// Atomically consumes exactly `count` tokens ONLY IF at least
        /// `keepAtLeast` would remain afterward. Used for (a) background's
        /// per-request reserve-for-now-playing check (`keepAtLeast:
        /// reserveForNowPlaying`) and (b) a single-token spend with no
        /// reserve (`keepAtLeast: 0`) — e.g. an image download, or
        /// now-playing's one storefront while the breaker is open.
        @discardableResult
        func tryReserve(_ count: Int, keepAtLeast: Int = 0, now: Date = Date()) -> Bool {
            guard count > 0 else { return true }
            return lock.withLock {
                refillLocked(now: now)
                guard tokens - Double(count) >= Double(keepAtLeast) else { return false }
                tokens -= Double(count)
                return true
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Now-playing token wait (2026-09-22 sixth-round fix)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // The 5-skip trace above (research/spec-2026-09-22-radio-artwork-
    // storefronts.md "结果补充（五轮）") showed round-1 width degrading to
    // ZERO storefronts on some skips, not just one — a track that gets 0
    // width and is never skipped past (the user actually lands on it and
    // keeps listening) would silently NEVER get an iTunes artwork attempt.
    // Fix: a now-playing round that finds 0 whole tokens WAITS for the next
    // one (bounded) instead of giving up immediately — but the wait is
    // abandoned instantly if superseded, so a track the user skips PAST
    // while it's waiting spends nothing, and whichever token arrives goes
    // to whichever track is actually current when it does.

    /// Ceiling on how long a now-playing fetch will wait for the next
    /// token. At 1 token per 10s (refillPerMinute 6), a wait that starts
    /// from empty needs at most ~10s for the next token — 12s leaves a
    /// couple of seconds of polling slack.
    static let artworkTokenWaitMaxSeconds: TimeInterval = 12
    /// Poll granularity while waiting.
    static let artworkTokenWaitPollInterval: TimeInterval = 1

    /// Injectable wait mechanism — NOT used by `.background` at all (its
    /// behavior is unchanged: skip immediately when the reserve would be
    /// breached). `isSuperseded` is the generation check: production wires
    /// it to `Task.isCancelled`, which nanoPod's existing architecture
    /// already flips the moment a new track change cancels the in-flight
    /// `artworkAPITask` (`fetchArtwork`'s Path 1) — cancelling the owning
    /// Task on every track change already IS declaring the previous
    /// fetch's generation superseded, so no separate generation counter
    /// needs to be threaded through these otherwise-pure functions. Tests
    /// inject their own `isSuperseded`/`tick` to drive this deterministically
    /// with a fake clock — no real sleeps.
    struct ArtworkTokenWaiter: Sendable {
        /// One poll step: advances time (sleeping for real in production)
        /// and returns the new "now" to re-check token availability against.
        var tick: @Sendable () async -> Date
        /// True the instant this wait must abandon.
        var isSuperseded: @Sendable () -> Bool

        static let live = ArtworkTokenWaiter(
            tick: {
                try? await Task.sleep(nanoseconds: UInt64(MusicController.artworkTokenWaitPollInterval * 1_000_000_000))
                return Date()
            },
            isSuperseded: { Task.isCancelled }
        )

        /// Abandons instantly, before ever ticking — the pre-fix "fail
        /// immediately on 0 tokens" behavior with zero ceremony. Tests that
        /// inject a fixed fake `now:` MUST use this (or their own
        /// fake-clock waiter) instead of `.live`: `.live.tick` returns the
        /// REAL wall-clock `Date()`, which — compared against a fake
        /// `now:` from a different epoch — silently corrupts the bucket's
        /// refill math (a decades-large apparent elapsed time) instead of
        /// producing a clean, obviously-wrong result.
        static let neverWait = ArtworkTokenWaiter(
            tick: { Date() },
            isSuperseded: { true }
        )
    }

    /// Polls `bucket` (via `waiter.tick`) until a now-playing round can
    /// afford at least 1 storefront, `waiter.isSuperseded()` fires, or
    /// `artworkTokenWaitMaxSeconds` elapses — whichever comes first. Checks
    /// supersession BEFORE each tick so an abandonment that happens between
    /// two ticks is caught at the very next opportunity, not after waiting
    /// out a whole extra poll interval.
    /// Returns the width found AND the `now` at which it was found (or the
    /// `now` the wait gave up at) — callers MUST use this returned `now` for
    /// everything downstream (the search itself, and critically the image
    /// download's own `tryReserve`), never the stale `startingAt` value.
    /// Using a stale `now` after waiting several ticks would make the image
    /// download's bucket check race against a `lastRefill` timestamp that's
    /// already moved PAST it (negative elapsed, silently skipped refill),
    /// starving the download of a token that legitimately regenerated
    /// during the wait.
    private static func waitForNowPlayingToken(
        storefrontCount: Int, bucket: ArtworkITunesTokenBucket, waiter: ArtworkTokenWaiter,
        startingAt: Date, roundLabel: String, term: String
    ) async -> (width: Int, now: Date) {
        let deadline = startingAt.addingTimeInterval(artworkTokenWaitMaxSeconds)
        var currentNow = startingAt
        while true {
            guard !waiter.isSuperseded() else {
                DebugLogger.log("Artwork", "🎨 [iTunes API][\(roundLabel)] wait for token abandoned — superseded '\(term)'")
                return (0, currentNow)
            }
            currentNow = await waiter.tick()
            let width = bucket.reserve(upTo: storefrontCount, now: currentNow)
            if width > 0 {
                DebugLogger.log("Artwork", "🎨 [iTunes API][\(roundLabel)] token became available after waiting — proceeding for '\(term)'")
                return (width, currentNow)
            }
            if currentNow >= deadline {
                DebugLogger.log("Artwork", "🎨 [iTunes API][\(roundLabel)] waited \(Int(artworkTokenWaitMaxSeconds))s for a token, still none — genuine miss for '\(term)'")
                return (0, currentNow)
            }
        }
    }

    /// iTunes' own rate-limit tell plus the standard HTTP codes for it. A
    /// generic decode failure on an otherwise-successful response IS this
    /// signal at this call site specifically because
    /// `ITunesArtworkTransport.live` only ever produces `.decodingFailed`
    /// when JSON parsing fails on a 2xx body — exactly what iTunes' HTML/
    /// plain-text rate-limit rejection page looks like here.
    static func isITunesRateLimitSignal(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPClient.HTTPError else { return false }
        switch httpError {
        case .httpError(let statusCode):
            return statusCode == 403 || statusCode == 429
        case .decodingFailed:
            return true
        default:
            return false
        }
    }

    /// Puts whatever storefronts `LanguageUtils.inferRegions` guesses for
    /// this title/artist first (in ITS order), keeping the rest of
    /// `artworkITunesStorefronts` in their declared order. Every storefront
    /// is still queried either way — this only decides which one wins a
    /// same-score tie in `selectBestITunesArtwork`. Pure and unit-testable
    /// without touching `MetadataResolver` (which just forwards to the same
    /// `LanguageUtils` call).
    static func orderedArtworkStorefronts(title: String, artist: String) -> [ArtworkStorefront] {
        let inferred = LanguageUtils.inferRegions(title: title, artist: artist)
        guard !inferred.isEmpty else { return artworkITunesStorefronts }
        let byCountry = Dictionary(uniqueKeysWithValues: artworkITunesStorefronts.map { ($0.country, $0) })
        var ordered: [ArtworkStorefront] = []
        for code in inferred {
            if let storefront = byCountry[code], !ordered.contains(storefront) {
                ordered.append(storefront)
            }
        }
        for storefront in artworkITunesStorefronts where !ordered.contains(storefront) {
            ordered.append(storefront)
        }
        return ordered
    }

    /// Removes every `(...)`/`[...]` segment from a title:
    /// "Gatsby Woman (2020 Remastered)" → "Gatsby Woman",
    /// "Who Are You? (DJ Version) [2022 Remaster]" → "Who Are You?".
    /// Generic — no keyword allowlist. A radio version/remaster/DJ-edit tag
    /// in the title is exactly what the plain catalog entry omits, and
    /// hand-enumerating every such tag string is the banned whitelist
    /// pattern (`.claude/rules/banned-patterns.md`).
    static func stripBracketedTitleSegments(_ title: String) -> String {
        var result = ""
        var depth = 0
        for ch in title {
            switch ch {
            case "(", "[": depth += 1
            case ")", "]": if depth > 0 { depth -= 1 }
            default: if depth == 0 { result.append(ch) }
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Cross-storefront candidate selection: scores every candidate from
    /// every storefront with the SAME `scoreArtworkCandidate` logic already
    /// used for every other source, then keeps the single highest-scoring
    /// RELIABLE one. Ties (equal `total`) keep whichever candidate was seen
    /// FIRST — callers pass storefronts in `orderedArtworkStorefronts`'s
    /// order, so a same-score tie prefers the region-inferred storefront.
    /// Pure — no network, no image decoding — so it is the direct unit-test
    /// surface for the whole multi-storefront fix.
    static func selectBestITunesArtwork(
        title: String, artist: String, album: String,
        storefrontResults: [(country: String, results: [[String: Any]])]
    ) -> (country: String, artworkUrlString: String, trackName: String, artistName: String, collectionName: String)? {
        var best: (country: String, url: String, trackName: String, artistName: String, collectionName: String, score: Int)?
        for (country, results) in storefrontResults {
            for r in results {
                guard let artworkUrlString = r["artworkUrl100"] as? String else { continue }
                let rArtist = r["artistName"] as? String ?? ""
                let rAlbum = r["collectionName"] as? String ?? ""
                let rTrack = r["trackName"] as? String ?? ""
                let score = scoreArtworkCandidate(
                    title: title, artist: artist, album: album,
                    candidateTitle: rTrack, candidateArtist: rArtist, candidateAlbum: rAlbum
                )
                guard score.isReliable else { continue }
                if best == nil || score.total > best!.score {
                    let highRes = artworkUrlString.replacingOccurrences(of: "100x100", with: "300x300")
                    best = (country, highRes, rTrack, rArtist, rAlbum, score.total)
                }
            }
        }
        guard let best else { return nil }
        return (best.country, best.url, best.trackName, best.artistName, best.collectionName)
    }

    /// Injectable transport for the iTunes multi-storefront search — the
    /// seam that makes `fetchArtworkViaITunesAPI` reproducible without a
    /// real network call, following the closure-injection idiom already
    /// used by `RowArtworkStore`. `search` returns `.success([])` for a
    /// genuine empty result and `.failure` for anything that means "we
    /// don't actually know" (transport error, non-JSON rate-limit reply,
    /// decode failure) so the per-storefront log line can tell the two
    /// apart (research Mode F: today's code cannot).
    struct ITunesArtworkTransport: Sendable {
        var search: @Sendable (_ term: String, _ storefront: ArtworkStorefront) async -> Result<[[String: Any]], Error>
        var fetchImageData: @Sendable (_ url: URL) async -> Data?

        static let live = ITunesArtworkTransport(
            search: { term, storefront in
                guard let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    return .success([])
                }
                var urlString = "https://itunes.apple.com/search?term=\(encodedTerm)&media=music&entity=song&limit=15&country=\(storefront.country)"
                if let lang = storefront.lang {
                    urlString += "&lang=\(lang)"
                }
                guard let url = URL(string: urlString) else { return .success([]) }
                do {
                    let (data, _) = try await HTTPClient.getData(
                        url: url, headers: [:], timeout: MusicController.artworkITunesStorefrontTimeout, retry: false
                    )
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let results = json["results"] as? [[String: Any]] else {
                        return .failure(HTTPClient.HTTPError.decodingFailed)
                    }
                    return .success(results)
                } catch {
                    return .failure(error)
                }
            },
            fetchImageData: { url in
                try? await HTTPClient.getData(url: url, timeout: 1.0, retry: false).0
            }
        )
    }

    /// iTunes Search API — multi-storefront race, generic bracket-strip
    /// fallback. Round 1 queries every storefront with "title artist"; only
    /// if EVERY storefront comes back unreliable does round 2 retry with
    /// version/remaster tags stripped from the title (still multi-
    /// storefront). The old "artist title" word-swap and "title only"
    /// strategies are dropped: they were the large-fanout, low-yield
    /// strategies research flagged as wasted requests, and their job
    /// (matching despite a title/artist variant) is already covered by
    /// `scoreArtworkCandidate`'s partial-match scoring across 4 storefronts
    /// worth of real candidates instead of 1 storefront worth of reordered
    /// query strings.
    ///
    /// `priority` is REQUIRED, not defaulted: it decides parallel-fan-out
    /// (now-playing) vs sequential-stop-at-first-hit (background rows/
    /// preload), and must come from the caller's own intent, never a guess.
    static func fetchArtworkViaITunesAPI(
        title: String, artist: String, album: String,
        priority: ArtworkFetchPriority,
        transport: ITunesArtworkTransport = .live,
        breaker: ArtworkITunesCircuitBreaker = .shared,
        bucket: ArtworkITunesTokenBucket = .shared,
        now: Date = Date(),
        waiter: ArtworkTokenWaiter = .live
    ) async -> NSImage? {
        await fetchArtworkViaITunesAPIDetailed(
            title: title, artist: artist, album: album,
            priority: priority, transport: transport, breaker: breaker, bucket: bucket, now: now, waiter: waiter
        )?.image
    }

    /// A resolved iTunes match with the matched catalog metadata attached —
    /// used by the live acceptance eval (`NANOPOD_LIVE_ARTWORK_EVAL=1`) to
    /// record which storefront won and whether the matched trackName/
    /// artistName is actually the requested song (a wrong match is worse
    /// than no match). Production code only ever consumes `.image`
    /// (`fetchArtworkViaITunesAPI` above); this struct exists so that
    /// verification never has to re-derive network/matching logic.
    struct ITunesArtworkMatch {
        let image: NSImage
        let country: String
        let trackName: String
        let artistName: String
        let collectionName: String
        let round: String
    }

    /// `now` is a single snapshot reused for every token/breaker check made
    /// by this ONE call (round 1, round 2, the image download) — real
    /// elapsed network time within a single track's fetch is a couple of
    /// seconds at most (well under one refill tick at 12/min), so treating
    /// it as instantaneous is the conservative (worst-case-leaning) choice,
    /// and it's what makes the fake-clock budget tests in
    /// ArtworkTokenBucketBudgetTests exact rather than approximate.
    static func fetchArtworkViaITunesAPIDetailed(
        title: String, artist: String, album: String,
        priority: ArtworkFetchPriority,
        transport: ITunesArtworkTransport = .live,
        breaker: ArtworkITunesCircuitBreaker = .shared,
        bucket: ArtworkITunesTokenBucket = .shared,
        now: Date = Date(),
        waiter: ArtworkTokenWaiter = .live
    ) async -> ITunesArtworkMatch? {
        let primaryTerm = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        if let match = await fetchArtworkViaITunesAPIRound(
            term: primaryTerm, title: title, artist: artist, album: album,
            transport: transport, roundLabel: "round1", priority: priority,
            breaker: breaker, bucket: bucket, now: now, waiter: waiter
        ) {
            return match
        }

        // Hard override: while the breaker is open, now-playing gets round 1
        // (one storefront, above) and NOTHING else — never spend more of a
        // scarce, actively-rejecting host's budget on a second round or the
        // caller's retry-after-miss, no matter how many tokens remain.
        if priority == .nowPlaying, breaker.isOpen(now: now) {
            DebugLogger.log("Artwork", "🎨 [iTunes API] 全部店面失败: '\(title)' by '\(artist)' (\(priority), breaker open — round1 only)")
            return nil
        }

        let strippedTitle = stripBracketedTitleSegments(title)
        let secondaryTerm = "\(strippedTitle) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !strippedTitle.isEmpty,
              strippedTitle.caseInsensitiveCompare(title) != .orderedSame,
              secondaryTerm != primaryTerm else {
            DebugLogger.log("Artwork", "🎨 [iTunes API] 全部店面失败: '\(title)' by '\(artist)' (\(priority))")
            return nil
        }
        // Round 2 is naturally token-gated: fetchArtworkViaITunesAPIRound's
        // own reserve/tryReserve calls below return 0/false and it returns
        // nil immediately (no requests) when the bucket can't afford it —
        // no separate pre-check needed here. For now-playing, a 0-token
        // round 2 will also WAIT (bounded, abandonable) exactly like round 1.
        if let match = await fetchArtworkViaITunesAPIRound(
            term: secondaryTerm, title: strippedTitle, artist: artist, album: album,
            transport: transport, roundLabel: "round2(stripped)", priority: priority,
            breaker: breaker, bucket: bucket, now: now, waiter: waiter
        ) {
            return match
        }
        DebugLogger.log("Artwork", "🎨 [iTunes API] 全部店面失败: '\(title)' by '\(artist)' (\(priority))")
        return nil
    }

    private static func fetchArtworkViaITunesAPIRound(
        term: String, title: String, artist: String, album: String,
        transport: ITunesArtworkTransport, roundLabel: String,
        priority: ArtworkFetchPriority, breaker: ArtworkITunesCircuitBreaker,
        bucket: ArtworkITunesTokenBucket, now: Date, waiter: ArtworkTokenWaiter
    ) async -> ITunesArtworkMatch? {
        guard !term.isEmpty else { return nil }
        var storefronts = orderedArtworkStorefronts(title: title, artist: artist)

        if breaker.isOpen(now: now) {
            switch priority {
            case .background:
                DebugLogger.log("Artwork", "🎨 [iTunes API][\(roundLabel)] circuit breaker open — skipping background fetch for '\(term)'")
                return nil
            case .nowPlaying:
                // Still worth ONE storefront for the visible track — just not
                // a full fan-out while the host is actively rejecting us.
                storefronts = Array(storefronts.prefix(1))
            }
        }

        // Advances past `now` ONLY if a now-playing wait actually ticked the
        // clock forward — everything downstream (the search race, and
        // critically the image download's own token check) MUST use this,
        // never the original stale `now`, or the image download's bucket
        // check races against a `lastRefill` already moved past it.
        var effectiveNow = now

        let storefrontResults: [(country: String, results: [[String: Any]])]
        switch priority {
        case .nowPlaying:
            // Fan-out width = min(storefront count, available tokens, at
            // least 1 if any token) — `reserve(upTo:)` IS this formula:
            // `upTo` is always ≥1, so it returns 0 only when there are
            // truly 0 tokens, and otherwise never exceeds either bound.
            var width = bucket.reserve(upTo: storefronts.count, now: now)
            if width == 0 {
                // Generic fix: whichever track the user is actually
                // LISTENING to (never skipped past) must not be silently
                // starved just because it happened to land between refill
                // ticks — wait for the next token instead of giving up.
                // Abandoned instantly if superseded (see ArtworkTokenWaiter).
                let waited = await waitForNowPlayingToken(
                    storefrontCount: storefronts.count, bucket: bucket, waiter: waiter,
                    startingAt: now, roundLabel: roundLabel, term: term
                )
                width = waited.width
                effectiveNow = waited.now
            }
            guard width > 0 else {
                return nil
            }
            let selected = Array(storefronts.prefix(width))
            storefrontResults = await searchStorefrontsInParallel(
                term: term, storefronts: selected, transport: transport,
                roundLabel: roundLabel, breaker: breaker, now: effectiveNow
            )
        case .background:
            storefrontResults = await searchStorefrontsSequentially(
                term: term, title: title, artist: artist, album: album,
                storefronts: storefronts, transport: transport,
                roundLabel: roundLabel, breaker: breaker, bucket: bucket, now: now
            )
        }

        guard let winner = selectBestITunesArtwork(
            title: title, artist: artist, album: album, storefrontResults: storefrontResults
        ) else {
            return nil
        }
        guard let url = URL(string: winner.artworkUrlString) else { return nil }

        // Image downloads spend from the SAME shared budget as searches.
        // Background still respects the now-playing reserve here too.
        let imageReserve = priority == .background ? ArtworkITunesTokenBucket.reserveForNowPlaying : 0
        guard bucket.tryReserve(1, keepAtLeast: imageReserve, now: effectiveNow) else {
            DebugLogger.log("Artwork", "🎨 [iTunes API][\(roundLabel)] token bucket empty — skipping image download for '\(term)' (storefront=\(winner.country))")
            return nil
        }
        guard let imageData = await transport.fetchImageData(url),
              let image = NSImage(data: imageData) else {
            return nil
        }
        DebugLogger.log("Artwork", "🎨 [iTunes API] 命中: storefront=\(winner.country) via '\(term)' (\(roundLabel), \(priority))")
        return ITunesArtworkMatch(
            image: image, country: winner.country,
            trackName: winner.trackName, artistName: winner.artistName, collectionName: winner.collectionName,
            round: roundLabel
        )
    }

    /// NOW-PLAYING: every storefront (already sized to the reserved token
    /// width by the caller) races in parallel — one track at a time, worth
    /// the request volume for the visible cover.
    private static func searchStorefrontsInParallel(
        term: String, storefronts: [ArtworkStorefront], transport: ITunesArtworkTransport,
        roundLabel: String, breaker: ArtworkITunesCircuitBreaker, now: Date
    ) async -> [(country: String, results: [[String: Any]])] {
        await withTaskGroup(
            of: (country: String, outcome: Result<[[String: Any]], Error>).self
        ) { group in
            for storefront in storefronts {
                group.addTask {
                    (storefront.country, await transport.search(term, storefront))
                }
            }
            var collected: [(country: String, results: [[String: Any]])] = []
            for await (country, outcome) in group {
                switch outcome {
                case .success(let results):
                    DebugLogger.log("Artwork", results.isEmpty
                        ? "🎨 [iTunes API][\(country)][\(roundLabel)] empty '\(term)'"
                        : "🎨 [iTunes API][\(country)][\(roundLabel)] \(results.count) result(s) '\(term)'")
                    collected.append((country, results))
                case .failure(let error):
                    DebugLogger.log("Artwork", "🎨 [iTunes API][\(country)][\(roundLabel)] error (\(type(of: error))): \(error.localizedDescription)")
                    if isITunesRateLimitSignal(error), breaker.trip(now: now) {
                        DebugLogger.log("Artwork", "🎨 [iTunes API] rate-limit signal from \(country) — circuit breaker OPEN \(Int(ArtworkITunesCircuitBreaker.openDuration))s (background fetches will skip iTunes)")
                    }
                }
            }
            return collected
        }
    }

    /// BACKGROUND (playlist rows, preload): storefronts are queried ONE AT
    /// A TIME, stopping the moment any storefront yields a reliable
    /// candidate. Each request also spends a token ONLY IF doing so leaves
    /// at least `reserveForNowPlaying` behind — the moment that reserve
    /// would be breached, background stops trying more storefronts in THIS
    /// call (a row that stops early is picked up again later by
    /// `RowArtworkNegativeCache`'s existing backoff, not retried here).
    /// Also aborts immediately on a rate-limit signal, rather than
    /// exhausting the list into a host that's already rejecting.
    private static func searchStorefrontsSequentially(
        term: String, title: String, artist: String, album: String,
        storefronts: [ArtworkStorefront], transport: ITunesArtworkTransport,
        roundLabel: String, breaker: ArtworkITunesCircuitBreaker,
        bucket: ArtworkITunesTokenBucket, now: Date
    ) async -> [(country: String, results: [[String: Any]])] {
        var collected: [(country: String, results: [[String: Any]])] = []
        for storefront in storefronts {
            guard bucket.tryReserve(1, keepAtLeast: ArtworkITunesTokenBucket.reserveForNowPlaying, now: now) else {
                DebugLogger.log("Artwork", "🎨 [iTunes API][\(storefront.country)][\(roundLabel)][seq] token bucket at now-playing reserve — skipping remaining background storefronts for '\(term)'")
                break
            }
            let outcome = await transport.search(term, storefront)
            switch outcome {
            case .success(let results):
                DebugLogger.log("Artwork", results.isEmpty
                    ? "🎨 [iTunes API][\(storefront.country)][\(roundLabel)][seq] empty '\(term)'"
                    : "🎨 [iTunes API][\(storefront.country)][\(roundLabel)][seq] \(results.count) result(s) '\(term)'")
                collected.append((storefront.country, results))
                if selectBestITunesArtwork(title: title, artist: artist, album: album, storefrontResults: collected) != nil {
                    return collected
                }
            case .failure(let error):
                DebugLogger.log("Artwork", "🎨 [iTunes API][\(storefront.country)][\(roundLabel)][seq] error (\(type(of: error))): \(error.localizedDescription)")
                if isITunesRateLimitSignal(error) {
                    if breaker.trip(now: now) {
                        DebugLogger.log("Artwork", "🎨 [iTunes API] rate-limit signal from \(storefront.country) — circuit breaker OPEN \(Int(ArtworkITunesCircuitBreaker.openDuration))s (background fetches will skip iTunes)")
                    }
                    return collected
                }
            }
        }
        return collected
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

    // iTunes Search API artwork fetching moved to the static, transport-
    // injectable `fetchArtworkViaITunesAPI` above (multi-storefront fix,
    // 2026-09-22).

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

    /// A late artwork result must not replace an already-applied
    /// Apple-authoritative image for the same generation: the replacement is
    /// visually identical catalog art, but the new NSImage instance replays
    /// the pointer-keyed background crossfade (mid-song "whole page refresh").
    static func shouldDropLateArtworkResult(
        source: ArtworkSource,
        appleAppliedForGeneration: Bool
    ) -> Bool {
        guard appleAppliedForGeneration else { return false }
        switch source {
        case .sb, .playbackSession, .musicKit, .iTunes, .web:
            return true
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

        // Once an Apple-authoritative image is applied for this generation,
        // EVERY later result is dropped — including the SB straggler, which
        // used to land 1-2s after the iTunes race winner and replay the full
        // background crossfade with a visually identical image. Web results
        // never set the flag, so Apple sources still upgrade over web art.
        if Self.shouldDropLateArtworkResult(
            source: source,
            appleAppliedForGeneration: sbAppliedForGeneration == generation
        ) {
            logToFile("🎨 [\(source)] Apple artwork already applied for gen \(generation), discarding later result")
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

        if let result = await fetchArtworkResult(title: title, artist: artist, album: album, priority: .nowPlaying) {
            await applyArtworkIfCurrent(result.image, persistentID: persistentID, title: title, artist: artist, album: album, generation: generation, source: result.source)
            debugPrint("✅ [retryArtworkFetch] API retry success\n")
        } else {
            debugPrint("⚠️ [retryArtworkFetch] API retry failed for \(title)\n")
        }
    }

    /// Caches a row-resolved image under its persistentID (and, when given,
    /// its metadata key too) so `getCachedArtwork(persistentID:)` — the free
    /// first check every row does before touching any fetch tier — hits on
    /// the next mount. Public wrapper around the private disk/memory
    /// `cacheArtwork`, for PlaylistView's row to call after a last-resort
    /// ScriptingBridge lookup succeeds.
    func cacheRowArtworkByPersistentID(
        _ image: NSImage,
        persistentID: String,
        title: String = "",
        artist: String = "",
        album: String = ""
    ) {
        cacheArtwork(image, persistentID: persistentID, title: title, artist: artist, album: album, persistToDisk: false)
    }

    // Fetch artwork by persistentID using ScriptingBridge (for playlist items)
    public func fetchArtworkByPersistentID(persistentID: String) async -> NSImage? {
        guard !isPreview, !persistentID.isEmpty else { return nil }

        // 先检查缓存
        if let cached = artworkCache.object(forKey: persistentID as NSString) {
            return cached
        }

        // 🔑 Use dedicated artworkQueue — separate SB instance, won't block position polls.
        // NEVER fall back to musicApp: accessing the same SBApplication from both the artwork
        // queue and scriptingBridgeQueue concurrently corrupts AppleEvent state (EXC_BAD_ACCESS
        // SIGSEGV with pointer-auth failure during rapid track switching).
        let controller = WeakSendableReference(self)
        let image: NSImage? = await withCheckedContinuation { continuation in
            artworkQueue.async {
                guard let self = controller.value else {
                    continuation.resume(returning: nil)
                    return
                }
                let app: SBApplication
                if let existing = self.artworkApp {
                    app = existing
                } else if let fresh = SBApplication(bundleIdentifier: "com.apple.Music") {
                    self.artworkApp = fresh
                    app = fresh
                } else {
                    continuation.resume(returning: nil)
                    return
                }
                guard app.isRunning else {
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

func defaultArtworkDiskCacheDirectory() -> URL? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    return appSupport
        .appendingPathComponent("nanoPod", isDirectory: true)
        .appendingPathComponent("ArtworkCache", isDirectory: true)
}

func pruneDefaultArtworkDiskCacheOnUtilityQueue() {
    guard let directory = defaultArtworkDiskCacheDirectory() else { return }
    DispatchQueue.global(qos: .utility).async {
        pruneArtworkDiskCache(in: directory)
    }
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
