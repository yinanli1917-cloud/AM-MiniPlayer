/**
 * [INPUT]: LyricsService.silentSystemTranslationConfiguration/
 *          registerPendingPieceTranslations/performPendingPieceTranslations/
 *          serveTranslationRequests (Services/LyricsService.swift) +
 *          LyricPieceTranslation (UI/LyricPieceTranslation.swift) +
 *          PieceTranslationCache (Services/PieceTranslationCache.swift)
 * [OUTPUT]: Reproduces, then pins the fix for, the 2026-09-23 founder report
 *           (Raveena "Mystery"): a Plan-A split line whose whole-line
 *           translation already came from the lyrics source never got a
 *           tier-2 per-piece translation for its later pieces.
 * [POS]: Tests — no Sources/ file beyond LyricsService.swift/LyricsView.swift
 *        changed to make this pass.
 *
 * Root cause (file:line references are to the FIXED file; see the commit
 * message / task report for the pre-fix line numbers):
 * `LyricsService.silentSystemTranslationConfiguration()` used to return nil
 * immediately when `isFillingPartialSourceTranslations &&
 * !hasMissingEligibleTranslations(lyrics)` — i.e. whenever the lyrics
 * source already supplies a COMPLETE translation for every eligible line —
 * BEFORE ever resolving a source language or checking pair availability.
 * That left `resolvedSongTranslationSourceLanguage` (and therefore
 * `resolvedTranslationSourceLanguageCode`) permanently nil for such a song,
 * so `LyricsView.makeDisplayLyricLines`'s registration gate
 * (`pieceSourceCode != nil`) and `LyricsService.performPendingPieceTranslations`'s
 * own `isSystemTranslationSource` guard both refused to do any per-piece
 * work — every split piece past the first fell through
 * `LyricPieceTranslation`'s tier 3 (fallback: only piece 0 carries a
 * translation) forever, exactly the founder's screenshot.
 *
 * Safety: no network, no ~/Library/Application Support/nanoPod/ access.
 * `translationDiskCache` is redirected to a temp file (same pattern as
 * LyricsServiceTranslationSessionReuseTests). `PieceTranslationCache.shared`
 * is an in-memory-only process singleton reset via `debugReset()`. The one
 * real system call this test makes (`TranslationAvailabilityMemo` /
 * `LanguageAvailability().status(from: en, to: zh-Hans)`) is on-device only
 * (NaturalLanguage/Translation frameworks), never the network — the SAME
 * call the shipping app already makes for this exact language pair.
 */

import XCTest
@testable import MusicMiniPlayerCore

@available(macOS 15.0, *)
@MainActor
final class PieceTranslationSessionWiringTests: XCTestCase {

    private final class FakeExecutor: LyricsTranslationExecuting {
        private(set) var calls: [[String]] = []

        func translateBatch(_ texts: [String]) async throws -> [String] {
            calls.append(texts)
            return texts.map { "译:" + $0 }
        }
    }

    private var savedShowTranslation = false
    private var savedTranslationLanguage = "zh-Hans"
    private var savedDiskCache: TranslationDiskCache?

    override func setUp() {
        super.setUp()
        let service = LyricsService.shared
        savedShowTranslation = service.showTranslation
        savedTranslationLanguage = service.translationLanguage
        savedDiskCache = service.translationDiskCache
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation_cache_piece_wiring_test_\(UUID().uuidString).json")
        service.translationDiskCache = TranslationDiskCache(fileURL: tmp, persistDebounce: 0.05)
        #if DEBUG
        PieceTranslationCache.shared.debugReset()
        #endif
    }

    override func tearDown() async throws {
        let service = LyricsService.shared
        service.showTranslation = savedShowTranslation
        service.translationLanguage = savedTranslationLanguage
        if let savedDiskCache { service.translationDiskCache = savedDiskCache }
        service.resetTranslationRequestStream()
        #if DEBUG
        PieceTranslationCache.shared.debugReset()
        #endif
        try await super.tearDown()
    }

