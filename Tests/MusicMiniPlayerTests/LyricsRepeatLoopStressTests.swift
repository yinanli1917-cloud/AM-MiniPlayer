import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Repeat-loop EDGE — 单曲循环 vs 歌单循环.
//
// Repeat-one: the same persistentID comes back around. That is NOT a
// track change (PID door), and a same-song fetch while content is on
// screen is P1-blocked. Replay of a cached song must land on .content
// synchronously (no spinner). Repeat-all wrapping last→first IS a
// track change (different PID) and must take the cache-hit path, not
// a fresh search, when the disk already has the row.
//
// Headless, injected identity — no Music.app. Founder rule 2026-08-21.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRepeatLoopStressTests: XCTestCase {

    private var savedDiskCache: LyricsDiskCache!
    private var tempCache: LyricsDiskCache!

    override func setUp() {
        super.setUp()
        savedDiskCache = LyricsFetcher.shared.lyricsDiskCache
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("repeat-loop-\(UUID().uuidString).json")
        tempCache = LyricsDiskCache(fileURL: url)
        LyricsFetcher.shared.lyricsDiskCache = tempCache
    }

    override func tearDown() {
        LyricsFetcher.shared.lyricsDiskCache = savedDiskCache
        tempCache = nil
        savedDiskCache = nil
        super.tearDown()
    }

    private func wordLevelLines(_ text: String, count: Int = 8) -> [LyricLine] {
        (0..<count).map { i in
            let s = TimeInterval(i) * 3, e = s + 3
            let w = (e - s) / 2
            return LyricLine(
                text: "\(text) \(i)", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "\(text) ", startTime: s, endTime: s + w),
                    LyricWord(word: "\(i)", startTime: s + w, endTime: e)
                ]
            )
        }
    }

    // ── Identity doors: repeat-one is not a track change ─────────────────

    func test_repeatOne_samePID_isNotATrackChange_evenWhenPlayerReraisesNotification() {
        XCTAssertFalse(MusicController.notificationIndicatesTrackChange(
            notificationPID: "AAAA", currentPID: "AAAA", metadataDiffers: true),
                       "repeat-one re-raise with drifted strings is still the same song")
        XCTAssertFalse(MusicController.snapshotIndicatesTrackChange(
            snapshotPID: "AAAA", snapshotIsURLTrack: false,
            snapshotTitle: "Loop Song", snapshotArtist: "Artist", snapshotAlbum: "LP",
            currentPID: "AAAA", currentTitle: "Loop Song", currentArtist: "Artist", currentAlbum: "LP"))
        XCTAssertTrue(LyricsService.isLikelySameSongMetadataCorrection(
            currentStableSongID: "loop song|artist",
            requestStableSongID: "loop song|artist",
            currentDuration: 210,
            requestDuration: 211,
            currentAlbum: "LP",
            requestAlbum: "LP",
            requestPersistentID: "AAAA",
            currentPersistentID: "AAAA"
        ))
    }

    func test_repeatAll_wrapFromLastToFirst_isATrackChange() {
        XCTAssertTrue(MusicController.notificationIndicatesTrackChange(
            notificationPID: "FIRST", currentPID: "LAST", metadataDiffers: true),
                      "playlist wrap last→first is a real identity change")
        XCTAssertTrue(MusicController.snapshotIndicatesTrackChange(
            snapshotPID: "FIRST", snapshotIsURLTrack: false,
            snapshotTitle: "Track 1", snapshotArtist: "Artist", snapshotAlbum: "LP",
            currentPID: "LAST", currentTitle: "Track 12", currentArtist: "Artist", currentAlbum: "LP"))
    }

    func test_repeatModeRawValues_stillRoundTrip() {
        XCTAssertEqual(AppleEventCode.repeatMode(from: AppleEventCode.repeatOne), 1)
        XCTAssertEqual(AppleEventCode.repeatMode(from: AppleEventCode.repeatAll), 2)
        XCTAssertEqual(AppleEventCode.repeatMode(from: AppleEventCode.repeatOff), 0)
    }

    // ── Cache-hit path on replay (the loop's second pass) ────────────────

    @MainActor
    func test_repeatOne_secondPass_diskHitLandsOnContent_noSpinner_p1BlocksCorrection() {
        let service = LyricsService.shared
        let title = "Repeat One \(UUID().uuidString.prefix(8))"
        let artist = "Loop Artist"
        tempCache.set(title: title, artist: artist, duration: 210, album: "LP",
                      source: LyricsSource.netEase.rawValue,
                      lines: wordLevelLines("loop"), matchedDurationDiff: 0.1)

        // First pass: disk pre-flight → content, word-level, no spinner.
        service.fetchLyrics(for: title, artist: artist, duration: 210, album: "LP",
                            persistentID: "LOOPPID", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        XCTAssertFalse(service.displayState.isSearchPhase)
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync })
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("loop") })
        let firstPassWords = service.lyrics.map(\.words.count)

        // Repeat-one "ended and restarted": same PID, +1s duration correction
        // (the SB snapshot that used to slip past the guard).
        service.fetchLyrics(for: title, artist: artist, duration: 211, album: "LP",
                            persistentID: "LOOPPID", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content, "repeat-one must not re-enter searching")
        XCTAssertFalse(service.displayState.isSearchPhase)
        XCTAssertEqual(service.lyrics.map(\.words.count), firstPassWords,
                       "P1 display lock: the original word axis stays")
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("loop") })
    }

    @MainActor
    func test_repeatAll_returningToACachedTrack_hitsDisk_noSpinner() {
        let service = LyricsService.shared
        let firstTitle = "Wrap First \(UUID().uuidString.prefix(8))"
        let lastTitle = "Wrap Last \(UUID().uuidString.prefix(8))"
        let artist = "Wrap Artist"
        tempCache.set(title: firstTitle, artist: artist, duration: 180, album: "LP",
                      source: LyricsSource.netEase.rawValue,
                      lines: wordLevelLines("first"), matchedDurationDiff: 0.1)
        tempCache.set(title: lastTitle, artist: artist, duration: 200, album: "LP",
                      source: LyricsSource.netEase.rawValue,
                      lines: wordLevelLines("last"), matchedDurationDiff: 0.1)

        service.fetchLyrics(for: firstTitle, artist: artist, duration: 180, album: "LP",
                            persistentID: "FIRST", forceRefresh: false)
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("first") })

        service.fetchLyrics(for: lastTitle, artist: artist, duration: 200, album: "LP",
                            persistentID: "LAST", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("last") })
        XCTAssertFalse(service.lyrics.contains { $0.text.contains("first") })

        // Playlist wrapped: last → first. Different PID, so this IS a change,
        // but the disk row must satisfy it synchronously (no spinner).
        service.fetchLyrics(for: firstTitle, artist: artist, duration: 180, album: "LP",
                            persistentID: "FIRST", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content, "returning to a cached track must not spinner")
        XCTAssertFalse(service.displayState.isSearchPhase)
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync })
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("first") },
                      "wrap-around must serve the first track's own cache row, not the last's")
        XCTAssertFalse(service.lyrics.contains { $0.text.contains("last") })
    }

    @MainActor
    func test_repeatOne_instrumentalMemoReplay_doesNotReenterSearch() {
        // A confirmed instrumental, looped: the session memo answers instantly.
        let memo = LyricsMissMemo<LyricsService.TerminalMissVerdict>()
        let songID = "air on a g string|bach|instrumental sketches|241"
        let key = LyricsService.missMemoKey(forSongID: songID)
        XCTAssertTrue(LyricsService.shouldRecordTerminalMiss(verdict: .instrumental))
        memo.record(.instrumental, forKey: key)
        XCTAssertEqual(memo.confirmedMiss(forKey: key), .instrumental)
        XCTAssertTrue(LyricsService.shouldServeMemoHit(storedDuration: 241, currentDuration: 240))
        XCTAssertFalse(
            LyricsService.TerminalMissVerdict.instrumental.displayState.isSearchPhase,
            "looping an instrumental must replay the terminal, never a spinner"
        )
        // A different track in the same playlist must not inherit the memo.
        XCTAssertNil(memo.confirmedMiss(forKey: LyricsService.missMemoKey(forSongID: "next vocal|bach|lp|180")))
    }
}
