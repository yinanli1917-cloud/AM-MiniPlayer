/**
 * [INPUT]: Foundation + NaturalLanguage (NLLanguageRecognizer, offline/on-device,
 *          no popups) + Utils' ScriptRunSegmenter/LanguageUtils (pure script-range
 *          classification). No Translation-framework calls here.
 * [OUTPUT]: Exports LyricsTranslationSourceDetection.songLevelSource (song-wide
 *           explicit source-language determination) and .lineIsConsistent
 *           (per-line gate for whether a line should ride the song's session).
 * [POS]: Services — feeds LyricsService.silentSystemTranslationConfiguration
 *        and performSystemTranslation (2026-09-22 fix for the macOS system
 *        language-picker popup: those call sites used to compute a source
 *        language and then discard it, passing `source: nil` to
 *        TranslationSession.Configuration — the framework then re-detects
 *        PER BATCH, and any batch it can't confidently identify (short lines,
 *        mixed script, romanized Japanese, vocables) surfaces the picker).
 *
 * Deliberately NOT per-line NLLanguageRecognizer (banned-patterns: short
 * strings misclassify, e.g. English -> Danish/Slovak). This module runs
 * NLLanguageRecognizer exactly ONCE, over the WHOLE song's eligible lyric
 * text, and only as a last resort after script-determined signals (which are
 * hard Unicode-range facts, not statistical guesses) have had a chance to
 * decide the language outright.
 */

import Foundation
import NaturalLanguage

public enum LyricsTranslationSourceDetection {

    // ------------------------------------------------------------------
    // MARK: - Tunables (named so a future recalibration has one place to look)
    // ------------------------------------------------------------------

    /// A script-determined run (kana/hangul/thai/arabic/cyrillic/devanagari)
    /// must cover at least this share of the song's total letters to decide
    /// the whole song's source by script alone — guards against one stray
    /// foreign word (e.g. a single Hangul aside in an English song) deciding
    /// the entire song's language.
    public static let minimumScriptDominance: Double = 0.6

    /// Matches the existing `lyricsArePredominantlyChinese` threshold (kept
    /// identical on purpose — this module supersedes that heuristic's ROLE
    /// for translation-source purposes but must not silently move the bar).
    public static let minimumHanDominance: Double = 0.4

    /// NLLanguageRecognizer confidence floor for the whole-song fallback
    /// pass. Below this, the song's language is treated as undetermined —
    /// translation is skipped SILENTLY (never falls back to `source: nil`
    /// auto-detect, which is what re-introduces the picker).
    public static let minimumConfidence: Double = 0.35

    /// The top hypothesis must lead the runner-up by at least this margin;
    /// a close call (e.g. "English 0.40 vs Danish 0.38") is exactly the
    /// ambiguous case that misclassified short strings in the past
    /// (banned-patterns: en -> da/sk) — treated as undetermined, not guessed.
    public static let minimumConfidenceMargin: Double = 0.15

    /// Best-effort static fallback for "languages Apple's Translation
    /// framework supports", used to constrain NLLanguageRecognizer's
    /// hypotheses when the live `LanguageAvailability().supportedLanguages`
    /// hasn't been queried (keeps this detector synchronously callable and
    /// unit-testable without an async round trip). Call sites that already
    /// have the live list (memoized once per process, see
    /// `SupportedTranslationLanguagesMemo`) should pass it instead.
    // NOTE: "pt" (bare, not just "pt-BR"/"pt-PT") is required here, not
    // optional -- NLLanguageRecognizer's `languageConstraints` buckets by the
    // PRIMARY language subtag. Constraining to only the regional variants
    // silently excluded Portuguese from the candidate hypothesis set
    // entirely, and short/generic romantic-themed Portuguese text then lost
    // to Spanish every time (real repro during this module's own eval,
    // see LyricsTranslationSourceDetectionTests / the research writeup).
    public static let fallbackSupportedLanguageCodes: Set<String> = [
        "ar", "zh-Hans", "zh-Hant", "da", "nl", "en", "fi", "fr", "de",
        "hi", "hu", "id", "it", "ja", "ko", "nb", "pl", "pt", "pt-BR", "pt-PT",
        "ro", "ru", "es", "sv", "th", "tr", "uk", "vi",
    ]

