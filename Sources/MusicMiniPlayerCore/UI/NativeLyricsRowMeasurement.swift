import AppKit
import CoreGraphics
import Foundation

enum NativeLyricsRowMeasurement {
    // 2026-09-21 founder feedback comparing against Apple Music's lyrics panel: the text column
    // sat too far right. Moved left (32→20 leading, 32→24 trailing) — the ONE constant pair every
    // consumer reads (LyricsLayerRendererView's `nativeLyricContentLeadingInset`/
    // `nativeLyricContentTrailingInset` alias these; see that file for the full usage inventory:
    // interlude-dot x anchor, hover background frame, NativeLyricsRowScale's scale pivot X, and
    // this file's own `textWidth` orphan-avoidance slack).
    static let leadingInset: CGFloat = 32
    static let trailingInset: CGFloat = 32
    static let preludeHeight: CGFloat = 46
    static let preludeDotContainerTopInset: CGFloat = 8
    static let preludeDotContainerHeight: CGFloat = 30
    static let preludeDotCenterY: CGFloat = preludeDotContainerTopInset + preludeDotContainerHeight / 2
    static let translationLoadingRowHeight: CGFloat = 8
    /// Normal per-row vertical padding baked into `estimatedHeight` (top+bottom
    /// margin contributing the visual gap between stacked rows).
    static let rowVerticalPadding: CGFloat = 16
    /// A backing-vocal (和声) row sits directly under its melody row at HALF the
    /// normal gap (founder 2026-09-20) — same constant, halved, no second
    /// layout path.
    static let backgroundRowVerticalPadding: CGFloat = rowVerticalPadding / 2

    static func estimatedHeight(
        for row: LayerBackedLyricRow,
        rowWidth: CGFloat,
        showTranslation: Bool,
        isTranslating: Bool,
        pendingTranslationLineIndices: Set<Int>
    ) -> CGFloat {
        if row.isPrelude {
            return preludeHeight
        }

        let staticPlan = NativeLyricsStaticTextRenderPlan.make(line: row.displayLine.line)
        let constants = staticPlan.constants
        let contentWidth = textWidth(
            for: staticPlan.displayText,
            font: .systemFont(ofSize: constants.mainFontSize, weight: .semibold),
            rowWidth: rowWidth
        )
        let mainHeight = measuredTextHeight(
            staticPlan.displayText,
            width: contentWidth,
            font: .systemFont(ofSize: constants.mainFontSize, weight: .semibold),
            lineSpacing: constants.mainLineSpacing
        )
        let verticalPadding = row.displayLine.line.isBackground ? backgroundRowVerticalPadding : rowVerticalPadding
        var height = mainHeight + verticalPadding
        if showTranslation,
           let translation = row.displayLine.line.translation,
           !translation.isEmpty {
            height += constants.mainFontSize * 0.33
            height += measuredTextHeight(
                translation,
                width: contentWidth,
                font: .systemFont(ofSize: constants.translationFontSize, weight: .semibold),
                lineSpacing: constants.translationLineSpacing
            )
        } else if showTranslation,
                  isTranslating,
                  row.displayLine.segmentIndex == 0,
                  !row.sourceLine.hasTranslation,
                  pendingTranslationLineIndices.contains(row.displayLine.sourceIndex) {
            height += translationLoadingRowHeight
        }

        return ceil(height)
    }

