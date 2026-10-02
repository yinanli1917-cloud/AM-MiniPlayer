/**
 * [INPUT]: TourGestureTrace + TourGestureFileWriter; a bare SnappablePanel for the unit tests, TourRealPanelFixture for the
 *          tour-wired ones; ScrollSynth events delivered through NSApp.sendEvent.
 * [OUTPUT]: TourRecordingGestureWriter (the injected sink that remembers which thread wrote) and TourGestureTraceTests.
 * [POS]: Tests. Pins the always-on gesture evidence: nothing standing outside the tour, a bounded ring, only gestures that
 *        look wrong (and the teardown) reach the disk, and never from the main thread.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

/// A sink that records what it was given and whether it was ever called on the main thread.
final class TourRecordingGestureWriter: TourGestureLogWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var storedChunks: [String] = []
    private var storedMainThreadWrites = 0
    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if Thread.isMainThread { storedMainThreadWrites += 1 }
        storedChunks.append(text)
    }
    var chunks: [String] { lock.lock(); defer { lock.unlock() }; return storedChunks }
    var mainThreadWrites: Int { lock.lock(); defer { lock.unlock() }; return storedMainThreadWrites }
    var text: String { chunks.joined() }
}

@MainActor
final class TourGestureTraceTests: XCTestCase {
    private var panel: SnappablePanel!
    private var other: NSWindow!
    private var writer: TourRecordingGestureWriter!
    private var trace: TourGestureTrace!
    private var page = "album"
    private var mouse = NSPoint.zero

    override func setUp() {
        super.setUp()
        let visible = NSScreen.main!.visibleFrame
        let size = NSSize(width: 250, height: 284)
        let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
        panel = SnappablePanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.currentPageProvider = { .album }
        panel.reduceMotionProvider = { true }
        panel.orderFrontRegardless()
        other = NSWindow(contentRect: NSRect(x: visible.minX + 100, y: visible.minY + 100, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFrontRegardless()
        writer = TourRecordingGestureWriter()
        mouse = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        trace = TourGestureTrace(
            environment: TourGestureTrace.Environment(
                page: { [unowned self] in self.page },
                tourState: { "step(corners beats:00)" },
                cardYielded: { false },
                mouseLocation: { [unowned self] in self.mouse },
                topmostWindow: { _, _ in "PANEL" }
            ),
            writer: writer
        )
        // (Long, so a loaded machine cannot judge a gesture mid-way; every test finalizes explicitly through `settle()`.)
        trace.settleDelay = 1.0
    }

    override func tearDown() {
        trace.stop()
        trace.drainWrites()
        panel.orderOut(nil)
        other.orderOut(nil)
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// One event through `NSApp.sendEvent`, aimed at `window` (the panel by default) at its centre.
    private func send(dx: CGFloat = 0, dy: CGFloat = 0, _ phase: NSEvent.Phase, momentum: ScrollSynth.Momentum = .none, to window: NSWindow? = nil) {
        let w: NSWindow = window ?? panel
        guard let e = ScrollSynth.event(dx: dx, dy: dy, phase: phase, momentum: momentum, window: w, at: NSPoint(x: w.frame.midX, y: w.frame.midY)) else { return XCTFail("no event") }
        NSApp.sendEvent(e)
    }

    private func gesture(dx: CGFloat, dy: CGFloat, steps: Int = 10, end: NSEvent.Phase = .ended, to window: NSWindow? = nil) {
        send(.mayBegin, to: window); send(.began, to: window)
        for _ in 0..<steps { send(dx: dx, dy: dy, .changed, to: window); spin(0.004) }
        send(end, to: window)
    }

    private func settle() { spin(0.3); trace.finalizeOpenGesture(); trace.drainWrites() }

    // MARK: - Nothing standing outside the tour

    func test_outsideTheTour_noMonitorsNoObserverNoLoopObserver_andScrollsAreNotSeen() {
        XCTAssertEqual(trace.monitorCount, 0)
        XCTAssertNil(panel.scrollDecisionObserver)
        XCTAssertFalse(trace.hasLoopObserver)
        XCTAssertFalse(trace.isRunning)
        gesture(dx: -10, dy: 8)                     // a scroll while the trace is off
        XCTAssertEqual(trace.gesturesSeen, 0)
        XCTAssertEqual(trace.ring.count, 0, "nothing is recorded")
        XCTAssertEqual(writer.chunks.count, 0)
    }

    func test_running_installsMonitorsAndObserver_stopRemovesAll() {
        trace.start(panel: panel)
        XCTAssertGreaterThanOrEqual(trace.monitorCount, 1)
        XCTAssertNotNil(panel.scrollDecisionObserver)
        send(.mayBegin); send(.began); send(dx: -5, dy: 4, .changed)
        XCTAssertTrue(trace.hasLoopObserver, "the stall watch lives only while a gesture is open")
        trace.stop()
        XCTAssertEqual(trace.monitorCount, 0)
        XCTAssertNil(panel.scrollDecisionObserver)
        XCTAssertFalse(trace.hasLoopObserver)
        XCTAssertFalse(trace.isRunning)
    }

    /// The real controller: nothing before the tour has windows, monitors while it is on screen, nothing again afterwards.
    func test_controller_monitorsOnlyWhileTheTourIsOnScreen() {
        let f = TourRealPanelFixture(page: .album)
        defer { f.tearDown() }
        XCTAssertEqual(f.controller.gestureTrace.monitorCount, 0, "before the tour")
        XCTAssertNil(f.panel.scrollDecisionObserver)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        XCTAssertGreaterThanOrEqual(f.controller.gestureTrace.monitorCount, 1, "while it is on screen")
        XCTAssertNotNil(f.panel.scrollDecisionObserver)
        f.controller.send(.stopTour)
        XCTAssertTrue(f.wait(4) { f.controller.gestureTrace.monitorCount == 0 }, "after teardown")
        XCTAssertNil(f.panel.scrollDecisionObserver)
        XCTAssertFalse(f.controller.gestureTrace.hasLoopObserver)
    }

    // MARK: - Ring

    func test_ring_isBounded() {
        trace.start(panel: panel, installMonitors: false)
        for _ in 0..<5_000 { trace.noteRaise() }
        XCTAssertEqual(trace.ring.count, TourGestureTrace.ringCapacity)
        XCTAssertEqual(trace.ring.elements.count, 400)
        XCTAssertGreaterThan(trace.ring.elements.last!.seq, trace.ring.elements.first!.seq, "oldest first, newest last")
        XCTAssertEqual(writer.chunks.count, 0, "filling the ring writes nothing")
    }

    // MARK: - What reaches the disk

    /// The cursor is over the panel, the fingers travel, and the panel does not move: here because the events were aimed at
    /// some other window. That is a FAILED gesture and it is flushed, with the window the events went to.
    func test_failedGesture_isFlushed_off_theMainThread() {
        trace.start(panel: panel)
        let start = panel.frame.origin
        gesture(dx: -10, dy: 8, to: other)
        settle()
        XCTAssertEqual(panel.frame.origin, start, "the panel did not move")
        XCTAssertEqual(writer.chunks.count, 1, "one flush for the failed gesture")
        let text = writer.text
        XCTAssertTrue(text.contains("END FAILED"), text)
        XCTAssertTrue(text.contains("local(NSWindow#"), "names the window that got the events: \(text)")
        XCTAssertTrue(text.contains("cursor=over-panel"))
        XCTAssertTrue(text.contains("topmost=PANEL"))
        XCTAssertTrue(text.contains("page=album"))
        XCTAssertTrue(text.contains("tour=step(corners beats:00)"))
        XCTAssertTrue(text.contains("routes{none"), "the panel's router never saw it: \(text)")
        XCTAssertEqual(writer.mainThreadWrites, 0, "nothing touched the disk on the main thread")
        trace.stop(); trace.drainWrites()
        XCTAssertEqual(writer.mainThreadWrites, 0, "not at teardown either")
    }

    /// A gesture that moved the panel is the normal case: judged, summarized in memory, never written.
    func test_normalGesture_isNotWritten() {
        trace.start(panel: panel)
        let start = panel.frame.origin
        gesture(dx: -40, dy: 30, steps: 12)
        settle()
        XCTAssertNotEqual(panel.frame.origin, start, "it moved")
        XCTAssertEqual(writer.chunks.count, 0, "nothing flushed for a gesture that worked")
        XCTAssertTrue(trace.ring.elements.contains { $0.text.contains("END ok") }, "but its verdict is in the ring")
        XCTAssertEqual(trace.failuresFlushed, 0)
    }

    /// A gesture shorter than 40 pt of finger travel is not evidence of anything.
    func test_smallGesture_isNotAFailure() {
        trace.start(panel: panel)
        gesture(dx: 0, dy: 0, steps: 5, to: other)
        send(dx: 1, dy: 1, .changed, to: other)
        settle()
        XCTAssertEqual(writer.chunks.count, 0)
    }

    /// Lyrics/playlist pages: a vertical swipe is the content scrolling, not the panel failing to move.
    func test_verticalScrollOnLyricsPage_isNotAFailure() {
        page = "lyrics"
        panel.currentPageProvider = { .lyrics }
        trace.start(panel: panel)
        gesture(dx: 0, dy: 12, steps: 10)
        settle()
        XCTAssertEqual(writer.chunks.count, 0)
    }

    /// Another app got the gesture while the cursor was over the panel (the global monitor's side): FAILED, and says so.
    func test_gestureDeliveredToAnotherApp_overThePanel_isFlagged() {
        trace.start(panel: panel, installMonitors: false)
        guard let e1 = ScrollSynth.event(dx: 0, dy: 0, phase: .began, window: nil, at: mouse),
              let e2 = ScrollSynth.event(dx: -10, dy: 8, phase: .changed, window: nil, at: mouse),
              let e3 = ScrollSynth.event(dx: 0, dy: 0, phase: .ended, window: nil, at: mouse) else { return XCTFail() }
        trace.observe(e1, source: .otherApp)
        for _ in 0..<10 { trace.observe(e2, source: .otherApp) }
        trace.observe(e3, source: .otherApp)
        settle()
        XCTAssertTrue(writer.text.contains("END FAILED"), writer.text)
        XCTAssertTrue(writer.text.contains("OTHER-APP"), writer.text)
    }

    /// The global monitor sees the whole machine: bursts with the cursor elsewhere leave no trace at all.
    func test_otherAppsScrollsElsewhere_areIgnored() {
        trace.start(panel: panel, installMonitors: false)
        mouse = NSPoint(x: panel.frame.minX - 400, y: panel.frame.minY - 400)
        guard let e = ScrollSynth.event(dx: -10, dy: 8, phase: .changed, window: nil, at: mouse) else { return XCTFail() }
        for _ in 0..<20 { trace.observe(e, source: .otherApp) }
        XCTAssertEqual(trace.gesturesSeen, 0)
    }

    /// A cancelled gesture is written even when it is not a failure, because it is the suspected way gestures get lost.
    func test_cancelledGesture_isFlushedAsSuspect() {
        trace.start(panel: panel)
        gesture(dx: -40, dy: 30, steps: 12, end: .cancelled)
        settle()
        XCTAssertTrue(writer.text.contains("SUSPECT(cancelled)"), writer.text)
    }

    func test_teardown_writesTheSummary_andWhatWasNotYetFlushed() {
        trace.start(panel: panel)
        gesture(dx: -40, dy: 30, steps: 12)
        settle()
        XCTAssertEqual(writer.chunks.count, 0)
        trace.stop(); trace.drainWrites()
        XCTAssertEqual(writer.chunks.count, 1)
        XCTAssertTrue(writer.text.contains("tour teardown (1 gestures)"), writer.text)
        XCTAssertTrue(writer.text.contains("END ok"))
        XCTAssertEqual(writer.mainThreadWrites, 0)
    }

    func test_teardownWithNoGesture_writesOneLine() {
        trace.start(panel: panel)
        trace.noteRaise()
        trace.stop(); trace.drainWrites()
        XCTAssertEqual(writer.chunks.count, 1)
        XCTAssertTrue(writer.text.contains("no scroll gesture seen"), writer.text)
        XCTAssertLessThan(writer.text.count, 300)
    }

    // MARK: - Stalls, tour notes

    func test_mainThreadStall_duringAGesture_isRecorded() {
        trace.settleDelay = 2
        trace.start(panel: panel)
        send(.mayBegin); send(.began); send(dx: -5, dy: 4, .changed)
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.09) }
        spin(0.25)
        XCTAssertTrue(trace.ring.elements.contains { $0.text.contains("STALL main thread busy") }, "stall recorded: \(trace.ring.elements.map(\.text).suffix(4))")
        XCTAssertGreaterThanOrEqual(trace.open?.loopStalls ?? 0, 1)
    }

    func test_tourNotes_landInTheGestureTheyHappenedIn() {
        trace.start(panel: panel)
        send(.mayBegin); send(.began)
        trace.noteYield(true); trace.noteRaise(); trace.noteYield(false)
        XCTAssertEqual(trace.open?.yields, 1)
        XCTAssertEqual(trace.open?.restores, 1)
        XCTAssertEqual(trace.open?.raises, 1)
    }

    // MARK: - File writer

    func test_fileWriter_rotatesAndStaysSmall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = TourGestureFileWriter(directory: dir, rotateAt: 2_000)
        let line = String(repeating: "x", count: 99) + "\n"
        for _ in 0..<100 { w.append(line) }
        let fm = FileManager.default
        let size = { (name: String) -> Int in ((try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path))?[.size] as? Int) ?? 0 }
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("tour-gesture.log.1").path), "rotated")
        XCTAssertLessThanOrEqual(size("tour-gesture.log"), 2_000 + 100)
        XCTAssertLessThanOrEqual(size("tour-gesture.log.1"), 2_000 + 100)
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("tour-gesture.log.2").path))
    }

    /// The diagnostics report bundle attaches whichever of the log and its backup exist.
    func test_logLocation_listsTheLogAndItsBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tg-loc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(NanoPodLogLocation.tourGestureLogs(in: dir), [])
        try "x".write(to: dir.appendingPathComponent("tour-gesture.log"), atomically: true, encoding: .utf8)
        XCTAssertEqual(NanoPodLogLocation.tourGestureLogs(in: dir).map(\.lastPathComponent), ["tour-gesture.log"])
        try "y".write(to: dir.appendingPathComponent("tour-gesture.log.1"), atomically: true, encoding: .utf8)
        XCTAssertEqual(NanoPodLogLocation.tourGestureLogs(in: dir).map(\.lastPathComponent), ["tour-gesture.log", "tour-gesture.log.1"])
        XCTAssertEqual(TourGestureFileWriter.fileName, NanoPodLogLocation.tourGestureLogName)
    }

    func test_defaultDirectory_underXCTest_isNotTheFoundersLogs() {
        XCTAssertFalse(TourGestureFileWriter.defaultDirectory().path.contains("/Library/Logs/nanoPod"))
    }

    // MARK: - With the real tour

    /// A real drag through NSApp during the tour: the trace sees it as delivered to the panel, with the panel's decisions,
    /// the card's yield, and the page and tour state.
    func test_realTour_dragIsTraced_withPanelDecisionsAndYield() {
        let f = TourRealPanelFixture(page: .album)
        defer { f.tearDown() }
        f.controller.send(.resume(completed: [.connect, .reveal]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(0.8)
        f.gesture(dx: -10, dy: 8, steps: 12)
        f.spin(0.3)
        let lines = f.controller.gestureTrace.ring.elements.map(\.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("BEGIN") && $0.contains("local(PANEL)") && $0.contains("page=album") && $0.contains("tour=step(corners") }, "\(lines.suffix(12))")
        XCTAssertTrue(lines.contains { $0.contains("route=albumDragApplied") })
        XCTAssertTrue(lines.contains { $0.contains("route=albumEndSpring") && $0.contains("target=") })
        XCTAssertTrue(lines.contains { $0.contains("card yielded") })
        f.controller.gestureTrace.finalizeOpenGesture()
        XCTAssertTrue(f.controller.gestureTrace.ring.elements.contains { $0.text.contains("END ok") && $0.text.contains("projectedCorner=") })
        XCTAssertEqual(f.gestureWriter.chunks.count, 0, "it worked, so nothing is written yet")
    }
}
