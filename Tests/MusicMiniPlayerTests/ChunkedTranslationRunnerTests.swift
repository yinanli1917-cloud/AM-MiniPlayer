/**
 * [INPUT]: MusicMiniPlayerCore ChunkedTranslationRunner + LyricsTranslationExecuting
 * [OUTPUT]: Chunked incremental translation + per-chunk timeout tests, using
 *           an injected fake translator (no real Translation framework).
 * [POS]: Test module (task A5, 2026-09) — pins audit fact (c): a single
 *        all-or-nothing batch with no timeout must become bounded chunks
 *        that publish independently.
 */

import XCTest
@testable import MusicMiniPlayerCore

private actor CallCounter {
    private(set) var count = 0
    func increment() -> Int {
        count += 1
        return count
    }
}

private final class FakeExecutor: LyricsTranslationExecuting {
    enum Behavior {
        case echo
        case stall(TimeInterval)
        case fail
    }
    var behaviorForChunk: (Int) -> Behavior
    private let counter = CallCounter()
    var callCount: Int {
        get async { await counter.count }
    }

    init(behaviorForChunk: @escaping (Int) -> Behavior = { _ in .echo }) {
        self.behaviorForChunk = behaviorForChunk
    }

    func translateBatch(_ texts: [String]) async throws -> [String] {
        let thisCall = await counter.increment()
        switch behaviorForChunk(thisCall - 1) {
        case .echo:
            return texts.map { "T:\($0)" }
        case .stall(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return texts.map { "T:\($0)" }
        case .fail:
            struct Boom: Error {}
            throw Boom()
        }
    }
}

final class ChunkedTranslationRunnerTests: XCTestCase {

    func test_singleChunk_publishesOnce() async {
        let executor = FakeExecutor()
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.run(
            lines: ["a", "b", "c"],
            chunkSize: 25,
            chunkTimeout: 2,
            executor: executor
        ) { publishes.append($0) }

        XCTAssertEqual(publishes.count, 1)
        XCTAssertEqual(publishes[0][0], "T:a")
        XCTAssertEqual(publishes[0][2], "T:c")
    }

    func test_threeChunks_publishesThreeTimes() async {
        let executor = FakeExecutor()
        var publishes: [[Int: String]] = []
        let lines = (0..<7).map { "line\($0)" } // chunkSize 3 -> chunks of 3,3,1
        await ChunkedTranslationRunner.run(
            lines: lines,
            chunkSize: 3,
            chunkTimeout: 2,
            executor: executor
        ) { publishes.append($0) }

        XCTAssertEqual(publishes.count, 3, "a 3-chunk song must publish exactly 3 times, one @Published merge per chunk")
        // indices preserved across chunk boundaries
        XCTAssertEqual(publishes[0][0], "T:line0")
        XCTAssertEqual(publishes[1][3], "T:line3")
        XCTAssertEqual(publishes[2][6], "T:line6")
    }

    func test_stuckChunk_timesOutAndOtherChunksStillLand() async {
        // Chunk 0 stalls forever (well past the timeout); chunk 1 must still
        // land. This is the audit-fact-(c) fix: "a stuck model spins forever".
        let executor = FakeExecutor(behaviorForChunk: { index in
            index == 0 ? .stall(5.0) : .echo
        })
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.run(
            lines: ["a", "b", "c", "d"],
            chunkSize: 2,
            chunkTimeout: 0.1,
            executor: executor
        ) { publishes.append($0) }

        XCTAssertEqual(publishes.count, 1, "the stuck chunk must fail silently and NOT publish")
        XCTAssertEqual(publishes.first?[2], "T:c")
        XCTAssertEqual(publishes.first?[3], "T:d")
    }

    func test_failingChunk_isSkippedSilently_othersStillLand() async {
        let executor = FakeExecutor(behaviorForChunk: { index in index == 1 ? .fail : .echo })
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.run(
            lines: ["a", "b", "c"],
            chunkSize: 1,
            chunkTimeout: 1,
            executor: executor
        ) { publishes.append($0) }

        XCTAssertEqual(publishes.count, 2)
        XCTAssertEqual(publishes[0][0], "T:a")
        XCTAssertEqual(publishes[1][2], "T:c")
    }

