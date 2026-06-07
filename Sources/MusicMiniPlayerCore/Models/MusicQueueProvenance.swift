import Foundation

public enum MusicQueueUnavailableReason: Equatable {
    case noPublicQueueObject
    case noCurrentPlaylistForTrackClass(String)
    case publicSourceUnverified
    case musicAppUnavailable
    case noCurrentTrack
    case pendingPublicRefresh

    public var diagnosticLabel: String {
        switch self {
        case .noPublicQueueObject:
            return "unavailable.no-public-queue-object"
        case .noCurrentPlaylistForTrackClass(let trackClass):
            let normalized = trackClass.trimmingCharacters(in: .whitespacesAndNewlines)
            return "unavailable.no-current-playlist.track-class.\(normalized.isEmpty ? "unknown" : normalized)"
        case .publicSourceUnverified:
            return "unavailable.public-source-unverified"
        case .musicAppUnavailable:
            return "unavailable.music-app-unavailable"
        case .noCurrentTrack:
            return "unavailable.no-current-track"
        case .pendingPublicRefresh:
            return "unavailable.pending-public-refresh"
        }
    }

    public var unavailableDisplayMessage: String {
        switch self {
        case .noPublicQueueObject:
            return "Music.app exposes no public Up Next object."
        case .noCurrentPlaylistForTrackClass(let trackClass):
            let normalized = trackClass.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Music.app exposes no public queue for \(normalized.isEmpty ? "this" : normalized) playback."
        case .publicSourceUnverified:
            return "No public exact queue source has been verified."
        case .musicAppUnavailable:
            return "Music.app is not available."
        case .noCurrentTrack:
            return "No current Music.app track is exposed."
        case .pendingPublicRefresh:
            return "Queue changed; waiting for a verified Music.app refresh."
        }
    }
}

public enum MusicQueueProvenance: Equatable {
    case preview
    case exactPublicMusicQueue(context: String)
    case playlistContextOnly(playlistName: String?)
    case appleMusicAccountRecentlyPlayed
    case unavailable(reason: MusicQueueUnavailableReason)

    public var isExactRealTimeQueue: Bool {
        if case .exactPublicMusicQueue = self { return true }
        return false
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    public var isPlaylistContextOnly: Bool {
        if case .playlistContextOnly = self { return true }
        return false
    }

    public var canDisplayAsRealTimeQueueRows: Bool {
        switch self {
        case .exactPublicMusicQueue, .preview:
            return true
        case .playlistContextOnly, .appleMusicAccountRecentlyPlayed, .unavailable:
            return false
        }
    }

    public var diagnosticLabel: String {
        switch self {
        case .preview:
            return "preview"
        case .exactPublicMusicQueue(let context):
            let normalized = context.trimmingCharacters(in: .whitespacesAndNewlines)
            return "exact-public-music-queue.context.\(normalized.isEmpty ? "unspecified" : normalized)"
        case .playlistContextOnly(let playlistName):
            let normalized = playlistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "playlist-context-only.playlist.\(normalized.isEmpty ? "unknown" : normalized)"
        case .appleMusicAccountRecentlyPlayed:
            return "apple-music-account-recently-played"
        case .unavailable(let reason):
            return reason.diagnosticLabel
        }
    }

    public var unavailableDisplayMessage: String? {
        switch self {
        case .exactPublicMusicQueue, .preview:
            return nil
        case .playlistContextOnly(let playlistName):
            let normalized = playlistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if normalized.isEmpty {
                return "Only the containing playlist is public; Up Next has not been verified."
            }
            return "Only \"\(normalized)\" is public; Up Next has not been verified."
        case .appleMusicAccountRecentlyPlayed:
            return "Apple Music history is not the live Music.app session."
        case .unavailable(let reason):
            return reason.unavailableDisplayMessage
        }
    }
}
