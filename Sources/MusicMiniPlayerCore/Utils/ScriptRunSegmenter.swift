/**
 * [INPUT]: Foundation only (pure character-class logic — no NLLanguageRecognizer,
 *          no Translation framework). Reuses LanguageUtils' scalar-range helpers.
 * [OUTPUT]: Exports ScriptRunSegmenter.segment/reassemble — splits a lyric line
 *           into contiguous script runs where the Unicode script UNAMBIGUOUSLY
 *           identifies a language (Hangul, kana(+adjacent kanji), Thai,
 *           Cyrillic, Arabic, Devanagari), leaving Latin/Han-only text as
 *           `.unknown` (source-language-undetermined).
 * [POS]: Utils — feeds LyricsService's mixed-script translation path (2026-09-20
 *        NewJeans "How Sweet" evidence: whole-line auto-detect only translates
 *        the dominant script, leaving the other script's text untouched).
 *
 * Deliberately NOT using NLLanguageRecognizer here: that misclassifies short
 * strings (banned-patterns.md: en→da/sk), and per-run text is often too short
 * for it to work reliably anyway. Script membership is a hard Unicode-range
 * fact, not a statistical guess, for the scripts this segmenter recognizes.
 */

import Foundation

public enum ScriptRunSegmenter {

    /// A determinate run's language is inferred purely from its script; an
    /// `.unknown` run's script (Latin, Han-only, digits, symbols) does not by
    /// itself identify a language and should keep going through
    /// auto-detection (`source: nil`) exactly like today.
    public enum RunLanguage: Equatable {
        case korean
        case japanese
        case thai
        case cyrillic
        case arabic
        case devanagari
        case unknown

        /// BCP-47-ish identifier suitable for `Locale.Language(identifier:)`
        /// when a caller wants to build an explicit-source translation
        /// configuration for this run. `nil` for `.unknown` — callers must
        /// fall back to `source: nil` auto-detection.
        public var localeIdentifier: String? {
            switch self {
            case .korean: return "ko"
            case .japanese: return "ja"
            case .thai: return "th"
            case .cyrillic: return "ru"
            case .arabic: return "ar"
            case .devanagari: return "hi"
            case .unknown: return nil
            }
        }
    }

    public struct Run: Equatable {
        public let text: String
        public let language: RunLanguage

        public init(text: String, language: RunLanguage) {
            self.text = text
            self.language = language
        }
    }

    /// A run must carry at least this many letters to stand on its own —
    /// shorter runs (a single stray Hangul particle mid-English-line, a lone
    /// Latin acronym letter) merge into a neighbor instead of round-tripping
    /// through translation as their own fragment.
    private static let minimumRunLetterCount = 2

    // ------------------------------------------------------------------
    // MARK: - Segmentation
    // ------------------------------------------------------------------

    public static func segment(_ line: String) -> [Run] {
        let characters = Array(line)
        guard !characters.isEmpty else { return [] }

        // Pass 1: classify every character, then group consecutive
        // same-class characters into raw runs (whitespace/punctuation get
        // their own transient `.attach` class).
        var raw: [(cls: CharClass, text: String)] = []
        for character in characters {
            let cls = classify(character)
            if let last = raw.last, last.cls == cls {
                raw[raw.count - 1].text.append(character)
            } else {
                raw.append((cls, String(character)))
            }
        }

        // Pass 2: fold `.attach` runs into a neighboring content run —
        // prefer the previous run; a leading attach run (line starts with
        // punctuation/space) sticks to whatever run follows it.
        var attached: [(cls: CharClass, text: String)] = []
        for run in raw {
            if run.cls == .attach {
                if !attached.isEmpty {
                    attached[attached.count - 1].text += run.text
                } else {
                    attached.append((.attach, run.text))
                }
            } else if !attached.isEmpty, attached[attached.count - 1].cls == .attach {
                let prefix = attached.removeLast().text
                attached.append((run.cls, prefix + run.text))
            } else {
                attached.append((run.cls, run.text))
            }
        }
        attached = mergeConsecutive(attached)

        // Pass 3: kanji adjacent to kana reads as Japanese; kanji elsewhere
        // is script-ambiguous (shared with Chinese) and stays `.unknown`.
        for index in attached.indices where attached[index].cls == .han {
            let prevIsKana = index > 0 && attached[index - 1].cls == .japanese
            let nextIsKana = index + 1 < attached.count && attached[index + 1].cls == .japanese
            if prevIsKana || nextIsKana {
                attached[index].cls = .japanese
            }
        }
        attached = mergeConsecutive(attached)

        // Pass 4: runs too short to trust on their own merge into a
        // neighbor (previous preferred, else next), repeated to a fixpoint.
        var stable = false
        while !stable, attached.count > 1 {
            stable = true
            for index in attached.indices {
                guard letterCount(in: attached[index].text) < minimumRunLetterCount else { continue }
                if index > 0 {
                    attached[index - 1].text += attached[index].text
                } else {
                    attached[index + 1].text = attached[index].text + attached[index + 1].text
                }
                attached.remove(at: index)
                stable = false
                break
            }
        }

        // Pass 5: map to the public language enum and merge any runs that
        // now share the same language (e.g. a former `.han` run folded next
        // to an `.other` run both read as `.unknown`).
        let tagged = attached.map { (cls: language(for: $0.cls), text: $0.text) }
        return mergeConsecutive(tagged).map { Run(text: $0.text, language: $0.cls) }
    }

