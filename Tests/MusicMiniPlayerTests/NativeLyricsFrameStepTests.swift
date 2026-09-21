import XCTest
@testable import MusicMiniPlayerCore

final class NativeLyricsFrameStepTests: XCTestCase {
    private let f = 1.0 / 120.0

    func test_jitterAroundOneFrame_snapsToExactlyOneFrame() {
        for raw in [f * 0.7, f * 0.9, f, f * 1.1, f * 1.4] {
            XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: raw, nominal: f), f, accuracy: 1e-12)
        }
    }

    func test_twoFramesElapsed_stepsTwo() {
        XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: f * 1.6, nominal: f), 2 * f, accuracy: 1e-12)
        XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: f * 2.3, nominal: f), 2 * f, accuracy: 1e-12)
    }

    func test_neverZeroOnceAFrameIsDue_andCapped() {
        XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: 0.0001, nominal: f), f, accuracy: 1e-12)
        XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: 1.0, nominal: f), 4 * f, accuracy: 1e-12)
    }

    func test_noNominalInterval_passesRawThrough() {
        XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: 0.0123, nominal: nil), 0.0123, accuracy: 1e-12)
        XCTAssertEqual(NativeLyricsFrameStep.quantizedDelta(raw: -1, nominal: nil), 0)
    }
}
