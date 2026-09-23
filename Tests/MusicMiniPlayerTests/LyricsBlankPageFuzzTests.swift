/**
 * [INPUT]: Depends on MusicMiniPlayerCore's LyricsService (fetchLyrics, displayState,
 *          lyrics, isLikelySameSongMetadataCorrection, shouldServeMemoHit,
 *          missMemoKey) and LyricsFetcher/LyricsDiskCache's synchronous disk
 *          pre-flight, driven directly through the same test seam
 *          LyricsRepeatLoopStressTests already uses (temp LyricsDiskCache swapped
 *          into LyricsFetcher.shared, real LyricsService.shared calls). No
 *          MusicController, no timers.
 * [OUTPUT]: Exports LyricsBlankPageFuzzTests — a minimal deterministic regression,
 *           a positive self-heal control, and a seeded pure-function fuzzer
 *           reproducing the 2026-09-22 founder report ("lyrics page occasionally
 *           goes completely blank; switching songs fixes it").
 * [POS]: Test module. Reproduction-only per the project's 先复现再修 iron rule — no
 *        production code is touched by this file. See
 *        research/diagnosis-2026-09-22-blank-lyrics-page.md for the full forensics,
 *        the mechanism writeup, and the proposed (not-yet-applied) fix direction.
 *
 * SAFETY (2026-09-22, added after an earlier draft of this file was found to have
 * written to the founder's real ~/Library/Application Support/nanoPod/ caches —
 * see the research doc's "Safety incident" section):
 *   - `LyricsFetcher.shared.lyricsDiskCache` IS swappable and is swapped to a temp
 *     file in setUp/tearDown (the established pattern). A "clean" call in this
 *     file is only ever asserted safe when it demonstrably resolves via that temp
 *     cache's synchronous disk pre-flight — it therefore never reaches
 *     `MetadataResolver.shared` or the network.
 *   - `MetadataResolver.shared.diskCache` is NOT swappable (`let`, bound to
 *     `MetadataDiskCache.defaultURL()` — the founder's real file). Any call that
 *     MISSES the disk pre-flight falls through to a real, unstructured
 *     `Task { … fetchAllSources … }` that touches it and the network, and that
 *     task can start running on a background thread before this synchronous test
 *     method even returns (confirmed: an earlier run of the 3000-trial fuzzer
 *     below, before this fix, took 191s of wall time and left the founder's
 *     `lyrics_cache.json`/`metadata_cache.json` mtimes updated).
 *   - The two tests below that deliberately construct a disk-cache MISS
 *     (`test_staleAlbumDurationRace…`, `test_selfHeals…`) wrap that one call in
 *     `LyricsCachePolicyContext.$current.withValue(.networkOnly())` — an
 *     already-existing, `#if DEBUG`-only production mechanism (the same one
 *     `LyricsVerifier run --network-only` uses, per CLAUDE.md) that makes BOTH
 *     `LyricsDiskCache` and `MetadataDiskCache` refuse every read AND write for
 *     the dynamic extent of the call, including any child `Task` it spawns
 *     (Swift task-locals are captured by an unstructured `Task {}` at creation).
 *     This guarantees zero reads/writes to any real cache file. It does NOT stop
 *     the spawned task's real NetEase/QQ/LRCLIB HTTP calls (those aren't gated by
 *     this policy) — which is why the bulk of the seeded exploration below
 *     (`test_fuzzedStaleFieldRaceBoundary…`) is redesigned to fuzz the
 *     already-extracted PURE decision functions directly instead of driving
 *     thousands of real `fetchLyrics` calls: zero network, zero disk I/O, fully
 *     deterministic, and still exercises the real production logic.
 */

