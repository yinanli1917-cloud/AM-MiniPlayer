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

        let hasExplicitWhitespace = visibleWords.contains { item in
            item.raw.contains(where: { $0.isWhitespace })
        }
        let needsSyntheticSpaces = !hasExplicitWhitespace && shouldUseSyntheticSpaces(
            for: visibleWords.map(\.trimmed)
        )

        return visibleWords.enumerated().map { offset, item in
            var text = item.trimmed
            let isLast = offset == visibleWords.count - 1
            if !isLast {
                let next = visibleWords[offset + 1]
                if hasExplicitWhitespace {
                    if item.raw.last?.isWhitespace == true || next.raw.first?.isWhitespace == true {
                        text += " "
                    }
                } else if needsSyntheticSpaces {
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
}
