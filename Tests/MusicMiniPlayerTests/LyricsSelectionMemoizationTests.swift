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
        matchedDurationDiff: Double? = 0.4,
        nativeAliasMatched: Bool = false
    ) -> LyricsFetcher.LyricsFetchResult {
        LyricsFetcher.LyricsFetchResult(
            lyrics: lines,
            source: source,
            score: score,
            kind: kind,
            albumMatched: false,
            titleMatched: titleMatched,
            matchedDurationDiff: matchedDurationDiff,
            nativeAliasMatched: nativeAliasMatched
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

    // ============================================================
    // MARK: - Exit-Closure Split (proposal 8b)
    // ============================================================
    //
    // The foreground drain loop re-evaluates its exit-decision closures on
    // every loop event over every accumulated result. The per-result PURE
    // terms of those closures (syllable-sync scan, CJK scan, romanized-CJK
    // check, timeline sanity, alias-identity flags) are split out into a
    // DrainExitFacts bundle computed once per result; pool composition,
    // elapsed time and branch flags stay event-side. selectReliable's
    // per-result scorer terms (isLikelyRomaji, analyzeQuality.isValid) ride
    // the same write-once box, and 1-element pool selections route through
    // the solo-verdict memo as the single chokepoint.

    /// Chinese lines spanning 0–198s (gap 18): sane timeline for a 240s song.
    private static let cjkSeed = [
        "我们的爱情在时间里慢慢变老",
        "你的心还在等待昨天的回答",
        "我走过黄昏的街角想起你",
        "雨水落在旧照片上的笑容",
        "我们说好的明天还没有来",
        "风吹过城市最安静的屋顶",
        "你留下的歌我还在反复听",
        "灯火熄灭后只剩下了回声",
        "我把思念写进未寄出的信",
        "时间带走了所有的不确定",
        "如果重来我还会牵你的手",
        "让这首歌代替我说再见吧",
    ]

    /// Pinyin-syllable lines: >= 4 real lines, >= 12 tokens, hit ratio far
    /// above the 0.45 romanized-CJK threshold.
    private static let pinyinSeed = [
        "wo men de ai qing zai shi jian li",
        "ni de xin hai zai deng wo de hui da",
        "wo men zai hui yi li man man bian lao",
        "ni shuo de hua wo hai ji de",
    ]

    // MARK: - (f) Drain facts: 12 simulated events compute once per result

    func testDrainExitFactsComputeOncePerResultAcrossSimulatedDrainEvents() {
        let pool = makeConsensusPool()
        let before = LyricsSelectionMemoProbe.drainFactsComputations

        // Drain-style access pattern: every loop event re-evaluates the
        // exit closures for every accumulated result (12+ events per fetch).
        for _ in 0..<12 {
            for result in pool {
                _ = fetcher.drainExitFacts(for: result, songDuration: 240)
            }
        }

        let computations = LyricsSelectionMemoProbe.drainFactsComputations - before
        XCTAssertEqual(
            computations, pool.count,
            "exit facts are pure per result — \(pool.count) results across 12 events must compute exactly once each, got \(computations)"
        )
    }

    // MARK: - (g) Drain facts equivalence: pinned pre-split values

    func testDrainExitFactsMatchPinnedPreSplitValues() {
        // Word-level English lines spanning 0-44s of a 240s song: syllable
        // sync yes; 196s tail gap blows the 90s ceiling → timeline insane.
        let wordLevel = makeResult(
            source: .appleMusic, score: 75,
            lines: makeLines(Self.identitySeed, wordLevel: true)
        )
        XCTAssertEqual(
            fetcher.drainExitFacts(for: wordLevel, songDuration: 240),
            LyricsFetcher.DrainExitFacts(
                hasSyllableSyncedLine: true, lyricsContainCJK: false,
                isLikelyRomanizedCJK: false, hasSaneTimeline: false,
                strongNativeAliasIdentity: false, tightCatalogAliasIdentity: false
            )
        )

        // CJK lines spanning 0-198s of 240s: timeline sane, CJK detected.
        let cjk = makeResult(source: .netEase, score: 72, lines: makeLines(Self.cjkSeed, gap: 18))
        XCTAssertEqual(
            fetcher.drainExitFacts(for: cjk, songDuration: 240),
            LyricsFetcher.DrainExitFacts(
                hasSyllableSyncedLine: false, lyricsContainCJK: true,
                isLikelyRomanizedCJK: false, hasSaneTimeline: true,
                strongNativeAliasIdentity: false, tightCatalogAliasIdentity: false
            )
        )

        // The romanized-CJK check is profile-gated: the same pinyin lines
        // trip it on the LRCLIB pair but never on NetEase.
        let pinyinLRCLIB = makeResult(source: .lrclib, score: 55, lines: makeLines(Self.pinyinSeed))
        let pinyinNetEase = makeResult(source: .netEase, score: 55, lines: makeLines(Self.pinyinSeed))
        XCTAssertTrue(fetcher.drainExitFacts(for: pinyinLRCLIB, songDuration: 240).isLikelyRomanizedCJK)
        XCTAssertFalse(fetcher.drainExitFacts(for: pinyinNetEase, songDuration: 240).isLikelyRomanizedCJK)

        // Alias-identity ladder: strong needs synced + score >= 60 + diff < 3
        // WITHOUT title evidence; tight needs title evidence + score >= 30 +
        // diff < 0.35. One fixture each side, pinned from the raw helpers.
        let strongAlias = makeResult(
            source: .netEase, score: 72, lines: makeLines(Self.identitySeed, gap: 18),
            titleMatched: false, matchedDurationDiff: 0.4, nativeAliasMatched: true
        )
        let strongFacts = fetcher.drainExitFacts(for: strongAlias, songDuration: 240)
        XCTAssertTrue(strongFacts.strongNativeAliasIdentity)
        XCTAssertFalse(strongFacts.tightCatalogAliasIdentity)
        XCTAssertTrue(strongFacts.hasSaneTimeline)

        let tightAlias = makeResult(
            source: .qq, score: 35, lines: makeLines(Self.identitySeed, gap: 18),
            titleMatched: true, matchedDurationDiff: 0.2, nativeAliasMatched: true
        )
        let tightFacts = fetcher.drainExitFacts(for: tightAlias, songDuration: 240)
        XCTAssertTrue(tightFacts.tightCatalogAliasIdentity)
        XCTAssertFalse(tightFacts.strongNativeAliasIdentity)
    }

    // MARK: - (h) Drain facts memo must be keyed by song duration

    func testDrainExitFactsAreKeyedBySongDuration() {
        // First vocal at 50s: a 400s song allows a 90s intro (sane), a 100s
        // song allows only 45s (insane). A memo ignoring the duration key
        // would leak the first verdict into the second ask.
        let lateIntro = makeResult(
            source: .netEase, score: 60,
            lines: makeLines(Self.identitySeed, startingAt: 50, gap: 30)
        )
        XCTAssertTrue(fetcher.drainExitFacts(for: lateIntro, songDuration: 400).hasSaneTimeline)
        XCTAssertFalse(fetcher.drainExitFacts(for: lateIntro, songDuration: 100).hasSaneTimeline)
    }

    // MARK: - (i) selectReliable scorer terms compute once per result

    func testRepeatedSelectionAnalyzesRomajiAndQualityOncePerResult() {
        let pool = makeConsensusPool()
        let beforeRomaji = LyricsSelectionMemoProbe.romajiAnalyses
        let beforeQuality = LyricsSelectionMemoProbe.qualityAnalyses

        let first = fetcher.selectBestResult(from: pool, songDuration: 240)
        for _ in 0..<11 {
            let again = fetcher.selectBestResult(from: pool, songDuration: 240)
            XCTAssertEqual(again?.source, first?.source)
            XCTAssertEqual(again?.score, first?.score)
        }

        let romaji = LyricsSelectionMemoProbe.romajiAnalyses - beforeRomaji
        let quality = LyricsSelectionMemoProbe.qualityAnalyses - beforeQuality
        XCTAssertLessThanOrEqual(
            romaji, pool.count,
            "romaji analysis is pure per result — at most \(pool.count) passes across 12 selections, got \(romaji)"
        )
        XCTAssertLessThanOrEqual(
            quality, pool.count,
            "quality analysis is pure per result — at most \(pool.count) passes across 12 selections, got \(quality)"
        )
    }

    // MARK: - (j) 1-element pools ride the solo-verdict memo (chokepoint)

    func testSingleResultPoolSelectionRidesTheSoloVerdictMemo() {
        // Pin the pre-split outcomes first: a full selection over [r] can
        // only ever return r or nil, which is exactly the solo verdict.
        let accepted = makeResult(source: .netEase, score: 72, lines: makeLines(Self.identitySeed, gap: 18))
        let rejected = makeResult(source: .qq, score: 8, lines: makeLines(Self.identitySeed, gap: 18))
        XCTAssertEqual(fetcher.selectBestResult(from: [accepted], songDuration: 240)?.source, .netEase)
        XCTAssertNil(fetcher.selectBestResult(from: [rejected], songDuration: 240))

        // Re-asking warm 1-element pools must never run the full selection
        // body again — the solo-verdict memo is the single chokepoint.
        let before = LyricsSelectionMemoProbe.fullSelectionPasses
        for _ in 0..<12 {
            XCTAssertEqual(fetcher.selectBestResult(from: [accepted], songDuration: 240)?.source, .netEase)
            XCTAssertNil(fetcher.selectBestResult(from: [rejected], songDuration: 240))
        }
        let passes = LyricsSelectionMemoProbe.fullSelectionPasses - before
        XCTAssertEqual(
            passes, 0,
            "warm 1-element selections must be solo-verdict memo hits, got \(passes) full selection passes"
        )
    }
}
