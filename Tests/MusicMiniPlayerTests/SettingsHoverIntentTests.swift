// ──────────────────────────────────────────────
// SettingsHoverIntentTests — settings rows: highlight now, demo after a rest
//
// Founder report (2026-09-29, first settings build): hovering a row gave no
// visible feedback and animation "started at once". The contract now:
//   - the hovered row lights up IMMEDIATELY (highlightedRow);
//   - the demo stage changes only after the pointer has rested on the row for
//     150ms with ≤4pt drift (the progress bar's ProgressHoverIntentEngine
//     numbers); a fast pass-through never changes it;
//   - moving to another row makes that row earn its own dwell;
//   - leaving all rows leaves the stage on the last committed still;
//   - an idle window has no timer armed (zero work with no hover).
// Fake clock throughout — nothing sleeps.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsHoverIntentTests: XCTestCase {

    /// Deterministic clock + scheduler: `advance(to:)` fires every armed,
    /// un-cancelled work item whose due time has been reached, in order.
    private final class FakeClock {
        var now: TimeInterval = 0
        private var pending: [(due: TimeInterval, item: DispatchWorkItem)] = []

        func schedule(_ delay: TimeInterval, _ item: DispatchWorkItem) {
            pending.append((now + delay, item))
        }

        func advance(to target: TimeInterval) {
            while let next = pending.filter({ $0.due <= target + 1e-9 }).min(by: { $0.due < $1.due }) {
                pending.removeAll { $0.item === next.item }
                now = max(now, next.due)
                if !next.item.isCancelled { next.item.perform() }
            }
            now = target
        }
    }

    private var clock: FakeClock!
    private var model: SettingsHoverIntentModel!

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        model = SettingsHoverIntentModel()
        model.now = { [clock] in clock!.now }
        model.schedule = { [clock] delay, item in clock!.schedule(delay, item) }
    }

    private let pointA = CGPoint(x: 100, y: 20)

    // MARK: highlight

    func test_hoveredRow_isHighlightedImmediately_beforeAnyDwell() {
        model.pointerEntered(.showInDock, at: pointA)
        XCTAssertEqual(model.highlightedRow, .showInDock, "the row must light up on entry, not after the dwell")
        XCTAssertNil(model.stageDemo, "…while the stage is still untouched")
        model.pointerExited(.showInDock)
        XCTAssertNil(model.highlightedRow)
    }

    // MARK: dwell gate

    func test_fastPassThrough_neverChangesTheStage() {
        model.pointerEntered(.showInDock, at: pointA)
        clock.advance(to: 0.149)
        model.pointerExited(.showInDock)
        clock.advance(to: 2)
        XCTAssertNil(model.stageDemo, "a pass shorter than 150ms must produce zero demo change")
        XCTAssertFalse(model.hasPendingTimer)
    }

    func test_restingFor150ms_commitsTheRow() {
        model.pointerEntered(.showInDock, at: pointA)
        clock.advance(to: 0.149)
        XCTAssertNil(model.stageDemo, "149ms is not yet a rest")
        clock.advance(to: 0.150)
        XCTAssertEqual(model.stageDemo, .showInDock)
    }

    func test_jitterWithin4pt_doesNotDelayTheCommit() {
        model.pointerEntered(.showInDock, at: pointA)
        clock.advance(to: 0.05)
        model.pointerMoved(.showInDock, to: CGPoint(x: pointA.x + 3, y: pointA.y))
        clock.advance(to: 0.10)
        model.pointerMoved(.showInDock, to: CGPoint(x: pointA.x, y: pointA.y + 3))
        clock.advance(to: 0.150)
        XCTAssertEqual(model.stageDemo, .showInDock, "hand tremor ≤4pt must not restart the dwell")
    }

    func test_movingMoreThan4pt_restartsTheDwell() {
        model.pointerEntered(.showInDock, at: pointA)
        clock.advance(to: 0.10)
        model.pointerMoved(.showInDock, to: CGPoint(x: pointA.x + 30, y: pointA.y))
        clock.advance(to: 0.150)
        XCTAssertNil(model.stageDemo, "still travelling: the original deadline must not commit")
        clock.advance(to: 0.249)
        XCTAssertNil(model.stageDemo)
        clock.advance(to: 0.250)
        XCTAssertEqual(model.stageDemo, .showInDock, "150ms after the pointer settled again")
    }

    func test_continuousSweepAcrossOneRow_neverCommits() {
        model.pointerEntered(.showInDock, at: pointA)
        for step in 1...10 {
            clock.advance(to: Double(step) * 0.05)
            model.pointerMoved(.showInDock, to: CGPoint(x: pointA.x + CGFloat(step) * 12, y: pointA.y))
        }
        XCTAssertNil(model.stageDemo, "a pointer that keeps moving >4pt per step never rests")
    }

    // MARK: row to row

    func test_movingToAnotherRow_keepsTheOldStillUntilTheNewRowDwells() {
        model.pointerEntered(.launchAtLogin, at: pointA)
        clock.advance(to: 0.2)
        XCTAssertEqual(model.stageDemo, .launchAtLogin)

        model.pointerExited(.launchAtLogin)
        clock.advance(to: 0.21)
        model.pointerEntered(.showInDock, at: pointA)
        XCTAssertEqual(model.highlightedRow, .showInDock)
        XCTAssertEqual(model.stageDemo, .launchAtLogin, "no swap before the new row rests")

        clock.advance(to: 0.21 + 0.149)
        XCTAssertEqual(model.stageDemo, .launchAtLogin)
        clock.advance(to: 0.21 + 0.150)
        XCTAssertEqual(model.stageDemo, .showInDock)
    }

    func test_fastSweepDownSeveralRows_changesNothing() {
        let rows: [SettingsDemo] = [.launchAtLogin, .showInDock, .gettingToKnowNanoPod, .musicAutomation]
        var t = 0.0
        for row in rows {
            model.pointerEntered(row, at: pointA)
            t += 0.05
            clock.advance(to: t)
            model.pointerExited(row)
        }
        clock.advance(to: t + 2)
        XCTAssertNil(model.stageDemo)
    }

    // MARK: leaving

    func test_leavingAllRows_keepsTheLastCommittedStill_andGoesIdle() {
        model.pointerEntered(.showInDock, at: pointA)
        clock.advance(to: 0.2)
        model.pointerExited(.showInDock)
        clock.advance(to: 5)
        XCTAssertEqual(model.stageDemo, .showInDock, "the stage stays on the last still")
        XCTAssertNil(model.highlightedRow)
        XCTAssertFalse(model.hasPendingTimer, "no hover ⇒ no timer ⇒ zero work")
    }

    func test_idleModel_hasNoTimer() {
        XCTAssertFalse(model.hasPendingTimer)
        XCTAssertNil(model.stageDemo)
        XCTAssertNil(model.highlightedRow)
    }

    func test_resetStage_dropsStillAndPendingDecision() {
        model.pointerEntered(.showInDock, at: pointA)
        clock.advance(to: 0.2)
        model.pointerEntered(.launchAtLogin, at: pointA)
        model.resetStage()
        clock.advance(to: 5)
        XCTAssertNil(model.stageDemo)
        XCTAssertNil(model.highlightedRow)
        XCTAssertFalse(model.hasPendingTimer)
    }

    // MARK: numbers

    func test_config_isTheProgressBarsNumbers() {
        XCTAssertEqual(ProgressHoverIntentEngine.Config.default.dwellDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(ProgressHoverIntentEngine.Config.default.movementTolerance, 4.0, accuracy: 0.0001)
    }
}

