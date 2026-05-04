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

## Local Entitlement Audit

- `Sources/MusicMiniPlayerApp/MusicMiniPlayer.entitlements` has App Sandbox enabled, network client access for MusicKit/Apple Music API, Apple Events automation enabled, and the temporary Apple Events target scoped to `com.apple.Music`.
- `Sources/MusicMiniPlayerApp/Info.plist` includes `NSAppleMusicUsageDescription` and `NSAppleEventsUsageDescription`.
- App Store Connect sandbox information should explain the temporary Apple Events exception narrowly: nanoPod uses it to control and mirror the user's visible Music.app playback session on macOS, including playback controls, current-track state, artwork, and live queue display. It is not used for private storage access, hidden scraping, or unrelated library profiling.

Current local implementation check:

- `MusicController+Playback.fetchRecentHistoryViaBridge()` prefers the documented Apple Music API recent-track endpoint when `MusicAuthorization.currentStatus == .authorized`.
- `fetchRecentHistoryViaAppleMusicAPI()` uses `MusicDataRequest` against `/v1/me/recent/played/tracks?types=songs,library-songs&limit=10`.
- Apple Music API recent-history rows with `am:` IDs now use MusicKit playback through `ApplicationMusicPlayer`, because `SystemMusicPlayer` is unavailable on macOS. Local Music.app rows still use the existing Music.app persistent-ID AppleScript path.
- `fetchUpNextViaBridge()` remains ScriptingBridge-backed, bounded to 2 tracks off the playlist page and 10 tracks on the playlist page.
- `preloadNearbyAssets(from:)` waits for track-generation stability before starting nearby artwork/lyrics preloads.

## Review Fallback Plan

If Apple rejects or questions live Music.app queue mirroring:

1. Keep Apple Music API recent history enabled because it is documented, user-authorized, and already separate from live queue mirroring.
2. Gate live Up Next behind the Music.app automation permission and review notes. If review still objects, hide live Up Next for App Store builds.
3. Offer a degraded Up Next mode only for queues nanoPod creates or controls through MusicKit/SystemMusicPlayer, because those queues are inside the documented MusicKit player model.
4. Keep artwork/metadata preloading for documented Apple Music API and MusicKit results; do not add private API, database inspection, accessibility scraping, or reverse-engineered queue reads to recover the hidden live queue.

## Sources Reviewed

- Apple Music API overview: https://developer.apple.com/documentation/AppleMusicAPI
- Get Recently Played Resources: https://developer.apple.com/documentation/applemusicapi/get-recently-played-resources
- Get Recently Played Tracks: https://developer.apple.com/documentation/applemusicapi/get-v1-me-recent-played-tracks
- User Authentication for MusicKit: https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit
- MusicKit `MusicPlayer.Queue.currentEntry`: https://developer.apple.com/documentation/musickit/musicplayer/queue/currententry
- Requesting access to Apple Music library: https://developer.apple.com/documentation/storekit/requesting-access-to-apple-music-library
