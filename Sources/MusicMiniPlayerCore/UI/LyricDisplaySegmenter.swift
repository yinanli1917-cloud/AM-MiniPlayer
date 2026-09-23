import Foundation

struct LyricDisplaySegmentationOptions: Equatable {
    let maxVisualLines: Int
    let maxLineUnits: Double

    init(maxVisualLines: Int = 3, maxLineUnits: Double) {
        self.maxVisualLines = max(1, maxVisualLines)
        self.maxLineUnits = max(1, maxLineUnits)
    }

    static let mainLyric = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 7.0)
    static let translation = LyricDisplaySegmentationOptions(maxVisualLines: 3, maxLineUnits: 14.0)

    var maxSegmentUnits: Double {
        maxLineUnits * Double(maxVisualLines)
    }
}

struct LyricTimedDisplayToken: Equatable {
    let word: LyricWord
    let text: String
}

// MARK: - Plan A: real-wrap-driven splitting (2026-09-22, founder-approved)
//
// Supersedes the unit-based `segments`/`balancedSegments` trigger for
// LyricsView.makeDisplayLyricLines' split decision: whether and where a line
// splits is now driven by the RENDERER'S OWN real NSLayoutManager wrap
// measurement (LyricDisplayLineMeasurement) at the CURRENT lyrics column
// width, not an estimated character-unit budget -- see
// docs/lyrics-ux-contract.md §E and research/long-line-eval-2026-09-22.md.
// The `segments`/`balancedSegments`/`wordSegments`/`estimatedVisualLineCount`
// functions above are left as-is (still covered by their existing tests) but
// are no longer called from the production split path.

/// Options for `LyricDisplaySegmenter.realWrapPieces` / `realWrapWordPieces` / `proportionalTiming`.
struct LyricRealWrapSplitOptions: Equatable {
    /// Every displayed piece should fit within this many real visual lines. A
    /// single unbreakable token that itself exceeds this is exempt (never
    /// split inside a word).
    let maxVisualLinesPerPiece: Int
    /// A piece at or below this glyph count (after trimming whitespace) is an
    /// orphan; the splitter avoids leaving one when a rebalance can prevent it.
    let minOrphanGlyphCount: Int
    /// A line-level piece whose proportional duration would fall below this
    /// floor is folded into a neighbour instead of flashing on screen.
    let minimumPieceDuration: TimeInterval

    static let `default` = LyricRealWrapSplitOptions(
        maxVisualLinesPerPiece: 2,
        minOrphanGlyphCount: 2,
        minimumPieceDuration: 1.2
    )
}

/// A text piece with its own start/end time -- line-level proportional timing
/// or word-level exact timing, both produced by `LyricDisplaySegmenter`.
struct LyricTimedPiece: Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum LyricDisplaySegmenter {
    private static let phraseBoundaryWhitespaceDuration: TimeInterval = 0.35

    static func displayText(
        for text: String,
        options: LyricDisplaySegmentationOptions
    ) -> String {
        segments(for: text, options: options).joined(separator: "\n")
    }