    // ------------------------------------------------------------------
    // MARK: - Reassembly
    // ------------------------------------------------------------------

    /// Joins already-translated run texts back into one line, in order.
    /// Runs join with a single space by default; two runs whose translated
    /// output is CJK on both sides of the boundary join with no space
    /// (matches how CJK target text is joined elsewhere in this codebase —
    /// no inter-character spacing).
    public static func reassemble(_ translatedRunTexts: [String]) -> String {
        var result = ""
        for text in translatedRunTexts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if result.isEmpty {
                result = trimmed
            } else if joinsWithoutSpace(result, trimmed) {
                result += trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    private static func joinsWithoutSpace(_ left: String, _ right: String) -> Bool {
        guard let lastLeft = left.unicodeScalars.last, let firstRight = right.unicodeScalars.first else {
            return false
        }
        return LanguageUtils.isCJKScalar(lastLeft) && LanguageUtils.isCJKScalar(firstRight)
    }

    // ------------------------------------------------------------------
    // MARK: - Character classification
    // ------------------------------------------------------------------

    private enum CharClass: Equatable {
        case korean, japanese, han, thai, cyrillic, arabic, devanagari, other, attach
    }

    private static let thaiRange: ClosedRange<UInt32> = 0x0E00...0x0E7F
    private static let cyrillicRanges: [ClosedRange<UInt32>] = [0x0400...0x04FF, 0x0500...0x052F]
    private static let arabicRanges: [ClosedRange<UInt32>] = [0x0600...0x06FF, 0x0750...0x077F]
    private static let devanagariRange: ClosedRange<UInt32> = 0x0900...0x097F

    private static func classify(_ character: Character) -> CharClass {
        if character.isWhitespace { return .attach }
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            // Multi-scalar graphemes (emoji, combining marks) are treated
            // like punctuation — they attach rather than forming their own run.
            return .attach
        }
        if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
            return .attach
        }
        if LanguageUtils.isKoreanScalar(scalar) { return .korean }
        if LanguageUtils.isJapaneseKana(scalar) { return .japanese }
        if LanguageUtils.isChineseScalar(scalar) { return .han }
        if thaiRange.contains(scalar.value) { return .thai }
        if cyrillicRanges.contains(where: { $0.contains(scalar.value) }) { return .cyrillic }
        if arabicRanges.contains(where: { $0.contains(scalar.value) }) { return .arabic }
        if devanagariRange.contains(scalar.value) { return .devanagari }
        return .other
    }

    private static func language(for cls: CharClass) -> RunLanguage {
        switch cls {
        case .korean: return .korean
        case .japanese: return .japanese
        case .thai: return .thai
        case .cyrillic: return .cyrillic
        case .arabic: return .arabic
        case .devanagari: return .devanagari
        case .han, .other, .attach: return .unknown
        }
    }

    private static func letterCount(in text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }

    private static func mergeConsecutive<T: Equatable>(_ runs: [(cls: T, text: String)]) -> [(cls: T, text: String)] {
        var result: [(cls: T, text: String)] = []
        for run in runs {
            if let last = result.last, last.cls == run.cls {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
