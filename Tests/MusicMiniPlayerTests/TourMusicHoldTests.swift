/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture),
 *          TourController's Music-beat hold, TourMusicReturn.
 * [OUTPUT]: TourMusicHoldTests — the corners step's Music beat opens the player app; the tour prepares the user
 *           (hint copy), holds still while they are away (no celebration, no handoff, no display link) and
 *           resumes when the cursor re-enters the panel or another app takes the front.
 *           Also the opt-in (TOUR_MUSIC_SHOTS=1) stills of the hint and the waiting card, light and dark.
 * [POS]: Tests. Founder 2026-10-02: Apple Music's own window animation plus our celebration at once is too much.
 */

import XCTest
import AppKit
import Combine
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourMusicHoldTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private let activations = PassthroughSubject<String?, Never>()
    private let own = "com.yinanli.nanoPod"

    override func tearDown() {
        f?.tearDown()
        f = nil
        super.tearDown()
    }

    private let L = { (key: String) in L10n.localized(key) }
    private var hintText: String { L10n.localized("tour.corners.bodyMusic", player: .appleMusic) }

    /// The corners step with the controls shown and the output beat already ticked: the Music beat is current.
    private func musicBeatCurrent(outputFirst: Bool = true, dark: Bool = false) throws {
        f = TourRealPanelFixture(dark: dark)
        f.controller.appActivations = activations.eraseToAnyPublisher()
        f.controller.ownBundleIdentifier = own
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
        if outputFirst {
            f.controller.send(.signal(.audioOutputMenuOpened))
            XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]))
            XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.body == self.hintText })
            f.spin(1.0)
        }
    }

    private var body: String? { f.controller.debugCardStore?.model.body }

    // MARK: - 1. Prepare before the jump

    func test_hint_showsWhenTheMusicBeatBecomesCurrent_inEnglish() throws {
        try musicBeatCurrent()
        XCTAssertEqual(body, "Tapping the top left opens Apple Music. Just have a look; I'll wait here till you're back.")
        XCTAssertNotEqual(body, L("tour.corners.body"), "not the generic line")
    }

    func test_hint_beforeTheMusicBeatIsCurrent_theGenericLineStays() throws {
        f = TourRealPanelFixture()
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.corners) })
        XCTAssertEqual(body, L("tour.corners.body"), "the output beat is current: nothing about Music yet")
    }

    func test_copy_zhAndEn_namePlayerFromIdentity_andNeverSay甩() throws {
        for key in ["tour.corners.bodyMusic", "tour.corners.bodyWaiting"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.zh.contains("甩"), "\(key): \(pair.zh)")
            XCTAssertFalse(pair.en.lowercased().contains("flick") || pair.en.lowercased().contains("swipe"), key)
            XCTAssertFalse(pair.zh.isEmpty || pair.en.isEmpty, key)
        }
        let saved = L10n.languageOverride
        defer { L10n.languageOverride = saved }
        L10n.languageOverride = "zh"
        XCTAssertEqual(L10n.localized("tour.corners.bodyMusic", player: .appleMusic), "点左上角会打开 Apple Music。去看一眼就好，我在这儿等你回来。")
        XCTAssertEqual(L10n.localized("tour.corners.bodyWaiting"), "看完了，把鼠标移回 nanoPod 就能接着来。")
        XCTAssertTrue(L10n.localized("tour.corners.bodyMusic", player: .neteaseCloudMusic).contains("NetEase Cloud Music"), "another edition swaps in cleanly")
        L10n.languageOverride = "en"
        XCTAssertEqual(L10n.localized("tour.corners.bodyWaiting"), "When you're done looking, move the pointer back to nanoPod to carry on.")
        XCTAssertTrue(L10n.localized("tour.corners.bodyMusic", player: .appleMusic).contains("Apple Music"))
    }

    // MARK: - 2. Hold while they are away

    func test_tapMusic_holds_noCelebration_noHandoff_ringDown_zeroDisplayLink() throws {
        try musicBeatCurrent()
        f.controller.send(.signal(.musicButtonTapped))

        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "the machine has not seen the tap: the step is not complete")
        XCTAssertEqual(f.controller.state.completedCount, 2, "the ring did not grow")
        // (The body crossfades first; the model lands with the new line.)
        XCTAssertTrue(f.wait(2) { self.f.controller.debugCardStore?.model.beats.first { $0.id == 1 }?.checked == true }, "the Music beat shows its small check")
        XCTAssertEqual(f.controller.debugCardStore?.model.ringCompleted, 2)

        // Let the check, the body crossfade and the (bounded, few-second) way-back hint finish, then it must be completely quiet.
        XCTAssertTrue(f.wait(14) {
            !f.controller.debugFeedback.isActive && f.controller.debugHaloFrame == nil && !f.controller.guidance.motion.hintRunning && !TourFrameDriver.shared.isRunning
        })
        XCTAssertEqual(body, L("tour.corners.bodyWaiting"), "the body settles to the one-liner")
        XCTAssertNotEqual(f.controller.debugFeedback.lastEvent?.growsRing, true, "only the beat's check ran: no ring growth, no sparks, no confetti")
        XCTAssertEqual(f.controller.debugFeedback.lastEvent?.confetti, false)
        XCTAssertNil(f.controller.debugHaloFrame, "the ring stopped pulsing and went down")
        let callbacks = TourFrameDriver.shared.callbackCount
        f.spin(1.5)
        XCTAssertEqual(TourFrameDriver.shared.callbackCount, callbacks, "waiting runs no display link")
        XCTAssertFalse(TourFrameDriver.shared.isRunning)
        XCTAssertFalse(f.controller.debugHasPendingTimers, "and no timer is armed")
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "still on the corners step: no handoff")
    }

    func test_hold_staysPast20Seconds_noAutoAdvance() throws {
        try musicBeatCurrent()
        f.controller.send(.signal(.musicButtonTapped))
        f.spin(2.5)
        // A long stay in the player app: a repeated hover value or an unrelated Music activation changes nothing.
        TourHookBus.shared.controlsVisible.send(true)
        activations.send("com.apple.Music")
        activations.send(nil)
        f.spin(0.5)
        XCTAssertTrue(f.controller.isHoldingForMusicReturn, "no timeout resumes it on its own")
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]))
    }

    // MARK: - 2b. The way back: a "Back to nanoPod" beat, an invitation in the words, a pointer toward the panel

    private func beat(_ id: Int) -> TourBeatModel? { f.controller.debugCardStore?.model.beats.first { $0.id == id } }

    func test_awayBeat_isPendingWhileAway_ticksOnReturn_beforeTheCelebration() throws {
        try musicBeatCurrent()
        XCTAssertNil(beat(TourController.musicReturnBeatID), "no third row before the trip")
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.wait(2) { self.beat(TourController.musicReturnBeatID) != nil })
        let ids = f.controller.debugCardStore?.model.beats.map(\.id)
        XCTAssertEqual(ids, [0, 1, TourController.musicReturnBeatID], "under the existing two beats")
        XCTAssertEqual(beat(TourController.musicReturnBeatID)?.text, L("tour.corners.beat3"))
        XCTAssertEqual(beat(TourController.musicReturnBeatID)?.checked, false)
        XCTAssertEqual(beat(TourController.musicReturnBeatID)?.pending, true, "pending: the one thing left to do")
        XCTAssertEqual(beat(1)?.checked, true, "the 'over to Music' beat shows its check as before")

        activations.send("com.apple.finder")                   // back
        XCTAssertTrue(f.wait(1) { self.beat(TourController.musicReturnBeatID)?.checked == true }, "the return ticks")
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "before the usual celebration, which has not been delivered yet")
        XCTAssertEqual(f.controller.state.completedCount, 2)
        XCTAssertTrue(f.wait(3) { f.controller.state.stepStates[.corners] == .completed }, "then the celebration")
        XCTAssertEqual(beat(TourController.musicReturnBeatID)?.checked ?? true, true, "and the row never disappears under the check")
    }

    func test_awayBody_endsWithTheComeBackInvitation_inBothLanguages() throws {
        let window = try XCTUnwrap(L10n.allStrings["tour.corners.bodyMusicWindow"])
        XCTAssertEqual(window.zh, "这是完整的 {player}，找歌、整理歌单都在这儿。nanoPod 是它身边的小伙伴，平时安静地陪你听。看完了，把鼠标移回 nanoPod 就能接着来。")
        XCTAssertEqual(window.en, "This is the full {player}: finding songs and building playlists happen here. nanoPod is the little companion beside it, quietly keeping you company while you listen. When you're done looking, move the pointer back to nanoPod to carry on.")
        let waiting = try XCTUnwrap(L10n.allStrings["tour.corners.bodyWaiting"])
        XCTAssertTrue(waiting.zh.contains("移回 nanoPod") && waiting.en.contains("move the pointer back to nanoPod"))
        let beat3 = try XCTUnwrap(L10n.allStrings["tour.corners.beat3"])
        XCTAssertEqual(beat3.zh, "回到 nanoPod")
        XCTAssertEqual(beat3.en, "Back to nanoPod")
        for pair in [window, waiting, beat3] { XCTAssertFalse(pair.zh.contains("甩")) }
    }

    func test_awayHint_ghostCursorAndGlow_pointAtThePanel_thenStopOnReturn() throws {
        try musicBeatCurrent()
        f.controller.send(.signal(.musicButtonTapped))
        let motion = f.controller.guidance.motion
        XCTAssertTrue(f.wait(4) { motion.makeFrame().ghostVisible }, "the ghost cursor glides from the card toward the panel")
        XCTAssertTrue(f.wait(4) { motion.makeFrame().panelGlow > 0.05 }, "and the panel's edge glows")
        XCTAssertNil(f.controller.debugHaloFrame, "no ring: the ring belongs to controls")
        activations.send("com.apple.finder")
        XCTAssertFalse(motion.hintRunning, "the hint stops the moment the user is back")
    }

    func test_panelHint_awayInThePlayerApp_isTheHoverInvite_onlyOnTheCornersStep() {
        let surface = TourSurface(page: .album, controlsVisible: false)
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: .step(.corners, beats: [true, false]), surface: surface, awayInPlayerApp: true), .hoverInvite)
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: .step(.corners, beats: [true, false]), surface: surface), .none)
        XCTAssertEqual(TourGuidanceResolver.panelHint(phase: .step(.lyrics, beats: [false]), surface: surface, awayInPlayerApp: true), .none)
    }

    // MARK: - 3. Resume on return

    private func assertResumedWithCelebration(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(f.controller.isHoldingForMusicReturn, file: file, line: line)
        XCTAssertTrue(f.wait(3) { f.controller.state.stepStates[.corners] == .completed }, "the usual completion (after the return beat's tick)", file: file, line: line)
        XCTAssertEqual(f.controller.state.completedCount, 3, file: file, line: line)
        XCTAssertTrue(f.wait(5) {
            if case .step(.lyrics, _) = f.controller.state.phase { return f.controller.debugCardStore?.model.kind == .step(.lyrics) }
            return false
        }, "and the transition to the next step", file: file, line: line)
    }

    func test_cursorReturn_resumes() throws {
        try musicBeatCurrent()
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.wait(2) { !f.controller.debugFeedback.isActive })
        TourHookBus.shared.controlsVisible.send(true)          // the same hover the tap came from: not a return
        f.spin(0.3)
        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
        TourHookBus.shared.controlsVisible.send(false)         // the cursor leaves for the player app
        f.spin(0.2)
        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
        TourHookBus.shared.controlsVisible.send(true)          // and comes back
        XCTAssertTrue(f.wait(1) { !f.controller.isHoldingForMusicReturn })
        assertResumedWithCelebration()
    }

    func test_anotherAppActivating_resumes() throws {
        try musicBeatCurrent()
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.wait(2) { !f.controller.debugFeedback.isActive })
        activations.send("com.apple.Music")                    // the trip itself
        activations.send(own)                                  // our own activation by the click
        f.spin(0.3)
        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
        activations.send("com.apple.finder")                   // the user went on to something else
        XCTAssertFalse(f.controller.isHoldingForMusicReturn)
        assertResumedWithCelebration()
    }

    func test_musicTappedFirst_holdsToo_thenTheRingGoesToTheOutputButton() throws {
        try musicBeatCurrent(outputFirst: false)
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [false, false]))
        XCTAssertTrue(f.wait(4) { f.controller.debugHaloFrame == nil && !f.controller.debugFeedback.isActive })
        XCTAssertEqual(body, L("tour.corners.bodyWaiting"))

        activations.send("com.apple.finder")
        XCTAssertTrue(f.wait(2) { f.controller.state.phase == .step(.corners, beats: [false, true]) }, "the held tap lands after the return beat's tick")
        XCTAssertNotEqual(f.controller.state.stepStates[.corners], .completed, "the output beat is still open")
        XCTAssertTrue(f.wait(3) {
            guard let c = f.ringCenter else { return false }
            let target = f.restingRect(.audioOutput)
            return abs(c.x - target.midX) < 2 && abs(c.y - target.midY) < 2
        }, "on return the ring goes to the output button")
        XCTAssertTrue(f.wait(2) { self.body == self.L("tour.corners.body") }, "and the body is the generic line again")
    }

    func test_skipOrStopWhileAway_endsTheHold() throws {
        try musicBeatCurrent()
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
        f.controller.send(.skipStep)
        XCTAssertFalse(f.controller.isHoldingForMusicReturn)
        activations.send("com.apple.finder")                   // nothing left listening
        f.spin(0.3)
        XCTAssertNotEqual(f.controller.state.stepStates[.corners], .completed)
    }

    func test_tapWhenTheMusicBeatIsNotOpen_isNotHeld() throws {
        f = TourRealPanelFixture()
        f.showControls(on: .album)
        f.controller.send(.resume(completed: [.connect]))      // the reveal step: a Music tap is an early, silent record
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertFalse(f.controller.isHoldingForMusicReturn)
    }

    // MARK: - Pure

    func test_returnRule() {
        let p = PlayerAppIdentity.appleMusic
        XCTAssertFalse(TourMusicReturn.isReturn(activatedBundleID: "com.apple.Music", player: p, ownBundleID: "x"))
        XCTAssertFalse(TourMusicReturn.isReturn(activatedBundleID: "x", player: p, ownBundleID: "x"))
        XCTAssertFalse(TourMusicReturn.isReturn(activatedBundleID: nil, player: p, ownBundleID: "x"))
        XCTAssertTrue(TourMusicReturn.isReturn(activatedBundleID: "com.apple.finder", player: p, ownBundleID: "x"))
        XCTAssertTrue(TourMusicReturn.isReturn(activatedBundleID: "com.apple.Music", player: .neteaseCloudMusic, ownBundleID: nil))
    }

    // MARK: - Stills (opt-in)

    private func shots(dark: Bool) throws {
        let studio = TourShotStudio(dark: dark)
        studio.outDir = ProcessInfo.processInfo.environment["TOUR_MUSIC_SHOTS_DIR"] ?? studio.outDir
        defer { studio.finish() }
        try musicBeatCurrent(dark: dark)
        studio.settleBackdrop(f)
        f.spin(1.0)
        studio.shoot("1-hint-musicBeatCurrent", fixture: f)
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.wait(4) { !f.controller.debugFeedback.isActive && f.controller.debugHaloFrame == nil })
        f.spin(0.8)
        studio.shoot("2-waiting", fixture: f)
    }

    func test_stills_lightAndDark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_MUSIC_SHOTS"] == "1", "opt-in: puts windows on the screen")
        try shots(dark: false)
        f.tearDown(); f = nil
        try shots(dark: true)
    }
}
