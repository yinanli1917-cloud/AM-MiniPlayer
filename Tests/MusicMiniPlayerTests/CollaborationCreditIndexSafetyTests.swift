/**
 * [INPUT]: Depends on MusicMiniPlayerCore's LyricsFetcher (asciiTitleCollaborators,
 *          titleWithoutCollaborationCredit, titleHasCollaborationCredit) and
 *          collaborationEvidenceTitleQuery (LyricsCandidateSelection extension)
 * [OUTPUT]: Exports CollaborationCreditIndexSafetyTests (XCTestCase)
 * [POS]: Regression test for the 2026-09-26 cross-string String.Index crash in
 *        LyricsFetcher's collaboration-credit parsing
 */

import XCTest
import Foundation
@testable import MusicMiniPlayerCore

// ============================================================
// MARK: - Collaboration Credit Index Safety Tests
// ============================================================
//
// 2026-09-26 crash: 7x nanoPod-2026-09-26-*.ips, all EXC_BREAKPOINT/SIGTRAP,
// same stack: `asciiTitleCollaborators(from:)` (LyricsFetcher.swift:3007,
// `var suffix = String(title[suffixStart...])`) <- `titleHasCollaborationCredit`
// <- `fetchAllSourcesWithinForegroundBudget`. Track: '练声曲 (feat. 窦靖童)' by
// Jude Chiu, album '裘德' — hit on both the foreground fetch and the preload
// path because the track sits in recent history.
//
// Root cause: `asciiTitleCollaborators`/`titleWithoutCollaborationCredit`
// computed a `String.Index` against `title.lowercased()` — a fresh NATIVE
// Swift String (UTF-8-backed) — then used that index to slice `title`
// itself. `title` here is a ScriptingBridge/AppleScript string: an actual
// NSString bridged to Swift, stored as UTF-16 code units. A `String.Index`
// minted against a UTF-8-backed string and reused on a UTF-16-backed string
// is only safe by coincidence (pure ASCII, where 1 byte == 1 code unit per
// character). Any CJK character before the match point breaks that
// coincidence (3 UTF-8 bytes vs 1 UTF-16 code unit), so the offset computed
// against `lower` overruns `title`'s actual code-unit count and subscripting
// traps.
//
// Fix: search `title` itself with `.range(of:options: .caseInsensitive)` and
// slice `title` with the resulting range — one string, one index space. The
// same fix is applied to `LyricsCandidateSelection.collaborationEvidenceTitleQuery`
// (guarded by `isPureASCII` today, so not currently exploitable, but the same
// banned pattern).
final class CollaborationCreditIndexSafetyTests: XCTestCase {

    // MARK: - Bridged-string construction

    /// Builds a Swift `String` the way ScriptingBridge/AppleScript hands
    /// titles back to the app: a real `NSString` object (UTF-16 code-unit
    /// storage), bridged to Swift without forcing a native re-encode.
    private func bridged(_ value: String) -> String {
        let units = Array(value.utf16)
        let ns = units.withUnsafeBufferPointer { buffer -> NSString in
            NSString(characters: buffer.baseAddress!, length: buffer.count)
        }
        return ns as String
    }

    /// A plain native Swift String (UTF-8 storage) — the control group.
    private func native(_ value: String) -> String { value }

    /// Sanity check that `bridged(_:)` produces genuine bridged storage
    /// rather than something the runtime silently folded back into a native
    /// small/large string. If this starts failing, the repro method itself
    /// needs to change — a silently-native string would prove nothing.
    func test_bridgedHelper_producesRealBridgedStorage() {
        let value = "练声曲 (feat. 窦靖童)"
        XCTAssertEqual(bridged(value), value, "bridging must round-trip content exactly")
        XCTAssertGreaterThan(value.utf8.count, 15, "must exceed small-string inline capacity")
    }

    // MARK: - Crash repro (the exact 2026-09-26 production crash)
    //
    // Pre-fix, each of these traps the whole XCTest process with a Swift
    // runtime fatal error (String/Range index-safety precondition,
    // SIGTRAP/EXC_BREAKPOINT) — see scratchpad/crash-repro-output.txt for
    // the captured pre-fix run:
    //
    //   Swift/Range.swift:760: Fatal error: Range requires lowerBound <= upperBound
    //   error: Exited with unexpected signal code 5
    //
    // (Field crash reports show the sibling trap "String index is out of
    // bounds" at the same call site; both are the Swift runtime rejecting
    // the same corrupted cross-string index — which one fires first depends
    // on the toolchain. Signal 5 == SIGTRAP == EXC_BREAKPOINT, matching all
    // 7 nanoPod-2026-09-26-*.ips reports.)

