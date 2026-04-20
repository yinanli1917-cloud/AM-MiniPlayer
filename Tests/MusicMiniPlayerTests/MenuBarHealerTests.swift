// ──────────────────────────────────────────────
// MenuBarHealerTests — verifies the ControlCenter plist cleaning logic
// without touching the user's real system plist.
// ──────────────────────────────────────────────

import XCTest
@testable import MusicMiniPlayerCore

final class MenuBarHealerTests: XCTestCase {

    // MARK: - Helpers

    private func header(_ bundleID: String) -> [String: Any] {
        return ["bundle": ["_0": bundleID]]
    }

    private func location(isAllowed: Bool = true, locations: [[String: Any]] = []) -> [String: Any] {
        return [
            "location": ["_0": "menuBar"],
            "isAllowed": isAllowed,
            "menuItemLocations": locations
        ]
    }

    // MARK: - Cases

    /// Clean database with no stale references → unchanged.
    func testCleanDatabaseIsUntouched() {
        let entries: [[String: Any]] = [
            header("com.yinanli.nanoPod"),
            location(),
            header("com.apple.controlcenter.Bluetooth"),
            location()
        ]
        let (cleaned, changed) = MenuBarHealer._cleanForTests(entries: entries)
        XCTAssertFalse(changed, "Clean DB must not be modified")
        XCTAssertEqual(cleaned.count, 4)
    }

    /// Stale MusicMiniPlayer header+location pair → removed, changed=true.
    func testStaleMusicMiniPlayerPairIsRemoved() {
        let entries: [[String: Any]] = [
            header("com.yinanli.MusicMiniPlayer"),
            location(),
            header("com.yinanli.nanoPod"),
            location(),
            header("com.apple.controlcenter.Bluetooth"),
            location()
        ]
        let (cleaned, changed) = MenuBarHealer._cleanForTests(entries: entries)
        XCTAssertTrue(changed)
        XCTAssertEqual(cleaned.count, 4, "Stale pair (2 entries) removed")

        let ids = cleaned.compactMap { ($0["bundle"] as? [String: Any])?["_0"] as? String }
        XCTAssertFalse(ids.contains { $0.contains("MusicMiniPlayer") })
        XCTAssertTrue(ids.contains("com.yinanli.nanoPod"))
    }

    /// Cross-contamination: another app's menuItemLocations references stale ID.
    func testCrossContaminationInMenuItemLocationsIsStripped() {
        let contaminated: [String: Any] = [
            "bundle": ["_0": "com.apple.controlcenter.Bluetooth"],
            "menuItemLocations": [
                ["bundle": ["_0": "com.yinanli.MusicMiniPlayer"]],
                ["bundle": ["_0": "com.apple.controlcenter.Bluetooth"]]
            ]
        ]
        let entries: [[String: Any]] = [contaminated]
        let (cleaned, changed) = MenuBarHealer._cleanForTests(entries: entries)
        XCTAssertTrue(changed)

        let locs = cleaned[0]["menuItemLocations"] as? [[String: Any]] ?? []
        XCTAssertEqual(locs.count, 1)
        let remainingID = (locs[0]["bundle"] as? [String: Any])?["_0"] as? String
        XCTAssertEqual(remainingID, "com.apple.controlcenter.Bluetooth")
    }

    /// Own bundle ID must NEVER be treated as stale (would force re-registration
    /// on every launch and be jarring).
    func testOwnBundleIDIsPreserved() {
        let entries: [[String: Any]] = [
            header("com.yinanli.nanoPod"),
            location()
        ]
        let (_, changed) = MenuBarHealer._cleanForTests(entries: entries)
        XCTAssertFalse(changed, "nanoPod's own entry must not be stripped")
    }

    /// Idempotency: running clean twice yields the same result.
    func testIdempotent() {
        let entries: [[String: Any]] = [
            header("com.yinanli.MusicMiniPlayer"),
            location(),
            header("com.yinanli.nanoPod"),
            location()
        ]
        let (first, firstChanged) = MenuBarHealer._cleanForTests(entries: entries)
        XCTAssertTrue(firstChanged)

        let (second, secondChanged) = MenuBarHealer._cleanForTests(entries: first)
        XCTAssertFalse(secondChanged, "Second pass on cleaned data must be a no-op")
        XCTAssertEqual(first.count, second.count)
    }

    /// Empty menuItemLocations after stripping gets a self-reference fallback
    /// (mirrors fix_menubar.py behaviour — system requires non-empty array).
    func testEmptyLocationsAfterStrippingGetsSelfReferenceFallback() {
        let entry: [String: Any] = [
            "bundle": ["_0": "com.apple.controlcenter.Sound"],
            "menuItemLocations": [
                ["bundle": ["_0": "com.yinanli.MusicMiniPlayer"]]
            ]
        ]
        let (cleaned, changed) = MenuBarHealer._cleanForTests(entries: [entry])
        XCTAssertTrue(changed)
        let locs = cleaned[0]["menuItemLocations"] as? [[String: Any]] ?? []
        XCTAssertEqual(locs.count, 1, "Empty locs replaced with self-reference stub")
        let fallbackID = (locs[0]["bundle"] as? [String: Any])?["_0"] as? String
        XCTAssertEqual(fallbackID, "com.apple.controlcenter.Sound")
    }
}
