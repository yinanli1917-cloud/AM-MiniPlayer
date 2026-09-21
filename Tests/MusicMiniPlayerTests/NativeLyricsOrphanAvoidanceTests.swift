import XCTest
import AppKit
@testable import MusicMiniPlayerCore

/// 2026-09-21 founder: a line that would leave a 1–2 glyph orphan on its last line must not become
/// an orphan line (one glyph; two are fine), and NO row may change its left edge or margins (a widened row that sat 12pt left
/// of its neighbours was rejected on sight). Rule: keep the width envelope, break EARLIER so the two
/// lines are balanced. Non-orphan rows keep the normal width exactly.
final class NativeLyricsOrphanAvoidanceTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 24, weight: .semibold)
    private func normal(_ rowWidth: CGFloat) -> CGFloat { rowWidth - NativeLyricsRowMeasurement.leadingInset - NativeLyricsRowMeasurement.trailingInset }
    private func capacity(_ glyph: String, width: CGFloat) -> Int {
        var n = 1
        while NativeLyricsTextMeasurement.metrics(String(repeating: glyph, count: n + 1), width: width, font: font).lineCount <= 1 { n += 1 }
        return n
    }
    private func lastLine(_ text: String, width: CGFloat) -> String {
        let m = NativeLyricsTextMeasurement.metrics(text, width: width, font: font)
        return (text as NSString).substring(with: m.lastLineRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test_cjkOneGlyphOrphan_breaksBalanced_sameLineCount_noShift() {
        let rowWidth: CGFloat = 250 // the founder's panel: 8 glyphs per line
        let n = capacity("想", width: normal(rowWidth))
        let text = String(repeating: "想", count: n + 1)
        XCTAssertEqual(lastLine(text, width: normal(rowWidth)).count, 1, "setup: one stranded glyph at the normal width")
        let w = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        XCTAssertLessThan(w, normal(rowWidth), "orphan row narrows its wrap width (never widens)")
        let m = NativeLyricsTextMeasurement.metrics(text, width: w, font: font)
        XCTAssertEqual(m.lineCount, 2, "same line count as the greedy layout")
        XCTAssertEqual(lastLine(text, width: w).count, 2, "exactly one more glyph wraps: 8+1 → 7+2, nothing more aggressive")
        XCTAssertEqual(NativeLyricsRowMeasurement.leadingShift(forTextWidth: w, rowWidth: rowWidth), 0, "rows never shift")
    }

    func test_nonOrphanRows_keepNormalWidth() {
        for rowWidth in [250.0, 370.0, 500.0] as [CGFloat] {
            let n = capacity("想", width: normal(rowWidth))
            for text in [String(repeating: "想", count: n), String(repeating: "想", count: n + 2), String(repeating: "想", count: n + 4), "对昨天心已死", "hello world"] {
                XCTAssertEqual(NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth), normal(rowWidth), "\(text) @\(rowWidth)")
            }
        }
    }

    func test_latinShortWordOrphan_wrapsOneMoreWord() {
        let rowWidth: CGFloat = 320
        // Deterministic fixture: the first word count whose greedy layout is exactly two lines with
        // "out" alone on the last one; skip (not fail) if this font never produces that shape.
        var fixture: String?
        for k in 1...30 {
            let text = Array(repeating: "memory", count: k).joined(separator: " ") + " out"
            let m = NativeLyricsTextMeasurement.metrics(text, width: normal(rowWidth), font: font)
            if m.lineCount == 2, lastLine(text, width: normal(rowWidth)) == "out" { fixture = text; break }
            if m.lineCount > 2 { break }
        }
        guard let text = fixture else { return }
        let w = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        XCTAssertLessThan(w, normal(rowWidth))
        XCTAssertEqual(NativeLyricsTextMeasurement.metrics(text, width: w, font: font).lineCount, 2)
        XCTAssertNotEqual(lastLine(text, width: w), "out", "the short word is no longer alone on the last line")
    }

    func test_longLine_orphanAtGreedy_stillSameLineCountAfterRebreak() {
        let rowWidth: CGFloat = 250
        let n = capacity("想", width: normal(rowWidth))
        let text = String(repeating: "想", count: 2 * n + 1) // 3 lines greedy, 1-glyph orphan
        let w = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth)
        let m = NativeLyricsTextMeasurement.metrics(text, width: w, font: font)
        XCTAssertEqual(m.lineCount, 3)
        // Narrowing shortens EVERY line by one glyph, so a 3-line row ends with 2–3 glyphs.
        XCTAssertGreaterThanOrEqual(lastLine(text, width: w).count, 2)
        XCTAssertLessThanOrEqual(lastLine(text, width: w).count, 3)
    }
}
