import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder feedback 2026-09-21 (comparing our panel against Apple Music's lyrics panel): the
// hover background (`NativeLyricsRowView.backgroundLayer`) was derived independently from
// `bounds` (full row width/height) instead of from the SAME content rect the text layers were
// just laid out with — so it did not track the moved-left insets or wrapped-line pitch, and read
// wider/taller than the rendered text.
//
// `hoverBackgroundFrame()` now unions `mainTextLayer.frame` (and `translationTextLayer.frame`
// when visible) — the exact rects `layout()` just assigned the text — and pads by the existing
// 8pt (`NativeLyricsRowView.hoverBackgroundPadding`). These tests pin that union+pad contract
// against `debugMainTextLayerFrame`/`debugTranslationTextLayerFrame` for a single-line row, a
// wrapped row, and a row with a translation, so the background can never again silently regress
// to a `bounds`-derived box.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsHoverBackgroundTests: XCTestCase {

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

    private func row(text: String, translation: String? = nil) -> LayerBackedLyricRow {
        let line = LyricLine(text: text, startTime: 0, endTime: 3, translation: translation)
        let displayLine = DisplayLyricLine(id: "hoverbg-\(text.hashValue)", sourceIndex: 0, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: displayLine.id, index: 0, displayLine: displayLine, sourceLine: line,
                                   isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    @MainActor
    private func config(rows: [LayerBackedLyricRow], rowWidth: CGFloat, mc: MusicController, showTranslation: Bool = false) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows, currentIndex: 0, anchorY: 250, rowWidth: rowWidth,
            renderedIndices: rows.map(\.index), accumulatedHeights: [0: 0], lineTargetIndices: [:],
            lineInterval: 3, hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 60),
            isWaveTimelineDiagnosticsEnabled: false, isManualScrolling: false, reduceMotion: false,
            suppressInitialMotion: false, pendingTranslationLineIndices: [], showTranslation: showTranslation,
            isTranslating: false, translationFailed: false, interludeAfterIndex: nil, directSnapRequest: nil,
            controlsVisible: false, musicController: mc,
            onLineTap: { _ in }, onDirectSnapConsumed: { _ in }, onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in }, onManualScrollEnded: {}, onManualScrollRecovered: {},
            onManualScrollChromeReset: nil, onHeightMeasured: { _, _ in }, lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast, lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in })
    }

    private func expectedFrame(main: CGRect, translation: CGRect?) -> CGRect {
        var rect = main
        if let translation, translation != .zero {
            rect = rect.union(translation)
        }
        return rect.insetBy(dx: -NativeLyricsRowView.hoverBackgroundPadding, dy: -NativeLyricsRowView.hoverBackgroundPadding)
    }

    // MARK: - Single-line row

    @MainActor
    func test_singleLineRow_hoverBackgroundHugsTextContentRect() {
        let mc = MusicController(preview: true)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        host(view, NSSize(width: 320, height: 56))
        let r = row(text: "short line")
        view.configure(row: r, configuration: config(rows: [r], rowWidth: 320, mc: mc), updatesPlaybackPhase: false)
        view.debugForceLayout()
        view.debugInvokeLayoutDirectly()

        let expected = expectedFrame(main: view.debugMainTextLayerFrame, translation: nil)
        XCTAssertEqual(view.debugHoverBackgroundFrame, expected, "hover background must equal main text frame padded by the 8pt constant, not `bounds`")
        // Sanity: it must NOT equal the old bounds-derived box (which spanned the full 320pt row width).
        XCTAssertNotEqual(view.debugHoverBackgroundFrame.width, 320, "regression guard: must not fall back to the full row width for a short line")
    }

    // MARK: - Wrapped row

    @MainActor
    func test_wrappedRow_hoverBackgroundHeightIncludesAllVisualLines() {
        let mc = MusicController(preview: true)
        let narrowWidth: CGFloat = 160
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: narrowWidth, height: 120))
        host(view, NSSize(width: narrowWidth, height: 120))
        let longText = "this line is long enough that it must wrap across more than one visual line at this width"
        let r = row(text: longText)
        view.configure(row: r, configuration: config(rows: [r], rowWidth: narrowWidth, mc: mc), updatesPlaybackPhase: false)
        view.debugForceLayout()
        view.debugInvokeLayoutDirectly()

        let mainFrame = view.debugMainTextLayerFrame
        XCTAssertGreaterThan(mainFrame.height, 40, "precondition: text must actually wrap to more than one line at this width")
        let expected = expectedFrame(main: mainFrame, translation: nil)
        XCTAssertEqual(view.debugHoverBackgroundFrame, expected, "wrapped row: hover background must hug the FULL multi-line text height, not one line's worth")
    }

    // MARK: - Row with translation

    @MainActor
    func test_rowWithTranslation_hoverBackgroundIncludesTranslationLine() {
        let mc = MusicController(preview: true)
        let view = NativeLyricsRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        host(view, NSSize(width: 320, height: 100))
        let r = row(text: "original line", translation: "翻译行")
        view.configure(row: r, configuration: config(rows: [r], rowWidth: 320, mc: mc, showTranslation: true), updatesPlaybackPhase: false)
        view.debugForceLayout()
        view.debugInvokeLayoutDirectly()

        let translationFrame = view.debugTranslationTextLayerFrame
        XCTAssertNotEqual(translationFrame, .zero, "precondition: translation must actually be laid out")
        let expected = expectedFrame(main: view.debugMainTextLayerFrame, translation: translationFrame)
        XCTAssertEqual(view.debugHoverBackgroundFrame, expected, "hover background must extend to cover the translation line too")
        XCTAssertGreaterThan(view.debugHoverBackgroundFrame.height, view.debugMainTextLayerFrame.height,
                             "background must be taller than the main line alone once a translation is present")
    }
}
