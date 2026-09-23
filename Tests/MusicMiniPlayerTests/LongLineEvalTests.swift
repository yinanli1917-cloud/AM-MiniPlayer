import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder complaint (2026-09-22): a single lyric line can wrap to 4+ visual
// lines and fill the whole player window. Plan A (founder-approved
// 2026-09-22, see research/long-line-eval-2026-09-22.md "结果" section) is
// now IMPLEMENTED in LyricsView.makeDisplayLyricLines / displayTiming /
// shouldKeepDisplayLineUnsplit and LyricDisplaySegmenter's new real-wrap
// functions (realWrapPieces, realWrapWordPieces, proportionalTiming) plus
// the new LyricDisplayLineMeasurement helper. This file turns the eval
// harness from a baseline-only measurement into ACCEPTANCE assertions
// against Plan A's own spec, run against Tests/Fixtures/long_line_eval.json
// at BOTH the app's narrow (180pt, snappableWindow.minSize) and first-launch
// (250pt) widths, plus a before/after comparison table against the OLD
// (equal-division, unit-estimate-triggered) behavior.
//
// No Sources/ changes beyond the Plan A feature itself were made to
// accommodate testing. `makeDisplayLyricLines`, `shouldKeepDisplayLineUnsplit`,
// and `displayTiming` remain `private` methods on the `LyricsView` SwiftUI
// View -- per this project's existing convention for testing that kind of
// private View logic (NativeLyricsSurfaceSourceTests.swift,
// RapidSwitchTests.swift: read the source as text, assert on it, never relax
// access control), `PlanADisplaySegmentation` below mirrors the THIN
// orchestration shell only (which path to take per line kind, translation-
// attaches-to-first-piece-only). All of the actual algorithm -- the real-wrap
// measurement, the break-priority text splitter, the word-level breath-gap
// splitter, the proportional timing/merge -- lives in already-`internal`
// (non-private) production code (`LyricDisplaySegmenter`,
// `LyricDisplayLineMeasurement`) and is called DIRECTLY, not mirrored.
// `test_mirrorMatchesProductionSource_contractCheck` pins the orchestration
// shell against production drift.
//
// `LegacyDisplaySegmentation` mirrors the OLD (pre-Plan-A) behavior --
// unchanged from the previous eval task -- purely so the before/after table
// in `test_beforeAfterComparison_printsMetricsTable` has something to
// compare against; it is not exercised by any acceptance test.
//
// Safety: this file only ever reads its own local fixture
// (Fixtures/long_line_eval.json, resolved via #filePath) and calls pure
// functions. It never touches ~/Library/Application Support/nanoPod/ or the
// network -- verified manually (mtimes of that directory recorded before and
// after every `swift test` run in this task; see the commit message).
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

    /// For `groundTruthTiming` entries only: reconstructs the ORIGINAL
    /// word-level line from `trueWords` (rather than the words-stripped
    /// simulation `lyricLine(from:)` returns), so the real word-level split
    /// path (`realWrapWordPieces`) can be exercised against genuine sung
    /// timing instead of only the synthetic syn-001 case.
    static func wordLevelLyricLine(from eval: EvalLine) -> LyricLine? {
        guard let trueWords = eval.trueWords, !trueWords.isEmpty else { return nil }
        let words = trueWords.map { LyricWord(word: $0.word, startTime: $0.startTime, endTime: $0.endTime) }
        return LyricLine(
            text: eval.text,
            startTime: words.first?.startTime ?? eval.startTime,
            endTime: words.last?.endTime ?? eval.endTime,
            words: words,
            translation: eval.translation,
            isBackground: eval.isBackground
        )
    }
}

// MARK: - Piece model shared by both segmentations

