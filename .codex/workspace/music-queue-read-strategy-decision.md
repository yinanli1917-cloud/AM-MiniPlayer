# Music Queue Read Strategy Decision

Status: foundation implemented, proof-gated
Last updated: 2026-05-31

## Decision

nanoPod must not treat `currentPlaylist.tracks`, Apple Music recently played
data, MusicKit `ApplicationMusicPlayer.queue`, cached observations, or catalog
search as the real Music.app queue unless a recorded visible parity pass proves
that source matches Music.app's Up Next/history panel for the active context.

Until that proof exists, the only honest product states are:

- `exact`: public source matches Music.app visible queue/history by order and
  identity for the tested context.
- `unavailable`: no public source can represent the visible Music.app queue for
  that context.
- `playlistContextOnly`: public ScriptingBridge exposes the containing playlist
  around the current track, but Play Next/Play Later/history parity is not
  proven. This may support diagnostics or a clearly labeled non-queue view, not
  the real-time queue feature.

## Current Classification

| Surface | Classification | Reason |
| --- | --- | --- |
| Music.app public Apple Events `current playlist` | `playlistContextOnly` when available; `unavailable` when absent | The SDEF describes it as the playlist containing the current targeted track, not the Up Next queue. Station/URL-track proof shows it can be absent while Music.app visibly has queue rows. |
| Music.app public Apple Events `fixed indexing` variants | probe-only candidate for album/playlist order | The SDEF says fixed indexing controls whether AppleScript track indices are independent of the play order of the owning playlist. The public probe can now opt into toggling this setting, recording current-playlist neighbor rows for both values, then restoring the original value. The validator rejects resolved rows if restoration is not recorded. This may help test album/playlist play order, but it is not exact proof without visible Up Next/history parity. In the current URL-track smoke run, both variants still failed because Music.app exposed no public current playlist. |
| Music.app public Apple Events `selection` / window selection | selected-items evidence only | The SDEF exposes the visible user selection and selected tracks in windows, so the probe now records it. A current URL-track run showed empty selection and no queue candidate. Even when non-empty, this surface is not exact queue proof unless it exposes every visible history/current/upcoming row in order. |
| Music.app public Apple Events `browser window.view` / `playlist window.view` | partial public view candidate | The SDEF exposes each window's displayed playlist. The probe now records view metadata and neighbor rows around the current track when the view contains it. This can discover whether Music.app exposes a visible queue-like playlist view, but it remains partial until visible Up Next/history rows match by order and identity. |
| Music.app public Apple Events queue object | `unavailable` | Local SDEF probe found no public `queue`, `Up Next`, or history object declaration. |
| Music.app distributed notifications | invalidation/metadata only until payload parity proof | nanoPod observes known public `DistributedNotificationCenter` names such as `com.apple.Music.playerInfo` and `com.apple.Music.playlistChanged` as change triggers. They must not become a queue source unless a recorded payload exposes every visible queue/history row by order and identity. The probe now separates possible row-carrier keys from context-only metadata keys so `playlist`/current-track fields cannot be mistaken for queue rows. Passive no-event runs remain inconclusive rather than exact proof. |
| Apple Music API recently played | metadata/history support only | It returns account history resources, not the live local Music.app Up Next/history panel. |
| MusicKit `ApplicationMusicPlayer.queue` | rejected for Music.app parity | Apple's public documentation says application music players do not affect Music.app state, so this surface is app-local by contract. Runtime probe `.codex/workspace/music-queue-probes/musickit-application-player-queue-non-disruptive-current-state-20260524T025025Z.txt` saw Music.app playing while `ApplicationMusicPlayer` was stopped with an empty queue. |
| MusicKit `SystemMusicPlayer` | unavailable on current macOS SDK; future candidate only with proof | Apple's public documentation identifies this as the Music.app-controlling MusicKit player, but local SDK compiler probe marks it unavailable on macOS. Documentation also says it shares only some Music.app state, so future availability would still require visible Up Next/history parity proof. |
| MediaPlayer `MPMusicPlayerController` / `applicationQueuePlayer` / `systemMusicPlayer` | unavailable on current macOS SDK; future candidate only for system player with proof | Local Xcode 26.2 macOS SDK marks `MPMusicPlayerController` unavailable on macOS, so its queue APIs cannot be compiled for nanoPod today. Public docs and headers also classify application players as app-local, while system player sharing is limited and would still need visible queue parity proof if macOS availability changes. |
| MediaPlayer `MPNowPlayingInfoCenter.default()` | current-app metadata only | Public docs and headers describe it as the current application's Now Playing info center. Local runtime returned `nowPlayingInfo=nil` and playback state `unknown`, with no Music.app queue rows. Queue index/count keys refer to the application's playback queue, not Music.app's Up Next/history panel. |
| Public SDK/API surface probe | supplemental availability evidence only | `.codex/workspace/probe_music_queue_sdk_surface.sh` records public MusicKit and MediaPlayer compiler/runtime availability without talking to Music.app, requesting authorization, or mutating playback. The 2026-05-31 refresh still classifies Xcode 26.2 as `application_player_queue_only_not_music_app_session`: `ApplicationMusicPlayer.queue` and insertion positions compile, `SystemMusicPlayer` and `MPMusicPlayerController` fail on native macOS, and `MPNowPlayingInfoCenter` is current-app metadata. |
| SiriKit Cloud Media `Queue` | rejected; service-provider API only | Apple's Cloud Media docs define a queue that a developer's media service returns to compatible devices for Siri playback fulfillment. It is not a macOS client API for reading or editing the user's local Music.app Up Next/history panel. |
| Music.app private files/caches/playback sessions | rejected | Not a public App Store-safe queue source. Existing artwork use does not make it acceptable for queue parity. |
| Accessibility/UI scraping | rejected for product implementation | Useful only for manual proof notes; not a shippable queue source. |

