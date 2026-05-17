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
    }

    func testRadioArtworkCurrentGuardRequiresTitleAndArtist() {
        let c = MusicController(preview: true)
        c.currentPersistentID = nil
        c.currentTrackTitle = "Shared Station Title"
        c.currentArtist = "Actual Artist"

        XCTAssertTrue(c.isStillCurrentTrack(persistentID: "", title: "Shared Station Title", artist: "Actual Artist"))
        XCTAssertFalse(
            c.isStillCurrentTrack(persistentID: "", title: "Shared Station Title", artist: "Previous Artist"),
            "Radio artwork callbacks without persistentID must not apply on title-only matches"
        )
    }

    func testPlaybackSessionArtworkExtractorFindsApplePlaybackArtworkURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackSessionArtworkFetcherTests-\(UUID().uuidString)")
        let archive = root.appendingPathComponent("IT-1.playbackSessionArchive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = """
        name:夜機 artist:Priscilla Chan album:陳慧嫻金曲精選
        https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/34/cf/5a/34cf5a94-fee1-760e-1cbb-9fde06a7a8d5/24UMGIM15495.rgb.jpg/800x800bb.jpg
        """
        let gz = archive.appendingPathComponent("contentItem.protobuf.gz")
        try makeGzip(payload, at: gz)

        let url = PlaybackSessionArtworkFetcher.latestArtworkURL(
            title: "夜機",
            artist: "Priscilla Chan",
            album: "陳慧嫻金曲精選",
            root: root
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/34/cf/5a/34cf5a94-fee1-760e-1cbb-9fde06a7a8d5/24UMGIM15495.rgb.jpg/800x800bb.jpg"
        )
    }

    func testPlaybackSessionArtworkExtractorNormalizesEscapedTemplateURL() {
        let payload = #"https:\/\/is1-ssl.mzstatic.com\/image\/thumb\/Music112\/v4\/34\/cf\/5a\/cover.rgb.jpg\/{w}x{h}{c}.{f}"#
        let url = PlaybackSessionArtworkFetcher.firstAppleArtworkURL(in: payload)
        XCTAssertEqual(
            url?.absoluteString,
            "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/34/cf/5a/cover.rgb.jpg/800x800bb.jpg"
        )
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

    private func makeGzip(_ text: String, at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        try output.fileHandleForReading.readDataToEndOfFile().write(to: url)
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
}