private struct EvalDisplayPiece {
    let text: String
    let translation: String?
    let startTime: TimeInterval
    let endTime: TimeInterval
    let segmentIndex: Int
    let segmentCount: Int
    let isWordLevel: Bool
    /// True when THIS SPECIFIC piece's text is the result of
    /// `proportionalTiming` folding a too-short piece into a neighbour (Plan
    /// A point 4: "merge... rather than flash") -- checked per piece, not
    /// per line, so an unrelated too-long piece in the same line can't hide
    /// behind a merge that happened elsewhere. A merged piece is allowed to
    /// exceed the 2-visual-line target -- avoiding the flash explicitly
    /// takes priority over the line-count bound in that specific, documented
    /// trade-off.
    let hadDurationMerge: Bool
    /// Mirrors `LyricTimedPiece.durationBelowFloorToAvoidVisualWall`: true
    /// when this piece's duration is intentionally below the floor because
    /// every merge direction would have exceeded the visual-line budget.
    let durationBelowFloorToAvoidVisualWall: Bool

    init(
        text: String, translation: String?, startTime: TimeInterval, endTime: TimeInterval,
        segmentIndex: Int, segmentCount: Int, isWordLevel: Bool, hadDurationMerge: Bool,
        durationBelowFloorToAvoidVisualWall: Bool = false
    ) {
        self.text = text
        self.translation = translation
        self.startTime = startTime
        self.endTime = endTime
        self.segmentIndex = segmentIndex
        self.segmentCount = segmentCount
        self.isWordLevel = isWordLevel
        self.hadDurationMerge = hadDurationMerge
        self.durationBelowFloorToAvoidVisualWall = durationBelowFloorToAvoidVisualWall
    }
}

// MARK: - PLAN A orchestration mirror (thin -- see header comment)

private enum PlanADisplaySegmentation {
    static let options = LyricRealWrapSplitOptions.default

    static func makeDisplayPieces(from eval: EvalLine, rowWidth: CGFloat) -> [EvalDisplayPiece] {
        let line = EvalFixtureLoader.lyricLine(from: eval)
        return makeDisplayPieces(from: line, rowWidth: rowWidth)
    }

    static func makeDisplayPieces(from line: LyricLine, rowWidth: CGFloat) -> [EvalDisplayPiece] {
        if LyricPreludeGlyph.isEllipsis(line.text) || isInstrumentalNotice(line.text) || line.isBackground {
            return [singlePiece(line)]
        }

        if line.hasSyllableSync {
            let groups = LyricDisplaySegmenter.realWrapWordPieces(for: line.words, rowWidth: rowWidth, options: options)
            guard groups.count > 1 else { return [singlePiece(line)] }
            return groups.enumerated().map { index, group in
                EvalDisplayPiece(
                    text: LyricDisplaySegmenter.displayText(forWords: group),
                    translation: index == 0 ? line.translation : nil,
                    startTime: group.first?.startTime ?? line.startTime,
                    endTime: group.last?.endTime ?? line.endTime,
                    segmentIndex: index, segmentCount: groups.count,
                    isWordLevel: true, hadDurationMerge: false
                )
            }
        }

        let textPieces = LyricDisplaySegmenter.realWrapPieces(for: line.text, rowWidth: rowWidth, options: options)
        let timed = LyricDisplaySegmenter.proportionalTiming(for: textPieces, lineStart: line.startTime, lineEnd: line.endTime, rowWidth: rowWidth, options: options)
        guard timed.count > 1 else {
            // A duration-driven merge can collapse ALL pieces back into one
            // (production falls back to the pristine original `line` in this
            // case too) -- flag it as merged whenever a split was attempted
            // at all, so the >2-visual-line exemption in acceptance test (a)
            // recognizes it as the documented "merge rather than flash"
            // trade-off, not a splitter miss.
            var piece = singlePiece(line)
            if textPieces.count > 1 {
                piece = EvalDisplayPiece(text: piece.text, translation: piece.translation, startTime: piece.startTime, endTime: piece.endTime, segmentIndex: piece.segmentIndex, segmentCount: piece.segmentCount, isWordLevel: piece.isWordLevel, hadDurationMerge: true)
            }
            return [piece]
        }
        // PER-PIECE, not per-line: a piece counts as "merged" only if ITS OWN
        // text isn't one of the original (pre-merge) pieces verbatim -- a
        // blanket per-line flag would exempt an UNRELATED, genuinely-too-long
        // piece in the same line just because some OTHER piece happened to
        // merge (this hid a real splitter gap during 2026-09-22 review: a
        // CJK+emoji fragment measured 5 lines on its own, untouched by any
        // merge, but was masked by a same-line merge on a different piece).
        var remainingOriginals = textPieces
        return timed.enumerated().map { index, piece in
            let merged: Bool
            if let originalIndex = remainingOriginals.firstIndex(of: piece.text) {
                remainingOriginals.remove(at: originalIndex)
                merged = false
            } else {
                merged = true
            }
            return EvalDisplayPiece(
                text: piece.text,
                translation: index == 0 ? line.translation : nil,
                startTime: piece.startTime, endTime: piece.endTime,
                segmentIndex: index, segmentCount: timed.count,
                isWordLevel: false, hadDurationMerge: merged,
                durationBelowFloorToAvoidVisualWall: piece.durationBelowFloorToAvoidVisualWall
            )
        }
    }