    func test_totalFailure_leavesOriginalUntouched_noPublishAtAll() async {
        let executor = FakeExecutor(behaviorForChunk: { _ in .fail })
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.run(
            lines: ["a", "b"],
            chunkSize: 25,
            chunkTimeout: 1,
            executor: executor
        ) { publishes.append($0) }

        XCTAssertTrue(publishes.isEmpty, "A rule: total failure must leave the original untouched — zero publishes")
    }

    func test_emptyInput_neverCallsExecutor() async {
        let executor = FakeExecutor()
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.run(lines: [], executor: executor) { publishes.append($0) }
        XCTAssertEqual(publishes.count, 0)
        let calls = await executor.callCount
        XCTAssertEqual(calls, 0)
    }
}

// ============================================================================
// MARK: - runMultiScript (mixed Hangul+Latin lines, 2026-09-20 evidence)
// ============================================================================

private final class TaggingExecutor: LyricsTranslationExecuting {
    let tag: String
    init(tag: String) { self.tag = tag }
    func translateBatch(_ texts: [String]) async throws -> [String] {
        texts.map { "[\(tag)]\($0)" }
    }
}

final class ChunkedTranslationRunnerMultiScriptTests: XCTestCase {

    func test_singleRunLines_takeTheSamePathAsRun_neverTouchKoExecutor() async {
        let defaultExecutor = FakeExecutor()
        let koExecutor = TaggingExecutor(tag: "ko")
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.runMultiScript(
            lines: ["hello there", "goodbye now"],
            defaultExecutor: defaultExecutor,
            executorsByLanguage: ["ko": koExecutor]
        ) { publishes.append($0) }

        XCTAssertEqual(publishes.count, 1)
        XCTAssertEqual(publishes[0][0], "T:hello there")
        XCTAssertEqual(publishes[0][1], "T:goodbye now")
    }

    func test_mixedKoreanLatinLine_routesKoreanRunToKoExecutor_andReassembles() async {
        // Mirrors the evidence line: "더는 안 봐 drama it's good karma"
        let defaultExecutor = TaggingExecutor(tag: "auto")
        let koExecutor = TaggingExecutor(tag: "ko")
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.runMultiScript(
            lines: ["더는 안 봐 drama it's good karma"],
            defaultExecutor: defaultExecutor,
            executorsByLanguage: ["ko": koExecutor]
        ) { publishes.append($0) }

        let merged = publishes.reduce(into: [Int: String]()) { acc, chunk in acc.merge(chunk) { _, new in new } }
        XCTAssertEqual(merged[0], "[ko]더는 안 봐 [auto]drama it's good karma")
    }

    func test_noKoExecutorRegistered_koreanRunFallsBackToDefault() async {
        // Graceful degradation: before the second session has warmed
        // (or on macOS < 15), the whole line still comes back translated
        // via auto-detect on each run, never silently dropped.
        let defaultExecutor = TaggingExecutor(tag: "auto")
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.runMultiScript(
            lines: ["그만해 cus it's clear"],
            defaultExecutor: defaultExecutor,
            executorsByLanguage: [:]
        ) { publishes.append($0) }

        let merged = publishes.reduce(into: [Int: String]()) { acc, chunk in acc.merge(chunk) { _, new in new } }
        XCTAssertEqual(merged[0], "[auto]그만해 [auto]cus it's clear")
    }

    func test_singleAndMultiRunLinesTogether_bothLand() async {
        let defaultExecutor = TaggingExecutor(tag: "auto")
        let koExecutor = TaggingExecutor(tag: "ko")
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.runMultiScript(
            lines: ["pure english line", "모든 게 typical"],
            defaultExecutor: defaultExecutor,
            executorsByLanguage: ["ko": koExecutor]
        ) { publishes.append($0) }

        let merged = publishes.reduce(into: [Int: String]()) { acc, chunk in acc.merge(chunk) { _, new in new } }
        XCTAssertEqual(merged[0], "[auto]pure english line")
        XCTAssertEqual(merged[1], "[ko]모든 게 [auto]typical")
    }

    func test_emptyInput_publishesNothing() async {
        let defaultExecutor = FakeExecutor()
        var publishes: [[Int: String]] = []
        await ChunkedTranslationRunner.runMultiScript(
            lines: [],
            defaultExecutor: defaultExecutor
        ) { publishes.append($0) }
        XCTAssertTrue(publishes.isEmpty)
    }
}
