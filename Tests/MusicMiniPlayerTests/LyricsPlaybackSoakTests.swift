import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Long-play SOAK — fake clocks, hours of playlist, bounded-growth proxies.
//
// No real wall-clock hours: the playback clock and the surface wall clock
// are injected (`debugPlaybackClockDateProvider` / `debugNowOverride` /
// `debugTick`) and jumped. Assertions are deterministic proxies for the
// leak class: session-memo TTL prune, disk-cache entry cap + TTL, native
// surface mounted-row / visual-state / reuse-pool bounds, and the frame
// loop idle gate (paused interlude MUST allow the display link to stop).
//
// Headless. Founder rule 2026-08-21 + stress-gap plan 2026-08-25.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsPlaybackSoakTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []

    @MainActor
    override func tearDown() {
        hostedSurfaces.forEach { $0.stopAnimations() }
        hostedSurfaces.removeAll()
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    // ── Memory-cache TTL (session miss memo) ────────────────────────────────

    func test_sessionMemo_hoursOfUniqueTracks_prunesToZeroPastTTL() {
        let memo = LyricsMissMemo<String>(ttl: 1200)
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        for i in 0..<400 {
            memo.record("noLyrics", forKey: "soak-\(i)|artist|album", at: t0)
        }
        XCTAssertEqual(memo.entryCountForTesting(at: t0), 400, "all 400 live inside the TTL window")

        // 10 minutes later — still inside 20 min TTL.
        let tMid = t0.addingTimeInterval(600)
        XCTAssertEqual(memo.entryCountForTesting(at: tMid), 400)

        // 21 minutes later — every entry expired; prune-on-sight must empty the table
        // so a long session cannot accumulate stale keys (the leak proxy).
        let tExpired = t0.addingTimeInterval(21 * 60)
        XCTAssertEqual(memo.entryCountForTesting(at: tExpired), 0)
        XCTAssertNil(memo.confirmedMiss(forKey: "soak-0|artist|album", at: tExpired))
    }

    func test_sessionMemo_rollingWrites_stayBoundedAcrossSimulatedHours() {
        let memo = LyricsMissMemo<String>(ttl: 1200)
        var now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        // 6 hours of play, a new confirmed miss every 3 minutes = 120 writes,
        // but the live window is 20 min → at most ~7 keys live at once.
        for i in 0..<120 {
            memo.record("noLyrics", forKey: "roll-\(i)|a|al", at: now)
            now = now.addingTimeInterval(180)
            XCTAssertLessThanOrEqual(
                memo.entryCountForTesting(at: now),
                8,
                "TTL window is 20 min / 3 min cadence ⇒ ≤7 live; hour \(i / 20) leaked?"
            )
        }
    }

    // ── Disk cache: cap + TTL ───────────────────────────────────────────────

    func test_diskCache_overflowPrunesToMaxEntryCount() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soak-cap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cap = 18
        let cache = LyricsDiskCache(fileURL: url, maxEntryCount: cap)
        for i in 0..<80 {
            cache.set(
                title: "Soak Song \(i)",
                artist: "Artist \(i)",
                duration: TimeInterval(200 + i * 17),
                album: "Album \(i)",
                source: "LRCLIB",
                lines: [LyricLine(text: "line \(i)", startTime: 1, endTime: 2)],
                matchedDurationDiff: 0
            )
        }
        XCTAssertLessThanOrEqual(
            cache.entryCountForTesting(),
            cap,
            "disk memory must not grow past maxEntryCount across a long playlist"
        )
    }

    func test_diskCache_expiredTimestamps_arePrunedOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soak-ttl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = LyricsDiskCache(fileURL: url)
        cache.set(
            title: "Old Hit",
            artist: "Band",
            duration: 210,
            album: "LP",
            source: "NetEase",
            lines: [LyricLine(text: "aged line", startTime: 1, endTime: 2)],
            matchedDurationDiff: 0
        )
        XCTAssertGreaterThan(cache.entryCountForTesting(), 0)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(root["entries"] as? [String: [String: Any]])
        let aged = Date().timeIntervalSince1970 - LyricsDiskCache.ttlSeconds - 60
        for key in entries.keys {
            entries[key]?["ts"] = aged
        }
        root["entries"] = entries
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: url, options: [.atomic])

        // Fresh instance reloads the file and prunes on ensureLoaded.
        let reloaded = LyricsDiskCache(fileURL: url)
        XCTAssertNil(reloaded.get(title: "Old Hit", artist: "Band", duration: 210, album: "LP"))
        XCTAssertEqual(reloaded.entryCountForTesting(), 0, "TTL-expired rows must not survive a reload")
    }

    // ── Frame-loop idle gate (paused interlude must stop) ───────────────────

    func test_pausedInterludeAfterHours_allowsLoopStop() {
        // Proxy for "the display link is not still ticking at 60 Hz after a
        // long pause inside an interlude" — the defect-5 class. The veto list
        // is the production decision the renderer calls every tick.
        let vetoes = NativeLyricsLoopIdleDecision.vetoes(
            keepsAppearWindowAlive: false,
            hasPendingTapSettle: false,
            hasEngineMotion: false,
            hasVisualMotion: false,
            hasActiveTextAnimation: false,
            hasInterlude: true,
            hasDeferredDeactivation: false,
            isPlaying: false
        )
        XCTAssertTrue(vetoes.isEmpty, "paused + interlude + settled must allow the loop to stop: \(vetoes)")
    }

    func test_playingInterlude_keepsLoopAliveAcrossSoak() {
        XCTAssertEqual(
            NativeLyricsLoopIdleDecision.vetoes(
                keepsAppearWindowAlive: false,
                hasPendingTapSettle: false,
                hasEngineMotion: false,
                hasVisualMotion: false,
                hasActiveTextAnimation: false,
                hasInterlude: true,
                hasDeferredDeactivation: false,
                isPlaying: true
            ),
            ["interlude"]
        )
    }

    // ── Hosted surface: fast-forward a multi-hour playlist ──────────────────

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
    }

    private func makeRows(kind: Int, lineCount: Int) -> [LayerBackedLyricRow] {
        (0..<lineCount).map { i in
            let s = TimeInterval(i) * 2.0
            let e = s + 2.0
            let isPrelude = i == 0 && kind % 3 == 0
            let wordLevel = kind % 2 == 0 && !isPrelude
            let text = isPrelude ? "…" : "soak line \(i) words here"
            var words: [LyricWord] = []
            if wordLevel {
                let d = (e - s) / 3
                words = [
                    LyricWord(word: "soak ", startTime: s, endTime: s + d),
                    LyricWord(word: "line ", startTime: s + d, endTime: s + 2 * d),
                    LyricWord(word: "\(i)", startTime: s + 2 * d, endTime: e),
                ]
            }
            let lyric = LyricLine(text: text, startTime: s, endTime: e, words: words)
            let dl = DisplayLyricLine(id: "s\(kind)-\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: lyric)
            return LayerBackedLyricRow(
                id: dl.id, index: i, displayLine: dl, sourceLine: lyric,
                isPrelude: isPrelude, preludeEndTime: isPrelude ? e : e, interlude: nil
            )
        }
    }

    @MainActor
    private func config(
        _ rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        title: String,
        isPlaying: Bool,
        interludeAfterIndex: Int?
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        mc.isPlaying = isPlaying
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: rows.contains { $0.sourceLine.hasSyllableSync },
            trackContext: DiagnosticTrackContext(title: title, artist: "Soak", album: "Long Play", duration: 210),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: true, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: interludeAfterIndex,
            directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    @MainActor
    func test_hostedSurface_fastForwardHoursOfPlaylist_boundsDoNotGrow() {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 210
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 900_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        // 120 tracks × ~3 min ≈ 6 hours of "playlist". Per track: a handful of
        // injected ticks, a pause-in-interlude (loop must be allowed to stop),
        // then the next identity. Growth proxies sampled every track.
        let tracks = 120
        var maxMounted = 0
        var maxVisual = 0
        var maxPool = 0
        for n in 0..<tracks {
            let lineCount = 4 + (n % 16)
            let rows = makeRows(kind: n, lineCount: lineCount)
            let current = min(2, max(0, rows.count - 1))
            // Jump both clocks by a song duration so the soak covers hours
            // without riding the host run loop.
            wall += 180
            date = date.addingTimeInterval(180)
            mc.duration = 210
            mc.syncPlaybackClock(to: TimeInterval(current) * 2 + 0.4, playing: true, at: date)
            surface.configure(config(
                rows, current: current, mc: mc,
                title: "soak-track-\(n)", isPlaying: true, interludeAfterIndex: nil
            ))
            surface.layoutSubtreeIfNeeded()
            for step in 0..<8 {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                let t = TimeInterval(current) * 2 + 0.4 + TimeInterval(step) / 60.0
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }

            // Pause inside an interlude — the loop-idle gate must allow stop
            // (no 60 Hz leak after hours of this pattern).
            mc.syncPlaybackClock(to: TimeInterval(current) * 2 + 0.4, playing: false, at: date)
            surface.configure(config(
                rows, current: current, mc: mc,
                title: "soak-track-\(n)", isPlaying: false, interludeAfterIndex: current
            ))
            surface.debugTick(displayInterval: 1.0 / 60.0)
            XCTAssertTrue(
                NativeLyricsLoopIdleDecision.vetoes(
                    keepsAppearWindowAlive: false,
                    hasPendingTapSettle: false,
                    hasEngineMotion: false,
                    hasVisualMotion: false,
                    hasActiveTextAnimation: false,
                    hasInterlude: true,
                    hasDeferredDeactivation: false,
                    isPlaying: false
                ).isEmpty
            )

            maxMounted = max(maxMounted, surface.debugMountedRowCount)
            maxVisual = max(maxVisual, surface.debugVisualStateCount)
            maxPool = max(maxPool, surface.debugReusePoolCount)
            XCTAssertLessThanOrEqual(surface.debugMountedRowCount, lineCount + 4, "track \(n)")
            XCTAssertLessThanOrEqual(surface.debugVisualStateCount, lineCount + 4, "track \(n)")
            XCTAssertLessThanOrEqual(surface.debugReusePoolCount, 80, "track \(n)")
        }

        XCTAssertLessThanOrEqual(maxMounted, 24, "mounted rows must stay in the visible-radius ballpark across 6h")
        XCTAssertLessThanOrEqual(maxVisual, 24, "visualStates must be filtered to the current track's rows")
        XCTAssertLessThanOrEqual(maxPool, 80, "reuse pool hard cap")
    }
}