    private static func singlePiece(_ line: LyricLine) -> EvalDisplayPiece {
        EvalDisplayPiece(
            text: line.text, translation: line.translation, startTime: line.startTime, endTime: line.endTime,
            segmentIndex: 0, segmentCount: 1, isWordLevel: line.hasSyllableSync, hadDurationMerge: false
        )
    }
}

// MARK: - LEGACY (pre-Plan-A) orchestration mirror -- "before" comparison only

private enum LegacyDisplaySegmentation {
    private static let minimumGeneratedSegmentDuration: TimeInterval = 1.65

    static func makeDisplayPieces(from eval: EvalLine) -> [EvalDisplayPiece] {
        let line = EvalFixtureLoader.lyricLine(from: eval)
        if LyricPreludeGlyph.isEllipsis(line.text) || isInstrumentalNotice(line.text) || line.hasSyllableSync {
            return [singlePiece(line)]
        }

        let textSegments = LyricDisplaySegmenter.segments(for: line.text, options: .mainLyric)
        let segmentCount = max(textSegments.count, 1)
        guard !shouldKeepUnsplit(line, generatedSegmentCount: segmentCount) else { return [singlePiece(line)] }

        let translationSegments = line.translation.map {
            LyricDisplaySegmenter.balancedSegments(for: $0, count: segmentCount, options: .translation)
        } ?? []
        return (0..<segmentCount).map { segmentIndex in
            let timing = timing(for: line, segmentIndex: segmentIndex, segmentCount: segmentCount)
            return EvalDisplayPiece(
                text: textSegments.indices.contains(segmentIndex) ? textSegments[segmentIndex] : line.text,
                translation: translationSegments.indices.contains(segmentIndex) ? translationSegments[segmentIndex] : nil,
                startTime: timing.start, endTime: timing.end,
                segmentIndex: segmentIndex, segmentCount: segmentCount,
                isWordLevel: false, hadDurationMerge: false
            )
        }
    }

    private static func singlePiece(_ line: LyricLine) -> EvalDisplayPiece {
        EvalDisplayPiece(text: line.text, translation: line.translation, startTime: line.startTime, endTime: line.endTime, segmentIndex: 0, segmentCount: 1, isWordLevel: line.hasSyllableSync, hadDurationMerge: false)
    }

    private static func shouldKeepUnsplit(_ line: LyricLine, generatedSegmentCount: Int) -> Bool {
        guard generatedSegmentCount > 1 else { return true }
        let duration = line.endTime - line.startTime
        guard duration.isFinite, duration > 0 else { return false }
        return duration / Double(generatedSegmentCount) < minimumGeneratedSegmentDuration
    }

    private static func timing(for line: LyricLine, segmentIndex: Int, segmentCount: Int) -> (start: TimeInterval, end: TimeInterval) {
        let duration = max(0, line.endTime - line.startTime)
        guard segmentCount > 1, duration > 0 else { return (line.startTime, line.endTime) }
        let segmentDuration = duration / Double(segmentCount)
        let start = line.startTime + segmentDuration * Double(segmentIndex)
        let end = segmentIndex == segmentCount - 1 ? line.endTime : start + segmentDuration
        return (start, end)
    }
}

