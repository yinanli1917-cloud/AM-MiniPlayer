import XCTest
@testable import MusicMiniPlayerCore

/// Pure-function tests for LyricsTranslationSessionTrigger (see that file's
/// header for the full root-cause writeup), plus an integration-level check
/// exercising the REAL `LyricsService.silentSystemTranslationConfiguration()`
/// -- the exact function LyricsView calls -- to prove the missing-retry
/// symptom is real: without a second call after a track change, the song's
/// translation source stays unresolved forever, exactly matching the
/// founder's /tmp/nanopod_debug.log evidence ("Roses"/"Ocean Side"/"Ring
/// Around the Rosie", all "no session (source not resolved yet)" for their
/// entire playback with zero intervening page switches).
///
/// `LyricsViewTranslationRetryWiringTests` (source-scan, same convention as
/// `TranslationConfigurationSourceScanTests`) is the other half: it proves
/// LyricsView.swift's `.onChange(of: lyricsService.lyrics)` handler actually
/// calls `LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate` and,
/// when true, `scheduleTranslationSessionConfigUpdate` -- i.e. that the fix
/// demonstrated here to be necessary is actually wired into the view. Full
/// SwiftUI view hosting (driving the real `.onChange`/`.translationTask`
/// lifecycle in an NSWindow) was not attempted: there is no existing
/// precedent for hosting LyricsView itself in this test target (unlike the
/// lower-level NativeLyrics* renderer views, which use MusicController(preview:)
/// + a real NSWindow), `.translationTask` would attempt a REAL on-device
/// Translation session tied to a live SwiftUI update cycle rather than the
/// already-established seams (`debugSeedDisplayedLyricsForTesting` + calling
/// the service method directly) other translation-session tests in this
/// suite use, and the actual defect is a WIRING fact about which onChange
/// handlers exist -- best proven by inspecting the source directly rather
/// than by an elaborate, timing-sensitive host.
///
/// Safety: no network. The one real system call
/// (`TranslationAvailabilityMemo` / on-device `LanguageAvailability().status`)
/// is on-device only, same call `PieceTranslationSessionWiringTests` already
/// makes for the identical en->zh-Hans pair. `translationDiskCache` is
/// redirected to a temp file; nothing touches
/// ~/Library/Application Support/nanoPod/.
@available(macOS 15.0, *)
@MainActor
final class LyricsTranslationSessionTriggerTests: XCTestCase {

    // MARK: - Pure function

    func test_realNewContent_schedules() {
        XCTAssertTrue(
            LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate(
                newLineCount: 12, isTranslationOnlyWriteback: false
            )
        )
    }

    func test_emptyLyrics_doesNotSchedule() {
        XCTAssertFalse(
            LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate(
                newLineCount: 0, isTranslationOnlyWriteback: false
            )
        )
    }

    func test_translationOnlyWriteback_doesNotSchedule() {
        // The source necessarily already resolved to produce this writeback
        // in the first place -- re-running resolution here would be wasted
        // async work with no observable effect.
        XCTAssertFalse(
            LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate(
                newLineCount: 12, isTranslationOnlyWriteback: true
            )
        )
    }

    func test_emptyAndTranslationOnly_doesNotSchedule() {
        XCTAssertFalse(
            LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate(
                newLineCount: 0, isTranslationOnlyWriteback: true
            )
        )
    }

    // MARK: - Integration-level reproduction (real LyricsService, real on-device detection)

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
            .appendingPathComponent("translation_cache_session_trigger_test_\(UUID().uuidString).json")
        service.translationDiskCache = TranslationDiskCache(fileURL: tmp, persistDebounce: 0.05)
    }

    override func tearDown() async throws {
        let service = LyricsService.shared
        service.showTranslation = savedShowTranslation
        service.translationLanguage = savedTranslationLanguage
        if let savedDiskCache { service.translationDiskCache = savedDiskCache }
        service.resetTranslationRequestStream()
        try await super.tearDown()
    }

    /// Reproduces the exact founder pattern: a Chinese song (source == target,
    /// nothing to resolve -- matches "冬至" in the real log) followed by an
    /// ordinary track change to an English song, WITHOUT any second call to
    /// `silentSystemTranslationConfiguration()` (simulating LyricsView before
    /// the fix, where nothing re-triggers this on a plain track change).
    /// `resolvedTranslationSourceLanguageCode` must stay nil after the track
    /// change -- proving the service does not somehow resolve on its own,
    /// which is exactly why the missing view-level retry is a real bug, not
    /// a hypothetical one. A second, explicit call (mirroring what the fixed
    /// LyricsView now schedules on lyrics arrival) then resolves it.
    func test_trackChangeWithoutRetry_staysUnresolved_untilCalledAgain() async throws {
        let service = LyricsService.shared
        service.showTranslation = true
        service.translationLanguage = "zh-Hans"

        // Song A: Chinese lyrics, Chinese target -- legitimately nothing to
        // resolve (matches the real log's "冬至": silentSystemTranslationConfiguration
        // returns nil via the `lyricsArePredominantlyChinese` early-out, not a bug).
        service.debugSeedDisplayedLyricsForTesting(
            [LyricLine(text: "指尖以东 在你夹克深处游动", startTime: 0, endTime: 4)],
            title: "SongA-\(UUID().uuidString.prefix(8))",
            artist: "Artist A",
            duration: 200,
            isUnsynced: false
        )
        let configA = await service.silentSystemTranslationConfiguration()
        XCTAssertNil(configA, "sanity: a Chinese song against a Chinese target has nothing to resolve")
        XCTAssertNil(service.resolvedTranslationSourceLanguageCode)

        // Track change to Song B (English, no lyrics-source translation) --
        // this is what `fetchLyrics` does on an ordinary track advance. NO
        // second call to `silentSystemTranslationConfiguration()` here: this
        // is the exact gap the founder's log shows (no PageSwitch, no
        // language/showTranslation toggle between songs).
        service.debugSeedDisplayedLyricsForTesting(
            [LyricLine(text: "I feel like I can finally let my guard down", startTime: 0, endTime: 4)],
            title: "SongB-\(UUID().uuidString.prefix(8))",
            artist: "Artist B",
            duration: 200,
            isUnsynced: false
        )
        XCTAssertNil(
            service.resolvedTranslationSourceLanguageCode,
            "the service must not magically resolve the new song's source on its own -- " +
            "without a real re-invocation of silentSystemTranslationConfiguration(), " +
            "the founder's symptom (source stuck nil for the song's whole playback) is exactly this state"
        )

        // The retry LyricsView's fixed `.onChange(of: lyricsService.lyrics)`
        // now schedules: calling the SAME real production method again.
        let configB = await service.silentSystemTranslationConfiguration()
        XCTAssertNotNil(configB, "re-invoking the real resolution after the new song's lyrics arrived must succeed")
        XCTAssertEqual(
            service.resolvedTranslationSourceLanguageCode, "en",
            "Song B's source must resolve to English once the retry actually runs"
        )
    }
}
