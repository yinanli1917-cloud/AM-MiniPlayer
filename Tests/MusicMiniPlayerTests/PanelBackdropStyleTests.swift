/**
 * [INPUT]: MusicMiniPlayerCore PanelBackdropStyle
 * [OUTPUT]: Unit tests for the panel backdrop style switch (fluid vs glass experiment)
 * [POS]: Test module. Pins the defaults-key contract: unknown/absent values must
 *        fall back to the shipping fluid backdrop so the experiment can never
 *        change the default look by accident.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PanelBackdropStyleTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fallback safety
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_resolve_absentValue_fallsBackToFluid() {
        XCTAssertEqual(PanelBackdropStyle.resolve(from: nil), .fluid)
    }

    func test_resolve_unknownValue_fallsBackToFluid() {
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "marble"), .fluid)
        XCTAssertEqual(PanelBackdropStyle.resolve(from: ""), .fluid)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Known styles, case-insensitive
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_resolve_knownStyles_caseInsensitive() {
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "glass"), .glass)
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "GLASS"), .glass)
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "Fluid"), .fluid)
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "fluid"), .fluid)
    }
}
