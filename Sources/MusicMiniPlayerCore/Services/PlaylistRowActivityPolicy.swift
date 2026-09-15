/**
 * [INPUT]: RowArtworkVisibilityPolicy.shouldFetch (page-visibility signal),
 *          PlaybackHistoryEntry — no other module dependencies
 * [OUTPUT]: PlaylistRowContinuousAnimationPolicy (pure), PlaybackHistoryDisplayPolicy (pure)
 * [POS]: Pure-logic sub-module of Services — PlaylistView.swift/PlaylistItemRowCompact
 *        are the sole callers. Extracted so both policies are directly unit-testable
 *        without hosting SwiftUI in an NSWindow.
 * [PROTOCOL]: Changes here → update this header, then check root CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - Playlist Row Continuous Animation Policy (pure)
// ============================================================

/// 2026-09-15 CPU-regression fix (WT-D plan H postmortem, part 2 — real
/// on-device sample evidence): a playlist row's continuous animations (the
/// current-track waveform icon's `.symbolEffect(.variableColor.iterative,
/// isActive:)`) are genuinely continuous 60fps work (`-[RBLayer display]`
/// every frame on the main thread), not a one-shot transition. PlaylistView
/// never leaves the view tree (banned-patterns.md), so once History could
/// show the CURRENTLY PLAYING track (its most recent entry, by construction —
/// see PlaybackHistoryDisplayPolicy below for why that row is now filtered
/// out too, belt-and-suspenders), that row's animation ran indefinitely even
/// while the Playlist page was not on screen (Lyrics/Album showing instead).
///
/// Generalized: ANY continuous per-row animation must also require the
/// Playlist page to be the visible page — same `currentPage` signal as the
/// row-artwork-storm fix (`RowArtworkVisibilityPolicy.shouldFetch`).
public enum PlaylistRowContinuousAnimationPolicy {
    public static func isActive(isPlaying: Bool, currentPage: PlayerPage) -> Bool {
        isPlaying && RowArtworkVisibilityPolicy.shouldFetch(currentPage: currentPage)
    }
}

// ============================================================
// MARK: - Playback History Display Policy (pure)
// ============================================================

/// What the History section actually shows, given the full recorded
/// `playbackHistory` and the current track's persistentID. The store still
/// RECORDS every confirmed track change unfiltered (`PlaybackHistoryStore`,
/// `MusicController.clearPlaybackHistory()`/persistence untouched) — this is
/// a pure display-layer filter: the currently playing track already has its
/// own row on the Now Playing card, and History is "what played before."
///
/// Guarded to a non-empty `currentPersistentID`: a radio/URL track's
/// persistentID is `""`, and several PAST radio/URL history entries can
/// legitimately also carry `""` — blindly matching `"" == ""` would hide
/// those unrelated rows too, not just the current one. With no real current
/// identity, the display list is unfiltered.
public enum PlaybackHistoryDisplayPolicy {
    public static func displayed(
        history: [PlaybackHistoryEntry],
        currentPersistentID: String?
    ) -> [PlaybackHistoryEntry] {
        guard let currentID = currentPersistentID, !currentID.isEmpty else {
            return history
        }
        return history.filter { $0.persistentID != currentID }
    }
}
