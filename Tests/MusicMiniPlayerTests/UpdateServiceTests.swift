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

    func testUpdateSequenceReadsInfoPlistValues() {
        XCTAssertEqual(UpdateService.updateSequence(from: ["NPUpdateSequence": 28]), 28)
        XCTAssertEqual(UpdateService.updateSequence(from: ["NPUpdateSequence": NSNumber(value: 29)]), 29)
        XCTAssertEqual(UpdateService.updateSequence(from: ["NPUpdateSequence": "30"]), 30)
        XCTAssertNil(UpdateService.updateSequence(from: [:]))
    }

    func testReleaseBodyUpdateSequenceBridgesFromV2TagToBetaVersion() {
        let body = """
        ## Release
        UpdateSequence: 28
        DisplayVersion: 0.28 beta
        """

        XCTAssertEqual(UpdateService.releaseUpdateSequence(tagName: "v2.8", body: body), 28)
        XCTAssertFalse(
            UpdateService.shouldUpdate(
                remoteTag: "v2.8",
                remoteBody: body,
                installedVersion: "0.28",
                installedUpdateSequence: 28
            ),
            "The 0.28 bridge app must not repeatedly stage the v2.8 bridge release."
        )
        XCTAssertTrue(
            UpdateService.shouldUpdate(
                remoteTag: "v2.8",
                remoteBody: body,
                installedVersion: "2.7",
                installedUpdateSequence: nil
            ),
            "Existing 2.7 installs still need the v2.8 tag to trigger the bridge update."
        )
    }

    func testZeroDotBetaTagsDeriveUpdateSequence() {
        XCTAssertEqual(UpdateService.releaseUpdateSequence(tagName: "v0.29", body: nil), 29)
        XCTAssertTrue(
            UpdateService.shouldUpdate(
                remoteTag: "v0.29",
                remoteBody: nil,
                installedVersion: "0.28",
                installedUpdateSequence: 28
            )
        )
        XCTAssertFalse(
            UpdateService.shouldUpdate(
                remoteTag: "v0.29",
                remoteBody: nil,
                installedVersion: "0.29",
                installedUpdateSequence: 29
            )
        )
    }
}