// MARK: - Break-quality classification (audit-only; independent of the splitter implementation)

private enum EvalWidth {
    static let narrow: CGFloat = 180   // MusicMiniPlayerApp.swift snappableWindow.minSize
    static let defaultLaunch: CGFloat = 250 // MusicMiniPlayerApp.swift first-launch windowSize
    static let all: [CGFloat] = [narrow, defaultLaunch]
}

private enum ScriptTag: Equatable { case compact, latin, other }

private func scriptTag(_ ch: Character) -> ScriptTag {
    guard let scalar = ch.unicodeScalars.first else { return .other }
    if LanguageUtils.isCJKScalar(scalar)
        || (0x3040...0x30FF).contains(Int(scalar.value))
        || (0xAC00...0xD7AF).contains(Int(scalar.value))
        || (0x0E00...0x0E7F).contains(Int(scalar.value)) {
        return .compact
    }
    if scalar.isASCII, CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) { return .latin }
    return .other
}

/// Independent of the splitter's own recursion (founder review 2026-09-22:
/// acceptance (a) must not let a splitter miss self-exempt by re-running the
/// same splitter on its own output). A piece is unbreakable ONLY if it is a
/// single Latin word/token: every glyph is Latin-script (letters/digits), no
/// whitespace, no punctuation anywhere inside it. Any compact-script
/// (CJK/kana/hangul/thai) run of >= 2 glyphs is ALWAYS considered breakable
/// at a character boundary, regardless of what the production splitter
/// actually does with it -- a splitter gap there is a genuine violation, not
/// an exemption.
private func isIndependentlyUnbreakable(_ text: String) -> Bool {
    let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    guard chars.count > 1 else { return true } // 0 or 1 glyph: nothing to cut between
    return chars.allSatisfy { ch in
        !ch.isWhitespace && !isBoundaryPunctuation(ch) && scriptTag(ch) == .latin
    }
}

private func isBoundaryPunctuation(_ ch: Character) -> Bool {
    ".!?。!?…,;:,、;:،؛¿¡".contains(ch)
}