import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Root cause under test (see research doc for the full log-forensics trail):
//
// MusicController.handleTrackChange(name:artist:album:) (MusicController.swift:1418)
// captures `name`/`artist` for the CURRENT notification and kicks off a deferred
// `metadataBridgeQueue.async` block (:1449) that reads ScriptingBridge (up to a 1.5s
// timeout) to backfill persistentID/duration. Its own `DispatchQueue.main.async`
// completion (:1497-1550) re-fires `lyricsService.fetchLyrics` with a "duration
// correction" at :1533:
//
//     self.lyricsService.fetchLyrics(for: name, artist: artist, duration: sbDuration,
//                                     album: self.currentAlbum, persistentID: self.currentPersistentID)
//
// `name`/`artist` are the STALE capture from when this closure was scheduled, but
// `self.currentAlbum` is read LIVE — and `self.currentAlbum` is written
// UNCONDITIONALLY by every `com.apple.Music.playerInfo` notification
// (MusicController.swift:1405, `applyTrackMetadata`, outside the `if trackChanged`
// gate), regardless of which generation is "current". The generation guard at
// :1452 is checked once, BEFORE the up-to-1.5s SB read and the main-queue hop — it
// is never re-checked at :1497 or :1533. During radio track-identity churn (two
// songs' notifications interleaving within ~1-9s, confirmed live in
// /tmp/nanopod_debug.log at 18:14:49-18:15:06 and 19:31:10-19:31:34, cross-
// referenced in research/diagnosis-2026-09-22-radio-artwork.md Mode B), this
// produces a torn composite: song A's title/artist paired with song B's
// album+duration (log evidence, L52334: songID
// 'mcs road de aimasho|kazuhito murata|french new wave 1957~1963|137' — title/
// artist from "Mc's Road De Aimasho" (dur 288s, album "Evergreen"), album/duration
// from "Roland Reve (From \"Lola\")" (dur 136s, album "French New Wave...")).
//
// LyricsService.fetchLyrics (LyricsService.swift:653) receives this composite and:
//   1. isLikelySameSongMetadataCorrection (:1363) decisively returns false whenever
//      both persistentIDs are present and differ (:1377-1380) — correct in
//      isolation, but the stability guard (:674-707) never gets a chance to run
//      because the composite's OWN persistentID belongs to the stale song, not the
//      one `self.currentAlbum`/`currentPersistentID` actually track.
//   2. The stability guard bypassed, the composite is treated as "a different song":
//      `lyrics = []`, `displayState = .searching` (:778-803) — a synchronous blank.
//   3. The synchronous disk pre-flight (LyricsFetcher.immediateSyncedDiskLyrics,
//      LyricsFetcher.swift:3335, keyed via LyricsDiskCache.cacheKeys at duration
//      rounded ±1s, LyricsDiskCache.swift:445-455) looks up (title=A, artist=A,
//      duration=B's value) — a bucket A's own real cached row was never written
//      under — so it MISSES even though A's real word-level lyrics sit in disk
//      cache right now under A's TRUE duration/album.
//   4. The call falls through to a full async re-search using the WRONG duration
//      (worth 40% of the matching score per CLAUDE.md's matching-algorithm table),
//      which can legitimately fail to re-find A's lyrics, terminating in
//      `.noLyrics`/`.networkUnreachable`.
//   5. Nothing else ever re-triggers fetchLyrics for A: MusicController's own
//      `currentTrackTitle` was never rewritten to the composite (only
//      LyricsService's internal bookkeeping was corrupted), so if Music.app is
//      still actually playing A, no further "track changed" is ever detected and
//      the page stays blank until a genuinely different track starts playing —
//      exactly the founder's report ("switching to another song fixes it").
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Deterministic seeded RNG (SplitMix64) — no external dependency, fully
/// reproducible across runs for a given seed so a failing trial can always be
/// replayed from just its integer seed.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class LyricsBlankPageFuzzTests: XCTestCase {

    private var savedDiskCache: LyricsDiskCache!
    private var tempCache: LyricsDiskCache!

    override func setUp() {
        super.setUp()
        savedDiskCache = LyricsFetcher.shared.lyricsDiskCache
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-lyrics-fuzz-\(UUID().uuidString).json")
        tempCache = LyricsDiskCache(fileURL: url)
        LyricsFetcher.shared.lyricsDiskCache = tempCache
    }

    override func tearDown() {
        LyricsFetcher.shared.lyricsDiskCache = savedDiskCache
        tempCache = nil
        savedDiskCache = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Word-level fixture lines. The word text MUST reconstruct the line's own
    /// `text` (LyricModels.swift:83-99's consistency invariant silently zeroes
    /// `words` otherwise — `"\(text) \(i)"` is the exact shape
    /// LyricsRepeatLoopStressTests already relies on).
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

    private struct FakeSong {
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let pid: String
        let marker: String
    }

    private func seed(_ song: FakeSong) {
        tempCache.set(title: song.title, artist: song.artist, duration: song.duration, album: song.album,
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines(song.marker),
                      matchedDurationDiff: 0.1)
    }

    /// Drives a real, clean `fetchLyrics` call for `song` (as a genuine
    /// notification-driven track change would) and returns whether it landed on
    /// content synchronously with the right lyrics. Safe by construction: every
    /// caller of this helper seeds `song` into `tempCache` first, so this either
    /// hits the swapped temp disk cache synchronously or the assertion fails
    /// loudly — it must never silently fall through to a real fetch.
    @MainActor
    @discardableResult
    private func applyClean(_ song: FakeSong, on service: LyricsService, forceRefresh: Bool = false) -> Bool {
        service.fetchLyrics(for: song.title, artist: song.artist, duration: song.duration,
                            album: song.album, persistentID: song.pid, forceRefresh: forceRefresh)
        return service.displayState == .content && service.lyrics.contains { $0.text.contains(song.marker) }
    }

    /// Drives the MusicController.swift:1533 deferred SB-duration-correction
    /// closure exactly AS THE FIXED CODE NOW HANDLES IT:
    /// `MusicController.shouldFireDeferredLyricsCorrection` is re-checked
    /// immediately before firing. `nameSong` is the closure's captured
    /// identity (`capturedGeneration`); `fieldSong` stands in for whatever
    /// became live-current in the meantime (`currentGeneration`) — its
    /// title/artist play the role of `self.currentTrackTitle`/`currentArtist`,
    /// its album/duration the role of the torn `self.currentAlbum` the OLD
    /// code used to read live. Only reaches `service.fetchLyrics` — the real
    /// production behavior pre-fix, or if a future change reintroduces the
    /// race — when the guard says the capture is still fresh, wrapped in
    /// `.networkOnly()` for the same safety reason as the file header.
    @MainActor
    private func applyStaleFieldRace(
        nameSong: FakeSong, fieldSong: FakeSong, pid: String?,
        capturedGeneration: Int, currentGeneration: Int,
        on service: LyricsService
    ) {
        guard MusicController.shouldFireDeferredLyricsCorrection(
            capturedGeneration: capturedGeneration, currentGeneration: currentGeneration,
            capturedTitle: nameSong.title, currentTitle: fieldSong.title,
            capturedArtist: nameSong.artist, currentArtist: fieldSong.artist
        ) else { return }
        LyricsCachePolicyContext.$current.withValue(.networkOnly()) {
            service.fetchLyrics(for: nameSong.title, artist: nameSong.artist, duration: fieldSong.duration,
                                album: fieldSong.album, persistentID: pid, forceRefresh: false)
        }
    }

    /// Feeds a torn composite DIRECTLY to `LyricsService.fetchLyrics`,
    /// bypassing MusicController's (now-fixed) guard entirely — simulating
    /// "some other, not-yet-reproduced path" per the coordinator's framing of
    /// the generic self-heal (item 2): LyricsService's own contract for bad
    /// input is unchanged by the MusicController fix (garbage in, treated as
    /// a new song, blanks), so this is the right seam for testing the
    /// self-heal independently of which caller produced the blank state.
    /// SAFETY: same `.networkOnly()` wrap as `applyStaleFieldRace`.
    @MainActor
    private func applyRawTornComposite(nameSong: FakeSong, fieldSong: FakeSong, pid: String?, on service: LyricsService) {
        LyricsCachePolicyContext.$current.withValue(.networkOnly()) {
            service.fetchLyrics(for: nameSong.title, artist: nameSong.artist, duration: fieldSong.duration,
                                album: fieldSong.album, persistentID: pid, forceRefresh: false)
        }
    }

    // MARK: - Minimal deterministic regression (shrunk from the live log) — root fix

    /// Reproduces /tmp/nanopod_debug.log L2432-2891 (Tell Me Oh Mama ↔ Mc's Road De
    /// Aimasho, 18:14:49-18:15:06) and L51698-52351 (Roland Reve ↔ Mc's Road De
    /// Aimasho, 19:31:10-19:31:34) in miniature: two real, disk-cached songs, a
    /// clean switch to each, then the deferred correction closure from A's OWN
    /// track change firing after B has already become current. Before the
    /// 2026-09-22 root fix (MusicController.swift:1531, generation+identity
    /// re-check) this call reached LyricsService with a torn composite and
    /// blanked B. After the fix, `shouldFireDeferredLyricsCorrection` drops it
    /// before it ever reaches LyricsService — this test now asserts THAT.
    @MainActor
    func test_staleAlbumDurationRace_blanksSongWithRealCachedLyrics_MusicControllerSwift1533() {
        let service = LyricsService.shared
        let uid = UUID().uuidString.prefix(8)
        let songA = FakeSong(title: "Mcs Road De Aimasho \(uid)", artist: "Kazuhito Murata \(uid)",
                              album: "Evergreen \(uid)", duration: 288.45, pid: "PID-A-\(uid)", marker: "aimasho\(uid)")
        let songB = FakeSong(title: "Roland Reve \(uid)", artist: "Jacqueline Danno \(uid)",
                              album: "French New Wave \(uid)", duration: 136.61, pid: "PID-B-\(uid)", marker: "roland\(uid)")
        seed(songA)
        seed(songB)

        // 1) Real track change to A — instant disk hit (founder rule: cached song
        //    must never show a spinner).
        XCTAssertTrue(applyClean(songA, on: service), "sanity: A must land on content from disk")

        // 2) Real track change to B (radio moved on) — instant disk hit; B is now
        //    "current" per both LyricsService's own bookkeeping and (in the real
        //    app) MusicController.currentTrackTitle/currentAlbum. This also
        //    advances the artwork/lyrics generation counter (1 → 2).
        XCTAssertTrue(applyClean(songB, on: service), "sanity: B must land on content from disk")

        // 3) The deferred SB-duration-correction closure from step 1's OWN
        //    handleTrackChange(A) finally executes (radio flipped back to A for
        //    real, so SB's live read confirms A's name again — the guard at
        //    MusicController.swift:1489 passes). It captured generation=1 and
        //    A's own title/artist when scheduled; by now generation is 2 and
        //    the live identity is B's — the root fix's re-check must drop it.
        applyStaleFieldRace(nameSong: songA, fieldSong: songB, pid: songA.pid,
                            capturedGeneration: 1, currentGeneration: 2, on: service)

        // FIXED: the call never reaches LyricsService, so B — the genuinely
        // current song — is never disturbed. (Before the fix, these two
        // assertions failed: displayState became .searching and lyrics
        // emptied, dropping B's real cached content for a song, A, whose
        // identity had not actually changed.)
        XCTAssertEqual(service.displayState, .content,
            "root fix: the dropped stale-correction call must never blank the genuinely current song")
        XCTAssertTrue(service.lyrics.contains { $0.text.contains(songB.marker) },
            "root fix: B's content must remain untouched — nothing was ever mixed with A's stale capture")
    }

    /// Positive control: the root fix must not break the LEGITIMATE use case
    /// the guard exists to protect — a genuine same-song duration correction
    /// (generation and identity both still match) must still fire and still
    /// land on content.
    @MainActor
    func test_deferredCorrection_stillFiresAndLandsOnContent_whenNothingActuallyChanged() {
        let service = LyricsService.shared
        let uid = UUID().uuidString.prefix(8)
        let songA = FakeSong(title: "Legit Correction \(uid)", artist: "Artist \(uid)",
                              album: "Album \(uid)", duration: 240.5, pid: "PID-A-\(uid)", marker: "legit\(uid)")
        seed(songA)

        XCTAssertTrue(applyClean(songA, on: service))
        // Same generation, same live identity as captured — a real duration
        // correction for the SAME still-current song.
        applyStaleFieldRace(nameSong: songA, fieldSong: songA, pid: songA.pid,
                            capturedGeneration: 1, currentGeneration: 1, on: service)

        XCTAssertEqual(service.displayState, .content)
        XCTAssertTrue(service.lyrics.contains { $0.text.contains(songA.marker) })
    }

    // MARK: - Generic self-heal recovers causes the root fix does not cover

    /// Item 2's own test: "the self-heal alone also recovers the torn-
    /// composite state" — regardless of what produced it. Feeds the torn
    /// composite directly to LyricsService (bypassing MusicController's now-
    /// fixed guard entirely, simulating an unforeseen path), then exercises
    /// the REAL self-heal decision function with the REAL identity-match
    /// check, and confirms reissuing per that decision actually restores A's
    /// content.
    @MainActor
    func test_selfHeal_aloneRecoversATornCompositeState_regardlessOfCause() {
        let service = LyricsService.shared
        let uid = UUID().uuidString.prefix(8)
        let songA = FakeSong(title: "Self Heal A \(uid)", artist: "Artist A \(uid)",
                              album: "Album A \(uid)", duration: 240, pid: "PID-A-\(uid)", marker: "healA\(uid)")
        let songB = FakeSong(title: "Self Heal B \(uid)", artist: "Artist B \(uid)",
                              album: "Album B \(uid)", duration: 180, pid: "PID-B-\(uid)", marker: "healB\(uid)")
        seed(songA)
        seed(songB)

        applyClean(songA, on: service)
        applyClean(songB, on: service)
        // pid: nil — the "PID not yet backfilled" window (this codebase's own
        // documented case: "Empty persistentID = title-based dedup; cache
        // backfill happens when SB returns ID", MusicController.swift:1438).
        // Using A's own pid here instead would make PID authority (a matching
        // persistentID proves the same physical song regardless of tuple
        // drift — isLikelySameSongMetadataCorrection:1377-1380, BY DESIGN)
        // correctly call this "still song A" despite the torn album/duration,
        // which would be a different, narrower scenario than the one under
        // test here — a fetch resolving with NO persistentID at all.
        applyRawTornComposite(nameSong: songA, fieldSong: songB, pid: nil, on: service)
        XCTAssertTrue(service.lyrics.isEmpty,
            "sanity: LyricsService's own contract for a torn composite is unchanged by the MusicController fix — it still blanks")

        // The self-heal's precise identity check (full title+artist+duration+
        // album+PID, tolerant of ordinary duration-rounding disagreement —
        // see LyricsService.isCurrentFetchIdentity) must recognize the
        // mismatch...
        let identitiesMatch = service.isCurrentFetchIdentity(
            title: songA.title, artist: songA.artist, duration: songA.duration, album: songA.album, persistentID: songA.pid
        )
        XCTAssertFalse(identitiesMatch, "the service's tracked identity must not match A's real identity after the torn call")
        XCTAssertTrue(MusicController.shouldReissueLyricsFetchForStaleIdentity(
            lyricsRowsAreEmpty: service.lyrics.isEmpty,
            lyricsMatchesControllerIdentity: identitiesMatch,
            reissueCountForCurrentTrack: 0,
            lastReissueAt: nil,
            now: Date()
        ), "the self-heal decision must say 'reissue' for this exact torn-composite state")

        // ...and reissuing (what MusicController's heartbeat does once that
        // decision is true) recovers A's real cached content — the self-heal
        // alone, with no further "switch songs" required from the founder.
        XCTAssertTrue(applyClean(songA, on: service),
            "the self-heal's reissue must restore A's content")
    }

    // MARK: - Seeded fuzzer over the PURE decision surface (zero network, zero disk I/O)
    //
    // The two tests above prove the end-to-end wiring once. Exploring thousands of
    // duration/album/PID combinations by driving `fetchLyrics` that many times
    // would mean thousands of real, uncontrollable NetEase/QQ/LRCLIB HTTP calls
    // (see the file header) — the opposite of "no network". Every one of those
    // combinations is fully decided by two ALREADY-EXTRACTED pure functions this
    // codebase ships:
    //   1. `LyricsService.isLikelySameSongMetadataCorrection` — the stability
    //      guard's "is this actually the same song" verdict (LyricsService.swift:1363).
    //   2. The disk cache's duration-rounding bucket
    //      (`LyricsDiskCache.cacheKeys`, LyricsDiskCache.swift:445-455): a request
    //      only has a CHANCE of a disk hit when `Int(duration.rounded())` lands in
    //      `[stored-1, stored, stored+1]` AND the normalized album matches (or the
    //      album-omitted fallback query is tried) — reproduced here as
    //      `diskBucketCouldHit`.
    // A torn composite reproduces the founder's bug exactly when BOTH say "no":
    // the guard doesn't recognize it as the same song (so the display blanks,
    // `lyrics = []`) AND the disk bucket can't rescue it (so it stays blank
    // instead of resolving synchronously). This is the same boundary the two
    // tests above already proved end-to-end for one concrete pair; fuzzing the
    // pure functions maps the boundary exhaustively and safely.

    private enum PIDMode: CaseIterable { case matchesNameSong, matchesFieldSong, missing }

    private struct Trial {
        let durationDelta: TimeInterval
        let albumsDiffer: Bool
        let pidMode: PIDMode
    }

    private func makeTrial(seed: UInt64) -> Trial {
        var rng = SplitMix64(seed: seed)
        // Spans well below and well above BOTH the guard's 2.0s tolerance
        // (LyricsService.swift:1389) and the disk cache's ±1s rounding bucket
        // (LyricsDiskCache.swift:450), so the fuzzer maps the boundary rather
        // than only ever landing deep in "obviously reproduces" territory.
        let durationDelta = TimeInterval.random(in: 0...220, using: &rng)
        let albumsDiffer = Bool.random(using: &rng)
        let pidMode = PIDMode.allCases.randomElement(using: &rng)!
        return Trial(durationDelta: durationDelta, albumsDiffer: albumsDiffer, pidMode: pidMode)
    }

    /// Mirrors `LyricsDiskCache.cacheKeys`' rounding bucket (LyricsDiskCache.swift:445-455)
    /// without touching any LyricsDiskCache instance: true iff a row stored at
    /// `storedDuration` could still be found by a lookup at `requestDuration`.
    private func diskBucketCouldHit(storedDuration: TimeInterval, requestDuration: TimeInterval) -> Bool {
        abs(Int(storedDuration.rounded()) - Int(requestDuration.rounded())) <= 1
    }

    /// Runs `trialCount` deterministic, pure, in-process trials (seed = trial
    /// index, so any failure is reproducible by re-running just that seed)
    /// against the REAL `isLikelySameSongMetadataCorrection` and the disk
    /// bucket arithmetic mirrored above — generalizing the minimal regression's
    /// one concrete pair across randomized duration/album/PID combinations.
    func test_fuzzedStaleFieldRaceBoundary_guardAndDiskBucketAgreeOnWhenAComposteIsSafe() {
        let trialCount: UInt64 = 5000
        var unsafeReproducingSeeds: [UInt64] = []
        // A's own stored duration for the disk-bucket check.
        let songADuration: TimeInterval = 200
        let songAAlbum = "Album A"
        let songAStable = "song a|artist a"

        for seedValue in 0..<trialCount {
            let trial = makeTrial(seed: seedValue)
            let requestDuration = songADuration + trial.durationDelta
            let requestAlbum = trial.albumsDiffer ? "Album B" : songAAlbum
            let (requestPID, currentPID): (String?, String?)
            switch trial.pidMode {
            case .matchesNameSong: (requestPID, currentPID) = ("PID-A", "PID-A")
            case .matchesFieldSong: (requestPID, currentPID) = ("PID-A", "PID-B") // decisive mismatch
            case .missing: (requestPID, currentPID) = (nil, nil)
            }

            let guardRecognizesSameSong = LyricsService.isLikelySameSongMetadataCorrection(
                currentStableSongID: songAStable,
                requestStableSongID: songAStable, // title/artist are ALWAYS A's own — that's the "torn" part
                currentDuration: songADuration,
                requestDuration: requestDuration,
                currentAlbum: songAAlbum,
                requestAlbum: requestAlbum,
                requestPersistentID: requestPID,
                currentPersistentID: currentPID
            )
            let diskCouldRescue = diskBucketCouldHit(storedDuration: songADuration, requestDuration: requestDuration)

            // The founder-report failure mode: NEITHER protection catches it.
            let wouldBlankAndStayBlank = !guardRecognizesSameSong && !diskCouldRescue

            // Sanity oracle, independent of the two systems under test: this MUST
            // happen whenever the duration drifted enough that a plain human
            // would call it "a different song's duration" (>2s, past the guard's
            // own documented tolerance) while ALSO landing outside the ±1s disk
            // bucket. A torn composite with `durationDelta` in (1, 2] can still
            // slip between the two systems' independent windows — recorded as a
            // finding, not asserted against, since the pure math already proves
            // whether the founder's exact log case (Δ≈151s) reproduces.
            if wouldBlankAndStayBlank {
                unsafeReproducingSeeds.append(seedValue)
            }
        }

        // The founder's own log case (title/artist correct, durationDelta≈151s,
        // decisive PID mismatch — MusicController.swift:1533's real shape) MUST
        // be among the reproducing seeds, or this fuzzer would be vacuous.
        let foundersCaseGuardVerdict = LyricsService.isLikelySameSongMetadataCorrection(
            currentStableSongID: songAStable, requestStableSongID: songAStable,
            currentDuration: songADuration, requestDuration: songADuration + 151,
            currentAlbum: songAAlbum, requestAlbum: "French New Wave",
            requestPersistentID: "PID-A", currentPersistentID: "PID-B"
        )
        XCTAssertFalse(foundersCaseGuardVerdict, "sanity: the fuzzer's own oracle must match the real log's shape")
        XCTAssertFalse(unsafeReproducingSeeds.isEmpty,
            "sanity: the fuzzer found zero reproducing seeds out of \(trialCount) — the boundary math is not exercising the bug at all")

        // The actual finding this test records: how much of the randomized
        // (durationDelta, album, PID) space reproduces the founder's exact
        // failure mode, entirely through the REAL guard + the REAL disk-bucket
        // arithmetic, with zero network and zero disk I/O.
        let reproductionRate = Double(unsafeReproducingSeeds.count) / Double(trialCount)
        XCTAssertGreaterThan(reproductionRate, 0.05,
            "expected a non-trivial slice of the randomized duration/album/PID space to reproduce the blank-and-stuck mechanism (found \(unsafeReproducingSeeds.count)/\(trialCount) = \(reproductionRate)); first failing seeds for replay: \(unsafeReproducingSeeds.prefix(10))")
    }

    // MARK: - MissMemo: the task's second invariant ("no 20-min miss memo recorded
    // for a track that got content") probed at the one place it can plausibly leak
    // across a torn composite: missMemoKey deliberately DROPS the duration
    // component (LyricsService.swift:1435-1442, "songID without its drifting
    // duration component") so ordinary ±1-2s player-snapshot jitter doesn't
    // fragment the memo. That means a torn composite sharing A's title+artist+
    // album but carrying a DIFFERENT (torn) duration collapses to the SAME memo
    // key as A's real identity. This test confirms the second, independent guard
    // that makes that collision harmless: `shouldServeMemoHit` (:1455-1458)
    // tolerance-checks the STORED duration against the CURRENT request (<=3.0s)
    // before ever replaying a memoized verdict — so a hypothetical confirmed-miss
    // recorded under the torn (duration=137) key is never served back to a
    // request carrying A's true duration (288). Both are asserted because either
    // one failing would let a torn composite poison the real song's terminal
    // state for up to the memo's TTL.

    func test_missMemoKey_collapsesAcrossDuration_byDesign() {
        let uid = UUID().uuidString.prefix(8)
        let realSongID = "song \(uid)|artist \(uid)|shared album \(uid)|288"
        let tornCompositeSongID = "song \(uid)|artist \(uid)|shared album \(uid)|137"
        XCTAssertEqual(
            LyricsService.missMemoKey(forSongID: realSongID),
            LyricsService.missMemoKey(forSongID: tornCompositeSongID),
            "documents the intentional design: the memo key ignores duration, so a same-album torn composite DOES collide with the real song's key"
        )
    }

    func test_missMemoDurationTolerance_preventsATornCompositesMissFromPoisoningTheRealSong() {
        // A torn composite's verdict was stored under the collided key with ITS
        // (torn) duration, 137. The real song's own request later arrives with
        // its true duration, 288 — a 151s gap, far past the 3.0s tolerance.
        XCTAssertFalse(
            LyricsService.shouldServeMemoHit(storedDuration: 137, currentDuration: 288),
            "BUG if this ever returns true: a torn composite's stale verdict would silently blank a song that has real cached lyrics under its true duration"
        )
        // Ordinary snapshot jitter for the SAME real song (no torn composite
        // involved) must still replay — this is the tolerance the design intends
        // to serve; confirms the assertion above isn't just tolerance=0.
        XCTAssertTrue(LyricsService.shouldServeMemoHit(storedDuration: 288.0, currentDuration: 288.9))
    }
}