    // ------------------------------------------------------------------
    // MARK: - Song-level source determination
    // ------------------------------------------------------------------

    /// Determines a single explicit source language for the WHOLE song, or
    /// `nil` when undetermined (caller must skip translation rather than
    /// fall back to auto-detect). Order of evidence:
    /// 1. Kana anywhere -> Japanese (kana is Japanese-exclusive among CJK).
    /// 2. Han-dominant text (no kana) -> zh-Hans/zh-Hant via existing
    ///    Simplified/Traditional character-set evidence.
    /// 3. Any other script that unambiguously identifies a language
    ///    (Hangul/Thai/Arabic/Cyrillic/Devanagari) and dominates the song's
    ///    letters -> that language.
    /// 4. Otherwise (Latin-dominant or genuinely mixed/ambiguous): a single
    ///    NLLanguageRecognizer pass over the whole song, constrained to
    ///    `supportedLanguageCodes`, gated by confidence + margin.
    public static func songLevelSource(
        eligibleLineTexts: [String],
        supportedLanguageCodes: Set<String> = fallbackSupportedLanguageCodes
    ) -> Locale.Language? {
        diagnostics(eligibleLineTexts: eligibleLineTexts, supportedLanguageCodes: supportedLanguageCodes).language
    }

    /// How `songLevelSource` decided (or failed to decide) a song's source.
    public enum DetectionMethod: String, Equatable {
        case kana, hanDominance, script, recognizer, undetermined
    }

    /// Richer result for eval/debugging call sites that want to know HOW a
    /// decision was reached, not just the answer -- `songLevelSource` itself
    /// stays the single source of truth by delegating here and discarding
    /// the extra fields, so the two never drift apart.
    public struct Diagnostics: Equatable {
        public let language: Locale.Language?
        public let method: DetectionMethod
        /// Only meaningful for `.recognizer` (NLLanguageRecognizer's own
        /// confidence for the winning hypothesis); `1.0` for the
        /// script-determined tiers (hard Unicode-range facts, not a
        /// statistical guess), `nil` when `.undetermined`.
        public let confidence: Double?
    }

    public static func diagnostics(
        eligibleLineTexts: [String],
        supportedLanguageCodes: Set<String> = fallbackSupportedLanguageCodes
    ) -> Diagnostics {
        let lines = eligibleLineTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return Diagnostics(language: nil, method: .undetermined, confidence: nil) }
        let sampleText = lines.joined(separator: "\n")

        let hasKana = lines.contains { LanguageUtils.containsJapanese($0) }
        if hasKana {
            return Diagnostics(language: Locale.Language(identifier: "ja"), method: .kana, confidence: 1.0)
        }

        let hanCount = lines.filter { LanguageUtils.containsChinese($0) }.count
        if Double(hanCount) / Double(lines.count) > minimumHanDominance {
            let isTraditional = LanguageUtils.containsTraditionalOnlyChars(sampleText)
                && !LanguageUtils.containsSimplifiedOnlyChars(sampleText)
            let language = Locale.Language(identifier: isTraditional ? "zh-Hant" : "zh-Hans")
            return Diagnostics(language: language, method: .hanDominance, confidence: 1.0)
        }

        if let scriptLanguage = dominantDeterminateScriptLanguage(in: sampleText) {
            return Diagnostics(language: scriptLanguage, method: .script, confidence: 1.0)
        }

