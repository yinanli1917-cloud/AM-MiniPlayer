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
/// `playbackHistory` and the currently-playing identity. The store still
/// RECORDS every qualified track play unfiltered (`PlaybackHistoryStore`,
/// `MusicController.clearPlaybackHistory()`/persistence untouched) — this is
/// a pure display-layer filter: the currently playing track already has its
/// own row on the Now Playing card, and History is "what played before."
///
/// 2026-09-25 diagnosis fix (H1): the old rule filtered EVERY entry whose
/// persistentID matched the current track, not just the row that duplicates
/// the Now Playing card — an A→B→A repeat listen made the earlier, already-
/// finished play of A vanish from History too. Since PendingPlaybackAccumulator
/// (PendingPlaybackAccumulator.swift) now only inserts a row once a play
/// QUALIFIES, "the row for THIS play" is structurally always `history.first`
/// (the newest entry) when it IS the currently-playing identity — so only
/// `history.first` is ever considered, never a broad PID-wide filter.
///
/// PID is authoritative when both sides have one (mirrors
/// `MusicController.notificationIndicatesTrackChange`'s own rule); otherwise
/// falls back to title+artist — a radio/URL track's persistentID is `""`,
/// and several PAST radio/URL history entries can legitimately also carry
/// `""`, so blind `"" == ""` PID matching would hide unrelated rows too.
public enum PlaybackHistoryDisplayPolicy {
    public static func displayed(
        history: [PlaybackHistoryEntry],
        currentTitle: String,
        currentArtist: String,
        currentPersistentID: String?
    ) -> [PlaybackHistoryEntry] {
        guard let first = history.first else { return history }

        let isCurrentPlay: Bool
        if let currentID = currentPersistentID, !currentID.isEmpty, !first.persistentID.isEmpty {
            isCurrentPlay = first.persistentID == currentID
        } else {
            isCurrentPlay = first.title == currentTitle && first.artist == currentArtist
        }

        guard isCurrentPlay else { return history }
        return Array(history.dropFirst())
    }

    /// 2026-09-26 founder ruling (research/evidence/2026-09-26-history-order-and-
    /// artwork.webp): the History section must read top-to-bottom OLDEST→NEWEST,
    /// matching Music.app's own History list — the row for the most recently
    /// finished play sits immediately above the Now Playing card, because
    /// PlaylistView renders the History section directly above Now Playing in
    /// its ScrollView (`PlaylistView.swift`, `historySection` then
    /// `nowPlayingSection`). Before this fix, `displayed(...)`'s newest-first
    /// order (mirroring the store's own insertion order, `history.first` ==
    /// newest) was rendered as-is, so the OLDEST visible row ended up adjacent
    /// to Now Playing and the newest sat at the top, farthest away — backwards.
    ///
    /// Kept as a SEPARATE pure step (not folded into `displayed` above) so
    /// `displayed`'s existing filter contract — and every test pinned to its
    /// newest-first return order — is untouched; only the final on-screen
    /// ordering changes. `PlaylistView` composes them:
    /// `chronological(displayed(...))`.
    public static func chronological(_ entries: [PlaybackHistoryEntry]) -> [PlaybackHistoryEntry] {
        entries.reversed()
    }
}
