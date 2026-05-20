import XCTest
@testable import MusicMiniPlayerCore

final class ScrollDetectorTests: XCTestCase {
    func testMomentumOnlyEventCannotStartScrollGesture() {
        XCTAssertTrue(
            ScrollEventPolicy.shouldDropMomentumOnlyEvent(
                isMomentum: true,
                isAlreadyScrolling: false
            )
        )
    }

    func testMomentumCanContinueActiveScrollGesture() {
        XCTAssertFalse(
            ScrollEventPolicy.shouldDropMomentumOnlyEvent(
                isMomentum: true,
                isAlreadyScrolling: true
            )
        )
    }

    func testNormalScrollEventCanStartScrollGesture() {
        XCTAssertFalse(
            ScrollEventPolicy.shouldDropMomentumOnlyEvent(
                isMomentum: false,
                isAlreadyScrolling: false
            )
        )
    }

    func testOutOfBoundsEventCannotStartScrollGesture() {
        XCTAssertTrue(
            ScrollEventPolicy.shouldDropOutOfBoundsEvent(
                isInsideDetectorBounds: false,
                isAlreadyScrolling: false
            )
        )
    }

    func testOutOfBoundsEventCanContinueActiveScrollGesture() {
        XCTAssertFalse(
            ScrollEventPolicy.shouldDropOutOfBoundsEvent(
                isInsideDetectorBounds: false,
                isAlreadyScrolling: true
            )
        )
    }
}
