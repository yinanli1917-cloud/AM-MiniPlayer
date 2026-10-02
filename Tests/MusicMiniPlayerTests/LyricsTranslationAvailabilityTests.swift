/**
 * [INPUT]: LyricsService.translationAvailabilityPrecheck / refreshTranslationAvailability
 *          (whether the translate button applies to the lyrics on screen).
 * [OUTPUT]: Tests: the cheap cases answer at once, language detection answers
 *           off the main thread, an answer is remembered per lyrics, a newer
 *           lyric set wins over a slower older answer.
 * [POS]: Language detection (Core ML, ~40ms) used to run on the main thread
 *        for every lyrics apply, inside the edge animation a track change starts.
 */

import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class LyricsTranslationAvailabilityTests: XCTestCase {
    private let service = LyricsService.shared
    private var savedLanguage = ""

    override func setUp() {
        super.setUp()
        savedLanguage = service.translationLanguage
        service.translationLanguage = "zh-Hans"
    }

    override func tearDown() {
        service.translationLanguage = savedLanguage
        apply([], title: "tearDown")
        super.tearDown()
    }

    private func english(_ n: Int = 8, tag: String = "") -> [LyricLine] {
        let texts = ["Every time you call my name", "I can hear it through the rain", "Waiting on the other side",
                     "Hold me closer when it fades", "Never let the morning find us", "Lights go down across the bay",
                     "Carry me along the shore", "Tell me what you came here for"]
        return (0..<n).map { LyricLine(text: texts[$0 % texts.count] + tag, startTime: Double($0) * 3, endTime: Double($0) * 3 + 2.5) }
    }

    private func chinese() -> [LyricLine] {
        ["我们一起走过雨天", "风吹过旧街边", "留下温柔的画面", "时间慢慢地走远"].enumerated()
            .map { LyricLine(text: $0.element, startTime: Double($0.offset) * 3, endTime: Double($0.offset) * 3 + 2.5) }
    }

    private func apply(_ lyrics: [LyricLine], title: String, fromSource: Bool = false) {
        service.applyLyrics(lyrics, firstRealLyricIndex: 0, hasSourceTranslation: fromSource, isUnsynced: false,
                            songID: title, title: title, artist: "A", stableSongID: title, duration: 200)
    }

    private func wait(_ cond: () -> Bool, timeout: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return cond()
    }

    func test_precheck_answersTheCheapCasesWithoutLanguageDetection() {
        XCTAssertEqual(LyricsService.translationAvailabilityPrecheck(lyrics: [], translationLanguage: "zh-Hans", translationsAreFromLyricsSource: false), .known(false))
        XCTAssertEqual(LyricsService.translationAvailabilityPrecheck(lyrics: english(), translationLanguage: "zh-Hans", translationsAreFromLyricsSource: true), .known(true))
        XCTAssertEqual(LyricsService.translationAvailabilityPrecheck(lyrics: chinese(), translationLanguage: "zh-Hans", translationsAreFromLyricsSource: false), .known(false))
        XCTAssertEqual(LyricsService.translationAvailabilityPrecheck(lyrics: english(), translationLanguage: "zh-Hans", translationsAreFromLyricsSource: false), .needsLanguageDetection)
    }

    func test_cheapCases_updateCanTranslateSynchronously() {
        apply(english(), title: "src", fromSource: true)
        XCTAssertTrue(service.canTranslate)
        apply(chinese(), title: "zh")
        XCTAssertFalse(service.canTranslate)
        apply([], title: "none")
        XCTAssertFalse(service.canTranslate)
    }

    func test_languageDetection_runsOffMain_andTheAnswerLands() {
        apply(chinese(), title: "reset")
        XCTAssertFalse(service.canTranslate)
        apply(english(tag: " a"), title: "en1")
        // The main thread did not wait for the Core ML pass: the previous value still stands.
        XCTAssertFalse(service.canTranslate, "language detection is asynchronous")
        XCTAssertTrue(wait { service.canTranslate }, "English lyrics against a Chinese target can be translated")
    }

    func test_anAnswerIsRememberedPerLyrics() {
        let lyrics = english(tag: " b")
        apply(chinese(), title: "zh0")   // start from a known `false`, whatever earlier tests left
        apply(lyrics, title: "en2")
        XCTAssertTrue(wait { service.canTranslate })
        apply(chinese(), title: "zh2")
        XCTAssertFalse(service.canTranslate)
        apply(lyrics, title: "en2")
        XCTAssertTrue(service.canTranslate, "the same lyrics again are answered from memory, synchronously")
    }

    func test_aNewerLyricSet_winsOverASlowerOlderAnswer() {
        apply(english(tag: " c"), title: "slow")     // detection starts...
        apply(chinese(), title: "newer")             // ...and is superseded before it lands
        XCTAssertFalse(service.canTranslate)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertFalse(service.canTranslate, "the stale English verdict must not flip the Chinese song's button on")
    }
}
