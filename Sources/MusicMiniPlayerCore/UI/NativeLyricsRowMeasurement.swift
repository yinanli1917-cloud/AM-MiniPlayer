import AppKit
import CoreGraphics
import Foundation

enum NativeLyricsRowMeasurement {
    static let leadingInset: CGFloat = 32
    static let trailingInset: CGFloat = 32
    static let preludeHeight: CGFloat = 46
    static let translationLoadingRowHeight: CGFloat = 8

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
        var height = mainHeight + 16
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
