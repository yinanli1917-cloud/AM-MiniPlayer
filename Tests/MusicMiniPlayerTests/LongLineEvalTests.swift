import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder complaint (2026-09-22): a single lyric line can wrap to 4+ visual
// lines and fill the whole player window. The existing mitigation
// (LyricDisplaySegmenter, wired into LyricsView.makeDisplayLyricLines) splits
// long LINE-LEVEL text by a unit budget with equal-duration timing, but never
// splits WORD-LEVEL (hasSyllableSync) lines at all, breaks land mid-phrase,
// and the translation is chopped into the same piece count regardless of its
// own punctuation.
//
// This is an EVAL harness, not a regression gate: it measures the CURRENT
// behavior against Tests/MusicMiniPlayerTests/Fixtures/long_line_eval.json
// (real lines harvested from the on-disk lyrics cache + repo fixtures,
// synthetic adversarial lines, and a ground-truth-timing subset) and prints a
// metrics table per research/long-line-eval-2026-09-22.md. It also simulates
// three candidate generalized designs using ALREADY-EXISTING production
// entry points (LyricDisplaySegmenter.wordSegments, a proportional-timing
// re-weighting, a punctuation-only splitter) so they can be compared on the
// same metrics without touching production code.
//
// No Sources/ changes were made for this task. `makeDisplayLyricLines`,
// `shouldKeepDisplayLineUnsplit`, and `displayTiming` are `private` methods
// on the `LyricsView` SwiftUI View (LyricsView.swift ~line 2014) -- the
// project's own convention for testing this kind of private View logic
// (see NativeLyricsSurfaceSourceTests.swift, RapidSwitchTests.swift) is to
// read the source file as text and assert on it, NOT to relax access
// control. `EvalDisplaySegmentation` below mirrors those three methods
// exactly (same three call sites: LyricDisplaySegmenter.segments /
// .balancedSegments, the same 1.65s-per-piece minimum-duration guard, the
// same equal-duration timing split) using ONLY already-internal production
// APIs (LyricDisplaySegmenter, NativeLyricsTextMeasurement,
// NativeLyricsRowMeasurement, NativeLyricsTextConstants — none of them
// `private`). `test_mirrorMatchesProductionSource_contractCheck` below is a
// source-text contract test, in the same style as the existing ones, that
// fails loudly if production drifts from this mirror.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// MARK: - Fixture model

private struct EvalWord: Codable {
    let word: String
    let startTime: Double
    let endTime: Double
}

private struct EvalSong: Codable {
    let key: String
    let album: String?
    let source: String
    let durationSec: Double?
}

private struct EvalLine: Codable {
    let id: String
    let category: String
    let script: String
    let sync: String
    let hasTranslation: Bool
    let song: EvalSong
    let text: String
    let translation: String?
    let startTime: Double
    let endTime: Double
    let isBackground: Bool
    let words: [EvalWord]
    let trueWords: [EvalWord]?
    let note: String?
}

private struct EvalFixture: Codable {
    let lines: [EvalLine]
}

private enum EvalFixtureLoader {
    static func load() throws -> [EvalLine] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/long_line_eval.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EvalFixture.self, from: data).lines
    }

    static func lyricLine(from eval: EvalLine) -> LyricLine {
        let words = eval.words.map { LyricWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) }
        return LyricLine(
            text: eval.text,
            startTime: eval.startTime,
            endTime: eval.endTime,
            words: words,
            translation: eval.translation,
            isBackground: eval.isBackground
        )
    }
}

// MARK: - Mirror of LyricsView.makeDisplayLyricLines (see header comment)

private struct EvalDisplayPiece {
    let text: String
    let translation: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let segmentIndex: Int
    let segmentCount: Int
}

/// Mirrors `LyricsView.lyricMinimumGeneratedSegmentDuration`.
private let mirroredMinimumGeneratedSegmentDuration: TimeInterval = 1.65

