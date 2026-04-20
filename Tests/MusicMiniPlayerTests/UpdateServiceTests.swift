// ──────────────────────────────────────────────
// UpdateServiceTests — version parsing + semver-ish comparison.
// The network-bound path is verified by LyricsVerifier in a separate
// "scripts/check_update.swift" smoke run, not here.
// ──────────────────────────────────────────────

import XCTest
@testable import MusicMiniPlayerCore

final class UpdateServiceTests: XCTestCase {

    // MARK: - normalize

    func testNormalizeStripsLeadingV() {
        XCTAssertEqual(UpdateService.normalize("v2.0.0"), "2.0.0")
        XCTAssertEqual(UpdateService.normalize("V2.1"), "2.1")
        XCTAssertEqual(UpdateService.normalize("2.0"), "2.0")
        XCTAssertEqual(UpdateService.normalize("  v1.2.3  "), "1.2.3")
    }

    // MARK: - isNewer

    func testIsNewerBasic() {
        XCTAssertTrue(UpdateService.isNewer(remote: "2.1.0", installed: "2.0.0"))
        XCTAssertTrue(UpdateService.isNewer(remote: "2.1", installed: "2.0"))
        XCTAssertTrue(UpdateService.isNewer(remote: "3.0", installed: "2.9.9"))
    }

    func testIsNewerSameVersion() {
        XCTAssertFalse(UpdateService.isNewer(remote: "2.0.0", installed: "2.0.0"))
        XCTAssertFalse(UpdateService.isNewer(remote: "2.0", installed: "2.0.0"),
                       "'2.0' must not be considered newer than '2.0.0' (pad with zeros)")
    }

    func testIsNewerOlder() {
        XCTAssertFalse(UpdateService.isNewer(remote: "1.9.9", installed: "2.0.0"))
        XCTAssertFalse(UpdateService.isNewer(remote: "1.0", installed: "2.0"))
    }

    func testIsNewerZeroPaddingSemantics() {
        // "2.0.0" vs "2.0" — installed is missing patch component, treated as 0
        XCTAssertFalse(UpdateService.isNewer(remote: "2.0.0", installed: "2.0"))
        // "2.0.1" vs "2.0" — patch bump IS newer
        XCTAssertTrue(UpdateService.isNewer(remote: "2.0.1", installed: "2.0"))
    }
}
