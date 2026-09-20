import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// 2026-09-19 coordinator follow-up ("下雨天" real-device report: "点点雨似渗出眼泪",唱到「出」
// 时暗底的「眼泪」整体比亮字块偏右约 1/3 字，扫掠边界处还有一条竖纹" — a horizontal desync between
// the per-glyph BRIGHT tile (positioned from `NativeLyricsTextSweepLayout`'s
// `layoutManager.boundingRect(forGlyphRange:in:)`, an INK-BOUNDS API) and where the SAME
// `NSLayoutManager` would place that glyph via `lineFragmentRect(forGlyphAt:).origin.x +
// location(forGlyphAt:).x` (an ADVANCE/BASELINE-ORIGIN API) — the two CAN legitimately disagree
// for glyphs with side bearings, and the founder's report of drift accumulating toward the end of
// the line is exactly the shape a per-glyph ACCUMULATED side-bearing error would produce.
//
// This is pure-code instrumentation + a pure-code assertion — no device needed to run it. It
// drives a REAL `NativeLyricsRowView` through REAL AppKit text layout (the same
// `NativeLyricsTextSweepLayout.makeUnifiedBuild` production code path uses), then compares the
// two APIs against each other for every glyph of an active, actively-sweeping line.
//
// `NativeLyricsRowView.debugGlyphAlignmentSamples` and `debugPerGlyphAlignmentDump()` (wired into
// `rowDumpLines`) expose the same two x values for the founder to capture on a real device
// (font/contentsScale/screen-scaling can differ there in ways this synthetic harness cannot
// reproduce) — this test only proves the MODEL-level formulas agree (or documents where they
// don't) in a controlled, deterministic environment.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsGlyphAlignmentTests: XCTestCase {
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

    private func row(for line: LyricLine, index: Int) -> LayerBackedLyricRow {
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(
            id: dl.id, index: index, displayLine: dl, sourceLine: line,
            isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], current: Int, mc: MusicController, width: CGFloat) -> LyricsLayerRendererConfiguration {
        var heights: [Int: CGFloat] = [:]
        for r in rows { heights[r.index] = 72 }
        return LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: current, anchorY: 200, rowWidth: width,
            renderedIndices: rows.map(\.index), accumulatedHeights: heights, lineTargetIndices: [:],
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

    /// 8-character CJK line, one character per word (matches "点点雨似渗出眼泪"'s shape).
    private func cjk8Line() -> LyricLine {
        let chars = ["点", "点", "雨", "似", "渗", "出", "眼", "泪"]
        var t: TimeInterval = 10
        var words: [LyricWord] = []
        for c in chars {
            words.append(LyricWord(word: c, startTime: t, endTime: t + 0.4))
            t += 0.4
        }
        return LyricLine(text: chars.joined(), startTime: 10, endTime: t, words: words)
    }

    /// 13-character CJK line, no spaces, single combined word run (matches the founder's "只有你
    /// 能带我走向未来的旅程" 13-字无空格 report shape).
    private func cjk13Line() -> LyricLine {
        let text = "只有你能带我走向未来的旅程"
        return LyricLine(
            text: text, startTime: 10, endTime: 12,
            words: [LyricWord(word: text, startTime: 10, endTime: 12)]
        )
    }

    private func englishLine() -> LyricLine {
        LyricLine(
            text: "hello brave new world tonight",
            startTime: 10, endTime: 16,
            words: [
                LyricWord(word: "hello ", startTime: 10, endTime: 11.2),
                LyricWord(word: "brave ", startTime: 11.2, endTime: 12.4),
                LyricWord(word: "new ", startTime: 12.4, endTime: 13.2),
                LyricWord(word: "world ", startTime: 13.2, endTime: 14.5),
                LyricWord(word: "tonight", startTime: 14.5, endTime: 16),
            ]
        )
    }

    @MainActor
    private func glyphAlignmentSamples(
        line: LyricLine, width: CGFloat, atTime currentTime: TimeInterval
    ) -> [NativeLyricsRowView.DebugGlyphAlignmentSample] {
        let target = row(for: line, index: 0)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        host(view, NSSize(width: width, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: currentTime, playing: true)
        let cfg = config(rows: [target], current: 0, mc: mc, width: width)
        view.configure(row: target, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)
        return view.debugGlyphAlignmentSamples ?? []
    }

    /// Core assertion: for every glyph of an actively-sweeping line, the per-glyph tile's own
    /// `frame.minX` (what `NativeLyricsTextSweepLayout` positioned it from — the ink-bounds API)
    /// must equal the SAME `NSLayoutManager`'s advance/baseline-origin API
    /// (`lineFragmentRect(forGlyphAt:).origin.x + location(forGlyphAt:).x`) within a sub-pixel
    /// tolerance. A real, non-trivial mismatch here — not assumed, not device-only — would be
    /// exactly the founder's reported drift, and would show up as a growing delta toward the end
    /// of the line (accumulated side-bearing error) rather than a constant offset.
    @MainActor
    private func assertGlyphAlignment(line: LyricLine, width: CGFloat, label: String) {
        let currentTime = (line.words.last?.startTime ?? line.startTime) + 0.05
        let samples = glyphAlignmentSamples(line: line, width: width, atTime: currentTime)
        XCTAssertFalse(samples.isEmpty, "\(label): expected at least one glyph sample")

        var maxDelta: CGFloat = 0
        var deltas: [CGFloat] = []
        for sample in samples {
            XCTAssertFalse(sample.layoutManagerX.isNaN, "\(label): char \"\(sample.char)\" has no resolvable glyph range")
            let delta = abs(sample.tileFrameMinX - sample.layoutManagerX)
            deltas.append(delta)
            maxDelta = max(maxDelta, delta)
        }
        print("[NativeLyricsGlyphAlignmentTests] \(label): deltas=\(deltas.map { String(format: "%.3f", $0) })")
        XCTAssertLessThanOrEqual(
            maxDelta, 0.5,
            "\(label): max |tileFrame.minX − layoutManagerX| = \(maxDelta)pt across \(samples.count) glyphs — "
                + "the two NSLayoutManager APIs disagree by more than half a point, which is model-level "
                + "evidence for the founder's reported horizontal drift"
        )
    }

    @MainActor
    func test_cjk8CharLine_tileFrameMatchesLayoutManagerAdvance() {
        assertGlyphAlignment(line: cjk8Line(), width: 250, label: "CJK-8")
    }

    @MainActor
    func test_cjk13CharNoSpaceLine_tileFrameMatchesLayoutManagerAdvance() {
        assertGlyphAlignment(line: cjk13Line(), width: 186, label: "CJK-13-nospace")
    }

    @MainActor
    func test_englishLine_tileFrameMatchesLayoutManagerAdvance() {
        assertGlyphAlignment(line: englishLine(), width: 250, label: "EN")
    }

    // ─────────────────────────────────────────────────────────────────────
    // 2026-09-20 (3p, founder real-device root cause on top of the above): the two APIs agreeing
    // on the advance ORIGIN (`tileFrameMinX == layoutManagerX`, proven above) does not mean the
    // two glyph renderers agree on the OUTLINE painted at that origin — a CATextLayer handed a
    // generic `NSFont.systemFont(weight:.semibold)` can (and for CJK, does) resolve its own Han
    // fallback to a DIFFERENT concrete font than what `NSLayoutManager` already resolved for the
    // SAME character while laying out the whole line. `resolvedGlyphFont` fixes this by pulling
    // the font straight from the shared `NSTextStorage` instead of re-deriving one. These tests
    // pin that the tile's actual `.font` now equals the layout-resolved font, by name, for every
    // glyph of an actively-sweeping line — CJK (where the divergence was real, per the rowdump)
    // and English (where the fix must be a no-op, not a regression).
    // ─────────────────────────────────────────────────────────────────────
    @MainActor
    private func assertGlyphFontMatchesLayoutResolution(line: LyricLine, width: CGFloat, label: String) {
        let currentTime = (line.words.last?.startTime ?? line.startTime) + 0.05
        let samples = glyphAlignmentSamples(line: line, width: width, atTime: currentTime)
        XCTAssertFalse(samples.isEmpty, "\(label): expected at least one glyph sample")
        for sample in samples {
            XCTAssertNotNil(sample.resolvedFontName, "\(label): char \"\(sample.char)\" has no resolvable layout font")
            XCTAssertEqual(
                sample.tileFontName, sample.resolvedFontName,
                "\(label): char \"\(sample.char)\" tile font \"\(sample.tileFontName ?? "nil")\" != "
                    + "layout-resolved font \"\(sample.resolvedFontName ?? "nil")\" — the glyph tile is "
                    + "painting a DIFFERENT concrete font than the one the shared layout committed to for "
                    + "this character, which is the founder's reported persistent double-edge/ghost root cause"
            )
        }
    }

    @MainActor
    func test_cjk8CharLine_tileFontMatchesLayoutResolvedFont() {
        assertGlyphFontMatchesLayoutResolution(line: cjk8Line(), width: 250, label: "CJK-8")
    }

    @MainActor
    func test_cjk13CharNoSpaceLine_tileFontMatchesLayoutResolvedFont() {
        assertGlyphFontMatchesLayoutResolution(line: cjk13Line(), width: 186, label: "CJK-13-nospace")
    }

    @MainActor
    func test_englishLine_tileFontMatchesLayoutResolvedFont() {
        assertGlyphFontMatchesLayoutResolution(line: englishLine(), width: 250, label: "EN")
    }

    /// Rendering-level proof, not just a font-name string comparison: rasterize the per-glyph
    /// BRIGHT tile and the whole-line dim base's `NativeLyricsUnifiedDimDrawLayer` into two
    /// bitmaps of the SAME size/origin/scale (the tile's own frame) and compare their non-
    /// transparent (ink) pixel masks. Before the fix, a font mismatch at an identical advance
    /// origin produces materially different glyph outlines — the masks disagree by more than a
    /// sliver of anti-aliasing noise at the edges. After the fix (both painting from the exact
    /// same resolved font), the masks must agree almost everywhere.
    @MainActor
    private func rasterize(_ layer: CALayer, in rect: CGRect, scale: CGFloat) -> NSBitmapImageRep? {
        let pixelWidth = max(1, Int((rect.width * scale).rounded()))
        let pixelHeight = max(1, Int((rect.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        layer.render(in: context)
        return rep
    }

    private func alphaCoverageMask(_ rep: NSBitmapImageRep, threshold: Int = 10) -> [Bool] {
        var mask: [Bool] = []
        mask.reserveCapacity(rep.pixelsWide * rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                mask.append(Int(alpha * 255) > threshold)
            }
        }
        return mask
    }

    @MainActor
    private func assertDimAndBrightRenderSameGlyphOutline(line: LyricLine, width: CGFloat, label: String) {
        let currentTime = (line.words.last?.startTime ?? line.startTime) + 0.05
        let target = row(for: line, index: 0)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        host(view, NSSize(width: width, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: currentTime, playing: true)
        let cfg = config(rows: [target], current: 0, mc: mc, width: width)
        view.configure(row: target, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)

        guard let dimLayer = view.debugFirstVisibleMainDimWordGlyphLayer() else {
            return XCTFail("\(label): expected at least one visible dim word-glyph tile")
        }
        let scale: CGFloat = 4 // supersample well past hinting noise for a small glyph box
        // Compare the DIM tile against itself vs the BRIGHT tile at the tile's own bounds — both
        // now must originate from `resolvedGlyphFont`, so their painted outlines should coincide
        // (previously the bright tile could legitimately differ from the dim base's font).
        guard let brightLayer = view.debugFirstVisibleMainBrightWordGlyphLayer(),
              let dimRep = rasterize(dimLayer, in: dimLayer.bounds, scale: scale),
              let brightRep = rasterize(brightLayer, in: brightLayer.bounds, scale: scale)
        else {
            return XCTFail("\(label): expected both dim and bright tiles to rasterize")
        }
        let dimMask = alphaCoverageMask(dimRep)
        let brightMask = alphaCoverageMask(brightRep)
        XCTAssertEqual(dimMask.count, brightMask.count, "\(label): dim/bright tiles must rasterize to the same pixel grid (same bounds/scale)")
        guard dimMask.count == brightMask.count, !dimMask.isEmpty else { return }
        let agree = zip(dimMask, brightMask).filter { $0 == $1 }.count
        let ratio = Double(agree) / Double(dimMask.count)
        XCTAssertGreaterThanOrEqual(
            ratio, 0.99,
            "\(label): dim/bright glyph-coverage masks agree on only \(String(format: "%.1f%%", ratio * 100)) of pixels — "
                + "same font is required for the two tiles to paint the identical outline"
        )
    }

    @MainActor
    func test_cjk8CharLine_dimAndBrightTilesRenderIdenticalGlyphOutline() {
        assertDimAndBrightRenderSameGlyphOutline(line: cjk8Line(), width: 250, label: "CJK-8")
    }

    @MainActor
    func test_englishLine_dimAndBrightTilesRenderIdenticalGlyphOutline() {
        assertDimAndBrightRenderSameGlyphOutline(line: englishLine(), width: 250, label: "EN")
    }
}
