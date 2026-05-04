# Apple Music Access Compliance Notes

Last reviewed: 2026-05-04

## Current Finding

nanoPod has two different data needs:

1. Current playback state and the live Up Next queue from the user's Music.app session.
2. Library/catalog/recently played Apple Music data that can be requested with user authorization.

Apple's public MusicKit and Apple Music API surface supports user-authorized catalog, library, playlist, and recently played requests. The documented recent endpoints include `GET /v1/me/recent/played` for recently played resources and `GET /v1/me/recent/played/tracks` for recently played tracks; both require a music user token. MusicKit player queues expose queues that the app creates or controls, but the reviewed docs do not expose a supported API for reading another app's existing live Music.app Up Next queue.

2026-05-03 refresh against current Apple docs/guidelines confirmed the same boundary: Apple documents recently played resources/tracks under Apple Music API history, and documents MusicKit queue/current-entry APIs for a `MusicPlayer` queue, but does not document a public API for importing Music.app's already-existing live Up Next queue from another process.

2026-05-04 refresh against current Apple Developer pages confirmed no change to that boundary. Apple Music API still documents recently played tracks/resources and MusicKit still documents `MusicPlayer.Queue` for queues owned or controlled by a MusicKit player. No reviewed public document exposes a supported API for reading Music.app's existing live Up Next queue from another process.

## Compliance Architecture Matrix

| Need | Preferred compliant source | Current nanoPod path | Compliance note |
|---|---|---|---|
| Recently played history | Apple Music API `GET /v1/me/recent/played/tracks` with a Music User Token | `fetchRecentHistoryViaAppleMusicAPI()` first when MusicKit authorization is available; ScriptingBridge fallback if unavailable or empty | This is documented Apple Music user data. It may lag or differ from local Music.app queue history, so label it as account recent history when sourced this way. |
| Live Music.app Up Next | No reviewed Apple Music API endpoint for another process's existing Music.app Up Next queue | ScriptingBridge reads `currentPlaylist`, `currentTrack`, and nearby `tracks` with timeout/generation guards | Keep this macOS-only, user-visible, permission-gated, and narrowly explained in App Review notes. Do not scrape private Music databases or accessibility UI. |
| Queue created by nanoPod | MusicKit `SystemMusicPlayer`/`ApplicationMusicPlayer` queue | Not the main current feature; fallback option if live queue mirroring is rejected | This is the cleanest App Store fallback: show Up Next only for queues nanoPod owns or controls through MusicKit. |
| Artwork for visible/current/nearby items | MusicKit / Apple Music API metadata where possible; Music.app automation only for the active session | MusicKit artwork lookup plus ScriptingBridge current-track artwork | App Review guideline 4.5.2 allows metadata only in connection with music playback or playlists. Do not reuse artwork for marketing without rights authorization. |
| Lyrics preloading for nearby queue/history | Use the same source-specific lyrics pipeline after a stable track generation | `preloadNearbyAssets(from:)` waits for generation stability before artwork/lyrics work | Preloading is allowed as app functionality, but must stay bounded and cancellable so transient rapid skips do not trigger broad background profiling. |

## App Store-Safe Direction

- Prefer MusicKit or Apple Music API for any data Apple exposes publicly: catalog metadata, artwork, library playlists, and recently played resources.
- Keep Music.app automation limited to macOS-only live playback features that have no public MusicKit equivalent, especially mirroring the existing Up Next queue.
- Request and explain `NSAppleMusicUsageDescription` for library/media access.
- Request Apple Events automation only for controlling or mirroring the user's active Music.app session, not for unrelated library profiling.
- Avoid private frameworks, private selectors, injected accessibility scraping, or reverse-engineered Music.app storage.
- App Store review notes should disclose why Apple Music and Apple Events access are requested: Apple Music for library/catalog/recent history metadata, Apple Events for user-visible control/mirroring of the active Music.app session on macOS.

## Implementation Implications

- Recent history should prefer Apple Music API where possible. `GET /v1/me/recent/played/tracks?types=songs,library-songs&limit=10` is user-authorized, documented, and now used when MusicKit authorization is available. It returns Apple Music account history, not necessarily the exact local queue history before the current item, so the ScriptingBridge path remains as a fallback.
- Live Up Next can remain ScriptingBridge-backed on macOS for now because it mirrors Music.app state that MusicKit does not publicly expose. The implementation should minimize scans, coalesce refreshes, bound list size when the playlist page is hidden, and avoid background profiling behavior.
- MusicKit `SystemMusicPlayer` is not a drop-in replacement for reading the existing Music.app queue. Apple documents that it assumes some shared Music.app state such as repeat/shuffle/playback status, but it does not state that it exposes every existing Music.app Up Next item. Treat MusicKit player queues as reliable for queues nanoPod creates or controls, not as proof that arbitrary Music.app queue mirroring is available.
- App Store review notes should distinguish these two modes plainly: Apple Music permission covers catalog/library/recent history metadata and artwork; Apple Events permission covers macOS-only control/mirroring of the user's visible Music.app session when public MusicKit APIs do not expose that session data.
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
- Apple Music API History collection: https://developer.apple.com/documentation/applemusicapi/history
- Get Recently Played Resources: https://developer.apple.com/documentation/applemusicapi/get-recently-played-resources
- Get Recently Played Tracks: https://developer.apple.com/documentation/applemusicapi/get-v1-me-recent-played-tracks
- User Authentication for MusicKit: https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit
- MusicKit `MusicPlayer.Queue.currentEntry`: https://developer.apple.com/documentation/musickit/musicplayer/queue/currententry
- MusicKit `MusicPlayer.Queue`: https://developer.apple.com/documentation/musickit/musicplayer/queue
- MusicKit `SystemMusicPlayer`: https://developer.apple.com/documentation/musickit/systemmusicplayer
- MusicKit `ApplicationMusicPlayer.Queue`: https://developer.apple.com/documentation/musickit/applicationmusicplayer/queue-swift.class
- ScriptingBridge `SBApplication`: https://developer.apple.com/documentation/scriptingbridge/sbapplication
- App Review Guidelines, Apple Music/User Data notes: https://developer.apple.com/app-store/review/guidelines/
- App Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
- Requesting access to Apple Music library: https://developer.apple.com/documentation/storekit/requesting-access-to-apple-music-library
