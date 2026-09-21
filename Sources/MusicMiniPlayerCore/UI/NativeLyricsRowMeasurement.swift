import AppKit
import CoreGraphics
import Foundation

enum NativeLyricsRowMeasurement {
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
        let textWidth = max(1, rowWidth - leadingInset - trailingInset)
        if row.isPrelude {
            return preludeHeight
        }

        let staticPlan = NativeLyricsStaticTextRenderPlan.make(line: row.displayLine.line)
        let constants = staticPlan.constants
        let mainHeight = measuredTextHeight(
            staticPlan.displayText,
            width: textWidth,
            font: .systemFont(ofSize: constants.mainFontSize, weight: .semibold)
        )
        let verticalPadding = row.displayLine.line.isBackground ? backgroundRowVerticalPadding : rowVerticalPadding
        var height = mainHeight + verticalPadding
        if showTranslation,
           let translation = row.displayLine.line.translation,
           !translation.isEmpty {
            height += constants.mainFontSize * 0.33
            height += measuredTextHeight(
                translation,
                width: textWidth,
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
}
