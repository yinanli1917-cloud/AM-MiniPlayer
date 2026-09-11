//
//  AppleMusicPlaybackSourceTests.swift
//  Covers the E1 playback-source protocol layer, step 1:
//    - NowPlayingSnapshot mapping from MusicController @Published state
//    - PlaybackSourceEvent stream (dedup, queue change, availability)
//    - Control forwarding to a fake AppleMusicControlSink
//    - PlaybackSourceRegistry default-fallback + persistence
//

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// MARK: - Fake sink

private final class FakeAppleMusicControlSink: AppleMusicControlSink {
    let controller: MusicController
    var togglePlayPauseCalls = 0
    var nextTrackCalls = 0
    var previousTrackCalls = 0
    var seekCalls: [Double] = []
    var toggleShuffleCalls = 0
    var cycleRepeatModeCalls = 0
    var setVolumeCalls: [Int] = []
    var toggleStarCalls = 0
    var playTrackCalls: [String] = []
    var fetchUpNextQueueCalls: [Bool] = []

    init(controller: MusicController) {
        self.controller = controller
    }

    func togglePlayPause() { togglePlayPauseCalls += 1 }
    func nextTrack() { nextTrackCalls += 1 }
    func previousTrack() { previousTrackCalls += 1 }
    func seek(to position: Double) { seekCalls.append(position) }
    func toggleShuffle() { toggleShuffleCalls += 1 }

    /// Mirrors the real MusicController: advancing repeat mode cycles 0 -> 1 -> 2 -> 0.
    func cycleRepeatMode() {
        cycleRepeatModeCalls += 1
        controller.repeatMode = (controller.repeatMode + 1) % 3
    }

    func setVolume(_ level: Int) { setVolumeCalls.append(level) }
    func toggleStar() { toggleStarCalls += 1 }
    func playTrack(persistentID: String) { playTrackCalls.append(persistentID) }
    func fetchUpNextQueue(forceRecent: Bool) { fetchUpNextQueueCalls.append(forceRecent) }
}

