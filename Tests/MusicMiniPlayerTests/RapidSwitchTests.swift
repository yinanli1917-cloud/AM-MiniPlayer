//
//  RapidSwitchTests.swift
//  覆盖快速切歌 + 电台封面修复中新增的 3 个原语：
//    - SBTimeoutRunner: 硬超时释放阻塞 SB 调用
//    - OBJCCatch:        Swift 不可捕获的 NSException 转 nil
//    - artworkCacheKey:  统一缓存键（persistentID vs "radio:title|artist"）
//
//  说明：完整端到端流程依赖 Music.app + 网络，不可进 CI；此处只测新引入的
//  原语，它们是这次修复的正确性基石。
//

import XCTest
import Foundation
import SQLite3
@testable import MusicMiniPlayerCore
import ObjCSupport

final class RapidSwitchTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - SBTimeoutRunner
    // ------------------------------------------------------------------

    /// 快速完成的 block 应立即返回值。
    func testTimeoutRunnerReturnsValueOnFastBlock() {
        let start = Date()
        let result = SBTimeoutRunner.run(timeout: 1.0) { () -> Int? in
            return 42
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, 42)
        XCTAssertLessThan(elapsed, 0.2, "fast block should return immediately")
    }

    /// 超时的 block 必须在 timeout 窗口内返回 nil，不能无限阻塞调用方。
    ///
    /// 🔑 `ZZZ` prefix forces this test to run LAST alphabetically within
    /// this class. The queue is now SERIAL (to prevent concurrent AE crash),
    /// so a 5-second hung block would otherwise block tests that come after
    /// it alphabetically (see rapid-switch SBTimeoutRunner.swift comment).
    /// Running this test last means its hung background block can drain
    /// without delaying other assertions.
    func testTimeoutRunnerZZZReturnsNilOnHangingBlock() {
        let start = Date()
        let result = SBTimeoutRunner.run(timeout: 0.3) { () -> Int? in
            Thread.sleep(forTimeInterval: 5.0)  // 模拟卡死的 SB IPC
            return 42
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "hanging block must time out to nil")
        XCTAssertLessThan(elapsed, 1.0, "caller must release within timeout window (got \(elapsed)s)")
    }

    /// block 返回 nil 本身不是超时 —— 调用方应拿到 nil 且快速返回。
    func testTimeoutRunnerPassesThroughNilResult() {
        let start = Date()
        let result = SBTimeoutRunner.run(timeout: 1.0) { () -> Int? in return nil }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.2)
    }

    /// 并发多个快速调用共享同一 worker queue 不应互相阻塞。
    func testTimeoutRunnerHandlesConcurrentCalls() {
        let group = DispatchGroup()
        var results: [Int] = []
        let lock = NSLock()

        for i in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                if let v: Int = SBTimeoutRunner.run(timeout: 1.0, { i }) {
                    lock.lock(); results.append(v); lock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2.0), .success)
        XCTAssertEqual(results.sorted(), Array(0..<10))
    }

    /// A hung metadata lane must not block an independent position-poll lane.
    /// This protects lyric timing from playlist/artwork ScriptingBridge stalls.
    func testTimeoutRunnerLaneIsolationBypassesHungLane() {
        DispatchQueue.global().async {
            let _: Int? = SBTimeoutRunner.run(timeout: 0.2, lane: "test-hung-metadata") {
                Thread.sleep(forTimeInterval: 3.0)
                return 1
            }
        }

        Thread.sleep(forTimeInterval: 0.05)
        let start = Date()
        let result: Int? = SBTimeoutRunner.run(timeout: 0.5, lane: "test-position-poll") {
            return 2
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, 2)
        XCTAssertLessThan(elapsed, 0.2, "independent lanes should not wait behind a hung lane")
    }

    func testPositionPollTimeoutCooldownBacksOffRepeatedTimeouts() {
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 1), 12.0)
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 2), 30.0)
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 3), 90.0)
        XCTAssertEqual(MusicController.positionPollTimeoutCooldown(forStreak: 10), 90.0)
        XCTAssertEqual(MusicController.positionPollFallbackMinInterval, 20.0)
    }

    func testProductionScriptingBridgeTimeoutCallsUseExplicitLanes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "Sources/MusicMiniPlayerCore/Services/MusicController.swift",
            "Sources/MusicMiniPlayerCore/Services/MusicController+Playback.swift",
            "Sources/MusicMiniPlayerCore/Services/MusicController+Artwork.swift"
        ]

        var offenders: [String] = []
        for path in files {
            let url = repoRoot.appendingPathComponent(path)
            let text = try String(contentsOf: url, encoding: .utf8)
            for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated()
            where line.contains("SBTimeoutRunner.run(timeout:") && !line.contains("lane:") {
                offenders.append("\(path):\(lineIndex + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Production ScriptingBridge calls must choose an explicit timeout lane to avoid shared-lane starvation: \(offenders.joined(separator: "; "))"
        )
    }

    func testMusicTrackClassNameMapsAppleEventDescriptorCodes() {
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'cURL'>"), "URL track")
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'cFlT'>"), "file track")
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'cShT'>"), "shared track")
        XCTAssertEqual(MusicController.musicTrackClassName(fromObjectClassDescription: "<NSAppleEventDescriptor: 'abcd'>"), "")
    }

    // ------------------------------------------------------------------
    // MARK: - OBJCCatch
    // ------------------------------------------------------------------

    /// 正常执行的 block 应返回 nil（表示无异常）。
    func testObjCCatchReturnsNilOnNormalExecution() {
        var ran = false
        let ex = OBJCCatch { ran = true }
        XCTAssertNil(ex)
        XCTAssertTrue(ran)
    }

    /// NSException 必须被捕获并返回，而不是炸掉进程。
    /// 这是 SBElementArray 迭代在 Music.app 中途变动时的真实崩溃模式。
    func testObjCCatchCapturesNSException() {
        let ex = OBJCCatch {
            NSException(
                name: .rangeException,
                reason: "simulated mid-iteration mutation",
                userInfo: nil
            ).raise()
        }
        XCTAssertNotNil(ex)
        XCTAssertEqual(ex?.name, .rangeException)
        XCTAssertEqual(ex?.reason, "simulated mid-iteration mutation")
    }

    // ------------------------------------------------------------------
    // MARK: - artworkCacheKey
    // ------------------------------------------------------------------

    /// 非空 persistentID → 直接用作 key（库内曲目保持原行为）
    func testCacheKeyUsesPersistentIDWhenNonEmpty() {
        let c = MusicController.shared
        let key = c.artworkCacheKey(persistentID: "ABC123", title: "Song", artist: "Artist")
        XCTAssertEqual(key, "ABC123" as NSString)
    }

    /// 空 persistentID → 返回 nil（电台不缓存，每次都重新拉取）
    /// 修复 commit: 之前用 "radio:title|artist" 作 key，导致多个不同歌曲
    /// 共享同一 title/artist 时命中过期封面。
    func testCacheKeyReturnsNilForEmptyPersistentID() {
        let c = MusicController.shared
        XCTAssertNil(c.artworkCacheKey(persistentID: "", title: "Song Name", artist: "Artist Name"))
        XCTAssertNil(c.artworkCacheKey(persistentID: "", title: "", artist: "A"))
        XCTAssertNil(c.artworkCacheKey(persistentID: "", title: "Song", artist: ""))
    }

    func testMetadataArtworkCacheKeyUsesTrackIdentityBeforePersistentIDBackfill() {
        let c = MusicController.shared
        let key = c.artworkMetadataCacheKey(title: "戀愛預告", artist: "Sandy Lamb", album: "My Lovely Legend")
        XCTAssertEqual(key, "meta:恋爱预告|sandy lamb|my lovely legend" as NSString)
        XCTAssertNil(c.artworkMetadataCacheKey(title: "", artist: "Sandy Lamb", album: "My Lovely Legend"))
        XCTAssertNil(c.artworkMetadataCacheKey(title: "戀愛預告", artist: "", album: "My Lovely Legend"))
        XCTAssertNil(c.artworkMetadataCacheKey(title: "戀愛預告", artist: "Sandy Lamb", album: ""))
    }

    func testMetadataArtworkCacheKeyAllowsURLTracksWhenAlbumDisambiguates() {
        let c = MusicController(preview: true)
        c.currentTrackIsURLTrack = true

        let key = c.artworkMetadataCacheKey(title: "Warm On a Cold Night", artist: "HONNE", album: "Warm On a Cold Night")

        XCTAssertEqual(key, "meta:warm on a cold night|honne|warm on a cold night" as NSString)
        XCTAssertNil(c.artworkMetadataCacheKey(title: "Warm On a Cold Night", artist: "HONNE", album: ""))
    }

    func testArtworkCacheMissKeepsPreviousArtworkBrieflyUntilReplacement() async throws {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Tout tout"
        c.currentArtist = "Miel De Montagne & Blasé"
        c.currentArtwork = NSImage(size: NSSize(width: 12, height: 12))
        c.currentArtworkIsPlaceholder = false
        c.appliedArtworkGeneration = 0
        let generation = c.incrementGeneration()

        c.fetchArtwork(
            for: "Tout tout",
            artist: "Miel De Montagne & Blasé",
            album: "Ouin Ouin Ouin (Deluxe Edition)",
            persistentID: "",
            generation: generation
        )

        XCTAssertNotNil(c.currentArtwork)
        XCTAssertNotEqual(c.appliedArtworkGeneration, generation)

        try await Task.sleep(nanoseconds: MusicController.retainedArtworkPlaceholderGraceNanoseconds + 250_000_000)

        XCTAssertNotNil(c.currentArtwork)
        XCTAssertEqual(c.appliedArtworkGeneration, generation)
        XCTAssertTrue(c.currentArtworkIsPlaceholder)
        XCTAssertFalse(c.hasAppliedRealArtwork(for: generation))
    }

    func testInitialPlaceholderDoesNotCountAsRealArtworkForGeneration() async throws {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Missing Cover"
        c.currentArtist = "Diagnostics"
        c.currentAlbum = "Debug Album"
        c.currentArtwork = nil
        c.currentArtworkIsPlaceholder = false
        let generation = c.incrementGeneration()

        c.fetchArtwork(
            for: "Missing Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            persistentID: "",
            generation: generation
        )

        XCTAssertNotNil(c.currentArtwork)
        XCTAssertEqual(c.appliedArtworkGeneration, generation)
        XCTAssertTrue(c.currentArtworkIsPlaceholder)
        XCTAssertFalse(c.hasAppliedRealArtwork(for: generation))

        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertTrue(c.currentArtworkIsPlaceholder)
        XCTAssertFalse(c.hasAppliedRealArtwork(for: generation))
    }

    func testWebArtworkApplyCachesMetadataKeyInMemory() async {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Airport in 10:30"
        c.currentArtist = "David Tao"
        c.currentAlbum = "David Tao"
        let generation = c.incrementGeneration()
        let image = NSImage(size: NSSize(width: 80, height: 80))

        await c.applyArtworkIfCurrent(
            image,
            persistentID: "",
            title: "Airport in 10:30",
            artist: "David Tao",
            album: "David Tao",
            generation: generation,
            source: .web
        )

        let key = c.artworkMetadataCacheKey(title: "Airport in 10:30", artist: "David Tao", album: "David Tao")
        XCTAssertNotNil(key)
        XCTAssertNotNil(c.artworkCache.object(forKey: key!))
    }

    func testAppleAuthoritativeArtworkCanReplaceWebFallbackForSameGeneration() async {
        let c = MusicController(preview: true)
        c.currentTrackTitle = "Late Apple Cover"
        c.currentArtist = "Diagnostics"
        c.currentAlbum = "Debug Album"
        let generation = c.incrementGeneration()
        let web = NSImage(size: NSSize(width: 80, height: 80))
        let apple = NSImage(size: NSSize(width: 120, height: 120))

        await c.applyArtworkIfCurrent(
            web,
            persistentID: "",
            title: "Late Apple Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            generation: generation,
            source: .web
        )
        await c.applyArtworkIfCurrent(
            apple,
            persistentID: "",
            title: "Late Apple Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            generation: generation,
            source: .playbackSession
        )

        XCTAssertEqual(c.currentArtwork?.size, NSSize(width: 120, height: 120))
        XCTAssertEqual(c.appliedArtworkGeneration, generation)
    }

    func testPlaybackSessionArtworkURLTrimsBinaryTailAfterConcreteImagePath() {
        let text = "title Unforgettable artist Nat King Cole https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/4e920b65-26fe-c608-d4a0-605cb1cfeca9/16UMGIM31150.rgb.jpg/800x800bb.jpg\u{fffd}\u{0005}more"

        let url = PlaybackSessionArtworkFetcher.firstAppleArtworkURL(in: text)

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/4e920b65-26fe-c608-d4a0-605cb1cfeca9/16UMGIM31150.rgb.jpg/800x800bb.jpg"
        )
    }

    func testPlaybackSessionArtworkURLNormalizesTemplatePath() {
        let text = #"{"artwork":{"url":"https:\/\/is1-ssl.mzstatic.com\/image\/thumb\/Music115\/v4\/3c\/0f\/75\/cover.jpg\/{w}x{h}bb.{f}"}}"#

        let url = PlaybackSessionArtworkFetcher.firstAppleArtworkURL(in: text)

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music115/v4/3c/0f/75/cover.jpg/800x800bb.jpg"
        )
    }

    func testPlaybackSessionArtworkTextMatchHandlesBinaryPayloadWithoutWholeBlobNormalization() {
        let binaryTail = String(repeating: "\u{fffd}\u{0005}\u{0000}", count: 2000)
        let text = "Plastic Love \u{0000} Palette:eillB https://is1-ssl.mzstatic.com/image/thumb/Music116/v4/ef/ea/df/cover.jpg/800x800bb.jpg\(binaryTail)"

        XCTAssertTrue(
            PlaybackSessionArtworkFetcher.textMatches(
                text,
                title: "Plastic Love",
                artist: "eill",
                album: "Palette"
            )
        )
    }

    func testPlaybackSessionArtworkTextMatchUsesLatinizedCJKArtistAlias() {
        let text = "REALIZE 孫燕姿 https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg"

        XCTAssertTrue(
            PlaybackSessionArtworkFetcher.textMatches(
                text,
                title: "Realize",
                artist: "Yanzi Sun",
                album: "My Desired Happiness"
            )
        )
    }

    func testPlaybackSessionArtworkTextMatchUsesPercentEncodedNativeTitle() {
        let text = #"{"url":"https:\/\/music.apple.com\/cn\/album\/%E9%9B%A8%E7%88%B1\/347295255?i=347295290","albumName":"Rainie & Love?","artistName":"Rainie Yang","artwork":{"url":"https:\/\/is1-ssl.mzstatic.com\/image\/thumb\/Music\/bc\/e0\/e5\/mzi.mzfgcpgj.jpg\/{w}x{h}bb.{f}"}}"#

        XCTAssertTrue(
            PlaybackSessionArtworkFetcher.textMatches(
                text,
                title: "雨愛",
                artist: "Rainie Yang",
                album: "Rainie & Love?"
            )
        )
    }

    func testPlaybackSessionArtworkPollsUntilArchiveAppears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-playback-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lookup = Task {
            await PlaybackSessionArtworkFetcher.latestArtworkURLPolling(
                title: "Lovers",
                artist: "Li Ronghao",
                album: "Lovers - Single",
                root: root,
                retryFor: 0.6,
                pollInterval: 0.05
            )
        }

        try await Task.sleep(nanoseconds: 120_000_000)
        try writePlaybackSessionArchive(
            root: root,
            payload: "Lovers Lovers - Single Li Ronghao https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4d/96/d6/cover.jpg/800x800bb.jpg"
        )

        let url = await lookup.value
        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music221/v4/4d/96/d6/cover.jpg/800x800bb.jpg"
        )
    }

    func testPlaybackSessionArtworkCacheReadsFilesystemBackedMusicUICache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanopod-artwork-cache-\(UUID().uuidString)")
        let fsRoot = root.appendingPathComponent("fsCachedData")
        try FileManager.default.createDirectory(at: fsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dbURL = root.appendingPathComponent("Cache.db")
        let fileName = "9E680B2E-C61A-459C-9D11-A3300AE98EE8"
        let expected = Data([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43])
        try expected.write(to: fsRoot.appendingPathComponent(fileName))
        try createMusicUICacheFixture(
            dbURL: dbURL,
            requestKey: "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg",
            fileName: fileName
        )

        let data = PlaybackSessionArtworkFetcher.cachedArtworkData(
            for: URL(string: "https://is1-ssl.mzstatic.com/image/thumb/Music126/v4/4e/92/0b/cover.rgb.jpg/800x800bb.jpg")!,
            cacheRoot: root
        )

        XCTAssertEqual(data, expected)
    }

    private func writePlaybackSessionArchive(root: URL, payload: String) throws {
        let archive = root.appendingPathComponent("IT-999999.playbackSessionArchive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let rawURL = archive.appendingPathComponent("contentItem.protobuf")
        try Data(payload.utf8).write(to: rawURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", rawURL.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let gzipped = output.fileHandleForReading.readDataToEndOfFile()
        try gzipped.write(to: archive.appendingPathComponent("contentItem.protobuf.gz"))
        try? FileManager.default.removeItem(at: rawURL)
    }

    private func createMusicUICacheFixture(dbURL: URL, requestKey: String, fileName: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE cfurl_cache_response(entry_ID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE, version INTEGER, hash_value INTEGER, storage_policy INTEGER, request_key TEXT UNIQUE, time_stamp NOT NULL DEFAULT CURRENT_TIMESTAMP, partition TEXT);
        CREATE TABLE cfurl_cache_receiver_data(entry_ID INTEGER PRIMARY KEY, isDataOnFS INTEGER, receiver_data BLOB);
        INSERT INTO cfurl_cache_response(entry_ID, request_key) VALUES (1, '\(requestKey)');
        INSERT INTO cfurl_cache_receiver_data(entry_ID, isDataOnFS, receiver_data) VALUES (1, 1, '\(fileName)');
        """
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, schema, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            XCTFail(message)
        }
    }

    func testArtworkBackgroundToneMapDarkensBrightArtwork() {
        let dark = ArtworkBackgroundToneMap.forLuminance(0.1)
        let mid = ArtworkBackgroundToneMap.forLuminance(0.45)
        let bright = ArtworkBackgroundToneMap.forLuminance(0.9)

        XCTAssertGreaterThan(bright.shadeOpacity, mid.shadeOpacity)
        XCTAssertGreaterThanOrEqual(bright.shadeOpacity, 0.25)
        XCTAssertLessThanOrEqual(bright.shadeOpacity, 0.36)
        XCTAssertGreaterThan(bright.textureDimmingOpacity, mid.textureDimmingOpacity)
        XCTAssertLessThanOrEqual(bright.textureDimmingOpacity, 0.14)
        XCTAssertGreaterThan(dark.liftOpacity, mid.liftOpacity)
        XCTAssertLessThanOrEqual(dark.liftOpacity, 0.075)
    }

    func testArtworkBackgroundToneMapUsesHighlightPressureNotJustAverage() {
        let flatMid = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.45,
            shadowLuminance: 0.36,
            highlightLuminance: 0.54,
            luminanceSpread: 0.18,
            averageSaturation: 0.10
        ))
        let whiteCover = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.62,
            shadowLuminance: 0.42,
            highlightLuminance: 0.98,
            luminanceSpread: 0.56,
            averageSaturation: 0.08
        ))

        XCTAssertGreaterThan(whiteCover.shadeOpacity, flatMid.shadeOpacity)
        XCTAssertGreaterThan(whiteCover.textureSaturation, flatMid.textureSaturation)
        XCTAssertLessThan(whiteCover.textureBrightness, flatMid.textureBrightness)
    }

    func testArtworkBackgroundToneMapCompressesOversaturatedArtwork() {
        let balancedRed = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.42,
            shadowLuminance: 0.24,
            highlightLuminance: 0.64,
            luminanceSpread: 0.40,
            averageSaturation: 0.35
        ))
        let oversaturatedRed = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.42,
            shadowLuminance: 0.24,
            highlightLuminance: 0.64,
            luminanceSpread: 0.40,
            averageSaturation: 0.95
        ))

        XCTAssertLessThan(oversaturatedRed.textureSaturation, balancedRed.textureSaturation)
        XCTAssertLessThanOrEqual(oversaturatedRed.textureSaturation, 0.92)
        XCTAssertLessThan(oversaturatedRed.textureContrast, balancedRed.textureContrast)
        XCTAssertGreaterThan(oversaturatedRed.textureDimmingOpacity, balancedRed.textureDimmingOpacity)
    }

    func testArtworkBackgroundToneMapLiftsDarkArtworkWithoutFlattening() {
        let mid = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.42,
            shadowLuminance: 0.24,
            highlightLuminance: 0.62,
            luminanceSpread: 0.38,
            averageSaturation: 0.45
        ))
        let dark = ArtworkBackgroundToneMap.forMetrics(ArtworkVisualMetrics(
            averageLuminance: 0.12,
            shadowLuminance: 0.04,
            highlightLuminance: 0.32,
            luminanceSpread: 0.28,
            averageSaturation: 0.45
        ))

        XCTAssertGreaterThan(dark.liftOpacity, mid.liftOpacity)
        XCTAssertGreaterThanOrEqual(dark.liftOpacity, 0.05)
        XCTAssertLessThanOrEqual(dark.liftOpacity, 0.075)
        XCTAssertGreaterThan(dark.textureBrightness, mid.textureBrightness)
        XCTAssertGreaterThanOrEqual(dark.textureContrast, 1.02)
    }

    // ------------------------------------------------------------------
    // MARK: - artwork candidate matching
    // ------------------------------------------------------------------

    func testArtworkCandidateRejectsTitleOnlyWrongArtist() {
        let score = MusicController.scoreArtworkCandidate(
            title: "Invisible", artist: "mei ehara", album: "Ampersands",
            candidateTitle: "Invisible", candidateArtist: "Uiro", candidateAlbum: "iro iro Case.2"
        )
        XCTAssertFalse(score.isReliable, "Title-only fallback must not accept artwork from a different artist/album")
    }

    func testArtworkCandidateAcceptsLocalizedAlbumMatch() {
        let score = MusicController.scoreArtworkCandidate(
            title: "我的寶貝", artist: "Lee Chih Ching", album: "Yin Shi Nan Nu",
            candidateTitle: "我的宝贝", candidateArtist: "李之勤", candidateAlbum: "飲食男女"
        )
        XCTAssertTrue(score.isReliable)
        XCTAssertGreaterThanOrEqual(score.total, 5)
    }

    // ------------------------------------------------------------------
    // MARK: - Apple Music API recent history
    // ------------------------------------------------------------------

    func testParseRecentTracksResponseMapsSongAndLibrarySongResources() throws {
        let json = """
        {
          "data": [
            {
              "id": "123456789",
              "type": "songs",
              "attributes": {
                "name": "Song A",
                "artistName": "Artist A",
                "albumName": "Album A",
                "durationInMillis": 185000
              }
            },
            {
              "id": "i.abcdef",
              "type": "library-songs",
              "attributes": {
                "name": "Song B",
                "artistName": "Artist B",
                "albumName": "Album B",
                "durationInMillis": 201500
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let tracks = MusicController.parseRecentTracksResponse(json)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].title, "Song A")
        XCTAssertEqual(tracks[0].artist, "Artist A")
        XCTAssertEqual(tracks[0].album, "Album A")
        XCTAssertEqual(tracks[0].persistentID, "am:123456789")
        XCTAssertEqual(tracks[0].duration, 185)
        XCTAssertEqual(tracks[1].persistentID, "am:i.abcdef")
        XCTAssertEqual(tracks[1].duration, 201.5)
    }

    func testSameTrackIdentityDetectsQueueReorder() {
        let original = [
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.0),
            (title: "B", artist: "Artist", album: "Album", persistentID: "2", duration: 181.0),
        ]
        let reordered = [
            (title: "B", artist: "Artist", album: "Album", persistentID: "2", duration: 181.0),
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.0),
        ]

        XCTAssertFalse(MusicController.sameTrackIdentity(original, reordered))
    }

    func testSameTrackIdentityIgnoresTinyDurationDrift() {
        let original = [
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.0),
        ]
        let drifted = [
            (title: "A", artist: "Artist", album: "Album", persistentID: "1", duration: 180.05),
        ]

        XCTAssertTrue(MusicController.sameTrackIdentity(original, drifted))
    }

    func testQueueSnapshotAppliesOnlyWhenQueueAndTrackGenerationsMatch() {
        XCTAssertTrue(MusicController.shouldApplyQueueSnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldApplyQueueSnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 4,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldApplyQueueSnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 8
        ))
    }

    func testPendingQueueFetchRequiresCapturedQueueAndTrackGenerations() {
        XCTAssertTrue(MusicController.shouldRunPendingQueueFetch(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldRunPendingQueueFetch(
            requestQueueGeneration: 3,
            currentQueueGeneration: 4,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldRunPendingQueueFetch(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 8
        ))

        XCTAssertFalse(MusicController.shouldRunPendingQueueFetch(
            requestQueueGeneration: nil,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldRunPendingQueueFetch(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: nil,
            currentTrackGeneration: 7
        ))
    }

    func testPendingQueueFetchCapturesLatestCurrentGenerations() {
        let c = MusicController(preview: true)
        c.isPreview = false
        c.queueFetchInFlight = true
        c.queueSyncGeneration = 12
        c.artworkFetchGeneration = 4

        c.fetchUpNextQueue(forceRecent: true)

        XCTAssertTrue(c.queueFetchPending)
        XCTAssertTrue(c.queueFetchPendingForceRecent)
        XCTAssertEqual(c.queueFetchPendingQueueGeneration, 12)
        XCTAssertEqual(c.queueFetchPendingTrackGeneration, 4)

        c.queueSyncGeneration = 13
        c.artworkFetchGeneration = 5

        c.fetchUpNextQueue(forceRecent: false)

        XCTAssertTrue(c.queueFetchPending)
        XCTAssertFalse(c.queueFetchPendingForceRecent)
        XCTAssertEqual(c.queueFetchPendingQueueGeneration, 13)
        XCTAssertEqual(c.queueFetchPendingTrackGeneration, 5)
    }

    func testRecentHistorySnapshotUsesSameGenerationGateAsQueue() {
        XCTAssertTrue(MusicController.shouldApplyRecentHistorySnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldApplyRecentHistorySnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 4,
            requestTrackGeneration: 7,
            currentTrackGeneration: 7
        ))

        XCTAssertFalse(MusicController.shouldApplyRecentHistorySnapshot(
            requestQueueGeneration: 3,
            currentQueueGeneration: 3,
            requestTrackGeneration: 7,
            currentTrackGeneration: 8
        ))
    }

    func testQueueAndRecentHistorySnapshotGatesStayEquivalent() {
        let cases: [(requestQueue: UInt64, currentQueue: UInt64, requestTrack: Int, currentTrack: Int)] = [
            (1, 1, 1, 1),
            (1, 2, 1, 1),
            (1, 1, 1, 2),
            (42, 42, 7, 7),
            (42, 41, 7, 8)
        ]

        for testCase in cases {
            XCTAssertEqual(
                MusicController.shouldApplyQueueSnapshot(
                    requestQueueGeneration: testCase.requestQueue,
                    currentQueueGeneration: testCase.currentQueue,
                    requestTrackGeneration: testCase.requestTrack,
                    currentTrackGeneration: testCase.currentTrack
                ),
                MusicController.shouldApplyRecentHistorySnapshot(
                    requestQueueGeneration: testCase.requestQueue,
                    currentQueueGeneration: testCase.currentQueue,
                    requestTrackGeneration: testCase.requestTrack,
                    currentTrackGeneration: testCase.currentTrack
                )
            )
        }
    }

    func testPlaylistOpenCachedQueueRequiresCurrentGeneration() {
        XCTAssertTrue(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: true,
            upNextProvenance: .exactPublicMusicQueue(context: "verified"),
            recentTracksProvenance: .exactPublicMusicQueue(context: "verified")
        ))

        XCTAssertFalse(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: false,
            upNextProvenance: .exactPublicMusicQueue(context: "verified"),
            recentTracksProvenance: .exactPublicMusicQueue(context: "verified")
        ))
    }

    func testPlaylistOpenCachedQueueRequiresRecentCompletedSnapshot() {
        XCTAssertFalse(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: false,
            completedCurrentQueueGeneration: true,
            upNextProvenance: .exactPublicMusicQueue(context: "verified"),
            recentTracksProvenance: .exactPublicMusicQueue(context: "verified")
        ))
    }

    func testPlaylistOpenCachedQueueRequiresDisplayableQueueAndHistoryProvenance() {
        XCTAssertTrue(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: true,
            upNextProvenance: .preview,
            recentTracksProvenance: .preview
        ))

        XCTAssertFalse(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: true,
            upNextProvenance: .playlistContextOnly(playlistName: "Music"),
            recentTracksProvenance: .exactPublicMusicQueue(context: "verified")
        ))

        XCTAssertFalse(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: true,
            upNextProvenance: .exactPublicMusicQueue(context: "verified"),
            recentTracksProvenance: .appleMusicAccountRecentlyPlayed
        ))

        XCTAssertFalse(MusicController.shouldUseCachedQueueForPlaylistOpen(
            recentlyCompletedQueue: true,
            completedCurrentQueueGeneration: true,
            upNextProvenance: .unavailable(reason: .noCurrentTrack),
            recentTracksProvenance: .exactPublicMusicQueue(context: "verified")
        ))
    }

    func testNearbyAssetPreloadRequiresDisplayableQueueProvenance() {
        XCTAssertTrue(MusicController.shouldPreloadNearbyAssets(
            didChange: true,
            provenance: .exactPublicMusicQueue(context: "manual-proof")
        ))

        XCTAssertFalse(MusicController.shouldPreloadNearbyAssets(
            didChange: true,
            provenance: .playlistContextOnly(playlistName: "Road Trip")
        ))

        XCTAssertFalse(MusicController.shouldPreloadNearbyAssets(
            didChange: true,
            provenance: .appleMusicAccountRecentlyPlayed
        ))

        XCTAssertFalse(MusicController.shouldPreloadNearbyAssets(
            didChange: false,
            provenance: .exactPublicMusicQueue(context: "manual-proof")
        ))
    }

    func testCurrentPlaylistRowsArePlaylistContextOnlyUntilParityProof() {
        let provenance = MusicController.currentPlaylistRowsProvenance(
            hasCurrentPlaylist: true,
            trackClass: "shared track",
            playlistName: "Road Trip"
        )

        XCTAssertEqual(provenance, .playlistContextOnly(playlistName: "Road Trip"))
        XCTAssertTrue(provenance.isPlaylistContextOnly)
        XCTAssertFalse(provenance.isExactRealTimeQueue)
        XCTAssertFalse(provenance.isUnavailable)
        XCTAssertFalse(provenance.canDisplayAsRealTimeQueueRows)
    }

    func testMissingCurrentPlaylistForURLTrackMarksQueueUnavailable() {
        let provenance = MusicController.currentPlaylistRowsProvenance(
            hasCurrentPlaylist: false,
            trackClass: "URL track",
            playlistName: nil
        )

        XCTAssertEqual(provenance, .unavailable(reason: .noCurrentPlaylistForTrackClass("URL track")))
        XCTAssertTrue(provenance.isUnavailable)
        XCTAssertFalse(provenance.isExactRealTimeQueue)
        XCTAssertFalse(provenance.canDisplayAsRealTimeQueueRows)
    }

    func testAppleMusicRecentHistoryProvenanceIsNotExactRealTimeQueue() {
        let provenance = MusicQueueProvenance.appleMusicAccountRecentlyPlayed

        XCTAssertFalse(provenance.isExactRealTimeQueue)
        XCTAssertFalse(provenance.isPlaylistContextOnly)
        XCTAssertFalse(provenance.isUnavailable)
        XCTAssertFalse(provenance.canDisplayAsRealTimeQueueRows)
    }

    func testOnlyPreviewAndExactProvenanceCanDisplayAsRealTimeQueueRows() {
        XCTAssertTrue(MusicQueueProvenance.preview.canDisplayAsRealTimeQueueRows)
        XCTAssertTrue(MusicQueueProvenance.exactPublicMusicQueue(context: "manual-proof").canDisplayAsRealTimeQueueRows)
        XCTAssertFalse(MusicQueueProvenance.playlistContextOnly(playlistName: "Road Trip").canDisplayAsRealTimeQueueRows)
        XCTAssertFalse(MusicQueueProvenance.appleMusicAccountRecentlyPlayed.canDisplayAsRealTimeQueueRows)
        XCTAssertFalse(MusicQueueProvenance.unavailable(reason: .publicSourceUnverified).canDisplayAsRealTimeQueueRows)
    }

    func testOnlyDisplayableProvenanceRetainsQueueRowsForStorage() {
        let rows = ["one", "two"]

        XCTAssertEqual(
            MusicController.rowsRetainedForRealTimeQueueStorage(rows, provenance: .preview),
            rows
        )
        XCTAssertEqual(
            MusicController.rowsRetainedForRealTimeQueueStorage(rows, provenance: .exactPublicMusicQueue(context: "manual-proof")),
            rows
        )
        XCTAssertTrue(MusicController.rowsRetainedForRealTimeQueueStorage(
            rows,
            provenance: .playlistContextOnly(playlistName: "Road Trip")
        ).isEmpty)
        XCTAssertTrue(MusicController.rowsRetainedForRealTimeQueueStorage(
            rows,
            provenance: .appleMusicAccountRecentlyPlayed
        ).isEmpty)
        XCTAssertTrue(MusicController.rowsRetainedForRealTimeQueueStorage(
            rows,
            provenance: .unavailable(reason: .publicSourceUnverified)
        ).isEmpty)
    }

    func testRuntimeOnlyMaterializesRowsForDisplayableQueueProvenance() {
        XCTAssertTrue(MusicController.shouldMaterializeQueueRows(provenance: .preview))
        XCTAssertTrue(MusicController.shouldMaterializeQueueRows(provenance: .exactPublicMusicQueue(context: "manual-proof")))
        XCTAssertFalse(MusicController.shouldMaterializeQueueRows(provenance: .playlistContextOnly(playlistName: "Road Trip")))
        XCTAssertFalse(MusicController.shouldMaterializeQueueRows(provenance: .appleMusicAccountRecentlyPlayed))
        XCTAssertFalse(MusicController.shouldMaterializeQueueRows(provenance: .unavailable(reason: .publicSourceUnverified)))
    }

    func testPlaylistOpenOnlyForcesRecentFetchForEmptyDisplayableHistory() {
        XCTAssertTrue(MusicController.shouldForceRecentHistoryForPlaylistOpen(
            provenance: .preview,
            rowsAreEmpty: true
        ))
        XCTAssertFalse(MusicController.shouldForceRecentHistoryForPlaylistOpen(
            provenance: .preview,
            rowsAreEmpty: false
        ))
        XCTAssertFalse(MusicController.shouldForceRecentHistoryForPlaylistOpen(
            provenance: .appleMusicAccountRecentlyPlayed,
            rowsAreEmpty: true
        ))
        XCTAssertFalse(MusicController.shouldForceRecentHistoryForPlaylistOpen(
            provenance: .unavailable(reason: .noCurrentPlaylistForTrackClass("URL track")),
            rowsAreEmpty: true
        ))
    }

    func testAppleMusicAPITrackIDsAreNotPlayableThroughAppLocalMusicKit() {
        XCTAssertTrue(MusicController.canPlayTrackViaMusicAppPersistentID("65C30E3EB6270892"))
        XCTAssertFalse(MusicController.canPlayTrackViaMusicAppPersistentID("am:123456789"))
        XCTAssertFalse(MusicController.canPlayTrackViaMusicAppPersistentID("am:i.abcdef"))
        XCTAssertFalse(MusicController.canPlayTrackViaMusicAppPersistentID(""))
        XCTAssertFalse(MusicController.canPlayTrackViaMusicAppPersistentID(" 65C30E3EB6270892"))
        XCTAssertFalse(MusicController.canPlayTrackViaMusicAppPersistentID("playlist-row-placeholder"))
        XCTAssertFalse(MusicController.canPlayTrackViaMusicAppPersistentID("65C30E3EB6270892\" or true"))
    }

    func testQueueProvenanceDiagnosticLabelsAreStable() {
        XCTAssertEqual(MusicQueueProvenance.preview.diagnosticLabel, "preview")
        XCTAssertEqual(
            MusicQueueProvenance.exactPublicMusicQueue(context: "manual-proof").diagnosticLabel,
            "exact-public-music-queue.context.manual-proof"
        )
        XCTAssertEqual(
            MusicQueueProvenance.playlistContextOnly(playlistName: "Road Trip").diagnosticLabel,
            "playlist-context-only.playlist.Road Trip"
        )
        XCTAssertEqual(
            MusicQueueProvenance.appleMusicAccountRecentlyPlayed.diagnosticLabel,
            "apple-music-account-recently-played"
        )
        XCTAssertEqual(
            MusicQueueProvenance.unavailable(reason: .noCurrentPlaylistForTrackClass("URL track")).diagnosticLabel,
            "unavailable.no-current-playlist.track-class.URL track"
        )
        XCTAssertEqual(
            MusicQueueProvenance.unavailable(reason: .pendingPublicRefresh).diagnosticLabel,
            "unavailable.pending-public-refresh"
        )
    }

    func testQueueProvenanceUnavailableDisplayMessagesAreStable() {
        XCTAssertNil(MusicQueueProvenance.preview.unavailableDisplayMessage)
        XCTAssertNil(MusicQueueProvenance.exactPublicMusicQueue(context: "manual-proof").unavailableDisplayMessage)

        XCTAssertEqual(
            MusicQueueProvenance.playlistContextOnly(playlistName: "Road Trip").unavailableDisplayMessage,
            "Only \"Road Trip\" is public; Up Next has not been verified."
        )
        XCTAssertEqual(
            MusicQueueProvenance.playlistContextOnly(playlistName: nil).unavailableDisplayMessage,
            "Only the containing playlist is public; Up Next has not been verified."
        )
        XCTAssertEqual(
            MusicQueueProvenance.appleMusicAccountRecentlyPlayed.unavailableDisplayMessage,
            "Apple Music history is not the live Music.app session."
        )
        XCTAssertEqual(
            MusicQueueProvenance.unavailable(reason: .noCurrentPlaylistForTrackClass("URL track")).unavailableDisplayMessage,
            "Music.app exposes no public queue for URL track playback."
        )
        XCTAssertEqual(
            MusicQueueProvenance.unavailable(reason: .noPublicQueueObject).unavailableDisplayMessage,
            "Music.app exposes no public Up Next object."
        )
        XCTAssertEqual(
            MusicQueueProvenance.unavailable(reason: .pendingPublicRefresh).unavailableDisplayMessage,
            "Queue changed; waiting for a verified Music.app refresh."
        )
    }

    func testQueueChangeInvalidatesPublishedRowsUntilFreshPublicSnapshot() {
        let c = MusicController(preview: true)
        c.isPreview = false
        c.upNextTracks = [
            (title: "Old Next", artist: "Artist", album: "Album", persistentID: "next", duration: 180)
        ]
        c.recentTracks = [
            (title: "Old Recent", artist: "Artist", album: "Album", persistentID: "recent", duration: 181)
        ]
        c.upNextRawRowCount = 3
        c.recentRawRowCount = 2
        c.lastRecentHistoryFetchAt = Date()
        c.upNextProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        c.recentTracksProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        let previousGeneration = c.queueSyncGeneration

        c.markQueueMayHaveChanged()

        XCTAssertEqual(c.queueSyncGeneration, previousGeneration + 1)
        XCTAssertTrue(c.upNextTracks.isEmpty)
        XCTAssertTrue(c.recentTracks.isEmpty)
        XCTAssertEqual(c.upNextRawRowCount, 0)
        XCTAssertEqual(c.recentRawRowCount, 0)
        XCTAssertEqual(c.lastRecentHistoryFetchAt, .distantPast)
        XCTAssertEqual(c.upNextProvenance, .unavailable(reason: .pendingPublicRefresh))
        XCTAssertEqual(c.recentTracksProvenance, .unavailable(reason: .pendingPublicRefresh))
    }

    func testObservedTrackChangeInvalidatesRowsBeforeDelayedQueueRefresh() {
        let c = MusicController(preview: true)
        c.isPreview = false
        c.currentPersistentID = "old-track"
        c.currentTrackIsURLTrack = true
        c.upNextTracks = [
            (title: "Old Next", artist: "Artist", album: "Album", persistentID: "next", duration: 180)
        ]
        c.recentTracks = [
            (title: "Old Recent", artist: "Artist", album: "Album", persistentID: "recent", duration: 181)
        ]
        c.upNextRawRowCount = 3
        c.recentRawRowCount = 2
        c.lastRecentHistoryFetchAt = Date()
        c.upNextProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        c.recentTracksProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        let previousQueueGeneration = c.queueSyncGeneration
        let previousArtworkGeneration = c.artworkFetchGeneration

        let generation = c.beginObservedTrackChangeForPendingQueueRefresh()

        XCTAssertEqual(generation, previousArtworkGeneration + 1)
        XCTAssertEqual(c.artworkFetchGeneration, generation)
        XCTAssertEqual(c.queueSyncGeneration, previousQueueGeneration + 1)
        XCTAssertNil(c.currentPersistentID)
        XCTAssertFalse(c.currentTrackIsURLTrack)
        XCTAssertTrue(c.upNextTracks.isEmpty)
        XCTAssertTrue(c.recentTracks.isEmpty)
        XCTAssertEqual(c.upNextRawRowCount, 0)
        XCTAssertEqual(c.recentRawRowCount, 0)
        XCTAssertEqual(c.lastRecentHistoryFetchAt, .distantPast)
        XCTAssertEqual(c.upNextProvenance, .unavailable(reason: .pendingPublicRefresh))
        XCTAssertEqual(c.recentTracksProvenance, .unavailable(reason: .pendingPublicRefresh))
    }

    func testObservedTrackChangeQueueRefreshRequiresCurrentTrackGeneration() {
        XCTAssertTrue(MusicController.shouldRunObservedTrackChangeQueueRefresh(
            requestTrackGeneration: 9,
            currentTrackGeneration: 9
        ))
        XCTAssertFalse(MusicController.shouldRunObservedTrackChangeQueueRefresh(
            requestTrackGeneration: 9,
            currentTrackGeneration: 10
        ))
    }

    func testMusicControlQueueRefreshRequiresCurrentQueueGeneration() {
        XCTAssertTrue(MusicController.shouldRunMusicControlQueueRefresh(
            requestQueueGeneration: 7,
            currentQueueGeneration: 7
        ))
        XCTAssertFalse(MusicController.shouldRunMusicControlQueueRefresh(
            requestQueueGeneration: 7,
            currentQueueGeneration: 8
        ))
    }

    func testMusicControlUnavailableStillExitsPendingViaPublicRefreshAttempt() async throws {
        let c = MusicController(preview: true)
        c.isPreview = false
        c.controlApp = nil
        c.queueApp = nil
        c.upNextTracks = [
            (title: "Old Next", artist: "Artist", album: "Album", persistentID: "next", duration: 180)
        ]
        c.recentTracks = [
            (title: "Old Recent", artist: "Artist", album: "Album", persistentID: "recent", duration: 181)
        ]
        c.upNextProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        c.recentTracksProvenance = .exactPublicMusicQueue(context: "verified-before-change")

        c.nextTrack()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if c.upNextProvenance == .unavailable(reason: .musicAppUnavailable),
               c.recentTracksProvenance == .unavailable(reason: .musicAppUnavailable),
               c.upNextTracks.isEmpty,
               c.recentTracks.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Unavailable control path should attempt a public refresh and exit pending state")
    }

    func testDetectedQueueHashChangeInvalidatesPublishedRowsUntilFreshPublicSnapshot() {
        let c = MusicController(preview: true)
        c.isPreview = false
        XCTAssertTrue(c.applyDetectedQueueHash("Music:10:current"))

        c.upNextTracks = [
            (title: "Old Next", artist: "Artist", album: "Album", persistentID: "next", duration: 180)
        ]
        c.recentTracks = [
            (title: "Old Recent", artist: "Artist", album: "Album", persistentID: "recent", duration: 181)
        ]
        c.upNextRawRowCount = 3
        c.recentRawRowCount = 2
        c.lastRecentHistoryFetchAt = Date()
        c.upNextProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        c.recentTracksProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        let previousGeneration = c.queueSyncGeneration

        XCTAssertTrue(c.applyDetectedQueueHash("Music:11:current"))

        XCTAssertEqual(c.queueSyncGeneration, previousGeneration + 1)
        XCTAssertTrue(c.upNextTracks.isEmpty)
        XCTAssertTrue(c.recentTracks.isEmpty)
        XCTAssertEqual(c.upNextRawRowCount, 0)
        XCTAssertEqual(c.recentRawRowCount, 0)
        XCTAssertEqual(c.lastRecentHistoryFetchAt, .distantPast)
        XCTAssertEqual(c.upNextProvenance, .unavailable(reason: .pendingPublicRefresh))
        XCTAssertEqual(c.recentTracksProvenance, .unavailable(reason: .pendingPublicRefresh))
    }

    func testDetectedQueueHashSameValueDoesNotInvalidateRows() {
        let c = MusicController(preview: true)
        c.isPreview = false
        XCTAssertTrue(c.applyDetectedQueueHash("Music:10:current"))

        c.upNextTracks = [
            (title: "Still Next", artist: "Artist", album: "Album", persistentID: "next", duration: 180)
        ]
        c.upNextRawRowCount = 1
        c.upNextProvenance = .exactPublicMusicQueue(context: "verified-before-change")
        let previousGeneration = c.queueSyncGeneration

        XCTAssertFalse(c.applyDetectedQueueHash("Music:10:current"))

        XCTAssertEqual(c.queueSyncGeneration, previousGeneration)
        XCTAssertEqual(c.upNextTracks.map { $0.persistentID }, ["next"])
        XCTAssertEqual(c.upNextRawRowCount, 1)
        XCTAssertEqual(c.upNextProvenance, .exactPublicMusicQueue(context: "verified-before-change"))
    }

    func testPreviewQueueChangeKeepsFixtureRowsVisible() {
        let c = MusicController(preview: true)
        let previousUpNext = c.upNextTracks.map { $0.persistentID }
        let previousRecent = c.recentTracks.map { $0.persistentID }

        c.markQueueMayHaveChanged()

        XCTAssertEqual(c.upNextTracks.map { $0.persistentID }, previousUpNext)
        XCTAssertEqual(c.recentTracks.map { $0.persistentID }, previousRecent)
        XCTAssertEqual(c.upNextProvenance, .preview)
        XCTAssertEqual(c.recentTracksProvenance, .preview)
    }

    func testLyricWaveTimingKeepsProtectedDefaultForLongLineInterval() {
        let indices = Array(0...18)
        let delay = LyricWaveTiming.baseDelay(
            for: indices,
            startPosition: 0,
            newIndex: 3,
            lineInterval: 4.0
        )

        XCTAssertEqual(delay, LyricWaveTiming.defaultBaseDelay, accuracy: 0.0001)
    }

    func testLyricWaveTimingCompressesShortLineIntervalBeforeNextLyric() {
        let indices = Array(0...18)
        let defaultDuration = LyricWaveTiming.waveDuration(
            for: indices,
            startPosition: 0,
            newIndex: 3,
            baseDelay: LyricWaveTiming.defaultBaseDelay
        )
        let delay = LyricWaveTiming.baseDelay(
            for: indices,
            startPosition: 0,
            newIndex: 3,
            lineInterval: 1.2
        )
        let adjustedDuration = LyricWaveTiming.waveDuration(
            for: indices,
            startPosition: 0,
            newIndex: 3,
            baseDelay: delay
        )

        XCTAssertLessThan(delay, LyricWaveTiming.defaultBaseDelay)
        XCTAssertLessThan(adjustedDuration, defaultDuration)
        XCTAssertLessThanOrEqual(adjustedDuration, 1.2 * LyricWaveTiming.maxLineIntervalFraction + 0.001)
    }

    func testLyricWaveTimingHonorsMinimumDelayForVeryDenseLyrics() {
        let indices = Array(0...30)
        let delay = LyricWaveTiming.baseDelay(
            for: indices,
            startPosition: 0,
            newIndex: 2,
            lineInterval: 0.25
        )

        XCTAssertEqual(delay, LyricWaveTiming.minimumBaseDelay, accuracy: 0.0001)
    }

    func testLyricMotionSamplingUsesPlaybackDerivedActiveIndex() {
        let lyrics = [
            LyricLine(text: "...", startTime: 0, endTime: 10),
            LyricLine(text: "first", startTime: 10, endTime: 14),
            LyricLine(text: "second", startTime: 14, endTime: 18),
            LyricLine(text: "third", startTime: 21, endTime: 25)
        ]

        XCTAssertEqual(
            LyricMotionSamplingPolicy.activeIndex(at: 9.5, lyrics: lyrics, firstRealIndex: 1),
            0
        )
        XCTAssertEqual(
            LyricMotionSamplingPolicy.activeIndex(at: 15.0, lyrics: lyrics, firstRealIndex: 1),
            2
        )
    }

    func testLyricMotionSamplingElevatesNearLineBoundaryOnly() {
        let lyrics = [
            LyricLine(text: "...", startTime: 0, endTime: 10),
            LyricLine(text: "first", startTime: 10, endTime: 14),
            LyricLine(text: "second", startTime: 14, endTime: 18)
        ]

        XCTAssertEqual(
            LyricMotionSamplingPolicy.sampleInterval(
                focusedWindowActive: false,
                playbackTime: 9.95,
                lyrics: lyrics,
                firstRealIndex: 1
            ),
            LyricMotionSamplingPolicy.boundaryInterval,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricMotionSamplingPolicy.sampleInterval(
                focusedWindowActive: false,
                playbackTime: 12.0,
                lyrics: lyrics,
                firstRealIndex: 1
            ),
            LyricMotionSamplingPolicy.idleInterval,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricMotionSamplingPolicy.sampleInterval(
                focusedWindowActive: true,
                playbackTime: 12.0,
                lyrics: lyrics,
                firstRealIndex: 1
            ),
            LyricMotionSamplingPolicy.focusedInterval,
            accuracy: 0.0001
        )
    }
}
