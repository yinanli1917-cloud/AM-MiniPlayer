/**
 * [INPUT]: The real SnappablePanel hosting the real MiniPlayerView, the real
 *          LiquidEdgeController on a real display link, MusicController.shared
 *          (preview mode under XCTest), LyricsService, and EdgeHitchTrace.
 * [OUTPUT]: EdgeHitchHarness — drives collapse / peek / expand cycles while a
 *           playback load runs (10Hz position ticks while the panel is on
 *           screen, track changes with artwork and lyrics arriving, queue
 *           updates), and returns per-frame deadline statistics.
 * [POS]: Test fixture for the edge-animation stutter investigation
 *        (2026-10-01). A quiet harness hides intermittent stalls, so the load
 *        is part of the fixture, not an option.
 */

import XCTest
import AppKit
import SwiftUI
import QuartzCore
@testable import MusicMiniPlayerCore

/// Per-motion frame statistics from the production trace.
struct EdgeHitchReport {
    var frames: [EdgeHitchTrace.Entry] = []
    var turns: [EdgeHitchTrace.Entry] = []
    var cycles = 0

    /// Main-thread busy time of the turn carrying each frame, ms.
    var turnTimes: [Double] { frames.map(\.turnMs) }
    var misses: [EdgeHitchTrace.Entry] { frames.filter { $0.missMs > 0.5 } }
    var droppedFrames: Int {
        frames.reduce(0) { $0 + max(0, Int(($1.gapMs / max($1.nominalMs, 1)).rounded()) - 1) }
    }

    func percentile(_ p: Double, of v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    /// Every main-thread turn seen during a motion: those carrying a frame and the long ones without.
    var allTurns: [EdgeHitchTrace.Entry] { frames + turns }

    var summary: String {
        let t = turnTimes
        let maxMiss = misses.map(\.missMs).max() ?? 0
        let big = frames.filter { $0.missMs > Self.hitchMs }.count
        // CPU time is what OUR work cost: unlike wall time it does not include being
        // preempted by other processes or blocked on WindowServer, so it stays comparable
        // between runs on a busy machine.
        let cpu = allTurns.map(\.turnCpuMs)
        let over8 = cpu.filter { $0 > 8.3 }.count, over16 = cpu.filter { $0 > Self.hitchMs }.count
        return String(format: "cycles=%d frames=%d | turn wall ms: p50=%.2f p95=%.2f p99=%.2f max=%.2f | deadline misses=%d (>16.7ms: %d) worstMiss=%.1fms | dropped frames=%d | long turns without frame=%d\n  main-thread CPU per turn: p95=%.2f p99=%.2f max=%.2f | turns with CPU >8.3ms: %d, >16.7ms: %d",
                      cycles, frames.count, percentile(0.5, of: t), percentile(0.95, of: t), percentile(0.99, of: t), t.max() ?? 0,
                      misses.count, big, maxMiss, droppedFrames, turns.count,
                      percentile(0.95, of: cpu), percentile(0.99, of: cpu), cpu.max() ?? 0, over8, over16)
    }

    static let hitchMs = 16.7

    /// Wall time of every main-thread turn seen during a motion, ms.
    var allTurnWall: [Double] { allTurns.map(\.turnMs) }
    /// Time a turn spent not computing (turn wall minus main-thread CPU): WindowServer / render-server round trips.
    var blockedMs: [Double] { allTurns.map { max(0, $0.turnMs - $0.turnCpuMs) } }

    /// The numbers the quick-peek scenario is judged by.
    var turnReport: String {
        let w = allTurnWall, b = blockedMs
        return String(format: "turns=%d worstTurn=%.1fms turns>16.7ms=%d | blocked (turn-cpu): total=%.0fms worst=%.1fms turns blocked>8ms=%d | dropped frames=%d",
                      w.count, w.max() ?? 0, w.filter { $0 > Self.hitchMs }.count,
                      b.reduce(0, +), b.max() ?? 0, b.filter { $0 > 8 }.count, droppedFrames)
    }

    func byMotion() -> String {
        Dictionary(grouping: frames, by: \.motion).sorted { $0.key < $1.key }.map { kind, fs in
            let t = fs.map(\.turnMs)
            let miss = fs.filter { $0.missMs > 0.5 }.count
            return String(format: "  %-9@ frames=%4d p95=%.2f max=%.2f misses=%d", kind as NSString, fs.count, percentile(0.95, of: t), t.max() ?? 0, miss)
        }.joined(separator: "\n")
    }

    /// Every missed frame (and long turn) with what ran in it.
    var detail: String {
        let all = (frames.filter { $0.missMs > 8 || $0.turnMs > 9 } + turns).sorted { $0.wall < $1.wall }
        return all.map { EdgeHitchTrace.format($0) }.joined()
    }
}

@MainActor
final class EdgeHitchHarness {
    enum Page { case album, lyrics }

