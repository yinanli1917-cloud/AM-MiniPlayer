/**
 * [INPUT]: MusicMiniPlayerCore's TourAnchorRegistry/TourAnchorKey/PanelWindowMetrics.
 * [OUTPUT]: TourAnchorGeometryTests — anchor rects are the control's resting
 *           position in true screen coordinates.
 * [POS]: Tests. Pins the two errors that put the tour halo 32pt off the play
 *        button after a hover (SwiftUI `.global` starts at the safe area; a
 *        hidden control's slide-in offset must not leak into its anchor).
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerCore

private struct AnchorTestRoot<Marker: View>: View {
    let marker: Marker
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 0) { marker.frame(width: 30, height: 30); Spacer() }
        }
        .padding(20)
        .onPreferenceChange(TourAnchorKey.self) { TourAnchorRegistry.shared.update($0) }
    }
}

@MainActor
final class TourAnchorGeometryTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        TourAnchorRegistry.shared.reset()
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        TourAnchorRegistry.shared.reset()
        super.tearDown()
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A real panel-shaped window (titled + fullSizeContentView, the 32pt-taller
    /// hosting view with a 32pt top safe area) with a 30pt marker whose true
    /// rest position is 20pt from the window's left and bottom edges.
    private func host<Marker: View>(_ marker: Marker) {
        let size = PanelWindowMetrics.defaultSize
        let origin = NSPoint(x: 300, y: 300)
        let w = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: PanelWindowMetrics.styleMask, backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = PanelWindowMetrics.makeContentView(root: AnchorTestRoot(marker: marker))
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.orderFront(nil)
        window = w
        spin(0.4)
    }

    func test_screenRect_isTheTrueScreenPosition_notShiftedByTheSafeArea() throws {
        host(Color.clear.tourAnchor(.playPause))
        let rect = try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: .playPause, in: window))
        XCTAssertEqual(rect.midX, window.frame.minX + 35, accuracy: 0.5)
        XCTAssertEqual(rect.midY, window.frame.minY + 35, accuracy: 0.5, "a 30pt marker 20pt above the bottom must convert to 35, not 67")
    }

    func test_hiddenOffset_isTakenBackOut_soTheAnchorIsWhereTheControlRests() throws {
        // The control is parked 30pt lower while hidden; its container says so.
        host(Color.clear.tourAnchor(.playPause).offset(y: 30).environment(\.tourAnchorRestOffset, 30))
        let rect = try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: .playPause, in: window))
        XCTAssertEqual(rect.midY, window.frame.minY + 35, accuracy: 0.5, "hidden and shown must publish the same resting rect")
    }

    func test_withoutARestOffset_aMovedControlKeepsItsMovedRect() throws {
        host(Color.clear.tourAnchor(.playPause).offset(y: 30))
        let rect = try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: .playPause, in: window))
        XCTAssertEqual(rect.midY, window.frame.minY + 5, accuracy: 0.5, "control group: no rest offset declared, no compensation")
    }
}
