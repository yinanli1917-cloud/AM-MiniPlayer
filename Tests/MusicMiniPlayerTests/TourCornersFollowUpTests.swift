/**
 * [INPUT]: TourRealPanelFixture (real panel + real tour windows), TourShotStudio (own-window capture),
 *          TourMusicWindowLocator / TourMusicWindowTracker / TourPlacement (pure), TourController.
 * [OUTPUT]: TourCornersFollowUpTests — the corners step's two follow-ups (founder 2026-10-02):
 *           (A) the output menu is open: a light invitation, the ring on the device list, the card clear of it,
 *               a soft acknowledgement when a device is picked, nothing required;
 *           (B) the Music beat's trip: the card hops over to the player app's window ("the full app; nanoPod is
 *               the companion beside it"), follows it, falls back, and springs home before the celebration.
 *           Also the opt-in (TOUR_CORNERS_SHOTS=1) stills: menu open, card at a fake Music window, light and dark.
 * [POS]: Tests. Never touches the real Music app or its window list: the window comes from `musicWindowProvider`.
 */

import XCTest
import AppKit
import Combine
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Pure
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TourMusicWindowPureTests: XCTestCase {
    private func info(pid: Int, layer: Int = 0, x: Double, y: Double, w: Double, h: Double, onscreen: Bool? = true, alpha: Double? = nil) -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: Double],
        ]
        if let onscreen { d[kCGWindowIsOnscreen as String] = onscreen }
        if let alpha { d[kCGWindowAlpha as String] = alpha }
        return d
    }

    // MARK: Locator

    func test_locator_picksTheLargestLayer0WindowOfThePID_andIgnoresTheRest() {
        let infos = [
            info(pid: 99, x: 0, y: 0, w: 3000, h: 2000),                  // someone else's huge window
            info(pid: 42, layer: 25, x: 0, y: 0, w: 1600, h: 1000),       // the app's menu-bar / panel layer
            info(pid: 42, x: 100, y: 80, w: 300, h: 60),                  // its mini player
            info(pid: 42, x: 200, y: 120, w: 1100, h: 700),               // its main window (largest layer-0)
            info(pid: 42, x: 200, y: 120, w: 900, h: 600),
            info(pid: 42, x: 10, y: 10, w: 20, h: 20),                    // a helper speck
            info(pid: 42, x: 0, y: 0, w: 2500, h: 1500, onscreen: false), // not on screen
            info(pid: 42, x: 0, y: 0, w: 2400, h: 1400, alpha: 0),        // fully transparent
        ]
        XCTAssertEqual(TourMusicWindowLocator.mainWindowBounds(in: infos, ownerPID: 42), CGRect(x: 200, y: 120, width: 1100, height: 700))
    }

    func test_locator_noWindowOfThatPID_isNil() {
        XCTAssertNil(TourMusicWindowLocator.mainWindowBounds(in: [info(pid: 99, x: 0, y: 0, w: 800, h: 600)], ownerPID: 42))
        XCTAssertNil(TourMusicWindowLocator.mainWindowBounds(in: [], ownerPID: 42))
        XCTAssertNil(TourMusicWindowLocator.mainWindowBounds(in: [info(pid: 42, layer: 3, x: 0, y: 0, w: 800, h: 600)], ownerPID: 42), "only ordinary windows")
    }

    func test_locator_readsRuntimeShapes_NSNumberValues() {
        let d: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: 42), kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: ["X": NSNumber(value: 10.5), "Y": NSNumber(value: 20), "Width": NSNumber(value: 640), "Height": NSNumber(value: 480)] as [String: Any],
        ]
        XCTAssertEqual(TourMusicWindowLocator.mainWindowBounds(in: [d], ownerPID: 42), CGRect(x: 10.5, y: 20, width: 640, height: 480))
    }

    func test_cgToAppKit_flipsAboutThePrimaryScreen() {
        let r = TourMusicWindowLocator.appKitRect(fromCG: CGRect(x: 100, y: 50, width: 400, height: 300), primaryScreenHeight: 1000)
        XCTAssertEqual(r, CGRect(x: 100, y: 650, width: 400, height: 300))
    }

    // MARK: Tracker

    private let a = CGRect(x: 100, y: 100, width: 800, height: 600)

    func test_tracker_settlesOnTwoAgreeingFrames_notOnAnAnimatingOne() {
        var t = TourMusicWindowTracker()
        XCTAssertNil(t.observe(nil, elapsed: 0.16))
        XCTAssertNil(t.observe(CGRect(x: 120, y: 120, width: 700, height: 500), elapsed: 0.32), "first sight of a frame is not settled")
        XCTAssertNil(t.observe(CGRect(x: 105, y: 105, width: 780, height: 580), elapsed: 0.48), "still growing")
        XCTAssertNil(t.observe(CGRect(x: 100, y: 100, width: 799, height: 600), elapsed: 0.64) , "still moving 5pt on an edge")
        XCTAssertEqual(t.observe(a, elapsed: 0.80), .found(a), "two frames within 2pt: settled")
        XCTAssertEqual(t.nextInterval, 0.5, "tracking is the slow poll")
    }

    func test_tracker_searchPollsAboutSixTimesASecond() {
        XCTAssertEqual(TourMusicWindowTracker().nextInterval ?? 0, 1.0 / 6, accuracy: 0.02)
    }

    func test_tracker_deadline_acceptsTheLastFrameSeen_orGivesUp() {
        var animating = TourMusicWindowTracker()
        _ = animating.observe(CGRect(x: 0, y: 0, width: 500, height: 400), elapsed: 1.0)
        XCTAssertEqual(animating.observe(CGRect(x: 40, y: 40, width: 600, height: 500), elapsed: 2.0), .found(CGRect(x: 40, y: 40, width: 600, height: 500)), "out of time with a window on screen: use it")

        var none = TourMusicWindowTracker()
        XCTAssertNil(none.observe(nil, elapsed: 1.0))
        XCTAssertEqual(none.observe(nil, elapsed: 2.0), .gaveUp)
        XCTAssertNil(none.nextInterval, "no more samples")
        XCTAssertTrue(none.isFinished)
        XCTAssertNil(none.observe(a, elapsed: 2.2), "and nothing more comes out of it")
    }

    func test_tracker_followsAMovedWindow_ignoresJitter_andLosesAClosedOne() {
        var t = TourMusicWindowTracker()
        _ = t.observe(a, elapsed: 0.2)
        XCTAssertEqual(t.observe(a, elapsed: 0.4), .found(a))
        XCTAssertNil(t.observe(a.offsetBy(dx: 3, dy: -2), elapsed: 0.9), "within the move tolerance")
        let moved = a.offsetBy(dx: 80, dy: 0)
        XCTAssertEqual(t.observe(moved, elapsed: 1.4), .moved(moved))
        XCTAssertNil(t.observe(nil, elapsed: 1.9), "one empty sample is a blink")
        XCTAssertNil(t.observe(moved, elapsed: 2.4), "and it came back")
        XCTAssertNil(t.observe(nil, elapsed: 2.9))
        XCTAssertEqual(t.observe(nil, elapsed: 3.4), .lost)
        XCTAssertNil(t.nextInterval)
    }

    // MARK: Placement

    private let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private let card = CGSize(width: 272, height: 210)
    private let panel = CGRect(x: 1334, y: 600, width: 250, height: 284)   // top-right of the screen

    private func assertSound(_ p: TourCardPlacement, window: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let rect = CGRect(origin: p.origin, size: card)
        XCTAssertTrue(visible.contains(rect), "on screen: \(rect)", file: file, line: line)
        XCTAssertFalse(rect.intersects(panel), "never over the panel", file: file, line: line)
        // The beak tip lies on the card's straight edge.
        XCTAssertGreaterThanOrEqual(p.beakOffset, TourPlacement.beakCornerClamp - 0.01, file: file, line: line)
        XCTAssertLessThanOrEqual(p.beakOffset, card.height - TourPlacement.beakCornerClamp + 0.01, file: file, line: line)
    }

    func test_placeNearWindow_panelAtTheRight_cardStandsAtTheWindowsRightEdge_beakPointsAtIt() throws {
        let window = CGRect(x: 100, y: 200, width: 800, height: 600)
        let p = try XCTUnwrap(TourPlacement.placeNearWindow(cardSize: card, window: window, panelFrame: panel, visibleFrame: visible))
        assertSound(p, window: window)
        XCTAssertEqual(p.beakSide, .left, "the card is right of the window: its beak is on its left edge, aimed at the window")
        XCTAssertEqual(p.origin.x, window.maxX + TourPlacement.panelGap, accuracy: 0.5)
        let tipY = p.origin.y + p.beakOffset
        XCTAssertEqual(tipY, window.midY, accuracy: 0.5, "aimed at the middle of the window's edge")
    }

    func test_placeNearWindow_windowTooCloseToThePanel_cardGoesToTheWindowsFarEdge() throws {
        let window = CGRect(x: 400, y: 200, width: 840, height: 600)      // 1240; the panel starts at 1334: no room for a 272 card
        let p = try XCTUnwrap(TourPlacement.placeNearWindow(cardSize: card, window: window, panelFrame: panel, visibleFrame: visible))
        assertSound(p, window: window)
        XCTAssertEqual(p.beakSide, .right, "left of the window, beak on the card's right edge, aimed at the window")
        XCTAssertEqual(p.origin.x + card.width, window.minX - TourPlacement.panelGap, accuracy: 0.5)
    }

    func test_placeNearWindow_aWindowFillingTheScreen_cardGoesInsideItsTopLeft() throws {
        let window = CGRect(x: 0, y: 0, width: 1320, height: 900)         // fills the screen up to the panel
        let p = try XCTUnwrap(TourPlacement.placeNearWindow(cardSize: card, window: window, panelFrame: panel, visibleFrame: visible))
        assertSound(p, window: window)
        let rect = CGRect(origin: p.origin, size: card)
        XCTAssertTrue(window.contains(rect), "inside the window")
        XCTAssertLessThan(rect.minX - window.minX, 60, "in its left region")
        XCTAssertGreaterThan(rect.midY, window.midY, "in its upper half")
        XCTAssertEqual(p.beakSide, .left)
    }

    func test_placeNearWindow_nothingFits_isNil() {
        // A short screen: no outside edge has width for the card, and the card is taller than the screen's visible height.
        XCTAssertNil(TourPlacement.placeNearWindow(cardSize: CGSize(width: 272, height: 210), window: CGRect(x: 0, y: 0, width: 300, height: 260),
                                                   panelFrame: CGRect(x: 310, y: 0, width: 250, height: 284), visibleFrame: CGRect(x: 0, y: 0, width: 560, height: 200)))
    }

    func test_placeNearPanel_preferringLeft_standsLeft_andFallsBackWhenItDoesNotFit() {
        let anchor = CGRect(x: 1400, y: 700, width: 214, height: 128)
        let atRightEdge = TourPlacement.placeNearPanel(cardSize: card, anchor: anchor, panelFrame: panel, visibleFrame: visible, preferring: .left)
        XCTAssertEqual(atRightEdge.beakSide, .right, "left of the panel: beak on the card's right edge")
        let leftPanel = CGRect(x: 16, y: 600, width: 250, height: 284)
        let center = TourPlacement.placeNearPanel(cardSize: card, anchor: anchor, panelFrame: leftPanel, visibleFrame: visible, preferring: .left)
        XCTAssertEqual(center.beakSide, .left, "no room on the left of a panel at the screen's left edge: the other side")
        let dflt = TourPlacement.placeNearPanel(cardSize: card, anchor: anchor, panelFrame: panel, visibleFrame: visible)
        XCTAssertEqual(dflt, atRightEdge, "(the default side for a top-right panel is already the left)")
    }

    // MARK: Resolver, copy

    func test_resolver_menuOpen_ringLeavesTheButtonForTheList_asAHint() {
        let phase = TourPhase.step(.corners, beats: [true, false])
        let closed = TourGuidanceResolver.target(phase: phase, surface: TourSurface(controlsVisible: true))
        XCTAssertEqual(closed?.subject, .control(.musicButton))
        let open = TourGuidanceResolver.target(phase: phase, surface: TourSurface(controlsVisible: true, outputMenuOpen: true))
        XCTAssertEqual(open?.subject, .control(.audioOutputMenu))
        XCTAssertEqual(open?.mode, .hint, "optional to try: a gentle ring, not a press-now")
        let fresh = TourGuidanceResolver.target(phase: .step(.corners, beats: [false, false]), surface: TourSurface(controlsVisible: true, outputMenuOpen: true))
        XCTAssertEqual(fresh?.subject, .control(.audioOutputMenu))
        XCTAssertNotEqual(TourGuidanceResolver.target(phase: .step(.lyrics, beats: [false]), surface: TourSurface(controlsVisible: true, outputMenuOpen: true))?.subject, .control(.audioOutputMenu), "only the corners step cares")
        let shape = TourGuidanceResolver.menuRingShape(menuRect: CGRect(x: 0, y: 0, width: 214, height: 128))
        XCTAssertGreaterThan(shape.size.width, 214)
        XCTAssertGreaterThan(shape.size.height, 128)
    }

    func test_copy_zhAndEn_noteTheRules() throws {
        for key in ["tour.corners.bodyOutputMenu", "tour.corners.bodyOutputSwitched", "tour.corners.bodyMusicWindow"] {
            let pair = try XCTUnwrap(L10n.allStrings[key], key)
            XCTAssertFalse(pair.zh.isEmpty || pair.en.isEmpty, key)
            XCTAssertFalse(pair.zh.contains("甩"), key)
            XCTAssertFalse(pair.en.lowercased().contains("flick") || pair.en.lowercased().contains("swipe"), key)
        }
        let saved = L10n.languageOverride
        defer { L10n.languageOverride = saved }
        L10n.languageOverride = "zh"
        XCTAssertEqual(L10n.localized("tour.corners.bodyOutputMenu"), "这些都是能出声的地方。想换就点一个，听听差别；换回来也一样简单。")
        XCTAssertEqual(L10n.localized("tour.corners.bodyOutputSwitched"), "好，换过去了。")
        XCTAssertEqual(L10n.localized("tour.corners.bodyMusicWindow", player: .appleMusic), "这是完整的 Apple Music，找歌、整理歌单都在这儿。nanoPod 是它身边的小伙伴，平时安静地陪你听。看完了，把鼠标移回 nanoPod 就能接着来。")
        XCTAssertTrue(L10n.localized("tour.corners.bodyMusicWindow", player: .neteaseCloudMusic).contains("NetEase Cloud Music"), "another edition reads correctly")
        XCTAssertFalse(L10n.localized("tour.corners.bodyMusicWindow", player: .neteaseCloudMusic).contains("Apple Music"))
        L10n.languageOverride = "en"
        XCTAssertTrue(L10n.localized("tour.corners.bodyMusicWindow", player: .appleMusic).contains("full Apple Music"))
        XCTAssertTrue(L10n.localized("tour.corners.bodyMusicWindow", player: .appleMusic).contains("companion"))
        XCTAssertTrue(L10n.localized("tour.corners.bodyMusicWindow", player: .appleMusic).hasSuffix("move the pointer back to nanoPod to carry on."), "it ends by inviting the user back")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Real panel
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
final class TourCornersFollowUpTests: XCTestCase {
    private var f: TourRealPanelFixture!
    private let activations = PassthroughSubject<String?, Never>()
    private let own = "com.yinanli.nanoPod"
    /// What the fake player-app window reports (screen space, AppKit). nil = no window.
    private var musicWindow: CGRect?
    private var providerCalls = 0

    override func tearDown() {
        f?.tearDown()
        f = nil
        musicWindow = nil
        super.tearDown()
    }

    private var body: String? { f.controller.debugCardStore?.model.body }
    private func text(_ key: String) -> String { L10n.localized(key) }
    private var musicHint: String { L10n.localized("tour.corners.bodyMusic", player: .appleMusic) }
    private var windowText: String { L10n.localized("tour.corners.bodyMusicWindow", player: .appleMusic) }

    private func startCorners(dark: Bool = false) {
        f = TourRealPanelFixture(dark: dark)
        f.controller.appActivations = activations.eraseToAnyPublisher()
        f.controller.ownBundleIdentifier = own
        f.controller.musicWindowProvider = { [unowned self] in providerCalls += 1; return musicWindow }
        f.controller.musicWindowTiming.searchInterval = 0.05
        f.controller.musicWindowTiming.trackInterval = 0.1
        f.controller.musicWindowTiming.searchDeadline = 0.8
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect, .reveal]))
        XCTAssertTrue(f.wait { f.controller.debugHaloFrame != nil })
        f.spin(0.7)
    }

    /// The menu rect as the real view lays it out: 214 wide, right edge 12pt in from the panel's, 49pt under its top (12 padding + 37 offset).
    private func menuScreenRect(rows: Int = 3) -> CGRect {
        let h = CGFloat(rows * 38 + 14)
        let p = f.panel.frame
        return CGRect(x: p.maxX - 12 - 214, y: p.maxY - 49 - h, width: 214, height: h)
    }

    /// What `AudioOutputSwitcherView` does when the menu opens: the anchor lands, "presented", then the host's "opened".
    @discardableResult
    private func openMenu(rows: Int = 3) -> CGRect {
        let rect = menuScreenRect(rows: rows)
        let p = f.panel.frame
        // (hosting-view global space: top-left of the panel, y down)
        TourAnchorRegistry.shared.update([.audioOutputMenu: CGRect(x: rect.minX - p.minX, y: p.maxY - rect.maxY, width: rect.width, height: rect.height)])
        TourHookBus.shared.audioOutputMenuPresented.send(true)
        TourHookBus.shared.audioOutputMenuOpened.send(())
        return rect
    }

    private func closeMenu() {
        TourHookBus.shared.audioOutputMenuPresented.send(false)
        TourAnchorRegistry.shared.remove(.audioOutputMenu)
    }

    // MARK: - A. The output menu

    func test_menuOpen_cardInvitesLightly_beatStillCompletes_noExtraBeatRequired() throws {
        startCorners()
        XCTAssertEqual(body, text("tour.corners.body"))
        openMenu()
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "opening the menu is still the top-right beat")
        XCTAssertTrue(f.wait(2) { self.body == self.text("tour.corners.bodyOutputMenu") })
        XCTAssertEqual(body, "These are all the places that can play sound. Tap one to hear the difference; switching back is just as easy.")
        XCTAssertEqual(f.controller.debugCardStore?.model.beats.count, 2, "no third beat was added")
        XCTAssertNotEqual(f.controller.state.stepStates[.corners], .completed)
    }

    func test_menuOpen_ringMovesOntoTheDeviceList_notTheButton_thenBack() throws {
        startCorners()
        let button = f.restingRect(.audioOutput)
        let menu = openMenu()
        XCTAssertTrue(f.wait(3) {
            guard let r = f.controller.debugHaloFrame else { return false }
            return abs(r.midX - menu.midX) < 2 && abs(r.midY - menu.midY) < 2
        }, "the ring is on the list, not on the button \(button)")
        let ring = try XCTUnwrap(f.controller.debugHaloFrame)
        XCTAssertGreaterThan(ring.width, menu.width, "it hugs the list")
        XCTAssertTrue(f.controller.debugRingIsDashed, "a hint, not a press-now")

        closeMenu()
        XCTAssertTrue(f.wait(3) {
            guard let r = f.controller.debugHaloFrame else { return false }
            let capsule = f.restingRect(.musicButton)
            return abs(r.midX - capsule.midX) < 2 && abs(r.midY - capsule.midY) < 2
        }, "closed: the ring goes on to the Music capsule, never left on the stale list rect")
        XCTAssertNil(TourAnchorRegistry.shared.rect(for: .audioOutputMenu))
    }

    func test_menuOpen_cardStandsBesideThePanel_clearOfTheMenu_onTheSideAwayFromIt() throws {
        startCorners()
        let menu = openMenu()
        XCTAssertTrue(f.wait(3) { self.body == self.text("tour.corners.bodyOutputMenu") })
        f.spin(1.0)
        let card = try XCTUnwrap(f.cardWindow).frame
        XCTAssertFalse(card.intersects(menu), "the card does not cover the menu")
        XCTAssertFalse(card.intersects(f.panel.frame), "nor the panel")
        XCTAssertLessThanOrEqual(card.maxX, f.panel.frame.minX, "left of the panel: the menu is on its right")
        let placement = try XCTUnwrap(f.controller.debugLastPlacement)
        XCTAssertEqual(placement.beakSide, .right)
        XCTAssertEqual(f.controller.debugLastAnchorRect?.midY ?? 0, menu.midY, accuracy: 1, "the card is centred on the list")
    }

    func test_menuClosed_withoutSwitching_theNormalFlowReturns_andTheMusicHintAppears() throws {
        startCorners()
        openMenu()
        XCTAssertTrue(f.wait(2) { self.body == self.text("tour.corners.bodyOutputMenu") })
        closeMenu()
        XCTAssertTrue(f.wait(2) { self.body == self.musicHint }, "the Music beat is next: its hint")
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]))
    }

    func test_deviceSwitched_softAcknowledgement_thenTheNormalFlow_neverARequiredBeat() throws {
        startCorners()
        f.controller.outputAckDuration = 0.5
        openMenu()
        XCTAssertTrue(f.wait(2) { self.body == self.text("tour.corners.bodyOutputMenu") })
        TourHookBus.shared.audioOutputDeviceSwitched.send(())
        XCTAssertTrue(f.wait(2) { self.body == "Okay, switched over." })
        closeMenu()                                           // the real menu closes ~0.1 s after a switch
        f.spin(0.2)
        XCTAssertEqual(body, "Okay, switched over.", "the acknowledgement outlives the menu's closing")
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "no beat was added or completed by switching")
        XCTAssertTrue(f.wait(2) { self.body == self.musicHint }, "then the step's normal text")
        XCTAssertFalse(f.controller.debugMusicWindowWatching, "no sampling for a menu")
    }

    func test_deviceSwitched_reopeningTheMenuEndsTheAcknowledgement() throws {
        startCorners()
        openMenu()
        TourHookBus.shared.audioOutputDeviceSwitched.send(())
        XCTAssertTrue(f.wait(2) { self.body == "Okay, switched over." })
        closeMenu()
        openMenu()
        XCTAssertTrue(f.wait(2) { self.body == self.text("tour.corners.bodyOutputMenu") })
    }

    func test_menuOpenedOnAnotherStep_changesNothing() throws {
        f = TourRealPanelFixture()
        f.showControls(on: .album)
        TourHookBus.shared.controlsVisible.send(true)
        f.controller.send(.resume(completed: [.connect]))       // the reveal step
        XCTAssertTrue(f.wait { f.controller.debugCardStore?.model.kind == .step(.reveal) })
        let before = body
        TourHookBus.shared.audioOutputMenuPresented.send(true)
        TourHookBus.shared.audioOutputDeviceSwitched.send(())
        f.spin(0.4)
        XCTAssertEqual(body, before)
    }

    // MARK: - B. The card at the player app's window

    /// The corners step, output beat ticked, the Music capsule tapped: the tour waits.
    private func tapMusic() {
        f.controller.send(.signal(.audioOutputMenuOpened))
        XCTAssertTrue(f.wait { self.body == self.musicHint })
        f.spin(0.6)
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.controller.isHoldingForMusicReturn)
    }

    /// A window comfortably left of the panel with room between them for the card.
    private func fakeWindow(extraGap: CGFloat = 0) -> CGRect {
        let v = NSScreen.main!.visibleFrame
        let panel = f.panel.frame
        let cardW: CGFloat = 272
        let maxX = panel.minX - 8 - cardW - 16 - 16 - extraGap
        let width = min(640, maxX - v.minX - 40)
        return CGRect(x: maxX - width, y: v.maxY - 620, width: width, height: 560)
    }

    func test_noPollingBeforeTheTap() throws {
        startCorners()
        f.controller.send(.signal(.audioOutputMenuOpened))
        f.spin(0.5)
        XCTAssertEqual(providerCalls, 0)
        XCTAssertFalse(f.controller.debugMusicWindowWatching)
    }

    func test_tapMusic_windowFound_cardHopsOverToIt_beakAimedAtIt_saysWhatItIs() throws {
        startCorners()
        let window = fakeWindow()
        musicWindow = window
        tapMusic()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText }, "the card names the full app and nanoPod's role")
        XCTAssertEqual(body, "This is the full Apple Music: finding songs and building playlists happen here. nanoPod is the little companion beside it, quietly keeping you company while you listen. When you're done looking, move the pointer back to nanoPod to carry on.")
        f.spin(1.2)
        let card = try XCTUnwrap(f.cardWindow).frame
        XCTAssertFalse(card.intersects(f.panel.frame), "not over the panel")
        let visible = NSScreen.main!.visibleFrame
        XCTAssertTrue(visible.contains(card), "on screen: \(card) in \(visible)")
        XCTAssertEqual(card.minX, window.maxX + TourPlacement.panelGap, accuracy: 1, "at the window's edge toward the panel")
        XCTAssertEqual(f.controller.musicWindowFrame, window)
        let placement = try XCTUnwrap(f.controller.debugLastPlacement)
        XCTAssertEqual(placement.beakSide, .left, "beak on the card's window-facing edge")
        let store = try XCTUnwrap(f.controller.debugCardStore)
        XCTAssertEqual(store.beakSide, .left)
        XCTAssertEqual(card.maxY - store.beakOffset, window.midY, accuracy: 6, "the beak tip is level with the window's middle")
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "still waiting: no celebration")
        XCTAssertNil(f.controller.debugHaloFrame, "and no ring")
    }

    func test_noWindow_cardStaysBesideThePanel_withTheWaitingLine_andPollingEnds() throws {
        startCorners()
        musicWindow = nil
        tapMusic()
        let before = try XCTUnwrap(f.cardWindow).frame
        XCTAssertTrue(f.wait(3) { !f.controller.debugMusicWindowWatching }, "gave up after the search deadline")
        f.spin(0.4)
        XCTAssertEqual(try XCTUnwrap(f.cardWindow).frame.origin.x, before.origin.x, accuracy: 1, "the card did not move")
        XCTAssertNil(f.controller.musicWindowFrame)
        XCTAssertEqual(body, text("tour.corners.bodyWaiting"))
        let calls = providerCalls
        f.spin(0.5)
        XCTAssertEqual(providerCalls, calls, "no sampling once it has given up")
    }

    func test_windowAppearsLate_withinTheSearch_cardGoesThen() throws {
        startCorners()
        tapMusic()
        f.spin(0.3)
        XCTAssertEqual(body, text("tour.corners.bodyWaiting"))
        musicWindow = fakeWindow()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
    }

    func test_windowMoves_cardFollows_windowCloses_cardGoesBackToThePanelSide() throws {
        startCorners()
        let window = fakeWindow()
        musicWindow = window
        tapMusic()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
        f.spin(1.0)
        let x0 = try XCTUnwrap(f.cardWindow).frame.minX

        let moved = window.offsetBy(dx: -60, dy: -40)
        musicWindow = moved
        XCTAssertTrue(f.wait(3) { f.controller.musicWindowFrame == moved })
        f.spin(1.2)
        let moved1 = try XCTUnwrap(f.cardWindow).frame
        XCTAssertEqual(moved1.minX, x0 - 60, accuracy: 2, "the card followed the window")

        musicWindow = nil                                      // the window closes
        XCTAssertTrue(f.wait(3) { f.controller.musicWindowFrame == nil })
        XCTAssertTrue(f.wait(2) { self.body == self.text("tour.corners.bodyWaiting") })
        f.spin(1.2)
        let home = try XCTUnwrap(f.cardWindow).frame
        XCTAssertLessThanOrEqual(home.maxX, f.panel.frame.minX, "back beside the panel")
        XCTAssertFalse(f.controller.debugMusicWindowWatching, "and the sampling ended with the window")
        XCTAssertTrue(f.controller.isHoldingForMusicReturn, "still waiting for the user")
    }

    func test_return_cardSpringsBackBesideThePanel_thenTheCelebrationPlays_andSamplingStops() throws {
        startCorners()
        let window = fakeWindow()
        musicWindow = window
        tapMusic()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
        f.spin(1.0)
        XCTAssertGreaterThan(f.controller.debugMusicWindowWatching ? 1 : 0, 0, "sampling while the card is over there")

        activations.send("com.apple.finder")                   // the user went on to something else
        XCTAssertFalse(f.controller.isHoldingForMusicReturn)
        XCTAssertFalse(f.controller.debugMusicWindowWatching, "sampling stops the moment the user is back")
        XCTAssertTrue(f.controller.isReturningFromMusic)
        XCTAssertNil(f.controller.musicWindowFrame)
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]), "the held tap is not delivered until the card is home")
        let calls = providerCalls

        XCTAssertTrue(f.wait(3) { f.controller.state.stepStates[.corners] == .completed }, "then the usual completion")
        XCTAssertFalse(f.controller.isReturningFromMusic)
        XCTAssertEqual(f.controller.state.completedCount, 3)
        XCTAssertTrue(f.wait(5) {
            if case .step(.lyrics, _) = f.controller.state.phase { return f.controller.debugCardStore?.model.kind == .step(.lyrics) }
            return false
        }, "and the transition to the next step")
        f.spin(0.6)
        XCTAssertEqual(providerCalls, calls, "no polling after the return")
        XCTAssertFalse(f.controller.debugMusicWindowWatching)
    }

    func test_return_cardIsBesideThePanelBeforeTheHeldTapLands() throws {
        startCorners()
        musicWindow = fakeWindow(extraGap: 600)
        tapMusic()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
        f.spin(1.0)
        let away = try XCTUnwrap(f.cardWindow).frame
        XCTAssertLessThan(away.maxX, f.panel.frame.minX - 500, "fixture sanity: it was far away")
        TourHookBus.shared.controlsVisible.send(false)
        TourHookBus.shared.controlsVisible.send(true)          // the cursor re-enters the panel
        XCTAssertTrue(f.controller.isReturningFromMusic)
        // Just before the tap lands the card has arrived next to the panel.
        f.spin(TourController.musicHopHomeDelay - 0.05)
        XCTAssertEqual(f.controller.state.phase, .step(.corners, beats: [true, false]))
        let near = try XCTUnwrap(f.cardWindow).frame
        XCTAssertLessThanOrEqual(near.maxX, f.panel.frame.minX, "beside the panel")
        XCTAssertGreaterThan(near.minX, f.panel.frame.minX - 400)
        XCTAssertTrue(f.wait(3) { f.controller.state.stepStates[.corners] == .completed })
    }

    func test_skipWhileHopping_dropsTheHeldTap() throws {
        startCorners()
        musicWindow = fakeWindow()
        tapMusic()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
        activations.send("com.apple.finder")
        XCTAssertTrue(f.controller.isReturningFromMusic)
        f.controller.send(.skipStep)
        XCTAssertFalse(f.controller.isReturningFromMusic)
        f.spin(TourController.musicHopHomeDelay + 0.3)
        XCTAssertNotEqual(f.controller.state.stepStates[.corners], .completed, "skipped, not completed by a late tap")
    }

    func test_stopWhileAway_endsSamplingAndWindows() throws {
        startCorners()
        musicWindow = fakeWindow()
        tapMusic()
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
        f.controller.send(.stopTour)
        XCTAssertFalse(f.controller.debugMusicWindowWatching)
        XCTAssertNil(f.controller.musicWindowFrame)
        let calls = providerCalls
        f.spin(0.6)
        XCTAssertEqual(providerCalls, calls)
    }

    // MARK: - Stills (opt-in)

    /// A stand-in for the player app's window, drawn by us (never the real one): title bar, sidebar, album tiles.
    private final class FakeMusicWindowView: NSView {
        var dark = false
        override func draw(_ dirtyRect: NSRect) {
            let bg = dark ? NSColor(srgbRed: 0.13, green: 0.12, blue: 0.13, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.96, blue: 0.96, alpha: 1)
            let side = dark ? NSColor(srgbRed: 0.18, green: 0.17, blue: 0.18, alpha: 1) : NSColor(srgbRed: 0.91, green: 0.90, blue: 0.90, alpha: 1)
            let ink = dark ? NSColor.white : NSColor.black
            bg.setFill(); bounds.fill()
            side.setFill(); NSRect(x: 0, y: 0, width: 170, height: bounds.height).fill()
            let bar = NSRect(x: 0, y: bounds.maxY - 52, width: bounds.width, height: 52)
            (dark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill(); bar.fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill(); NSBezierPath(ovalIn: NSRect(x: 16 + CGFloat(i) * 20, y: bounds.maxY - 32, width: 12, height: 12)).fill()
            }
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: ink.withAlphaComponent(0.8)]
            "Apple Music".draw(at: NSPoint(x: bounds.midX - 40, y: bounds.maxY - 36), withAttributes: title)
            let rowAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink.withAlphaComponent(0.6)]
            for (i, name) in ["Listen Now", "Browse", "Radio", "Library", "Playlists"].enumerated() {
                name.draw(at: NSPoint(x: 22, y: bounds.maxY - 96 - CGFloat(i) * 30), withAttributes: rowAttr)
            }
            let tiles: [NSColor] = [.systemPink, .systemOrange, .systemTeal, .systemIndigo, .systemRed, .systemBrown]
            for (i, c) in tiles.enumerated() {
                let col = i % 3, row = i / 3
                let r = NSRect(x: 200 + CGFloat(col) * 150, y: bounds.maxY - 230 - CGFloat(row) * 190, width: 130, height: 130)
                c.withAlphaComponent(dark ? 0.7 : 0.8).setFill()
                NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
                ink.withAlphaComponent(0.22).setFill()
                NSRect(x: r.minX, y: r.minY - 18, width: 100, height: 7).fill()
                NSRect(x: r.minX, y: r.minY - 32, width: 64, height: 6).fill()
            }
        }
    }

    /// A stand-in for the open output list (three rows), for the stills only.
    private final class FakeMenuView: NSView {
        var dark = false
        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
            (dark ? NSColor(white: 0.16, alpha: 0.96) : NSColor(white: 0.97, alpha: 0.96)).setFill(); shape.fill()
            (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.18).setStroke(); shape.lineWidth = 0.75; shape.stroke()
            let ink = dark ? NSColor.white : NSColor.black
            for (i, name) in ["MacBook Pro Speakers", "AirPods Pro", "Living Room HomePod"].enumerated() {
                let y = bounds.maxY - 7 - CGFloat(i + 1) * 38 + 3
                if i == 0 { NSColor.controlAccentColor.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect: NSRect(x: 7, y: y, width: bounds.width - 14, height: 32), xRadius: 12, yRadius: 12).fill() }
                ink.withAlphaComponent(0.25).setFill(); NSBezierPath(ovalIn: NSRect(x: 14, y: y + 4, width: 24, height: 24)).fill()
                name.draw(at: NSPoint(x: 46, y: y + 8), withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: i == 0 ? .semibold : .medium), .foregroundColor: ink.withAlphaComponent(0.85)])
            }
        }
    }

    private func shots(dark: Bool) throws {
        let studio = TourShotStudio(dark: dark)
        studio.outDir = ProcessInfo.processInfo.environment["TOUR_CORNERS_SHOTS_DIR"]
            ?? "/private/tmp/claude-501/-Users-yinanli-Documents-MusicMiniPlayer/cfb45a38-b79d-442a-a7fa-137414b7e316/scratchpad/tour-corners-shots"
        var fakeWindow: NSWindow?
        defer { fakeWindow?.orderOut(nil); studio.finish() }
        startCorners(dark: dark)
        // A wide wallpaper: the Music window stands left of the card, the card left of the panel.
        let panel = f.panel.frame
        let win = self.fakeWindow()
        studio.backdrop.setFrame(NSRect(x: win.minX - 40, y: panel.maxY - 780, width: panel.maxX + 40 - (win.minX - 40), height: 780), display: true)
        studio.settleBackdrop(f)
        f.spin(0.5)

        // 1. The menu is open.
        f.controller.send(.signal(.audioOutputMenuOpened))
        f.spin(0.8)
        let menu = openMenuForShot()
        // The real list is not on screen in a headless still (it needs a click): a stand-in of the same size and place.
        let fakeMenu = NSWindow(contentRect: menu, styleMask: [.borderless], backing: .buffered, defer: false)
        fakeMenu.isReleasedWhenClosed = false
        fakeMenu.level = .floating
        fakeMenu.isOpaque = false
        fakeMenu.backgroundColor = .clear
        fakeMenu.ignoresMouseEvents = true
        let menuView = FakeMenuView(frame: NSRect(origin: .zero, size: menu.size))
        menuView.dark = dark
        fakeMenu.contentView = menuView
        fakeMenu.orderFrontRegardless()
        defer { fakeMenu.orderOut(nil) }
        f.spin(1.4)
        studio.shoot("1-menuOpen", fixture: f, extraRect: menu)
        fakeMenu.orderOut(nil)
        closeMenu()
        f.spin(1.0)

        // 2. The card at the (fake) player app's window.
        let w = NSWindow(contentRect: win, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.hasShadow = true
        w.level = .floating
        w.isOpaque = true
        w.ignoresMouseEvents = true
        let v = FakeMusicWindowView(frame: NSRect(origin: .zero, size: win.size))
        v.dark = dark
        w.contentView = v
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 12
        w.contentView?.layer?.masksToBounds = true
        w.isOpaque = false
        w.backgroundColor = .clear
        fakeWindow = w
        studio.backdrop.orderFrontRegardless()
        w.orderFrontRegardless()
        f.panel.orderFrontRegardless()
        musicWindow = w.frame
        f.controller.send(.signal(.musicButtonTapped))
        XCTAssertTrue(f.wait(3) { self.body == self.windowText })
        f.spin(1.6)
        studio.shoot("2-cardAtMusicWindow", fixture: f, extraRect: w.frame)
    }

    private func openMenuForShot() -> CGRect {
        // The menu's rect for the ring/card; the real view's own menu is not on screen in this still, so draw nothing extra.
        let rect = menuScreenRect()
        let p = f.panel.frame
        TourAnchorRegistry.shared.update([.audioOutputMenu: CGRect(x: rect.minX - p.minX, y: p.maxY - rect.maxY, width: rect.width, height: rect.height)])
        TourHookBus.shared.audioOutputMenuPresented.send(true)
        return rect
    }

    func test_stills_lightAndDark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TOUR_CORNERS_SHOTS"] == "1", "opt-in: puts windows on the screen")
        try shots(dark: false)
        f.tearDown(); f = nil
        try shots(dark: true)
    }
}