// ──────────────────────────────────────────────
// MARK: - Real view chain (tracking-area bridge → model → row fill + stage)
// ──────────────────────────────────────────────

/// Drives the REAL SettingsWindowView through the same entry points AppKit
/// uses (`mouseEntered` / `mouseMoved` / `mouseExited` on the row's tracker
/// view), with real (short) waits: the row lights up at once, the stage swaps
/// only after the dwell, and a fast pass leaves the stage byte-identical.
@MainActor
final class SettingsHoverIntentViewTests: XCTestCase {

    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        window?.close()
        window = nil
        SettingsPalette.accentOverride = nil
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func allSubviews(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(allSubviews) }

    private func host() throws -> NSWindow {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.settings-hover.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = .general
        var view = SettingsWindowView(state: state)
        view.automationStatusProvider = { .authorized }
        view.appleMusicStatusProvider = { .notDetermined }
        let controller = NSHostingController(rootView: view.environmentObject(MusicController(preview: true)))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 562))
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        self.window = window
        spin(0.4)
        return window
    }

    private func tracker(_ demo: SettingsDemo, in window: NSWindow) throws -> SettingsRowHoverTrackerView {
        let all = allSubviews(try XCTUnwrap(window.contentView)).compactMap { $0 as? SettingsRowHoverTrackerView }
        return try XCTUnwrap(all.first { $0.demo == demo }, "no tracker for \(demo)")
    }

    private func event(_ type: NSEvent.EventType, in window: NSWindow, at p: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(
            with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
    }

    private func moved(in window: NSWindow, at p: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    /// Pixel bytes of the stage region (top 20…140pt of the content view).
    private func stageBytes(_ window: NSWindow) throws -> [UInt8] {
        let content = try XCTUnwrap(window.contentView)
        let rep = SettingsWindowRenderTests.capture(content)
        let bytesPerRow = rep.bytesPerRow
        let rowsTop = 40, rowsBottom = 280 // 20…140pt at 2x
        let data = try XCTUnwrap(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data + rowsTop * bytesPerRow, count: (rowsBottom - rowsTop) * bytesPerRow))
    }

    /// Colour of the pixel at `local` inside `view`, read from a 2x capture.
    private func pixel(in window: NSWindow, of view: NSView, at local: NSPoint) throws -> [UInt8] {
        let content = try XCTUnwrap(window.contentView)
        let rep = SettingsWindowRenderTests.capture(content)
        let p = view.convert(local, to: content)
        let y = content.isFlipped ? p.y : content.bounds.height - p.y
        let data = try XCTUnwrap(rep.bitmapData)
        let offset = Int(y * 2) * rep.bytesPerRow + Int(p.x * 2) * 4
        return Array(UnsafeBufferPointer(start: data + offset, count: 3))
    }

    func test_realView_rowLightsUpAtOnce_stageSwapsOnlyAfterDwell() throws {
        let window = try host()
        let row = try tracker(.showInDock, in: window)
        let other = try tracker(.launchAtLogin, in: window)
        let restBytes = try stageBytes(window)
        let restRowPixel = try pixel(in: window, of: row, at: NSPoint(x: 4, y: 20))
        let otherRowPixel = try pixel(in: window, of: other, at: NSPoint(x: 4, y: 20))
        XCTAssertEqual(restRowPixel, otherRowPixel, "before hover, rows share one fill")

        let at = NSPoint(x: 100, y: 20)
        row.mouseEntered(with: try event(.mouseEntered, in: window, at: at))
        spin(0.04)
        XCTAssertNotEqual(try pixel(in: window, of: row, at: NSPoint(x: 4, y: 20)), restRowPixel, "the hovered row must light up within a frame or two")
        XCTAssertEqual(try stageBytes(window), restBytes, "40ms in: the stage must not have changed")

        spin(0.6) // 150ms dwell + 220ms cross-fade
        XCTAssertNotEqual(try stageBytes(window), restBytes, "after the rest the stage shows this row's still")

        row.mouseExited(with: try event(.mouseExited, in: window, at: at))
        spin(0.4)
        XCTAssertEqual(try pixel(in: window, of: row, at: NSPoint(x: 4, y: 20)), restRowPixel, "the fill goes away on exit")

        if ProcessInfo.processInfo.environment["NANOPOD_SETTINGS_RENDER_DIR"] != nil {
            row.mouseEntered(with: try event(.mouseEntered, in: window, at: at))
            spin(0.7)
            try SettingsWindowRenderTests.writePNG(
                SettingsWindowRenderTests.capture(try XCTUnwrap(window.contentView)),
                name: "window-general-light-hover-showInDock.png")
            row.mouseExited(with: try event(.mouseExited, in: window, at: at))
        }
    }

    func test_realView_fastPass_leavesTheStageUntouched() throws {
        let window = try host()
        let row = try tracker(.showInDock, in: window)
        let restBytes = try stageBytes(window)
        let at = NSPoint(x: 100, y: 20)
        row.mouseEntered(with: try event(.mouseEntered, in: window, at: at))
        spin(0.06)
        row.mouseExited(with: try event(.mouseExited, in: window, at: at))
        spin(0.6)
        XCTAssertEqual(try stageBytes(window), restBytes, "a 60ms pass must not change the stage at all")
    }

    func test_realView_driftingPointer_doesNotSwapTheStageWhileMoving() throws {
        let window = try host()
        let row = try tracker(.showInDock, in: window)
        let restBytes = try stageBytes(window)
        row.mouseEntered(with: try event(.mouseEntered, in: window, at: NSPoint(x: 20, y: 20)))
        for step in 1...8 { // 8 × 40ms = 320ms of steady travel, 12pt per step
            spin(0.04)
            row.mouseMoved(with: try moved(in: window, at: NSPoint(x: 20 + CGFloat(step) * 12, y: 20)))
        }
        XCTAssertEqual(try stageBytes(window), restBytes, "a pointer that keeps travelling never rests, so the stage stays")
        row.mouseExited(with: try event(.mouseExited, in: window, at: NSPoint(x: 200, y: 20)))
    }
}
