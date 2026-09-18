import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder defect #3 follow-up (2026-09-18): "强调词尤其 CJK 还是重影的方式实现的" — the
// CJK trailing-word ghost fix (59647e1, on top of research/repro-2026-09-17-lyrics-render-3c.md
// §CJK) closed the specific rasterization-vs-text-phase race that was PROVEN in that round, but
// the founder still sees a doubled/ghosted glyph on real playback.
//
// Two deliverables here, both explicitly scoped as "report, do not fix" (the founder has not
// seen fresh real-machine evidence since 59647e1 landed, so a blind further change here would
// violate the project's "先复现再修" rule):
//
// 1. `NativeLyricsRowDump` / `nanopod://debug/rowdump` (Sources/MusicMiniPlayerCore/Utils/
//    NativeLyricsRowDump.swift, wired in MusicMiniPlayerAppKit/MusicMiniPlayerApp.swift) — an
//    on-demand, release-usable dump of the active + previous row's visible text sublayers
//    (class, frame, opacity, string prefix, whether contents is a rasterized bitmap,
//    shouldRasterize, transform) to /tmp/nanopod_rowdump.txt, so the founder can capture exact
//    evidence the moment they see a ghost on their own machine.
//
// 2. This test: drives the SAME real CJK word-level fixture the 3c investigation and 59647e1's
//    own regression test used (8 lines, row 6 = "爱愁思心碎滋味", trailing word "滋味") through
//    the SAME real-time window that investigation identified (t≈13.85-14.10, the row settling
//    from blurred/inactive into active sweep), and captures `rowDumpLines()` output at each
//    sampled tick — the exact artifact a founder-triggered `nanopod://debug/rowdump` would
//    produce, but automated and archived here instead of requiring a real machine.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class LyricsRenderDefects20260918RowDumpTests: XCTestCase {
    private var hostWindow: NSWindow?
    @MainActor override func tearDown() { hostWindow?.orderOut(nil); hostWindow = nil; super.tearDown() }

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

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                    isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 1.5, hasSyllableSync: true,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 60),
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

    /// Same 8-row CJK fixture as NativeLyricsRasterizationSignatureTests' own CJK ghost repro:
    /// row 6 ends with the trailing word "滋味" — the exact case the founder's screenshot named.
    private func cjkRows() -> [LayerBackedLyricRow] {
        let texts: [[String]] = [
            ["这", "是", "第", "一", "句"], ["这", "是", "第", "二", "句"], ["这", "是", "第", "三", "句"],
            ["这", "是", "第", "四", "句"], ["这", "是", "第", "五", "句"], ["这", "是", "第", "六", "句"],
            ["爱", "愁", "思", "心", "碎", "滋", "味"], ["这", "是", "第", "八", "句"],
        ]
        var rows: [LayerBackedLyricRow] = []
        var start: TimeInterval = 0
        for (i, chars) in texts.enumerated() {
            var words: [LyricWord] = []
            var t = start
            let charDur: TimeInterval = 0.4
            for c in chars {
                words.append(LyricWord(word: c, startTime: t, endTime: t + charDur))
                t += charDur
            }
            let line = LyricLine(text: chars.joined(), startTime: start, endTime: t, words: words)
            rows.append(row(for: line, index: i))
            start = t + 0.3
        }
        return rows
    }

    @MainActor
    func test_cjkTrailingWordGhost_rowDumpCapturesLayerTreeAcrossTheKnownGhostWindow() {
        let rows = cjkRows()
        let panelWidth: CGFloat = 360
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 600))
        host(surface, NSSize(width: panelWidth, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 60
        mc.isPlaying = true
        surface.debugSkipDedupe = true
        var wall: CFTimeInterval = 5_000
        var date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer { surface.debugNowOverride = nil; mc.debugPlaybackClockDateProvider = nil }

        func tick(_ t: TimeInterval, _ ticks: Int) {
            mc.syncPlaybackClock(to: t, playing: true, at: date)
            let current = min(max(0, NativeLyricsTimelinePolicy.liveDisplayIndex(at: t, rows: rows, fallback: 0)), max(0, rows.count - 1))
            surface.configure(config(rows: rows, current: current, mc: mc, width: panelWidth))
            surface.layoutSubtreeIfNeeded()
            for _ in 0..<ticks {
                wall += 1.0 / 60.0
                date = date.addingTimeInterval(1.0 / 60.0)
                mc.syncPlaybackClock(to: t, playing: true, at: date)
                surface.debugTick(displayInterval: 1.0 / 60.0)
            }
        }

        // Same warmup as the 3c/59647e1 repro: play through the first few lines so row 6 settles
        // far/blurred/inactive/rasterized, then approach and enter its own active window.
        for r in 0..<3 {
            tick(rows[r].displayLine.line.startTime + 0.5, 6)
        }
        tick(rows[2].displayLine.line.startTime + 0.5, 60)

        var allDumps: [String] = []
        var suspiciousFrames: [(t: TimeInterval, dump: [String])] = []

        for r in 3...6 {
            let lineStart = rows[r].displayLine.line.startTime
            let lineEnd = rows[r].displayLine.line.endTime
            var t = lineStart - 0.3
            while t <= lineEnd {
                tick(t, 2)
                if let v6 = surface.debugRowView(forIndex: 6) {
                    let dump = v6.rowDumpLines(role: "row6(t=\(String(format: "%.3f", t)))")
                    allDumps.append(contentsOf: dump)

                    // Best-effort duplicate-glyph check: the SAME visible string prefix showing
                    // up in more than the architecturally-expected dim+bright pair (one dim
                    // tile + one bright tile per glyph is BY DESIGN, not a ghost) is worth
                    // flagging for a human to look at. This is informational, not a hard
                    // pass/fail oracle — see the file header for why no assertion is made.
                    var stringOccurrences: [String: Int] = [:]
                    for line in dump {
                        guard let range = line.range(of: "string=\"") else { continue }
                        let rest = line[range.upperBound...]
                        guard let end = rest.firstIndex(of: "\"") else { continue }
                        let s = String(rest[..<end])
                        guard !s.isEmpty else { continue }
                        stringOccurrences[s, default: 0] += 1
                    }
                    if stringOccurrences.values.contains(where: { $0 > 2 }) {
                        suspiciousFrames.append((t: t, dump: dump))
                    }
                }
                t += 0.05
            }
        }

        let scratchPath = "/tmp/nanopod_rowdump_cjk_ghost_repro.txt"
        try? allDumps.joined(separator: "\n").write(toFile: scratchPath, atomically: true, encoding: .utf8)

        // Informational report only — see file header. `swift test` output (and the archived
        // dump at scratchPath) is the deliverable; this test always "passes" in the CI sense
        // because a human decision, not an oracle, is what this data is for.
        print("[RowDump CJK] captured \(allDumps.count) lines across the known ghost window; "
            + "full dump: \(scratchPath); suspicious frames (glyph in >2 layers): "
            + "\(suspiciousFrames.count)")
        for frame in suspiciousFrames.prefix(3) {
            print("[RowDump CJK] suspicious frame t=\(frame.t):")
            for line in frame.dump { print("    " + line) }
        }

        XCTAssertFalse(allDumps.isEmpty, "the dump probe itself must produce output for a mounted, visible row")
    }
}
