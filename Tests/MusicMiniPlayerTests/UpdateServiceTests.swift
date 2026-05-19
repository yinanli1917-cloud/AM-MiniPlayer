import XCTest
@testable import MusicMiniPlayerCore

final class UpdateServiceTests: XCTestCase {
    func testNormalizeStripsLeadingV() {
        XCTAssertEqual(UpdateService.normalize("v2.0.0"), "2.0.0")
        XCTAssertEqual(UpdateService.normalize("V2.1"), "2.1")
        XCTAssertEqual(UpdateService.normalize("2.0"), "2.0")
        XCTAssertEqual(UpdateService.normalize("  v1.2.3  "), "1.2.3")
    }

    func testIsNewerBasic() {
        XCTAssertTrue(UpdateService.isNewer(remote: "2.1.0", installed: "2.0.0"))
        XCTAssertTrue(UpdateService.isNewer(remote: "2.1", installed: "2.0"))
        XCTAssertTrue(UpdateService.isNewer(remote: "3.0", installed: "2.9.9"))
    }

    func testIsNewerSameVersion() {
        XCTAssertFalse(UpdateService.isNewer(remote: "2.0.0", installed: "2.0.0"))
        XCTAssertFalse(
            UpdateService.isNewer(remote: "2.0", installed: "2.0.0"),
            "'2.0' must not be considered newer than '2.0.0' (pad with zeros)"
        )
    }

    func testIsNewerOlder() {
        XCTAssertFalse(UpdateService.isNewer(remote: "1.9.9", installed: "2.0.0"))
        XCTAssertFalse(UpdateService.isNewer(remote: "1.0", installed: "2.0"))
    }

    func testIsNewerZeroPaddingSemantics() {
        XCTAssertFalse(UpdateService.isNewer(remote: "2.0.0", installed: "2.0"))
        XCTAssertTrue(UpdateService.isNewer(remote: "2.0.1", installed: "2.0"))
    }

    func testLocalDeveloperBuildDisablesAutoUpdates() {
        XCTAssertTrue(UpdateService.autoUpdatesDisabled(info: ["NPLocalDeveloperBuild": true], environment: [:]))
    }

    func testExplicitInfoFlagDisablesAutoUpdates() {
        XCTAssertTrue(UpdateService.autoUpdatesDisabled(info: ["NPDisableAutoUpdate": true], environment: [:]))
        XCTAssertTrue(UpdateService.autoUpdatesDisabled(info: ["NPDisableAutoUpdate": "true"], environment: [:]))
    }

    func testEnvironmentFlagDisablesAutoUpdates() {
        XCTAssertTrue(UpdateService.autoUpdatesDisabled(info: [:], environment: ["NANOPOD_DISABLE_AUTO_UPDATE": "1"]))
    }

    func testAutoUpdatesRemainEnabledForNormalBundles() {
        XCTAssertFalse(UpdateService.autoUpdatesDisabled(info: [:], environment: [:]))
    }
}
