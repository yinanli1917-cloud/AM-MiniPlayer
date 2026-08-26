import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Prelude end-time resolution — crash-safe.
//
// A prelude/interlude ellipsis display row ("…") ends when the next REAL (non-ellipsis) source
// line starts. LyricsView.makeLayerBackedRows used to scan for that inline as:
//
//     for nextIndex in max(index + 1, firstRealIndex)..<sourceLines.count { ... }
//
// `index` is a DISPLAY-space index (display rows can be segmented, so there can be MORE display
// rows than source lines) while `sourceLines.count` is SOURCE-space. When a prelude/interlude
// ellipsis lands at a display index whose `index + 1` (or `firstRealIndex`) exceeds the source
// line count — or during the brief window where the published `lyrics` array has already shrunk
// but the display cache has not — the range's lowerBound exceeds its upperBound and Swift traps
// (`Range requires lowerBound <= upperBound`, EXC_BREAKPOINT on the main thread). This crashed
// nanoPod on CJK songs with preludes (e.g. 君は1000% / 1986オメガトライブ), reproduced across two
// builds with an identical faulting stack.
//
// This pure function never forms an inverted range: when the scan start is not strictly inside the
// source array it simply falls through to the prelude line's own end time (the original fallback).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
/// Glyphs treated as prelude / interlude ellipsis rows (the "…" display line).
/// Shared by `LyricLayerRowBuilder` and `LyricsView` so the crash-era scan and
/// the display-line splitter never disagree on what counts as a prelude.
enum LyricPreludeGlyph {
    static let ellipsisPatterns = ["...", "…", "⋯", "。。。", "···", "・・・"]

    static func isEllipsis(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return ellipsisPatterns.contains(trimmed) || trimmed.isEmpty
    }
}

public enum LyricPreludeResolution {

    /// Resolve the end time for a prelude/ellipsis display row.
    ///
    /// - Parameters:
    ///   - displayIndex: the prelude row's index in the DISPLAY array (may exceed `sourceLines.count`).
    ///   - preludeLineEndTime: the prelude line's own end time — the fallback when no next real line exists.
    ///   - sourceLines: the published source lyric lines (SOURCE-space).
    ///   - firstRealIndex: index of the first real (non-prelude) source line.
    ///   - isEllipsis: predicate identifying an ellipsis/prelude line by its text.
    /// - Returns: the start time of the next real source line, or `preludeLineEndTime` if there is none.
    public static func preludeEndTime(
        displayIndex: Int,
        preludeLineEndTime: TimeInterval,
        sourceLines: [LyricLine],
        firstRealIndex: Int,
        isEllipsis: (String) -> Bool
    ) -> TimeInterval {
        let count = sourceLines.count
        guard count > 0 else { return preludeLineEndTime }

        // A leading prelude (display row 0) ends at the first real line's start — but only if that
        // index is genuinely inside the source array (it may not be during a shrink/desync).
        if displayIndex == 0, firstRealIndex >= 0, firstRealIndex < count {
            return sourceLines[firstRealIndex].startTime
        }

        // Otherwise scan forward from just past this prelude (never before firstRealIndex) for the
        // next non-ellipsis line. The `scanStart < count` guard is what makes this crash-safe: when
        // the display index has run past the source array, we never build an inverted range.
        let scanStart = max(displayIndex + 1, firstRealIndex)
        if scanStart >= 0, scanStart < count {
            for nextIndex in scanStart..<count where !isEllipsis(sourceLines[nextIndex].text) {
                return sourceLines[nextIndex].startTime
            }
        }
        return preludeLineEndTime
    }
}
