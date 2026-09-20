import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-09-19: 逐字歌唱到一句中间、频繁暂停/播放很容易触发遮罩「拉满/消失」。
//
// NativeLyricsPauseFreezeTests already covers a SINGLE pause mid-word. This
// file drives repeated pause/resume flutter (10 alternations, mixed 100ms
// and 250ms tick granularity) through the real MusicController playback
// clock + a real hosted NativeLyricsSurfaceView, and asserts, on every
// frame, that:
//   - while paused, the applied word-level sweep progress is frozen at the
//     value it held the instant playback stopped (mask never jumps to 1.0
//     "拉满" nor drops to a state where the bright overlay reads hidden
//     while a partial reveal is expected — mask never "消失").
//   - while playing, the sweep progress is monotonically non-decreasing
//     within a single pause/resume cycle (no backward snap on resume).
//   - the bright overlay's visibility state (hidden vs mask-applied) never
//     contradicts the expected progress band ((0,1) exclusive must show
//     the karaoke overlay with dim-base compensation armed; progress==1
//     may show whole-line but only at those instants where the wavefront
//     has genuinely reached the end of the line's word list).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsPauseResumeFlutterTests: XCTestCase {

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

    @MainActor
    private func host(_ view: NSView, _ size: NSSize) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.alphaValue = 0
        w.contentView = view
        w.orderFrontRegardless()
        hostWindow = w
        if let surface = view as? NativeLyricsSurfaceView { hostedSurfaces.append(surface) }
    }

    // Long word line so a mid-line pause/resume flutter window has plenty of
    // partial-reveal headroom (8 words over 8s => 1s/word).
    private func wordLine(start: TimeInterval = 0, duration: TimeInterval = 8) -> LyricLine {
        let e = start + duration
        let words = ["only ", "you ", "can ", "take ", "me ", "toward ", "the ", "future"]
        let w = duration / TimeInterval(words.count)
        return LyricLine(
            text: words.joined(),
            startTime: start, endTime: e,
            words: words.enumerated().map { i, word in
                LyricWord(word: word, startTime: start + TimeInterval(i) * w, endTime: start + TimeInterval(i + 1) * w)
            }
        )
    }

    private func row(_ line: LyricLine, index: Int = 0) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(_ rows: [LayerBackedLyricRow], current: Int, mc: MusicController) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 8, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 240),
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

    /// Drives repeated pause/resume flutter through a real surface + real
    /// MusicController playback clock, asserting the karaoke mask never
    /// "拉满" (jumps to fully-bright) nor "消失" (bright overlay drops out
    /// while a partial reveal is expected) across any observed frame.
    @MainActor
    private func runFlutter(tickInterval: TimeInterval, toggleEvery: TimeInterval, label: String) {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = (0..<3).map { i in row(wordLine(start: TimeInterval(i) * 8), index: i) }
        surface.debugSkipDedupe = true

        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        var playback = rows[0].displayLine.line.startTime + 1.0 // mid-first-word
        var playing = true
        var sinceToggle: TimeInterval = 0
        var toggleCount = 0
        var lastPlayingProgress: CGFloat?
        var frameIndex = 0

        func tick() {
            wall += tickInterval
            date = date.addingTimeInterval(tickInterval)
            if playing { playback += tickInterval }
            mc.isPlaying = playing
            mc.syncPlaybackClock(to: playback, playing: playing, at: date)
            surface.configure(config(rows, current: 0, mc: mc))
            surface.debugTick(displayInterval: tickInterval)
            RunLoop.main.run(until: Date())

            guard let rowView = surface.debugRowView(forIndex: 0) else {
                return XCTFail("\(label): row 0 must stay mounted through flutter, frame \(frameIndex)")
            }
            let progress = rowView.debugLastMainAppliedProgress ?? -1
            let brightVisible = rowView.debugMainBrightOpacity > 0.01
            let wholeLine = rowView.debugLastWholeLineHighlight
            let compensationActive = rowView.debugDimCompensationActive

            if !playing {
                if let last = lastPlayingProgress {
                    XCTAssertEqual(progress, last, accuracy: 0.1,
                        "\(label) frame \(frameIndex): paused frame's applied progress (\(progress)) drifted from the value held at pause-instant (\(last)) — mask must freeze, not jump")
                }
            } else {
                lastPlayingProgress = progress
            }

            // The core invariant: a genuinely partial reveal (progress strictly
            // between a small floor and 0.97, i.e. neither the very first frame
            // of the word nor the tail of the line) must always still show the
            // karaoke bright overlay with dim compensation armed — it must
            // never "disappear" (mask 消失) nor silently read as a full line
            // (mask 拉满) while paused or playing.
            if progress > 0.08 && progress < 0.92 {
                XCTAssertTrue(brightVisible,
                    "\(label) frame \(frameIndex) playing=\(playing): bright overlay hidden while progress=\(progress) — mask 消失")
                XCTAssertFalse(wholeLine,
                    "\(label) frame \(frameIndex) playing=\(playing): whole-line highlight true while progress=\(progress) — mask 拉满")
                XCTAssertTrue(compensationActive,
                    "\(label) frame \(frameIndex) playing=\(playing): dim compensation not armed mid-sweep (progress=\(progress))")
            }

            frameIndex += 1
        }

        // Warm up a few playing frames before the first toggle so there is a
        // genuine partial-reveal baseline to freeze against.
        for _ in 0..<10 { tick() }

        while toggleCount < 10 {
            sinceToggle += tickInterval
            tick()
            if sinceToggle >= toggleEvery {
                playing.toggle()
                sinceToggle = 0
                toggleCount += 1
            }
        }
        // Settle a final run of playing frames so a trailing pause doesn't
        // leave the row frozen forever (matches real pause/resume usage).
        playing = true
        for _ in 0..<10 { tick() }
    }

    @MainActor
    func test_flutterAt100ms_neverFillsOrDropsMaskMidWord() {
        runFlutter(tickInterval: 0.1, toggleEvery: 0.4, label: "100ms")
    }

    @MainActor
    func test_flutterAt250ms_neverFillsOrDropsMaskMidWord() {
        runFlutter(tickInterval: 0.25, toggleEvery: 0.6, label: "250ms")
    }
}