    let music = MusicController.shared
    private(set) var card: SnappablePanel!
    private(set) var controller: LiquidEdgeController!
    private var load: PlaybackLoad?
    private var report = EdgeHitchReport()
    private let savedPage: PlayerPage
    private let trace: EdgeHitchTrace

    init(page: Page, trace: EdgeHitchTrace = .shared) {
        self.trace = trace
        savedPage = music.currentPage
        music.currentPage = page == .lyrics ? .lyrics : .album

        let size = PanelWindowMetrics.defaultSize
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        card = SnappablePanel(contentRect: NSRect(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16, width: size.width, height: size.height),
                              styleMask: PanelWindowMetrics.styleMask, backing: .buffered, defer: false)
        card.isFloatingPanel = true
        card.level = .floating
        card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        card.backgroundColor = .clear
        card.isOpaque = false
        card.hasShadow = true
        card.titlebarAppearsTransparent = true
        card.titleVisibility = .hidden
        card.hidesOnDeactivate = false
        card.acceptsMouseMovedEvents = true
        let root = MiniPlayerView().environmentObject(music).environmentObject(EdgePresentationModel())
        card.contentView = PanelWindowMetrics.makeContentView(root: root)
        card.orderFront(nil)

        controller = LiquidEdgeController(card: card)
        controller.onPanelOccluded = { [weak self] occluded in
            self?.music.setPanelOccluded(occluded)
            self?.load?.panelOccluded = occluded
        }
        // The real log, written where the benchmark says (never the founder's ~/Library/Logs).
        let logPath = ProcessInfo.processInfo.environment["NANOPOD_EDGE_HITCH_LOG"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("eh-harness/edge-hitch.log")
        trace.logURLOverride = URL(fileURLWithPath: logPath)
        trace.entrySink = { [weak self] e in
            guard let self else { return }
            switch e.kind {
            case .frame: self.report.frames.append(e)
            case .turn: self.report.turns.append(e)
            }
        }
    }

    func tearDown() {
        load?.stop(); load = nil
        trace.entrySink = nil
        trace.logURLOverride = nil
        controller.reset()
        controller.stageWindow?.orderOut(nil)
        controller.stageWindow?.contentView = nil
        card.orderOut(nil)
        card.contentView = nil   // drop the hosted MiniPlayerView: it observes the shared MusicController
        controller = nil
        card = nil
        music.setPanelOccluded(false)
        music.currentPage = savedPage
        music.isPlaying = false
    }

    // MARK: Driving

    func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @discardableResult
    func wait(timeout: Double = 4, until cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return cond()
    }

    private func settle() { wait { !self.controller.isAnimating } }

    /// One collapse -> hover peek -> retract -> hover -> click-expand round.
    /// Every third cycle also exercises the track-change auto-peek.
    func cycle(_ n: Int) {
        XCTAssertTrue(controller.collapse(to: .right), "cycle \(n): collapse refused")
        settle()
        spin(0.35)

        controller.hoverEntered()
        wait { self.controller.state == .floating && !self.controller.isAnimating }
        spin(0.4)
        controller.hoverExited()
        settle()
        spin(0.3)

        if n % 3 == 0 {
            // A track change while tucked: the capsule peeks on its own and retracts.
            load?.changeTrackNow()
            wait(timeout: 6) { self.controller.state == .floating && !self.controller.isAnimating }
            wait(timeout: 6) { self.controller.state == .tucked && !self.controller.isAnimating }
            spin(0.3)
        }

        controller.hoverEntered()
        wait { self.controller.state == .floating && !self.controller.isAnimating }
        spin(0.25)
        controller.expand()
        wait { self.controller.state == .card && !self.controller.isAnimating }
        spin(0.5)
        report.cycles += 1
    }

    /// The quick hover: the capsule floats out and the cursor leaves again after `stay` seconds, so the retract
    /// begins while whatever the float-out started is still settling.
    func quickPeekRound(stay: Double) {
        guard controller.state == .tucked else {
            XCTFail("quick peek round started in state \(controller.state)")
            return
        }
        controller.hoverEntered()
        wait(timeout: 3) { self.controller.state == .floating }
        spin(stay)
        controller.hoverExited()
        settle()
        spin(0.35)
    }

    /// floatOut -> leave after `stay` -> retract, `rounds` times, tucked and under the playback load.
    func runQuickPeek(rounds: Int, stay: Double = 0.15) -> EdgeHitchReport {
        report = EdgeHitchReport()
        load = PlaybackLoad(music: music)
        load?.start(trackTimer: false)
        spin(1.0)
        cycle(0) // warm-up
        controller.hoverExited()
        XCTAssertTrue(controller.collapse(to: .right))
        settle()
        XCTAssertEqual(controller.state, .tucked)
        spin(0.5)
        report = EdgeHitchReport()
        for _ in 0..<rounds { quickPeekRound(stay: stay); report.cycles += 1 }
        load?.stop()
        spin(0.2)
        trace.drainLogWrites()
        return report
    }

    /// The track-change auto-peek on its own: tucked and idle, the track changes (cover and
    /// lyrics arrive while the capsule comes out), the capsule holds, retracts.
    func autoPeekRound() {
        guard controller.state == .tucked else {
            XCTFail("auto-peek round started in state \(controller.state), isAnimating=\(controller.isAnimating)")
            return
        }
        spin(1.2)
        load?.changeTrackNow()
        wait(timeout: 6) { self.controller.state == .floating && !self.controller.isAnimating }
        wait(timeout: 8) { self.controller.state == .tucked && !self.controller.isAnimating }
        spin(0.6)
    }

    func runAutoPeek(rounds: Int) -> EdgeHitchReport {
        report = EdgeHitchReport()
        load = PlaybackLoad(music: music)
        load?.start(trackTimer: false) // the rounds change the track themselves
        spin(1.0)
        cycle(0) // warm-up
        controller.hoverExited() // the cycle ended with the pointer still "on" the capsule
        XCTAssertTrue(controller.collapse(to: .right))
        settle()
        XCTAssertEqual(controller.state, .tucked)
        report = EdgeHitchReport()
        for _ in 0..<rounds { autoPeekRound(); report.cycles += 1 }
        load?.stop()
        spin(0.2)
        trace.drainLogWrites()
        return report
    }

    func run(cycles: Int, withLoad: Bool = true) -> EdgeHitchReport {
        report = EdgeHitchReport()
        if withLoad { load = PlaybackLoad(music: music) }
        load?.start()
        spin(1.0) // let the hosted views settle before measuring
        cycle(0) // warm-up: first-use costs (XPC connections, font and shader caches) are not recurring hitches
        report = EdgeHitchReport()
        for n in 1...cycles { cycle(n) }
        load?.stop()
        spin(0.2)
        trace.drainLogWrites()
        return report
    }
}

/// What the player does to the main thread while the panel animates.
@MainActor
final class PlaybackLoad {
    private let music: MusicController
    private var timers: [Timer] = []
    private var playhead: TimeInterval = 40
    private var trackIndex = 0
    private let jpeg: [Data]
    /// Mirrors MusicController's own flag (the 10Hz clock stops while the panel is off screen).
    var panelOccluded = false

