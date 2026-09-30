/**
 * [INPUT]: TourRealPanelFixture (the REAL panel + MiniPlayerView + TourController and its real windows).
 * [OUTPUT]: TourGestureRoutingTests — WindowServer-level routing of the move step's two-finger drag.
 * [POS]: Tests. The earlier test posted events straight to `panel.sendEvent`, which skips routing and
 *        gave a false green (founder 2026-09-29: the drag does nothing during the move step). Here the
 *        target window of every sampled moment is decided by WindowServer's own hit test
 *        (`NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`), never by the test.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourGestureRoutingTests: XCTestCase {
    private var f: TourRealPanelFixture!
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    private let allButMoveAndBack: Set<TourStep> = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])

    private func tourWindows() -> [(String, NSWindow)] {
        var out: [(String, NSWindow)] = []
        if let w = f.controller.debugCardWindow { out.append(("card", w)) }
        if let w = f.controller.debugOverlayWindow { out.append(("ring", w)) }
        if let w = f.controller.debugFeedback.debugSparkOverlay.window { out.append(("fx", w)) }
        return out
    }

    /// Who WindowServer says gets a scroll at `p` (screen, y up).
    private func topWindowNumber(at p: NSPoint) -> Int { NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0) }

    private func describe(_ n: Int) -> String {
        if n == f.panel.windowNumber { return "PANEL" }
        for (name, w) in tourWindows() where w.windowNumber == n { return "TOUR:\(name)" }
        return "other(\(n))"
    }

    /// Control experiment: does the hit test honour ignoresMouseEvents at all?
    func test_control_hitTestHonoursIgnoresMouseEvents() throws {
        f = TourRealPanelFixture(page: .album)
        let centre = NSPoint(x: f.panel.frame.midX, y: f.panel.frame.midY)
        let cover = NSWindow(contentRect: f.panel.frame.insetBy(dx: 20, dy: 20), styleMask: [.borderless], backing: .buffered, defer: false)
        cover.isReleasedWhenClosed = false
        cover.level = .floating + 1
        cover.backgroundColor = .clear
        cover.isOpaque = false
        cover.ignoresMouseEvents = false
        cover.orderFrontRegardless()
        f.spin(0.3)
        XCTAssertEqual(topWindowNumber(at: centre), cover.windowNumber, "a window that takes mouse events, on top, wins the hit test")
        cover.ignoresMouseEvents = true
        f.spin(0.3)
        XCTAssertEqual(topWindowNumber(at: centre), f.panel.windowNumber, "the same window click-through no longer does")
        cover.orderOut(nil)
    }

    func test_moveStep_everyMoment_theTopmostWindowAtThePanelIsThePanel() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        var bad: [String] = []
        let t0 = Date()
        var samples = 0
        while Date().timeIntervalSince(t0) < 7 {
            f.spin(0.05)
            let fr = f.panel.frame
            for (fx, fy) in [(0.5, 0.5), (0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8), (0.5, 0.15)] {
                let p = NSPoint(x: fr.minX + fr.width * fx, y: fr.minY + fr.height * fy)
                let n = topWindowNumber(at: p)
                samples += 1
                if n != f.panel.windowNumber {
                    bad.append(String(format: "t=%.2f (%.1f,%.1f) -> %@", Date().timeIntervalSince(t0), fx, fy, describe(n)))
                }
            }
        }
        print("[routing] samples=\(samples) bad=\(bad.count)")
        for w in tourWindows() { print("[routing] \(w.0) level=\(w.1.level.rawValue) ignores=\(w.1.ignoresMouseEvents) frame=\(w.1.frame)") }
        print("[routing] panel level=\(f.panel.level.rawValue) frame=\(f.panel.frame)")
        XCTAssertTrue(bad.isEmpty, "a tour window sits over the panel: \(bad.prefix(8))")
    }

    /// Every step of the tour, on both pages, panel in every corner: WindowServer's topmost window at the panel's points is the panel.
    func test_everyStep_everyCorner_thePanelOwnsItsOwnPixels() throws {
        var bad: [String] = []
        for corner in [ScreenCorner.topRight, .bottomRight, .topLeft, .bottomLeft] {
            for (i, step) in TourStep.orderedSteps.enumerated() where step != .back {
                for page in [PlayerPage.album, .lyrics] {
                    f = TourRealPanelFixture(corner: corner, page: page)
                    let done = Set(TourStep.orderedSteps.prefix(i))
                    f.controller.send(step == .connect ? .launch : .resume(completed: done))
                    f.spin(1.6)
                    let fr = f.panel.frame
                    for (fx, fy) in [(0.5, 0.5), (0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)] {
                        let p = NSPoint(x: fr.minX + fr.width * fx, y: fr.minY + fr.height * fy)
                        let n = topWindowNumber(at: p)
                        if n != f.panel.windowNumber { bad.append("\(corner) \(step) \(page) (\(fx),\(fy)) -> \(describe(n))") }
                    }
                    f.tearDown(); f = nil
                }
            }
        }
        print("[routing] sweep bad=\(bad.count) \(bad.prefix(6))")
        XCTAssertTrue(bad.isEmpty, "\(bad.prefix(8))")
    }

    /// Where does a two-finger drag of a given size leave a panel that starts in the top-right corner?
    /// (Candidate (e): can "nudge it to a corner" from the corner the panel already sits in ever work?)
    func test_nudgeFromTopRight_whatEachGestureSizeDoes() throws {
        struct Case { let name: String; let dx: CGFloat; let dy: CGFloat; let steps: Int; let stepMs: Double }
        let cases = [
            Case(name: "tiny push  left-down  (12 x (-3,+3))", dx: -3, dy: 3, steps: 12, stepMs: 16),
            Case(name: "light push left-down  (12 x (-8,+6))", dx: -8, dy: 6, steps: 12, stepMs: 16),
            Case(name: "medium push left-down (12 x (-20,+15))", dx: -20, dy: 15, steps: 12, stepMs: 16),
            Case(name: "firm push  left-down  (12 x (-40,+30))", dx: -40, dy: 30, steps: 12, stepMs: 16),
            Case(name: "light push down       (12 x (0,+10))", dx: 0, dy: 10, steps: 12, stepMs: 16),
            Case(name: "medium push down      (12 x (0,+25))", dx: 0, dy: 25, steps: 12, stepMs: 16),
            Case(name: "medium push left      (12 x (-25,0))", dx: -25, dy: 0, steps: 12, stepMs: 16),
        ]
        for c in cases {
            f = TourRealPanelFixture(page: .album)
            let start = f.panel.frame.origin
            f.controller.send(.resume(completed: allButMoveAndBack))
            f.spin(1.0)
            if let e = f.gestureEvent(dx: 0, dy: 0, phase: .began) { f.panel.sendEvent(e) }
            for _ in 0..<c.steps {
                if let e = f.gestureEvent(dx: c.dx, dy: c.dy, phase: .changed) { f.panel.sendEvent(e) }
                f.spin(c.stepMs / 1000)
            }
            let held = f.panel.frame.origin
            if let e = f.gestureEvent(dx: 0, dy: 0, phase: .ended) { f.panel.sendEvent(e) }
            f.spin(1.6)
            let end = f.panel.frame.origin
            let corner = f.panel.currentCorner()
            print("[routing] \(c.name): followed fingers by \(Int(held.x - start.x)),\(Int(held.y - start.y)) -> settled at \(String(describing: corner)) (moved \(Int(end.x - start.x)),\(Int(end.y - start.y))) beat1=\(f.controller.state.phase)")
            f.tearDown(); f = nil
        }
    }
}
