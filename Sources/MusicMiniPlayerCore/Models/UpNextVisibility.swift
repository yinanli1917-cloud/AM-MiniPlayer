/**
 * [INPUT]: MusicQueueProvenance
 * [OUTPUT]: UpNextVisibility — pure decision of whether the whole Up Next
 *           section may render at all
 * [POS]: Models — PlaylistView.swift consumes `.decide(provenance:shuffleEnabled:)`
 *        to gate the entire Up Next PlaylistSection (WT-D plan H3, founder
 *        ruling 2026-09-13)
 *
 * Founder ruling 2026-09-13: Up Next is shown ONLY when it is provably exact
 * — playing from a library playlist (user or subscription playlist, i.e.
 * `queueProvenance` is the playlist-context case) AND shuffle is off.
 * Otherwise the whole section is hidden and one fixed explanatory line is
 * shown instead (not flickering in/out).
 */

import Foundation

public enum UpNextVisibility: Equatable {
    case shown
    case hidden(reason: HiddenReason)

    public enum HiddenReason: Equatable {
        /// Playing from a library playlist, but shuffle is on — order is no
        /// longer provably exact.
        case shuffle
        /// Not playing from a library playlist context at all (radio, Apple
        /// Music catalog stream, unavailable, pending refresh, etc.) — no
        /// exact queue exists to show.
        case sourceHasNoQueue
    }

    public static func decide(provenance: MusicQueueProvenance, shuffleEnabled: Bool) -> UpNextVisibility {
        switch provenance {
        case .playlistContextOnly, .preview:
            return shuffleEnabled ? .hidden(reason: .shuffle) : .shown
        case .exactPublicMusicQueue, .appleMusicAccountRecentlyPlayed, .unavailable:
            return .hidden(reason: .sourceHasNoQueue)
        }
    }
}
