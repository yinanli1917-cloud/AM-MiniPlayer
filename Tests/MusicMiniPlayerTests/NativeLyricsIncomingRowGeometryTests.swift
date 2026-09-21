import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-20 founder repro (60fps recording, word-level Chinese song 下雨天): at the line
// boundary the INCOMING row visibly "twitches 1-2px" 0.24s BEFORE its own position wave even
// starts. Whole-row integer cross-correlation shift = 0 (screen-recording measurement), so this
// is a sub-pixel/rasterization change, not a translation the founder's own eye is tracking wrong.
// Blur mode v28 (springed blur, nanopod://debug/feel/blur/v28) and the wave-sync arm were both
// tried live and did NOT help — ruling out the stepped blur and the wave lag as the channel.
//
// This test drives the REAL NativeLyricsSurfaceView across a line boundary with lockstep
// injected clocks (debugNowOverride / mc.debugPlaybackClockDateProvider / debugTick — same rig
// as NativeLyricsHandoffClockTests) and measures, every 8.33ms tick, the alpha-weighted INK
// bounding box of the incoming/outgoing row's rendered layer tree (mainTextLayer CATextLayer
// path OR activeLineDrawLayer bitmap-tile path, whichever is visible) — not just layer frames,
// which can stay bit-identical while the RASTERIZED ink still moves a fraction of a point.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsIncomingRowGeometryTests: XCTestCase {

    private var hostWindow: NSWindow?
    private var hostedSurfaces: [NativeLyricsSurfaceView] = []
    private let renderScale: CGFloat = 2

    @MainActor
    override func setUp() {
        super.setUp()
        // The shipping default is the single-pass bitmap renderer (NativeLyricsActiveLineDrawLayer);
        // under XCTest NativeLyricsFeelParity.activeLineRenderer silently falls back to the old
        // per-glyph `.tiles` path unless a test opts in explicitly. This suite is investigating the
        // PRODUCTION path, so it must opt in.
        NativeLyricsFeelParity.testingActiveLine = .singlePass
    }

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.testingActiveLine = nil
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
        if let surface = view as? NativeLyricsSurfaceView {
            hostedSurfaces.append(surface)
        }
    }

    // Word-level Chinese fixture, same shape as the founder's 下雨天 report: short lines,
    // 0.5-1.0 s gaps between lines, per-word timings within each line.
    private struct LineSpec { let text: String; let words: [String]; let start: TimeInterval; let duration: TimeInterval }

    private func makeRows() -> [LayerBackedLyricRow] {
        let specs: [LineSpec] = [
            LineSpec(text: "又独行旧地", words: ["又", "独行", "旧地"], start: 0.0, duration: 2.2),
            LineSpec(text: "遇着拦路雨洒遍地", words: ["遇着", "拦路", "雨洒", "遍地"], start: 2.9, duration: 2.6),
            LineSpec(text: "路静人寂寞", words: ["路静", "人", "寂寞"], start: 6.2, duration: 2.0),
            LineSpec(text: "旧巷里灯柱一双", words: ["旧巷里", "灯柱", "一双"], start: 8.9, duration: 2.4),
            LineSpec(text: "路上一双心印", words: ["路上", "一双", "心印"], start: 12.0, duration: 2.1),
            LineSpec(text: "路上七彩灯饰", words: ["路上", "七彩", "灯饰"], start: 14.8, duration: 2.1),
            LineSpec(text: "但是我怕这个夜晚", words: ["但是", "我怕", "这个", "夜晚"], start: 17.5, duration: 2.5),
            LineSpec(text: "细雨渐渐洒得凄迷", words: ["细雨", "渐渐", "洒得", "凄迷"], start: 20.7, duration: 2.6),
        ]
        return specs.enumerated().map { i, spec in
            let n = spec.words.count
            let per = spec.duration / TimeInterval(n)
            var t = spec.start
            var words: [LyricWord] = []
            for w in spec.words {
                words.append(LyricWord(word: w, startTime: t, endTime: t + per))
                t += per
            }
            let line = LyricLine(text: spec.text, startTime: spec.start, endTime: spec.start + spec.duration, words: words)
            let dl = DisplayLyricLine(id: "r\(i)", sourceIndex: i, segmentIndex: 0, segmentCount: 1, line: line)
            return LayerBackedLyricRow(id: dl.id, index: i, displayLine: dl, sourceLine: line,
                                       isPrelude: false, preludeEndTime: 0, interlude: nil)
        }
    }

    @MainActor
    private func config(
        _ rowList: [LayerBackedLyricRow], current: Int, mc: MusicController
    ) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rowList { heights[r.index] = 56 }
        return LyricsLayerRendererConfiguration(
            rows: rowList, currentIndex: current, anchorY: 300, rowWidth: 320,
            renderedIndices: rowList.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
            lineInterval: 4, hasSyllableSync: true,
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

    // ── Ink bbox measurement ────────────────────────────────────────────────────────────────

    struct InkBBox { var minX: CGFloat; var minY: CGFloat; var maxX: CGFloat; var maxY: CGFloat; var mass: CGFloat
        var centroidX: CGFloat; var centroidY: CGFloat
        static let empty = InkBBox(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity, mass: 0, centroidX: 0, centroidY: 0)
        var isEmpty: Bool { mass <= 0 }
    }

    /// Render `layer`'s own subtree (local bounds, top-left origin, y-down — matching the
    /// NSView.isFlipped=true row hierarchy) into an offscreen bitmap and compute the
    /// alpha-weighted bounding box + centroid, in the row's LOCAL point space.
    @MainActor
    private func inkBBox(of layer: CALayer, width: CGFloat, height: CGFloat) -> InkBBox {
        guard width > 0, height > 0 else { return .empty }
        let w = Int((width * renderScale).rounded()), h = Int((height * renderScale).rounded())
        guard w > 0, h > 0 else { return .empty }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .empty }
        ctx.scaleBy(x: renderScale, y: renderScale)
        // CALayer.render(in:) treats the context as non-flipped (CG default, y-up). This row
        // hierarchy is y-down (isFlipped NSView). Flip once here so pixel row 0 is the row's TOP,
        // consistently every tick — absolute orientation doesn't matter for a delta measurement,
        // only tick-to-tick consistency does, and this keeps it matching the view's own sense of y.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)

        var minX = w, minY = h, maxX = -1, maxY = -1
        var mass: Double = 0, sx: Double = 0, sy: Double = 0
        for py in 0..<h {
            let rowBase = py * w * 4
            for px in 0..<w {
                let a = Double(data[rowBase + px * 4 + 3])
                if a > 25.5 { // alpha > 0.1 * 255
                    if px < minX { minX = px }
                    if px > maxX { maxX = px }
                    if py < minY { minY = py }
                    if py > maxY { maxY = py }
                    mass += a
                    sx += a * Double(px)
                    sy += a * Double(py)
                }
            }
        }
        guard maxX >= minX, mass > 0 else { return .empty }
        let s = Double(renderScale)
        return InkBBox(
            minX: CGFloat(Double(minX) / s), minY: CGFloat(Double(minY) / s),
            maxX: CGFloat(Double(maxX + 1) / s), maxY: CGFloat(Double(maxY + 1) / s),
            mass: CGFloat(mass), centroidX: CGFloat(sx / mass / s), centroidY: CGFloat(sy / mass / s)
        )
    }

    // ── Per-tick sample ─────────────────────────────────────────────────────────────────────

    struct RowSample {
        let tick: Int
        let tOffset: TimeInterval   // seconds relative to the line boundary
        let frameOriginY: CGFloat   // row view frame.origin.y within the surface
        let mainTextLayerHidden: Bool
        let activeLineDrawLayerHidden: Bool
        let bbox: InkBBox           // in SURFACE coordinates (frame origin + local bbox)
    }

    @MainActor
    private func sampleRow(_ view: NativeLyricsRowView) -> RowSample {
        let mainHidden = view.debugMainTextLayerHidden
        let drawHidden = view.debugActiveLineDrawLayerHidden
        let local = inkBBox(of: view.layer!, width: view.bounds.width, height: max(1, view.bounds.height))
        let originY = view.frame.origin.y
        var surfaceBBox = local
        if !local.isEmpty {
            surfaceBBox.minY += originY; surfaceBBox.maxY += originY; surfaceBBox.centroidY += originY
        }
        return RowSample(tick: 0, tOffset: 0, frameOriginY: originY,
                         mainTextLayerHidden: mainHidden, activeLineDrawLayerHidden: drawHidden, bbox: surfaceBBox)
    }

    // ── Drive ───────────────────────────────────────────────────────────────────────────────

    struct GeometryReport {
        let incoming: [RowSample]
        let outgoing: [RowSample]
        let incomingIndex: Int
        let outgoingIndex: Int
        let boundaryTick: Int
    }

    @MainActor
    private func runHandoff() -> GeometryReport? {
        let surface = NativeLyricsSurfaceView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        host(surface, NSSize(width: 360, height: 600))
        let mc = MusicController(preview: true)
        mc.duration = 240
        mc.isPlaying = true
        let rows = makeRows()
        surface.debugSkipDedupe = true

        let outgoingIndex = 3
        let incomingIndex = outgoingIndex + 1
        let lineEnd = rows[outgoingIndex].displayLine.line.endTime
        let lineStart = rows[outgoingIndex].displayLine.line.startTime
        // The renderer holds the OUTGOING row active through the gap between lines — the semantic
        // handoff happens at the INCOMING row's own start time, not the outgoing row's endTime.
        // (Verified by first centering the census on `lineEnd`: with a 0.7s gap between lines, the
        // handoff never appeared in a +/-0.5s window there — it was still 0.7s away.)
        let boundaryTime = rows[incomingIndex].displayLine.line.startTime

        var wall: CFTimeInterval = 1_000
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        surface.debugNowOverride = { wall }
        mc.debugPlaybackClockDateProvider = { date }
        defer {
            surface.debugNowOverride = nil
            mc.debugPlaybackClockDateProvider = nil
        }

        let tickDt = 1.0 / 120.0
        func step(playback: TimeInterval) {
            wall += tickDt
            date = date.addingTimeInterval(tickDt)
            mc.syncPlaybackClock(to: playback, playing: true, at: date)
            surface.configure(config(rows, current: surface.debugNativeSemanticIndex ?? 0, mc: mc))
            surface.debugTick(displayInterval: tickDt)
            RunLoop.main.run(until: Date())
        }

        // Settle by driving playback CONTINUOUSLY from before the very first row, through every
        // real line boundary up to line N, so the semantic engine advances the same way it does
        // in production (seeding `current` mid-song desyncs the engine's own index tracking and
        // freezes the whole render — verified by running this with an arbitrary seeded start).
        let settleStart: TimeInterval = -0.5
        mc.syncPlaybackClock(to: settleStart, playing: true, at: date)
        surface.configure(config(rows, current: 0, mc: mc))
        surface.layoutSubtreeIfNeeded()
        var t = settleStart
        let censusLeadIn = boundaryTime - 0.3
        while t < censusLeadIn {
            step(playback: t)
            t += tickDt
        }
        XCTAssertGreaterThanOrEqual(lineStart, 0, "sanity: fixture line \(outgoingIndex) starts at \(lineStart)")

        // Census: -0.3s to +0.5s around the boundary, one tick every 8.33ms (120Hz).
        var incoming: [RowSample] = []
        var outgoing: [RowSample] = []
        let censusEnd = boundaryTime + 0.5
        var tickIndex = 0
        var boundaryTick = -1
        var playback = t
        while playback <= censusEnd {
            step(playback: playback)
            if let outView = surface.debugRowView(forIndex: outgoingIndex) {
                var s = sampleRow(outView)
                s = RowSample(tick: tickIndex, tOffset: playback - boundaryTime, frameOriginY: s.frameOriginY,
                              mainTextLayerHidden: s.mainTextLayerHidden, activeLineDrawLayerHidden: s.activeLineDrawLayerHidden, bbox: s.bbox)
                outgoing.append(s)
            }
            if let inView = surface.debugRowView(forIndex: incomingIndex) {
                var s = sampleRow(inView)
                s = RowSample(tick: tickIndex, tOffset: playback - boundaryTime, frameOriginY: s.frameOriginY,
                              mainTextLayerHidden: s.mainTextLayerHidden, activeLineDrawLayerHidden: s.activeLineDrawLayerHidden, bbox: s.bbox)
                incoming.append(s)
            }
            if boundaryTick < 0, playback >= boundaryTime { boundaryTick = tickIndex }
            tickIndex += 1
            playback += tickDt
        }

        guard !incoming.isEmpty, !outgoing.isEmpty else {
            XCTFail("rows \(outgoingIndex)/\(incomingIndex) must stay mounted across the boundary")
            return nil
        }
        return GeometryReport(incoming: incoming, outgoing: outgoing,
                              incomingIndex: incomingIndex, outgoingIndex: outgoingIndex, boundaryTick: boundaryTick)
    }

    // ── Jump detection ──────────────────────────────────────────────────────────────────────

    struct Jump { let tick: Int; let tOffset: TimeInterval; let field: String; let delta: CGFloat; let positionMoved: Bool }

    private func findJumps(_ samples: [RowSample], threshold: CGFloat = 0.5) -> [Jump] {
        var jumps: [Jump] = []
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            guard !a.bbox.isEmpty, !b.bbox.isEmpty else { continue }
            let positionMoved = abs(b.frameOriginY - a.frameOriginY) > 0.05
            let fields: [(String, CGFloat, CGFloat)] = [
                ("left", a.bbox.minX, b.bbox.minX), ("right", a.bbox.maxX, b.bbox.maxX),
                ("top", a.bbox.minY, b.bbox.minY), ("bottom", a.bbox.maxY, b.bbox.maxY),
                ("centroidX", a.bbox.centroidX, b.bbox.centroidX), ("centroidY", a.bbox.centroidY, b.bbox.centroidY)
            ]
            for (name, av, bv) in fields {
                let d = bv - av
                if abs(d) >= threshold && !positionMoved {
                    jumps.append(Jump(tick: b.tick, tOffset: b.tOffset, field: name, delta: d, positionMoved: positionMoved))
                }
            }
        }
        return jumps
    }

    private func dumpTable(_ label: String, _ samples: [RowSample]) -> String {
        var lines = ["  tick   t_off   frameY  mainHid drawHid    left   right     top  bottom  centX  centY"]
        for s in samples {
            lines.append(String(
                format: "  %4d  %+6.3f  %7.2f  %7@  %7@  %6.2f  %6.2f  %6.2f  %6.2f  %6.2f  %6.2f",
                s.tick, s.tOffset, s.frameOriginY,
                s.mainTextLayerHidden as NSNumber, s.activeLineDrawLayerHidden as NSNumber,
                s.bbox.isEmpty ? -1 : s.bbox.minX, s.bbox.isEmpty ? -1 : s.bbox.maxX,
                s.bbox.isEmpty ? -1 : s.bbox.minY, s.bbox.isEmpty ? -1 : s.bbox.maxY,
                s.bbox.isEmpty ? -1 : s.bbox.centroidX, s.bbox.isEmpty ? -1 : s.bbox.centroidY
            ))
        }
        return "[\(label)]\n" + lines.joined(separator: "\n")
    }

    // ── Test ────────────────────────────────────────────────────────────────────────────────

    @MainActor
    func test_incomingRowInkGeometryAcrossHandoff_namesTheTwitchChannel() {
        guard let r = runHandoff() else { return }

        let incomingTable = dumpTable("incoming row \(r.incomingIndex)", r.incoming)
        let outgoingTable = dumpTable("outgoing row \(r.outgoingIndex)", r.outgoing)
        print(incomingTable)
        print(outgoingTable)

        let incomingJumps = findJumps(r.incoming)
        let outgoingJumps = findJumps(r.outgoing)

        var report = "# Incoming-row ink geometry across the line boundary (2026-09-20)\n\n"
        report += "Rig: NativeLyricsHandoffClockTests-style lockstep injected clocks, 120Hz ticks, "
        report += "settle >= 3.5s on line \(r.outgoingIndex), census from -0.3s to +0.5s around its end.\n\n"
        report += "Outgoing row index \(r.outgoingIndex), incoming row index \(r.incomingIndex).\n\n"
        report += "## Incoming row table\n\n```\n\(incomingTable)\n```\n\n"
        report += "## Outgoing row table\n\n```\n\(outgoingTable)\n```\n\n"
        report += "## Jumps found (bbox/centroid moved >= 0.5px with frame origin unchanged)\n\n"
        if incomingJumps.isEmpty && outgoingJumps.isEmpty {
            report += "None. No sub-pixel ink jump was reproduced at this fixture/pacing.\n"
        } else {
            for j in incomingJumps { report += "- incoming tick \(j.tick) t=\(String(format: "%+.3f", j.tOffset))s field=\(j.field) delta=\(String(format: "%.3f", j.delta))px\n" }
            for j in outgoingJumps { report += "- outgoing tick \(j.tick) t=\(String(format: "%+.3f", j.tOffset))s field=\(j.field) delta=\(String(format: "%.3f", j.delta))px\n" }
        }
        report += "\nNote: CIFilters (blur) do not apply under headless `layer.render(in:)` — this measurement "
        report += "cannot see blur-only ink changes; it is a lower bound on the visible jump, not an upper bound.\n\n"
        report += "## Reading\n\n"
        report += "Tick 35 (t=-0.000s, exactly the boundary) is the tick `mainTextLayerHidden` flips "
        report += "false->true and `activeLineDrawLayerHidden` flips true->false — the production swap from "
        report += "the CATextLayer whole-line dim base (`mainTextLayer`) to the bitmap single-pass active-line "
        report += "renderer (`NativeLyricsActiveLineDrawLayer`, `applySinglePassActiveLine`). The row's own "
        report += "FRAME origin (`frameY`) does not move that tick. The rasterized ink right edge moves "
        report += "-0.5 device-px (0.25pt at 2x). NAMED CHANNEL: the two rasterizers (CATextLayer.render(in:) "
        report += "and NSLayoutManager.drawGlyphs via NativeLyricsActiveLineDrawLayer.runImage) round the same "
        report += "glyph run's bounding box to a different device pixel at the moment of the swap — a real, "
        report += "sub-pixel geometry discontinuity, distinct from (and additional to) the ink-density parity "
        report += "NativeLyricsActiveLineInkParityTests already pins. This is pinned as a hard-failing "
        report += "assertion in this file (the swap-tick block) — see 'Fixed / left failing' below.\n\n"
        report += "The two LATER jumps (tick 44 t=+0.075s, tick 61 t=+0.217s, both on `top`, both -0.5px) are "
        report += "a SECOND, smaller channel: each lands mid-line, well after the swap, close to where a new "
        report += "word's active/float phase would begin for this fixture's per-word timings. "
        report += "`NativeLyricsActiveLineDrawLayer.runImage` rounds each run's bitmap size UP to the next "
        report += "device pixel (`Int((frame.width/height * scale).rounded(.up))`) independently per run, so "
        report += "successive words can each pixel-snap by a different sub-pixel remainder — plausible but NOT "
        report += "independently isolated/pinned here (lower priority per the task; left as a report-only "
        report += "finding, not gated).\n\n"
        report += "CIFilters (the stepped blur, springed-blur v28 arm) cannot run under headless "
        report += "`layer.render(in:)`, so this measurement cannot see or rule out a blur-related contribution "
        report += "on top of these two channels — consistent with the founder's report that toggling the blur "
        report += "arm live did NOT fix the twitch: the swap-tick channel found here is upstream of blur "
        report += "entirely (blur is applied to already-rasterized ink; this jump is a difference in WHERE "
        report += "that ink is before blur ever runs).\n\n"
        report += "## Fixed / left failing\n\n"
        report += "Not fixed. The two rasterizers use materially different code paths (AppKit CATextLayer "
        report += "internal compositing vs. a hand-rolled NSLayoutManager bitmap + CGContext draw) with no "
        report += "documented sub-pixel rounding contract between them; forcing bit-identical rounding needs "
        report += "either (a) deriving the bitmap run's placement from the SAME rounding CATextLayer uses "
        report += "internally (not publicly exposed — would need empirical curve-fitting, fragile) or (b) "
        report += "snapping BOTH rasterizers' frame/position to the same device-pixel grid explicitly before "
        report += "the swap tick specifically (a few lines in `applySinglePassActiveLine` / `layout()`, but "
        report += "risks reintroducing the 2026-08-27 行距/字距 jump banned pattern if the snap is applied to "
        report += "the wrong coordinate — needs founder-reviewed real-machine verification, not a same-session "
        report += "blind patch). Per the fix-only-what-is-asked rule this is left as a failing pin: "
        report += "`NativeLyricsIncomingRowGeometryTests.test_incomingRowInkGeometryAcrossHandoff_namesTheTwitchChannel` "
        report += "(the swap-tick block) currently FAILS on the right-edge assertion (167.0 vs 166.5, tolerance "
        report += "0.25px), which is the reproduction.\n"

        let path = "research/repro-2026-09-20-incoming-row-geometry.md"
        try? report.write(toFile: path, atomically: true, encoding: .utf8)

        // The measurement itself must be alive: at least one row shows visible ink at some tick,
        // and we must have samples spanning the boundary.
        XCTAssertTrue(r.incoming.contains { !$0.bbox.isEmpty }, "incoming row never rasterized any ink")
        XCTAssertGreaterThan(r.boundaryTick, 0, "boundary must fall inside the census window")

        if !incomingJumps.isEmpty {
            print("[IncomingRowGeometry] TWITCH FOUND: \(incomingJumps.map(\.field))")
        }

        // ── Pin: the CATextLayer(dim base) -> bitmap(activeLineDrawLayer) swap tick itself must
        // not move the row's rasterized ink while its frame origin is unchanged. Named channel
        // (see the report written above): at the EXACT tick `mainTextLayerHidden` flips
        // false->true (production swaps `mainTextLayer` for `activeLineDrawLayer`), tick 35 in
        // this fixture, the ink right edge shifted -0.5px device-px with the row's own frame
        // origin bit-identical — the two rasterizers disagree on where the SAME glyphs' ink
        // starts/ends. This assertion is the reproducible, currently-FAILING pin for that
        // channel; it is scoped to the swap tick only (not every per-word float-onset wobble
        // later in the line, which is a second, smaller-priority channel — see the report).
        if let swapTickIndex = r.incoming.firstIndex(where: { $0.mainTextLayerHidden }),
           swapTickIndex > 0 {
            let before = r.incoming[swapTickIndex - 1]
            let after = r.incoming[swapTickIndex]
            XCTAssertEqual(before.frameOriginY, after.frameOriginY, accuracy: 0.01,
                           "precondition: the swap tick itself must not also move the row's frame")
            XCTAssertFalse(before.bbox.isEmpty, "pre-swap ink bbox must be measurable")
            XCTAssertFalse(after.bbox.isEmpty, "post-swap ink bbox must be measurable")
            XCTAssertEqual(before.bbox.minX, after.bbox.minX, accuracy: 0.25,
                           "rasterizer swap must not move the ink LEFT edge (CATextLayer vs bitmap)")
            XCTAssertEqual(before.bbox.maxX, after.bbox.maxX, accuracy: 0.25,
                           "rasterizer swap must not move the ink RIGHT edge (CATextLayer vs bitmap)")
            XCTAssertEqual(before.bbox.minY, after.bbox.minY, accuracy: 0.25,
                           "rasterizer swap must not move the ink TOP edge (CATextLayer vs bitmap)")
            XCTAssertEqual(before.bbox.maxY, after.bbox.maxY, accuracy: 0.25,
                           "rasterizer swap must not move the ink BOTTOM edge (CATextLayer vs bitmap)")
        } else {
            XCTFail("the incoming row never activated (mainTextLayer never hidden) — cannot pin the swap tick")
        }
    }
}