    func test_crashRepro_bridgedChineseFeatTitle_asciiTitleCollaborators_doesNotTrap() {
        let fetcher = LyricsFetcher.shared
        let title = bridged("练声曲 (feat. 窦靖童)")
        let collaborators = fetcher.asciiTitleCollaborators(from: title)
        // 窦靖童 is CJK, not ASCII, so it is correctly excluded from the
        // ascii-only collaborator list — the function must just report none,
        // not crash.
        XCTAssertEqual(collaborators, [])
    }

    func test_crashRepro_bridgedChineseFeatTitle_titleHasCollaborationCredit_doesNotTrap() {
        let fetcher = LyricsFetcher.shared
        let title = bridged("练声曲 (feat. 窦靖童)")
        XCTAssertFalse(fetcher.titleHasCollaborationCredit(title))
    }

    func test_crashRepro_bridgedChineseFeatTitle_titleWithoutCollaborationCredit_returnsPrimaryTitle() {
        let fetcher = LyricsFetcher.shared
        let title = bridged("练声曲 (feat. 窦靖童)")
        XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(title), "练声曲")
    }

    // MARK: - Native-ASCII regression (must be byte-for-byte identical to pre-fix)
    //
    // ASCII case-folding never changes UTF-8/UTF-16 code-unit counts, so the
    // pre-fix `lower.range(of:)`-derived index already happened to be valid
    // here. These values are hand-verified and must not change.

    func test_nativeAsciiTitle_behaviorUnchanged() {
        let fetcher = LyricsFetcher.shared
        let title = "Perfect (feat. Ed Sheeran)"
        XCTAssertTrue(fetcher.titleHasCollaborationCredit(title))
        XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(title), "Perfect")
        XCTAssertEqual(fetcher.asciiTitleCollaborators(from: title), ["Ed Sheeran"])
    }

    func test_noMarker_returnsEmptyRegardlessOfStorage() {
        let fetcher = LyricsFetcher.shared
        for title in [native("Just A Title"), bridged("Just A Title")] {
            XCTAssertFalse(fetcher.titleHasCollaborationCredit(title))
            XCTAssertNil(fetcher.titleWithoutCollaborationCredit(title))
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: title), [])
        }
    }

    // MARK: - Case-insensitivity preserved (the old code's whole reason to
    // lowercase in the first place — the fix must not regress this)

    func test_markerCaseInsensitivity_preservedAcrossCaseVariants() {
        let fetcher = LyricsFetcher.shared
        let variants = ["Song (feat. Guest)", "Song (FEAT. Guest)", "Song (Feat. Guest)", "Song (FeAt. Guest)"]
        let results = variants.map { title -> (Bool, String?, [String]) in
            (fetcher.titleHasCollaborationCredit(title),
             fetcher.titleWithoutCollaborationCredit(title),
             fetcher.asciiTitleCollaborators(from: title))
        }
        for result in results {
            XCTAssertTrue(result.0)
            XCTAssertEqual(result.1, "Song")
            XCTAssertEqual(result.2, ["Guest"])
        }
    }

    // MARK: - Storage-independence across title shapes
    //
    // The bug was that storage form (bridged UTF-16 vs native UTF-8) changed
    // — or crashed — the answer. The fix makes the answer depend only on
    // CONTENT, never storage. Rather than hand-deriving each expected string
    // (fragile: e.g. `titleWithoutCollaborationCredit`'s marker list is a
    // strict subset of `asciiTitleCollaborators`'s and does not include the
    // fullwidth "（feat." variant — a pre-existing asymmetry, out of scope
    // here), assert the invariant the crash actually violated: bridged and
    // native storage of the SAME content must agree, and neither must trap.

    private let titleShapes: [String] = [
        "练声曲 (feat. 窦靖童)",       // Chinese before marker (the production crash title)
        "曲名 (feat. Yui)",           // Japanese before marker
        "노래 (feat. Jay)",           // Korean before marker
        "🎵Song (feat. Guest)",       // emoji (astral/surrogate-pair) before marker
        "İstanbul (feat. Guest)",     // Turkish dotted I — lowercased to a 2-scalar sequence
        "歌 （feat. Guest)",          // fullwidth "（feat." marker
        "(feat. Guest) Song",         // marker at the very start (empty prefix)
        "Song feat. Guest",           // marker near the end, no closing bracket
        "Just A Title",               // no marker
    ]

    func test_allTitleShapes_bridgedMatchesNative_andNeitherTraps() {
        let fetcher = LyricsFetcher.shared
        for title in titleShapes {
            let nativeTitle = native(title)
            let bridgedTitle = bridged(title)
            XCTAssertEqual(
                fetcher.titleHasCollaborationCredit(bridgedTitle),
                fetcher.titleHasCollaborationCredit(nativeTitle),
                "hasCredit diverged by storage form for '\(title)'"
            )
            XCTAssertEqual(
                fetcher.titleWithoutCollaborationCredit(bridgedTitle),
                fetcher.titleWithoutCollaborationCredit(nativeTitle),
                "primaryTitle diverged by storage form for '\(title)'"
            )
            XCTAssertEqual(
                fetcher.asciiTitleCollaborators(from: bridgedTitle),
                fetcher.asciiTitleCollaborators(from: nativeTitle),
                "collaborators diverged by storage form for '\(title)'"
            )
        }
    }

    /// Same content, hand-verified expected values, for the shapes simple
    /// enough to reason about by hand (no cross-function marker-list quirks).
    func test_selectedTitleShapes_matchHandVerifiedValues() {
        let fetcher = LyricsFetcher.shared
        for wrap in [native, bridged] {
            XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(wrap("曲名 (feat. Yui)")), "曲名")
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: wrap("曲名 (feat. Yui)")), ["Yui"])

            XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(wrap("노래 (feat. Jay)")), "노래")
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: wrap("노래 (feat. Jay)")), ["Jay"])

            XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(wrap("🎵Song (feat. Guest)")), "🎵Song")
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: wrap("🎵Song (feat. Guest)")), ["Guest"])

            XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(wrap("İstanbul (feat. Guest)")), "İstanbul")
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: wrap("İstanbul (feat. Guest)")), ["Guest"])

            // Marker at the very start: empty prefix before trimming -> nil.
            XCTAssertNil(fetcher.titleWithoutCollaborationCredit(wrap("(feat. Guest) Song")))
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: wrap("(feat. Guest) Song")), ["Guest"])

            // Marker near the end, no closing bracket to truncate at.
            XCTAssertEqual(fetcher.titleWithoutCollaborationCredit(wrap("Song feat. Guest")), "Song")
            XCTAssertEqual(fetcher.asciiTitleCollaborators(from: wrap("Song feat. Guest")), ["Guest"])
        }
    }

    // MARK: - Same-class fix: collaborationEvidenceTitleQuery (LyricsCandidateSelection)
    //
    // Only reached with `isPureASCII` inputs today, so not currently
    // exploitable, but fixed to the same same-string pattern for hygiene.

    func test_collaborationEvidenceTitleQuery_asciiTitle_unchangedFromPreFix() {
        // Pinned to the existing oracle in LyricsSelectionTests.swift
        // (testCollaborationEvidenceTitleQueryPreservesFeaturedArtistTokens).
        XCTAssertEqual(
            LyricsFetcher.collaborationEvidenceTitleQuery(from: "Distance (feat. deca joins)"),
            "Distance deca joins"
        )
        XCTAssertEqual(
            LyricsFetcher.collaborationEvidenceTitleQuery(from: "Song ft. Artist A & Artist B"),
            "Song Artist A Artist B"
        )
    }

    func test_collaborationEvidenceTitleQuery_bridgedMatchesNative() {
        for title in ["Distance (feat. deca joins)", "Song (FEAT. Guest Name)"] {
            XCTAssertEqual(
                LyricsFetcher.collaborationEvidenceTitleQuery(from: bridged(title)),
                LyricsFetcher.collaborationEvidenceTitleQuery(from: native(title))
            )
        }
    }
}
