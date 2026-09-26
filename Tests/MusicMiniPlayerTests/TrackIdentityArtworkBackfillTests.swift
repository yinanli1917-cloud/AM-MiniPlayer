/**
 * [INPUT]: MusicController (preview) — hasAppliedRealArtwork/backfillArtworkCacheIfCurrent
 * [OUTPUT]: Regression pins for the 2026-09-26 History-row-wrong-artwork fix
 *           (founder report: research/evidence/2026-09-26-history-order-and-artwork.webp —
 *           "Close 2 U" showed "Roses"'s cover in the History list)
 * [POS]: Tests/ — MusicController+Artwork.swift's `backfillArtworkCacheIfCurrent` is the
 *        sole production caller (MusicController.swift's `handleTrackChange`, inside the
 *        ScriptingBridge-resolved-persistentID completion closure). These tests call it
 *        directly — no ScriptingBridge/network needed, since both the bug and its fix
 *        live entirely in NSCache + a handful of @Published/plain properties
 *        (`currentArtwork`, `appliedArtworkGeneration`, `currentArtworkIsPlaceholder`,
 *        `artworkFetchGeneration`) that `hasAppliedRealArtwork(for:)` already reads.
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import XCTest
import AppKit
@testable import MusicMiniPlayerCore

final class TrackIdentityArtworkBackfillTests: XCTestCase {

    private func tinyImage() -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4))
    }

    // MARK: - The bug: a RETAINED previous track's cover must not be cached under the NEW track's PID

    /// Reproduces the founder's report exactly. `fetchArtwork`'s
    /// `heldPreviousArtwork` path deliberately keeps the OLD track's real
    /// cover on screen (not a placeholder) while the NEW track's own cover
    /// is still in flight, to avoid a visible flash — so
    /// `appliedArtworkGeneration` still holds the OLD generation number at
    /// that moment. If ScriptingBridge resolves the NEW track's
    /// persistentID (up to 1.5s later, `handleTrackChange`) before the new
    /// cover itself arrives, the backfill must NOT cache the retained
    /// wrong-song image under the new track's persistentID — that is
    /// exactly how "Close 2 U" ended up displaying "Roses"'s artwork in
    /// History.
    func test_retainedPreviousTrackArtwork_notCachedUnderNewPersistentID() {
        let controller = MusicController(preview: true)
        let previousTrackCover = tinyImage()

        controller.artworkFetchGeneration = 5           // this SB read belongs to track-change event #5
        controller.appliedArtworkGeneration = 4          // ...but the on-screen artwork was applied for #4 (the OLD track)
        controller.currentArtworkIsPlaceholder = false   // it's a real image (heldPreviousArtwork path), not the placeholder
        controller.currentArtwork = previousTrackCover

        controller.backfillArtworkCacheIfCurrent(persistentID: "NEW_TRACK_PID", generation: 5)

        XCTAssertNil(
            controller.artworkCache.object(forKey: "NEW_TRACK_PID" as NSString),
            "the OLD track's retained cover must not be cached under the NEW track's persistentID"
        )
        XCTAssertNil(
            controller.getCachedArtwork(persistentID: "NEW_TRACK_PID"),
            "a later History/Up Next row asking for this persistentID's cover — the exact read path (RowArtworkStore's memory tier / getCachedArtwork) the founder's screenshot exposed — must not receive the wrong song's image"
        )
    }

    /// The placeholder variant of the same race: `fetchArtwork`'s
    /// non-retaining branch shows the music-note placeholder for the SAME
    /// generation being resolved here (cache miss, nothing to hold onto). A
    /// placeholder must never be cached as if it were a real cover, even
    /// though the generation matches.
    func test_placeholderArtwork_evenForMatchingGeneration_notCached() {
        let controller = MusicController(preview: true)

        controller.artworkFetchGeneration = 5
        controller.appliedArtworkGeneration = 5          // generation matches...
        controller.currentArtworkIsPlaceholder = true    // ...but it's the placeholder, not a real cover
        controller.currentArtwork = controller.createPlaceholder()

        controller.backfillArtworkCacheIfCurrent(persistentID: "NEW_TRACK_PID", generation: 5)

        XCTAssertNil(controller.artworkCache.object(forKey: "NEW_TRACK_PID" as NSString))
    }

    /// A stale SB completion for an OLD generation (superseded by a later
    /// track change before this closure ran) must not backfill either, even
    /// if by coincidence `appliedArtworkGeneration` also lags behind to the
    /// same old number — `artworkFetchGeneration` (the CURRENT generation)
    /// has already moved on, so this whole callback is for a track the user
    /// isn't even on anymore.
    func test_generationSuperseded_notCached() {
        let controller = MusicController(preview: true)

        controller.artworkFetchGeneration = 7   // a THIRD track change has already happened
        controller.appliedArtworkGeneration = 5 // matches the (stale) generation this callback is for
        controller.currentArtworkIsPlaceholder = false
        controller.currentArtwork = tinyImage()

        controller.backfillArtworkCacheIfCurrent(persistentID: "STALE_PID", generation: 5)

        XCTAssertNil(controller.artworkCache.object(forKey: "STALE_PID" as NSString))
    }

    // MARK: - The legitimate case: genuinely-applied artwork for THIS generation still backfills

    func test_artworkAppliedForThisGeneration_isCached() {
        let controller = MusicController(preview: true)
        let newTrackCover = tinyImage()

        controller.artworkFetchGeneration = 5
        controller.appliedArtworkGeneration = 5   // genuinely applied FOR this exact track-change event
        controller.currentArtworkIsPlaceholder = false
        controller.currentArtwork = newTrackCover

        controller.backfillArtworkCacheIfCurrent(persistentID: "NEW_TRACK_PID", generation: 5)

        XCTAssertIdentical(
            controller.artworkCache.object(forKey: "NEW_TRACK_PID" as NSString), newTrackCover,
            "artwork proven to belong to this generation must still backfill — the fix must not regress the legitimate/common case"
        )
    }

    // MARK: - Pre-existing guard rails, unchanged by this fix

    func test_emptyPersistentID_neverCached() {
        let controller = MusicController(preview: true)
        controller.artworkFetchGeneration = 1
        controller.appliedArtworkGeneration = 1
        controller.currentArtworkIsPlaceholder = false
        controller.currentArtwork = tinyImage()

        controller.backfillArtworkCacheIfCurrent(persistentID: "", generation: 1)

        XCTAssertNil(controller.artworkCache.object(forKey: "" as NSString))
    }

    func test_alreadyOccupiedKey_notOverwritten() {
        let controller = MusicController(preview: true)
        let original = tinyImage()
        let candidate = tinyImage()
        controller.artworkCache.setObject(original, forKey: "PID" as NSString, cost: 64)

        controller.artworkFetchGeneration = 1
        controller.appliedArtworkGeneration = 1
        controller.currentArtworkIsPlaceholder = false
        controller.currentArtwork = candidate

        controller.backfillArtworkCacheIfCurrent(persistentID: "PID", generation: 1)

        XCTAssertIdentical(controller.artworkCache.object(forKey: "PID" as NSString), original, "an existing cache entry must not be clobbered")
    }

    func test_noCurrentArtwork_doesNotCrash_nothingCached() {
        let controller = MusicController(preview: true)
        controller.artworkFetchGeneration = 1
        controller.appliedArtworkGeneration = 1
        controller.currentArtworkIsPlaceholder = false
        controller.currentArtwork = nil

        controller.backfillArtworkCacheIfCurrent(persistentID: "PID", generation: 1)

        XCTAssertNil(controller.artworkCache.object(forKey: "PID" as NSString))
    }
}
