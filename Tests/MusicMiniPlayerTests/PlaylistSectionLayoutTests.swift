/**
 * [INPUT]: MusicMiniPlayerCore PlaylistStickyHeaderPolicy
 * [OUTPUT]: Unit tests for the global sticky-header show/hide decision
 * [POS]: Pins the founder-reported overlap (History title over "No recent
 *        tracks"): at rest, a section's minY is already ~0, so `minY <= 0`
 *        used to fire immediately; the inline header must be FULLY scrolled
 *        off (minY <= -headerHeight) before the fixed duplicate appears.
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PlaylistSectionLayoutTests: XCTestCase {

    func test_atRestPosition_stickyHeaderHidden() {
        // Natural top-of-scroll position: minY == 0, short empty-state body.
        XCTAssertFalse(PlaylistStickyHeaderPolicy.shouldShow(minY: 0, maxY: 92, headerHeight: 32))
    }

    func test_headerPartiallyScrolled_stillHidden() {
        // Header has started moving but hasn't fully cleared the viewport.
        XCTAssertFalse(PlaylistStickyHeaderPolicy.shouldShow(minY: -10, maxY: 82, headerHeight: 32))
    }

    func test_headerFullyScrolledOff_withContentRemaining_shows() {
        XCTAssertTrue(PlaylistStickyHeaderPolicy.shouldShow(minY: -32, maxY: 300, headerHeight: 32))
    }

    func test_sectionNoTallerThanHeader_neverTriggersSticky() {
        // A section whose total height is <= headerHeight (nothing follows
        // the header) can never satisfy both bounds at once.
        XCTAssertFalse(PlaylistStickyHeaderPolicy.shouldShow(minY: -32, maxY: 32, headerHeight: 32))
    }

    func test_sectionFullyScrolledPast_hidden() {
        XCTAssertFalse(PlaylistStickyHeaderPolicy.shouldShow(minY: -400, maxY: -20, headerHeight: 32))
    }
}
