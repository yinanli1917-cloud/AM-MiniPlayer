import XCTest
import Combine
@testable import MusicMiniPlayerCore

/// `TourDetectors` with every source substituted by a `PassthroughSubject` —
/// confirms each raw signal maps to the right `TourEvent`, that `.expanding`
/// alone never counts as a tuck, that `.floating` and a settled `.card`
/// (arriving FROM `.expanding`) map to back's two beats, and the pure corner
/// / translate-readiness helpers (§11.1 TourDetectorTests).
final class TourDetectorTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func collect(_ detectors: TourDetectors) -> [TourEvent] {
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        return received
    }

    func test_controlsRevealed_mapsToRevealBeatSignal() {
        let subject = PassthroughSubject<Void, Never>()
        let detectors = TourDetectors(controlsRevealed: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(())
        XCTAssertEqual(received, [.signal(.controlsRevealed)])
    }

    /// Item 4 (2026-09-29): the reveal step's second beat took only "started playing",
    /// so with music already playing it asked for a press that could never count.
    /// Every emission is now a toggle (the controller feeds `dropFirst().removeDuplicates()`),
    /// pause included.
    func test_isPlaying_everyToggleFires_pauseIncluded() {
        let subject = PassthroughSubject<Bool, Never>()
        let detectors = TourDetectors(isPlaying: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(false)
        subject.send(true)
        subject.send(false)
        XCTAssertEqual(received, [.signal(.isPlaying), .signal(.isPlaying), .signal(.isPlaying)])
    }

    func test_currentPageIsLyrics_onlyFiresOnTrue() {
        let subject = PassthroughSubject<Bool, Never>()
        let detectors = TourDetectors(currentPageIsLyrics: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(false)
        subject.send(true)
        XCTAssertEqual(received, [.signal(.onLyricsPage)])
    }

    func test_snappedCorner_mapsToPanelSettled() {
        let subject = PassthroughSubject<ScreenCorner, Never>()
        let detectors = TourDetectors(snappedCorner: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(.bottomRight)
        XCTAssertEqual(received, [.panelSettled(corner: .bottomRight)])
    }

    // MARK: - LiquidEdgeState → panelTucked / liquidEdgeFloating / panelExpanded

    func test_liquidEdgeState_tuckedSettled_mapsToPanelTucked() {
        let subject = PassthroughSubject<LiquidEdgeState, Never>()
        let detectors = TourDetectors(liquidEdgeState: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(.collapsing)
        subject.send(.tucked)
        XCTAssertEqual(received, [.panelTucked])
    }

    func test_liquidEdgeState_floating_mapsToBeatOneSignal() {
        let subject = PassthroughSubject<LiquidEdgeState, Never>()
        let detectors = TourDetectors(liquidEdgeState: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(.tucked)
        subject.send(.floating)
        XCTAssertEqual(received, [.panelTucked, .signal(.liquidEdgeFloating)])
    }

    /// `.expanding` on its own must never count as either back beat — only a
    /// settled `.card` arriving FROM `.expanding` counts as beat ②.
    func test_liquidEdgeState_expandingAlone_producesNoEvent() {
        let subject = PassthroughSubject<LiquidEdgeState, Never>()
        let detectors = TourDetectors(liquidEdgeState: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(.floating)
        subject.send(.expanding)
        XCTAssertEqual(received, [.signal(.liquidEdgeFloating)], "`.expanding` alone must not emit anything new")
    }

    func test_liquidEdgeState_cardFromExpanding_mapsToPanelExpanded() {
        let subject = PassthroughSubject<LiquidEdgeState, Never>()
        let detectors = TourDetectors(liquidEdgeState: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(.floating)
        subject.send(.expanding)
        subject.send(.card)
        XCTAssertEqual(received, [.signal(.liquidEdgeFloating), .panelExpanded])
    }

    /// A settled `.card` that did NOT come from `.expanding` (e.g. `.reset()`
    /// forcing back to `.card` directly) must not be mistaken for "the user
    /// expanded it" (§5.2's back-beat-② semantics).
    func test_liquidEdgeState_cardWithoutExpanding_doesNotMapToPanelExpanded() {
        let subject = PassthroughSubject<LiquidEdgeState, Never>()
        let detectors = TourDetectors(liquidEdgeState: subject.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        subject.send(.tucked)
        subject.send(.card) // reset(), not an expand
        XCTAssertEqual(received, [.panelTucked])
    }

    // MARK: - Merge: several sources at once

    func test_multipleSources_allSurface() {
        let reveal = PassthroughSubject<Void, Never>()
        let corner = PassthroughSubject<ScreenCorner, Never>()
        let detectors = TourDetectors(controlsRevealed: reveal.eraseToAnyPublisher(), snappedCorner: corner.eraseToAnyPublisher())
        var received: [TourEvent] = []
        detectors.events.sink { received.append($0) }.store(in: &cancellables)
        reveal.send(())
        corner.send(.topLeft)
        XCTAssertEqual(received, [.signal(.controlsRevealed), .panelSettled(corner: .topLeft)])
    }

    // MARK: - Pure helpers

    func test_cornerMatch_allFourCorners_withinTolerance() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 250, height: 284)
        let margin: CGFloat = 16
        XCTAssertEqual(TourCornerMatch.corner(origin: CGPoint(x: 1440 - 250 - 16, y: 900 - 284 - 16), frameSize: size, visibleFrame: visible, margin: margin), .topRight)
        XCTAssertEqual(TourCornerMatch.corner(origin: CGPoint(x: 16, y: 900 - 284 - 16), frameSize: size, visibleFrame: visible, margin: margin), .topLeft)
        XCTAssertEqual(TourCornerMatch.corner(origin: CGPoint(x: 1440 - 250 - 16, y: 16), frameSize: size, visibleFrame: visible, margin: margin), .bottomRight)
        XCTAssertEqual(TourCornerMatch.corner(origin: CGPoint(x: 16, y: 16), frameSize: size, visibleFrame: visible, margin: margin), .bottomLeft)
        // Within ±1pt tolerance still matches.
        XCTAssertEqual(TourCornerMatch.corner(origin: CGPoint(x: 16.8, y: 16.6), frameSize: size, visibleFrame: visible, margin: margin), .bottomLeft)
    }

    func test_cornerMatch_notACorner_returnsNil() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 250, height: 284)
        XCTAssertNil(TourCornerMatch.corner(origin: CGPoint(x: 400, y: 400), frameSize: size, visibleFrame: visible, margin: 16))
        // Just past tolerance.
        XCTAssertNil(TourCornerMatch.corner(origin: CGPoint(x: 18, y: 18), frameSize: size, visibleFrame: visible, margin: 16, tolerance: 1))
    }
}