## Implementation Implications

Before product implementation starts, add a queue provenance model rather than
only arrays of rows. The UI and tests need to know whether rows are exact,
unavailable, or playlist-context-only.

Suggested model shape:

```swift
enum MusicQueueProvenance: Equatable {
    case exactPublicMusicQueue(context: String)
    case playlistContextOnly(playlistName: String?)
    case unavailable(reason: MusicQueueUnavailableReason)
}

enum MusicQueueUnavailableReason: Equatable {
    case noPublicQueueObject
    case noCurrentPlaylistForTrackClass(String)
    case publicSourceUnverified
    case musicAppUnavailable
}
```

The current `upNextTracks` and `recentTracks` arrays are insufficient because
empty rows can mean a truly empty exact queue, an unavailable queue, or an
unproven source. Any implementation should add provenance before changing the
playlist page UX.

This foundation now exists in code:

- `MusicQueueProvenance`
- `MusicQueueUnavailableReason`
- `MusicController.upNextProvenance`
- `MusicController.recentTracksProvenance`

Current fetch paths classify ScriptingBridge `currentPlaylist.tracks` rows as
`playlistContextOnly`, missing `currentPlaylist` as `unavailable`, and Apple
Music API recently played rows as `appleMusicAccountRecentlyPlayed`.

The playlist UI now uses `MusicQueueProvenance.canDisplayAsRealTimeQueueRows`.
Only `exactPublicMusicQueue` and `preview` may render row arrays under the
History/Up Next sections. `playlistContextOnly`, account recently played, and
unavailable states render an unavailable state instead. The unavailable state
also includes a concise provenance reason so the UI exposes the limitation
without showing synthetic queue rows.

The production snapshot apply path now applies the same gate before storing
published queue/history rows. Non-displayable snapshots may record raw row
counts for diagnostics, but they do not retain playlist-context or
account-history rows in `upNextTracks`/`recentTracks`; playlist-open refreshes
also avoid forcing Apple Music recent-history fetches just because those hidden
rows were intentionally dropped.
Production fetches now also avoid materializing track rows from sources already
classified as non-displayable. For example, once `currentPlaylist` is classified
as `playlistContextOnly`, nanoPod records the provenance and returns without
asking Music.app for the playlist `tracks` array. That keeps the long-running
assistant path from doing hidden ScriptingBridge scans that cannot be shown as
the real queue. The same materialization gate prevents Apple Music account
recently-played rows from being fetched as queue rows in the always-on runtime.
Row-level evidence for these unproven sources belongs in the explicit probe
harness, not the always-on runtime.

Owner diagnostics now keep retained and raw queue counts separately. This keeps
reports honest: non-displayable provenance can show `0` retained rows while
still preserving how many raw playlist-context/account-history rows the public
surface returned during the session.
Reports also include the same concise unavailable reason shown in the UI, so
owner diagnostics can explain why nanoPod withheld queue/history rows without
requiring someone to decode provenance labels.

