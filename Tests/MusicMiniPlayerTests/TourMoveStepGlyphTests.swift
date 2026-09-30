/**
 * [INPUT]: TourRealPanelFixture (the REAL panel, MiniPlayerView, TourController and its real windows).
 * [OUTPUT]: TourMoveStepGlyphTests — which beat of the move step shows the trackpad demo, and what the card does about it.
 * [POS]: Tests. Founder 2026-09-29 (third walk, item 1): the demo showed on the "Back to the cover page" beat. It belongs to
 *        the beats that ask for the gesture: "Nudge it to a corner" (and, once that is done, the edge push) — it grows in
 *        (short fade / scale-in) when the beat becomes current, folds away when it stops being, and the card height springs.
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourMoveStepGlyphTests: XCTestCase {
    private var f: TourRealPanelFixture!
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    private let allButMoveAndBack: Set<TourStep> = Set(TourStep.orderedSteps).subtracting([.moveTuck, .back])
    private let band = 10.0 + 72.0 * 1.15

    private func presence() -> Double { f.controller.guidance.lastFrame.glyphPresence }
    private var cardHeight: Double { Double(f.cardWindow?.frame.height ?? 0) }

    func test_theLeadingBackToCoverBeat_hasNoDemo_theNudgeBeatDoes() throws {
        f = TourRealPanelFixture(page: .lyrics)
        f.showControls(on: .lyrics)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.6)
        let store = try XCTUnwrap(f.controller.debugCardStore)
        XCTAssertEqual(store.model.beats.first?.id, 2, "fixture sanity: the leading beat is on the card")
        XCTAssertEqual(store.model.beats.first?.checked, false)
        XCTAssertNil(store.gestureKind, "no demo while the current beat is 'Back to the cover page'")
        XCTAssertEqual(presence(), 0, accuracy: 1e-9)
        let heightWithoutDemo = cardHeight

        // The user comes back to the cover: the nudge beat is now current.
        f.music.currentPage = .album
        XCTAssertTrue(f.wait(2) { store.gestureKind == .nudgeToCorner })
        // …and it grows in over several frames rather than popping.
        var samples: [Double] = []
        var pairs: [(p: Double, growth: Double)] = []
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 0.9 {
            f.spin(0.016); samples.append(presence())
            pairs.append((presence(), cardHeight - heightWithoutDemo))
        }
        // The bubble and the band move as one: at every instant the card has grown by the same fraction the band has.
        let finalGrowth = try XCTUnwrap(pairs.last).growth
        let worstGap = pairs.map { abs($0.growth - $0.p * finalGrowth) }.max() ?? 0
        XCTAssertLessThan(worstGap, 12, "card growth follows the demo band's presence frame by frame (worst gap \(worstGap) pt of \(finalGrowth))")
        XCTAssertTrue(samples.contains { $0 > 0.05 && $0 < 0.95 }, "a fade / scale-in, not a pop: \(samples.prefix(12))")
        XCTAssertEqual(presence(), 1, accuracy: 0.02)
        // (The body text differs between the two pages too, so the growth is the band plus whatever the copy changed.)
        XCTAssertGreaterThan(cardHeight - heightWithoutDemo, band - 2, "the card springs taller by at least the demo's band")
        let window = try XCTUnwrap(f.cardWindow)
        XCTAssertEqual(window.frame.height, window.contentFittingSize.height, accuracy: 1.5, "and it is exactly as tall as its content: nothing clipped, no blank")
    }

    func test_theDemo_foldsAway_whenTheNudgeBeatIsDone_andTheEdgeDemoTakesItsPlace() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.6)
        let store = try XCTUnwrap(f.controller.debugCardStore)
        XCTAssertEqual(store.gestureKind, .nudgeToCorner)
        XCTAssertEqual(presence(), 1, accuracy: 0.02, "a card that opens on the nudge beat has its demo at once")

        f.controller.send(.panelSettled(corner: .bottomLeft))
        f.spin(1.6)
        if case .swipeToEdge = store.gestureKind {} else { XCTFail("the second beat's demo: \(String(describing: store.gestureKind))") }
        XCTAssertEqual(presence(), 1, accuracy: 0.02)
    }

    func test_backOnTheLyricsPage_theDemoFoldsAwayAgain() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: allButMoveAndBack))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(1.6)
        let store = try XCTUnwrap(f.controller.debugCardStore)
        XCTAssertEqual(store.gestureKind, .nudgeToCorner)
        let tall = cardHeight
        f.music.userManuallyOpenedLyrics = true
        f.music.currentPage = .lyrics
        XCTAssertTrue(f.wait(2) { store.gestureKind == nil })
        f.spin(1.0)
        XCTAssertEqual(presence(), 0, accuracy: 0.02)
        XCTAssertGreaterThan(tall - cardHeight, band - 2, "the card is shorter by (at least) the band again")
        let window = try XCTUnwrap(f.cardWindow)
        XCTAssertEqual(window.frame.height, window.contentFittingSize.height, accuracy: 1.5)
    }
}
