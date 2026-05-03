# Apple Music Access Compliance Notes

Last reviewed: 2026-05-03

## Current Finding

nanoPod has two different data needs:

1. Current playback state and the live Up Next queue from the user's Music.app session.
2. Library/catalog/recently played Apple Music data that can be requested with user authorization.

Apple's public MusicKit and Apple Music API surface supports user-authorized catalog, library, playlist, and recently played requests. The documented recent endpoints include `GET /v1/me/recent/played` for recently played resources and `GET /v1/me/recent/played/tracks` for recently played tracks; both require a music user token. MusicKit player queues expose queues that the app creates or controls, but the reviewed docs do not expose a supported API for reading another app's existing live Music.app Up Next queue.

## App Store-Safe Direction

- Prefer MusicKit or Apple Music API for any data Apple exposes publicly: catalog metadata, artwork, library playlists, and recently played resources.
- Keep Music.app automation limited to macOS-only live playback features that have no public MusicKit equivalent, especially mirroring the existing Up Next queue.
- Request and explain `NSAppleMusicUsageDescription` for library/media access.
- Request Apple Events automation only for controlling or mirroring the user's active Music.app session, not for unrelated library profiling.
- Avoid private frameworks, private selectors, injected accessibility scraping, or reverse-engineered Music.app storage.

## Implementation Implications

- Recent history should prefer Apple Music API where possible. `GET /v1/me/recent/played/tracks?types=songs,library-songs&limit=10` is user-authorized, documented, and now used when MusicKit authorization is available. It returns Apple Music account history, not necessarily the exact local queue history before the current item, so the ScriptingBridge path remains as a fallback.
- Live Up Next can remain ScriptingBridge-backed on macOS for now because it mirrors Music.app state that MusicKit does not publicly expose. The implementation should minimize scans, coalesce refreshes, and avoid background profiling behavior.
- If App Review objects to queue mirroring, the fallback is to show Up Next only for queues created by nanoPod through MusicKit/SystemMusicPlayer and hide or degrade the live Music.app queue feature.

## Sources Reviewed

- Apple Music API overview: https://developer.apple.com/documentation/AppleMusicAPI
- Get Recently Played Resources: https://developer.apple.com/documentation/applemusicapi/get-recently-played-resources
- Get Recently Played Tracks: https://developer.apple.com/documentation/applemusicapi/get-v1-me-recent-played-tracks
- User Authentication for MusicKit: https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit
- MusicKit `MusicPlayer.Queue.currentEntry`: https://developer.apple.com/documentation/musickit/musicplayer/queue/currententry
- Requesting access to Apple Music library: https://developer.apple.com/documentation/storekit/requesting-access-to-apple-music-library
