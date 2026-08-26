import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Layer-row builder — the crash-era integration path, now a pure entry.
//
// `LyricsView.refreshDisplayLineCache` used to inline `makeLayerBackedRows`,
// which mixed DISPLAY-space indices with SOURCE-space arrays. The 2026-08-25
// SIGTRAP (`Range requires lowerBound <= upperBound`) lived on that path:
// a prelude scan built `max(displayIndex+1, firstReal)..<source.count` and
// trapped when the display index ran past the source line count (segmented
// rows, or a lyrics-array shrink mid-update).
//
// The scan itself now lives in `LyricPreludeResolution` (never inverted).
// This builder is the rest of the take-from-two-arrays logic — bounds-checked
// source lookup, prelude end-time, last-segment interlude — so churn tests
// can drive the same entry `onChange → refreshDisplayLineCache` used to,
// without hosting SwiftUI. LyricsView keeps a one-line wrapper so the
// RapidSwitchTests source-scan ("body must not rebuild rows") stays valid.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
enum LyricLayerRowBuilder {

    static func makeRows(
        from displayLines: [DisplayLyricLine],
        sourceLines: [LyricLine],
        firstRealLyricIndex: Int,
        isEllipsis: (String) -> Bool = LyricPreludeGlyph.isEllipsis
    ) -> [LayerBackedLyricRow] {
        displayLines.enumerated().map { index, displayLine in
            let line = displayLine.line
            let sourceLine = sourceLines.indices.contains(displayLine.sourceIndex)
                ? sourceLines[displayLine.sourceIndex]
                : line
            let isPrelude = isEllipsis(line.text)
            let preludeEndTime: TimeInterval = isPrelude
                ? LyricPreludeResolution.preludeEndTime(
                    displayIndex: index,
                    preludeLineEndTime: line.endTime,
                    sourceLines: sourceLines,
                    firstRealIndex: firstRealLyricIndex,
                    isEllipsis: isEllipsis
                )
                : line.endTime
            return LayerBackedLyricRow(
                id: displayLine.id,
                index: index,
                displayLine: displayLine,
                sourceLine: sourceLine,
                isPrelude: isPrelude,
                preludeEndTime: preludeEndTime,
                interlude: displayLine.isLastSegment
                    ? interlude(
                        at: displayLine.sourceIndex,
                        sourceLines: sourceLines,
                        isEllipsis: isEllipsis
                    )
                    : nil
            )
        }
    }

    static func interlude(
        at index: Int,
        sourceLines: [LyricLine],
        isEllipsis: (String) -> Bool = LyricPreludeGlyph.isEllipsis
    ) -> LayerBackedLyricInterlude? {
        guard index + 1 < sourceLines.count else { return nil }
        let currentLine = sourceLines[index]
        let nextLine = sourceLines[index + 1]
        if isEllipsis(currentLine.text) || isEllipsis(nextLine.text) { return nil }
        let gap = nextLine.startTime - currentLine.endTime
        return gap >= 5.0
            ? LayerBackedLyricInterlude(startTime: currentLine.endTime, endTime: nextLine.startTime)
            : nil
    }
}