    init(music: MusicController) {
        self.music = music
        // Real covers arrive as encoded data and decode lazily on first use.
        jpeg = (0..<4).map { Self.makeJPEG(side: 1000, seed: $0) }
    }

    func start(trackTimer: Bool = true) {
        music.isPlaying = true
        music.duration = 215
        installLyrics()
        // The 10Hz playback clock (interpolateTime): runs only while the panel is on screen.
        add(0.1) { [self] in
            guard music.isPlaying, !panelOccluded else { return }
            playhead += 0.1
            music.currentTime = playhead
            music.lyricsService.updateCurrentTime(playhead)
        }
        // The 2s position poll applies its result on main.
        add(2.0) { [self] in music.currentTime = playhead }
        // Track changes on their own cadence, unaligned with the test's cycles.
        if trackTimer { add(7.3) { [self] in changeTrackNow() } }
    }

    func stop() { timers.forEach { $0.invalidate() }; timers = [] }

    private func add(_ interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let t = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    /// What a notification-driven track change does on main: published track
    /// fields at once, lyrics a moment later, the cover when it has downloaded.
    func changeTrackNow() {
        trackIndex += 1
        let i = trackIndex
        music.currentPersistentID = "load-\(i)"
        music.currentTrackTitle = "Load Track \(i)"
        music.currentArtist = "Load Artist \(i % 5)"
        music.currentAlbum = "Load Album \(i)"
        music.duration = 200 + Double(i % 40)
        playhead = 0
        music.currentTime = 0
        music.recentTracks = (0..<20).map { (title: "Recent \(i)-\($0)", artist: "Artist", album: "Album", persistentID: "r\(i)-\($0)", duration: 200) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            MainActor.assumeIsolated { installLyrics() }
        }
        // The cover arrives from a fetch task off the main thread, which hands it over the way
        // the production fetch sites do (decoded for display there, see makeDisplayArtwork).
        let data = jpeg[i % jpeg.count]
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard let fetched = NSImage(data: data) else { return }
            let image = ArtworkDisplayImageFactory.makeDisplayArtwork(from: fetched)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { music.setArtwork(image) }
            }
        }
    }

