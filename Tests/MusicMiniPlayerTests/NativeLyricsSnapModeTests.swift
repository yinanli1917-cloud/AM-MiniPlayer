import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsSnapModeTests: XCTestCase {

    func testNaturalModeDoesNotSnapOutsideAppearWindow() {
        let mode = NativeLyricsSnapMode.resolve(
            playbackMode: .natural,
            isWithinAppearWindow: false
        )

        XCTAssertEqual(mode.playbackMode, .natural)
        XCTAssertFalse(mode.snapsPositions)
        XCTAssertFalse(mode.snapsVisuals)
        XCTAssertFalse(mode.keepsPresentationLoopAlive)
    }

    func testDirectSnapModeSnapsPositionsAndVisuals() {
        let mode = NativeLyricsSnapMode.resolve(
            playbackMode: .directSnap(.seek),
            isWithinAppearWindow: false
        )

        XCTAssertEqual(mode.playbackMode, .directSnap(.seek))
        XCTAssertTrue(mode.snapsPositions)
        XCTAssertTrue(mode.snapsVisuals)
        XCTAssertFalse(mode.keepsPresentationLoopAlive)
    }

    func testAppearWindowKeepsPresentationLoopAliveFromSameModeValue() {
        let mode = NativeLyricsSnapMode.resolve(
            playbackMode: .directSnap(.initialLayout),
            isWithinAppearWindow: true
        )

        XCTAssertEqual(mode.playbackMode, .directSnap(.initialLayout))
        XCTAssertTrue(mode.snapsPositions)
        XCTAssertTrue(mode.snapsVisuals)
        XCTAssertTrue(mode.keepsPresentationLoopAlive)
    }
}
