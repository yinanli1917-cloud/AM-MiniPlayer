import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// layout() memoization (scroll CPU fix).
//
// NativeLyricsRowView.layout() is invoked by AppKit on every CATransaction
// commit while a view is dirty — i.e. every presentation tick during scroll
// and playback. Its body measures wrapped text with a full NSLayoutManager
// stack (two measuredTextHeight calls) and rewrites every text-layer frame.
// Those outputs depend only on (bounds, textWidth, text, translation,
// awaiting-translation, font constants); when none change, the re-layout is
// pure waste. Profiling showed it as ~85% of main-thread time during scroll.
//
// These tests pin the memoization at the real call site: an unchanged
// re-layout must NOT re-measure, and a genuine content change MUST.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsLayoutMemoTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    @MainActor
    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    private func row(_ text: String, translation: String? = nil, index: Int = 0) -> LayerBackedLyricRow {
        let line = LyricLine(
            text: text,
            startTime: TimeInterval(index * 10),
            endTime: TimeInterval(index * 10 + 10),
            translation: translation
        )
        let displayLine = DisplayLyricLine(
            id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line
        )
        return LayerBackedLyricRow(
            id: displayLine.id, index: index, displayLine: displayLine,
            sourceLine: line, isPrelude: false, preludeEndTime: 0, interlude: nil
        )
    }

    @MainActor
    private func configuration(
        rows: [LayerBackedLyricRow],
        rowWidth: CGFloat,
        showTranslation: Bool
    ) -> LyricsLayerRendererConfiguration {
        LyricsLayerRendererConfiguration(
            rows: rows,
            currentIndex: 0,
            anchorY: 0,
            rowWidth: rowWidth,
            renderedIndices: rows.map(\.index),
            accumulatedHeights: [:],
            lineTargetIndices: [:],
            lineInterval: nil,
            hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 100),
            isWaveTimelineDiagnosticsEnabled: false,
            isManualScrolling: false,
            reduceMotion: false,
            suppressInitialMotion: false,
            pendingTranslationLineIndices: [],
            showTranslation: showTranslation,
            isTranslating: false,
            translationFailed: false,
            interludeAfterIndex: nil,
            directSnapRequest: nil,
            controlsVisible: true,
            musicController: MusicController(preview: true),
            onLineTap: { _ in },
            onDirectSnapConsumed: { _ in },
            onManualScrollStarted: { _ in },
            onManualScrollDelta: { _, _ in },
            onManualScrollEnded: {},
            onManualScrollRecovered: {},
            onManualScrollChromeReset: nil,
            onHeightMeasured: { _, _ in },
            lineMotionSamplingEnabled: false,
            lineMotionFocusedSamplingUntil: Date.distantPast,
            lineMotionFirstRealDisplayIndex: 0,
            onLineMotionFrames: { _, _, _, _ in }
        )
    }

    /// An unchanged re-layout must not spin up the NSLayoutManager text-measurement stack again.
    @MainActor
    func test_repeatedIdenticalLayout_doesNotReMeasureText() {
        let width: CGFloat = 320
        let r = row("Now that I have found you", translation: "既然我找到了你")
        let view = NativeLyricsRowView(frame: .zero)
        hostInWindow(view)
        view.configure(row: r, configuration: configuration(rows: [r], rowWidth: width, showTranslation: true))
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))

        // First layout: cache miss → measures main + translation text.
        NativeLyricsTextMeasurement.debugMeasureCount = 0
        view.debugInvokeLayoutDirectly()
        let afterFirst = NativeLyricsTextMeasurement.debugMeasureCount
        XCTAssertGreaterThan(afterFirst, 0, "first layout must measure text at least once")

        // Second + third identical layouts: cache hit → no new measurement.
        view.debugInvokeLayoutDirectly()
        view.debugInvokeLayoutDirectly()
        XCTAssertEqual(
            NativeLyricsTextMeasurement.debugMeasureCount, afterFirst,
            "an unchanged re-layout must not re-measure text (this is the scroll CPU regression guard)"
        )
    }

    /// A genuine content change must invalidate the memo and re-measure — otherwise the cache
    /// would serve a stale layout (wrong text-layer frames after translation arrives / width change).
    @MainActor
    func test_contentChange_reMeasuresText() {
        let width: CGFloat = 320
        let bare = row("Now that I have found you")
        let view = NativeLyricsRowView(frame: .zero)
        hostInWindow(view)
        view.configure(row: bare, configuration: configuration(rows: [bare], rowWidth: width, showTranslation: true))
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))
        view.debugInvokeLayoutDirectly()

        // Translation arrives for the same row → layout output changes → must re-measure.
        let translated = row("Now that I have found you", translation: "既然我找到了你")
        view.configure(row: translated, configuration: configuration(rows: [translated], rowWidth: width, showTranslation: true))
        view.frame = CGRect(x: 0, y: 0, width: width, height: view.measuredHeight(width: width))

        NativeLyricsTextMeasurement.debugMeasureCount = 0
        view.debugInvokeLayoutDirectly()
        XCTAssertGreaterThan(
            NativeLyricsTextMeasurement.debugMeasureCount, 0,
            "a content change (translation arrival) must invalidate the memo and re-measure"
        )
    }
}
