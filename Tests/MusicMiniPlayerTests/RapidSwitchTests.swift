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
