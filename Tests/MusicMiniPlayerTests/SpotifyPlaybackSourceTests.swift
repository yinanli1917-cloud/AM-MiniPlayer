//
//  SpotifyPlaybackSourceTests.swift
//  Covers the E1 Spotify playback-source adapter, over a fake
//  SpotifyScriptingReading — never touches the real Spotify.app.
//

import XCTest
@testable import MusicMiniPlayerCore

// MARK: - Fake reader

private final class FakeSpotifyReader: SpotifyScriptingReading {
    var isRunning: Bool = true
    var state: SpotifyPlayerState?
    var performedCommands: [SpotifyCommand] = []

    func readState() -> SpotifyPlayerState? { state }

    func perform(_ command: SpotifyCommand) {
        performedCommands.append(command)
    }
}

@MainActor
final class SpotifyPlaybackSourceTests: XCTestCase {

    private func makeTrack(
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        duration: Int = 200,
        spotifyURL: String? = "spotify:track:abc123",
        coverURL: String? = "https://example.com/art.jpg"
    ) -> SpotifyTrackInfo {
        SpotifyTrackInfo(title: title, artist: artist, album: album, duration: duration, spotifyURL: spotifyURL, coverURL: coverURL)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Snapshot mapping
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_readSnapshot_mapsStateFields() async {
        let reader = FakeSpotifyReader()
        reader.state = SpotifyPlayerState(
            playerState: 1,
            playbackPosition: 12.5,
            soundVolume: 70,
            shuffle: true,
            repeatMode: false,
            track: makeTrack()
        )
        let source = SpotifyPlaybackSource(reader: reader)

        let snapshot = await source.readSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.identity?.title, "Song")
        XCTAssertEqual(snapshot?.identity?.artist, "Artist")
        XCTAssertEqual(snapshot?.identity?.album, "Album")
        XCTAssertEqual(snapshot?.identity?.duration, 200) // Int seconds -> Double
        XCTAssertEqual(snapshot?.identity?.nativeID, "spotify:track:abc123")
        XCTAssertEqual(snapshot?.identity?.stableKey, "spotify:spotify:track:abc123")
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.position, 12.5)
        XCTAssertEqual(snapshot?.shuffle, true)
        XCTAssertEqual(snapshot?.repeatMode, 0)
        XCTAssertEqual(snapshot?.volume, 70)
        XCTAssertEqual(snapshot?.artwork, .url(URL(string: "https://example.com/art.jpg")!))
    }

    func test_readSnapshot_noCoverURL_fallsBackToLookupByMetadata() async {
        let reader = FakeSpotifyReader()
        reader.state = SpotifyPlayerState(
            playerState: 2,
            playbackPosition: 0,
            soundVolume: 50,
            shuffle: false,
            repeatMode: false,
            track: makeTrack(coverURL: nil)
        )
        let source = SpotifyPlaybackSource(reader: reader)

        let snapshot = await source.readSnapshot()

        XCTAssertEqual(snapshot?.artwork, .lookupByMetadata)
        XCTAssertEqual(snapshot?.isPlaying, false) // playerState 2 = paused
    }

    func test_readSnapshot_repeatTrue_mapsToRepeatModeAll() async {
        let reader = FakeSpotifyReader()
        reader.state = SpotifyPlayerState(
            playerState: 1, playbackPosition: 0, soundVolume: 50,
            shuffle: false, repeatMode: true, track: makeTrack()
        )
        let source = SpotifyPlaybackSource(reader: reader)

        let snapshot = await source.readSnapshot()
        XCTAssertEqual(snapshot?.repeatMode, 2)
    }

    func test_readSnapshot_noTrack_identityIsNil() async {
        let reader = FakeSpotifyReader()
        reader.state = SpotifyPlayerState(
            playerState: 0, playbackPosition: 0, soundVolume: 50,
            shuffle: false, repeatMode: false, track: nil
        )
        let source = SpotifyPlaybackSource(reader: reader)

        let snapshot = await source.readSnapshot()
        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.identity)
    }

    func test_readSnapshot_notRunning_returnsNil() async {
        let reader = FakeSpotifyReader()
        reader.isRunning = false
        reader.state = SpotifyPlayerState(
            playerState: 1, playbackPosition: 0, soundVolume: 50,
            shuffle: false, repeatMode: false, track: makeTrack()
        )
        let source = SpotifyPlaybackSource(reader: reader)

        let snapshot = await source.readSnapshot()
        XCTAssertNil(snapshot)
    }

    func test_readQueue_isAlwaysNil() async {
        let reader = FakeSpotifyReader()
        let source = SpotifyPlaybackSource(reader: reader)
        let queue = await source.readQueue()
        XCTAssertNil(queue)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Polling / events
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_start_notRunning_yieldsAppNotRunningOnce() async {
        let reader = FakeSpotifyReader()
        reader.isRunning = false
        let source = SpotifyPlaybackSource(reader: reader, pollInterval: 0.02)

        var availabilities: [PlaybackSourceAvailability] = []
        let expectation = expectation(description: "not running")
        let task = Task {
            for await event in source.events {
                if case let .availability(a) = event {
                    availabilities.append(a)
                    expectation.fulfill()
                }
            }
        }
        source.start()
        await fulfillment(of: [expectation], timeout: 1.0)
        source.stop()
        task.cancel()

        XCTAssertEqual(availabilities.first, .appNotRunning)
        // Should not re-yield on every tick within the reprobe window.
        XCTAssertLessThanOrEqual(availabilities.count, 2)
    }

    func test_start_becomesAvailable_yieldsAvailabilityThenSnapshot() async {
        let reader = FakeSpotifyReader()
        reader.isRunning = false
        let source = SpotifyPlaybackSource(reader: reader, pollInterval: 0.02)

        var events: [PlaybackSourceEvent] = []
        let snapshotExpectation = expectation(description: "snapshot arrives")
        let task = Task {
            for await event in source.events {
                events.append(event)
                if case .snapshot = event {
                    snapshotExpectation.fulfill()
                }
            }
        }

        source.start()
        try? await Task.sleep(nanoseconds: 60_000_000)

        reader.isRunning = true
        reader.state = SpotifyPlayerState(
            playerState: 1, playbackPosition: 0, soundVolume: 50,
            shuffle: false, repeatMode: false, track: makeTrack()
        )

        await fulfillment(of: [snapshotExpectation], timeout: 1.0)
        source.stop()
        task.cancel()

        let hadNotRunning = events.contains { if case .availability(.appNotRunning) = $0 { return true }; return false }
        let hadAvailable = events.contains { if case .availability(.available) = $0 { return true }; return false }
        XCTAssertTrue(hadNotRunning)
        XCTAssertTrue(hadAvailable)
    }

    func test_pollTwiceWithSameState_doesNotDuplicateSnapshot() async {
        let reader = FakeSpotifyReader()
        reader.state = SpotifyPlayerState(
            playerState: 1, playbackPosition: 5, soundVolume: 50,
            shuffle: false, repeatMode: false, track: makeTrack()
        )
        let source = SpotifyPlaybackSource(reader: reader, pollInterval: 0.02)

        var snapshotCount = 0
        let task = Task {
            for await event in source.events {
                if case .snapshot = event {
                    snapshotCount += 1
                }
            }
        }

        source.start()
        try? await Task.sleep(nanoseconds: 200_000_000) // several poll ticks, identical state
        source.stop()
        task.cancel()

        XCTAssertEqual(snapshotCount, 1, "identical state across polls must collapse into one snapshot event")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Command forwarding
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_controls_forwardExpectedCommands() async {
        let reader = FakeSpotifyReader()
        let source = SpotifyPlaybackSource(reader: reader)

        await source.togglePlayPause()
        await source.next()
        await source.previous()
        await source.seek(to: 42.0)
        await source.setShuffle(true)
        await source.setRepeatMode(0)
        await source.setRepeatMode(2)
        await source.setVolume(33)

        XCTAssertEqual(reader.performedCommands.count, 8)

        guard case .playpause = reader.performedCommands[0] else { return XCTFail("expected playpause") }
        guard case .nextTrack = reader.performedCommands[1] else { return XCTFail("expected nextTrack") }
        guard case .previousTrack = reader.performedCommands[2] else { return XCTFail("expected previousTrack") }
        guard case let .seek(pos) = reader.performedCommands[3] else { return XCTFail("expected seek") }
        XCTAssertEqual(pos, 42.0)
        guard case let .setShuffle(on) = reader.performedCommands[4] else { return XCTFail("expected setShuffle") }
        XCTAssertTrue(on)
        guard case let .setRepeat(off) = reader.performedCommands[5] else { return XCTFail("expected setRepeat") }
        XCTAssertFalse(off)
        guard case let .setRepeat(on) = reader.performedCommands[6] else { return XCTFail("expected setRepeat") }
        XCTAssertTrue(on)
        guard case let .setVolume(level) = reader.performedCommands[7] else { return XCTFail("expected setVolume") }
        XCTAssertEqual(level, 33)
    }

    func test_repeatMode_roundTrips0And2() async {
        let reader = FakeSpotifyReader()
        let source = SpotifyPlaybackSource(reader: reader)

        await source.setRepeatMode(0)
        guard case let .setRepeat(off) = reader.performedCommands.last else { return XCTFail() }
        XCTAssertFalse(off)

        await source.setRepeatMode(2)
        guard case let .setRepeat(on) = reader.performedCommands.last else { return XCTFail() }
        XCTAssertTrue(on)
    }
}
