/**
 * [INPUT]: LyricsService.performSystemTranslation (Services/LyricsService.swift)
 *          + a REAL Translation.framework TranslationSession (not the
 *          LyricsServiceTranslationSessionReuseTests fake executor)
 * [OUTPUT]: Empirical check of the founder's 2026-09-14 hypothesis for defect
 *           #1 (translations often missing): does ONE TranslationSession,
 *           reused across songs the way A5 part 2 (commit 4e3b59a) intends,
 *           still produce translations for a SECOND song whose real content
 *           language differs from the first song's?
 * [POS]: Tests — repro harness for research/repro-2026-09-14-lyrics-pipeline.md
 *        defect #1. Skips (not fails) when the on-device language packs this
 *        assertion needs are not installed, since that is a machine property,
 *        not a code defect.
 *
 * Why `installedSource:`, not `Configuration(source: nil)`: production always
 * builds `Configuration(source: nil, target: ...)` — the session vended by
 * SwiftUI's `.translationTask` auto-detects per request. That vending only
 * happens inside a live `.translationTask` view hierarchy; there is no public
 * initializer for a `source: nil` session outside SwiftUI. `TranslationSession
 * (installedSource:target:)` (macOS 26+) is the closest headless-obtainable
 * proxy: it anchors the session to the FIRST song's language on purpose, which
 * is the WORST case for the reuse hypothesis (nil-source auto-detect should,
 * if anything, be less anchored than an explicit installedSource).
 */

import XCTest
@testable import MusicMiniPlayerCore
#if canImport(Translation)
import Translation
#endif

@available(macOS 26.0, *)
@MainActor
final class LyricsServiceRealTranslationSessionReuseTests: XCTestCase {

    private var savedShowTranslation = false
    private var savedTranslationLanguage = "zh-Hans"
    private var savedDiskCache: TranslationDiskCache?

    override func setUp() {
        super.setUp()
        let service = LyricsService.shared
        savedShowTranslation = service.showTranslation
        savedTranslationLanguage = service.translationLanguage
        savedDiskCache = service.translationDiskCache
        // Redirect disk persistence to a throwaway file for this test run —
        // the real LyricsServiceTranslationSessionReuseTests fake-executor
        // variant does NOT do this and pollutes the real
        // ~/Library/Application Support/nanoPod/translation_cache.json with
        // "译:hello world" rows (found during the 2026-09-14 repro; noted,
        // not fixed here — out of this task's four assigned defects).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation_cache_real_reuse_test_\(UUID().uuidString).json")
        service.translationDiskCache = TranslationDiskCache(fileURL: tmp, persistDebounce: 0.05)
    }

    override func tearDown() {
        let service = LyricsService.shared
        service.showTranslation = savedShowTranslation
        service.translationLanguage = savedTranslationLanguage
        if let savedDiskCache { service.translationDiskCache = savedDiskCache }
        super.tearDown()
    }

    private func makeService() -> LyricsService {
        let service = LyricsService.shared
        service.showTranslation = true
        service.translationLanguage = "zh-Hans"
        return service
    }

    /// Real production behavior for defect #1's song ("How Sweet" — NewJeans,
    /// 219s, cached 2026-09-14 03:47:49Z with 0/84 lines translated): lines
    /// code-switch English/Korean almost line by line. This is a verbatim
    /// prefix of that song's real cached lyrics (see
    /// research/repro-2026-09-14-lyrics-pipeline.md defect #1).
    private let mixedEnKoSample: [String] = [
        "All I know is now",
        "알게 됐어 나",
        "I know",
        "그동안 맨날",
        "Always up and do",
        "No more",
        "생각 또 생각",
        "Spinnin' 'round and 'round",
        "Changing my mind",
        "수상해서 그렇지",
        "이런 헛소리",
        "No more",
        "How it's supposed to be",
        "그만해 cus it's clear",
        "It's simple",
    ]

    func test_secondSong_koreanAfterJapanese_reusedSession_translationsNonEmpty() async throws {
        let avail = LanguageAvailability()
        let ja = Locale.Language(identifier: "ja")
        let zh = Locale.Language(identifier: "zh-Hans")
        guard await avail.status(from: ja, to: zh) == .installed else {
            throw XCTSkip("ja->zh-Hans language pack not installed on this machine")
        }

        let service = makeService()

        // ONE session, anchored to the FIRST song's language, reused for BOTH
        // songs exactly like serveTranslationRequests reuses its `session`
        // parameter across `for await` iterations.
        let session = TranslationSession(installedSource: ja, target: zh)

        // Song A: unambiguous Japanese, single language — sanity that the
        // pipeline + this session work at all before testing the switch.
        service.debugSeedDisplayedLyricsForTesting(
            [
                LyricLine(text: "こんにちは、世界", startTime: 0, endTime: 2),
                LyricLine(text: "今日はいい天気ですね", startTime: 2, endTime: 4),
                LyricLine(text: "音楽を聴きましょう", startTime: 4, endTime: 6),
            ],
            title: "TransReuse JA \(UUID().uuidString.prefix(8))",
            artist: "Test Artist",
            duration: 200,
            isUnsynced: false
        )
        await service.performSystemTranslation(session: session)
        let songATranslated = service.lyrics.filter { $0.hasTranslation }.count
        XCTAssertGreaterThan(songATranslated, 0, "song A (Japanese, session's anchor language) must translate — sanity check")

        // Song B: the real code-switched English/Korean content from defect
        // #1, translated through the SAME session instance (no rebuild).
        service.debugSeedDisplayedLyricsForTesting(
            mixedEnKoSample.enumerated().map {
                LyricLine(text: $0.element, startTime: Double($0.offset) * 2, endTime: Double($0.offset) * 2 + 2)
            },
            title: "TransReuse KO \(UUID().uuidString.prefix(8))",
            artist: "Test Artist",
            duration: 200,
            isUnsynced: false
        )
        await service.performSystemTranslation(session: session)
        let songBTranslated = service.lyrics.filter { $0.hasTranslation }.count

        XCTAssertGreaterThan(
            songBTranslated, 0,
            "song B (Korean/English code-switched, translated through the session reused from song A's Japanese anchor) must produce SOME translations — 0 reproduces defect #1 (founder 2026-09-14: whole page untranslated)"
        )
    }
}
