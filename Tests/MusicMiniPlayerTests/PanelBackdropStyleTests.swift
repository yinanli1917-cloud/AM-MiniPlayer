/**
 * [INPUT]: MusicMiniPlayerCore PanelBackdropStyle
 * [OUTPUT]: Unit tests for the panel backdrop style switch (fluid vs glass experiment)
 *           and the glassOpacity(style:isAlbumPageNonFullscreen:) pure helper
 * [POS]: Test module. Pins the defaults-key contract: unknown/absent values must
 *        fall back to the shipping fluid backdrop so the experiment can never
 *        change the default look by accident. Also pins the founder 2026-09-25
 *        scoping decision: glass/clear only show on the non-fullscreen album page.
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
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "clear"), .clear)
        XCTAssertEqual(PanelBackdropStyle.resolve(from: "CLEAR"), .clear)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - glassOpacity: glass/clear scoped to the non-fullscreen album page
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_glassOpacity_fluidStyle_neverShowsGlass() {
        XCTAssertEqual(PanelBackdropStyle.glassOpacity(style: .fluid, isAlbumPageNonFullscreen: true), 0)
        XCTAssertEqual(PanelBackdropStyle.glassOpacity(style: .fluid, isAlbumPageNonFullscreen: false), 0)
    }

    func test_glassOpacity_glassAndClear_onlyOnNonFullscreenAlbumPage() {
        XCTAssertEqual(PanelBackdropStyle.glassOpacity(style: .glass, isAlbumPageNonFullscreen: true), 1)
        XCTAssertEqual(PanelBackdropStyle.glassOpacity(style: .glass, isAlbumPageNonFullscreen: false), 0)
        XCTAssertEqual(PanelBackdropStyle.glassOpacity(style: .clear, isAlbumPageNonFullscreen: true), 1)
        XCTAssertEqual(PanelBackdropStyle.glassOpacity(style: .clear, isAlbumPageNonFullscreen: false), 0)
    }
}
