import XCTest
import Combine
@testable import MusicMiniPlayerCore

/// `TourHookBus` — confirms it's a plain singleton Combine bus (no state, no
/// buffering) the three new SwiftUI-side hooks post through.
@MainActor
final class TourHookBusTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func test_controlsRevealed_delivers_toAllSubscribers() {
        var count = 0
        TourHookBus.shared.controlsRevealed.sink { count += 1 }.store(in: &cancellables)
        TourHookBus.shared.controlsRevealed.send(())
        TourHookBus.shared.controlsRevealed.send(())
        XCTAssertEqual(count, 2)
    }

    func test_audioOutputMenuOpened_and_musicButtonTapped_areIndependentStreams() {
        var audioOutputCount = 0
        var musicButtonCount = 0
        TourHookBus.shared.audioOutputMenuOpened.sink { audioOutputCount += 1 }.store(in: &cancellables)
        TourHookBus.shared.musicButtonTapped.sink { musicButtonCount += 1 }.store(in: &cancellables)
        TourHookBus.shared.musicButtonTapped.send(())
        XCTAssertEqual(musicButtonCount, 1)
        XCTAssertEqual(audioOutputCount, 0)
    }

    func test_shared_isASingleton() {
        XCTAssertTrue(TourHookBus.shared === TourHookBus.shared)
    }
}