        let (recognized, confidence) = recognizerDeterminedLanguageWithConfidence(
            sampleText: sampleText, supportedLanguageCodes: supportedLanguageCodes
        )
        guard let recognized else {
            return Diagnostics(language: nil, method: .undetermined, confidence: confidence)
        }
        return Diagnostics(language: recognized, method: .recognizer, confidence: confidence)
    }

    /// Sums `ScriptRunSegmenter`-determinate run letter counts across the
    /// whole sample and returns the dominant one when it clears
    /// `minimumScriptDominance` of the sample's total letters. Han runs are
    /// excluded (handled separately above — Han alone is Chinese/Japanese-
    /// ambiguous, only kana disambiguates it).
    private static func dominantDeterminateScriptLanguage(in sampleText: String) -> Locale.Language? {
        let runs = ScriptRunSegmenter.segment(sampleText).filter { $0.language != .unknown }
        guard !runs.isEmpty else { return nil }

        var counts: [ScriptRunSegmenter.RunLanguage: Int] = [:]
        for run in runs {
            counts[run.language, default: 0] += run.text.count
        }
        guard let (dominant, dominantCount) = counts.max(by: { $0.value < $1.value }) else { return nil }

        let totalLetters = sampleText.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard totalLetters > 0, Double(dominantCount) / Double(totalLetters) >= minimumScriptDominance else { return nil }
        guard let identifier = dominant.localeIdentifier else { return nil }
        return Locale.Language(identifier: identifier)
    }

    /// Returns (language, confidence). `language` is nil when the winner
    /// misses the confidence floor or its margin over the runner-up, but
    /// `confidence` (the raw top-hypothesis value) is still returned for
    /// diagnostics even in that case.
    private static func recognizerDeterminedLanguageWithConfidence(
        sampleText: String,
        supportedLanguageCodes: Set<String>
    ) -> (Locale.Language?, Double?) {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supportedLanguageCodes.map { NLLanguage($0) }
        recognizer.processString(sampleText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        guard let best = hypotheses.first else { return (nil, nil) }
        guard best.value >= minimumConfidence else { return (nil, best.value) }
        if hypotheses.count > 1, best.value - hypotheses[1].value < minimumConfidenceMargin {
            return (nil, best.value)
        }
        return (Locale.Language(identifier: best.key.rawValue), best.value)
    }

    // ------------------------------------------------------------------
    // MARK: - Per-line gate
    // ------------------------------------------------------------------

    /// Whether `text` should be sent to the song's translation session (bound
    /// to the explicit `songSource`) at all. A line rides the song source
    /// when it either (a) carries no determinate script signal of its own
    /// (Latin/Han-only content — the common case, genuinely ambiguous
    /// without the song-level context) or (b) its determinate script(s)
    /// agree with `songSource`. A line that is ENTIRELY a different
    /// determinate script (e.g. a stray Korean aside in a Japanese song), or
    /// carries no letters at all (numbers/emoji/symbols only), is refused —
    /// sending mismatched content into a fixed-source session is exactly the
    /// "batch it cannot identify" case that used to surface the picker; the
    /// safe behavior is silence, not a guess.
    public static func lineIsConsistent(_ text: String, withSongSource songSource: Locale.Language) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }

        let determinateRuns = ScriptRunSegmenter.segment(trimmed).filter { $0.language != .unknown }
        guard !determinateRuns.isEmpty else { return true }

        let songCode = songSource.languageCode?.identifier
        return determinateRuns.allSatisfy { run in
            guard let identifier = run.language.localeIdentifier else { return true }
            return Locale.Language(identifier: identifier).languageCode?.identifier == songCode
        }
    }
}

// ============================================================================
// MARK: - Live "Translation-supported languages" memo (macOS 15+)
// ============================================================================

#if canImport(Translation)
import Translation

/// One real `LanguageAvailability().supportedLanguages` query for the life of
/// the process — mirrors `TranslationAvailabilityMemo`'s per-pair memo, but
/// for the flat list of supported language codes used to constrain
/// `LyricsTranslationSourceDetection`'s NLLanguageRecognizer pass.
@available(macOS 15.0, *)
public actor SupportedTranslationLanguagesMemo {
    public static let shared = SupportedTranslationLanguagesMemo()

    private var cached: Set<String>?

    public func languageCodes() async -> Set<String> {
        if let cached { return cached }
        let languages = await LanguageAvailability().supportedLanguages
        let codes = Set(languages.compactMap(\.languageCode?.identifier))
        let resolved = codes.isEmpty ? LyricsTranslationSourceDetection.fallbackSupportedLanguageCodes : codes
        cached = resolved
        return resolved
    }

    #if DEBUG
    public func debugReset() {
        cached = nil
    }
    #endif
}
#endif
