import XCTest
import Combine
@testable import MusicMiniPlayerCore

/// `TourDeferredWatcher` — the one subscription allowed to survive a torn-
/// down tour. Fake clock, injected `PassthroughSubject`s standing in for
/// `LyricsService.$canTranslate` / `MusicController.$currentTrackTitle`.
@MainActor
final class TourDeferredWatcherTests: XCTestCase {
    private var canTranslate: PassthroughSubject<Bool, Never>!
    private var trackTitle: PassthroughSubject<String, Never>!
    private var watcher: TourDeferredWatcher!
    private var events: [TourEvent] = []
    private var fakeNow = Date(timeIntervalSince1970: 1_000_000)
    private var panelIsVisible = true

    override func setUp() {
        super.setUp()
        canTranslate = PassthroughSubject<Bool, Never>()
        trackTitle = PassthroughSubject<String, Never>()
        events = []
        panelIsVisible = true
        fakeNow = Date(timeIntervalSince1970: 1_000_000)
        watcher = TourDeferredWatcher(now: { [unowned self] in self.fakeNow })
        watcher.onEvent = { [unowned self] in self.events.append($0) }
    }

    private func arm() {
        watcher.arm(
            canTranslate: canTranslate.eraseToAnyPublisher(),
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
}
