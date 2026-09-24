import XCTest

/// Source-scan guard (2026-09-23 fix, see LyricsTranslationSessionTrigger.swift
/// and LyricsTranslationSessionTriggerTests.swift for the full root-cause
/// writeup and the integration-level proof that the underlying service call
/// needs this retry). LyricsView's `.onChange(of: lyricsService.lyrics)`
/// handler is not directly callable from a test (it's a private SwiftUI
/// closure with no host in this suite -- see
/// LyricsTranslationSessionTriggerTests's header for why full view hosting
/// was not attempted), so this pins the WIRING FACT by reading the actual
/// source text, mirroring the existing convention
/// (TranslationConfigurationSourceScanTests / NativeLyricsSurfaceSourceTests):
/// read the file as text, strip comments, assert on the stripped body.
final class LyricsViewTranslationRetryWiringTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func lyricsViewSource() throws -> String {
        let path = repoRoot()
            .appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Strips `//` line comments and `/* ... */` block comments -- same
    /// algorithm as TranslationConfigurationSourceScanTests, so a call
    /// mentioned only in a doc comment (as this very explanation does) never
    /// trips the scan.
    private func stripComments(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    /// The `.onChange(of: lyricsService.lyrics)` handler's body, isolated by
    /// finding that marker and cutting off at the NEXT `.onChange(of:` (the
    /// `musicController.isPlaying` handler that immediately follows it in
    /// LyricsView.swift's modifier chain).
    private func lyricsChangeHandlerBody(in strippedSource: String) throws -> String {
        let marker = ".onChange(of: lyricsService.lyrics) { oldLyrics, newLyrics in"
        guard let markerRange = strippedSource.range(of: marker) else {
            XCTFail("Could not find the .onChange(of: lyricsService.lyrics) handler -- has it been renamed or restructured?")
            return ""
        }
        let afterMarker = strippedSource[markerRange.upperBound...]
        guard let nextOnChangeRange = afterMarker.range(of: ".onChange(of:") else {
            XCTFail("Could not find the next .onChange(of:) after the lyrics handler to bound the scan")
            return ""
        }
        return String(afterMarker[afterMarker.startIndex..<nextOnChangeRange.lowerBound])
    }

    func test_lyricsChangeHandler_schedulesTranslationSessionConfigUpdate() throws {
        let stripped = stripComments(try lyricsViewSource())
        let body = try lyricsChangeHandlerBody(in: stripped)

        XCTAssertTrue(
            body.contains("LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate("),
            "the .onChange(of: lyricsService.lyrics) handler must gate on the pure decision function " +
            "(LyricsTranslationSessionTrigger.shouldScheduleConfigUpdate), not an ad-hoc inline condition, " +
            "so the decision stays independently testable"
        )
        XCTAssertTrue(
            body.contains("scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)"),
            "the .onChange(of: lyricsService.lyrics) handler must (re-)schedule a translation session-config " +
            "resolution attempt when real new lyric content arrives -- this is the fix for the founder's " +
            "'no session (source not resolved yet)' symptom persisting across an entire song's playback " +
            "(see LyricsTranslationSessionTrigger.swift)"
        )
    }

    /// Regression guard: before the fix there were exactly 4 call sites
    /// (page-appear, onAppear, translationLanguage change, showTranslation
    /// toggle). The fix adds a 5th (lyrics content arriving). If this count
    /// ever drops back to 4, the retry this test suite exists to prove
    /// necessary has been silently removed.
    func test_scheduleTranslationSessionConfigUpdateCallSiteCount_isFive() throws {
        let stripped = stripComments(try lyricsViewSource())
        let marker = "scheduleTranslationSessionConfigUpdate(after: lyricPageSwitchTranslationDeferDuration)"
        var count = 0
        var searchRange = stripped.startIndex..<stripped.endIndex
        while let range = stripped.range(of: marker, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<stripped.endIndex
        }
        XCTAssertEqual(
            count, 5,
            "expected 5 call sites (page-appear, onAppear, translationLanguage change, showTranslation toggle, " +
            "and the 2026-09-23 lyrics-arrival retry) -- found \(count). If this dropped to 4, the fix for " +
            "'no session (source not resolved yet)' persisting forever across track changes was removed."
        )
    }
}
