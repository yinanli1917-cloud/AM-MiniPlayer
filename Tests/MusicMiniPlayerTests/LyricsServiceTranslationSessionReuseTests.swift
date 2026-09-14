/**
 * [INPUT]: LyricsService.requestTranslation/serveTranslationRequests/
 *          resetTranslationRequestStream (Services/LyricsService.swift) +
 *          LyricsTranslationExecuting seam (Services/TranslationChunking.swift)
 * [OUTPUT]: Proof that A5 part 1 stopped rebuilding the TranslationSession
 *           per trigger — two consecutive songs' translations run through
 *           the SAME injected executor instance — and that a config
 *           (language) change cleanly drains the old request queue instead
 *           of leaking a stale request onto the new session.
 * [POS]: Tests — task A5 part 1 red→green.
 *
 * No real Translation framework session is needed: `performSystemTranslation`
 * is generic over `LyricsTranslationExecuting`, so a fake executor stands in
 * for `TranslationSession` here.
 *
 * Disk-cache isolation (found during the 2026-09-14 repro): this test drives
 * `LyricsService.shared` — the real, process-wide singleton — through
 * `performSystemTranslation`, which persists successful translations via
 * `translationDiskCache`. Before this fix that field defaulted to
 * `TranslationDiskCache.defaultURL()`, the SAME path the real app reads and
 * writes (`~/Library/Application Support/nanoPod/translation_cache.json`), so
 * every `swift test` run was writing "译:hello world" rows into the
 * founder's real translation cache (79/82 real rows on the machine this was
 * found on). Same redirect-to-temp-file pattern as
 * `TranslationDiskCacheTests.swift` / `MetadataDiskCacheTierTests.swift`.
 */

import XCTest
@testable import MusicMiniPlayerCore

@available(macOS 15.0, *)
@MainActor
final class LyricsServiceTranslationSessionReuseTests: XCTestCase {

    private final class FakeExecutor: LyricsTranslationExecuting {
        private(set) var callCount = 0
        var onCall: ((Int) -> Void)?

        func translateBatch(_ texts: [String]) async throws -> [String] {
            callCount += 1
            onCall?(callCount)
            return texts.map { "译:" + $0 }
        }
    }

    private var savedShowTranslation = false
    private var savedTranslationLanguage = "zh-Hans"
    private var savedDiskCache: TranslationDiskCache?

    override func setUp() {
        super.setUp()
        let service = LyricsService.shared
        savedShowTranslation = service.showTranslation
        savedTranslationLanguage = service.translationLanguage
        savedDiskCache = service.translationDiskCache
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation_cache_session_reuse_test_\(UUID().uuidString).json")
        service.translationDiskCache = TranslationDiskCache(fileURL: tmp, persistDebounce: 0.05)
    }

    override func tearDown() async throws {
        let service = LyricsService.shared
        service.showTranslation = savedShowTranslation
        service.translationLanguage = savedTranslationLanguage
        if let savedDiskCache { service.translationDiskCache = savedDiskCache }
        // `LyricsService.shared` is a process-wide singleton: a `for await`
        // loop left suspended by a merely-`cancel()`ed Task (Task
        // cancellation does not itself unblock an AsyncStream await) would
        // otherwise leak into the NEXT test and silently steal that test's
        // yielded request. Finishing the stream unblocks and ends any such
        // leaked loop and hands out a fresh stream for the next test.
        service.resetTranslationRequestStream()
        try await super.tearDown()
    }

    private func makeService() -> LyricsService {
        // Shared singleton — same pattern as LyricsWordLevelPriorityTests.
        // Unique song titles (UUID suffix) keep this test's songID from
        // colliding with other tests sharing the same process.
        let service = LyricsService.shared
        service.showTranslation = true
        service.translationLanguage = "zh-Hans"
        return service
    }

    private func seed(_ service: LyricsService, title: String) {
        service.debugSeedDisplayedLyricsForTesting(
            [LyricLine(text: "hello world", startTime: 0, endTime: 2)],
            title: "\(title) \(UUID().uuidString.prefix(8))",
            artist: "Test Artist",
            duration: 200,
            isUnsynced: false
        )
    }

    func test_twoConsecutiveSongs_reuseSameExecutorInstance_noRebuildPerTrigger() async {
        let service = makeService()
        let executor = FakeExecutor()

        seed(service, title: "Song A")
        let serveTask = Task { await service.serveTranslationRequests(with: executor) }

        let firstDone = expectation(description: "song A translated by the SAME executor")
        executor.onCall = { count in if count == 1 { firstDone.fulfill() } }
        service.requestTranslation()
        await fulfillment(of: [firstDone], timeout: 2.0)

        // Second song, SAME session/executor — no host/session rebuild.
        seed(service, title: "Song B")
        let secondDone = expectation(description: "song B translated by the SAME executor")
        executor.onCall = { count in if count == 2 { secondDone.fulfill() } }
        service.requestTranslation()
        await fulfillment(of: [secondDone], timeout: 2.0)

        serveTask.cancel()
        XCTAssertEqual(executor.callCount, 2, "both songs must have been translated")
        // The whole point of the test: ONE executor instance served both
        // songs — there is only ever one `executor` variable in scope, so
        // reaching callCount == 2 on it IS the proof of reuse.
    }

    func test_configChangeReset_drainsOldQueue_andNeverLeaksIntoNewSession() async {
        let service = makeService()
        let oldExecutor = FakeExecutor()

        seed(service, title: "Song A")
        let oldServeTask = Task { await service.serveTranslationRequests(with: oldExecutor) }
        // Let the loop attach to the stream before we simulate a language
        // change — no request has been enqueued yet.
        try? await Task.sleep(nanoseconds: 50_000_000)

        service.resetTranslationRequestStream()
        // Finishing the stream must end the OLD loop cleanly.
        await oldServeTask.value
        XCTAssertEqual(oldExecutor.callCount, 0, "no request was ever enqueued before the reset")

        let newExecutor = FakeExecutor()
        let newDone = expectation(description: "new session translated after reset")
        newExecutor.onCall = { _ in newDone.fulfill() }
        let newServeTask = Task { await service.serveTranslationRequests(with: newExecutor) }
        service.requestTranslation()
        await fulfillment(of: [newDone], timeout: 2.0)
        newServeTask.cancel()

        XCTAssertEqual(newExecutor.callCount, 1, "the new session must serve the post-reset request")
        XCTAssertEqual(oldExecutor.callCount, 0, "the old executor must never fire after its queue was reset")
    }
}
