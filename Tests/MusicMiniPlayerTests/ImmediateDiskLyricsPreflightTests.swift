import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Phase 1 of the founder's 2026-08-25 ruling: a CACHED song must never show a spinner.
// LyricsFetcher.immediateSyncedDiskLyrics is the synchronous, correctness-gated disk lookup that
// LyricsService.fetchLyrics calls in its pre-flight (before .searching) so a disk-cached word-level
// song renders immediately with no spinner and no line-level→word-level flip (T2 #1/#3).
//
// These pin the correctness gates — because "never spinner" must NEVER become "sometimes wrong
// lyrics" (postmortem 006). The method must:
//   - serve a non-CJK word-level disk hit,
//   - refuse to serve when the title/artist is CJK (that path stays async, alias-resolved),
//   - refuse a line-level-only entry (canUseImmediateCachedLyrics requires syllable sync),
//   - refuse a romanized-input → CJK-lyrics sibling (the 006 guard),
//   - return nil on a genuine miss (caller falls through to the async fetch — no regression).
// A temp-file LyricsDiskCache is injected so the user's real lyrics_cache.json is never touched.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class ImmediateDiskLyricsPreflightTests: XCTestCase {

    private var savedDiskCache: LyricsDiskCache!
    private var tempCache: LyricsDiskCache!

    override func setUp() {
        super.setUp()
        savedDiskCache = LyricsFetcher.shared.lyricsDiskCache
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString).json")
        tempCache = LyricsDiskCache(fileURL: url)
        LyricsFetcher.shared.lyricsDiskCache = tempCache
    }

    override func tearDown() {
        LyricsFetcher.shared.lyricsDiskCache = savedDiskCache
        tempCache = nil
        savedDiskCache = nil
        super.tearDown()
    }

    private func wordLevelLines(_ text: String, count: Int = 10) -> [LyricLine] {
        (0..<count).map { i in
            let s = TimeInterval(i) * 3, e = s + 3
            let w = (e - s) / 2
            return LyricLine(
                text: "\(text) \(i)", startTime: s, endTime: e,
                words: [
                    LyricWord(word: "\(text) ", startTime: s, endTime: s + w),
                    LyricWord(word: "\(i)", startTime: s + w, endTime: e),
                ]
            )
        }
    }

    private func lineLevelLines(_ text: String, count: Int = 10) -> [LyricLine] {
        (0..<count).map { i in
            LyricLine(text: "\(text) \(i)", startTime: TimeInterval(i) * 3, endTime: TimeInterval(i) * 3 + 3)
        }
    }

    // Non-CJK word-level disk hit → served synchronously.
    func test_nonCJKWordLevelHit_isServed() {
        tempCache.set(title: "Everything I Know", artist: "Laufey", duration: 210, album: "Deluxe",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("word"), matchedDurationDiff: 0.2)
        let result = LyricsFetcher.shared.immediateSyncedDiskLyrics(
            title: "Everything I Know", artist: "Laufey", duration: 210, album: "Deluxe", translationEnabled: false)
        XCTAssertNotNil(result, "a non-CJK word-level disk entry must be served immediately")
        XCTAssertTrue(result?.lyrics.contains { $0.hasSyllableSync } ?? false, "served lyrics must be word-level")
        XCTAssertEqual(result?.kind, .synced)
    }

    // CJK title → NOT served here (stays on the async, alias-resolved path). No wrong-lyrics risk.
    func test_cjkTitle_isNotServedByPreflight() {
        tempCache.set(title: "残酷な天使のテーゼ", artist: "高橋洋子", duration: 245, album: "",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("残酷"), matchedDurationDiff: 0.1)
        let result = LyricsFetcher.shared.immediateSyncedDiskLyrics(
            title: "残酷な天使のテーゼ", artist: "高橋洋子", duration: 245, album: "", translationEnabled: false)
        XCTAssertNil(result, "CJK-titled songs must NOT be served by the synchronous pre-flight (postmortem 006 — stays async)")
    }

    // Line-level-only entry → NOT served (canUseImmediateCachedLyrics requires syllable sync).
    func test_lineLevelOnlyEntry_isNotServed() {
        tempCache.set(title: "Line Level Song", artist: "Some Artist", duration: 180, album: "",
                      source: LyricsSource.lrclib.rawValue, lines: lineLevelLines("plain"), matchedDurationDiff: 0.0)
        let result = LyricsFetcher.shared.immediateSyncedDiskLyrics(
            title: "Line Level Song", artist: "Some Artist", duration: 180, album: "", translationEnabled: false)
        XCTAssertNil(result, "a line-level-only entry must not be served immediately (no word timeline to sweep)")
    }

    // Genuine miss → nil (caller falls through to the async fetch).
    func test_miss_returnsNil() {
        let result = LyricsFetcher.shared.immediateSyncedDiskLyrics(
            title: "Never Cached", artist: "Nobody", duration: 200, album: "", translationEnabled: false)
        XCTAssertNil(result, "a genuine cache miss must return nil so the caller runs the normal async fetch")
    }

    // Romanized (ASCII) input whose disk lyrics are CJK: the 006 guard in canUseImmediateCachedLyrics
    // allows this ONLY under its strict ASCII-title conditions; a plainly English-looking title must
    // not pull CJK lyrics. Here the title reads as English → must be refused.
    func test_englishLookingTitleWithCJKLyrics_isRefused() {
        tempCache.set(title: "Love Story", artist: "Taylor", duration: 230, album: "",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("我爱你"), matchedDurationDiff: 0.1)
        let result = LyricsFetcher.shared.immediateSyncedDiskLyrics(
            title: "Love Story", artist: "Taylor", duration: 230, album: "", translationEnabled: false)
        XCTAssertNil(result, "an English-looking title must not immediately pull CJK lyrics (006 sibling-collision guard)")
    }

    // ── End-to-end: T2#1/#3 turned green in the "disk has word-level" scenario ──────────────
    // A disk-cached word-level non-CJK song, fetched from cold (not in the 50-item in-memory cache),
    // must land on .content SYNCHRONOUSLY (no .searching spinner) with word-level lyrics — no
    // line-level→word-level upgrade flip, no "Searching more sources" prompt. Because fetchLyrics'
    // pre-flight applies the disk result in the same main-thread tick, SwiftUI never renders a
    // spinner frame.
    @MainActor
    func test_fetchLyrics_diskWordLevelHit_landsOnContentSynchronously_noSpinner() {
        let service = LyricsService.shared
        // Unique identity so the in-memory NSCache and the dedup/stability guards all miss → the
        // disk pre-flight is the only thing that can satisfy this fetch.
        let title = "Preflight E2E \(UUID().uuidString.prefix(8))"
        let artist = "E2E Artist"
        let duration: TimeInterval = 201
        tempCache.set(title: title, artist: artist, duration: duration, album: "",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("hello"), matchedDurationDiff: 0.1)

        service.fetchLyrics(for: title, artist: artist, duration: duration, album: "", persistentID: "e2e-pid", forceRefresh: false)

        // Synchronously after the call: content is up, word-level, no spinner phase.
        XCTAssertEqual(service.displayState, .content,
                       "a disk-cached song must land on .content synchronously — never a spinner")
        XCTAssertFalse(service.displayState.isSearchPhase, "no searching/deep-searching phase for a cached song")
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync },
                      "the served lyrics must be word-level (the granularity upgrade flip is gone)")
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("hello") },
                      "the served content must be the seeded disk entry for this exact song")
        // No assertion on network: the pre-flight returns before launching the async fetch task,
        // so this test performs zero network I/O.
    }

    // ── Phase 2: CJK native-exact serve (immediateNativeExactDiskLyrics) ────────────────────
    // Safety rests on exact-key identity: a romanized input hashes to a different key and misses,
    // so the 006 sibling path is unreachable; a native-CJK re-play hits its own key.

    func test_phase2_cjkNativeExactWordLevelHit_isServed() {
        tempCache.set(title: "残酷な天使のテーゼ", artist: "高橋洋子", duration: 245, album: "NEON GENESIS",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("残酷"), matchedDurationDiff: 0.1)
        let result = LyricsFetcher.shared.immediateNativeExactDiskLyrics(
            title: "残酷な天使のテーゼ", artist: "高橋洋子", duration: 245, album: "NEON GENESIS", translationEnabled: false)
        XCTAssertNotNil(result, "a native-CJK exact-key word-level entry must be served (Phase 2)")
        XCTAssertTrue(result?.lyrics.contains { $0.hasSyllableSync } ?? false)
    }

    // A ROMANIZED input for the same song hashes to a different key → miss → falls to async
    // (no wrong-lyrics via the 006 sibling path).
    func test_phase2_romanizedInputForSameCJKSong_missesExactKey() {
        tempCache.set(title: "残酷な天使のテーゼ", artist: "高橋洋子", duration: 245, album: "NEON GENESIS",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("残酷"), matchedDurationDiff: 0.1)
        let result = LyricsFetcher.shared.immediateNativeExactDiskLyrics(
            title: "Zankoku na Tenshi no Teeze", artist: "Yoko Takahashi", duration: 245, album: "NEON GENESIS", translationEnabled: false)
        XCTAssertNil(result, "a romanized query is a different key — must miss and stay on the async alias-resolved path")
    }

    // Non-CJK is owned by Phase 1; the Phase 2 method must not serve it (returns nil).
    func test_phase2_nonCJK_isNotServedByNativeExactPath() {
        tempCache.set(title: "Some English Song", artist: "English Artist", duration: 200, album: "",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("english"), matchedDurationDiff: 0.0)
        let result = LyricsFetcher.shared.immediateNativeExactDiskLyrics(
            title: "Some English Song", artist: "English Artist", duration: 200, album: "", translationEnabled: false)
        XCTAssertNil(result, "non-CJK titles are Phase 1's job; the native-exact path returns nil for them")
    }

    // ── P1 anti-oscillation: a same-song re-fetch while content is displayed must not replace it ──
    // Founder 2026-08-25: "逐字→逐行→逐字" oscillation = a later re-fetch (duration correction) that
    // re-selects a worse-granularity result and swaps the display. P1 blocks the same-song re-fetch
    // whenever content is on screen, so the display is frozen.
    @MainActor
    func test_p1_sameSongDurationCorrectionRefetch_whileContentDisplayed_isBlocked() {
        let service = LyricsService.shared
        let title = "P1 Freeze \(UUID().uuidString.prefix(8))"
        let artist = "Freeze Artist"

        // 1) First fetch: word-level disk hit → content shown, word-level.
        tempCache.set(title: title, artist: artist, duration: 205, album: "Alb",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("first"), matchedDurationDiff: 0.1)
        service.fetchLyrics(for: title, artist: artist, duration: 205, album: "Alb", persistentID: "p1freeze", forceRefresh: false)
        XCTAssertEqual(service.displayState, .content)
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync }, "precondition: first publish is word-level")
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("first") })

        // 2) Overwrite the disk entry with a WORSE line-level result and re-fetch the SAME song with a
        //    +1s duration correction (a new songID, the path that used to slip past the guard).
        tempCache.set(title: title, artist: artist, duration: 206, album: "Alb",
                      source: LyricsSource.lrclib.rawValue, lines: lineLevelLines("second"), matchedDurationDiff: 0.0)
        service.fetchLyrics(for: title, artist: artist, duration: 206, album: "Alb", persistentID: "p1freeze", forceRefresh: false)

        // 3) P1: blocked — the display must stay the word-level "first", never flip to line-level "second".
        XCTAssertEqual(service.displayState, .content, "display must remain content, not re-enter searching")
        XCTAssertTrue(service.lyrics.contains { $0.hasSyllableSync },
                      "P1: a same-song correction must NOT downgrade the shown word-level lyrics to line-level")
        XCTAssertTrue(service.lyrics.contains { $0.text.contains("first") },
                      "P1: the originally shown lyrics must remain — no mid-stream replacement")
        XCTAssertFalse(service.lyrics.contains { $0.text.contains("second") },
                       "P1: the re-fetch's worse result must not reach the display")
    }

    // The duration gate blocks a ±1 neighbor-key entry whose stored duration is genuinely far off.
    func test_phase2_durationGate_blocksFarNeighbor() {
        // Seed at duration 246 (so its dur-1 key = 245 overlaps a query at 245), but stored duration 246
        // is only 1s off → within the 1.5s gate → SERVED. Then seed a far one to confirm the gate bites.
        tempCache.set(title: "曲名テスト", artist: "アーティスト", duration: 250, album: "A",
                      source: LyricsSource.netEase.rawValue, lines: wordLevelLines("遠い"), matchedDurationDiff: 3.0)
        // Query at 248: keys {247,248,249} — the stored 250 entry's keys are {249,250,251}, overlap at 249.
        // Stored duration 250 vs query 248 = 2.0s > 1.5s gate → must be blocked.
        let result = LyricsFetcher.shared.immediateNativeExactDiskLyrics(
            title: "曲名テスト", artist: "アーティスト", duration: 248, album: "A", translationEnabled: false)
        XCTAssertNil(result, "an entry whose stored duration is >1.5s from the query must be blocked by the duration gate")
    }
}
