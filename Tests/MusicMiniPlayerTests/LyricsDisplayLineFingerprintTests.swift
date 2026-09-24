/**
 * [INPUT]: Depends on LyricsView.displayLineInputFingerprint(trackKey:showTranslation:
 *          firstRealLyricIndex:interludeAfterIndex:lyrics:) and
 *          LyricsView.wordLevelDowngradeViolations(sourceLines:displayLines:)
 *          (Sources/MusicMiniPlayerCore/UI/LyricsView.swift) + LyricModels
 *          (LyricLine/LyricWord) + DisplayLyricLine (LyricsPresentationModels.swift)
 * [OUTPUT]: Regression tests pinning the 2026-09-24 fix for word-level lyrics
 *           silently displaying as line-level.
 * [POS]: Tests -- exercises the real, now-`static` (non-private) production
 *        functions directly, not a source-mirror. No SwiftUI view hosting
 *        needed since both entry points are pure.
 *
 * Founder report (2026-09-24): Teresa Teng "The Way We Were" (radio) and
 * earlier Michael Jackson "Off the Wall" -- word-level (逐字) lyrics degrade
 * to line-level (逐行) ON SCREEN even though `/tmp/nanopod_debug.log` shows
 * the pipeline applying word-level data correctly ("NetEase YRC word-level
 * ... Applied ... unsynced=false").
 *
 * Mechanism (LyricsView.swift): `refreshDisplayLineCache()`'s dedup guard
 * bails out whenever `displayLineInputFingerprint()` is unchanged from the
 * last committed value -- but that fingerprint used to hash only
 * `line.text` + `line.translation` for every source line, NEVER `line.words`
 * / `hasSyllableSync`. `LyricsService.applyLyrics` performs an intentional,
 * tested line-level -> word-level hot-switch
 * (`applyFetchedLyricsIfCurrent`'s `upgradedLineToWord`,
 * `LyricsWordLevelPriorityTests`) whenever a later, better source resolves
 * for the same song. When that later source transcribes the identical line
 * text (the common case -- different providers of the same real lyrics),
 * `text`/`translation` are unchanged and ONLY `words` differs. `LyricLine`'s
 * `id` is a fresh UUID per construction (so SwiftUI's
 * `.onChange(of: lyricsService.lyrics)` DOES fire on every hot-switch --
 * verified by reading `LyricModels.swift`: `Equatable` is synthesized and
 * includes `id`), but the OLD fingerprint deliberately ignored `id` ("hash
 * the content... never the line identity") while also, as an oversight,
 * ignoring the one piece of "content" that actually changed: `words`. Net
 * effect: `refreshDisplayLineCache` silently no-ops, `cachedDisplayLyrics`
 * stays frozen at the earlier line-level split, and the native renderer
 * keeps drawing a whole-line sweep forever -- even though
 * `lyricsService.lyrics` (and the debug log) show the word-level upgrade
 * landed correctly. `research/diagnosis-2026-09-24-word-level-display-freeze.md`
 * has the full writeup.
 *
 * Red-before-fix verified manually: temporarily removed the
 * `hasher.combine(line.words.count)` line from
 * `LyricsView.displayLineInputFingerprint`, reran
 * `test_fingerprintChangesWhenWordLevelSyncAppears_identicalTextAndTranslation`
 * -- failed (`XCTAssertNotEqual` fired, fingerprints were identical). Restored
 * immediately after, reran green.
 *
 * Safety: pure value-type tests, no network, no LyricsService/disk-cache
 * access, no ~/Library/Application Support/nanoPod/ I/O.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsDisplayLineFingerprintTests: XCTestCase {

    // MARK: - Fixtures

    /// Same real lyric text NetEase's plain LRC and YRC (word-level) endpoints
    /// would both transcribe for the same song -- this is the actual
    /// real-world shape of a line-level -> word-level hot-switch, not a
    /// contrived edge case.
    private static let sharedLines: [String] = [
        "when the world is on your shoulder",
        "gotta straighten up your act and boogie down",
    ]

    private func makeLine(_ text: String, wordLevel: Bool, translation: String? = nil, index: Int) -> LyricLine {
        let start = Double(index) * 4.0
        let end = start + 3.5
        let words: [LyricWord] = wordLevel
            ? text.split(separator: " ").enumerated().map { wordIndex, word in
                let wordStart = start + Double(wordIndex) * 0.3
                return LyricWord(word: String(word), startTime: wordStart, endTime: wordStart + 0.25)
            }
            : []
        return LyricLine(text: text, startTime: start, endTime: end, words: words, translation: translation)
    }

    private func makeLines(wordLevel: Bool, translation: String? = nil) -> [LyricLine] {
        Self.sharedLines.enumerated().map { index, text in
            makeLine(text, wordLevel: wordLevel, translation: translation, index: index)
        }
    }

    // MARK: - The regression itself

    /// The exact mechanism: a hot-switch from line-level to word-level that
    /// transcribes IDENTICAL text/translation must produce a DIFFERENT
    /// fingerprint, or `refreshDisplayLineCache`'s dedup guard freezes the
    /// display at line-level forever.
    func test_fingerprintChangesWhenWordLevelSyncAppears_identicalTextAndTranslation() {
        let lineLevel = makeLines(wordLevel: false, translation: "翻译甲")
        let wordLevel = makeLines(wordLevel: true, translation: "翻译甲")

        // Sanity: this really is the "only words differs" scenario the
        // mechanism depends on.
        XCTAssertEqual(lineLevel.map(\.text), wordLevel.map(\.text))
        XCTAssertEqual(lineLevel.map(\.translation), wordLevel.map(\.translation))
        XCTAssertFalse(lineLevel.contains { $0.hasSyllableSync })
        XCTAssertTrue(wordLevel.allSatisfy { $0.hasSyllableSync })

        let fingerprintBefore = LyricsView.displayLineInputFingerprint(
            trackKey: "The Way We Were|Teresa Teng",
            showTranslation: true,
            firstRealLyricIndex: 0,
            interludeAfterIndex: nil,
            lyrics: lineLevel
        )
        let fingerprintAfter = LyricsView.displayLineInputFingerprint(
            trackKey: "The Way We Were|Teresa Teng",
            showTranslation: true,
            firstRealLyricIndex: 0,
            interludeAfterIndex: nil,
            lyrics: wordLevel
        )

        XCTAssertNotEqual(
            fingerprintBefore, fingerprintAfter,
            "a text-identical line-level -> word-level hot-switch must invalidate the display-line cache"
        )
    }

    /// Word COUNT changing while `hasSyllableSync` stays true (e.g. a more
    /// complete word-level backfill replacing a partial one) must also be
    /// visible -- not just the boolean transition.
    func test_fingerprintChangesWhenWordCountChangesButSyncStaysTrue() {
        let partial = [makeLine("hello there friend", wordLevel: false, index: 0)]
            .map { line -> LyricLine in
                LyricLine(text: line.text, startTime: line.startTime, endTime: line.endTime,
                          words: [LyricWord(word: "hello there friend", startTime: 0, endTime: 1)])
            }
        let full = [makeLine("hello there friend", wordLevel: true, index: 0)]

        let fingerprintPartial = LyricsView.displayLineInputFingerprint(
            trackKey: "k", showTranslation: false, firstRealLyricIndex: 0,
            interludeAfterIndex: nil, lyrics: partial
        )
        let fingerprintFull = LyricsView.displayLineInputFingerprint(
            trackKey: "k", showTranslation: false, firstRealLyricIndex: 0,
            interludeAfterIndex: nil, lyrics: full
        )

        XCTAssertNotEqual(fingerprintPartial, fingerprintFull)
    }

    /// The fingerprint must stay a pure function of CONTENT, not identity --
    /// `LyricLine.id` is a fresh UUID every construction (confirmed via
    /// `LyricModels.swift`), so two independently-built, content-identical
    /// arrays must fingerprint the SAME, or every re-render (even a no-op
    /// one) would thrash the native surface. This is the invariant the
    /// original code's own comment stated as intentional; the fix must not
    /// break it.
    func test_fingerprintIsIdenticalForContentIdenticalButDistinctLineObjects() {
        let a = makeLines(wordLevel: true, translation: "同一句翻译")
        let b = makeLines(wordLevel: true, translation: "同一句翻译")
        XCTAssertNotEqual(a.map(\.id), b.map(\.id), "sanity: distinct constructions really do get distinct UUIDs")

        let fingerprintA = LyricsView.displayLineInputFingerprint(
            trackKey: "k", showTranslation: true, firstRealLyricIndex: 0,
            interludeAfterIndex: 2, lyrics: a
        )
        let fingerprintB = LyricsView.displayLineInputFingerprint(
            trackKey: "k", showTranslation: true, firstRealLyricIndex: 0,
            interludeAfterIndex: 2, lyrics: b
        )
        XCTAssertEqual(fingerprintA, fingerprintB)
    }

    /// The other existing inputs (track identity, translation visibility,
    /// first-real-lyric index, interlude index) must still participate --
    /// guards against a careless refactor collapsing the fingerprint down to
    /// "just the lyrics".
    func test_fingerprintStillReactsToNonLyricsInputs() {
        let lyrics = makeLines(wordLevel: true)
        let base = LyricsView.displayLineInputFingerprint(
            trackKey: "song|artist", showTranslation: true, firstRealLyricIndex: 1,
            interludeAfterIndex: 3, lyrics: lyrics
        )
        XCTAssertNotEqual(base, LyricsView.displayLineInputFingerprint(
            trackKey: "different|artist", showTranslation: true, firstRealLyricIndex: 1,
            interludeAfterIndex: 3, lyrics: lyrics
        ))
        XCTAssertNotEqual(base, LyricsView.displayLineInputFingerprint(
            trackKey: "song|artist", showTranslation: false, firstRealLyricIndex: 1,
            interludeAfterIndex: 3, lyrics: lyrics
        ))
        XCTAssertNotEqual(base, LyricsView.displayLineInputFingerprint(
            trackKey: "song|artist", showTranslation: true, firstRealLyricIndex: 0,
            interludeAfterIndex: 3, lyrics: lyrics
        ))
        XCTAssertNotEqual(base, LyricsView.displayLineInputFingerprint(
            trackKey: "song|artist", showTranslation: true, firstRealLyricIndex: 1,
            interludeAfterIndex: nil, lyrics: lyrics
        ))
    }

    // MARK: - DEBUG invariant guard

    #if DEBUG
    /// Clean path: every display row split from a word-level source line
    /// still carries words -- exactly what `makeDisplayLyricLines`'s
    /// `hasSyllableSync` branch produces today (`words: group` on every
    /// segment, see LyricsView.swift). No violations reported.
    func test_invariantGuard_reportsNoViolations_whenSplitPiecesKeepWords() {
        let source = makeLines(wordLevel: true)
        let displayLines: [DisplayLyricLine] = source.enumerated().map { index, line in
            // Mirrors makeDisplayLyricLines's word-level branch: split into
            // two pieces, EACH keeping a non-empty words slice (the
            // production invariant this codebase is supposed to hold).
            let half = max(1, line.words.count / 2)
            let firstWords = Array(line.words.prefix(half))
            let secondWords = Array(line.words.suffix(from: half))
            return [
                DisplayLyricLine(
                    id: "\(index)-0", sourceIndex: index, segmentIndex: 0, segmentCount: 2,
                    line: LyricLine(text: LyricDisplaySegmenter.displayText(forWords: firstWords),
                                     startTime: line.startTime, endTime: line.endTime, words: firstWords)
                ),
                DisplayLyricLine(
                    id: "\(index)-1", sourceIndex: index, segmentIndex: 1, segmentCount: 2,
                    line: LyricLine(text: LyricDisplaySegmenter.displayText(forWords: secondWords),
                                     startTime: line.startTime, endTime: line.endTime, words: secondWords)
                ),
            ]
        }.flatMap { $0 }

        let violations = LyricsView.wordLevelDowngradeViolations(sourceLines: source, displayLines: displayLines)
        XCTAssertTrue(violations.isEmpty, "no real split piece should ever lose its words")
    }

    /// Defense-in-depth: if a FUTURE edit to the split path ever drops
    /// `words` for a piece built from a word-level source line, the guard
    /// must catch it (this is what would have caught this bug's sibling
    /// mechanism had it lived inside the split itself, rather than the
    /// cache-invalidation gate this fix addresses).
    func test_invariantGuard_detectsWordLossOnWordLevelSourceLine() {
        let source = makeLines(wordLevel: true)
        // Simulate the bug class: a display piece built from a word-level
        // source line that ended up with an EMPTY words array.
        let brokenDisplayLines = [
            DisplayLyricLine(
                id: "0-0", sourceIndex: 0, segmentIndex: 0, segmentCount: 1,
                line: LyricLine(text: source[0].text, startTime: source[0].startTime, endTime: source[0].endTime, words: [])
            ),
            DisplayLyricLine(
                id: "1-0", sourceIndex: 1, segmentIndex: 0, segmentCount: 1,
                line: source[1]
            ),
        ]

        let violations = LyricsView.wordLevelDowngradeViolations(sourceLines: source, displayLines: brokenDisplayLines)
        XCTAssertEqual(violations.count, 1)
        XCTAssertEqual(violations.first?.sourceIndex, 0)
    }
    #endif

    // MARK: - Render plan still produces word runs once the display line keeps its words

    /// Closes the loop end-to-end: a display line that correctly kept its
    /// `words` (the fixed path) actually gets rendered with per-word sweep
    /// runs, not a whole-line fallback -- the on-screen symptom the founder
    /// reported.
    func test_renderPlan_producesWordRuns_forWordLevelDisplayLine() {
        let wordLevelLine = makeLine("gotta straighten up your act and boogie down", wordLevel: true, index: 0)
        XCTAssertTrue(wordLevelLine.hasSyllableSync)

        let staticPlan = NativeLyricsStaticTextRenderPlan.make(line: wordLevelLine)
        XCTAssertFalse(staticPlan.wordRuns.isEmpty, "a word-level line must produce per-word run plans, not an empty list")

        let configuration = NativeLyricsTextRenderPlan.Configuration(
            line: wordLevelLine, currentTime: wordLevelLine.startTime + 0.5, isActive: true
        )
        let plan = NativeLyricsTextRenderPlan.make(configuration: configuration, staticPlan: staticPlan)
        XCTAssertFalse(plan.wordRuns.isEmpty)
        // mainSweepProgress must be computed from the per-word timeline
        // (wordCountProgress), not the line-level linear fallback -- both
        // land in [0, 1], but a mid-line active word-level row should not
        // read as fully swept this early.
        XCTAssertGreaterThan(plan.mainSweepProgress, 0)
        XCTAssertLessThan(plan.mainSweepProgress, 1)
    }
}
