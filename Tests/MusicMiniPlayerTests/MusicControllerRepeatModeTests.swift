import XCTest
@testable import MusicMiniPlayerCore

final class MusicControllerRepeatModeTests: XCTestCase {
    func testRepeatAllUsesMusicAppKAllValueForReadAndWrite() {
        XCTAssertEqual(AppleEventCode.repeatAll, 0x6B416C6C)
        XCTAssertEqual(AppleEventCode.songRepeatValue(for: 2), AppleEventCode.repeatAll)
        XCTAssertEqual(AppleEventCode.repeatMode(from: AppleEventCode.repeatAll), 2)
    }

    func testRepeatOneAndOffMappingsRoundTrip() {
        XCTAssertEqual(AppleEventCode.songRepeatValue(for: 1), AppleEventCode.repeatOne)
        XCTAssertEqual(AppleEventCode.repeatMode(from: AppleEventCode.repeatOne), 1)

        XCTAssertEqual(AppleEventCode.songRepeatValue(for: 0), AppleEventCode.repeatOff)
        XCTAssertEqual(AppleEventCode.repeatMode(from: AppleEventCode.repeatOff), 0)
    }
}
