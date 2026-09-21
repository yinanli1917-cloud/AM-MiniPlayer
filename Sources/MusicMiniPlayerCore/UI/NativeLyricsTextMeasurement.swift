import AppKit
import CoreGraphics
import Foundation

enum NativeLyricsTextMeasurement {
    struct Metrics: Equatable {
        let height: CGFloat
        let lineCount: Int
        let usedRect: CGRect
        /// The character range (into the ORIGINAL text) of the LAST non-empty line
        /// fragment at this measurement width — the orphan-avoidance choke point
        /// (`NativeLyricsRowMeasurement.textWidth`) uses this to decide whether the
        /// last line is a lone stranded character/short word. `.zero`/length-0 when
        /// the text is empty or single-line.
        let lastLineRange: NSRange
    }

    #if DEBUG
    // ─────────────────────────────────────────────────────────────────────
    // Test-only counter. Each call below spins up a full NSLayoutManager/
    // NSTypesetter stack — the dominant scroll-time cost. The layout()
    // memoization in NativeLyricsRowView exists to keep this from being hit
    // on every CATransaction commit; the regression test asserts that an
    // unchanged re-layout does NOT increment this counter.
    // ─────────────────────────────────────────────────────────────────────
    nonisolated(unsafe) static var debugMeasureCount = 0
    #endif

    static func metrics(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat? = nil
    ) -> Metrics {
        guard !text.isEmpty, width > 1 else {
            return Metrics(height: 0, lineCount: 0, usedRect: .zero, lastLineRange: NSRange(location: 0, length: 0))
        }
        #if DEBUG
        debugMeasureCount += 1
        #endif

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left
        paragraph.lineSpacing = lineSpacing ?? 0

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph
            ]
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineCount = 0
        var lastLineGlyphRange = NSRange(location: 0, length: 0)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, glyphFragmentRange, _ in
            if usedRect.width > 0 || usedRect.height > 0 {
                lineCount += 1
                lastLineGlyphRange = glyphFragmentRange
            }
        }
        let lastLineRange = lastLineGlyphRange.length > 0
            ? layoutManager.characterRange(forGlyphRange: lastLineGlyphRange, actualGlyphRange: nil)
            : NSRange(location: 0, length: 0)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return Metrics(
            height: max(1, ceil(usedRect.height)),
            lineCount: lineCount,
            usedRect: usedRect,
            lastLineRange: lastLineRange
        )
    }

    static func measuredTextHeight(
        _ text: String,
        width: CGFloat,
        font: NSFont,
        lineSpacing: CGFloat? = nil
    ) -> CGFloat {
        metrics(text, width: width, font: font, lineSpacing: lineSpacing).height
    }
}

enum NativeLyricsHeightAccumulator {
    static let rowSpacing: CGFloat = 6
    static let defaultRowHeight: CGFloat = 36

    static let interludeGapHeight: CGFloat = 34

    static func accumulatedHeights(
        renderedIndices: [Int],
        configuredAccumulatedHeights: [Int: CGFloat],
        measuredHeights: [Int: CGFloat],
        interludeAfterIndex: Int? = nil,
        rowSpacing: CGFloat = rowSpacing,
        defaultRowHeight: CGFloat = defaultRowHeight
    ) -> [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        var accumulated: CGFloat = 0

        for (position, index) in renderedIndices.enumerated() {
            result[index] = accumulated
            accumulated += rowHeight(
                for: index,
                at: position,
                renderedIndices: renderedIndices,
                configuredAccumulatedHeights: configuredAccumulatedHeights,
                measuredHeights: measuredHeights,
                rowSpacing: rowSpacing,
                defaultRowHeight: defaultRowHeight
            )
            if index == interludeAfterIndex {
                accumulated += interludeGapHeight
            }
            if position < renderedIndices.count - 1 {
                accumulated += rowSpacing
            }
        }

        return result
    }

    static func rowHeight(
        for index: Int,
        at position: Int,
        renderedIndices: [Int],
        configuredAccumulatedHeights: [Int: CGFloat],
        measuredHeights: [Int: CGFloat],
        rowSpacing: CGFloat = rowSpacing,
        defaultRowHeight: CGFloat = defaultRowHeight
    ) -> CGFloat {
        if let measured = measuredHeights[index], measured > 1 {
            return measured
        }

        if position + 1 < renderedIndices.count,
           let currentOffset = configuredAccumulatedHeights[index],
           let nextOffset = configuredAccumulatedHeights[renderedIndices[position + 1]] {
            let configured = nextOffset - currentOffset - rowSpacing
            if configured > 1 {
                return configured
            }
        }

        return defaultRowHeight
    }
}
