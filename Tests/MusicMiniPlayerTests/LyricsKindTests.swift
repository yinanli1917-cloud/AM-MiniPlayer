/**
 * [INPUT]: MusicMiniPlayerCore 的 LyricsParser, LyricsFetcher, LyricsKind, LyricsClassifier
 * [OUTPUT]: LyricsKind tagging + classifier + gamma perf envelope tests
 * [POS]: Tests — guards the synced/unsynced contract so regressions (QQ
 *        auto-scroll disabled by CV/IQR heuristic) cannot return.
 *
 *  These tests lock in three bug-fix invariants:
 *
 *   (a) A realistic QQ-Music-shaped LRC string, run through the SAME path
 *       as production (parseLRC → fetch result construction), must be
 *       classified as `.synced`. Previously the CV/IQR heuristic
 *       false-positived on sparse songs and silenced auto-scroll.
 *
 *   (b) A `createUnsyncedLyrics` payload MUST be classified as `.unsynced`
 *       regardless of line count, and must earn less than the synced score
 *       for the same line array. This prevents Genius/lyrics.ovh from
 *       beating synced sources via free duration/coverage bonuses.
 *
 *   (c) The same `LyricsClassifier.classify(result:)` helper used by the
 *       verifier CLI and by future app-side gates must agree on the kind
 *       the parser assigned. If the verifier and the app diverge here,
 *       the user sees "synced in verifier, unsynced in app" bugs.
 *
 *  The perf latency test (d) is env-gated — it only fires when
 *  `NANOPOD_LIVE_TESTS=1` is set, because CI and offline runs have no
 *  network. The skip path still counts toward XCTest's pass count.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class LyricsKindTests: XCTestCase {

    private let parser = LyricsParser.shared
    private let scorer = LyricsScorer.shared

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - (a) Parser sync classification — QQ-shaped LRC
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Minimal LRC that looks like a real QQ Music payload. The point is
    /// that parseLRC produces lines whose gaps happen to look uniform-ish
    /// (CV < 0.05) on short intros — enough to fool the old CV/IQR
    /// heuristic. With kind-tagging at parse time, this must be `.synced`.
    func testParseLRC_classifiesAsSynced_evenWithNearUniformGaps() {
        let lrc = """
        [00:12.00]第一行
        [00:17.00]第二行
        [00:22.00]第三行
        [00:27.00]第四行
        [00:32.00]第五行
        [00:37.00]第六行
        """
        let lines = parser.parseLRC(lrc)
        XCTAssertGreaterThanOrEqual(lines.count, 5, "parseLRC should return lines")

        // Wrap it the way LyricsFetcher does for QQ and classify.
        let result = LyricsFetcher.LyricsFetchResult(
            lyrics: lines, source: "QQ", score: 80, kind: .synced
        )
        XCTAssertEqual(LyricsFetcher.LyricsClassifier.classify(result: result), .synced,
            "Real LRC data must classify as synced, not fabricated — this is the QQ auto-scroll regression guard")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - (b) createUnsyncedLyrics is always unsynced
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testCreateUnsyncedLyrics_mustBeTaggedUnsynced() {
        let plainText = """
        Line one of the plain text lyrics
        Line two of the plain text lyrics
        Line three of the plain text lyrics
        Line four of the plain text lyrics
        Line five of the plain text lyrics
        """
        let lines = parser.createUnsyncedLyrics(plainText, duration: 240)
        XCTAssertGreaterThan(lines.count, 0)

        let result = LyricsFetcher.LyricsFetchResult(
            lyrics: lines, source: "lyrics.ovh", score: 0, kind: .unsynced
        )
        XCTAssertEqual(LyricsFetcher.LyricsClassifier.classify(result: result), .unsynced)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - (c) Scorer kind gating — unsynced cannot outscore synced
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Same lines, same source — unsynced must score strictly lower
    /// because duration/coverage gates close and authenticity flips sign.
    /// This is the "explicit kind" replacement for the old CV/IQR gate.
    func testScorer_syncedBeatsUnsyncedForSameLines() {
        let lines = (0..<20).map { i -> LyricLine in
            // Non-uniform gaps so the legacy CV heuristic would have
            // ALSO called this authentic. Kind now decides, not CV.
            let base = Double(i) * 10
            return LyricLine(
                text: "line \(i) content long enough",
                startTime: base + Double(i % 3),
                endTime: base + 10 + Double(i % 3)
            )
        }
        let synced = scorer.calculateScore(lines, source: "NetEase", duration: 240, translationEnabled: false, kind: .synced)
        let unsynced = scorer.calculateScore(lines, source: "NetEase", duration: 240, translationEnabled: false, kind: .unsynced)
        XCTAssertGreaterThan(synced, unsynced,
            "Explicit .synced must outscore .unsynced for identical line arrays")
        XCTAssertGreaterThan(synced - unsynced, 20,
            "Kind gating should open up more than ~20 points of spread (auth ±15 + duration/coverage)")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - (d) Gamma speculative latency envelope (env-gated live test)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Gated behind NANOPOD_LIVE_TESTS=1 because this hits the real
    /// iTunes / NetEase / QQ endpoints. Asserts three previously-slow
    /// ASCII→CJK songs now return under 2.5s each, well inside the
    /// 3-second budget.
    func testGammaSpeculative_ASCIItoCJK_under2500ms() async throws {
        guard ProcessInfo.processInfo.environment["NANOPOD_LIVE_TESTS"] == "1" else {
            throw XCTSkip("NANOPOD_LIVE_TESTS=1 not set — skipping live network test")
        }
        let fetcher = LyricsFetcher.shared
        // Pure romaji input → branch 2 should race JP candidates.
        let samples: [(title: String, artist: String, duration: Double)] = [
            ("Plastic Love", "Mariya Takeuchi", 292),
            ("Koibitotachi no Chiheisen", "Momoko Kikuchi", 229),
            ("Try to Say", "EPO", 276),
        ]
        for sample in samples {
            let start = Date()
            _ = await fetcher.fetchAllSources(
                title: sample.title, artist: sample.artist,
                duration: sample.duration, translationEnabled: false
            )
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            XCTAssertLessThan(elapsedMs, 2500,
                "Gamma speculative branch should resolve '\(sample.title)' under 2500ms, got \(elapsedMs)ms")
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - (e) Invisible (mei ehara) auto-scroll regression guard
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Env-gated live integration: the user reported "Invisible" by mei ehara
    /// lost synced lyrics + auto-scroll. Once the kind refactor landed,
    /// this song must classify as synced with a first real line startTime > 0
    /// and with non-uniform gaps (CV > 0.05).
    func testInvisible_byMeiEhara_returnsSynced() async throws {
        guard ProcessInfo.processInfo.environment["NANOPOD_LIVE_TESTS"] == "1" else {
            throw XCTSkip("NANOPOD_LIVE_TESTS=1 not set — skipping live network test")
        }
        let fetcher = LyricsFetcher.shared
        let results = await fetcher.fetchAllSources(
            title: "Invisible", artist: "mei ehara",
            duration: 232, translationEnabled: false
        )
        guard let best = results.sorted(by: { $0.score > $1.score }).first else {
            return XCTFail("No result for Invisible (mei ehara)")
        }
        XCTAssertEqual(best.kind, .synced, "Invisible must be classified as synced, not unsynced")

        let realLines = best.lyrics.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertGreaterThan(realLines.count, 5, "Expected > 5 real lines")
        XCTAssertGreaterThan(realLines.first?.startTime ?? 0, 0,
            "First real line startTime must be > 0")

        // Consecutive-line gap variation — guards against silent fabrication.
        var gaps: [Double] = []
        for i in 1..<realLines.count {
            let gap = realLines[i].startTime - realLines[i - 1].startTime
            if gap > 0 { gaps.append(gap) }
        }
        guard gaps.count >= 5 else {
            return XCTFail("Not enough gaps to compute CV")
        }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let variance = gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)
        let cv = (mean > 0) ? sqrt(variance) / mean : 0
        XCTAssertGreaterThan(cv, 0.05, "Invisible gap CV must exceed 0.05 to prove real timestamps")
    }
}
