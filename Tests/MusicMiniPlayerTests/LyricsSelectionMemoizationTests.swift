import XCTest
@testable import MusicMiniPlayerCore

// ============================================================
// MARK: - Selection Memoization Tests (proposal 8a)
// ============================================================
//
// The drain loop in fetchAllSources re-runs selection-style checks on every
// loop event. Two per-result facts dominate that cost and are pure functions
// of the immutable result (+ the fetch-constant song duration):
//
//   1. identity-token sets used in all-pairs lyric similarity
//   2. the single-result ("solo") selection verdict
//
// These tests pin the memo contract: repeated drain-style invocations must
// (a) never recompute a fact already known for a result instance, and
// (b) stay bit-identical to the unmemoized single-shot answers.
// Counters live in LyricsSelectionMemoProbe (DEBUG-only instrumentation).

final class LyricsSelectionMemoizationTests: XCTestCase {

    private let fetcher = LyricsFetcher.shared

    // MARK: - Fixtures

    /// English lines long enough that identity tokenization yields >= 6
    /// word-bigram tokens (the gate every consensus path checks).
    private static let identitySeed = [
        "standing by the doorway under neon light",
        "dancing with the shadow that keeps me awake",
        "every borrowed morning leaves a quiet trace",
        "carry all the letters that we never sent",
        "river running backwards through the silver town",
        "promise me the winter never finds this room",
        "counting every heartbeat on the kitchen floor",
        "all the tiny lanterns lead the long way home",
        "someday when the garden grows above the wall",
        "hold the fading photograph against the sun",
        "whisper to the engine till the highway ends",
        "morning paints the harbor in forgotten gold",
    ]

    private func makeLines(
        _ seed: [String],
        startingAt firstStart: Double = 0,
        gap: Double = 4.0,
        wordLevel: Bool = false
    ) -> [LyricLine] {
        seed.enumerated().map { index, text in
            let start = firstStart + Double(index) * gap
            let words: [LyricWord] = wordLevel
                ? text.split(separator: " ").enumerated().map { wordIndex, word in
                    let wordStart = start + Double(wordIndex) * 0.25
                    return LyricWord(word: String(word), startTime: wordStart, endTime: wordStart + 0.2)
                }
                : []
            return LyricLine(text: text, startTime: start, endTime: start + gap - 0.5, words: words)
        }
    }

    private func makeResult(
        source: LyricsSource,
        score: Double,
        lines: [LyricLine],
        kind: LyricsKind = .synced,
        titleMatched: Bool = true,
        matchedDurationDiff: Double? = 0.4
    ) -> LyricsFetcher.LyricsFetchResult {
        LyricsFetcher.LyricsFetchResult(
            lyrics: lines,
            source: source,
            score: score,
            kind: kind,
            albumMatched: false,
            titleMatched: titleMatched,
            matchedDurationDiff: matchedDurationDiff
        )
    }

    /// Four independent-source synced results sharing one lyric identity —
    /// enough candidates (>= 3) that selection runs the all-pairs identity
    /// consensus, the heaviest tokenization consumer.
    private func makeConsensusPool() -> [LyricsFetcher.LyricsFetchResult] {
        let shared = makeLines(Self.identitySeed)
        return [
            makeResult(source: .appleMusic, score: 75, lines: makeLines(Self.identitySeed, wordLevel: true)),
            makeResult(source: .netEase, score: 72, lines: shared),
            makeResult(source: .qq, score: 64, lines: shared),
            makeResult(source: .lrclib, score: 55, lines: shared),
        ]
    }

    // MARK: - (a) Token memo: drain-style repeats must not re-tokenize

    func testRepeatedDrainStyleSelectionTokenizesEachResultAtMostOnce() {
        let pool = makeConsensusPool()
        let before = LyricsSelectionMemoProbe.tokenizationPasses

        // Drain-style access pattern: the same accumulated pool is selected
        // over and over as loop events arrive (12+ events per fetch).
        for _ in 0..<12 {
            _ = fetcher.selectBestResult(from: pool, songDuration: 0)
        }

        let passes = LyricsSelectionMemoProbe.tokenizationPasses - before
        XCTAssertLessThanOrEqual(
            passes, pool.count,
            "lyric text is immutable per result — \(pool.count) results may tokenize at most once each, got \(passes) tokenization passes"
        )
    }