    private func installLyrics() {
        var lines: [LyricLine] = []
        for i in 0..<60 {
            let start = Double(i) * 3.2
            let translation: String? = i % 2 == 0 ? "合成歌词第 \(i) 行" : nil
            lines.append(LyricLine(text: "Synthetic lyric line number \(i) with a few words to wrap maybe",
                                   startTime: start, endTime: start + 3.0, translation: translation))
        }
        let title = music.currentTrackTitle, artist = music.currentArtist, album = music.currentAlbum
        music.lyricsService.applyLyrics(
            lines, firstRealLyricIndex: 0, hasSourceTranslation: false, isUnsynced: false,
            songID: "\(title)|\(artist)|\(album)|215", title: title, artist: artist,
            stableSongID: "\(title)|\(artist)",
            duration: 215, album: album)
        music.lyricsService.updateCurrentTime(playhead)
    }

    /// A JPEG with real detail (random-walk colour blocks), like a store cover.
    static func makeJPEG(side: Int, seed: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let px = rep.bitmapData!
        let bpr = rep.bytesPerRow
        for y in 0..<side {
            for x in 0..<side {
                let n = Int.random(in: 0...30, using: &rng)
                let o = y * bpr + x * 4
                px[o] = UInt8(min(255, 40 + (x * 200 / side) + n + seed * 20))
                px[o + 1] = UInt8(min(255, 60 + (y * 180 / side) + n))
                px[o + 2] = UInt8(min(255, 90 + ((x ^ y) & 63) + n))
                px[o + 3] = 255
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }
}
