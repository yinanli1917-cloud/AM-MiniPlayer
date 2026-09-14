/**
 * [INPUT]: MusicMiniPlayerCore TranslationAvailabilityMemo
 * [OUTPUT]: Per-(source,target) memoization of the system LanguageAvailability
 *           check
 * [POS]: Test module (task A5, 2026-09) — pins audit fact (a)'s system-check
 *        half: `silentSystemTranslationConfiguration` used to call
 *        `LanguageAvailability().status(...)` once per song even when the
 *        language pair never changes. This must collapse to one real check
 *        per process per pair.
 */

import XCTest
@testable import MusicMiniPlayerCore

@available(macOS 15.0, *)
final class TranslationAvailabilityMemoTests: XCTestCase {

    override func setUp() async throws {
        await TranslationAvailabilityMemo.shared.debugReset()
    }

    func test_samePair_checkedOnce() async {
        let en = Locale.Language(identifier: "en")
        let zh = Locale.Language(identifier: "zh-Hans")

        _ = await TranslationAvailabilityMemo.shared.status(from: en, to: zh)
        _ = await TranslationAvailabilityMemo.shared.status(from: en, to: zh)
        _ = await TranslationAvailabilityMemo.shared.status(from: en, to: zh)

        let count = await TranslationAvailabilityMemo.shared.debugCheckCount
        XCTAssertEqual(count, 1, "repeat requests for the same (source, target) pair must not re-run the system check")
    }

    func test_differentPairs_eachCheckedOnce() async {
        let en = Locale.Language(identifier: "en")
        let zh = Locale.Language(identifier: "zh-Hans")
        let ja = Locale.Language(identifier: "ja")

        _ = await TranslationAvailabilityMemo.shared.status(from: en, to: zh)
        _ = await TranslationAvailabilityMemo.shared.status(from: en, to: ja)
        _ = await TranslationAvailabilityMemo.shared.status(from: en, to: zh)

        let count = await TranslationAvailabilityMemo.shared.debugCheckCount
        XCTAssertEqual(count, 2, "distinct pairs are independent — 2 pairs, 2 checks total, not 3")
    }
}
