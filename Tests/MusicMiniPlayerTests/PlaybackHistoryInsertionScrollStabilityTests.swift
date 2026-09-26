/**
 * [INPUT]: MusicController (preview + DEBUG seed), PlaylistView, SwiftUI/AppKit hosting
 * [OUTPUT]: Real wall-clock/on-screen measurement (not a static-reading guess) of
 *           whether the Now Playing card's on-screen position shifts when a new
 *           History entry is appended while the Playlist page is visible — the
 *           founder's 2026-09-26 History-order fix requires the newest entry to
 *           land directly above Now Playing (PlaybackHistoryDisplayPolicy.
 *           chronological). Two scenarios, two different verified outcomes:
 *           (1) the founder's ACTUAL reported/screenshotted scenario — scrolled
 *           UP into older History, away from Now Playing
 *           (research/evidence/2026-09-26-history-order-and-artwork.webp) — is
 *           SAFE, no fix needed, proven green below; (2) sitting AT the default
 *           Now-Playing anchor (the resting position right after
 *           .onAppear/page-open/track-change) DOES currently shift when a
 *           background History commit lands — measured and pinned as a KNOWN,
 *           deliberately-unaddressed limitation (see that test's own comment for
 *           why a quick fix was not attempted).
 * [POS]: Test module. Uses the SAME real-NSWindow-hosting idiom as
 *        PlaylistViewRenderChurnTests/PlaybackHistoryCapacityMeasurementTests — a
 *        detached NSHostingView never reproduces real SwiftUI/AppKit layout
 *        behavior (banned-patterns.md). Reads `PlaylistView.debugLastSectionOffsets`
 *        (test-only instrumentation added alongside the order fix): "history_maxY"
 *        is the History section's bottom edge in the "playlistScroll" coordinate
 *        space, which — since History and Now Playing are adjacent siblings with
 *        zero spacing in the same VStack (PlaylistView.body) — is exactly the Now
 *        Playing card's own top edge, with zero NEW GeometryReader/.preference
 *        plumbing needed beyond what PlaylistSection already reports for the
 *        sticky-header overlay.
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import XCTest
import SwiftUI
@testable import MusicMiniPlayerCore

#if DEBUG
@MainActor
final class PlaybackHistoryInsertionScrollStabilityTests: XCTestCase {

    private var hostWindow: NSWindow?

    override func tearDown() {
        hostWindow?.orderOut(nil)
        hostWindow = nil
        super.tearDown()
    }

    private func hostInWindow(_ view: NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 560),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
        window.orderFrontRegardless()
        hostWindow = window
    }

    private func pump(_ seconds: TimeInterval = 0.03) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// `historyCount` distinct, pre-artwork-cached entries plus a "now
    /// playing" identity that matches NONE of them (so nothing is filtered
    /// by `PlaybackHistoryDisplayPolicy.displayed`, keeping the row count —
    /// and therefore the on-screen geometry — predictable).
    private func makeController(historyCount: Int) -> MusicController {
        let controller = MusicController(preview: true)
        var entries: [PlaybackHistoryEntry] = []
        entries.reserveCapacity(historyCount)
        let tinyImage = NSImage(size: NSSize(width: 4, height: 4))
        for i in 0..<historyCount {
            let pid = "SCROLL-STABILITY-TEST-\(i)"
            entries.append(PlaybackHistoryEntry(
                persistentID: pid, title: "Song \(i)", artist: "Artist \(i % 13)", album: "Album \(i % 7)",
                duration: 180 + Double(i % 60), sourceKind: .library,
                // Oldest last (index historyCount-1 is startedAt-earliest) so
                // `entries` is already newest-first, matching the store's own
                // insertion order/contract — same shape PlaybackHistoryCapacityMeasurementTests uses.
                startedAt: Date(timeIntervalSince1970: Double(1_000_000 - i))
            ))
            controller.artworkCache.setObject(tinyImage, forKey: pid as NSString, cost: 64)
        }
        controller.debugSeedPlaybackHistoryForTesting(entries)
        controller.currentTrackTitle = "Now Playing Track"
        controller.currentArtist = "Now Playing Artist"
        controller.currentPersistentID = "NOW-PLAYING-PID" // distinct from every seeded entry
        controller.currentArtwork = tinyImage
        // Enough Up Next content to fill the viewport below Now Playing —
        // an empty/short queue would make the ScrollView bottom out BEFORE
        // reaching a true top-pinned anchor regardless of History's length
        // (nothing below Now Playing to scroll into), which would make
        // "already at the anchor" unmeasurable via `history_maxY` on its
        // own. A real, non-empty queue (the common case whenever something
        // is actually playing from one) doesn't have this degenerate shape.
        controller.upNextTracks = (0..<15).map { i in
            ("Up Next \(i)", "Artist \(i)", "Album \(i)", "UPNEXT-\(i)", 200.0)
        }
        controller.recentTracks = []
        controller.queueProvenance = .playlistContextOnly(playlistName: "Test Playlist")
        return controller
    }

    /// The default landing position after `.onAppear`/every page switch/every
    /// track change: `scrollProxy.scrollTo("nowPlayingSection", anchor: .top)`.
    /// This is the majority-of-the-time resting state (open Playlist page,
    /// glance at Now Playing/Up Next).
    ///
    /// MEASURED, NOT FIXED — a known, disclosed limitation, pinned here
    /// deliberately rather than silently left undocumented. While sitting at
    /// this anchor, a background History commit (`PendingPlaybackAccumulator`
    /// can qualify a play up to `minimumListenSecondsForHistory` INTO
    /// still-ongoing playback, not only at the next track's notification —
    /// so this is NOT gated on a track change) DOES currently push Now
    /// Playing down on screen by roughly one row's height: a plain
    /// `ScrollView` keeps its raw offset fixed, and content inserted above
    /// that offset pushes visible content down.
    ///
    /// A robust fix needs to distinguish "the user is genuinely still at the
    /// anchor" from "the user scrolled away and is reading History" — this
    /// app's own scroll-gesture detector (`ScrollDetector.swift`) is driven
    /// by real `NSEvent .scrollWheel` monitoring, not a bounds-change
    /// observer, and the natural "history_maxY ≈ 0 at the anchor" assumption
    /// does not hold in general (it settles at a fixed, content-independent
    /// value that is NOT 0 in this exact hosting configuration — verified
    /// empirically, not a hardcoded guess). Getting this right needs new,
    /// carefully-verified state-tracking machinery in a component
    /// `.claude/rules/banned-patterns.md` already documents an entire
    /// section of hard-won "PlaylistView — Verified Failures" for. The
    /// founder's ACTUAL reported/screenshotted scenario — scrolled UP into
    /// History, away from Now Playing — is proven SAFE below
    /// (`test_appendingHistoryEntry_whileScrolledIntoOlderHistory_earlierRowsDoNotShift`).
    /// This corner case is left as a follow-up rather than risking an
    /// under-verified scroll-management patch.
    func test_appendingHistoryEntry_atDefaultNowPlayingAnchor_currentlyShiftsNowPlaying_knownLimitation() {
        let controller = makeController(historyCount: 12)
        let hosting = NSHostingView(rootView: ScrollStabilityProbeHost(controller: controller))
        hostInWindow(hosting)

        // Let the initial mount + the 0.1s-deferred onAppear scrollTo(anchor: .top) settle.
        pump(0.4)

        guard let before = PlaylistView.debugLastSectionOffsets["history_maxY"] else {
            return XCTFail("history_maxY must have been reported by now — PlaylistSection's GeometryReader/.preference plumbing never fired")
        }

        // Simulate a History row committing in the background (PendingPlaybackAccumulator
        // qualifying a play well after the track itself changed, `MusicController.
        // minimumListenSecondsForHistory`) — prepend at index 0, exactly like the
        // real store's `record()`. `currentPersistentID` is untouched, so this is
        // NOT a track change — nothing re-anchors it.
        var updated = controller.playbackHistory
        updated.insert(
            PlaybackHistoryEntry(
                persistentID: "NEWLY-COMMITTED-PID", title: "Newly Committed Song", artist: "Someone",
                album: "Some Album", duration: 210, sourceKind: .library, startedAt: Date()
            ),
            at: 0
        )
        controller.debugSeedPlaybackHistoryForTesting(updated)
        pump(0.3)

        guard let after = PlaylistView.debugLastSectionOffsets["history_maxY"] else {
            return XCTFail("history_maxY must still be reported after the update")
        }

        XCTAssertGreaterThan(
            after - before, 20,
            "expected the KNOWN shift (Now Playing currently moves roughly one row's height down) — got before=\(before) after=\(after); if this now reads ~0, the underlying behavior changed and this 'known limitation' pin should be revisited/removed"
        )
    }

    /// The founder's actual reported scenario (research/evidence/2026-09-26-
    /// history-order-and-artwork.webp): scrolled UP into History, away from
    /// Now Playing. A new entry appends at the END of the (now oldest→newest)
    /// History list — i.e. immediately above Now Playing, BELOW whatever
    /// earlier rows are currently on screen — so content already visible
    /// above the insertion point must not move at all.
    func test_appendingHistoryEntry_whileScrolledIntoOlderHistory_earlierRowsDoNotShift() throws {
        let controller = makeController(historyCount: 30)
        let hosting = NSHostingView(rootView: ScrollStabilityProbeHost(controller: controller))
        hostInWindow(hosting)
        pump(0.4)

        guard let scrollView = Self.findScrollView(in: hosting) else {
            throw XCTSkip("could not locate the backing NSScrollView in the hosted view tree — SwiftUI's internal ScrollView implementation may have changed")
        }
        // Scroll to the very top of the document (oldest History rows) —
        // as far from Now Playing/the insertion point as possible.
        scrollView.documentView?.scroll(NSPoint(x: 0, y: 1_000_000))
        pump(0.15)
        let offsetBefore = scrollView.contentView.bounds.origin.y

        var updated = controller.playbackHistory
        updated.insert(
            PlaybackHistoryEntry(
                persistentID: "NEWLY-COMMITTED-PID-2", title: "Another Newly Committed Song", artist: "Someone",
                album: "Some Album", duration: 190, sourceKind: .library, startedAt: Date()
            ),
            at: 0
        )
        controller.debugSeedPlaybackHistoryForTesting(updated)
        pump(0.3)

        let offsetAfter = scrollView.contentView.bounds.origin.y
        XCTAssertEqual(
            offsetAfter, offsetBefore, accuracy: 0.5,
            "scrolled to the oldest History rows (as far as possible from the insertion point adjacent to Now Playing), the raw scroll offset moved from \(offsetBefore) to \(offsetAfter) — content the user was actually looking at shifted on screen"
        )
    }

    private static func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }
}

private struct ScrollStabilityProbeHost: View {
    @ObservedObject var controller: MusicController
    @Namespace private var namespace
    @State private var currentPage: PlayerPage = .playlist

    var body: some View {
        PlaylistView(
            currentPage: $currentPage,
            animationNamespace: namespace,
            selectedTab: .constant(1),
            showControls: .constant(true),
            isHovering: .constant(false),
            showOverlayContent: .constant(true)
        )
        .environmentObject(controller)
        .frame(width: 320, height: 560)
    }
}
#endif