@MainActor
final class AppleMusicPlaybackSourceTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Snapshot mapping
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_readSnapshot_mapsControllerFields() async {
        let mc = MusicController(preview: true)
        mc.currentTrackTitle = "Song Title"
        mc.currentArtist = "Artist"
        mc.currentAlbum = "Album"
        mc.duration = 245
        mc.currentPersistentID = "ABCD1234"
        mc.isPlaying = true
        mc.shuffleEnabled = true
        mc.repeatMode = 1

        let source = AppleMusicPlaybackSource(controller: mc)
        let snapshot = await source.readSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.identity?.title, "Song Title")
        XCTAssertEqual(snapshot?.identity?.artist, "Artist")
        XCTAssertEqual(snapshot?.identity?.album, "Album")
        XCTAssertEqual(snapshot?.identity?.duration, 245)
        XCTAssertEqual(snapshot?.identity?.nativeID, "ABCD1234")
        XCTAssertEqual(snapshot?.identity?.stableKey, "appleMusic:ABCD1234")
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.shuffle, true)
        XCTAssertEqual(snapshot?.repeatMode, 1)
    }

    func test_readSnapshot_nilPersistentID_stableKeyUsesMetaForm() async {
        let mc = MusicController(preview: true)
        mc.currentTrackTitle = "Radio Song"
        mc.currentArtist = "Radio Artist"
        mc.currentAlbum = "Radio Album"
        mc.currentPersistentID = nil

        let source = AppleMusicPlaybackSource(controller: mc)
        let snapshot = await source.readSnapshot()

        XCTAssertEqual(snapshot?.identity?.stableKey, "appleMusic:meta:Radio Song|Radio Artist|Radio Album")
    }

    func test_readSnapshot_notPlayingSentinel_identityIsNil() async {
        let mc = MusicController(preview: true)
        mc.currentTrackTitle = kNotPlayingSentinel

        let source = AppleMusicPlaybackSource(controller: mc)
        let snapshot = await source.readSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.identity)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Events
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_events_trackTitleChange_emitsOneSnapshot() async {
        let mc = MusicController(preview: true)
        mc.currentTrackTitle = "First"
        let source = AppleMusicPlaybackSource(controller: mc)
        source.start()
        defer { source.stop() }

        var receivedTitles: [String?] = []
        let task = Task {
            for await event in source.events {
                if case let .snapshot(snapshot) = event {
                    receivedTitles.append(snapshot.identity?.title)
                }
            }
        }

        // Let the stream's initial buffered state settle before mutating.
        try? await Task.sleep(nanoseconds: 50_000_000)
        mc.currentTrackTitle = "Second"
        try? await Task.sleep(nanoseconds: 300_000_000)

        task.cancel()
        XCTAssertTrue(receivedTitles.contains("Second"), "expected a snapshot event carrying the new title; got \(receivedTitles)")
    }

    func test_events_repeatedIdenticalAssignment_doesNotDuplicate() async {
        let mc = MusicController(preview: true)
        mc.currentTrackTitle = "Same Song"
        mc.currentArtist = "Same Artist"
        let source = AppleMusicPlaybackSource(controller: mc)
        source.start()
        defer { source.stop() }

        var receivedCount = 0
        let task = Task {
            for await event in source.events {
                if case .snapshot = event {
                    receivedCount += 1
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        // Re-assigning the same value should not fire a new @Published event
        // at all (Combine's @Published already skips no-op assignment via
        // equality... but guard the content-dedupe path anyway).
        mc.currentArtist = "Same Artist"
        mc.currentArtist = "Same Artist"
        try? await Task.sleep(nanoseconds: 200_000_000)

        task.cancel()
        XCTAssertLessThanOrEqual(receivedCount, 1, "identical re-assignment must not flood duplicate snapshot events")
    }

    func test_events_queueChange_emitsQueueChanged() async {
        let mc = MusicController(preview: true)
        let source = AppleMusicPlaybackSource(controller: mc)
        source.start()
        defer { source.stop() }

        let expectation = expectation(description: "queue changed event")
        let task = Task {
            for await event in source.events {
                if case .queueChanged = event {
                    expectation.fulfill()
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        mc.upNextTracks = [(title: "Next Song", artist: "Next Artist", album: "Next Album", persistentID: "XYZ", duration: 200)]

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }

    func test_events_connectionErrorSetThenCleared_emitsTwoAvailabilityEvents() async {
        let mc = MusicController(preview: true)
        let source = AppleMusicPlaybackSource(controller: mc)
        source.start()
        defer { source.stop() }

        var availabilities: [PlaybackSourceAvailability] = []
        let expectation = expectation(description: "two availability events")
        let task = Task {
            for await event in source.events {
                if case let .availability(availability) = event {
                    availabilities.append(availability)
                    if availabilities.count >= 2 {
                        expectation.fulfill()
                        break
                    }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        mc.connectionError = "Music.app unreachable"
        try? await Task.sleep(nanoseconds: 100_000_000)
        mc.connectionError = nil

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(availabilities.count, 2)
        if case .unreachable = availabilities[0] {} else { XCTFail("expected .unreachable first, got \(availabilities[0])") }
        XCTAssertEqual(availabilities[1], .available)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Control forwarding
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_controls_forwardToSink() async {
        let mc = MusicController(preview: true)
        let fakeSink = FakeAppleMusicControlSink(controller: mc)
        let source = AppleMusicPlaybackSource(controller: mc, sink: fakeSink)

        await source.togglePlayPause()
        await source.next()
        await source.previous()
        await source.seek(to: 42.5)
        await source.setVolume(70)
        await source.toggleFavorite()
        await source.play(itemID: "PID999")

        XCTAssertEqual(fakeSink.togglePlayPauseCalls, 1)
        XCTAssertEqual(fakeSink.nextTrackCalls, 1)
        XCTAssertEqual(fakeSink.previousTrackCalls, 1)
        XCTAssertEqual(fakeSink.seekCalls, [42.5])
        XCTAssertEqual(fakeSink.setVolumeCalls, [70])
        XCTAssertEqual(fakeSink.toggleStarCalls, 1)
        XCTAssertEqual(fakeSink.playTrackCalls, ["PID999"])
    }

    func test_setShuffle_sameValue_doesNotCallToggle() async {
        let mc = MusicController(preview: true)
        mc.shuffleEnabled = true
        let fakeSink = FakeAppleMusicControlSink(controller: mc)
        let source = AppleMusicPlaybackSource(controller: mc, sink: fakeSink)

        await source.setShuffle(true)
        XCTAssertEqual(fakeSink.toggleShuffleCalls, 0)

        await source.setShuffle(false)
        XCTAssertEqual(fakeSink.toggleShuffleCalls, 1)
    }

    func test_setRepeatMode_cyclesFromZeroToTwo() async {
        let mc = MusicController(preview: true)
        mc.repeatMode = 0
        let fakeSink = FakeAppleMusicControlSink(controller: mc)
        let source = AppleMusicPlaybackSource(controller: mc, sink: fakeSink)

        await source.setRepeatMode(2)

        XCTAssertEqual(fakeSink.cycleRepeatModeCalls, 2)
        XCTAssertEqual(mc.repeatMode, 2)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Registry
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_registry_unknownDefaultsValue_fallsBackToAppleMusic() {
        let suiteName = "AppleMusicPlaybackSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("someUnknownSource", forKey: PlaybackSourceRegistry.defaultsKey)
        let registry = PlaybackSourceRegistry(defaults: defaults)
        XCTAssertEqual(registry.activeSourceID, .appleMusic)
    }

    func test_registry_absentDefaultsValue_fallsBackToAppleMusic() {
        let suiteName = "AppleMusicPlaybackSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = PlaybackSourceRegistry(defaults: defaults)
        XCTAssertEqual(registry.activeSourceID, .appleMusic)
    }

    func test_registry_select_persistsToDefaults() {
        let suiteName = "AppleMusicPlaybackSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = PlaybackSourceRegistry(defaults: defaults)
        registry.select(.appleMusic)

        XCTAssertEqual(defaults.string(forKey: PlaybackSourceRegistry.defaultsKey), "appleMusic")
        XCTAssertEqual(registry.activeSourceID, .appleMusic)
    }

    func test_registry_registerAndActiveSource() {
        let suiteName = "AppleMusicPlaybackSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let mc = MusicController(preview: true)
        let source = AppleMusicPlaybackSource(controller: mc)
        let registry = PlaybackSourceRegistry(defaults: defaults)
        registry.register(source)

        XCTAssertTrue(registry.activeSource === source)
    }
}
