/**
 * [INPUT]: Depends on AppKit (NSFont) and, read-only, the native renderer's own measurement
 *          primitives (NativeLyricsTextMeasurement, NativeLyricsRowMeasurement,
 *          NativeLyricsTextConstants) -- never modifies or drives renderer state.
 * [OUTPUT]: Exports LyricDisplayLineMeasurement.visualLineCount(for:rowWidth:isBackground:)
 * [POS]: UI/display-line construction layer. Used by LyricDisplaySegmenter's Plan A split
 *        (2026-09-22, docs/lyrics-ux-contract.md §E) so the "should this line split" decision is
 *        driven by the SAME real NSLayoutManager wrap the renderer will actually draw, instead of
 *        the old character-unit estimate (LyricDisplaySegmentationOptions.maxLineUnits), which a
 *        54-line eval dataset (research/long-line-eval-2026-09-22.md) found undercounts the real
 *        wrap on 44/54 lines at the app's narrow (180pt) resizable-minimum width.
 */
import AppKit
import Foundation

enum LyricDisplayLineMeasurement {
    /// The real visual-line count `text` wraps to at `rowWidth`, measured with the exact recipe
    /// the native renderer uses (NativeLyricsTextConstants font/line-spacing,
    /// NativeLyricsRowMeasurement's orphan-avoidance content width, NativeLyricsTextMeasurement's
    /// NSLayoutManager pass) -- so a split decision made here can never disagree with what the
    /// renderer actually draws.
    static func visualLineCount(for text: String, rowWidth: CGFloat, isBackground: Bool = false) -> Int {
        guard !text.isEmpty else { return 0 }
        guard rowWidth > 1 else { return 1 }
        let constants = NativeLyricsTextConstants(scale: NativeLyricsTextConstants.scale(forBackground: isBackground))
        let font = NSFont.systemFont(ofSize: constants.mainFontSize, weight: .semibold)
        let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: rowWidth, lineSpacing: constants.mainLineSpacing)
        return NativeLyricsTextMeasurement.metrics(text, width: width, font: font, lineSpacing: constants.mainLineSpacing).lineCount
    }
}