Playlist row playback follows the same assistant-only rule. Apple Music API
row IDs (`am:*`) are not delegated to `ApplicationMusicPlayer`, because that
would start app-local playback instead of controlling the user's visible
Music.app session. Exact row playback remains limited to Music.app public
control surfaces until a public Music.app route for catalog/account IDs is
proven.

Playlist-open cache reuse is tied to a fresh completed, displayable public
snapshot for the current queue generation. Exact-empty snapshots remain
reusable because exact public provenance is displayable even with zero rows, but
unavailable, account-history, and playlist-context-only snapshots force another
public refresh attempt when the user opens the playlist page. Queue, track, or
source changes still bump the generation and force a fresh public snapshot
attempt before any rows can be shown. Nearby asset preloading follows the same
displayable-provenance gate, so unproven rows cannot fill predictive
artwork/lyrics caches for weeks as if they were the user's real upcoming queue.

Owner diagnostics now carry stable Up Next/recent provenance labels, row counts,
and displayability flags. This does not prove exact parity, but it makes
long-running unavailable/playlist-context-only states auditable when users keep
nanoPod open for weeks.

Queue-change invalidation now follows the same proof gate. When a user control,
distributed Music.app `playerInfo` track-change notification, externally
observed track/source change, or periodic Music.app queue-hash change can make
the visible Music.app queue different, nanoPod clears retained queue/history
rows and marks both surfaces as `pendingPublicRefresh` until a fresh public
snapshot is applied. This avoids showing stale rows from the previous context
as if they were still exact.
User controls that can advance or reorder playback now schedule a public queue
refresh after the Music.app command returns, fails, or cannot reach Music.app.
Those scheduled reads are guarded by the queue generation captured when the
rows were invalidated, so a control completion or failure cannot refresh a
newer queue state after another detector has already superseded it.
Playlist row playback remains limited to non-empty hexadecimal Music.app
`persistent ID` values, matching the public scripting dictionary. Catalog IDs,
placeholders, whitespace, and arbitrary strings are rejected instead of being
sent to Music.app or an app-local player.
Observed track-change paths now also schedule the same delayed, generation-gated
queue refresh. This includes notification handling, full-state sync, and
radio/backstop fallback detection; if a newer track generation arrives before
the timer fires, the stale refresh is skipped.
Both Up Next and recent-history snapshot application are generation-gated, and
queue invalidation resets the recent-history refresh timestamp so a stale
in-flight history result cannot suppress the next fresh read for the new
context. Up Next and recent history must both use the queue and track
generations captured when the fetch was scheduled, including early unavailable
results.
Coalesced pending refreshes carry the same queue and track generations. A
throttled delayed callback may only consume the pending request if those
generations still match current state; stale pending refreshes are discarded
instead of being allowed to recapture a newer state without proof.

The next manual proof passes should use
`.codex/workspace/run_music_queue_parity_matrix.sh`. The runner creates a
runbook and per-context visible-note templates, then delegates to the
public-surface probe for the current Music.app state. It intentionally never
changes Music.app playback, so album/playlist/radio/edit setup remains a manual
step unless the user explicitly approves playback-changing automation later.
The public-surface probe now also records Music.app's documented `selection`
and window-selection properties. Use that evidence to reject or continue
investigating selection-based surfaces, but do not treat selected rows as a
complete queue unless the visible parity notes prove every visible queue row is
exposed by order and identity.
The probe also records public browser/playlist window `view` playlists and, if
the view contains the current track, a neighbor window around that item. Treat
these as another public candidate surface to compare against the visible
Up Next/history UI, not as exact queue proof by themselves.
The first URL-track window-view run
`.codex/workspace/music-queue-probes/public-surface-window-view-current-state-20260524T042652Z.txt`
found no usable window-view queue candidate: the browser window view returned
`Unknown object type`, no playlist window view existed, and the classification
remained `unavailable_no_current_playlist`.

