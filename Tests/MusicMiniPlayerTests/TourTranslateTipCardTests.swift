/**
 * [INPUT]: TourRealPanelFixture (the REAL panel, tour controller, watcher and card windows), LyricsService.debugSetCanTranslate.
 * [OUTPUT]: TourTranslateTipCardTests — the standalone translation tip on a real panel (founder 2026-10-06: translation left
 *           the tour; it is taught the first time the user is on the lyrics page and the button is really there): never on
 *           the album page, shown on the lyrics page with the ring on the real button, closes when the page is left,
 *           completes on a toggle, can be dismissed.
 * [POS]: Tests. The reducer / watcher / persistence halves are TourTranslateTipTests and TourDeferredWatcherTests.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourTranslateTipCardTests: XCTestCase {
    private var f: TourRealPanelFixture!
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    private let L = { (key: String) in L10n.localized(key) }

    /// The tour is over (finished, on the page `page`), the song can be translated: the tip's watcher is armed.
    private func armedTip(on page: PlayerPage, canTranslate: Bool = true) {
        f = TourRealPanelFixture(page: page, translationOn: false)
        f.showControls(on: page)
        f.spin(0.4)
        if canTranslate { f.lyricsService.debugSetCanTranslate(true) }   // after the page switch: LyricsView re-derives it on entry
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps)))
        f.controller.send(.finaleDismiss)
        XCTAssertEqual(f.controller.state.phase, .idle(deferredArmed: true))
        XCTAssertTrue(f.controller.debugIsDeferredWatcherArmed)
    }

    func test_onTheLyricsPage_tipShowsAfterThreeSeconds_ringOnTheRealButton_toggleCompletesIt() throws {
        armedTip(on: .lyrics)
        f.spin(1.0)
        XCTAssertEqual(f.controller.state.phase, .idle(deferredArmed: true), "not before the 3 s mark")
        XCTAssertTrue(f.wait(4) { f.controller.state.phase == .deferredTip(.translate) }, "and then on its own: the user is sitting on the lyrics page")
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .deferredTip })
        let model = try XCTUnwrap(f.controller.debugCardStore?.model)
        XCTAssertEqual(model.body, L("tour.later.body"))
        XCTAssertEqual(model.title, L("tour.later.title"))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
        let ring = try XCTUnwrap(f.ringCenter)
        let button = f.restingRect(.translate)
        XCTAssertEqual(ring.x, button.midX, accuracy: 2, "the ring is on the real translate button")
        XCTAssertEqual(ring.y, button.midY, accuracy: 2)

        f.lyricsService.showTranslation = true
        XCTAssertTrue(f.wait { f.controller.state.stepStates[.translate] == .completed }, "toggling it is what completes the tip")
        XCTAssertTrue(f.wait { !f.controller.debugIsDeferredWatcherArmed }, "and the tip is done for good")
    }

    func test_onTheAlbumPage_neverShows_thenAppearsWhenTheLyricsPageOpens_andClosesWhenItIsLeft() throws {
        armedTip(on: .album)
        f.spin(3.4)                                       // well past the 3 s mark, button "available", wrong page
        XCTAssertEqual(f.controller.state.phase, .idle(deferredArmed: true))
        XCTAssertNil(f.cardWindow, "no card on the album page")

        // (The test panel has no lyrics, so entering the lyrics page re-derives `canTranslate` to false: say so first, then
        // let the button "arrive", rather than flash the stale true that the fixture would otherwise carry across.)
        f.lyricsService.debugSetCanTranslate(false)
        f.music.userManuallyOpenedLyrics = true
        f.music.currentPage = .lyrics
        f.spin(0.4)
        f.lyricsService.debugSetCanTranslate(true)        // LyricsView re-derives it on entry
        XCTAssertTrue(f.wait(2) { f.controller.state.phase == .deferredTip(.translate) }, "opening the lyrics page is the moment")

        f.music.currentPage = .album
        XCTAssertTrue(f.wait(2) { f.controller.state.phase == .idle(deferredArmed: true) }, "leaving it closes the tip")
        XCTAssertEqual(f.controller.state.deferredAttempts, 0, "without costing an attempt")
        XCTAssertTrue(f.wait(2) { !f.controller.guidance.motion.cardVisible })
    }

    func test_withoutTheButton_onTheLyricsPage_neverShows() throws {
        armedTip(on: .lyrics, canTranslate: false)
        f.lyricsService.debugSetCanTranslate(false)
        f.spin(3.6)
        XCTAssertEqual(f.controller.state.phase, .idle(deferredArmed: true))
    }

    func test_dismiss_isDoneForGood_andTheTourStatusStaysCompleted() throws {
        armedTip(on: .lyrics)
        XCTAssertTrue(f.wait(5) { f.controller.state.phase == .deferredTip(.translate) })
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .deferredTip })
        XCTAssertEqual(f.controller.debugCardStore?.model.stopTitle, L("tour.later.dismiss"))
        let dismiss = try XCTUnwrap(f.controller.debugCardStore?.onStop)
        dismiss()
        XCTAssertEqual(f.controller.state.stepStates[.translate], .skipped)
        XCTAssertEqual(f.controller.state.status, .completed)
        XCTAssertFalse(f.controller.debugIsDeferredWatcherArmed)
    }

    func test_copy_hasBothLanguages_namesTheCorner_andNeverUsesTheBannedWord() throws {
        let body = try XCTUnwrap(L10n.allStrings["tour.later.body"])
        XCTAssertEqual(body.zh, "这首可以翻译。点右下角的按钮，译文会跟在每一句下面。")
        XCTAssertEqual(body.en, "This one can be translated. Tap the button at the bottom right, and each line gets one underneath.")
        for key in ["tour.later.title", "tour.later.body", "tour.later.dismiss"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.zh.isEmpty || pair.en.isEmpty, key)
            XCTAssertFalse(pair.zh.contains("甩"), key)
        }
        for key in ["tour.translate.title", "tour.translate.body", "tour.translate.deferred.body", "tour.done.bodyDeferred"] {
            XCTAssertNil(L10n.allStrings[key], "\(key): the tour's translate step and its deferral note are gone")
        }
    }
}