    // MARK: - (b) Equivalence: repeated drain-style calls vs single call

    func testDrainStyleRepeatedSelectionIsOutputIdenticalToSingleSelection() {
        let pool = makeConsensusPool()

        for songDuration in [0.0, 240.0] {
            // Growing prefixes simulate results arriving one by one, with the
            // selection re-asked several times per arrival (loop events).
            var lastPrefixAnswers: [(source: LyricsSource, score: Double, kind: LyricsKind)?] = []
            for upper in 1...pool.count {
                let prefix = Array(pool.prefix(upper))
                let answers = (0..<3).map { _ in
                    fetcher.selectBestResult(from: prefix, songDuration: songDuration)
                        .map { (source: $0.source, score: $0.score, kind: $0.kind) }
                }
                for answer in answers.dropFirst() {
                    XCTAssertEqual(answer?.source, answers[0]?.source)
                    XCTAssertEqual(answer?.score, answers[0]?.score)
                    XCTAssertEqual(answer?.kind, answers[0]?.kind)
                }
                lastPrefixAnswers = answers
            }

            // The final repeated answer must equal a fresh single-shot call
            // on an independently constructed (memo-cold) identical pool.
            let coldPool = makeConsensusPool()
            let single = fetcher.selectBestResult(from: coldPool, songDuration: songDuration)
            XCTAssertEqual(lastPrefixAnswers.last??.source, single?.source)
            XCTAssertEqual(lastPrefixAnswers.last??.score, single?.score)
            XCTAssertEqual(lastPrefixAnswers.last??.kind, single?.kind)
        }
    }

    // MARK: - (c) Solo verdict memo: computed once per result

    func testSoloSelectionVerdictComputesOncePerResult() {
        let result = makeResult(source: .netEase, score: 72, lines: makeLines(Self.identitySeed))
        let before = LyricsSelectionMemoProbe.soloVerdictComputations

        let first = fetcher.soloSelectionVerdict(for: result, songDuration: 0)
        for _ in 0..<11 {
            XCTAssertEqual(fetcher.soloSelectionVerdict(for: result, songDuration: 0), first)
        }

        let computations = LyricsSelectionMemoProbe.soloVerdictComputations - before
        XCTAssertEqual(
            computations, 1,
            "the solo verdict is a pure function of (result, songDuration) — 12 drain events must compute it once, got \(computations)"
        )
    }

    // MARK: - (d) Solo verdict equivalence with direct single-result selection

    func testSoloVerdictAgreesWithDirectSingleResultSelection() {
        let fixtures: [LyricsFetcher.LyricsFetchResult] = [
            makeResult(source: .netEase, score: 72, lines: makeLines(Self.identitySeed)),
            makeResult(source: .qq, score: 8, lines: makeLines(Self.identitySeed)),
            makeResult(source: .genius, score: 30, lines: makeLines(Self.identitySeed), kind: .unsynced),
            makeResult(source: .netEase, score: 50, lines: [], kind: .instrumental),
        ]
        for (index, result) in fixtures.enumerated() {
            let direct = fetcher.selectBestResult(from: [result], songDuration: 240) != nil
            XCTAssertEqual(
                fetcher.soloSelectionVerdict(for: result, songDuration: 240), direct,
                "fixture #\(index) memoized verdict must equal the direct single-result selection"
            )
        }
    }

    // MARK: - (e) Solo verdict memo must be keyed by song duration

    func testSoloVerdictIsKeyedBySongDuration() {
        // Timeline overshoots a 200s song (maxEnd ≈ 250s) → rejected there,
        // but with duration 0 every timeline validator is inert → accepted.
        // A memo that ignored the duration key would leak the first verdict.
        let overshooting = makeResult(
            source: .netEase,
            score: 72,
            lines: makeLines(Self.identitySeed, startingAt: 5, gap: 20)
        )
        XCTAssertFalse(fetcher.soloSelectionVerdict(for: overshooting, songDuration: 200))
        XCTAssertTrue(fetcher.soloSelectionVerdict(for: overshooting, songDuration: 0))
    }
}
