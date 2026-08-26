import XCTest
@testable import MusicMiniPlayerCore

// Regression for the nanoPod SIGTRAP (EXC_BREAKPOINT, "Range requires lowerBound <= upperBound")
// on the main thread inside LyricsView.makeLayerBackedRows — an inline prelude scan that built
// `max(displayIndex+1, firstRealIndex)..<sourceLines.count` and trapped whenever the display index
// ran past the source line count (segmented display rows, or a lyrics-array shrink mid-update).
// Two real crashes (14:43 and 20:03 on 2026-08-25) shared this exact faulting stack.
final class LyricPreludeResolutionTests: XCTestCase {

    private func line(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> LyricLine {
        LyricLine(text: text, startTime: start, endTime: end)
    }
    private func isEllipsis(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces) == "…" }

    // ── The crash case: display index beyond the source array must NOT trap ──
    func test_displayIndexPastSourceCount_returnsFallback_neverInvertedRange() {
        let source = [line("real one", 1, 3), line("real two", 3, 5)] // count = 2
        // A prelude row sitting at display index 7 (display array longer than source, e.g. segmented):
        // max(7+1, firstReal)=8 > 2 would have been an inverted range 8..<2 → crash. Must fall back.
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 7, preludeLineEndTime: 42, sourceLines: source,
            firstRealIndex: 0, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 42, "past-the-end prelude must fall back to its own end time, not crash")
    }

    func test_scanStartEqualsCount_returnsFallback() {
        let source = [line("a", 1, 2), line("b", 2, 3)] // count = 2
        // displayIndex+1 == count (2) → scanStart 2, range 2..<2 is EMPTY (valid) → fallback.
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 1, preludeLineEndTime: 99, sourceLines: source,
            firstRealIndex: 0, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 99)
    }

    func test_firstRealIndexPastCount_returnsFallback() {
        let source = [line("…", 0, 1)]
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 0, preludeLineEndTime: 7, sourceLines: source,
            firstRealIndex: 5, isEllipsis: isEllipsis // firstReal 5 > count 1
        )
        XCTAssertEqual(end, 7, "out-of-range firstRealIndex must not index or invert")
    }

    func test_emptySource_returnsFallback() {
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 0, preludeLineEndTime: 3, sourceLines: [],
            firstRealIndex: 0, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 3)
    }

    // ── Normal behavior preserved ──
    func test_leadingPrelude_returnsFirstRealLineStart() {
        // first real line starts at 3; fallback is a distinct 99 so a pass proves the branch taken.
        let source = [line("…", 0, 2), line("first real", 3, 5), line("second", 5, 8)]
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 0, preludeLineEndTime: 99, sourceLines: source,
            firstRealIndex: 1, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 3, "leading prelude ends when the first real line (index 1) starts")
    }

    func test_midPrelude_returnsNextNonEllipsisStart() {
        // interlude ellipsis at index 2, next real at index 3 (start 11); fallback distinct 99.
        let source = [line("a", 0, 2), line("b", 2, 4), line("…", 4, 10), line("c", 11, 13)]
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 2, preludeLineEndTime: 99, sourceLines: source,
            firstRealIndex: 0, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 11, "interlude prelude ends when the next real line (index 3) starts")
    }

    func test_midPrelude_skipsConsecutiveEllipses() {
        let source = [line("a", 0, 2), line("…", 2, 4), line("…", 4, 6), line("c", 6, 9)]
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 1, preludeLineEndTime: 4, sourceLines: source,
            firstRealIndex: 0, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 6, "skip consecutive ellipsis lines to the next real start")
    }

    func test_noRealLineAfter_returnsFallback() {
        let source = [line("a", 0, 2), line("…", 2, 6), line("…", 6, 9)]
        let end = LyricPreludeResolution.preludeEndTime(
            displayIndex: 1, preludeLineEndTime: 6, sourceLines: source,
            firstRealIndex: 0, isEllipsis: isEllipsis
        )
        XCTAssertEqual(end, 6, "no real line after → prelude's own end time")
    }
}
