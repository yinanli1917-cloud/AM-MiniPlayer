/**
 * [INPUT]: EdgeMotionGate (deferral of non-urgent main-thread work while an
 *          edge animation runs), LiquidEdgeController (holds the gate for the
 *          length of a motion).
 * [OUTPUT]: Tests: immediate when idle, deferred and ordered when held,
 *           reference counted, one item per run-loop turn on drain, held by a
 *           real controller exactly while it animates.
 * [POS]: Guards the frame-budget mechanism of the liquid edge.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

@MainActor
final class EdgeMotionGateTests: XCTestCase {
    private func spin(_ s: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    func test_idle_runsAtOnce() {
        let gate = EdgeMotionGate()
        var ran = false
        gate.whenIdle { ran = true }
        XCTAssertTrue(ran)
        XCTAssertFalse(gate.isActive)
    }

    func test_held_defersInOrder_thenRunsAfterEnd() {
        let gate = EdgeMotionGate()
        var order: [Int] = []
        gate.begin()
        XCTAssertTrue(gate.isActive)
        gate.whenIdle { order.append(1) }
        gate.whenIdle { order.append(2) }
        spin()
        XCTAssertEqual(order, [], "nothing runs while the motion holds the gate")
        gate.end()
        XCTAssertEqual(order, [], "end() itself does not run the backlog inside the motion's last turn")
        spin(0.2)
        XCTAssertEqual(order, [1, 2])
        XCTAssertFalse(gate.isActive)
    }

    func test_referenceCounted_retargetKeepsOneHoldPerBegin() {
        let gate = EdgeMotionGate()
        var ran = false
        gate.begin(); gate.begin()
        gate.whenIdle { ran = true }
        gate.end()
        spin()
        XCTAssertFalse(ran, "one hold is still outstanding")
        gate.end()
        spin()
        XCTAssertTrue(ran)
    }

    func test_backlogDrainsOneItemPerTurn() {
        let gate = EdgeMotionGate()
        var turnsSeen: [Int] = []
        var turn = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in turn += 1 }!
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopObserverInvalidate(observer) }
        gate.begin()
        for _ in 0..<4 { gate.whenIdle { turnsSeen.append(turn) } }
        gate.end()
        spin(0.2)
        XCTAssertEqual(turnsSeen.count, 4)
        XCTAssertEqual(Set(turnsSeen).count, 4, "each deferred item gets its own run-loop turn, so the backlog cannot become one long stall: \(turnsSeen)")
    }

    func test_newWorkDuringDrain_queuesBehindTheBacklog() {
        let gate = EdgeMotionGate()
        var order: [String] = []
        gate.begin()
        gate.whenIdle { order.append("a"); gate.whenIdle { order.append("c") } }
        gate.whenIdle { order.append("b") }
        gate.end()
        spin(0.2)
        XCTAssertEqual(order, ["a", "b", "c"])
    }

    func test_motionStartingMidDrain_holdsTheRest() {
        let gate = EdgeMotionGate()
        var order: [Int] = []
        gate.begin()
        gate.whenIdle { order.append(1); gate.begin() }
        gate.whenIdle { order.append(2) }
        gate.end()
        spin(0.2)
        XCTAssertEqual(order, [1], "a new motion keeps the remainder queued")
        gate.end()
        spin(0.2)
        XCTAssertEqual(order, [1, 2])
    }

    // MARK: - The controller holds the gate exactly while it animates

    private var now: CFTimeInterval = 5000
    private var card: SnappablePanel!
    private var controller: LiquidEdgeController!

    private func makeController(gate: EdgeMotionGate) throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let v = screen.visibleFrame
        let size = NSSize(width: 250, height: 316)
        card = SnappablePanel(contentRect: NSRect(x: v.maxX - size.width - 16, y: v.maxY - size.height - 16, width: size.width, height: size.height),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.level = .floating
        card.isOpaque = false
        card.contentView = NSView()
        card.orderFront(nil)
        controller = LiquidEdgeController(card: card)
        controller.clock = { [unowned self] in self.now }
        controller.drivesFrames = false
        controller.reduceMotionOverride = false
        controller.gate = gate
    }

    override func tearDown() {
        controller?.reset()
        controller?.stageWindow?.orderOut(nil)
        card?.orderOut(nil)
        controller = nil
        card = nil
        super.tearDown()
    }

    private func settle() {
        var frames = 0
        while controller.isAnimating, frames < 600 {
            now += 1.0 / 120
            controller.tick(at: now)
            frames += 1
        }
    }

    func test_controller_holdsGateWhileAnimating_andReleasesAtRest() throws {
        let gate = EdgeMotionGate()
        try makeController(gate: gate)
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(controller.collapse(to: .right))
        XCTAssertTrue(gate.isActive, "collapse animates: non-urgent work waits")
        now += 0.1
        controller.tick(at: now)
        XCTAssertTrue(gate.isActive)
        settle()
        XCTAssertFalse(gate.isActive, "tucked at rest: the frame budget is free again")

        controller.hoverEntered()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // dwell
        XCTAssertTrue(gate.isActive, "the peek is a motion too")
        settle()
        XCTAssertFalse(gate.isActive)
    }

    func test_controller_interruptedMotion_isOneHold() throws {
        let gate = EdgeMotionGate()
        try makeController(gate: gate)
        XCTAssertTrue(controller.collapse(to: .right))
        settle()
        controller.hoverEntered()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        now += 0.05
        controller.tick(at: now)
        controller.expand() // retargets the running motion
        settle()
        XCTAssertFalse(gate.isActive, "a retarget must not leave a hold behind")
    }

    func test_controller_resetMidMotion_releasesTheGate() throws {
        let gate = EdgeMotionGate()
        try makeController(gate: gate)
        XCTAssertTrue(controller.collapse(to: .right))
        now += 0.05
        controller.tick(at: now)
        XCTAssertTrue(gate.isActive)
        controller.reset()
        XCTAssertFalse(gate.isActive)
    }
}