private enum EvalDisplaySegmentation {
    static func makeDisplayPieces(from line: LyricLine) -> [EvalDisplayPiece] {
        if LyricPreludeGlyph.isEllipsis(line.text) || isInstrumentalNotice(line.text) {
            return [singlePiece(line)]
        }
        if line.hasSyllableSync {
            return [singlePiece(line)]
        }

        let textSegments = LyricDisplaySegmenter.segments(for: line.text, options: .mainLyric)
        let segmentCount = max(textSegments.count, 1)
        if shouldKeepUnsplit(line, generatedSegmentCount: segmentCount) {
            return [singlePiece(line)]
        }

        let translationSegments = line.translation.map {
            LyricDisplaySegmenter.balancedSegments(for: $0, count: segmentCount, options: .translation)
        } ?? []

        var pieces: [EvalDisplayPiece] = []
        for segmentIndex in 0..<segmentCount {
            let timing = displayTiming(for: line, segmentIndex: segmentIndex, segmentCount: segmentCount)
            pieces.append(EvalDisplayPiece(
                text: textSegments.indices.contains(segmentIndex) ? textSegments[segmentIndex] : line.text,
                translation: translationSegments.indices.contains(segmentIndex) ? translationSegments[segmentIndex] : nil,
                startTime: timing.start,
                endTime: timing.end,
                segmentIndex: segmentIndex,
                segmentCount: segmentCount
            ))
        }
        return pieces
    }

    private static func singlePiece(_ line: LyricLine) -> EvalDisplayPiece {
        EvalDisplayPiece(text: line.text, translation: line.translation, startTime: line.startTime, endTime: line.endTime, segmentIndex: 0, segmentCount: 1)
    }

    private static func shouldKeepUnsplit(_ line: LyricLine, generatedSegmentCount: Int) -> Bool {
        guard generatedSegmentCount > 1 else { return true }
        let duration = line.endTime - line.startTime
        guard duration.isFinite, duration > 0 else { return false }
        return duration / Double(generatedSegmentCount) < mirroredMinimumGeneratedSegmentDuration
    }

    private static func displayTiming(
        for line: LyricLine,
        segmentIndex: Int,
        segmentCount: Int
    ) -> (start: TimeInterval, end: TimeInterval) {
        let duration = max(0, line.endTime - line.startTime)
        guard segmentCount > 1, duration > 0 else { return (line.startTime, line.endTime) }
        let segmentDuration = duration / Double(segmentCount)
        let start = line.startTime + segmentDuration * Double(segmentIndex)
        let end = segmentIndex == segmentCount - 1 ? line.endTime : start + segmentDuration
        return (start, end)
    }
}

// MARK: - Candidate C: proportional-to-characters timing (same text splits, different timing rule)

private enum EvalProportionalTiming {
    /// Same `pieces` (same text/translation splits as current code) but each
    /// piece's duration is weighted by its own character count instead of
    /// dividing the line duration equally.
    static func retimed(_ pieces: [EvalDisplayPiece], line: LyricLine) -> [EvalDisplayPiece] {
        guard pieces.count > 1 else { return pieces }
        let duration = max(0, line.endTime - line.startTime)
        guard duration > 0 else { return pieces }
        let weights = pieces.map { max(1, $0.text.count) }
        let totalWeight = weights.reduce(0, +)
        var cursor = line.startTime
        var result: [EvalDisplayPiece] = []
        for (index, piece) in pieces.enumerated() {
            let share = Double(weights[index]) / Double(totalWeight)
            let pieceDuration = duration * share
            let start = cursor
            let end = index == pieces.count - 1 ? line.endTime : start + pieceDuration
            result.append(EvalDisplayPiece(text: piece.text, translation: piece.translation, startTime: start, endTime: end, segmentIndex: piece.segmentIndex, segmentCount: piece.segmentCount))
            cursor = end
        }
        return result
    }
}

// MARK: - Candidate B: punctuation-only splitter (never cuts mid-phrase, ignores the unit budget)

