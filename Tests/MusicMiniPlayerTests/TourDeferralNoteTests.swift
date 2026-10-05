/**
 * [INPUT]: TourRealPanelFixture (the REAL panel, tour controller and card windows), LyricsService.debugSetCanTranslate.
 * [OUTPUT]: TourDeferralNoteTests — the "this one doesn't need translating" card (founder 2026-10-04: it flashed by in 1.1 s):
 *           it stays until the user acts, "Got it" continues to the move step with translate still deferred, and a song that
 *           can be translated turns the card into the real translate step.
 * [POS]: Tests.
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourDeferralNoteTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private let untilTranslate = Set(TourStep.orderedSteps).subtracting([.translate, .moveTuck, .back])
    override func tearDown() { f?.tearDown(); f = nil; super.tearDown() }

    private func startOnTheNote() {
        f = TourRealPanelFixture(page: .lyrics, canTranslate: false)
        f.controller.send(.resume(completed: untilTranslate))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
    }

    func test_theNoteStaysUntilTheUserActs_andOffersGotIt() throws {
        startOnTheNote()
        XCTAssertTrue(f.controller.state.isShowingDeferralNote)
        f.spin(2.5)                                         // well past the old 1.1 s timer
        XCTAssertTrue(f.controller.state.isShowingDeferralNote, "nothing advances it on its own")
        let model = try XCTUnwrap(f.controller.debugCardStore?.model)
        XCTAssertEqual(model.kind, .deferralNote)
        XCTAssertEqual(model.primaryTitle, L10n.localized("tour.translate.deferred.gotIt"))
        XCTAssertFalse(f.controller.debugHasTransitionTimer, "no clock is running behind the card")
    }

    func test_gotIt_continuesToTheMoveStep_translateStaysDeferred() throws {
        startOnTheNote()
        f.spin(0.5)
        let gotIt = try XCTUnwrap(f.controller.debugCardStore?.onPrimary)
        gotIt()
        f.spin(0.3)
        guard case .step(.moveTuck, _) = f.controller.state.phase else { return XCTFail("got \(f.controller.state.phase)") }
        XCTAssertEqual(f.controller.state.stepStates[.translate], .deferred)
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.moveTuck) })
    }

    func test_aTranslatableSongWhileTheNoteIsUp_turnsItIntoTheTranslateStep() throws {
        startOnTheNote()
        f.spin(0.5)
        f.lyricsService.debugSetCanTranslate(true)
        f.spin(0.3)
        XCTAssertEqual(f.controller.state.phase, .step(.translate, beats: [false]))
        XCTAssertEqual(f.controller.state.stepStates[.translate], .pending)
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.translate) }, "the card became the real step")
    }

    func test_aTranslatableSongOutsideTheNote_isNotTheTourBusiness() throws {
        f = TourRealPanelFixture(page: .lyrics, canTranslate: false)
        f.controller.send(.resume(completed: untilTranslate.union([.translate])))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        let before = f.controller.state.phase
        f.lyricsService.debugSetCanTranslate(true)
        f.spin(0.3)
        XCTAssertEqual(f.controller.state.phase, before)
    }

    func test_copy_hasBothLanguages_andNotTheBannedWord() throws {
        let body = try XCTUnwrap(L10n.allStrings["tour.translate.deferred.body"])
        XCTAssertEqual(body.zh, "这首用不着翻译。等遇到外文歌，我再来告诉你翻译在哪。")
        XCTAssertEqual(body.en, "This one doesn't need translating. When a song in another language comes along, I'll show you where translation is.")
        let gotIt = try XCTUnwrap(L10n.allStrings["tour.translate.deferred.gotIt"])
        XCTAssertEqual(gotIt.zh, "知道了")
        XCTAssertEqual(gotIt.en, "Got it")
        for pair in [body, gotIt] { XCTAssertFalse(pair.zh.contains("甩")) }
    }
}