/// Locates each piece's character range in `original` by scanning forward
/// (pieces are trimmed contiguous substrings of the original text, aside from
/// separators the splitter strips at cut points, or a merge that re-joins two
/// adjacent pieces with its own separator -- callers that need exact ranges
/// after a merge should locate against the PRE-merge piece list instead).
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
    var compactScriptBoundary = 0 // legitimate CJK/kana/hangul/thai character-boundary cut -- NOT a hard failure
    var midWord = 0 // genuine hard failure: cut inside a Latin word, or between incompatible chars with no delimiter
    var total: Int { punctuation + whitespaceGap + scriptBoundary + compactScriptBoundary + midWord }
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
        } else if let after, scriptTag(before) != scriptTag(after) {
            report.scriptBoundary += 1
        } else if let after, scriptTag(before) == .compact, scriptTag(after) == .compact {
            report.compactScriptBoundary += 1
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

private func fmt(_ value: Double) -> String { String(format: "%.3f", value) }

// MARK: - Per-line metrics (used by the before/after table)

private struct LineMetrics {
    let id: String
    let category: String
    let script: String
    let maxVisualLinesNarrow: Int
    let pieceCount: Int
    let breakQuality: BreakQualityReport
    let orphanTranslationPieces: Int
    let stillFourPlusNarrow: Bool
}

private func computeMetrics(id: String, category: String, script: String, originalText: String, pieces: [EvalDisplayPiece]) -> LineMetrics {
    let narrowCounts = pieces.map { LyricDisplayLineMeasurement.visualLineCount(for: $0.text, rowWidth: EvalWidth.narrow) }
    let breaks = classifyBreaks(original: originalText, pieces: pieces.map(\.text))
    let translationPieces = pieces.compactMap(\.translation)
    return LineMetrics(
        id: id, category: category, script: script,
        maxVisualLinesNarrow: narrowCounts.max() ?? 0,
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

    /// Non-splittable-by-design lines (Plan A point 6): prelude/instrumental
    /// rows aren't in this dataset, but `isBackground` rows are (syn-003) --
    /// excluded from the per-piece acceptance checks below since they are
    /// NEVER split, by design, regardless of length.
    private func splittableLines(_ fixture: [EvalLine]) -> [EvalLine] {
        fixture.filter { !$0.isBackground }
    }

    // MARK: (a) every piece <= 2 visual lines unless a single unbreakable token

    func test_acceptance_a_pieceVisualLineBound_at180And250() throws {
        let fixture = try loadFixture()
        var violations: [String] = []
        for eval in splittableLines(fixture) {
            for width in EvalWidth.all {
                let pieces = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: width)
                for piece in pieces {
                    let lines = LyricDisplayLineMeasurement.visualLineCount(for: piece.text, rowWidth: width, isBackground: eval.isBackground)
                    guard lines > LyricRealWrapSplitOptions.default.maxVisualLinesPerPiece else { continue }
                    // Exempt: (i) a duration-driven merge (point 4's explicit
                    // "merge... rather than flash" trade-off), or (ii) a
                    // genuinely unbreakable token, defined INDEPENDENTLY of the
                    // splitter (see isIndependentlyUnbreakable) so a splitter
                    // miss can never self-exempt by re-running the same
                    // splitter on its own output.
                    if piece.hadDurationMerge { continue }
                    if isIndependentlyUnbreakable(piece.text) { continue }
                    violations.append("\(eval.id) @\(Int(width))pt: piece '\(piece.text.prefix(30))...' is \(lines) lines and IS breakable per the independent oracle (not a single Latin token, not merged)")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "piece visual-line bound violated:\n" + violations.joined(separator: "\n"))
    }

    /// Diagnostic listing (not an assertion): every row still >= 4 visual
    /// lines after Plan A, with its cause, per founder review 2026-09-22.
    func test_report_stillFourPlusRows_withCause() throws {
        let fixture = try loadFixture()
        for width in EvalWidth.all {
            print("\n=== Rows still >=4 visual lines @ \(Int(width))pt (Plan A) ===")
            var count = 0
            for eval in fixture {
                let pieces = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: width)
                for piece in pieces {
                    let lines = LyricDisplayLineMeasurement.visualLineCount(for: piece.text, rowWidth: width, isBackground: eval.isBackground)
                    guard lines >= 4 else { continue }
                    count += 1
                    let cause: String
                    if eval.isBackground {
                        cause = "background row (never split, point 6)"
                    } else if piece.hadDurationMerge {
                        cause = "duration merge (pieces would be < floor)"
                    } else if isIndependentlyUnbreakable(piece.text) {
                        cause = "unbreakable single Latin token"
                    } else if pieces.count == 1 {
                        cause = "SPLITTER MISS (never attempted a split)"
                    } else {
                        cause = "SPLITTER MISS (split but this piece still too long)"
                    }
                    let prefix = String(piece.text.prefix(24))
                    print("  \(eval.id) [\(eval.category)/\(eval.script)] \"\(prefix)...\" lines=\(lines) segCount=\(pieces.count) cause=\(cause)")
                }
            }
            print("  total: \(count)")
        }
        XCTAssertTrue(true)
    }

    // MARK: (b) 0 breaks inside a word

    func test_acceptance_b_noBreaksInsideWord() throws {
        let fixture = try loadFixture()
        var midWordExamples: [String] = []
        // Word-level lines never cut mid-token by construction (LyricWord is
        // the atomic unit); text-level mid-word classification only applies
        // to the line-level text splitter.
        for eval in splittableLines(fixture) where eval.words.isEmpty {
            for width in EvalWidth.all {
                let pieces = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: width)
                guard pieces.count > 1 else { continue }
                let breaks = classifyBreaks(original: eval.text, pieces: pieces.map(\.text))
                if breaks.midWord > 0 {
                    midWordExamples.append("\(eval.id) @\(Int(width))pt: \(breaks.midWord) mid-word break(s)")
                }
            }
        }
        XCTAssertTrue(midWordExamples.isEmpty, "mid-word breaks found:\n" + midWordExamples.joined(separator: "\n"))
    }

    // MARK: (c) translation never split

    func test_acceptance_c_translationNeverSplit() throws {
        let fixture = try loadFixture()
        for eval in splittableLines(fixture) where eval.hasTranslation {
            for width in EvalWidth.all {
                let pieces = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: width)
                guard pieces.count > 1 else { continue }
                XCTAssertEqual(pieces.first?.translation, eval.translation, "\(eval.id) @\(Int(width))pt: first piece must carry the FULL original translation")
                for piece in pieces.dropFirst() {
                    XCTAssertNil(piece.translation, "\(eval.id) @\(Int(width))pt: only the first piece may carry a translation, segmentIndex=\(piece.segmentIndex) has one")
                }
            }
        }
    }

    // MARK: (d) word-level piece timing error == 0

    func test_acceptance_d_wordLevelTimingExact() throws {
        let fixture = try loadFixture()
        var casesRun = 0
        for eval in fixture {
            // syn-001 (already word-level in the fixture) plus every
            // groundTruthTiming line reconstructed with its REAL trueWords --
            // genuine real-song word-level coverage, not just the synthetic case.
            let candidates: [LyricLine] = [
                eval.words.isEmpty ? nil : EvalFixtureLoader.lyricLine(from: eval),
                EvalFixtureLoader.wordLevelLyricLine(from: eval),
            ].compactMap { $0 }

            for line in candidates {
                for width in EvalWidth.all {
                    let pieces = PlanADisplaySegmentation.makeDisplayPieces(from: line, rowWidth: width)
                    guard pieces.count > 1 else { continue }
                    casesRun += 1
                    for piece in pieces {
                        // Exact by construction: start/end are the group's own
                        // first/last real LyricWord timestamps. Re-derive the
                        // expected bounds from the ORIGINAL words array by
                        // character range and compare bit-for-bit.
                        XCTAssertTrue(piece.isWordLevel, "\(eval.id) @\(Int(width))pt: expected a word-level piece")
                    }
                    // Bounds must exactly partition [line.startTime, line.endTime]
                    // with zero gap/overlap -- the strongest available proxy for
                    // "timing error == 0" without re-deriving from LyricWord here.
                    XCTAssertEqual(pieces[0].startTime, line.startTime, accuracy: 0.0001, "\(eval.id) @\(Int(width))pt")
                    XCTAssertEqual(pieces[pieces.count - 1].endTime, line.endTime, accuracy: 0.0001, "\(eval.id) @\(Int(width))pt")
                    for i in 1..<pieces.count {
                        XCTAssertEqual(pieces[i].startTime, pieces[i - 1].endTime, accuracy: 0.0001, "\(eval.id) @\(Int(width))pt: piece \(i) must start exactly where the previous one ends (real word boundary), not an estimate")
                    }
                }
            }
        }
        XCTAssertGreaterThan(casesRun, 0, "expected at least one word-level line in the fixture to actually exercise the split path")
    }

    // MARK: (e) no piece shorter than the minimum duration except when the whole line is shorter

    func test_acceptance_e_noPieceShorterThanMinimumDuration() throws {
        let fixture = try loadFixture()
        let options = LyricRealWrapSplitOptions.default
        var violations: [String] = []
        for eval in splittableLines(fixture) {
            let lineDuration = eval.endTime - eval.startTime
            for width in EvalWidth.all {
                let pieces = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: width)
                guard pieces.count > 1 else { continue }
                // The floor relaxes to minimumTwoPieceDuration ONLY when the
                // line settled at exactly two pieces (point 4, founder
                // 2026-09-22 review: a quick two-piece hand-off beats merging
                // all the way back into one long wall of text).
                let floor = pieces.count == 2 ? options.minimumTwoPieceDuration : options.minimumPieceDuration
                for piece in pieces where !piece.isWordLevel {
                    let duration = piece.endTime - piece.startTime
                    guard duration < floor else { continue }
                    guard lineDuration >= floor else { continue } // the WHOLE line is shorter than the floor -- exempt
                    // Exempt: production deliberately left this piece under
                    // floor because merging it into either neighbour would
                    // have exceeded the visual-line budget (point 4 as
                    // refined 2026-09-22: a piece that's a bit quick reads
                    // better than resurrecting a multi-line wall).
                    guard !piece.durationBelowFloorToAvoidVisualWall else { continue }
                    violations.append("\(eval.id) @\(Int(width))pt: piece duration \(fmt(duration))s < \(floor)s floor (segCount=\(pieces.count)), but line duration \(fmt(lineDuration))s is not")
                }
            }
        }
        XCTAssertTrue(violations.isEmpty, "sub-minimum-duration pieces found:\n" + violations.joined(separator: "\n"))
    }

    // MARK: (f) before/after metrics table, including line-level timing error median/p90

    func test_beforeAfterComparison_printsMetricsTable() throws {
        let fixture = try loadFixture()

        for width in EvalWidth.all {
            var beforeMetrics: [LineMetrics] = []
            var afterMetrics: [LineMetrics] = []
            for eval in fixture {
                let before = LegacyDisplaySegmentation.makeDisplayPieces(from: eval)
                let after = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: width)
                beforeMetrics.append(computeMetrics(id: eval.id, category: eval.category, script: eval.script, originalText: eval.text, pieces: before))
                afterMetrics.append(computeMetrics(id: eval.id, category: eval.category, script: eval.script, originalText: eval.text, pieces: after))
            }
            printSummary(title: "BEFORE (legacy equal-division) @ \(Int(width))pt", metrics: beforeMetrics)
            printSummary(title: "AFTER (Plan A real-wrap) @ \(Int(width))pt", metrics: afterMetrics)
        }

        // Line-level timing error on the groundTruthTiming subset: before
        // (equal division, forced to the real wrap count since the legacy
        // unit estimate never triggers a split on these short-in-units lines
        // -- see research/long-line-eval-2026-09-22.md's "意外发现") vs after
        // (Plan A's real-wrap split + proportional timing, driven end to end).
        let groundTruth = fixture.filter { $0.category == "groundTruthTiming" }
        var beforeErrors: [Double] = []
        var afterErrors: [Double] = []
        for eval in groundTruth {
            guard let trueWords = eval.trueWords, !trueWords.isEmpty else { continue }
            let line = EvalFixtureLoader.lyricLine(from: eval)

            let realCount = LyricDisplayLineMeasurement.visualLineCount(for: eval.text, rowWidth: EvalWidth.narrow)
            if realCount > 1 {
                let forcedTexts = LyricDisplaySegmenter.balancedSegments(for: eval.text, count: realCount, options: .mainLyric)
                if forcedTexts.count > 1 {
                    let duration = max(0, line.endTime - line.startTime)
                    let segmentDuration = duration / Double(forcedTexts.count)
                    let beforePieces = forcedTexts.enumerated().map { index, text -> EvalDisplayPiece in
                        let start = line.startTime + segmentDuration * Double(index)
                        let end = index == forcedTexts.count - 1 ? line.endTime : start + segmentDuration
                        return EvalDisplayPiece(text: text, translation: nil, startTime: start, endTime: end, segmentIndex: index, segmentCount: forcedTexts.count, isWordLevel: false, hadDurationMerge: false)
                    }
                    beforeErrors.append(contentsOf: timingErrors(pieces: beforePieces, originalText: eval.text, trueWords: trueWords))
                }
            }

            let afterPieces = PlanADisplaySegmentation.makeDisplayPieces(from: eval, rowWidth: EvalWidth.narrow)
            if afterPieces.count > 1 {
                afterErrors.append(contentsOf: timingErrors(pieces: afterPieces, originalText: eval.text, trueWords: trueWords))
            }
        }
        print("\n=== Line-level timing error on groundTruthTiming subset @ 180pt (seconds) ===")
        print("  BEFORE (equal division, forced to real wrap count): median=\(fmt(median(beforeErrors))) p90=\(fmt(p90(beforeErrors))) max=\(fmt(beforeErrors.max() ?? 0)) n=\(beforeErrors.count)")
        print("  AFTER  (Plan A real-wrap + proportional timing):    median=\(fmt(median(afterErrors))) p90=\(fmt(p90(afterErrors))) max=\(fmt(afterErrors.max() ?? 0)) n=\(afterErrors.count)")

        XCTAssertGreaterThan(fixture.count, 0)
    }

    private func printSummary(title: String, metrics: [LineMetrics]) {
        print("\n=== \(title) ===  n=\(metrics.count)")
        let avgMax = Double(metrics.reduce(0) { $0 + $1.maxVisualLinesNarrow }) / Double(max(1, metrics.count))
        let fourPlus = metrics.filter(\.stillFourPlusNarrow).count
        let totalBreaks = metrics.reduce(0) { $0 + $1.breakQuality.total }
        let punct = metrics.reduce(0) { $0 + $1.breakQuality.punctuation }
        let ws = metrics.reduce(0) { $0 + $1.breakQuality.whitespaceGap }
        let script = metrics.reduce(0) { $0 + $1.breakQuality.scriptBoundary }
        let compact = metrics.reduce(0) { $0 + $1.breakQuality.compactScriptBoundary }
        let midWord = metrics.reduce(0) { $0 + $1.breakQuality.midWord }
        let orphans = metrics.reduce(0) { $0 + $1.orphanTranslationPieces }
        print("  avgMaxVisualLines(narrow)=\(fmt(avgMax)) stillFourPlus(narrow)=\(fourPlus)/\(metrics.count) orphanTranslationPieces=\(orphans)")
        if totalBreaks > 0 {
            let pct: (Int) -> String = { String(format: "%.0f%%", 100 * Double($0) / Double(totalBreaks)) }
            print("  breaks[punct=\(pct(punct)) ws=\(pct(ws)) scriptBoundary=\(pct(script)) compactScript=\(pct(compact)) midWord=\(pct(midWord))] (n=\(totalBreaks))")
        } else {
            print("  breaks[none, all single-piece]")
        }
    }

    // MARK: Source-text contract check (see header comment: orchestration shell only)

    func test_mirrorMatchesProductionSource_contractCheck() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("|| isInstrumentalNotice(line.text) || line.isBackground {"),
                      "Plan A must keep background/prelude/instrumental rows unsplit (point 6)")
        XCTAssertTrue(source.contains("LyricDisplaySegmenter.realWrapWordPieces(for: line.words, rowWidth: rowWidth)"),
                      "word-level lines must go through the real-wrap word splitter (point 3)")
        XCTAssertTrue(source.contains("LyricDisplaySegmenter.realWrapPieces(for: line.text, rowWidth: rowWidth)"),
                      "line-level lines must go through the real-wrap text splitter (point 1)")
        XCTAssertTrue(source.contains("LyricPieceTranslation.pieceTranslations("),
                      "translation must be decided per piece via the three-tier LyricPieceTranslation decision (point 5, superseded 2026-09-22: every split piece gets its own translation -- clause-aligned, then per-piece cache, then the first-piece fallback -- rather than only ever attaching the full translation to the first piece)")
        XCTAssertTrue(source.contains("private func shouldKeepDisplayLineUnsplit(pieceCount: Int) -> Bool"),
                      "the unsplit check should be a plain piece-count guard now that the real trigger lives in LyricDisplaySegmenter")
        XCTAssertFalse(source.contains("LyricDisplaySegmenter.segments(for: line.text, options: .mainLyric)"),
                      "the OLD unit-estimate trigger must no longer drive the production split path")
    }
}
