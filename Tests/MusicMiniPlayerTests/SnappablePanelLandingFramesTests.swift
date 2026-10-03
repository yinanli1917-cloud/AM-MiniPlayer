/**
 * [INPUT]: MusicMiniPlayerCore's SnappablePanel + TourCornerMatch.
 * [OUTPUT]: SnappablePanelLandingFramesTests — `cornerLandingFrames()` (the frames the tour draws as snap-target marks)
 *           equals where the panel really settles, from every corner's side of the screen.
 * [POS]: Tests. A real SnappablePanel springing for real (display link), never the pure copy of the math.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SnappablePanelLandingFramesTests: XCTestCase {
    private var panel: SnappablePanel!

    override func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        super.tearDown()
    }

    private func makePanel(at origin: NSPoint, size: NSSize = NSSize(width: 250, height: 284)) {
        panel = SnappablePanel(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSView()
        panel.orderFront(nil)
    }

    private func wait(_ timeout: Double = 4, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    func test_fourFrames_haveThePanelsSize_andTheCornerMarginFromTheVisibleFrame() throws {
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        makePanel(at: NSPoint(x: visible.midX, y: visible.midY))
        let frames = panel.cornerLandingFrames()
        XCTAssertEqual(frames.count, 4)
        let m = panel.cornerMargin
        XCTAssertEqual(frames[.topLeft], CGRect(x: visible.minX + m, y: visible.maxY - 284 - m, width: 250, height: 284))
        XCTAssertEqual(frames[.topRight], CGRect(x: visible.maxX - 250 - m, y: visible.maxY - 284 - m, width: 250, height: 284))
        XCTAssertEqual(frames[.bottomLeft], CGRect(x: visible.minX + m, y: visible.minY + m, width: 250, height: 284))
        XCTAssertEqual(frames[.bottomRight], CGRect(x: visible.maxX - 250 - m, y: visible.minY + m, width: 250, height: 284))
    }

    func test_thePanelSettlesExactlyOnTheFrameOfTheCornerItWasHeadedFor_inEveryCorner() throws {
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let starts: [(ScreenCorner, NSPoint)] = [
            (.topLeft, NSPoint(x: visible.minX + 120, y: visible.maxY - 284 - 90)),
            (.topRight, NSPoint(x: visible.maxX - 250 - 120, y: visible.maxY - 284 - 90)),
            (.bottomLeft, NSPoint(x: visible.minX + 120, y: visible.minY + 90)),
            (.bottomRight, NSPoint(x: visible.maxX - 250 - 120, y: visible.minY + 90)),
        ]
        for (corner, start) in starts {
            makePanel(at: start)
            let expected = try XCTUnwrap(panel.cornerLandingFrames()[corner])
            var landed: ScreenCorner?
            panel.onSnappedToCorner = { _, c in landed = c }
            panel.snapToNearestCorner()
            XCTAssertTrue(wait { landed != nil }, "\(corner): the panel settles")
            XCTAssertEqual(landed, corner)
            XCTAssertEqual(panel.frame.origin.x, expected.origin.x, accuracy: 0.5, "\(corner) x")
            XCTAssertEqual(panel.frame.origin.y, expected.origin.y, accuracy: 0.5, "\(corner) y")
            XCTAssertEqual(panel.frame.size, expected.size, "\(corner) size")
            XCTAssertEqual(panel.currentCorner(), corner)
            panel.orderOut(nil)
        }
    }

    func test_framesFollowThePanelsSize() throws {
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        makePanel(at: NSPoint(x: visible.midX, y: visible.midY), size: NSSize(width: 300, height: 341))
        let m = panel.cornerMargin
        XCTAssertEqual(panel.cornerLandingFrames()[.bottomRight], CGRect(x: visible.maxX - 300 - m, y: visible.minY + m, width: 300, height: 341))
    }
}
