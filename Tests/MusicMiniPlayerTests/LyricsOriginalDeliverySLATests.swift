import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Original-lyrics 3s SLA — fake-clock path inventory (A-rule 2026-08-26).
//
// Each real trigger→display path has a ceiling. 2.9s is the last in-budget
// instant; 3.1s is a legal translation sidecar, never a reason to hold the
// original. No real network, no wall sleep.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsOriginalDeliverySLATests: XCTestCase {

    private let paths = LyricsOriginalDeliveryPath.allCases

    func testForegroundBudgetSitsInsideOriginalMustPublishBy() {
        XCTAssertLessThanOrEqual(
            LyricsOriginalDeliverySLA.foregroundBudget,
            LyricsOriginalDeliverySLA.originalMustPublishBy
        )
        XCTAssertLessThan(
            LyricsOriginalDeliverySLA.originalMustPublishBy,
            LyricsOriginalDeliverySLA.userVisibleCeiling
        )
        XCTAssertGreaterThan(
            LyricsOriginalDeliverySLA.translationLateArrival,
            LyricsOriginalDeliverySLA.userVisibleCeiling
        )
        XCTAssertEqual(LyricsFetcher.shared.foregroundHardDeadlineForTesting, 2.70, accuracy: 0.0001)
    }

    func testEveryPathCeilingFitsInside2_9sBoundary() {
        for path in paths {
            let ceiling = LyricsOriginalDeliverySLA.originalCeiling(for: path)
            XCTAssertLessThanOrEqual(
                ceiling,
                LyricsOriginalDeliverySLA.originalMustPublishBy,
                "\(path.rawValue) ceiling \(ceiling)s must be ≤ 2.9s"
            )
            XCTAssertLessThanOrEqual(
                ceiling,
                LyricsOriginalDeliverySLA.userVisibleCeiling,
                "\(path.rawValue) ceiling \(ceiling)s must be ≤ 3s"
            )
        }
    }

    func testSyncPathsPublishAtElapsedZero() {
        let sync: [LyricsOriginalDeliveryPath] = [
            .memoryCacheHit, .diskPreflightHit, .missMemoReplay, .provisionalCache, .sameTrackSeek
        ]
        for path in sync {
            XCTAssertEqual(LyricsOriginalDeliverySLA.originalCeiling(for: path), 0, path.rawValue)
            XCTAssertTrue(
                LyricsOriginalDeliverySLA.shouldPublishOriginal(
                    elapsed: 0, hasOriginal: true, translationReady: false
                ),
                "\(path.rawValue) must publish original at t=0 without translation"
            )
        }
    }

    func testNetworkPathsPublishOriginalAt2_9sEvenWithoutTranslation() {
        let network: [LyricsOriginalDeliveryPath] = [
            .networkForegroundHit, .networkForegroundMiss, .trackChange, .forceRefresh, .coldStart
        ]
        let t = LyricsOriginalDeliverySLA.originalMustPublishBy
        XCTAssertTrue(LyricsOriginalDeliverySLA.originalMustHavePublished(elapsed: t))
        for path in network {
            XCTAssertLessThanOrEqual(
                LyricsOriginalDeliverySLA.originalCeiling(for: path),
                t,
                path.rawValue
            )
            XCTAssertTrue(
                LyricsOriginalDeliverySLA.shouldPublishOriginal(
                    elapsed: t, hasOriginal: true, translationReady: false
                ),
                "\(path.rawValue) at 2.9s: original publishes; translation is not a gate"
            )
            XCTAssertFalse(
                LyricsOriginalDeliverySLA.shouldWaitForTranslation(elapsed: t, hasOriginal: true),
                "\(path.rawValue) must not stall original for translation at 2.9s"
            )
        }
    }

    func test3_1sTranslationIsHotInsertNotOriginalMiss() {
        let t = LyricsOriginalDeliverySLA.translationLateArrival
        XCTAssertTrue(
            LyricsOriginalDeliverySLA.originalMustHavePublished(elapsed: t),
            "by 3.1s original is already required to have published"
        )
        XCTAssertFalse(
            LyricsOriginalDeliverySLA.originalBudgetViolated(
                elapsed: t, hasPublishedOriginal: true
            ),
            "original already on screen at 3.1s is not an SLA miss"
        )
        XCTAssertTrue(
            LyricsOriginalDeliverySLA.originalBudgetViolated(
                elapsed: t, hasPublishedOriginal: false
            ),
            "still searching at 3.1s IS an SLA miss"
        )
        XCTAssertTrue(
            LyricsOriginalDeliverySLA.translationHotInsertAllowed(
                elapsed: t, originalAlreadyPublished: true
            )
        )
        XCTAssertFalse(
            LyricsOriginalDeliverySLA.shouldWaitForTranslation(elapsed: t, hasOriginal: true)
        )
    }

    func testSeekDoesNotOpenANewForegroundBudget() {
        XCTAssertEqual(
            LyricsOriginalDeliverySLA.originalCeiling(for: .sameTrackSeek),
            0
        )
        XCTAssertTrue(
            LyricsOriginalDeliverySLA.shouldPublishOriginal(
                elapsed: 0, hasOriginal: true, translationReady: true
            )
        )
    }

    func testAccuracyDegradationOrderMatchesSourceBonusLadder() {
        let order = LyricsOriginalDeliverySLA.accuracyDegradationOrder
        XCTAssertEqual(order.count, LyricsSource.allCases.count)
        for i in 0..<(order.count - 1) {
            XCTAssertGreaterThanOrEqual(
                order[i].profile.bonus,
                order[i + 1].profile.bonus,
                "\(order[i].rawValue) must degrade after higher-bonus \(order[i + 1].rawValue) is dropped"
            )
        }
        XCTAssertEqual(order.first, .appleMusic)
        XCTAssertEqual(order.last, .lyricsOvh)
    }

    func testClipToForegroundBudgetNeverExceedsHardDeadline() {
        for raw in [3.0, 2.95, 2.90, 2.85, 2.80, 2.70, 2.20, 0, -1] as [TimeInterval] {
            let clipped = LyricsFetcher.clipToForegroundBudget(raw)
            XCTAssertLessThanOrEqual(clipped, LyricsFetcher.foregroundHardDeadline)
            XCTAssertGreaterThanOrEqual(clipped, 0)
            if raw > LyricsFetcher.foregroundHardDeadline {
                XCTAssertEqual(clipped, LyricsFetcher.foregroundHardDeadline, accuracy: 0.0001)
            }
        }
    }

    func testCatalogExactTitleEmptyDeadlineNoLongerSitsAt2_95() {
        let deadline = LyricsFetcher.shared.foregroundEmptyResultDeadlineForTesting(
            title: "This Is My Love",
            artist: "Michelle Chen",
            duration: 312,
            album: "Young Stars"
        )
        XCTAssertLessThanOrEqual(deadline, LyricsFetcher.foregroundHardDeadline)
        XCTAssertLessThanOrEqual(deadline, LyricsOriginalDeliverySLA.originalMustPublishBy)
        XCTAssertLessThan(deadline, LyricsOriginalDeliverySLA.userVisibleCeiling)
    }

    func testCJKAlbumNativeProviderTimeoutClippedInsideHardDeadline() {
        let timeout = LyricsFetcher.shared.foregroundNativeProviderTimeoutForTesting(
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美"
        )
        XCTAssertLessThanOrEqual(timeout, LyricsFetcher.foregroundHardDeadline)
        XCTAssertLessThanOrEqual(timeout, LyricsOriginalDeliverySLA.originalMustPublishBy)
    }
}