    /// The founder's exact repro shape: an English line long enough for
    /// Plan A to split into two pieces, with a COMPLETE Chinese translation
    /// already supplied by the lyrics source for the whole line (no missing
    /// eligible translations at all -- the exact condition that used to
    /// short-circuit `silentSystemTranslationConfiguration` before source
    /// resolution ever ran).
    func test_sourceTranslationComplete_stillResolvesSessionAndServicesPieceTier2() async throws {
        let service = LyricsService.shared
        service.showTranslation = true
        service.translationLanguage = "zh-Hans"

        let fullTranslation = "我感觉我那高傲的心墙终于倒塌"
        let line = LyricLine(
            text: "I feel like I can finally let my guard down",
            startTime: 0,
            endTime: 4,
            translation: fullTranslation
        )
        service.debugSeedDisplayedLyricsForTesting(
            [line],
            title: "Mystery-piece-wiring-\(UUID().uuidString.prefix(8))",
            artist: "Raveena",
            duration: 200,
            isUnsynced: false
        )
        XCTAssertTrue(service.hasTranslation, "sanity: the seeded line already carries a lyrics-source translation")

        // ---- Mechanism check #1 -------------------------------------------
        // A session must still resolve even though every eligible line
        // already has a COMPLETE lyrics-source translation. On unfixed main
        // this returns nil.
        let config = await service.silentSystemTranslationConfiguration()
        XCTAssertNotNil(
            config,
            "a TranslationSession.Configuration must still be produced so tier-2 per-piece " +
            "translation has a session to run on, even when performSystemTranslation itself " +
            "has nothing left to do"
        )
        XCTAssertEqual(
            service.resolvedTranslationSourceLanguageCode, "en",
            "the ORIGINAL line's source language must resolve for piece-level work even though " +
            "the WHOLE-line translation came from the lyrics source"
        )

        // ---- Sanity: before tier 2 lands, LyricPieceTranslation's own pure
        // three-tier decision (unmodified by this task) puts only piece 0 in
        // tier 3 and leaves piece 1 untranslated -- mirrors the founder's
        // screenshot ("I feel like I can" / "finally let my guard down", no
        // clause punctuation at the cut so tier 1 cannot apply either).
        let pieces = ["I feel like I can", "finally let my guard down"]
        let pieceCache: (String) -> String? = { text in
            guard let sourceCode = service.resolvedTranslationSourceLanguageCode else { return nil }
            let targetCode = LyricsService.normalizedSystemTranslationLanguage(service.translationLanguage)
            return PieceTranslationCache.shared.translation(for: text, source: sourceCode, target: targetCode)
        }
        let (beforeTranslations, beforeTiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: fullTranslation, cache: pieceCache
        )
        XCTAssertEqual(beforeTiers, [.fallbackFirstPiece, .none])
        XCTAssertNotNil(beforeTranslations[0])
        XCTAssertNil(beforeTranslations[1])

        // ---- Mechanism check #2 -------------------------------------------
        // Register the piece the way LyricsView.makeDisplayLyricLines does,
        // then let the SAME serve loop (`serveTranslationRequests`) the real
        // app uses actually service it through a fake translator.
        service.registerPendingPieceTranslations(["finally let my guard down"])

        let executor = FakeExecutor()
        let serveTask = Task { await service.serveTranslationRequests(with: executor) }
        let deadline = Date().addingTimeInterval(3.0)
        while service.pieceTranslationVersion == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        serveTask.cancel()

        XCTAssertTrue(
            executor.calls.contains { $0.contains("finally let my guard down") },
            "the fake translator must actually have been asked to translate the pending piece " +
            "(proves performPendingPieceTranslations ran, not just that it was registered)"
        )
        XCTAssertGreaterThan(service.pieceTranslationVersion, 0, "landing a piece translation must bump pieceTranslationVersion")

        // ---- Mechanism check #3 (the founder's acceptance bar) ------------
        // After servicing, EVERY piece has its own translation.
        let (afterTranslations, afterTiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: fullTranslation, cache: pieceCache
        )
        XCTAssertEqual(afterTiers[1], .perPieceCache, "piece 1 must now be served by the tier-2 cache")
        XCTAssertNotNil(afterTranslations[0])
        XCTAssertNotNil(afterTranslations[1], "every split piece must have its own translation")
    }
}
