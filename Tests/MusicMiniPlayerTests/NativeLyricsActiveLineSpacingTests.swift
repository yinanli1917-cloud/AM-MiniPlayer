import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-08-27: 切到激活行后当前行的行内/行间距会变，中文尤其明显。
//
// Mechanism (reproduced):
// v2.8 Canvas kept the dim base as one laid-out string (pass 1) and only
// floated the bright overlay (pass 2). Native niled the dim string on
// activation and retessellated it as per-glyph CATextLayers that also
// floated — wrap-line 行距 and CJK 字距 jumped at the activation frame.
// Scale about the layer origin (top-left) compounded this vs v2.8's
// `.scaleEffect(anchor: .leading)`.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsActiveLineSpacingTests: XCTestCase {

    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
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

    private func cjkLine() -> LyricLine {
        LyricLine(
            text: "想走出你控制的领域就从今晚开始",
            startTime: 10, endTime: 18,
            words: [
                LyricWord(word: "想", startTime: 10, endTime: 11),
                LyricWord(word: "走", startTime: 11, endTime: 12),
                LyricWord(word: "出", startTime: 12, endTime: 13),
                LyricWord(word: "你", startTime: 13, endTime: 14),
                LyricWord(word: "控", startTime: 14, endTime: 15),
                LyricWord(word: "制", startTime: 15, endTime: 16),
                LyricWord(word: "的", startTime: 16, endTime: 16.4),
                LyricWord(word: "领", startTime: 16.4, endTime: 16.8),
                LyricWord(word: "域", startTime: 16.8, endTime: 17.2),
                LyricWord(word: "就", startTime: 17.2, endTime: 17.4),
                LyricWord(word: "从", startTime: 17.4, endTime: 17.6),
                LyricWord(word: "今", startTime: 17.6, endTime: 17.8),
                LyricWord(word: "晚", startTime: 17.8, endTime: 17.9),
                LyricWord(word: "开", startTime: 17.9, endTime: 17.95),
                LyricWord(word: "始", startTime: 17.95, endTime: 18),
            ]
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
        width: CGFloat
    ) -> LyricsLayerRendererConfiguration {
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

    private func snapshot(for line: LyricLine, width: CGFloat) -> NativeLyricsTextSweepLayout.LayoutSnapshot {
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: line.startTime, isActive: true
        ))
        let textWidth = max(1, width - NativeLyricsRowMeasurement.leadingInset - NativeLyricsRowMeasurement.trailingInset)
        return NativeLyricsTextSweepLayout.layoutSnapshot(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: textWidth,
            fontSize: plan.constants.mainFontSize
        )
    }

    @MainActor
    private func assertActivationKeepsLayout(line: LyricLine, width: CGFloat, label: String) {
        NativeLyricsFeelParity.testingSweep = .v28
        let inactive = row(for: englishLine(), index: 0)
        let target = row(for: line, index: 1)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: width, height: 96))
        host(view, NSSize(width: width, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240

        let beforeSnap = snapshot(for: line, width: width)
        XCTAssertGreaterThan(beforeSnap.lineCount, 0, "\(label): layout snapshot must see the line")

        view.configure(row: target, configuration: config(rows: [inactive, target], current: 0, mc: mc, width: width))
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let inactiveString = view.debugMainTextLayerString
        XCTAssertNotNil(inactiveString, "\(label): neighbor row uses the whole-line dim base")
        let inactiveHeight = view.debugMainTextLayerFrame.height
        let inactiveGlyphs = view.debugVisibleDimWordGlyphCount

        mc.syncPlaybackClock(to: line.startTime, playing: true)
        view.configure(row: target, configuration: config(rows: [inactive, target], current: 1, mc: mc, width: width))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: config(rows: [inactive, target], current: 1, mc: mc, width: width))

        XCTAssertNotNil(view.debugMainTextLayerString,
                        "\(label): activation must keep the whole-line dim base (v2.8 Canvas pass 1)")
        XCTAssertEqual(view.debugMainTextLayerString, inactiveString,
                       "\(label): dim string must not be rewritten into a different wrap")
        XCTAssertEqual(view.debugVisibleDimWordGlyphCount, 0,
                       "\(label): dim must not retessellate into glyph tiles")
        XCTAssertEqual(inactiveGlyphs, 0, "\(label): inactive dim was already whole-line")
        XCTAssertEqual(view.debugMainTextLayerFrame.height, inactiveHeight, accuracy: 0.5,
                       "\(label): dim-base frame height (行高) must not jump on activation")

        let afterSnap = snapshot(for: line, width: width)
        XCTAssertEqual(afterSnap.lineCount, beforeSnap.lineCount,
                       "\(label): wrap-line count is identity across activation")
        XCTAssertEqual(afterSnap.lineSpacing, beforeSnap.lineSpacing, accuracy: 0.01,
                       "\(label): wrap-line 行距 is identity across activation")
        XCTAssertEqual(afterSnap.meanGlyphAdvance, beforeSnap.meanGlyphAdvance, accuracy: 0.01,
                       "\(label): mean 字距 is identity across activation")
        XCTAssertEqual(afterSnap.fragmentHeights, beforeSnap.fragmentHeights,
                       "\(label): fragment heights must match")
        XCTAssertGreaterThan(view.debugVisibleBrightWordGlyphCount, 0,
                             "\(label): bright overlay still uses per-glyph float tiles")
    }

    @MainActor
    func test_cjkWrappedLine_activationDoesNotChangeLineHeightOrTracking() {
        let width: CGFloat = 186
        let snap = snapshot(for: cjkLine(), width: width)
        XCTAssertGreaterThanOrEqual(snap.lineCount, 2, "precondition: CJK fixture must wrap so 行距 is observable")
        assertActivationKeepsLayout(line: cjkLine(), width: width, label: "CJK")
    }

    @MainActor
    func test_englishLine_activationDoesNotChangeLineHeightOrTracking() {
        assertActivationKeepsLayout(line: englishLine(), width: 320, label: "EN")
    }

    @MainActor
    func test_layerSweepPath_stillNilsDimString_soA_BHasAVisibleDelta() {
        NativeLyricsFeelParity.testingSweep = .layer
        let line = cjkLine()
        let r = row(for: line, index: 0)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 186, height: 96))
        host(view, NSSize(width: 186, height: 96))
        let mc = MusicController(preview: true)
        mc.isPlaying = true
        mc.duration = 240
        mc.syncPlaybackClock(to: line.startTime + 2, playing: true)
        let cfg = config(rows: [r], current: 0, mc: mc, width: 186)
        view.configure(row: r, configuration: cfg)
        view.frame = NSRect(x: 0, y: 0, width: 186, height: view.measuredHeight(width: 186))
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        _ = view.updatePlaybackPhase(configuration: cfg)
        XCTAssertNil(view.debugMainTextLayerString,
                     "layer A/B arm keeps the old per-glyph dim tessellation so the founder can compare")
        XCTAssertGreaterThan(view.debugVisibleDimWordGlyphCount, 0)
    }

    func test_leadingScale_preservesLeftCenter_matchingV28AnchorLeading() {
        let height: CGFloat = 80
        let t = NativeLyricsRowScale.leadingTransform(scale: 0.95, height: height)
        let pivot = CGPoint(x: 0, y: height / 2)
        let mapped = pivot.applying(t)
        XCTAssertEqual(mapped.x, 0, accuracy: 0.0001)
        XCTAssertEqual(mapped.y, height / 2, accuracy: 0.0001)

        let top = CGPoint(x: 0, y: 0).applying(t)
        let originScaled = CGPoint(x: 0, y: 0).applying(CGAffineTransform(scaleX: 0.95, y: 0.95))
        XCTAssertNotEqual(top.y, originScaled.y, accuracy: 0.0001,
                          "leading-center scale must move the top edge; origin scale leaves it put (the 行距 look)")
        XCTAssertEqual(NativeLyricsRowScale.leadingTransform(scale: 1, height: height), .identity)
    }
}
