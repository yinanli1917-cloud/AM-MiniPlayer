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

    // MARK: - Round 3 (coordinator 2026-09-14, final round on this item): jittered
    // ScriptingBridge-shaped clock
    //
    // Rounds 1-2 above used MusicController(preview: true)'s clean Date()-interpolated
    // lyricRenderTime() — real CVDisplayLink, real wall clock, but never the real SB-polling
    // clock's jitter/backward-correction path. This round drives the SAME real CVDisplayLink +
    // real wall-clock surface with a SYNTHETIC poll loop shaped like real ScriptingBridge
    // polling, reusing the REAL production policy function (not a reimplementation):
    // `PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(drift:readLatency:)`
    // — the exact rule that gates whether a slow/noisy poll is allowed to move the clock at all
    // in production (MusicController.swift:1841-1850). Shape, every ~2 real seconds:
    //   - a simulated SB read takes 0.1-0.4s (readLatency) to "land"; the value it carries
    //     reflects the true song position AS OF WHEN THE READ STARTED (staleness = readLatency),
    //     matching the 2026-07-17 postmortem's own model ("drift equalled the read latency, i.e.
    //     pure measurement staleness" — PlaybackClockTrustTests.swift's header comment);
    //   - the poll is only allowed to move `mc`'s clock (via syncPlaybackClock) when the REAL
    //     trust policy says so — small/noisy corrections from a slow read are suppressed exactly
    //     as production suppresses them, so this cannot fabricate a discontinuity production's
    //     own gate would have blocked;
    //   - one exact replay of the 2026-07-17 21:55:22 log event (sbRead=743.5ms, matching
    //     drift≈-0.58s) is injected once per song as a direct "jitter sample", per the
    //     coordinator's suggestion;
    //   - one deliberate 1-3s forward jump (late track discovery / seek landing) and one
    //     pause-then-resume are injected once per song.
    // Seed-point method (coordinator-approved): rather than playing each song start-to-finish in
    // real time (357s for the worst case), the real jittered clock is seeded a few seconds before
    // each near-zero-gap transition flagged in the earlier data-level check and run just long
    // enough (7 real seconds, ~3 real poll cycles) to cross it — covering ALL 25 such transitions
    // in "How's about your company" and all 8 in 大橋純子's track (its total; "at least 25" isn't
    // reachable there since the song only has 8 — covered exhaustively instead, noted in the
    // report).
    private struct JitteredCaptureEvent {
        let seedSongTime: TimeInterval
        let sampleT: TimeInterval
        let kind: String   // "poll_trusted" | "poll_suppressed" | "forward_jump" | "pause" | "resume"
        let polledPosition: TimeInterval?
        let readLatencyMs: TimeInterval?
        let drift: TimeInterval?
    }

    @MainActor
    private func runJitteredSeedSweep(
        song: CachedSong,
        seedTimes: [TimeInterval],
        lookback: TimeInterval,
        perSeedRealDuration: TimeInterval,
        slug: String
    ) -> (wholeLineFlashFrames: Int, events: [JitteredCaptureEvent]) {
        let rows = song.lines.enumerated().map { row(for: $1, index: $0) }
        let panelWidth: CGFloat = 360
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }

        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = song.duration
        mc.isPlaying = true

        let path = "\(Self.outDir)/wholeline-flash-jittered-\(slug).jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            XCTFail("could not open \(path) for writing")
            return (0, [])
        }
        defer { try? handle.close() }

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

        var totalFlashes = 0
        var allEvents: [JitteredCaptureEvent] = []

        for (seedIndex, seedTime) in seedTimes.enumerated() {
            let startSongTime = max(0, seedTime - lookback)
            mc.isPlaying = true
            mc.syncPlaybackClock(to: startSongTime, playing: true)
            lastConfiguredIndex = -1
            _ = reconfigureIfNeeded(songTime: startSongTime)

            // Independent "true" song-time reference this seed's polls sample from — mc's OWN
            // clock is what we are perturbing, so it cannot also be the ground truth.
            var trueAnchorDate = Date()
            var trueAnchorTime = startSongTime
            var truePlaying = true
            func trueSongTime(at date: Date) -> TimeInterval {
                truePlaying ? trueAnchorTime + date.timeIntervalSince(trueAnchorDate) : trueAnchorTime
            }

            var nextPollAt = Date().addingTimeInterval(2.0)
            var pendingPollStart: Date?
            var pendingPollReadLatency: TimeInterval = 0
            var pendingPollGroundTruth: TimeInterval = 0
            var injectedHistoricalReplay = false
            var injectedForwardJump = false
            var injectedPause = false
            var pauseResumeAt: Date?

            let startWall = Date()
            var sampledFrames = 0
            let expectation = XCTestExpectation(description: "jittered seed \(seedIndex) \(slug)")
            let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
                let now = Date()
                let elapsed = now.timeIntervalSince(startWall)

                // Deliberate one-shot pause/resume, seed 0 only, roughly mid-window.
                if seedIndex == 0, !injectedPause, elapsed >= perSeedRealDuration * 0.4 {
                    injectedPause = true
                    truePlaying = false
                    mc.isPlaying = false
                    mc.syncPlaybackClock(to: trueSongTime(at: now), playing: false, at: now)
                    pauseResumeAt = now.addingTimeInterval(1.2)
                    allEvents.append(JitteredCaptureEvent(
                        seedSongTime: seedTime, sampleT: elapsed, kind: "pause",
                        polledPosition: nil, readLatencyMs: nil, drift: nil))
                }
                if let resumeAt = pauseResumeAt, now >= resumeAt {
                    pauseResumeAt = nil
                    trueAnchorDate = now
                    trueAnchorTime = trueSongTime(at: now)
                    truePlaying = true
                    mc.isPlaying = true
                    mc.syncPlaybackClock(to: trueAnchorTime, playing: true, at: now)
                    allEvents.append(JitteredCaptureEvent(
                        seedSongTime: seedTime, sampleT: elapsed, kind: "resume",
                        polledPosition: nil, readLatencyMs: nil, drift: nil))
                }

                // Deliberate one-shot 1-3s forward jump (late track discovery / seek landing),
                // seed 2 only.
                if seedIndex == 2, !injectedForwardJump, elapsed >= perSeedRealDuration * 0.5 {
                    injectedForwardJump = true
                    let jump = TimeInterval.random(in: 1...3)
                    trueAnchorTime = trueSongTime(at: now) + jump
                    trueAnchorDate = now
                    allEvents.append(JitteredCaptureEvent(
                        seedSongTime: seedTime, sampleT: elapsed, kind: "forward_jump",
                        polledPosition: trueAnchorTime, readLatencyMs: nil, drift: jump))
                }

                // Poll scheduling: a read is "in flight" for readLatency seconds, then lands.
                if pendingPollStart == nil, now >= nextPollAt {
                    let readLatency: TimeInterval
                    if seedIndex == 0, !injectedHistoricalReplay {
                        // Exact 2026-07-17 21:55:22 log replay (PlaybackClockTrustTests.swift):
                        // sbRead=743.5ms → drift=-0.58s.
                        readLatency = 0.7435
                        injectedHistoricalReplay = true
                    } else {
                        readLatency = TimeInterval.random(in: 0.1...0.4)
                    }
                    pendingPollStart = now
                    pendingPollReadLatency = readLatency
                    pendingPollGroundTruth = trueSongTime(at: now)
                    nextPollAt = now.addingTimeInterval(2.0)
                }
                if let pollStart = pendingPollStart, now.timeIntervalSince(pollStart) >= pendingPollReadLatency {
                    let measurementTime = now
                    let polledPosition = pendingPollGroundTruth
                    let interpolated = mc.lyricRenderTime(at: measurementTime)
                    let drift = polledPosition - interpolated
                    let trust = PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
                        drift: drift, readLatency: pendingPollReadLatency)
                    if trust {
                        mc.syncPlaybackClock(to: polledPosition, playing: mc.isPlaying, at: measurementTime)
                    }
                    allEvents.append(JitteredCaptureEvent(
                        seedSongTime: seedTime, sampleT: elapsed,
                        kind: trust ? "poll_trusted" : "poll_suppressed",
                        polledPosition: polledPosition,
                        readLatencyMs: pendingPollReadLatency * 1000, drift: drift))
                    pendingPollStart = nil
                }

                let idx = reconfigureIfNeeded(songTime: mc.lyricRenderTime(at: now))
                if let view = surface.debugRowView(forIndex: idx) {
                    sampledFrames += 1
                    let flash = view.debugLastWholeLineHighlight
                    if flash { totalFlashes += 1 }
                    let expected = view.debugLastMainExpectedProgress
                    let applied = view.debugLastMainAppliedProgress
                    let line = String(
                        format: "{\"seed\":%d,\"seedSongTime\":%.2f,\"t\":%.3f,\"rowIndex\":%d,\"wholeLineFlash\":%@,\"perRunSweep\":%@,\"expected\":%@,\"applied\":%@,\"wordIndex\":%d}\n",
                        seedIndex, seedTime, elapsed, idx,
                        flash ? "true" : "false",
                        view.debugLastAppliedActivePerRunSweep ? "true" : "false",
                        expected.map { String(format: "%.4f", $0) } ?? "null",
                        applied.map { String(format: "%.4f", $0) } ?? "null",
                        view.debugLastActiveWordIndex
                    )
                    if let data = line.data(using: .utf8) {
                        handle.write(data)
                    }
                }
                if elapsed >= perSeedRealDuration {
                    expectation.fulfill()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            wait(for: [expectation], timeout: perSeedRealDuration + 10)
            timer.invalidate()
            print("[JitteredSweep] \(slug) seed=\(seedIndex) seedSongTime=\(seedTime)s " +
                  "sampledFrames=\(sampledFrames)")
        }

        print("[JitteredSweep] \(slug): TOTAL seeds=\(seedTimes.count) " +
              "wholeLineFlashFrames=\(totalFlashes) jsonl=\(path)")
        return (totalFlashes, allEvents)
    }

    /// All 25 near-zero-gap ('How's about your company', 85 lines) transitions from the earlier
    /// data-level check, seeded 3 real/song seconds ahead, 7 real seconds each.
    @MainActor
    func test_jitteredSweep_fastest1_allNearZeroGapTransitions() throws {
        let song = try loadCachedSong(
            hash: "c0c6f4a109d7a3fa5f5b3a9d7a0b05804b717ddd6412a1bd180ef78f0398d0f7",
            label: "How's about your company this evenin'"
        )
        let seeds: [TimeInterval] = [
            65.4, 77.19, 79.44, 87.39, 96.54, 103.41, 121.14, 123.33, 131.31, 133.02,
            135.36, 136.5, 144.47, 151.5, 155.55, 159.48, 265.2, 271.35, 275.19, 276.99,
            279.27, 280.35, 288.33, 296.31, 336.3
        ]
        let result = runJitteredSeedSweep(
            song: song, seedTimes: seeds, lookback: 3, perSeedRealDuration: 7,
            slug: "fastest1-hows-about"
        )
        reportJitteredResult(slug: "fastest1-hows-about", result: result)
    }

    /// All 8 near-zero-gap transitions (大橋純子's track only has 8 total — "at least 25" isn't
    /// reachable here, covered exhaustively instead).
    @MainActor
    func test_jitteredSweep_oohashi_allNearZeroGapTransitions() throws {
        let song = try loadCachedSong(
            hash: "4ac42fd65a7f7f7dbcb7cac717cfceb9c79548627476d05eb62660b78204eacf",
            label: "大橋純子「水玉模様の傘」"
        )
        let seeds: [TimeInterval] = [36.34, 47.43, 63.54, 75.29, 102.79, 166.36, 170.69, 180.94]
        let result = runJitteredSeedSweep(
            song: song, seedTimes: seeds, lookback: 3, perSeedRealDuration: 7,
            slug: "oohashi-mizutama"
        )
        reportJitteredResult(slug: "oohashi-mizutama", result: result)
    }

    private func reportJitteredResult(
        slug: String,
        result: (wholeLineFlashFrames: Int, events: [JitteredCaptureEvent])
    ) {
        let pollCount = result.events.filter { $0.kind == "poll_trusted" || $0.kind == "poll_suppressed" }.count
        let suppressedCount = result.events.filter { $0.kind == "poll_suppressed" }.count
        let jumpCount = result.events.filter { $0.kind == "forward_jump" }.count
        print("[JitteredSweep] \(slug) SUMMARY: wholeLineFlashFrames=\(result.wholeLineFlashFrames) " +
              "polls=\(pollCount) suppressed=\(suppressedCount) forwardJumps=\(jumpCount)")
        if result.wholeLineFlashFrames > 0 {
            let flashSeedTimes = Set(result.events.map(\.seedSongTime))
            print("[JitteredSweep] \(slug) FLASH occurred — seeds involved: \(flashSeedTimes)")
        }
        XCTAssertGreaterThanOrEqual(result.wholeLineFlashFrames, 0) // observational — see report
    }
}
