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

    /// A window of THIS process. (Another app's window over the panel — a notification banner in the top-right corner, say —
    /// is not the tour's doing and must not fail these tests; it did once, on the panel's top corners.)
    private func isOurs(_ windowNumber: Int) -> Bool { NSApp.window(withWindowNumber: windowNumber) != nil }

    /// Who WindowServer says gets a scroll at `p` (screen, y up).
    private func topWindowNumber(at p: NSPoint) -> Int { NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0) }

    private func describe(_ n: Int) -> String {
        if n == f.panel.windowNumber { return "PANEL" }
        for (name, w) in tourWindows() where w.windowNumber == n { return "TOUR:\(name)" }
        if let ours = NSApp.window(withWindowNumber: n) { return "OURS:\(type(of: ours)) level=\(ours.level.rawValue) frame=\(ours.frame) visible=\(ours.isVisible)" }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let info = list.first { ($0[kCGWindowNumber as String] as? Int) == n }
        return "other(\(n)) owner=\(info?[kCGWindowOwnerName as String] ?? "?") layer=\(info?[kCGWindowLayer as String] ?? "?") bounds=\(info?[kCGWindowBounds as String] ?? "?")"
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
                if isOurs(n), n != f.panel.windowNumber {
                    bad.append(String(format: "t=%.2f (%.1f,%.1f) -> %@", Date().timeIntervalSince(t0), fx, fy, describe(n)))
                }
            }
        }
        print("[routing] samples=\(samples) bad=\(bad.count)")
        for w in tourWindows() { print("[routing] \(w.0) level=\(w.1.level.rawValue) ignores=\(w.1.ignoresMouseEvents) frame=\(w.1.frame)") }
        print("[routing] panel level=\(f.panel.level.rawValue) frame=\(f.panel.frame)")
        XCTAssertTrue(bad.isEmpty, "a tour window sits over the panel: \(bad.prefix(8))")
    }

    /// The move step and the step before it, on both pages, panel in a corner on each side: WindowServer's topmost
    /// window at the panel's points is the panel. (The full 7 steps x 4 corners x 2 pages sweep, 140 s, found nothing either.)
    func test_moveStepAndNeighbour_theTopmostWindowAtThePanelIsThePanel() throws {
        var bad: [String] = []
        for corner in [ScreenCorner.topRight, .bottomLeft] {
            for step in [TourStep.translate, .moveTuck] {
                for page in [PlayerPage.album, .lyrics] {
                    f = TourRealPanelFixture(corner: corner, page: page)
                    let i = TourStep.orderedSteps.firstIndex(of: step)!
                    f.controller.send(.resume(completed: Set(TourStep.orderedSteps.prefix(i))))
                    f.spin(1.4)
                    let fr = f.panel.frame
                    for (fx, fy) in [(0.5, 0.5), (0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9)] {
                        let p = NSPoint(x: fr.minX + fr.width * fx, y: fr.minY + fr.height * fy)
                        let n = topWindowNumber(at: p)
                        if isOurs(n), n != f.panel.windowNumber { bad.append("\(corner) \(step) \(page) (\(fx),\(fy)) -> \(describe(n))") }
                    }
                    f.tearDown(); f = nil
                }
            }
        }
        XCTAssertTrue(bad.isEmpty, "\(bad.prefix(8))")
    }

    /// Candidate (e) — can "nudge it to a corner" from the corner the panel already sits in work? It does, with the panel
    /// following the fingers 1.5x and, on release, landing in the corner its projected centre is nearest (`calculateTargetCorner`):
    /// a tiny push settles straight back in the same corner (the beat still completes: any settle in a corner counts), a
    /// medium push down lands in the other corner of that edge, a firm one across the screen. Nothing swallows the gesture.
    func test_nudgeFromTopRight_followsTheFingers_andSettlesInTheNearestCornerOfWhereItWouldLand() throws {
        struct Case { let name: String; let dx: CGFloat; let dy: CGFloat; let lands: ScreenCorner }
        let cases = [
            Case(name: "tiny push left-down (12 x (-3,+3))", dx: -3, dy: 3, lands: .topRight),
            Case(name: "medium push down (12 x (0,+25))", dx: 0, dy: 25, lands: .bottomRight),
            Case(name: "firm push left-down (12 x (-40,+30))", dx: -40, dy: 30, lands: .bottomLeft),
        ]
        for c in cases {
            f = TourRealPanelFixture(page: .album)
            let start = f.panel.frame.origin
            f.controller.send(.resume(completed: allButMoveAndBack))
            f.spin(1.0)
            if let e = f.gestureEvent(dx: 0, dy: 0, phase: .began) { f.panel.sendEvent(e) }
            for _ in 0..<12 {
                if let e = f.gestureEvent(dx: c.dx, dy: c.dy, phase: .changed) { f.panel.sendEvent(e) }
                f.spin(0.016)
            }
            let held = f.panel.frame.origin
            XCTAssertEqual(held.x - start.x, 12 * c.dx * 1.5, accuracy: 10, "\(c.name): the panel follows the fingers (1.5x) while they are down")
            XCTAssertEqual(held.y - start.y, -12 * c.dy * 1.5, accuracy: 10, "\(c.name)")
            if let e = f.gestureEvent(dx: 0, dy: 0, phase: .ended) { f.panel.sendEvent(e) }
            XCTAssertTrue(f.wait(3) { f.panel.currentCorner() == c.lands }, "\(c.name): settles in \(c.lands), is at \(String(describing: f.panel.currentCorner()))")
            XCTAssertTrue(f.wait(2) { f.controller.state.phase == .step(.moveTuck, beats: [true, false]) }, "\(c.name): the first beat completes")
            f.tearDown(); f = nil
        }
    }
}
