import XCTest
import Combine
@testable import MusicMiniPlayerCore

/// `TourDeferredWatcher` — the one subscription allowed to survive a torn-
/// down tour. Fake clock and a manual scheduler, injected subjects standing in for
/// `LyricsService.$canTranslate` / `MusicController.$currentPage` / `MusicController.$currentTrackTitle`.
@MainActor
final class TourDeferredWatcherTests: XCTestCase {
    private var canTranslate: PassthroughSubject<Bool, Never>!
    private var trackTitle: PassthroughSubject<String, Never>!
    private var watcher: TourDeferredWatcher!
    private var events: [TourEvent] = []
    private var fakeNow = Date(timeIntervalSince1970: 1_000_000)
    private var onLyricsPage: CurrentValueSubject<Bool, Never>!
    private var panelIsVisible = true
    /// The watcher's one pending re-check (the 3 s mark), run by hand.
    private var pending: (delay: TimeInterval, work: @MainActor () -> Void)?

    override func setUp() {
        super.setUp()
        canTranslate = PassthroughSubject<Bool, Never>()
        trackTitle = PassthroughSubject<String, Never>()
        events = []
        panelIsVisible = true
        fakeNow = Date(timeIntervalSince1970: 1_000_000)
        onLyricsPage = CurrentValueSubject<Bool, Never>(true)
        pending = nil
        watcher = TourDeferredWatcher(now: { [unowned self] in self.fakeNow }, schedule: { [unowned self] delay, work in
            self.pending = (delay, work)
            return AnyCancellable { [weak self] in self?.pending = nil }
        })
        watcher.onEvent = { [unowned self] in self.events.append($0) }
    }

    private func arm() {
        watcher.arm(
            canTranslate: canTranslate.eraseToAnyPublisher(),
            onLyricsPage: onLyricsPage.eraseToAnyPublisher(),
            trackTitle: trackTitle.eraseToAnyPublisher(),
            panelVisible: { [unowned self] in self.panelIsVisible }
        )
    }

    func test_arm_setsIsArmed() {
        XCTAssertFalse(watcher.isArmed)
        arm()
        XCTAssertTrue(watcher.isArmed)
    }

    func test_canTranslateBecomesTrue_reportsSecondsSinceSongStarted() {
        arm()
        fakeNow.addTimeInterval(4.2)
        canTranslate.send(true)
        guard case .canTranslateBecameTrue(let seconds)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(seconds, 4.2, accuracy: 0.001)
        XCTAssertEqual(events.count, 1)
    }

    func test_canTranslateFalse_doesNotFire() {
        arm()
        fakeNow.addTimeInterval(4.2)
        canTranslate.send(false)
        XCTAssertTrue(events.isEmpty)
    }

    func test_canTranslateTrue_panelNotVisible_doesNotFire() {
        arm()
        panelIsVisible = false
        fakeNow.addTimeInterval(4.2)
        canTranslate.send(true)
        XCTAssertTrue(events.isEmpty)
    }

    func test_trackTitleChange_emitsSongChanged_resetsSongClock() {
        arm()
        fakeNow.addTimeInterval(10)
        trackTitle.send("A New Song")
        XCTAssertEqual(events, [.songChanged])

        events.removeAll()
        fakeNow.addTimeInterval(2.5)
        canTranslate.send(true)
        guard case .canTranslateBecameTrue(let seconds)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(seconds, 2.5, accuracy: 0.001, "the song clock must reset on track change")
    }

    func test_recordLaunch_onlyFires_whileArmed() {
        watcher.recordLaunch()
        XCTAssertTrue(events.isEmpty, "must not fire before arm()")
        arm()
        watcher.recordLaunch()
        XCTAssertEqual(events, [.launch])
    }

    func test_cancel_stopsFurtherEvents_andClearsIsArmed() {
        arm()
        watcher.cancel()
        XCTAssertFalse(watcher.isArmed)
        canTranslate.send(true)
        trackTitle.send("Whatever")
        XCTAssertTrue(events.isEmpty)
    }

    func test_rearm_replacesPreviousSubscription() {
        arm()
        let secondCanTranslate = PassthroughSubject<Bool, Never>()
        watcher.arm(canTranslate: secondCanTranslate.eraseToAnyPublisher(), trackTitle: trackTitle.eraseToAnyPublisher(), panelVisible: { true })
        canTranslate.send(true) // the OLD subject — must be ignored now
        XCTAssertTrue(events.isEmpty)
        secondCanTranslate.send(true)
        XCTAssertEqual(events.count, 1)
    }

    // MARK: - Where the tip may show: the lyrics page, with the button really there

    func test_onTheAlbumPage_neverFires_evenWithTheButtonAvailable() {
        onLyricsPage.send(false)
        arm()
        fakeNow.addTimeInterval(30)
        canTranslate.send(true)
        XCTAssertTrue(events.isEmpty)
        XCTAssertNil(pending, "and nothing is waiting to try again")
    }

    func test_onTheLyricsPage_withoutTheButton_neverFires() {
        arm()
        fakeNow.addTimeInterval(30)
        canTranslate.send(false)
        XCTAssertTrue(events.isEmpty)
    }

    func test_openingTheLyricsPageLater_firesThen_withTheSecondsIntoTheSong() {
        onLyricsPage.send(false)
        arm()
        canTranslate.send(true)
        fakeNow.addTimeInterval(40)
        XCTAssertTrue(events.isEmpty)
        onLyricsPage.send(true)
        guard case .canTranslateBecameTrue(let seconds)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(seconds, 40, accuracy: 0.001)
        XCTAssertEqual(events.count, 1)
    }

    func test_leavingTheLyricsPage_reportsTheTipUnavailable_once() {
        arm()
        canTranslate.send(true)
        events.removeAll()
        onLyricsPage.send(false)
        XCTAssertEqual(events, [.deferredTipUnavailable])
        onLyricsPage.send(false)
        canTranslate.send(false)
        XCTAssertEqual(events, [.deferredTipUnavailable], "not repeated while it stays unavailable")
    }

    func test_groundReachedBeforeThreeSeconds_isSentAgainWhenTheMarkPasses() throws {
        arm()
        fakeNow.addTimeInterval(1.0)
        canTranslate.send(true)
        guard case .canTranslateBecameTrue(let early)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertEqual(early, 1.0, accuracy: 0.001)
        let recheck = try XCTUnwrap(pending)
        XCTAssertEqual(recheck.delay, 2.05, accuracy: 0.001, "set for just past the 3 s mark")
        events.removeAll()
        fakeNow.addTimeInterval(2.05)
        recheck.work()
        guard case .canTranslateBecameTrue(let late)? = events.first else { return XCTFail("got \(events)") }
        XCTAssertGreaterThanOrEqual(late, 3.0)
        XCTAssertNil(pending, "the mark has passed: nothing more to wait for")
    }

    func test_leavingBeforeTheMark_cancelsTheRecheck() {
        arm()
        canTranslate.send(true)
        XCTAssertNotNil(pending)
        onLyricsPage.send(false)
        XCTAssertNil(pending)
    }

    func test_cancel_dropsTheRecheckToo() {
        arm()
        canTranslate.send(true)
        watcher.cancel()
        XCTAssertNil(pending)
    }
}