    static func segments(
        for text: String,
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var result: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            result.append(contentsOf: segmentSingleLine(trimmed, options: options))
        }
        return result.isEmpty ? [] : polishedWordDelimitedSegments(result, options: options)
    }

    static func balancedSegments(
        for text: String,
        count: Int,
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        guard count > 1 else { return segments(for: text, options: options) }
        let existing = segments(for: text, options: options)
        if existing.count == count { return existing }

        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let tokens = wrapTokens(from: normalized)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !tokens.isEmpty else { return [] }

        let totalUnits = tokens.reduce(0) { $0 + displayUnits(for: $1) }
        let targetUnits = max(1, totalUnits / Double(count))
        var result: [String] = []
        var current = ""
        var currentUnits: Double = 0

        for (index, token) in tokens.enumerated() {
            let remainingTokens = tokens.count - index
            let remainingSlots = count - result.count - 1
            if !current.isEmpty,
               currentUnits >= targetUnits,
               remainingSlots > 0,
               remainingTokens > remainingSlots {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll()
                currentUnits = 0
            }
            current += token
            currentUnits += displayUnits(for: token)
        }

        if !current.isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }

        let polished = polishedWordDelimitedSegments(result.filter { !$0.isEmpty }, options: options)
        if polished.count == count {
            return polished
        }
        if polished.count < count {
            let forced = forcedBalancedSegments(normalized, count: count, options: options)
            if forced.count == count {
                return forced
            }
        }
        if result.count < count, existing.count > result.count {
            return existing
        }
        return polished
    }

    static func wordSegments(
        for words: [LyricWord],
        options: LyricDisplaySegmentationOptions
    ) -> [[LyricWord]] {
        guard !words.isEmpty else { return [] }

        var result: [[LyricWord]] = []
        var current: [LyricWord] = []
        var currentUnits: Double = 0

        for word in words {
            let trimmedWord = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedWord.isEmpty {
                let whitespaceDuration = max(word.endTime - word.startTime, 0)
                if !current.isEmpty, whitespaceDuration >= phraseBoundaryWhitespaceDuration {
                    result.append(current)
                    current.removeAll()
                    currentUnits = 0
                }
                continue
            }

            let unit = displayUnits(for: trimmedWord)
            let separatorUnit = needsSeparator(before: word, in: current) ? displayUnits(for: " ") : 0
            let nextUnits = currentUnits + separatorUnit + unit

            if !current.isEmpty && nextUnits > options.maxSegmentUnits {
                result.append(current)
                current = [word]
                currentUnits = unit
            } else {
                current.append(word)
                currentUnits = nextUnits
            }

            if isStrongBoundary(trimmedWord), !current.isEmpty {
                result.append(current)
                current.removeAll()
                currentUnits = 0
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return polishedWordSegments(result, options: options)
    }

    static func displayText(forWords words: [LyricWord]) -> String {
        displayTokens(forWords: words).map(\.text).joined()
    }

    static func displayTokens(forWords words: [LyricWord]) -> [LyricTimedDisplayToken] {
        let visibleWords = words.compactMap { word -> (word: LyricWord, raw: String, trimmed: String)? in
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (word, word.word, trimmed)
        }
        guard !visibleWords.isEmpty else { return [] }

        let needsSyntheticSpaces = shouldUseSyntheticSpaces(
            for: visibleWords.map(\.trimmed)
        )

        return visibleWords.enumerated().map { offset, item in
            var text = item.trimmed
            let isLast = offset == visibleWords.count - 1
            if !isLast {
                let next = visibleWords[offset + 1]
                let hasExplicitBoundaryWhitespace = item.raw.last?.isWhitespace == true
                    || next.raw.first?.isWhitespace == true
                if hasExplicitBoundaryWhitespace || needsSyntheticSpaces {
                    text += " "
                }
            }
            return LyricTimedDisplayToken(word: item.word, text: text)
        }
    }

    static func estimatedVisualLineCount(
        for text: String,
        options: LyricDisplaySegmentationOptions
    ) -> Int {
        let units = displayUnits(for: text)
        return max(1, Int(ceil(units / options.maxLineUnits)))
    }

    static func estimatedWrappedLineWordCounts(
        for text: String,
        options: LyricDisplaySegmentationOptions
    ) -> [Int] {
        let words = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return estimatedWrappedLineWordCounts(forWords: words, options: options)
    }

    private static func segmentSingleLine(
        _ text: String,
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        let pieces = punctuationPieces(from: text)
        var result: [String] = []
        var current = ""
        var currentUnits: Double = 0

        for piece in pieces {
            let pieceUnits = displayUnits(for: piece)
            if pieceUnits > options.maxSegmentUnits {
                if !current.isEmpty {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                    current.removeAll()
                    currentUnits = 0
                }
                result.append(contentsOf: hardWrap(piece, options: options))
                continue
            }

            let nextUnits = currentUnits + pieceUnits
            if !current.isEmpty && nextUnits > options.maxSegmentUnits {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = piece
                currentUnits = pieceUnits
            } else {
                current += piece
                currentUnits = nextUnits
            }

            if isStrongBoundary(piece), currentUnits >= options.maxLineUnits {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll()
                currentUnits = 0
            }
        }

        if !current.isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return polishedWordDelimitedSegments(result.filter { !$0.isEmpty }, options: options)
    }

    private static func punctuationPieces(from text: String) -> [String] {
        var pieces: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if isBoundary(character) {
                pieces.append(current)
                current.removeAll()
            }
        }

        if !current.isEmpty {
            pieces.append(current)
        }
        return pieces
    }

    private static func hardWrap(
        _ text: String,
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnits: Double = 0

        for token in wrapTokens(from: text) {
            let tokenUnits = displayUnits(for: token)
            if !current.isEmpty && currentUnits + tokenUnits > options.maxSegmentUnits {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll()
                currentUnits = 0
            }
            if current.isEmpty && token.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            current += token
            currentUnits += tokenUnits
        }

        if !current.isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }
        return polishedWordDelimitedSegments(result.filter { !$0.isEmpty }, options: options)
    }

    private static func polishedWordDelimitedSegments(
        _ segments: [String],
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        segments
    }

    private static func avoidSingleWordOrphans(
        in segments: [String],
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        guard !segments.isEmpty else { return segments }
        let combined = segments.joined(separator: " ")
        guard combined.contains(where: { $0.isWhitespace }) else { return segments }
        guard !containsCompactScript(combined) else { return segments }

        let words = combined
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count > 2, segments.contains(where: { semanticWordCount(in: $0) == 1 }) else {
            return segments
        }

        let targetCount = max(1, min(segments.count, words.count / 2))
        guard targetCount < words.count else { return segments }

        let joined = balancedWordStrings(words, targetCount: targetCount, options: options)
        return joined.isEmpty ? segments : joined
    }

    private static func balancedWordStrings(
        _ words: [String],
        targetCount: Int,
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        if targetCount == 2, let splitIndex = bestTwoWaySplitIndex(forWords: words, options: options) {
            return [
                words[..<splitIndex].joined(separator: " "),
                words[splitIndex...].joined(separator: " "),
            ]
        }

        let splitIndices = balancedSplitIndices(forWords: words, targetCount: targetCount)
        guard !splitIndices.isEmpty else { return [words.joined(separator: " ")] }

        var result: [[String]] = []
        var start = words.startIndex
        for splitIndex in splitIndices {
            result.append(Array(words[start..<splitIndex]))
            start = splitIndex
        }
        result.append(Array(words[start..<words.endIndex]))
        rebalanceOneWordBuckets(&result)
        return result.map { $0.joined(separator: " ") }.filter { !$0.isEmpty }
    }

    private static func forcedBalancedSegments(
        _ text: String,
        count: Int,
        options: LyricDisplaySegmentationOptions
    ) -> [String] {
        guard count > 1 else { return [text] }

        let wordPieces = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        if wordPieces.count >= count {
            let grouped = balancedWordStrings(wordPieces, targetCount: count, options: options)
            if grouped.count == count {
                return grouped
            }
        }

        let glyphs = text.map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard glyphs.count >= count else { return [text] }

        var result: [String] = []
        var current = ""
        var currentUnits: Double = 0
        let totalUnits = glyphs.reduce(0) { $0 + displayUnits(for: $1) }
        let targetUnits = max(1, totalUnits / Double(count))

        for (index, glyph) in glyphs.enumerated() {
            let remainingGlyphsAfterCurrent = glyphs.count - index - 1
            let remainingSlots = count - result.count - 1
            if !current.isEmpty,
               remainingSlots > 0,
               remainingGlyphsAfterCurrent >= remainingSlots,
               currentUnits >= targetUnits {
                result.append(current)
                current.removeAll()
                currentUnits = 0
            }
            current += glyph
            currentUnits += displayUnits(for: glyph)
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result.count == count ? result : [text]
    }

    private static func bestTwoWaySplitIndex(
        forWords words: [String],
        options: LyricDisplaySegmentationOptions
    ) -> Int? {
        guard words.count >= 4 else { return nil }

        var best: (index: Int, score: Double)?
        for index in 2...(words.count - 2) {
            let left = Array(words[..<index])
            let right = Array(words[index...])
            let leftText = left.joined(separator: " ")
            let rightText = right.joined(separator: " ")
            let leftUnits = displayUnits(for: leftText)
            let rightUnits = displayUnits(for: rightText)
            let singleVisualLinePenalty: Double =
                (estimatedVisualLineCount(for: leftText, options: options) == 1 ? 600 : 0)
                + (estimatedVisualLineCount(for: rightText, options: options) == 1 ? 600 : 0)
            let score = singleVisualLinePenalty + abs(leftUnits - rightUnits)
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private static func balancedSplitIndices(forWords words: [String], targetCount: Int) -> [Int] {
        let targetCount = max(1, min(targetCount, max(1, words.count / 2)))
        var current: [String] = []
        var currentUnits: Double = 0
        var splitIndices: [Int] = []
        let totalUnits = displayUnits(for: words.joined(separator: " "))
        let targetUnits = max(1, totalUnits / Double(targetCount))

        for (index, word) in words.enumerated() {
            let remainingWordsAfterCurrent = words.count - index - 1
            let remainingSlots = targetCount - splitIndices.count - 1
            let canCloseCurrent = current.count >= 2
                && remainingSlots > 0
                && remainingWordsAfterCurrent >= remainingSlots * 2
                && currentUnits >= targetUnits

            if canCloseCurrent {
                splitIndices.append(index)
                current.removeAll()
                currentUnits = 0
            }

            if !current.isEmpty {
                currentUnits += displayUnits(for: " ")
            }
            current.append(word)
            currentUnits += displayUnits(for: word)
        }

        return splitIndices
    }

    private static func estimatedWrappedLineWordCounts(
        forWords words: [String],
        options: LyricDisplaySegmentationOptions
    ) -> [Int] {
        guard !words.isEmpty else { return [] }

        var lineCounts: [Int] = []
        var currentCount = 0
        var currentUnits: Double = 0
        let visualLineUnits = options.maxLineUnits + 1.0

        for word in words {
            let wordUnits = displayUnits(for: word)
            let separatorUnits = currentCount == 0 ? 0 : displayUnits(for: " ")
            if currentCount > 0, currentUnits + separatorUnits + wordUnits > visualLineUnits {
                lineCounts.append(currentCount)
                currentCount = 1
                currentUnits = wordUnits
            } else {
                currentCount += 1
                currentUnits += separatorUnits + wordUnits
            }
        }

        if currentCount > 0 {
            lineCounts.append(currentCount)
        }
        return lineCounts
    }

    private static func avoidSingleWordOrphans(
        in segments: [[LyricWord]],
        options: LyricDisplaySegmentationOptions
    ) -> [[LyricWord]] {
        let totalWordCount = segments.reduce(0) { $0 + $1.count }
        guard totalWordCount > 2 else {
            return segments
        }

        guard segments.count > 1, segments.contains(where: { $0.count == 1 }) else {
            return segments
        }

        var result = segments
        rebalanceOneWordBuckets(&result)

        for index in result.indices {
            if result[index].count == 1 {
                if index > result.startIndex,
                   !result[index - 1].isEmpty,
                   wordSegmentUnits(result[index - 1] + result[index], options: options) <= options.maxSegmentUnits {
                    result[index - 1].append(contentsOf: result[index])
                    result[index].removeAll()
                } else if index + 1 < result.endIndex,
                          !result[index + 1].isEmpty,
                          wordSegmentUnits(result[index] + result[index + 1], options: options) <= options.maxSegmentUnits {
                    result[index + 1].insert(contentsOf: result[index], at: 0)
                    result[index].removeAll()
                }
            }
        }

        let compacted = result.filter { !$0.isEmpty }
        return compacted.isEmpty ? segments : compacted
    }

    private static func polishedWordSegments(
        _ segments: [[LyricWord]],
        options: LyricDisplaySegmentationOptions
    ) -> [[LyricWord]] {
        segments
    }

    private static func shouldUseSyntheticSpaces(for words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let avgLen = Double(words.reduce(0) { $0 + $1.count }) / Double(words.count)
        return avgLen > 2
    }

    private static func shouldPreserveCompactPhrase(
        wordCount: Int,
        estimatedLineCount: Int,
        options: LyricDisplaySegmentationOptions
    ) -> Bool {
        guard wordCount > 0 else { return true }
        guard estimatedLineCount <= options.maxVisualLines else { return false }

        // Short lyric phrases can wrap to two or three visual lines in the
        // compact window and still read as one sentence. Splitting those into
        // separate scroll rows makes the cadence look broken.
        return wordCount <= 8 || estimatedLineCount <= 2
    }

    private static func rebalanceOneWordBuckets<T>(_ buckets: inout [[T]]) {
        guard buckets.count > 1 else { return }

        for index in buckets.indices where buckets[index].count == 1 {
            if index > buckets.startIndex, buckets[index - 1].count > 2 {
                buckets[index].insert(buckets[index - 1].removeLast(), at: 0)
            } else if index + 1 < buckets.endIndex, buckets[index + 1].count > 2 {
                buckets[index].append(buckets[index + 1].removeFirst())
            }
        }

        var index = buckets.startIndex
        while index < buckets.endIndex {
            if buckets[index].count == 1 {
                if index > buckets.startIndex {
                    buckets[index - 1].append(contentsOf: buckets[index])
                    buckets[index].removeAll()
                } else if index + 1 < buckets.endIndex {
                    buckets[index + 1].insert(contentsOf: buckets[index], at: 0)
                    buckets[index].removeAll()
                }
            }
            index += 1
        }
    }

    private static func semanticWordCount(in text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .count
    }

    private static func containsCompactScript(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            LanguageUtils.isCJKScalar($0)
                || isKana($0)
                || isHangul($0)
                || isThai($0)
        }
    }

    private static func wordSegmentUnits(_ words: [LyricWord], options: LyricDisplaySegmentationOptions) -> Double {
        var units: Double = 0
        for (index, word) in words.enumerated() {
            if index > 0, needsSeparator(before: word, in: Array(words.prefix(index))) {
                units += displayUnits(for: " ")
            }
            units += displayUnits(for: word.word.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return units
    }

    private static func wrapTokens(from text: String) -> [String] {
        guard text.contains(where: { $0.isWhitespace }) else {
            return text.map(String.init)
        }

        var tokens: [String] = []
        var current = ""
        var currentIsWhitespace: Bool?

        for character in text {
            let isWhitespace = character.isWhitespace
            if let currentIsWhitespace, currentIsWhitespace != isWhitespace {
                tokens.append(current)
                current.removeAll()
            }
            current.append(character)
            currentIsWhitespace = isWhitespace
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func needsSeparator(before word: LyricWord, in current: [LyricWord]) -> Bool {
        guard !current.isEmpty else { return false }
        return !LanguageUtils.containsCJK(word.word)
            && !LanguageUtils.containsCJK(current.last?.word ?? "")
    }

    private static func isBoundary(_ character: Character) -> Bool {
        isStrongBoundary(character) || isWeakBoundary(character)
    }

    private static func isStrongBoundary(_ text: String) -> Bool {
        text.contains { isStrongBoundary($0) }
    }

    private static func isStrongBoundary(_ character: Character) -> Bool {
        ".!?。！？…".contains(character)
    }

    private static func isWeakBoundary(_ character: Character) -> Bool {
        ",;:，、；：،؛¿¡".contains(character)
    }

    private static func displayUnits(for text: String) -> Double {
        text.reduce(0) { partial, character in
            partial + displayUnits(for: character)
        }
    }

    private static func displayUnits(for character: Character) -> Double {
        guard let scalar = character.unicodeScalars.first else { return 1.0 }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return 0.28 }
        if CharacterSet.punctuationCharacters.contains(scalar) { return 0.35 }
        if LanguageUtils.isCJKScalar(scalar)
            || isKana(scalar)
            || isHangul(scalar)
            || isThai(scalar) {
            return 1.0
        }
        if scalar.isASCII { return 0.55 }
        return 0.85
    }

    private static func isKana(_ scalar: UnicodeScalar) -> Bool {
        (0x3040...0x30FF).contains(Int(scalar.value))
    }

    private static func isHangul(_ scalar: UnicodeScalar) -> Bool {
        (0xAC00...0xD7AF).contains(Int(scalar.value))
            || (0x1100...0x11FF).contains(Int(scalar.value))
            || (0x3130...0x318F).contains(Int(scalar.value))
    }

    private static func isThai(_ scalar: UnicodeScalar) -> Bool {
        (0x0E00...0x0E7F).contains(Int(scalar.value))
    }

    // MARK: - Plan A: line-level text splitting (real wrap, priority break points)

    /// Splits `text` into pieces that each fit within
    /// `options.maxVisualLinesPerPiece` real visual lines at `rowWidth`
    /// (measured via `LyricDisplayLineMeasurement`, the SAME NSLayoutManager
    /// recipe the native renderer measures with). Break points, in priority
    /// order: strong punctuation > weak punctuation > script-run boundary >
    /// whitespace nearest the balanced midpoint > (no delimiters at all, and
    /// the text is entirely a compact script -- CJK/kana/hangul/thai, which
    /// carries no inter-word spacing) character boundary nearest the balanced
    /// midpoint. Never splits inside a Latin word (Latin text with no
    /// delimiter at all falls through every tier and is returned whole). An
    /// orphan piece (<= `options.minOrphanGlyphCount` glyphs) is folded into
    /// a neighbour as a final pass.
    static func realWrapPieces(
        for text: String,
        rowWidth: CGFloat,
        isBackground: Bool = false,
        options: LyricRealWrapSplitOptions = .default
    ) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pieces = splitRecursively(trimmed, rowWidth: rowWidth, isBackground: isBackground, options: options)
        return mergeOrphanTextPieces(pieces, minGlyphs: options.minOrphanGlyphCount)
    }

    private static func splitRecursively(
        _ text: String,
        rowWidth: CGFloat,
        isBackground: Bool,
        options: LyricRealWrapSplitOptions
    ) -> [String] {
        guard LyricDisplayLineMeasurement.visualLineCount(for: text, rowWidth: rowWidth, isBackground: isBackground) > options.maxVisualLinesPerPiece else {
            return [text]
        }
        guard let cut = bestRealWrapCut(in: text, options: options) else {
            return [text] // unbreakable token -- allowed to exceed the target
        }
        let left = String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespaces)
        let right = String(text[cut...]).trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return [text] }
        return splitRecursively(left, rowWidth: rowWidth, isBackground: isBackground, options: options)
            + splitRecursively(right, rowWidth: rowWidth, isBackground: isBackground, options: options)
    }

    /// Finds the best `String.Index` to cut `text` at, per the priority order
    /// documented on `realWrapPieces`. Returns nil when there is no
    /// candidate at all (an unbreakable token).
    private static func bestRealWrapCut(in text: String, options: LyricRealWrapSplitOptions) -> String.Index? {
        let chars = Array(text)
        guard chars.count > 1 else { return nil }
        let balancedOffset = chars.count / 2

        func pick(_ offsets: [Int]) -> Int? {
            guard !offsets.isEmpty else { return nil }
            let safe = offsets.filter { $0 >= options.minOrphanGlyphCount && chars.count - $0 >= options.minOrphanGlyphCount }
            let pool = safe.isEmpty ? offsets : safe
            return pool.min(by: { abs($0 - balancedOffset) < abs($1 - balancedOffset) })
        }

        // 1-2. Strong / weak punctuation: cut right after the punctuation
        // character (and any immediately-following closing quote/bracket).
        let strongOffsets = punctuationCutOffsets(chars, isBoundary: isStrongBoundary)
        let weakOffsets = punctuationCutOffsets(chars, isBoundary: isWeakBoundary)

        // 3. Script-run boundary: the point where the Unicode script class
        // changes (e.g. CJK -> Latin). Only a genuine compact<->Latin
        // transition counts -- NOT a transition into/out of `.other`
        // (apostrophes, hyphens, quotes, symbols), which would otherwise
        // treat punctuation glued to a word (e.g. the apostrophe in "Don't")
        // as a script boundary and cut straight through the middle of it.
        var scriptOffsets: [Int] = []
        for i in 1..<chars.count {
            let prev = scriptClass(chars[i - 1])
            let next = scriptClass(chars[i])
            guard prev != next, (prev == .compact || prev == .latin), (next == .compact || next == .latin) else { continue }
            scriptOffsets.append(i)
        }

        // 4. Whitespace: cut at the start of the next non-whitespace run.
        var whitespaceOffsets: [Int] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace {
                var j = i
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count { whitespaceOffsets.append(j) }
                i = j
            } else {
                i += 1
            }
        }

        // 5. Compact-script (CJK/kana/hangul/thai) character boundary --
        // ONLY when the whole string has no punctuation and no whitespace to
        // fall back on AND is entirely a compact script (those scripts do
        // not mark word boundaries with spaces, so cutting between two
        // characters is not "inside a word" the way it would be for Latin).
        var compactScriptOffsets: [Int] = []
        if strongOffsets.isEmpty, weakOffsets.isEmpty, whitespaceOffsets.isEmpty,
           chars.allSatisfy({ scriptClass($0) == .compact }) {
            compactScriptOffsets = Array(1..<chars.count)
        }

        if let offset = pick(strongOffsets) { return text.index(text.startIndex, offsetBy: offset) }
        if let offset = pick(weakOffsets) { return text.index(text.startIndex, offsetBy: offset) }
        if let offset = pick(scriptOffsets) { return text.index(text.startIndex, offsetBy: offset) }
        if let offset = pick(whitespaceOffsets) { return text.index(text.startIndex, offsetBy: offset) }
        if let offset = pick(compactScriptOffsets) { return text.index(text.startIndex, offsetBy: offset) }
        return nil
    }

    private static func punctuationCutOffsets(_ chars: [Character], isBoundary: (Character) -> Bool) -> [Int] {
        var offsets: [Int] = []
        for i in chars.indices where isBoundary(chars[i]) {
            var j = i + 1
            while j < chars.count, chars[j].isWhitespace || "\"'\u{201d}\u{2019}\u{3011}\u{300d}\u{300f})".contains(chars[j]) { j += 1 }
            if j < chars.count { offsets.append(j) }
        }
        return offsets
    }

    private enum ScriptClass: Equatable {
        case compact // CJK / kana / hangul / thai -- no inter-word spacing
        case latin
        case whitespace
        case other
    }

    private static func scriptClass(_ character: Character) -> ScriptClass {
        if character.isWhitespace { return .whitespace }
        guard let scalar = character.unicodeScalars.first else { return .other }
        if LanguageUtils.isCJKScalar(scalar) || isKana(scalar) || isHangul(scalar) || isThai(scalar) {
            return .compact
        }
        if scalar.isASCII, CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
            return .latin
        }
        return .other
    }

    private static func mergeOrphanTextPieces(_ pieces: [String], minGlyphs: Int) -> [String] {
        guard pieces.count > 1 else { return pieces }
        var result = pieces
        var index = 0
        while index < result.count {
            let glyphCount = result[index].trimmingCharacters(in: .whitespacesAndNewlines).count
            guard glyphCount > 0, glyphCount <= minGlyphs, result.count > 1 else { index += 1; continue }
            if index > 0 {
                result[index - 1] += textJoinSeparator(result[index - 1], result[index]) + result[index]
                result.remove(at: index)
            } else {
                result[index + 1] = result[index] + textJoinSeparator(result[index], result[index + 1]) + result[index + 1]
                result.remove(at: index)
            }
        }
        return result
    }

    private static func textJoinSeparator(_ left: String, _ right: String) -> String {
        guard let lastLeft = left.last, let firstRight = right.first else { return "" }
        func isCompact(_ ch: Character) -> Bool {
            guard let scalar = ch.unicodeScalars.first else { return false }
            return LanguageUtils.isCJKScalar(scalar) || isKana(scalar) || isHangul(scalar) || isThai(scalar)
        }
        return (isCompact(lastLeft) || isCompact(firstRight)) ? "" : " "
    }

    // MARK: - Plan A: line-level timing (proportional to display length, merge short pieces)

    /// Distributes `[lineStart, lineEnd]` across `pieces` proportional to each
    /// piece's own display length (character count) rather than dividing
    /// equally, then folds any piece whose resulting duration would fall
    /// below `options.minimumPieceDuration` into a neighbour (merging text
    /// too) so it never flashes on screen for a fraction of a second.
    static func proportionalTiming(
        for pieces: [String],
        lineStart: TimeInterval,
        lineEnd: TimeInterval,
        options: LyricRealWrapSplitOptions = .default
    ) -> [LyricTimedPiece] {
        guard pieces.count > 1 else {
            return pieces.map { LyricTimedPiece(text: $0, startTime: lineStart, endTime: lineEnd) }
        }
        let duration = max(0, lineEnd - lineStart)
        guard duration > 0 else {
            return [LyricTimedPiece(text: pieces.joined(), startTime: lineStart, endTime: lineEnd)]
        }

        var texts = pieces
        while texts.count > 1 {
            let weights = texts.map { max(1, $0.trimmingCharacters(in: .whitespacesAndNewlines).count) }
            let totalWeight = weights.reduce(0, +)
            let pieceDurations = weights.map { duration * Double($0) / Double(totalWeight) }
            guard let shortIndex = pieceDurations.firstIndex(where: { $0 < options.minimumPieceDuration }) else { break }
            let mergeWithPrevious: Bool
            if shortIndex == 0 {
                mergeWithPrevious = false
            } else if shortIndex == texts.count - 1 {
                mergeWithPrevious = true
            } else {
                mergeWithPrevious = weights[shortIndex - 1] <= weights[shortIndex + 1]
            }
            if mergeWithPrevious {
                texts[shortIndex - 1] += textJoinSeparator(texts[shortIndex - 1], texts[shortIndex]) + texts[shortIndex]
                texts.remove(at: shortIndex)
            } else {
                texts[shortIndex + 1] = texts[shortIndex] + textJoinSeparator(texts[shortIndex], texts[shortIndex + 1]) + texts[shortIndex + 1]
                texts.remove(at: shortIndex)
            }
        }

        guard texts.count > 1 else {
            return [LyricTimedPiece(text: texts.joined(), startTime: lineStart, endTime: lineEnd)]
        }

        let weights = texts.map { max(1, $0.trimmingCharacters(in: .whitespacesAndNewlines).count) }
        let totalWeight = weights.reduce(0, +)
        var cursor = lineStart
        var result: [LyricTimedPiece] = []
        for (index, text) in texts.enumerated() {
            let share = Double(weights[index]) / Double(totalWeight)
            let start = cursor
            let end = index == texts.count - 1 ? lineEnd : start + duration * share
            result.append(LyricTimedPiece(text: text, startTime: start, endTime: end))
            cursor = end
        }
        return result
    }

    // MARK: - Plan A: word-level splitting (exact timing; breath-gap break points)

    /// Splits `words` (a syllable-synced line) into groups that each fit
    /// within `options.maxVisualLinesPerPiece` real visual lines at
    /// `rowWidth`. Each group keeps its own `LyricWord`s verbatim -- the
    /// caller derives start/end from `group.first`/`group.last`, so timing
    /// error against the source data is always exactly zero. Break points
    /// prefer the largest inter-word silence near the balanced midpoint
    /// (lyric-align "breath split" style -- see
    /// research/long-line-eval-2026-09-22.md); with no clear pause, falls
    /// back to the plain balanced word-count midpoint (still a boundary
    /// BETWEEN words, never inside one -- `LyricWord` is already the atomic
    /// unit).
    static func realWrapWordPieces(
        for words: [LyricWord],
        rowWidth: CGFloat,
        options: LyricRealWrapSplitOptions = .default
    ) -> [[LyricWord]] {
        guard !words.isEmpty else { return [] }
        let text = displayText(forWords: words)
        guard LyricDisplayLineMeasurement.visualLineCount(for: text, rowWidth: rowWidth) > options.maxVisualLinesPerPiece else {
            return [words]
        }
        guard words.count > 1, let cutIndex = bestBreathGapCutIndex(words: words) else {
            return [words] // a single atomic word/character token -- unbreakable
        }
        let left = Array(words[..<cutIndex])
        let right = Array(words[cutIndex...])
        return realWrapWordPieces(for: left, rowWidth: rowWidth, options: options)
            + realWrapWordPieces(for: right, rowWidth: rowWidth, options: options)
    }

    private static func balancedWordSplitIndex(_ words: [LyricWord]) -> Int? {
        guard words.count > 1 else { return nil }
        let lens = words.map { max(1, $0.word.count) }
        let total = lens.reduce(0, +)
        var running = 0
        var bestIndex = 1
        var bestDiff = Int.max
        for i in 1..<words.count {
            running += lens[i - 1]
            let diff = abs(2 * running - total)
            if diff < bestDiff { bestDiff = diff; bestIndex = i }
        }
        return bestIndex
    }

    private static func bestBreathGapCutIndex(words: [LyricWord]) -> Int? {
        guard let balanced = balancedWordSplitIndex(words) else { return nil }
        let windowRadius = max(1, words.count / 3)
        let lo = max(1, balanced - windowRadius)
        let hi = min(words.count - 1, balanced + windowRadius)
        guard lo <= hi else { return balanced }
        var bestIndex = balanced
        var bestGap: TimeInterval = -1
        for i in lo...hi {
            let gap = words[i].startTime - words[i - 1].endTime
            if gap > bestGap {
                bestGap = gap
                bestIndex = i
            }
        }
        // A gap this small isn't a genuine breath -- still cut, just at the
        // plain balanced word boundary rather than pretending a micro-gap is
        // meaningful.
        return bestGap >= 0.12 ? bestIndex : balanced
    }
}
