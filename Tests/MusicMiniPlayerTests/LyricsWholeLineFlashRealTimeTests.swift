import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Real-time (non-lockstep) reproduction harness for the founder-reported
// "整行全亮" (whole-line-flash) defect (message A, 2026-09-14 follow-up to
// stage bundle 2). Every lockstep/debugTick attempt this session and WT-B's
// (0 occurrences across 7 songs) found nothing — the founder's conclusion is
// that lockstep itself drops a real-runtime condition, so this harness
// deliberately does NOT use debugNowOverride / debugTick:
//   - The surface's own CVDisplayLink runs for real (never stopped/faked),
//     driving updatePlaybackPhase every real display frame via
//     presentationTick → updateTextPhasesForCurrentConfiguration.
//   - MusicController's playback clock is never given debugPlaybackClockDateProvider,
//     so lyricRenderTime() falls through to real Date() — a genuinely
//     continuous 1x real-time clock (MusicController.swift:495-503), not a
//     frame-jumped fake one.
//   - Each song plays at real pace for real wall-clock seconds (founder:
//     60-120s; 60s used here — the floor of that range — per song to keep
//     4 songs inside one bounded test run; see the report for why a longer
//     per-song window was not attempted this round).
//
// Every ~50ms of REAL time (20Hz — a deliberate sampling-loop compromise:
// genuinely regular and non-lockstep as required, not literally every 60Hz
// display frame, to keep 4×60s of JSONL data tractable; noted transparently
// in the report rather than silently claimed as "every frame"), this samples
// the currently text-active row's debugLastWholeLineHighlight / expected vs
// applied sweep progress / per-run-sweep flag and appends one JSON line to
// research/repro-2026-09-14-lyrics-render/wholeline-flash-realtime-<slug>.jsonl.
//
// Headless (offscreen alpha-0 NSWindow), no computer use, no screen
// recording (founder rule 2026-08-21) — "real-time" here means the real
// CVDisplayLink/wall clock, not a human watching the screen.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsWholeLineFlashRealTimeTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
    }

    // MARK: - Real cache loading

    private struct CachedSong {
        let hash: String
        let label: String
        let duration: TimeInterval
        let lines: [LyricLine]
    }

    /// Reads the REAL production lyrics cache (read-only) and extracts one entry by hash. No
    /// fixture data — the founder specifically asked for the real cached tracks (大橋純子's
    /// "水玉模様の傘" + the 3 fastest-average-syllable-duration syllable-synced entries),
    /// identified during this session's prep pass and documented in the report.
    private func loadCachedSong(hash: String, label: String) throws -> CachedSong {
        let path = ("~/Library/Application Support/nanoPod/lyrics_cache.json" as NSString)
            .expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let entries = root?["entries"] as? [String: Any],
              let entry = entries[hash] as? [String: Any],
              let rawLines = entry["lines"] as? [[String: Any]]
        else {
            throw XCTSkip("hash \(hash) (\(label)) not found in the real lyrics cache — cache may have been pruned/rewritten since prep")
        }
        let duration = (entry["duration"] as? Double) ?? (rawLines.last?["endTime"] as? Double ?? 0)
        let lines: [LyricLine] = rawLines.map { raw in
            let start = raw["startTime"] as? Double ?? 0
            let end = raw["endTime"] as? Double ?? start
            let text = raw["text"] as? String ?? ""
            let translation = raw["translation"] as? String
            let words: [LyricWord] = (raw["words"] as? [[String: Any]] ?? []).map { w in
                LyricWord(
                    word: w["word"] as? String ?? "",
                    startTime: w["startTime"] as? Double ?? start,
                    endTime: w["endTime"] as? Double ?? end
                )
            }
            return LyricLine(text: text, startTime: start, endTime: end, words: words, translation: translation)
        }
        return CachedSong(hash: hash, label: label, duration: duration, lines: lines)
    }

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(
        rows: [LayerBackedLyricRow],
        current: Int,
        mc: MusicController,
        width: CGFloat,
        heights: [Int: CGFloat]
    ) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "RealTime", artist: "A", album: "Al", duration: mc.duration),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: false,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    private static let outDir: String = {
        let dir = "research/repro-2026-09-14-lyrics-render"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Plays one real cached song at real 1x pace for `realDuration` real wall-clock seconds,
    /// sampling every ~50ms, and writes the result as JSONL. Returns the count of frames where
    /// debugLastWholeLineHighlight was true (the whole-line-flash signal) for the caller to log.
    @MainActor
    @discardableResult
    private func runRealTimeCapture(
        song: CachedSong,
        realDuration: TimeInterval,
        slug: String,
        startAt: TimeInterval = 0,
        sampleInterval: TimeInterval = 0.05
    ) -> Int {
        let rows = song.lines.enumerated().map { row(for: $1, index: $0) }
        let panelWidth: CGFloat = 360
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = song.duration
        mc.isPlaying = true
        // No debugNowOverride, no debugPlaybackClockDateProvider anywhere in this test — the
        // surface's CVDisplayLink and MusicController's lyricRenderTime() both run on the REAL
        // wall clock for the whole capture. This is the entire point of this harness. `startAt`
        // seeds the song-time anchor (still via the real Date() below) so a targeted capture can
        // reach a specific real-data-flagged transition without needing the full song length.
        mc.syncPlaybackClock(to: startAt, playing: true)

        var lastConfiguredIndex = -1
        func reconfigureIfNeeded(songTime: TimeInterval) -> Int {
            let idx = min(
                max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: songTime, rows: rows, fallback: 0)),
                max(0, rows.count - 1)
            )
            if idx != lastConfiguredIndex {
                surface.configure(config(rows: rows, current: idx, mc: mc, width: panelWidth, heights: heights))
                surface.layoutSubtreeIfNeeded()
                lastConfiguredIndex = idx
            }
            return idx
        }
        _ = reconfigureIfNeeded(songTime: startAt)

        let path = "\(Self.outDir)/wholeline-flash-realtime-\(slug).jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            XCTFail("could not open \(path) for writing")
            return 0
        }
        defer { try? handle.close() }

        let startWall = Date()
        var wholeLineFlashFrames = 0
        var sampledFrames = 0
        let expectation = XCTestExpectation(description: "real-time capture \(slug)")
        let timer = Timer(timeInterval: sampleInterval, repeats: true) { _ in
            let elapsed = Date().timeIntervalSince(startWall)
            let idx = reconfigureIfNeeded(songTime: startAt + elapsed)
            guard let view = surface.debugRowView(forIndex: idx) else { return }
            sampledFrames += 1
            let flash = view.debugLastWholeLineHighlight
            if flash { wholeLineFlashFrames += 1 }
            let expected = view.debugLastMainExpectedProgress
            let applied = view.debugLastMainAppliedProgress
            let line = String(
                format: "{\"t\":%.3f,\"rowIndex\":%d,\"wholeLineFlash\":%@,\"perRunSweep\":%@,\"expected\":%@,\"applied\":%@,\"wordIndex\":%d}\n",
                elapsed, idx,
                flash ? "true" : "false",
                view.debugLastAppliedActivePerRunSweep ? "true" : "false",
                expected.map { String(format: "%.4f", $0) } ?? "null",
                applied.map { String(format: "%.4f", $0) } ?? "null",
                view.debugLastActiveWordIndex
            )
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            if elapsed >= realDuration {
                expectation.fulfill()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        wait(for: [expectation], timeout: realDuration + 15)
        timer.invalidate()

        print("[WholeLineFlashRealTime] \(slug): sampledFrames=\(sampledFrames) " +
              "wholeLineFlashFrames=\(wholeLineFlashFrames) realDuration=\(realDuration)s " +
              "startAt=\(startAt)s lines=\(rows.count) jsonl=\(path)")
        return wholeLineFlashFrames
    }

    // MARK: - Targeted real-time windows around data-flagged near-zero-gap transitions
    //
    // The 4 whole-song 60s captures below only reach the first ~3-8 lines of each song in real
    // time (60s of real 1x playback simply doesn't cover an 85-line, 357s track) — a genuine
    // coverage gap, not a null result. Before spending several more real minutes per song on full
    // coverage, a direct DATA-LEVEL check of the real cached line timestamps (independent of any
    // runtime capture) found concrete near-zero/negative gaps between ADJACENT lines — hypothesis
    // ①'s precondition — most densely in "How's about your company" (25 of 84 line-to-line gaps
    // < 0.05s; see the report). These two targeted captures seed the real playback clock a few
    // seconds BEFORE one of those flagged transitions (still via the real Date()-based clock —
    // startAt only changes WHERE real-time playback begins, not how it advances) so a short real
    // capture directly covers the highest-suspicion moments instead of hoping a blind 60s window
    // happens to reach them.

    /// fastest1 index 8→9 ('Cause the rhythm keeps i.../What do you say now?, gap≈0.03s at
    /// t≈77.16s) plus index 4's transition (gap≈0.03s at t≈63.36s) both fall inside this window.
    @MainActor
    func test_realTime_fastest1_targetedNearZeroGapWindow() throws {
        let song = try loadCachedSong(
            hash: "c0c6f4a109d7a3fa5f5b3a9d7a0b05804b717ddd6412a1bd180ef78f0398d0f7",
            label: "How's about your company this evenin'"
        )
        let flashes = runRealTimeCapture(
            song: song, realDuration: 22, slug: "fastest1-targeted-nearzero",
            startAt: 60, sampleInterval: 0.02
        )
        XCTAssertGreaterThanOrEqual(flashes, 0)
    }

    /// oohashi index 15→16 (exact 0.0s gap at t=166.36s) — the largest single anomaly found in
    /// the data check (line 15 is also itself a 39s-long anomalous English line embedded in an
    /// otherwise all-Japanese YRC track; flagged separately in the report as a possible unrelated
    /// data-quality issue, not chased down here).
    @MainActor
    func test_realTime_oohashi_targetedZeroGapWindow() throws {
        let song = try loadCachedSong(
            hash: "4ac42fd65a7f7f7dbcb7cac717cfceb9c79548627476d05eb62660b78204eacf",
            label: "大橋純子「水玉模様の傘」"
        )
        let flashes = runRealTimeCapture(
            song: song, realDuration: 15, slug: "oohashi-targeted-zerogap",
            startAt: 160, sampleInterval: 0.02
        )
        XCTAssertGreaterThanOrEqual(flashes, 0)
    }

    // MARK: - The 4 founder-specified songs

    /// 大橋純子「水玉模様の傘」— the song the founder's 09-12 recording spec names directly
    /// (Symptom 2, frame f1053). 23 lines, real per-character YRC timestamps, duration 225s —
    /// matches the founder's cache description exactly (see report prep-status section).
    @MainActor
    func test_realTime_oohashiJunko_mizutamaMoyouNoKasa() throws {
        let song = try loadCachedSong(
            hash: "4ac42fd65a7f7f7dbcb7cac717cfceb9c79548627476d05eb62660b78204eacf",
            label: "大橋純子「水玉模様の傘」"
        )
        let flashes = runRealTimeCapture(song: song, realDuration: 60, slug: "oohashi-mizutama")
        XCTAssertGreaterThanOrEqual(flashes, 0) // observational — see report for verdict
    }

    /// Fastest cached syllable-synced track (avg 0.406s/syllable, 449 syllables, 85 lines).
    @MainActor
    func test_realTime_fastest1_howsAboutYourCompany() throws {
        let song = try loadCachedSong(
            hash: "c0c6f4a109d7a3fa5f5b3a9d7a0b05804b717ddd6412a1bd180ef78f0398d0f7",
            label: "How's about your company this evenin'"
        )
        let flashes = runRealTimeCapture(song: song, realDuration: 60, slug: "fastest1-hows-about")
        XCTAssertGreaterThanOrEqual(flashes, 0)
    }

    /// 2nd fastest (avg 0.430s/syllable, 310 syllables, 39 lines).
    @MainActor
    func test_realTime_fastest2_shengFenDe() throws {
        let song = try loadCachedSong(
            hash: "2e9d901f619400b35ffb8af96914a419b6334812329bde244755ca32d5bdef1f",
            label: "生份的 遥远的歹势细腻"
        )
        let flashes = runRealTimeCapture(song: song, realDuration: 60, slug: "fastest2-shengfende")
        XCTAssertGreaterThanOrEqual(flashes, 0)
    }

    /// 3rd fastest (avg 0.446s/syllable, 236 syllables, 27 lines).
    @MainActor
    func test_realTime_fastest3_rengRanJiDe() throws {
        let song = try loadCachedSong(
            hash: "9e95e15c0d104cbfffda520dbd5af4a8e4180ee2d9c16f9e3db8351e833d7c8b",
            label: "仍然记得个一次 风里相依"
        )
        let flashes = runRealTimeCapture(song: song, realDuration: 60, slug: "fastest3-rengranjide")
        XCTAssertGreaterThanOrEqual(flashes, 0)
    }
}
