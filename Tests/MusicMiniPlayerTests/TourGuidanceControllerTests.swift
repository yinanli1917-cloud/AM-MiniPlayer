/**
 * [INPUT]: TourRealPanelFixture (the REAL MiniPlayerView in the REAL SnappablePanel, the real
 *          TourController with its card / ring windows), MusicMiniPlayerCore's TourAnchorRegistry.
 * [OUTPUT]: TourGuidanceControllerTests — the founder's 2026-09-29 walk, item by item, against the
 *           real windows: where the ring is, what it does when a beat ticks, what the card says.
 * [POS]: Tests. Ring-vs-control assertions use 2pt tolerance (the founder's ring sat 30pt off).
 */

import XCTest
import AppKit
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class TourGuidanceControllerTests: XCTestCase {
    private var f: TourRealPanelFixture!

    override func tearDown() {
        f?.tearDown()
        f = nil
        super.tearDown()
    }

    private let L = { (key: String) in L10n.localized(key) }
    private let almostAll: Set<TourStep> = [.connect, .reveal, .corners, .lyrics, .translate]

    private func assertRing(on rect: CGRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let c = f.ringCenter else { return XCTFail("no ring is showing: \(message)", file: file, line: line) }
        XCTAssertEqual(c.x, rect.midX, accuracy: 2, "ring x: \(message)", file: file, line: line)
        XCTAssertEqual(c.y, rect.midY, accuracy: 2, "ring y: \(message)", file: file, line: line)
    }

    // MARK: - Item 1: "again" starts at the welcome card

    func test_item1_again_startsFromTheWelcomeCard() throws {
        f = TourRealPanelFixture()
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps)))
        f.controller.send(.finaleDismiss)
        XCTAssertEqual(f.controller.state.status, .completed)
        f.controller.requestTour(fromStart: true)
        XCTAssertEqual(f.controller.state.phase, .welcome, "not the second step")
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .welcome })
        XCTAssertNotNil(f.cardWindow, "and the welcome card is on screen")
        XCTAssertEqual(f.controller.state.completedCount, 0, "a fresh run: no ring progress carried over")
    }

    // MARK: - Item 2: the reveal step with the controls hidden

    func test_item2_reveal_controlsHidden_dashedRing_ghostCursor_glow_thenStopWhenTheMouseArrives() throws {
        f = TourRealPanelFixture()
        f.hideControls(on: .album)
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil }, "the ring appears")
        XCTAssertTrue(f.controller.debugRingIsDashed, "controls hidden: a dashed hint, not a solid dot")
        // Ghost cursor from the card's beak, and the panel glow, while the mouse is away.
        let guidance = f.controller.guidance
        XCTAssertTrue(f.wait(4) { guidance.motion.makeFrame().ghostVisible }, "the ghost cursor floats from the beak")
        XCTAssertTrue(f.wait(4) { guidance.motion.makeFrame().panelGlow > 0.05 }, "the panel edge glows")
        // The mouse reaches the panel: all of it stops, the ring turns solid.
        TourHookBus.shared.controlsVisible.send(true)
        XCTAssertTrue(f.wait(1) { !guidance.motion.makeFrame().ghostVisible && guidance.motion.makeFrame().panelGlow == 0 },
                      "ghost cursor and glow stop as soon as the mouse is on the panel")
        XCTAssertTrue(f.wait(1) { !f.controller.debugRingIsDashed }, "press-now: solid")
    }

    func test_item2_revealCopy_isPageNeutral() throws {
        for key in ["tour.reveal.body", "tour.reveal.bodyArmedPlay", "tour.reveal.bodyArmedPause", "tour.body.away"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.en.lowercased().contains("cover"), "\(key): the panel may be on the lyrics page — \(pair.en)")
            XCTAssertFalse(pair.zh.contains("封面"), "\(key): \(pair.zh)")
        }
    }

    // MARK: - Item 3: the ring is ON the play button, hidden or shown

    func test_item3_ringOnPlayButton_albumHidden_albumShown_lyricsShown() throws {
        for (label, page, shown) in [("album hidden", PlayerPage.album, false), ("album shown", .album, true), ("lyrics shown", .lyrics, true)] {
            f = TourRealPanelFixture(page: page)
            if shown { f.showControls(on: page) } else { f.hideControls(on: page) }
            f.controller.send(.resume(completed: [.connect]))
            XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil }, label)
            f.spin(0.6)
            let expected = CGPoint(x: f.panel.frame.midX, y: f.panel.frame.minY + 31)   // the panel's own layout
            let c = try XCTUnwrap(f.ringCenter, label)
            XCTAssertEqual(c.x, expected.x, accuracy: 2, "\(label): x")
            XCTAssertEqual(c.y, expected.y, accuracy: 2, "\(label): y — the founder saw it 30pt low")
            assertRing(on: f.restingRect(.playPause), label)
            f.tearDown(); f = nil
        }
    }

    func test_item3_ringDoesNotDrift_whenTheControlsSlideIn() throws {
        f = TourRealPanelFixture(page: .album)
        f.hideControls(on: .album)
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.6)
        let before = try XCTUnwrap(f.ringCenter)
        f.showControls(on: .album)               // the controls slide in from 30pt below
        var worst: CGFloat = 0
        for _ in 0..<20 {
            f.spin(0.05)
            if let c = f.ringCenter { worst = max(worst, hypot(c.x - before.x, c.y - before.y)) }
        }
        XCTAssertLessThan(worst, 2, "the ring points at where the control RESTS, in either state")
    }

    // MARK: - Item 4: the second beat takes either toggle

    func test_item4_secondBeat_asksForPause_whenPlaying_andAnyToggleCompletesIt() throws {
        f = TourRealPanelFixture()
        f.music.isPlaying = true
        f.spin(0.2)
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.reveal) })
        var beats = try XCTUnwrap(f.controller.debugCardStore?.model.beats)
        XCTAssertEqual(beats[1].text, L("tour.reveal.beat2pause"), "playing: the offered action is pause, not \"Already playing\"")
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.signal(.controlsRevealed))
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.body == self.L("tour.reveal.bodyArmedPause") })
        beats = try XCTUnwrap(f.controller.debugCardStore?.model.beats)
        XCTAssertTrue(beats[1].pending, "ready for the last move")
        f.music.isPlaying = false                                   // the user pressed pause
        XCTAssertTrue(f.wait { f.controller.state.stepStates[.reveal] == .completed }, "pausing completes the beat")
    }

    func test_item4_secondBeat_asksForPlay_whenPaused_andPlayCompletesIt() throws {
        f = TourRealPanelFixture()
        f.music.isPlaying = false
        f.spin(0.2)
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.reveal) })
        XCTAssertEqual(f.controller.debugCardStore?.model.beats[1].text, L("tour.reveal.beat2"))
        f.controller.send(.signal(.controlsRevealed))
        f.music.isPlaying = true
        XCTAssertTrue(f.wait { f.controller.state.stepStates[.reveal] == .completed })
    }

    func test_item4_playingAtStepStart_doesNotPreCompleteTheBeat() throws {
        f = TourRealPanelFixture()
        f.music.isPlaying = true
        f.controller.send(.resume(completed: [.connect]))
        f.spin(0.4)
        XCTAssertEqual(f.controller.state.stepStates[.reveal], nil, "already playing is not a press")
        XCTAssertEqual(f.controller.state.phase, .step(.reveal, beats: [false, false]))
    }

    // MARK: - Item 5: the corners step — the ring jumps from output to Music

    func test_item5_ringJumpsFromTheOutputButtonToTheMusicCapsule() throws {
        f = TourRealPanelFixture()
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
        assertRing(on: f.restingRect(.audioOutput), "first beat: the output button (top right)")
        XCTAssertEqual(f.controller.debugHaloFrame?.size.width ?? 0, 40, accuracy: 0.5)

        f.controller.send(.signal(.audioOutputMenuOpened))      // the output menu opened; that beat ticks
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]))
        XCTAssertTrue(f.wait(3) {
            guard let c = f.ringCenter else { return false }
            let target = f.restingRect(.musicButton)
            return abs(c.x - target.midX) < 2 && abs(c.y - target.midY) < 2
        }, "the ring must jump to the Music capsule at the top left instead of disappearing")
        XCTAssertEqual(f.controller.debugHaloFrame?.size.width ?? 0, 82, accuracy: 0.5, "and become the capsule")
        // The card's beak re-aims with it.
        let placement = try XCTUnwrap(f.controller.debugLastPlacement)
        XCTAssertEqual(placement.beakSide, .right)
    }

    func test_item5_musicFirst_thenTheRingGoesToTheOutputButton() throws {
        f = TourRealPanelFixture()
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        f.spin(0.7)
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.wait(3) {
            guard let c = f.ringCenter else { return false }
            let target = f.restingRect(.audioOutput)
            return abs(c.x - target.midX) < 2 && abs(c.y - target.midY) < 2
        })
    }

    // MARK: - Item 6: the lyrics step

    func test_item6_lyricsStep_ringOnTheBubble_andACardWithABeat() throws {
        f = TourRealPanelFixture(page: .album)
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal, .corners]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
        let model = try XCTUnwrap(f.controller.debugCardStore?.model)
        XCTAssertEqual(model.kind, .step(.lyrics))
        XCTAssertEqual(model.beats.map(\.text), [L("tour.lyrics.beat1")], "the card lists its one beat")
        assertRing(on: f.restingRect(.lyricsNav), "the speech bubble, bottom left")
        XCTAssertEqual(f.controller.debugHaloFrame?.size.width ?? 0, 36, accuracy: 0.5)
        f.music.currentPage = .lyrics
        XCTAssertTrue(f.wait { f.controller.state.stepStates[.lyrics] == .completed }, "opening the lyrics completes it")
    }

    func test_item6_alreadyOnTheLyricsPage_theStepCompletesQuietly() throws {
        f = TourRealPanelFixture(page: .lyrics)
        f.controller.send(.resume(completed: [.connect, .reveal, .corners]))
        XCTAssertEqual(f.controller.state.stepStates[.lyrics], .completed, "no round trip lyrics -> cover -> lyrics")
        f.spin(0.4)
        XCTAssertNotEqual(f.controller.debugCardStore?.model.kind, .step(.lyrics))
    }

    // MARK: - Item 7: translation, either direction

    private func translateStep(initiallyOn: Bool) throws {
        f = TourRealPanelFixture(page: .lyrics, translationOn: initiallyOn)
        f.showControls(on: .lyrics)
        f.lyricsService.debugSetCanTranslate(true)      // after the page switch: LyricsView re-derives it on entry
        f.spin(0.5)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal, .corners, .lyrics]))
        XCTAssertEqual(f.controller.state.phase, .step(.translate, beats: [false]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
        assertRing(on: f.restingRect(.translate), "the translate button, bottom right")
        // The ring stays put while the user has not toggled.
        for _ in 0..<6 { f.spin(0.1); XCTAssertNotNil(f.controller.debugHaloFrame) }
        f.lyricsService.showTranslation = !initiallyOn
        XCTAssertTrue(f.wait { f.controller.state.stepStates[.translate] == .completed }, "toggling \(initiallyOn ? "off" : "on") counts")
    }

    func test_item7_translationAlreadyOn_turningItOffCompletesTheStep() throws { try translateStep(initiallyOn: true) }
    func test_item7_translationOff_turningItOnCompletesTheStep() throws { try translateStep(initiallyOn: false) }

    // MARK: - Item 8: the move step

    func test_item8_moveStep_onTheCover_bodyStatesBothRules_noTopEdgeContact() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: almostAll))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(0.8)
        let model = try XCTUnwrap(f.controller.debugCardStore?.model)
        XCTAssertEqual(model.kind, .step(.moveTuck))
        XCTAssertEqual(model.beats.map(\.id), [0, 1], "on the cover: corner, then edge")
        XCTAssertEqual(model.body, L("tour.move.body"))
        let card = try XCTUnwrap(f.cardWindow).frame
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        XCTAssertGreaterThanOrEqual(visible.maxY - card.maxY, 10, "the card top must not touch the menu bar")
    }

    func test_item8_moveStep_onTheLyricsPage_firstBeatIsBackToTheCover_withARingOnTheBubble() throws {
        f = TourRealPanelFixture(page: .lyrics)
        f.showControls(on: .lyrics)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: almostAll))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
        let model = try XCTUnwrap(f.controller.debugCardStore?.model)
        XCTAssertEqual(model.beats.map(\.id), [2, 0, 1], "back to the cover first")
        XCTAssertEqual(model.beats.first?.text, L("tour.move.beat0"))
        XCTAssertEqual(model.beats.first?.checked, false)
        XCTAssertEqual(model.body, L("tour.move.bodyLyrics"))
        assertRing(on: f.restingRect(.lyricsNav), "the bubble that turns the lyrics page back into the cover")
        f.music.currentPage = .album
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.beats.first?.checked == true }, "on the cover the precondition ticks")
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.body == self.L("tour.move.body") })
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame == nil }, "and the ring leaves")
    }

    func test_item8_moveCopy_saysWhereCornersWork_inBothLanguages_andNeverUsesTheBannedWord() throws {
        for key in ["tour.move.body", "tour.move.bodyLyrics"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertTrue(pair.en.contains("cover page"), pair.en)
            XCTAssertTrue(pair.en.contains("lyrics page"), pair.en)
            XCTAssertTrue(pair.zh.contains("封面页"), pair.zh)
            XCTAssertTrue(pair.zh.contains("歌词页"), pair.zh)
        }
        XCTAssertTrue(try XCTUnwrap(L10n.allStrings["tour.move.body"]).en.contains("edge"))
        for (key, pair) in L10n.allStrings where key.hasPrefix("tour.") {
            XCTAssertFalse(pair.zh.contains("甩"), "\(key): the word is banned in the tour copy")
        }
    }

    // MARK: - Item 9: the panel is on top and the tour blocks nothing

    func test_item9_panelIsRaisedAboveAForeignFloatingWindow_whenAStepStarts() throws {
        f = TourRealPanelFixture()
        let foreign = NSPanel(contentRect: NSRect(x: f.panel.frame.midX - 260, y: f.panel.frame.midY - 360, width: 520, height: 720),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        foreign.level = .floating
        foreign.hidesOnDeactivate = false
        foreign.backgroundColor = .systemTeal
        foreign.isReleasedWhenClosed = false
        foreign.orderFrontRegardless()
        f.spin(0.4)
        defer { foreign.orderOut(nil) }
        func order(_ w: NSWindow) -> Int { f.zRank(w) ?? Int.max }
        XCTAssertLessThan(order(foreign), order(f.panel), "fixture sanity: the other app's window is in front of the panel")
        f.controller.send(.resume(completed: almostAll))
        XCTAssertTrue(f.wait { order(f.panel) < order(foreign) }, "the panel comes back to the front")
        XCTAssertGreaterThan(f.cardWindow?.level.rawValue ?? 0, f.panel.level.rawValue, "and the tour's windows stay above the panel")
    }

    func test_item9_tourWindowsNeverSwallowThePanelsGestures() throws {
        f = TourRealPanelFixture()
        f.controller.send(.resume(completed: almostAll))
        XCTAssertTrue(f.wait { f.cardWindow != nil && f.controller.debugOverlayWindow != nil })
        f.spin(0.8)
        let overlay = try XCTUnwrap(f.controller.debugOverlayWindow)
        XCTAssertTrue(overlay.ignoresMouseEvents, "the ring overlay spans the screen and must be click-through")
        // Nothing of the tour sits on top of the panel's own area.
        let card = try XCTUnwrap(f.cardWindow).frame
        XCTAssertFalse(card.intersects(f.panel.frame), "the card stands beside the panel, never over it")
        // At the panel's centre the topmost window that takes mouse events is the panel.
        let centre = NSPoint(x: f.panel.frame.midX, y: f.panel.frame.midY)
        let top = NSWindow.windowNumber(at: centre, belowWindowWithWindowNumber: 0)
        XCTAssertEqual(top, f.panel.windowNumber, "hit-testing the panel's centre lands on the panel")
    }

    func test_item9_twoFingerDrag_onTheCover_movesThePanel_andItSnapsToACorner_duringTheMoveStep() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: almostAll))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.spin(0.8)
        let start = f.panel.frame.origin
        // Toward the lower left.
        f.twoFingerDrag(dx: -40, dy: 30)
        XCTAssertLessThan(f.panel.frame.origin.x, start.x - 100, "the panel follows the fingers")
        XCTAssertLessThan(f.panel.frame.origin.y, start.y - 60)
        XCTAssertTrue(f.wait(4) { f.controller.state.phase == .step(.moveTuck, beats: [true, false]) },
                      "and after the spring it has snapped to a corner, which completes the first beat")
        let screen = try XCTUnwrap(f.panel.screen ?? NSScreen.main)
        XCTAssertNotNil(TourCornerMatch.corner(origin: f.panel.frame.origin, frameSize: f.panel.frame.size,
                                                visibleFrame: screen.visibleFrame, margin: f.panel.cornerMargin))
    }

    // MARK: - Item 10: the last step — tuck, peek, return

    func test_item10_ringIsOnTheStrip_thenOnThePeekCard_andTheOldCardStepsOutBeforeThePanelReturns() throws {
        f = TourRealPanelFixture(page: .album)
        f.controller.send(.resume(completed: Set(TourStep.orderedSteps).subtracting([.back])))
        XCTAssertEqual(f.controller.state.phase, .step(.back, beats: [false, false]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        // Tuck the real panel into the screen edge.
        XCTAssertTrue(f.liquidEdge.collapse(to: .right))
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .tucked })
        XCTAssertTrue(f.wait(3) { f.controller.debugHaloFrame != nil }, "a ring on the strip")
        f.spin(0.8)
        let strip = f.liquidEdge.tuckedRegionInScreen
        assertRing(on: strip, "ON the edge strip (it floated 80pt to the left of it)")
        XCTAssertEqual(f.controller.debugHaloFrame?.size.width ?? 0, 18, accuracy: 0.5)

        f.liquidEdge.hoverEntered()                         // rest the cursor on it: it peeks out
        XCTAssertTrue(f.wait(4) { f.liquidEdge.state == .floating })
        XCTAssertTrue(f.wait(3) { (f.controller.debugHaloFrame?.size.width ?? 0) > 100 }, "the ring jumps to the peek card")
        f.spin(0.8)
        assertRing(on: f.liquidEdge.floatingHitRegionInScreen, "ON the peek card, not at the stale spot")

        f.liquidEdge.expand()                               // click it: the panel comes back
        XCTAssertTrue(f.wait(0.5) { !f.controller.guidance.motion.cardVisible }, "the old card starts leaving with the click")
        XCTAssertTrue(f.wait(0.6) { (f.cardWindow?.alphaValue ?? 0) < 0.05 }, "and is gone within its 0.16 s exit, before the panel lands")
        XCTAssertTrue(f.wait(5) { f.controller.state.phase == .finale })
        XCTAssertTrue(f.wait(3) { f.controller.debugCardStore?.model.kind == .finale(deferred: true) || f.controller.debugCardStore?.model.kind == .finale(deferred: false) })
    }

    // MARK: - Item 11: the finale's primary button

    func test_item11_primaryButtonsUseTheAccent() throws {
        XCTAssertEqual(TourCardPalette.light.accent, Color(hex: 0xFA4058))
        XCTAssertEqual(TourCardPalette.dark.accent, Color(hex: 0xFB546C))
        let light = TourContrast.rgb(TourCardPalette.light.accent)
        XCTAssertEqual(light.r, 0xFA / 255.0, accuracy: 0.01)
        // Rendered: the button is pink, not black.
        let view = Button("Set a shortcut") {}.buttonStyle(TourPrimaryButtonStyle(palette: .light)).padding(8)
        let px = try XCTUnwrap(TourRender.pixels(view, size: CGSize(width: 140, height: 40), scale: 2))
        let center = px.rgba(atPoint: CGPoint(x: 14, y: 20))
        XCTAssertTrue(center.r > 200 && center.g < 120, "primary button fill is the accent pink: \(center)")
    }

    // MARK: - C.5.4: "skip this one" is a quiet retreat

    func test_skipStep_showsTheAckThenMovesOnQuietly_noHaptic_noRingGrowth() throws {
        f = TourRealPanelFixture()
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.reveal) })
        f.spin(0.5)
        let before = f.controller.state.completedCount
        f.controller.debugCardStore?.onSkipStep?()
        XCTAssertTrue(f.wait(0.5) { f.controller.debugCardStore?.model.body == self.L("tour.skip.ack") }, "the body crossfades to the acknowledgement")
        let model = try XCTUnwrap(f.controller.debugCardStore?.model)
        XCTAssertTrue(model.beats.allSatisfy { $0.skipped }, "the unfinished dots turn dashed")
        XCTAssertFalse(f.controller.guidance.motion.ringVisible, "the ring steps down while the card acknowledges")
        XCTAssertTrue(f.wait(2) { f.controller.state.stepStates[.reveal] == .skipped })
        XCTAssertEqual(f.controller.state.completedCount, before, "skipping never grows the ring")
        XCTAssertFalse(f.controller.debugFeedback.isActive, "no tick, no sparks")
        XCTAssertTrue(f.wait(2) { f.controller.debugCardStore?.model.kind == .step(.corners) })
    }

    // MARK: - Teardown

    func test_teardown_cardStepsOutThenEveryWindowIsReleased() throws {
        f = TourRealPanelFixture()
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.cardWindow != nil })
        f.controller.send(.stopTour)
        XCTAssertFalse(f.controller.guidance.motion.cardVisible, "it starts leaving at once")
        XCTAssertTrue(f.wait(1) { f.controller.debugAllocatedWindowCount == 0 })
        XCTAssertFalse(f.controller.debugHasPendingTimers)
    }

    // MARK: - Reduce Motion

    func test_reduceMotion_ringIsAStaticVisibleRing_noPulse() throws {
        f = TourRealPanelFixture(reduceMotion: true)
        f.controller.send(.resume(completed: [.connect]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        var sawRipple = false
        for _ in 0..<40 {
            f.spin(0.1)
            let frame = f.controller.guidance.motion.makeFrame()
            if !frame.ripples.isEmpty || frame.ghostVisible || frame.panelGlow > 0 { sawRipple = true }
        }
        XCTAssertFalse(sawRipple, "Reduce Motion: no pulse, no ghost cursor, no glow")
        XCTAssertNotNil(f.controller.debugHaloFrame, "but the ring itself stays")
    }
}
