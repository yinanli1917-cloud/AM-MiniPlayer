/**
 * [INPUT]: TourRealPanelFixture (real MiniPlayerView in a real SnappablePanel), MusicMiniPlayerCore's
 *          TourAnchorRegistry / TourPanelLayout / View.tourControlsSlide.
 * [OUTPUT]: TourAnchorRealPanelTests — the anchor rects of the real panel in every state the
 *           tour can meet it in, the layout table that backs unrendered controls, and the guard
 *           that keeps both pages sliding their controls through the one anchor-aware modifier.
 * [POS]: Tests. Founder 2026-09-29, item 3: the ring sat 30pt below the play button. The lyrics
 *        page slid its controls with a bare `.offset` (hidden = 30pt low) and published that hidden
 *        rect; the cover page compensated. A headless test cannot hover the lyrics page, so the
 *        mechanism is pinned twice: the shared modifier at both offsets, and the source guard.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

private struct SlideRoot: View {
    let offset: CGFloat
    let compensated: Bool
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 0) {
                Group {
                    if compensated {
                        Color.clear.frame(width: 30, height: 30).tourAnchor(.playPause).tourControlsSlide(offsetY: offset)
                    } else {
                        Color.clear.frame(width: 30, height: 30).tourAnchor(.playPause).offset(y: offset)   // what LyricsView used to do
                    }
                }
                Spacer()
            }
        }
        .padding(20)
        .onPreferenceChange(TourAnchorKey.self) { TourAnchorRegistry.shared.update($0) }
    }
}

@MainActor
final class TourAnchorRealPanelTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private var window: NSWindow?

    override func tearDown() {
        f?.tearDown(); f = nil
        window?.orderOut(nil); window = nil
        TourAnchorRegistry.shared.reset()
        super.tearDown()
    }

    private func rest(_ id: TourAnchorID) -> CGRect { f.restingRect(id) }

    // MARK: - The shared modifier, both offsets

    private func slideRect(offset: CGFloat, compensated: Bool) throws -> CGRect {
        TourAnchorRegistry.shared.reset()
        let size = PanelWindowMetrics.defaultSize
        let origin = NSPoint(x: 300, y: 300)
        let w = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: PanelWindowMetrics.styleMask, backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentView = PanelWindowMetrics.makeContentView(root: SlideRoot(offset: offset, compensated: compensated))
        w.setFrame(NSRect(origin: origin, size: size), display: true)
        w.orderFront(nil)
        window?.orderOut(nil)
        window = w
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: .playPause, in: w))
    }

    func test_item3_tourControlsSlide_publishesTheRestingRect_hiddenAndShown() throws {
        let shown = try slideRect(offset: 0, compensated: true)
        let hidden = try slideRect(offset: 30, compensated: true)
        XCTAssertEqual(hidden.midY, shown.midY, accuracy: 0.5, "hidden and shown publish the SAME rect")
    }

    func test_item3_control_aBareOffset_publishesTheHiddenRect_30ptLow() throws {
        let shown = try slideRect(offset: 0, compensated: false)
        let hidden = try slideRect(offset: 30, compensated: false)
        XCTAssertEqual(shown.midY - hidden.midY, 30, accuracy: 0.5, "what the lyrics page did: the ring sat on the panel's bottom edge")
    }

    /// Both pages slide their controls through the anchor-aware modifier; a bare
    /// `.offset(y: controlsOffsetY)` next to the shared bottom controls brings the bug back.
    func test_item3_sourceGuard_lyricsPageSlidesItsControlsThroughTheModifier() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let lyrics = try String(contentsOf: root.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/LyricsView.swift"), encoding: .utf8)
        let mini = try String(contentsOf: root.appendingPathComponent("Sources/MusicMiniPlayerCore/UI/MiniPlayerView.swift"), encoding: .utf8)
        XCTAssertTrue(lyrics.contains(".tourControlsSlide(offsetY: controlsOffsetY)"))
        XCTAssertFalse(lyrics.contains(".offset(y: controlsOffsetY)"), "LyricsView must not slide the anchored controls with a bare offset")
        XCTAssertTrue(mini.contains(".tourControlsSlide(offsetY: controlsOffsetY)"))
    }

    // MARK: - The real panel, every state

    func test_item3_realPanel_anchorsAtRest_matchTheLayoutTable_inEveryState() throws {
        for (label, page, shown) in [("album hidden", PlayerPage.album, false), ("album shown", .album, true), ("lyrics", .lyrics, true)] {
            f = TourRealPanelFixture(page: page)
            if shown { f.showControls(on: page) } else { f.hideControls(on: page) }
            let frame = f.panel.frame
            for id in [TourAnchorID.playPause, .lyricsNav] {
                let published = try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: id, in: f.panel), "\(label) \(id)")
                let table = TourPanelLayout.screenRect(for: id, panelFrame: frame)
                XCTAssertEqual(published.midX, table.midX, accuracy: 2, "\(label) \(id) x")
                XCTAssertEqual(published.midY, table.midY, accuracy: 2, "\(label) \(id) y")
            }
            f.tearDown(); f = nil
        }
    }

    /// The corner buttons only exist after a hover; the table is what the ring uses before that.
    /// If the panel layout ever changes, this fails and the table gets re-measured.
    func test_layoutTable_matchesTheCornerButtonsTheRealPanelDraws() throws {
        f = TourRealPanelFixture(page: .album)
        f.showControls(on: .album)
        for id in [TourAnchorID.musicButton, .audioOutput] {
            let published = try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: id, in: f.panel), "\(id)")
            let table = TourPanelLayout.screenRect(for: id, panelFrame: f.panel.frame)
            XCTAssertEqual(published.midX, table.midX, accuracy: 3, "\(id) x")
            XCTAssertEqual(published.midY, table.midY, accuracy: 3, "\(id) y")
        }
    }

    func test_layoutTable_matchesTheTranslateButtonOnTheLyricsPage() throws {
        f = TourRealPanelFixture(page: .album)
        f.showControls(on: .lyrics)
        f.lyricsService.debugSetCanTranslate(true)
        f.spin(0.6)
        let published = try XCTUnwrap(TourAnchorRegistry.shared.screenRect(for: .translate, in: f.panel))
        let table = TourPanelLayout.screenRect(for: .translate, panelFrame: f.panel.frame)
        XCTAssertEqual(published.midX, table.midX, accuracy: 3, "translate x (\(published) vs \(table))")
        XCTAssertEqual(published.midY, table.midY, accuracy: 3, "translate y (\(published) vs \(table))")
    }

    func test_resolvedRect_fallsBackToTheTable_whenNothingWasPublished() throws {
        f = TourRealPanelFixture(page: .album)
        TourAnchorRegistry.shared.reset()
        let r = TourAnchorRegistry.shared.resolvedScreenRect(for: .musicButton, in: f.panel)
        XCTAssertEqual(r, TourPanelLayout.screenRect(for: .musicButton, panelFrame: f.panel.frame))
    }
}
