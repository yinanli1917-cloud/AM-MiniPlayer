/**
 * [INPUT]: MetadataWarmupSweep (all seams injected — zero network, zero
 *          UserDefaults, zero singletons)
 * [OUTPUT]: Warm-up sweep contract proofs — once per schema version,
 *           row-present skip, foreground yield, whole-sweep cancellation
 * [POS]: Regression tests for the launch metadata warm-up (latency review,
 *        post-round-2 item A)
 */

import XCTest
@testable import MusicMiniPlayerCore

// ============================================================
// MARK: - Recorder (lock-guarded seam state)
// ============================================================

/// Captures what the sweep did. Lock-guarded: seam closures run on the
/// sweep task while tests read from the test task.
private final class SweepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _resolvedTitles: [String] = []
    private var _storedVersion: Int?
    private var _foregroundActive = false
    private var _warmTitles: Set<String> = []

    var resolvedTitles: [String] {
        lock.lock(); defer { lock.unlock() }
        return _resolvedTitles
    }
    var storedVersion: Int? {
        lock.lock(); defer { lock.unlock() }
        return _storedVersion
    }
    var foregroundActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _foregroundActive }
        set { lock.lock(); _foregroundActive = newValue; lock.unlock() }
    }
    var warmTitles: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _warmTitles }
        set { lock.lock(); _warmTitles = newValue; lock.unlock() }
    }

    func recordResolve(_ title: String) {
        lock.lock(); _resolvedTitles.append(title); lock.unlock()
    }
    func recordVersion(_ version: Int) {
        lock.lock(); _storedVersion = version; lock.unlock()
    }
}