    private static func measuredTextHeight(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat? = nil
    ) -> CGFloat {
        NativeLyricsTextMeasurement.measuredTextHeight(
            text,
            width: width,
            font: font,
            lineSpacing: lineSpacing
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Orphan-line avoidance (founder 2026-09-21)
    //
    // A CJK line wraps with a lone character stranded on its own second line
    // ("总是有单个字在那一行"). Rule (generalized, no per-song logic): a row lays
    // out at the NORMAL content width UNLESS laying it out there would strand an
    // orphan last line — ≤2 CJK graphemes, or a single Latin word of ≤3 letters —
    // AND widening the container to `normalWidth + slack` (slack = trailingInset
    // minus an 8pt safety margin to the panel edge) lets the WHOLE text fit in one
    // fewer line. Only then does the row use the widened width, still left-aligned
    // at the same leading inset. Every consumer of the row's content width MUST
    // route through this function — it is the ONE place the widening decision is
    // made — so measurement, the whole-line base layer, the active-line bitmaps
    // and the sweep-mask bounds can never disagree (see `NativeLyricsRowView.
    // contentTextWidth`, the row-level choke that calls this).
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// A widened row still leaves this much room to the panel's own trailing edge —
    /// never lets orphan-avoidance push text flush against the frame.
    static let orphanAvoidanceSafetyMargin: CGFloat = 4

    private struct WidthMemoKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let fontName: String
        let rowWidth: CGFloat
        let lineSpacing: CGFloat
    }

    // Runs on the main thread only (CALayer/NSView layout), same convention as
    // NativeLyricsTextMeasurement.debugMeasureCount. Capped and FIFO-evicted so a
    // long listening session (many distinct lines) can't grow this unbounded.
    nonisolated(unsafe) private static var widthMemo: [WidthMemoKey: CGFloat] = [:]
    nonisolated(unsafe) private static var widthMemoOrder: [WidthMemoKey] = []
    private static let widthMemoCapacity = 500

    /// Pure: the content width a row should lay its text out at, applying orphan
    /// avoidance. Memoized on (text, font size/name, rowWidth, lineSpacing) since
    /// this runs per row per layout pass.
    static func textWidth(
        for text: String,
        font: NSFont,
        rowWidth: CGFloat,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        let normalWidth = max(1, rowWidth - leadingInset - trailingInset)
        guard !text.isEmpty else { return normalWidth }

        let key = WidthMemoKey(
            text: text,
            fontSize: font.pointSize,
            fontName: font.fontName,
            rowWidth: rowWidth,
            lineSpacing: lineSpacing
        )
        if let cached = widthMemo[key] { return cached }

        let result = computeOrphanAvoidingWidth(
            text: text,
            font: font,
            normalWidth: normalWidth,
            lineSpacing: lineSpacing
        )
        memoize(result, for: key)
        return result
    }

    private static func memoize(_ value: CGFloat, for key: WidthMemoKey) {
        if widthMemo.updateValue(value, forKey: key) == nil {
            widthMemoOrder.append(key)
        }
        guard widthMemoOrder.count > widthMemoCapacity else { return }
        let evictCount = widthMemoOrder.count - widthMemoCapacity
        for evicted in widthMemoOrder.prefix(evictCount) {
            widthMemo.removeValue(forKey: evicted)
        }
        widthMemoOrder.removeFirst(evictCount)
    }

    private static func computeOrphanAvoidingWidth(
        text: String,
        font: NSFont,
        normalWidth: CGFloat,
        lineSpacing: CGFloat
    ) -> CGFloat {
        let slack = max(0, trailingInset - orphanAvoidanceSafetyMargin)
        guard slack > 0, normalWidth > 1 else { return normalWidth }

        let normalMetrics = NativeLyricsTextMeasurement.metrics(text, width: normalWidth, font: font, lineSpacing: lineSpacing)
        // Nothing to fix: already one line (or empty) at the normal width.
        guard normalMetrics.lineCount > 1 else { return normalWidth }
        guard isOrphanLastLine(text: text, range: normalMetrics.lastLineRange) else { return normalWidth }

        let widenedWidth = normalWidth + slack
        let widenedMetrics = NativeLyricsTextMeasurement.metrics(text, width: widenedWidth, font: font, lineSpacing: lineSpacing)
        // Widening only helps if it actually collapses the text into fewer lines —
        // an orphan that persists even at the widened width (the text is simply too
        // long) must not shift the whole row's wrap width for nothing.
        return widenedMetrics.lineCount < normalMetrics.lineCount ? widenedWidth : normalWidth
    }

    private static func isOrphanLastLine(text: String, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        let nsText = text as NSString
        guard range.location >= 0, range.location + range.length <= nsText.length else { return false }
        let lastLine = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lastLine.isEmpty else { return false }
        if LanguageUtils.containsCJK(lastLine) {
            return lastLine.count <= 2
        }
        // Latin: only a single word (no internal whitespace) of <=3 letters counts —
        // a short multi-word tail ("of it") is not the reported orphan shape.
        guard !lastLine.contains(where: { $0.isWhitespace }) else { return false }
        return lastLine.count <= 3
    }
}
