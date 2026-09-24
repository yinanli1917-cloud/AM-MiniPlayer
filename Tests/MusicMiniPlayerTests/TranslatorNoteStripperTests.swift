import XCTest
@testable import MusicMiniPlayerCore

/// Founder screenshot (2026-09-22/23): a NetEase-supplied translation
/// carried a translator's editorial note in full-width parentheses with no
/// counterpart in the original line -- see TranslatorNoteStripper.swift's
/// header for the exact string and the generalized (non-blocklist) rule.
final class TranslatorNoteStripperTests: XCTestCase {

    private func strip(_ translation: String, original: String) -> String {
        TranslatorNoteStripper.stripTrailingTranslatorNote(translation: translation, original: original)
    }

    // MARK: - The reported case (full-width parentheses)

    func test_fullWidthTrailingNote_noCounterpartInOriginal_isStripped() {
        let result = strip(
            "他说的没错。（其实所有的一切都是Mac的幻想，源于这个女生情愫）",
            original: "He was right."
        )
        XCTAssertEqual(result, "他说的没错。")
    }

    // MARK: - ASCII parentheses

    func test_asciiTrailingNote_noCounterpartInOriginal_isStripped() {
        let result = strip(
            "Hello there (translator's note: idiom)",
            original: "Hi"
        )
        XCTAssertEqual(result, "Hello there")
    }

    // MARK: - Original HAS a parenthetical counterpart -> keep translation untouched

    func test_originalHasFullWidthParenthetical_translationKeptAsIs() {
        let translation = "我依然爱你（永远）"
        let result = strip(translation, original: "I still love you (forever)")
        XCTAssertEqual(result, translation)
    }

    func test_originalHasAsciiParenthetical_translationKeptAsIs() {
        let translation = "你好（世界）"
        let result = strip(translation, original: "Hello (world)")
        XCTAssertEqual(result, translation)
    }

    /// Cross-bracket-kind counterpart still counts -- the original having
    /// ANY parenthetical aside is evidence the translation's own bracket is
    /// likely a legitimate rendering of it, not an annotator's note.
    func test_originalHasAsciiParenthetical_translationFullWidthKeptAsIs() {
        let translation = "你好（世界）"
        let result = strip(translation, original: "Hello (world)")
        XCTAssertEqual(result, translation)
    }

    // MARK: - Translation is ONLY a parenthetical -> keep as-is, never blank

    func test_translationIsOnlyAParenthetical_keptAsIs() {
        let translation = "（其实所有的一切都是Mac的幻想）"
        let result = strip(translation, original: "He was right.")
        XCTAssertEqual(result, translation)
    }

    func test_translationIsOnlyAsciiParenthetical_keptAsIs() {
        let translation = "(just a note)"
        let result = strip(translation, original: "Hi")
        XCTAssertEqual(result, translation)
    }

    // MARK: - No trailing parenthetical -> unchanged

    func test_noTrailingParenthetical_unchanged() {
        let translation = "他说的没错。"
        let result = strip(translation, original: "He was right.")
        XCTAssertEqual(result, translation)
    }

    // MARK: - Unbalanced brackets -> leave untouched (never guess)

    func test_unbalancedTrailingBracket_unchanged() {
        let translation = "他说的没错）"
        let result = strip(translation, original: "He was right.")
        XCTAssertEqual(result, translation)
    }

    // MARK: - Nested same-kind brackets inside the trailing note

    func test_nestedSameKindBracketsInsideNote_wholeNoteStripped() {
        let result = strip(
            "他说的没错。（注：这里有个 (细节) 需要说明）",
            original: "He was right."
        )
        XCTAssertEqual(result, "他说的没错。")
    }

    // MARK: - Trailing whitespace after the note

    func test_trailingWhitespaceAfterNote_stillStripped() {
        let result = strip(
            "他说的没错。（注）  \n",
            original: "He was right."
        )
        XCTAssertEqual(result, "他说的没错。")
    }

    // MARK: - Empty / trivial inputs

    func test_emptyTranslation_unchanged() {
        XCTAssertEqual(strip("", original: "He was right."), "")
    }
}