private enum EvalPunctuationOnlySplitter {
    static func pieces(for line: LyricLine) -> [EvalDisplayPiece] {
        guard !line.hasSyllableSync else {
            // Candidate B still refuses to touch word-level lines in this
            // simulation (that's Candidate A's job) so the two designs stay
            // comparable to the current-code baseline on the same axis.
            return [EvalDisplayPiece(text: line.text, translation: line.translation, startTime: line.startTime, endTime: line.endTime, segmentIndex: 0, segmentCount: 1)]
        }
        let strongBoundary = CharacterSet(charactersIn: ".!?。!?…")
        var pieces: [String] = []
        var current = ""
        for scalar in line.text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if strongBoundary.contains(scalar) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { pieces.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty { pieces.append(trailing) }
        guard pieces.count > 1 else {
            return [EvalDisplayPiece(text: line.text, translation: line.translation, startTime: line.startTime, endTime: line.endTime, segmentIndex: 0, segmentCount: 1)]
        }

        let translationPieces = line.translation.map {
            LyricDisplaySegmenter.balancedSegments(for: $0, count: pieces.count, options: .translation)
        } ?? []
        let duration = max(0, line.endTime - line.startTime)
        let segmentDuration = pieces.isEmpty ? 0 : duration / Double(pieces.count)
        return pieces.enumerated().map { index, text in
            let start = line.startTime + segmentDuration * Double(index)
            let end = index == pieces.count - 1 ? line.endTime : start + segmentDuration
            return EvalDisplayPiece(
                text: text,
                translation: translationPieces.indices.contains(index) ? translationPieces[index] : nil,
                startTime: start, endTime: end, segmentIndex: index, segmentCount: pieces.count
            )
        }
    }
}

// MARK: - Candidate A: word-level split via the ALREADY-EXISTING (but unused for hasSyllableSync
// lines) LyricDisplaySegmenter.wordSegments, with EXACT per-piece timing from real word times.

private enum EvalWordLevelSplitter {
    static func pieces(for line: LyricLine) -> [EvalDisplayPiece] {
        guard line.hasSyllableSync else { return [] }
        let groups = LyricDisplaySegmenter.wordSegments(for: line.words, options: .mainLyric)
        guard groups.count > 1 else {
            return [EvalDisplayPiece(text: line.text, translation: line.translation, startTime: line.startTime, endTime: line.endTime, segmentIndex: 0, segmentCount: 1)]
        }
        return groups.enumerated().map { index, group in
            let text = group.map(\.word).joined()
            let start = group.first?.startTime ?? line.startTime
            let end = group.last?.endTime ?? line.endTime
            return EvalDisplayPiece(text: text, translation: nil, startTime: start, endTime: end, segmentIndex: index, segmentCount: groups.count)
        }
    }
}

// MARK: - Visual-line measurement (uses the RENDERER's own NSLayoutManager recipe directly --
// NativeLyricsTextMeasurement / NativeLyricsRowMeasurement / NativeLyricsTextConstants are all
// already `internal`, no seam needed)

private enum EvalWidth {
    static let narrow: CGFloat = 180   // MusicMiniPlayerApp.swift snappableWindow.minSize
    static let defaultLaunch: CGFloat = 250 // MusicMiniPlayerApp.swift first-launch windowSize
}

private func visualLineCount(_ text: String, windowWidth: CGFloat, isBackground: Bool = false) -> Int {
    guard !text.isEmpty else { return 0 }
    let constants = NativeLyricsTextConstants(scale: NativeLyricsTextConstants.scale(forBackground: isBackground))
    let font = NSFont.systemFont(ofSize: constants.mainFontSize, weight: .semibold)
    let width = NativeLyricsRowMeasurement.textWidth(for: text, font: font, rowWidth: windowWidth, lineSpacing: constants.mainLineSpacing)
    return NativeLyricsTextMeasurement.metrics(text, width: width, font: font, lineSpacing: constants.mainLineSpacing).lineCount
}

// MARK: - Break-quality classification

private enum BreakKind: String { case punctuation, whitespaceGap, scriptBoundary, midWord }

private func scriptOf(_ ch: Character) -> String {
    guard let scalar = ch.unicodeScalars.first else { return "other" }
    if LanguageUtils.isCJKScalar(scalar) { return "cjk" }
    if (0x3040...0x30FF).contains(Int(scalar.value)) { return "kana" }
    if (0xAC00...0xD7AF).contains(Int(scalar.value)) { return "hangul" }
    if scalar.isASCII, CharacterSet.letters.contains(scalar) { return "latin" }
    return "other"
}

private func isBoundaryPunctuation(_ ch: Character) -> Bool {
    ".!?。!?…,;:,、;:،؛¿¡".contains(ch)
}

/// Locates each piece's character range in `original` by scanning forward
/// (pieces are trimmed contiguous substrings of the original text, aside
/// from separators the segmenter strips at cut points).
private func locatePieceRanges(original: String, pieces: [String]) -> [(start: Int, end: Int)] {
    let chars = Array(original)
    var searchFrom = 0
    var ranges: [(Int, Int)] = []
    for piece in pieces {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { ranges.append((searchFrom, searchFrom)); continue }
        let needle = Array(trimmed)
        var found: Int? = nil
        if !needle.isEmpty, needle.count <= chars.count {
            var i = searchFrom
            while i <= chars.count - needle.count {
                if Array(chars[i..<i + needle.count]) == needle { found = i; break }
                i += 1
            }
        }
        guard let start = found else { ranges.append((searchFrom, searchFrom)); continue }
        let end = start + needle.count
        ranges.append((start, end))
        searchFrom = end
    }
    return ranges
}

private struct BreakQualityReport {
    var punctuation = 0
    var whitespaceGap = 0
    var scriptBoundary = 0
    var midWord = 0
    var total: Int { punctuation + whitespaceGap + scriptBoundary + midWord }
}

private func classifyBreaks(original: String, pieces: [String]) -> BreakQualityReport {
    var report = BreakQualityReport()
    guard pieces.count > 1 else { return report }
    let chars = Array(original)
    let ranges = locatePieceRanges(original: original, pieces: pieces)
    for i in 0..<(ranges.count - 1) {
        let cut = ranges[i].end
        guard cut > 0, cut <= chars.count else { continue }
        let before = chars[cut - 1]
        var afterIdx = cut
        var sawWhitespace = false
        while afterIdx < chars.count, chars[afterIdx].isWhitespace {
            sawWhitespace = true
            afterIdx += 1
        }
        let after = afterIdx < chars.count ? chars[afterIdx] : nil
        if isBoundaryPunctuation(before) {
            report.punctuation += 1
        } else if before.isWhitespace || sawWhitespace {
            report.whitespaceGap += 1
        } else if let after, scriptOf(before) != scriptOf(after) {
            report.scriptBoundary += 1
        } else {
            report.midWord += 1
        }
    }
    return report
}

private func orphanPieceCount(_ pieces: [String]) -> Int {
    pieces.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count <= 2 }.count
}

