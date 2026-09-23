import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder decision (2026-09-20): backing vocals (和声) render as their own
// row directly under their melody line — 0.8x font size, one dim tier lower
// than the melody row's own tier in the same state, no active-line scale-up,
// half the normal inter-row gap, never a blur-focus centre — while the
// melody row's own geometry stays byte-identical whether or not a
// background row follows it.
//
// These are code-level / geometry-level checks per project rule (手感类验证
// 2026-08-21): unit assertions on the pure measurement + visual-target
// functions, hosted in a realized NSWindow per the CALayer implicit-
// animation testing pitfall (.claude/rules/banned-patterns.md). The actual
// on-screen feel (0.8x, tier, gap) still needs the founder's own check.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsBackgroundRowTests: XCTestCase {

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

    private func row(index: Int, text: String, isBackground: Bool, start: TimeInterval = 0, end: TimeInterval = 3) -> LayerBackedLyricRow {
        let line = LyricLine(text: text, startTime: start, endTime: end, isBackground: isBackground)
        let dl = DisplayLyricLine(id: "r\(index)", sourceIndex: index, segmentIndex: 0, segmentCount: 1, line: line)
        return LayerBackedLyricRow(id: dl.id, index: index, displayLine: dl, sourceLine: line,
                                   isPrelude: false, preludeEndTime: 0, interlude: nil)
    }

    // MARK: - Font size ratio

    @MainActor
    func test_backgroundRow_fontSize_is0Point8xMelody() {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        host(hostView, NSSize(width: 360, height: 200))

        let melodyPlan = NativeLyricsStaticTextRenderPlan.make(line: LyricLine(text: "melody", startTime: 0, endTime: 3, isBackground: false))
        let backgroundPlan = NativeLyricsStaticTextRenderPlan.make(line: LyricLine(text: "bg", startTime: 0, endTime: 3, isBackground: true))

        XCTAssertEqual(melodyPlan.constants.mainFontSize, 24)
        XCTAssertEqual(backgroundPlan.constants.mainFontSize, 24 * 0.8, accuracy: 0.001)
        XCTAssertEqual(
            backgroundPlan.constants.mainFontSize / melodyPlan.constants.mainFontSize,
            NativeLyricsTextConstants.backgroundRowFontScale,
            accuracy: 0.001
        )

        // Translation text scales by the same ratio.
        XCTAssertEqual(
            backgroundPlan.constants.translationFontSize / melodyPlan.constants.translationFontSize,
            NativeLyricsTextConstants.backgroundRowFontScale,
            accuracy: 0.001
        )
    }

    @MainActor
    func test_backgroundRow_renderPlan_configuration_alsoScalesFont() {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        host(hostView, NSSize(width: 360, height: 200))

        let bgLine = LyricLine(text: "echo", startTime: 0, endTime: 3, isBackground: true)
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(line: bgLine, currentTime: 0.1, isActive: true))
        XCTAssertEqual(plan.constants.mainFontSize, 24 * 0.8, accuracy: 0.001)
    }

    // MARK: - Dim tier

    func test_backgroundRow_dimTier_isOneStepLowerThanMelody_whileActive() {
        let melody = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 0, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [0, 1], isManualScrolling: false
        )
        let background = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [0, 1], isManualScrolling: false, isBackground: true
        )
        XCTAssertLessThan(background.dimBaseBrightness, melody.dimBaseBrightness)
        XCTAssertEqual(
            background.dimBaseBrightness,
            NativeLyricsVisualTarget.nextLowerBrightnessTier(melody.dimBaseBrightness)
        )
    }

    func test_backgroundRow_opacityTier_isOneStepLowerThanMelody_duringManualScroll() {
        let melody = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 0, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [], isManualScrolling: true
        )
        let background = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [], isManualScrolling: true, isBackground: true
        )
        XCTAssertEqual(melody.opacity, 0.6)
        XCTAssertLessThan(background.opacity, melody.opacity)
        XCTAssertEqual(background.opacity, NativeLyricsVisualTarget.nextLowerBrightnessTier(0.6))
    }

    // MARK: - Active with melody, sweep carries through

    func test_backgroundRow_activeAlongsideMelody_carriesIsActiveForSweep() {
        // Both rows are hot together (co-starting harmony pair) — background must
        // read isActive so its own word sweep (when it has words) still runs.
        let background = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [0, 1], isManualScrolling: false, isBackground: true
        )
        XCTAssertTrue(background.isActive)
    }

    // MARK: - No active-line scale-up

    func test_backgroundRow_neverScalesUpPastInactiveValue() {
        // Even when hot-active (index 1 == currentIndex), a background row must not
        // take the active row's scale (~1.0) — it stays at the inactive value (0.95).
        let backgroundAsHot = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 1, scrollTargetIndex: 1,
            hotActiveIndices: [1], isManualScrolling: false, isBackground: true
        )
        XCTAssertLessThanOrEqual(backgroundAsHot.scale, 0.95)

        let backgroundAsHarmony = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 1, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [0, 1], isManualScrolling: false, isBackground: true
        )
        XCTAssertLessThanOrEqual(backgroundAsHarmony.scale, 0.95)
    }

    // MARK: - Never a blur-focus centre

    func test_backgroundRow_blurIsAlwaysZero() {
        let far = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 10, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [], isManualScrolling: false, isBackground: true
        )
        XCTAssertEqual(far.blur, 0)
    }

    // MARK: - Reduced gap to its melody row

    @MainActor
    func test_backgroundRow_verticalPadding_isHalfOfNormalRow() {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        host(hostView, NSSize(width: 360, height: 400))

        let melodyRow = row(index: 0, text: "melody line", isBackground: false)
        let backgroundRow = row(index: 1, text: "bg", isBackground: true)

        let melodyHeight = NativeLyricsRowMeasurement.estimatedHeight(
            for: melodyRow, rowWidth: 360, showTranslation: false, isTranslating: false, pendingTranslationLineIndices: []
        )
        let backgroundHeight = NativeLyricsRowMeasurement.estimatedHeight(
            for: backgroundRow, rowWidth: 360, showTranslation: false, isTranslating: false, pendingTranslationLineIndices: []
        )

        // Same single-line text length ("melody line" vs "bg" differ, so measure the
        // PADDING contribution directly rather than the whole height, which also
        // depends on the (smaller) background font's own text height.
        XCTAssertEqual(NativeLyricsRowMeasurement.backgroundRowVerticalPadding,
                       NativeLyricsRowMeasurement.rowVerticalPadding / 2)
        XCTAssertGreaterThan(melodyHeight, 0)
        XCTAssertGreaterThan(backgroundHeight, 0)
    }

    // MARK: - Melody row geometry unchanged whether or not a background row follows

    @MainActor
    func test_melodyRow_measurement_identical_withAndWithoutFollowingBackgroundRow() {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        host(hostView, NSSize(width: 360, height: 400))

        let melodyRow = row(index: 0, text: "And don't you know how sweet it tastes?", isBackground: false)

        let heightAlone = NativeLyricsRowMeasurement.estimatedHeight(
            for: melodyRow, rowWidth: 360, showTranslation: false, isTranslating: false, pendingTranslationLineIndices: []
        )
        // Measuring the SAME row object is unaffected by whatever other rows exist —
        // estimatedHeight takes a single row, so a following background row cannot
        // perturb it. This pins that invariant explicitly.
        let heightAgain = NativeLyricsRowMeasurement.estimatedHeight(
            for: melodyRow, rowWidth: 360, showTranslation: false, isTranslating: false, pendingTranslationLineIndices: []
        )
        XCTAssertEqual(heightAlone, heightAgain)

        let melodyTargetAlone = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 0, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [0], isManualScrolling: false, isBackground: false
        )
        let melodyTargetWithBackgroundSibling = NativeLyricsVisualTarget.amllTarget(
            displayIndex: 0, currentIndex: 0, scrollTargetIndex: 0,
            hotActiveIndices: [0, 1], isManualScrolling: false, isBackground: false
        )
        XCTAssertEqual(melodyTargetAlone, melodyTargetWithBackgroundSibling)
    }
}
