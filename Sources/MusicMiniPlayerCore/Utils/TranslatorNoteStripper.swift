/**
 * [INPUT]: Foundation only (pure string logic -- no LyricsService, no
 *          network, no LyricsParser dependency the other direction).
 * [OUTPUT]: Exports TranslatorNoteStripper.stripTrailingTranslatorNote.
 * [POS]: Utils -- called by LyricsParser.mergeLyricsWithTranslation /
 *        mergeOneLineDelayedTranslationsIfSupported right where a lyrics
 *        PROVIDER's own translation text (NetEase/QQ tlyric, never the
 *        on-device system Translation framework's output) is attached to a
 *        line, before it is ever displayed or cached.
 *
 * Founder screenshot (2026-09-22/23): a NetEase translation carried a
 * translator's editorial note in full-width parentheses with no counterpart
 * in the original line --
 * "（其实所有的一切都是Mac的幻想，源于这个女生情愫）" appended after the
 * real translated sentence. This is a known class of noise in
 * community-sourced lyrics translations (annotator commentary, not part of
 * the song), and it is NOT specific to one song or one exact string --
 * hence a generic bracket-balance rule instead of a literal-string
 * blocklist (banned-patterns.md: no whitelist/enumeration-style fixes).
 *
 * Rule: if the translation ends with a BALANCED parenthetical segment
 * (ASCII `(...)` or full-width `（...）`) and the ORIGINAL line has no
 * parenthetical of its own (either kind — a real parenthetical aside in the
 * original is exactly the case where the translation's matching
 * parenthetical is legitimate content, not an annotator's note), that
 * trailing segment is removed. If removing it would leave nothing behind
 * (the translation IS just the parenthetical, nothing else), the
 * translation is left untouched — better an occasional un-stripped note
 * than a blanked-out line where a real translation used to be.
 */

import Foundation

public enum TranslatorNoteStripper {

    private static let closingToOpening: [Character: Character] = [
        ")": "(",
        "）": "（",
    ]

    /// True when `text` contains a matched (open ... close) pair of either
    /// ASCII or full-width parentheses, in that order — used as the "does
    /// the original have a parenthetical counterpart" test. Deliberately
    /// coarse (a same-kind open followed later by a same-kind close
    /// anywhere in the string, not necessarily balanced/nested correctly):
    /// this only needs to answer "should a trailing note in the TRANSLATION
    /// be trusted as real content", and a false positive here just means an
    /// occasional note survives uncleaned — the safe direction, matching
    /// this module's overall bias toward under- rather than over-stripping.
    private static func hasParentheticalCounterpart(_ text: String) -> Bool {
        for (close, open) in closingToOpening {
            if let openIndex = text.firstIndex(of: open),
               let closeIndex = text[openIndex...].firstIndex(of: close) {
                _ = closeIndex
                return true
            }
        }
        return false
    }

    /// Removes a single TRAILING balanced parenthetical segment from
    /// `translation` when `original` has no parenthetical counterpart of
    /// its own. Returns `translation` unchanged in every other case
    /// (original has its own parentheses; translation doesn't end with a
    /// closing bracket; brackets are unbalanced; or stripping would leave
    /// an empty string).
    public static func stripTrailingTranslatorNote(translation: String, original: String) -> String {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last, let openChar = closingToOpening[lastChar] else {
            return translation
        }
        guard !hasParentheticalCounterpart(original) else { return translation }

        // Walk backward from the end tracking bracket depth (same kind
        // only) to find the OPEN character that matches this trailing
        // CLOSE — handles a trailing note that itself contains a nested
        // same-kind pair, e.g. "text.（note (detail) more）".
        var depth = 0
        var openIndex: String.Index?
        var index = trimmed.index(before: trimmed.endIndex)
        while true {
            let character = trimmed[index]
            if character == lastChar {
                depth += 1
            } else if character == openChar {
                depth -= 1
                if depth == 0 {
                    openIndex = index
                    break
                }
            }
            if index == trimmed.startIndex { break }
            index = trimmed.index(before: index)
        }

        guard let openIndex else { return translation } // unbalanced -- leave untouched

        let before = trimmed[trimmed.startIndex..<openIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !before.isEmpty else {
            // The translation IS just the parenthetical -- keep it as-is
            // rather than blanking a line that would otherwise carry no
            // translation at all.
            return translation
        }
        return before
    }
}