/// One-shot async latch (same shape as the resolver single-flight tests):
/// lets a test hold the first resolution open until it has acted.
private actor SweepLatch {
    private(set) var entries = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entries += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

// ============================================================
// MARK: - MetadataWarmupTests
// ============================================================

final class MetadataWarmupTests: XCTestCase {

    private let fastConfig: MetadataWarmupSweep.Configuration = {
        var config = MetadataWarmupSweep.Configuration()
        config.interTrackDelay = 0.01
        config.trackListPollInterval = 0.01
        config.trackListPollAttempts = 3
        config.schemaVersion = 42
        return config
    }()

    private func track(_ n: Int) -> MetadataWarmupTrack {
        MetadataWarmupTrack(title: "Song \(n)", artist: "Artist \(n)", duration: 200 + Double(n))
    }

    private func makeSweep(
        tracks: [MetadataWarmupTrack],
        recorder: SweepRecorder,
        resolveBody: (@Sendable (MetadataWarmupTrack) async -> Void)? = nil
    ) -> MetadataWarmupSweep {
        MetadataWarmupSweep(
            configuration: fastConfig,
            tracksProvider: { tracks },
            hasWarmRows: { recorder.warmTitles.contains($0.title) },
            resolve: { track in
                recorder.recordResolve(track.title)
                await resolveBody?(track)
            },
            isForegroundFetchActive: { recorder.foregroundActive },
            lastWarmedVersion: { recorder.storedVersion },
            storeWarmedVersion: { recorder.recordVersion($0) }
        )
    }

    // MARK: - Once per schema version

    @MainActor
    func testSweepRunsOncePerSchemaVersion() async {
        let recorder = SweepRecorder()
        let sweep = makeSweep(tracks: [track(1), track(2)], recorder: recorder)

        let task = sweep.startIfNeeded()
        XCTAssertNotNil(task, "first sweep for an unwarmed schema version must start")
        await task?.value

        XCTAssertEqual(recorder.resolvedTitles, ["Song 1", "Song 2"])
        XCTAssertEqual(recorder.storedVersion, 42, "completion must stamp the warmed schema version")

        // Same version store → a second sweep must be a no-op.
        let second = makeSweep(tracks: [track(1), track(2)], recorder: recorder)
        let secondTask = second.startIfNeeded()
        XCTAssertNil(secondTask, "already-warmed schema version must not start a sweep")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.resolvedTitles.count, 2, "no further resolutions after the stamp")
    }

    @MainActor
    func testIncompleteTrackListDoesNotStampVersion() async {
        let recorder = SweepRecorder()
        let sweep = makeSweep(tracks: [], recorder: recorder)

        let task = sweep.startIfNeeded()
        XCTAssertNotNil(task)
        await task?.value

        XCTAssertTrue(recorder.resolvedTitles.isEmpty)
        XCTAssertNil(
            recorder.storedVersion,
            "an empty snapshot must NOT stamp — the next launch retries the warm-up"
        )
    }

    // MARK: - Row-present skip

    @MainActor
    func testTracksWithWarmRowsAreSkippedWithoutResolution() async {
        let recorder = SweepRecorder()
        recorder.warmTitles = ["Song 2"]
        let sweep = makeSweep(tracks: [track(1), track(2), track(3)], recorder: recorder)

        await sweep.startIfNeeded()?.value

        XCTAssertEqual(
            recorder.resolvedTitles, ["Song 1", "Song 3"],
            "a track whose rows are already on disk must skip the resolver consult entirely"
        )
        XCTAssertEqual(recorder.storedVersion, 42)
    }

    @MainActor
    func testDuplicateAndOverflowTracksAreBounded() async {
        let recorder = SweepRecorder()
        var config = fastConfig
        config.maxTracks = 3
        let tracks = [track(1), track(1), track(2), track(3), track(4)]
        let sweep = MetadataWarmupSweep(
            configuration: config,
            tracksProvider: { tracks },
            hasWarmRows: { _ in false },
            resolve: { recorder.recordResolve($0.title) },
            isForegroundFetchActive: { false },
            lastWarmedVersion: { recorder.storedVersion },
            storeWarmedVersion: { recorder.recordVersion($0) }
        )

        await sweep.startIfNeeded()?.value

        XCTAssertEqual(
            recorder.resolvedTitles, ["Song 1", "Song 2", "Song 3"],
            "duplicates dedupe by identity and the cap bounds the sweep"
        )
    }

    // MARK: - Yield to foreground

    @MainActor
    func testSweepPausesWhileForegroundFetchIsActive() async {
        let recorder = SweepRecorder()
        recorder.foregroundActive = true
        let sweep = makeSweep(tracks: [track(1)], recorder: recorder)

        let task = sweep.startIfNeeded()
        XCTAssertNotNil(task)

        // Several yield-poll cycles pass — the sweep must not consult while
        // a foreground lyrics fetch is running.
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(
            recorder.resolvedTitles.isEmpty,
            "sweep must pause while the foreground fetch is active"
        )

        recorder.foregroundActive = false
        await task?.value
        XCTAssertEqual(recorder.resolvedTitles, ["Song 1"], "sweep resumes after the foreground fetch ends")
        XCTAssertEqual(recorder.storedVersion, 42)
    }

    // MARK: - Cancellation

    @MainActor
    func testCancellationStopsSweepWithoutStamping() async {
        let recorder = SweepRecorder()
        let latch = SweepLatch()
        let sweep = makeSweep(
            tracks: (1...5).map { track($0) },
            recorder: recorder,
            resolveBody: { _ in await latch.enterAndWait() }
        )

        let task = sweep.startIfNeeded()
        XCTAssertNotNil(task)

        // Wait for the first resolution to begin, cancel the WHOLE sweep,
        // then release the in-flight resolution.
        let deadline = Date().addingTimeInterval(5)
        while await latch.entries < 1, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        sweep.cancel()
        await latch.open()
        await task?.value

        XCTAssertEqual(recorder.resolvedTitles, ["Song 1"], "no further tracks after cancellation")
        XCTAssertNil(recorder.storedVersion, "a cancelled sweep must NOT stamp the schema version")
    }
}