// MARK: - Ground-truth timing scoring

private func wordCharStartTimes(_ words: [EvalWord]) -> [(charStart: Int, charEnd: Int, startTime: TimeInterval)] {
    var spans: [(Int, Int, TimeInterval)] = []
    var cursor = 0
    for w in words {
        let len = w.word.count
        spans.append((cursor, cursor + len, w.startTime))
        cursor += len
    }
    return spans
}

private func trueStartTime(atCharOffset offset: Int, spans: [(charStart: Int, charEnd: Int, startTime: TimeInterval)]) -> TimeInterval? {
    for span in spans where offset >= span.charStart && offset < span.charEnd {
        return span.startTime
    }
    return spans.last?.startTime
}

private func timingErrors(pieces: [EvalDisplayPiece], originalText: String, trueWords: [EvalWord]) -> [Double] {
    guard pieces.count > 1 else { return [] }
    let ranges = locatePieceRanges(original: originalText, pieces: pieces.map(\.text))
    let spans = wordCharStartTimes(trueWords)
    var errors: [Double] = []
    for (index, piece) in pieces.enumerated() {
        guard let trueStart = trueStartTime(atCharOffset: ranges[index].start, spans: spans) else { continue }
        errors.append(abs(piece.startTime - trueStart))
    }
    return errors
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

private func p90(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = min(sorted.count - 1, Int(ceil(0.9 * Double(sorted.count))) - 1)
    return sorted[max(0, idx)]
}

// MARK: - Per-line metrics

private struct LineMetrics {
    let id: String
    let category: String
    let script: String
    let sync: String
    let hasTranslation: Bool
    let maxVisualLinesNarrow: Int
    let maxVisualLinesDefault: Int
    let pieceCount: Int
    let breakQuality: BreakQualityReport
    let orphanTranslationPieces: Int
    let stillFourPlusNarrow: Bool
}

private func computeMetrics(for eval: EvalLine, pieces: [EvalDisplayPiece]) -> LineMetrics {
    let narrowCounts = pieces.map { visualLineCount($0.text, windowWidth: EvalWidth.narrow, isBackground: eval.isBackground) }
    let defaultCounts = pieces.map { visualLineCount($0.text, windowWidth: EvalWidth.defaultLaunch, isBackground: eval.isBackground) }
    let breaks = classifyBreaks(original: eval.text, pieces: pieces.map(\.text))
    let translationPieces = pieces.compactMap(\.translation)
    return LineMetrics(
        id: eval.id, category: eval.category, script: eval.script, sync: eval.sync, hasTranslation: eval.hasTranslation,
        maxVisualLinesNarrow: narrowCounts.max() ?? 0,
        maxVisualLinesDefault: defaultCounts.max() ?? 0,
        pieceCount: pieces.count,
        breakQuality: breaks,
        orphanTranslationPieces: orphanPieceCount(translationPieces),
        stillFourPlusNarrow: (narrowCounts.max() ?? 0) >= 4
    )
}

// MARK: - Tests

final class LongLineEvalTests: XCTestCase {

    private static var fixtureCache: [EvalLine]?

    private func loadFixture() throws -> [EvalLine] {
        if let cached = Self.fixtureCache { return cached }
        let lines = try EvalFixtureLoader.load()
        Self.fixtureCache = lines
        return lines
    }

    // MARK: Baseline: current production behavior

    func test_baseline_currentBehavior_printsMetricsTable() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThan(fixture.count, 0, "eval dataset must not be empty")

        var allMetrics: [LineMetrics] = []
        for eval in fixture {
            let line = EvalFixtureLoader.lyricLine(from: eval)
            let pieces = EvalDisplaySegmentation.makeDisplayPieces(from: line)
            allMetrics.append(computeMetrics(for: eval, pieces: pieces))
        }

        printTable(title: "BASELINE (current LyricsView.makeDisplayLyricLines)", metrics: allMetrics)

        // How far the segmenter's UNIT-based length estimate
        // (LyricDisplaySegmenter.estimatedVisualLineCount, maxLineUnits=7.0)
        // is from the REAL NSLayoutManager wrap count at the narrow width --
        // this is the "should we even try to split this line" signal, and if
        // it systematically undercounts, lines that visually wrap 3-4+ times
        // never trigger a split at all (segmentCount stays 1) regardless of
        // how good the splitter itself is.
        var deltas: [Int] = []
        var undercounts = 0
        for eval in fixture {
            let estimate = LyricDisplaySegmenter.estimatedVisualLineCount(for: eval.text, options: .mainLyric)
            let real = visualLineCount(eval.text, windowWidth: EvalWidth.narrow, isBackground: eval.isBackground)
            let delta = estimate - real
            deltas.append(delta)
            if estimate < real { undercounts += 1 }
        }
        let deltaDoubles = deltas.map(Double.init)
        print("\n=== Unit-estimate vs. real NSLayoutManager wrap (narrow width, whole original text) ===")
        print("  estimate-minus-real: median=\(fmt(median(deltaDoubles))) p90(abs)=\(fmt(p90(deltaDoubles.map(abs)))) min=\(deltas.min() ?? 0) max=\(deltas.max() ?? 0)")
        print("  lines where the estimate UNDERCOUNTS the real wrap (estimate < real, i.e. a split never even triggers): \(undercounts)/\(fixture.count)")

        // Locks in the reproduction of the founder's literal symptom: at least
        // one real word-level (hasSyllableSync) line in the dataset is STILL
        // >=3 visual lines wide, unsplit, at the narrow window width, because
        // makeDisplayLyricLines never splits word-level lines. If this ever
        // starts failing because the count drops to 0, the bug this dataset
        // was built to characterize has been fixed upstream -- update this
        // test alongside the fix, don't just relax it.
        let wordLevelStillLong = allMetrics.filter { $0.sync == "wordLevel" && $0.maxVisualLinesNarrow >= 3 }
        XCTAssertGreaterThan(
            wordLevelStillLong.count, 0,
            "expected the ground-truth word-level lines to still be reproduced as unsplit >=3-visual-line rows under current code"
        )

        // Sanity: every fixture line round-trips to at least one piece.
        XCTAssertTrue(allMetrics.allSatisfy { $0.pieceCount >= 1 })
    }

    // MARK: Candidate A -- word-level split via existing (unused-for-this-path) wordSegments

    func test_candidateA_wordLevelSplit_onGroundTruthAndSyntheticWordLevelLines() throws {
        let fixture = try loadFixture()
        let wordLevelLines = fixture.filter { !$0.words.isEmpty }
        guard !wordLevelLines.isEmpty else {
            throw XCTSkip("no word-level lines in this fixture snapshot")
        }

        var allMetrics: [LineMetrics] = []
        var timingErrorsAll: [Double] = []
        for eval in wordLevelLines {
            let line = EvalFixtureLoader.lyricLine(from: eval)
            let pieces = EvalWordLevelSplitter.pieces(for: line)
            allMetrics.append(computeMetrics(for: eval, pieces: pieces))
            // Candidate A's timing IS the true word timing by construction, so
            // this should read ~0 -- included to make that explicit in the table
            // rather than assumed.
            if pieces.count > 1 {
                let spans = wordCharStartTimes(eval.words.map { EvalWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) })
                let ranges = locatePieceRanges(original: eval.text, pieces: pieces.map(\.text))
                for (idx, _) in pieces.enumerated() {
                    if let t = trueStartTime(atCharOffset: ranges[idx].start, spans: spans) {
                        timingErrorsAll.append(abs(pieces[idx].startTime - t))
                    }
                }
            }
        }
        printTable(title: "CANDIDATE A (wordSegments-based split for word-level lines)", metrics: allMetrics)
        print("  timing error (should be ~0 by construction): median=\(median(timingErrorsAll)) p90=\(p90(timingErrorsAll)) n=\(timingErrorsAll.count)")

        XCTAssertTrue(timingErrorsAll.allSatisfy { $0 < 0.05 }, "Candidate A uses real word times directly, so estimated piece starts must match true starts")
    }

    // MARK: Candidate B -- punctuation-only splitter (line-level lines)

    func test_candidateB_punctuationOnlySplit_onLineLevelLines() throws {
        let fixture = try loadFixture()
        let lineLevelLines = fixture.filter { $0.words.isEmpty && $0.category != "groundTruthTiming" }
        guard !lineLevelLines.isEmpty else { throw XCTSkip("no line-level lines in this fixture snapshot") }

        var allMetrics: [LineMetrics] = []
        for eval in lineLevelLines {
            let line = EvalFixtureLoader.lyricLine(from: eval)
            let pieces = EvalPunctuationOnlySplitter.pieces(for: line)
            allMetrics.append(computeMetrics(for: eval, pieces: pieces))
        }
        printTable(title: "CANDIDATE B (punctuation-only splitter, ignores the unit budget)", metrics: allMetrics)

        // Trade-off this candidate is expected to show: break quality should
        // be perfect (every cut is at a strong-punctuation boundary or the
        // line simply isn't split), but that means lines with NO internal
        // punctuation stay whole and can still be >=4 visual lines.
        let midWordBreaks = allMetrics.reduce(0) { $0 + $1.breakQuality.midWord }
        XCTAssertEqual(midWordBreaks, 0, "a punctuation-only splitter must never cut mid-word/mid-phrase")
    }

    // MARK: Candidate C -- proportional-to-characters timing on the ground-truth subset

    func test_candidateC_proportionalTiming_onGroundTruthSubset() throws {
        let fixture = try loadFixture()
        let groundTruth = fixture.filter { $0.category == "groundTruthTiming" }
        guard !groundTruth.isEmpty else { throw XCTSkip("no groundTruthTiming lines in this fixture snapshot") }

        var currentErrors: [Double] = []
        var proportionalErrors: [Double] = []
        var neverActuallySplitByCurrentCode = 0
        for eval in groundTruth {
            guard let trueWords = eval.trueWords, !trueWords.isEmpty else { continue }
            let line = EvalFixtureLoader.lyricLine(from: eval) // words already stripped to simulate line-level
            let currentPieces = EvalDisplaySegmentation.makeDisplayPieces(from: line)

            // Every ground-truth line in this fixture genuinely wraps to 3
            // visual lines at the narrow width (that's how they were
            // harvested), but they are short in the segmenter's UNIT terms
            // (its maxLineUnits=7.0 budget assumes far more glyphs fit per
            // line than the real 24pt-font/116pt-content-width renderer
            // actually fits) -- so `estimatedVisualLineCount` never crosses
            // the split threshold and `makeDisplayPieces` returns them as a
            // single, unsplit piece. That mismatch IS one of this eval's
            // findings (see the unit-estimate-vs-real-wrap metric in the
            // baseline test); it also means Candidate C has nothing to
            // compare against equal-division timing using the CURRENT
            // split-or-not decision. To still measure "if something splits
            // this line, is proportional timing more accurate than equal
            // division," force a split at the REAL measured visual-line
            // count via the same production `balancedSegments` helper the
            // current translation-splitting path already uses.
            let piecesToScore: [EvalDisplayPiece]
            if currentPieces.count > 1 {
                piecesToScore = currentPieces
            } else {
                neverActuallySplitByCurrentCode += 1
                let realCount = visualLineCount(eval.text, windowWidth: EvalWidth.narrow)
                guard realCount > 1 else { continue }
                let forcedTexts = LyricDisplaySegmenter.balancedSegments(for: eval.text, count: realCount, options: .mainLyric)
                guard forcedTexts.count > 1 else { continue }
                let duration = max(0, line.endTime - line.startTime)
                let segmentDuration = duration / Double(forcedTexts.count)
                piecesToScore = forcedTexts.enumerated().map { index, text in
                    let start = line.startTime + segmentDuration * Double(index)
                    let end = index == forcedTexts.count - 1 ? line.endTime : start + segmentDuration
                    return EvalDisplayPiece(text: text, translation: nil, startTime: start, endTime: end, segmentIndex: index, segmentCount: forcedTexts.count)
                }
            }

            currentErrors.append(contentsOf: timingErrors(pieces: piecesToScore, originalText: eval.text, trueWords: trueWords))
            let proportionalPieces = EvalProportionalTiming.retimed(piecesToScore, line: line)
            proportionalErrors.append(contentsOf: timingErrors(pieces: proportionalPieces, originalText: eval.text, trueWords: trueWords))
        }

        print("\n=== CANDIDATE C: timing error on groundTruthTiming subset (seconds) ===")
        print("  lines the CURRENT segmenter never actually splits (unit estimate too low): \(neverActuallySplitByCurrentCode)/\(groundTruth.count) -- scored via balancedSegments forced to the real visual-line count instead")
        print("  equal division:              median=\(fmt(median(currentErrors))) p90=\(fmt(p90(currentErrors))) max=\(fmt(currentErrors.max() ?? 0)) n=\(currentErrors.count)")
        print("  candidate C (char-weighted): median=\(fmt(median(proportionalErrors))) p90=\(fmt(p90(proportionalErrors))) max=\(fmt(proportionalErrors.max() ?? 0)) n=\(proportionalErrors.count)")

        // This is a baseline-recording test, not a hard regression gate (the
        // ground-truth subset is small and real singing timing doesn't
        // always correlate with character count) -- but flag loudly if a
        // future dataset change makes candidate C surprisingly WORSE than
        // equal division, since that would undercut the design's rationale.
        if !currentErrors.isEmpty, !proportionalErrors.isEmpty {
            XCTAssertLessThanOrEqual(
                median(proportionalErrors), median(currentErrors) * 1.5,
                "character-weighted timing should not be dramatically worse than equal division on this subset"
            )
        }
    }

    // MARK: Source-text contract check (see header comment: no Sources/ seam was added)

    func test_mirrorMatchesProductionSource_contractCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("private let lyricMinimumGeneratedSegmentDuration: TimeInterval = 1.65"),
                      "EvalDisplaySegmentation mirrors this constant -- update mirroredMinimumGeneratedSegmentDuration if this changes")
        XCTAssertTrue(source.contains("if line.hasSyllableSync {"),
                      "EvalDisplaySegmentation mirrors the hasSyllableSync-never-splits branch")
        XCTAssertTrue(source.contains("LyricDisplaySegmenter.segments(for: line.text, options: .mainLyric)"),
                      "EvalDisplaySegmentation mirrors this exact call site")
        XCTAssertTrue(source.contains("LyricDisplaySegmenter.balancedSegments("),
                      "EvalDisplaySegmentation mirrors the translation balancedSegments call")
        XCTAssertTrue(source.contains("return duration / Double(generatedSegmentCount) < lyricMinimumGeneratedSegmentDuration"),
                      "EvalDisplaySegmentation mirrors shouldKeepDisplayLineUnsplit's guard exactly")
        XCTAssertTrue(source.contains("let segmentDuration = duration / Double(segmentCount)"),
                      "EvalDisplaySegmentation mirrors displayTiming's equal-division formula")
    }

    // MARK: - Table printing

    private func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func printTable(title: String, metrics: [LineMetrics]) {
        print("\n=== \(title) ===")
        print("  n=\(metrics.count)")

        let byCategory = Dictionary(grouping: metrics, by: \.category)
        for (category, group) in byCategory.sorted(by: { $0.key < $1.key }) {
            printStratumRow(label: "category=\(category)", group: group)
        }
        let byScript = Dictionary(grouping: metrics, by: \.script)
        for (script, group) in byScript.sorted(by: { $0.key < $1.key }) {
            printStratumRow(label: "script=\(script)", group: group)
        }
        let bySync = Dictionary(grouping: metrics, by: \.sync)
        for (sync, group) in bySync.sorted(by: { $0.key < $1.key }) {
            printStratumRow(label: "sync=\(sync)", group: group)
        }

        let stillFourPlus = metrics.filter(\.stillFourPlusNarrow)
        print("  rows STILL >=4 visual lines at narrow(180) width: \(stillFourPlus.count)/\(metrics.count) -> \(stillFourPlus.map(\.id))")
    }

    private func printStratumRow(label: String, group: [LineMetrics]) {
        let n = group.count
        guard n > 0 else { return }
        let avgMaxNarrow = Double(group.reduce(0) { $0 + $1.maxVisualLinesNarrow }) / Double(n)
        let totalBreaks = group.reduce(0) { $0 + $1.breakQuality.total }
        let punct = group.reduce(0) { $0 + $1.breakQuality.punctuation }
        let ws = group.reduce(0) { $0 + $1.breakQuality.whitespaceGap }
        let script = group.reduce(0) { $0 + $1.breakQuality.scriptBoundary }
        let midWord = group.reduce(0) { $0 + $1.breakQuality.midWord }
        let orphans = group.reduce(0) { $0 + $1.orphanTranslationPieces }
        let fourPlus = group.filter(\.stillFourPlusNarrow).count
        if totalBreaks > 0 {
            let pct: (Int) -> String = { String(format: "%.0f%%", 100 * Double($0) / Double(totalBreaks)) }
            print("  \(label): n=\(n) avgMaxVisualLines(narrow)=\(fmt(avgMaxNarrow)) breaks[punct=\(pct(punct)) ws=\(pct(ws)) script=\(pct(script)) midWord=\(pct(midWord))] orphanTranslationPieces=\(orphans) stillFourPlus=\(fourPlus)")
        } else {
            print("  \(label): n=\(n) avgMaxVisualLines(narrow)=\(fmt(avgMaxNarrow)) breaks[none, all single-piece] orphanTranslationPieces=\(orphans) stillFourPlus=\(fourPlus)")
        }
    }
}
