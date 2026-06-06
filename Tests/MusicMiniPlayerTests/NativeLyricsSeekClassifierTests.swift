import XCTest
@testable import MusicMiniPlayerCore

/// First-class seek: natural playback only ever advances the semantic line index by 0 or +1, so any
/// other transition (backward, or forward by more than one line) is a seek discontinuity. An explicit
/// in-app seek signal (progress-bar scrub) forces a seek even for a +1 step that would look natural.
final class NativeLyricsSeekClassifierTests: XCTestCase {
    func testNaturalAdvanceIsNotSeek() {
        // Index holds or steps forward by exactly one line — the only natural transitions.
        XCTAssertFalse(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 5, explicitSeek: false))
        XCTAssertFalse(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 6, explicitSeek: false))
    }

    func testFirstFrameIsNotSeek() {
        XCTAssertFalse(NativeLyricsSeekClassifier.isSeek(previousIndex: nil, liveIndex: 7, explicitSeek: false))
    }

    func testBackwardMovementIsAlwaysSeek() {
        // Playback never rewinds on its own — backward by ANY amount (incl. 1) is a seek.
        XCTAssertTrue(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 4, explicitSeek: false))
        XCTAssertTrue(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 1, explicitSeek: false))
    }

    func testForwardSkipIsSeek() {
        // Forward by more than one line skips lines — a seek, not natural advance.
        XCTAssertTrue(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 7, explicitSeek: false))
    }

    func testExplicitSeekForcesSeekEvenForNaturalLookingStep() {
        // An in-app scrub that happens to land one line ahead must still snap, not wave.
        XCTAssertTrue(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 6, explicitSeek: true))
        XCTAssertTrue(NativeLyricsSeekClassifier.isSeek(previousIndex: 5, liveIndex: 5, explicitSeek: true))
    }
}