The distributed-notification probe
`.codex/workspace/probe_music_distributed_notifications.sh` captures the
`userInfo` keys from known Music.app notification names. It now records
`row_carrier_userInfo_keys`, `context_only_userInfo_keys`, and value shapes so
metadata/context fields cannot be overclassified as real queue rows. The first
passive run
`.codex/workspace/music-queue-probes/distributed-notifications-distributed-notification-current-state-20260524T043736Z.txt`
observed no notification during the capture window, with Music.app paused on a
URL track and `current playlist` unavailable. That result is only a passive
no-event artifact; a future run during a manual Music.app play/pause or track
change is needed to classify the payload. Until a payload exposes every visible
Up Next/history row by order and identity, these notifications remain
invalidation signals only.
The refined classifier run
`.codex/workspace/music-queue-probes/distributed-notifications-distributed-notification-classifier-current-state-20260524T044335Z.txt`
also observed no event, but verifies the stricter report fields for future
manual event captures.
The first clean triggered run
`.codex/workspace/music-queue-probes/distributed-notifications-distributed-notification-muted-playpause-trigger-restored-20260524T044927Z.txt`
used public Music.app Apple Events to play/pause with Music.app muted, then
restored the original paused state and volume. It captured both
`com.apple.Music.playerInfo` and legacy `com.apple.iTunes.playerInfo` payloads.
Those payloads contained only `Album`, `Artist`, `Genre`, `Name`,
`Player State`, and `Total Time`; `row_carrier_userInfo_keys` was empty. This
is scoped evidence that play/pause `playerInfo` notifications are metadata and
invalidation signals, not queue/history row data for the current URL-track
state.

Before any matrix result is used as implementation evidence, run
`.codex/workspace/validate_music_queue_parity_matrix.py` on that session. Exact
rows must have visible rows, explicit row-match confirmation, and a
non-unavailable public probe classification.
Before claiming that the read strategy is complete, run the same validator with
`--require-complete`. That mode requires all product contexts from the parity
matrix to have a resolved `exact` or `unavailable` row, so missing album,
playlist, local-file, queue-edit, or rapid-change proof cannot be hidden by one
well-tested context.
Unavailable rows must also be proven, not assumed: they need completed visible
Music.app notes with the queue UI open and visible rows recorded, plus either an
unavailable public probe classification or an explicit visible/probe row
mismatch. This prevents a missing public snapshot from being mistaken for a
true context limit without evidence of what Music.app actually showed.
For distributed-notification artifacts, exact rows must also have observed
events, non-empty row-carrier keys, and non-empty array/dictionary payload
shapes for those keys. No-event and metadata-only captures are blocked as exact
queue evidence.
Notification captures should normally be attached through
`run_music_queue_parity_matrix.sh --run-notifications`, which writes
`NOTIFICATION_SUMMARY.md` supplemental evidence rather than adding rows to the
exact-claim `SUMMARY.md`.
SDK/API availability captures should normally be attached through
`run_music_queue_parity_matrix.sh --run-sdk`, which writes `SDK_SUMMARY.md`.
Treat that as a repeatable way to rule API surfaces in or out for further
manual parity testing, not as queue parity proof by itself.

When investigating MusicKit as an alternative read path, also run
`.codex/workspace/probe_musickit_application_player_queue.sh`. The first
non-disruptive runtime pass found Music.app playing a URL-track station item
while `ApplicationMusicPlayer.shared` reported `stopped`, `currentEntry=nil`,
and `entries_count=0`; this supports treating `ApplicationMusicPlayer.queue` as
not bound to the user's visible Music.app session unless later visible parity
evidence proves otherwise.

The official API audit is recorded in
`.codex/workspace/music-queue-official-api-audit.md`. It raises the bar further:
`ApplicationMusicPlayer` is app-local by documented contract, while
`SystemMusicPlayer` is the only MusicKit player conceptually aligned with
Music.app control and is unavailable in the current local macOS SDK. MediaPlayer
`MPMusicPlayerController` is also unavailable on the current macOS SDK, and its
application queue player is app-local by public contract. `MPNowPlayingInfoCenter`
is a current-app metadata publishing surface, not a system Music.app queue
reader. SiriKit Cloud Media `Queue` is also not a client-side Music.app reader;
it is the queue payload a media service returns to compatible devices for Siri
playback fulfillment.

## Product Rule

If the active context is a URL/radio/station track and public Apple Events
cannot read `current playlist`, nanoPod must not show stale or guessed Up Next
rows. It should show an unavailable state for real-time queue parity, while
keeping normal Now Playing controls.

If `current playlist` is available during album or playlist playback, nanoPod
still cannot call those neighbor rows "real-time queue" until Play Next/Play
Later edits and Music.app visible order have been compared.

## Editing Rule

Queue editing remains locked. It can only unlock after both conditions are true:

1. nanoPod can read the same Music.app queue exactly through a public source.
2. A public API is proven to modify that same Music.app session, with the
   subsequent read proving the visible order changed as expected.

`MusicPlayer.Queue.insert` and its `afterCurrentEntry`/`tail` positions are
public and relevant to future Play Next/Play Later research. They are not an
editing implementation path until the target queue is proven to be the same
visible Music.app queue.
