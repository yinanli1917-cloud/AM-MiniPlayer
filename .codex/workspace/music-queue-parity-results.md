# Music Queue Parity Results

This file records evidence for the real-time queue goal. A context is `exact`
only when a public App Store-safe surface matches Music.app's visible
Up Next/history UI by order and identity. Probe output alone is not enough.

## Proof Standard

For each context:

1. Open Music.app's visible Up Next/history queue.
2. Prefer the guarded matrix runner:
   `bash .codex/workspace/run_music_queue_parity_matrix.sh --run-current --context <context>`.
   It creates/uses visible-note templates and calls the public probe without
   changing Music.app playback.
   Use `--run-notifications` on the same session when notification payload
   evidence is needed; this writes supplemental rows to
   `NOTIFICATION_SUMMARY.md` rather than the exact-claim `SUMMARY.md`.
   Use `--run-sdk` when SDK/API availability evidence is needed; this writes
   supplemental rows to `SDK_SUMMARY.md`, not the exact-claim `SUMMARY.md`.
3. Save the generated probe path.
4. Save a screenshot or written notes of the visible Music.app queue/history.
5. Mark `exact` only if the visible rows and public-surface rows match by order
   and identity.
6. Run `python3 .codex/workspace/validate_music_queue_parity_matrix.py <session-dir>`
   before using the matrix as implementation evidence.
   Add `--coverage-report` when you need the resolved/pending/missing status
   for every required playback context without failing solely because the
   matrix is incomplete.
   Run the same validator with `--require-complete` before claiming that the
   read strategy covers the required product contexts.
   The validator now explicitly rejects exact claims backed by
   distributed-notification artifacts that observed no events, contain only
   metadata/context payloads, have no row-carrier keys, or lack non-empty
   array/dictionary row-like payload shapes.
   It also rejects `unavailable` claims unless visible Music.app notes are
   complete and prove either that the public probe was unavailable for a
   visible queue state or that the public rows mismatched the visible queue by
   order and identity.
   Resolved rows backed by a fixed-indexing probe must also show
   `fixed_indexing.restored=true`; otherwise the probe changed a public
   Music.app setting and cannot support an exact or unavailable claim.
   Notification rows in `NOTIFICATION_SUMMARY.md` are not considered exact
   claims unless promoted into `SUMMARY.md` and validated with visible parity
   notes.
   `--require-complete` additionally rejects missing required contexts and
   contexts without any resolved `exact` or `unavailable` evidence row; it also
   prints the coverage report before the blocking errors.

Private Music.app storage, Accessibility/UI scraping, private AppleEvents, and
memory inspection are not acceptable proof sources for this App Store goal.
Apple Music API recently played data may support history metadata, but it is not
live Music.app queue proof.

## Compliance Notes

- The app currently has `com.apple.security.automation.apple-events`, which is
  the right public automation lane for Music.app scripting when the user grants
  permission.
- The app also has a temporary read exception for
  `Library/Application Support/Music/PlaybackSessions/`, currently used by
  artwork discovery code. That private storage path must not be used as the
  real-time queue source.
- Local SDK probe: `ApplicationMusicPlayer.shared.queue` compiles on macOS, but
  it is not proven to target the user's Music.app session.
- Runtime MusicKit probe:
  `.codex/workspace/music-queue-probes/musickit-application-player-queue-non-disruptive-current-state-20260524T025025Z.txt`
  recorded Music.app playing a URL-track station item while
  `ApplicationMusicPlayer` reported `stopped`, `current_entry=nil`, and
  `entries_count=0`. That run classified the surface as
  `not_music_app_session_music_playing_application_player_empty`.
- Official API audit:
  `.codex/workspace/music-queue-official-api-audit.md` records that Apple's
  public documentation describes application music players as not affecting
  Music.app state, while `SystemMusicPlayer` is the Music.app-controlling
  concept but is unavailable in the current local macOS SDK.
- Local SDK probe: `SystemMusicPlayer.shared` fails to compile on macOS because
  `SystemMusicPlayer` is marked unavailable.
- Local SDK probe:
  `.codex/workspace/music-queue-probes/public-surface-mediaplayer-current-state-20260524T034231Z.txt`
  records that MediaPlayer `MPMusicPlayerController`,
  `applicationQueuePlayer`, and `systemMusicPlayer` all fail to compile on
  macOS because `MPMusicPlayerController` is marked unavailable in the current
  Xcode 26.2 macOS SDK.
- Local runtime probe:
  `.codex/workspace/music-queue-probes/public-surface-now-playing-center-current-state-20260524T034454Z.txt`
  records `MPNowPlayingInfoCenter.default()` as available but current-app
  scoped: `nowPlayingInfo=nil`, playback state `unknown`, and no Music.app queue
  rows. The public header excerpt describes default center data as current-app
  Now Playing info.
- Standalone SDK surface probe:
  `.codex/workspace/music-queue-probes/sdk-supplemental-smoke-20260524T050239Z/sdk-surface-sdk-current-state-20260524T050239Z.txt`
  records the same Xcode 26.2 public SDK shape without talking to Music.app:
  `ApplicationMusicPlayer.queue` and queue insertion positions compile,
  `SystemMusicPlayer` and `MPMusicPlayerController` fail on macOS, and
  `MPNowPlayingInfoCenter.default()` compiles as current-app metadata. Its
  matrix wrapper writes only supplemental `SDK_SUMMARY.md` evidence.
- SDK refresh probe:
  `.codex/workspace/music-queue-probes/sdk-refresh-20260531/SDK_SUMMARY.md`
  repeats the public SDK/API availability check on 2026-05-31 with the same
  classification: no native macOS `SystemMusicPlayer` or MediaPlayer music
  player controller path is available, and the only compiling queue remains
  app-local `ApplicationMusicPlayer.queue`.
- Official API audit records SiriKit Cloud Media `Queue` as a service-provider
  fulfillment surface for compatible Siri devices, not a client-side Music.app
  queue reader. It should not be added to the runtime parity matrix unless
  Apple's docs expose a macOS client API for the user's local Music.app queue.
- Public Apple Events expose `selection` and window-selection properties. The
  probe now records them as selected visible-item evidence, not as complete
  queue proof unless a visible parity pass shows every queue row is exposed by
  order and identity.
- Public Apple Events also expose browser/playlist window `view` playlists. The
  probe now records those view summaries and neighbor rows when a view contains
  the current track; these are candidate public surfaces only until visible
  Up Next/history parity is proven.
- Public Apple Events expose the application-level `fixed indexing` setting,
  which controls whether AppleScript track indices are independent of playlist
  play order. The public probe now has an opt-in `--probe-fixed-indexing` mode
  that toggles both values and restores the original value. The current
  URL-track smoke artifact
  `.codex/workspace/music-queue-probes/public-surface-fixed-indexing-current-state-20260524T052141Z.txt`
  restored `fixed_indexing.original=false` and still found no public current
  playlist for either variant, so it does not change the radio/station
  conclusion. It remains useful for future album/playlist parity passes.
- Public Foundation `DistributedNotificationCenter` is acceptable for
  observing known Music.app notification names as change triggers, but
  notification payloads are not queue proof unless they expose every visible
  Up Next/history row by order and identity. The notification probe now
  separates row-carrier keys from context-only metadata keys so playlist/current
  track fields are not overclassified as queue rows. The first passive
  notification probe
  `.codex/workspace/music-queue-probes/distributed-notifications-distributed-notification-current-state-20260524T043736Z.txt`
  observed no notification during a 5-second URL-track paused-state capture, so
  it is an inconclusive no-event artifact rather than a payload rejection.
  The refined classifier artifact
  `.codex/workspace/music-queue-probes/distributed-notifications-distributed-notification-classifier-current-state-20260524T044335Z.txt`
  also observed no event, but verifies the stricter
  `row_carrier_userInfo_keys` and `context_only_userInfo_keys` report shape.
- Triggered notification evidence:
  `.codex/workspace/music-queue-probes/distributed-notifications-distributed-notification-muted-playpause-trigger-restored-20260524T044927Z.txt`
  used a public play/pause Apple Event with Music.app muted, restored
  `paused|100`, and captured Music/iTunes `playerInfo` payloads. Those payloads
  contained only `Album`, `Artist`, `Genre`, `Name`, `Player State`, and
  `Total Time`; no row-carrier keys were present.

## Matrix

| Context | Status | Evidence | Notes |
| --- | --- | --- | --- |
| Album playback | pending |  | Needs visible Music.app queue comparison. |
| User playlist playback | pending |  | Needs visible Music.app queue comparison. |
| Apple Music playlist playback | pending |  | Needs visible Music.app queue comparison. |
| Local/library file track playback | pending |  | Needs visible Music.app queue comparison. |
| Radio/station or URL-track playback | unavailable | `.codex/workspace/music-queue-probes/public-surface-20260524T015627Z.txt`; `.codex/workspace/music-queue-probes/public-surface-20260524T020052Z.txt`; `.codex/workspace/music-queue-probes/visible-state-20260524T020052Z.md`; `.codex/workspace/music-queue-probes/public-surface-non-disruptive-current-state-20260524T020738Z.txt`; `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/RUNBOOK.md`; `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/SUMMARY.md`; `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/public-surface-radio-station-url-track-resolved-20260524T020052Z.txt`; `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-radio-station-url-track-resolved-20260524T020052Z.md`; `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/public-surface-radio-station-url-track-20260524T023857Z.txt`; `.codex/workspace/music-queue-probes/public-surface-selection-surface-current-state-20260524T033512Z.txt`; `.codex/workspace/music-queue-probes/public-surface-mediaplayer-current-state-20260524T034231Z.txt`; `.codex/workspace/music-queue-probes/public-surface-now-playing-center-current-state-20260524T034454Z.txt`; `.codex/workspace/music-queue-probes/public-surface-window-view-current-state-20260524T042652Z.txt` | Music.app visibly showed a play queue with `Continue Playing` from the user's station and upcoming rows, but public AppleScript read only `current track`; `current playlist` failed; no public `Up Next` object/playlist was exposed; probe classified `unavailable_no_current_playlist`. The guarded matrix now includes a resolved `unavailable` row for the 2026-05-24 02:00:52 UTC station/URL-track capture using a reviewed wrapper around the raw public probe and completed visible notes. Later current-state matrix runs also recorded the same unavailable classification for a URL-track state without changing playback. The first selection-surface run showed empty app/window selection and did not expose a public queue candidate. The window-view probe also found no public window view queue surface in the current URL-track state: `browser_window[1].view` errored with `Unknown object type`, no playlist-window view existed, selection was empty, and classification remained `unavailable_no_current_playlist`. The MediaPlayer probe adds no macOS implementation path because `MPMusicPlayerController` is unavailable. The Now Playing Center probe is current-app scoped and returned no Music.app queue rows. |
| Manual Play Next / Play Later edits | pending |  | Needs a setup with visible queue edits, then probe comparison. |
| Skip/previous rapid changes | pending |  | Needs stale-snapshot check after repeated controls. |

## Current Conclusion

The current `currentPlaylist.tracks` strategy is not a universal real queue
source. It already fails for a URL-track/radio-like runtime state where the
Music.app UI visibly has a queue, so any first implementation must either find
another public exact source or show the queue as unavailable in that context.

The current read-strategy gate is recorded in
`.codex/workspace/music-queue-read-strategy-decision.md`: public rows are either
`exact`, `unavailable`, or `playlistContextOnly`. The existing
`currentPlaylist.tracks` rows can only be considered `playlistContextOnly` until
visible Music.app queue parity, including Play Next/Play Later edits, is proven.
`ApplicationMusicPlayer.queue` is also not usable as Music.app queue proof in
the current runtime evidence because it is empty/stopped while Music.app is
playing, and Apple's public documentation describes application music players
as not affecting Music.app state.

Distributed notifications currently remain invalidation evidence only. The
passive probe has been added so future manual parity passes can capture
`playerInfo` and playlist-change payload keys, but no exact queue row payload
has been observed or accepted. A payload with only context metadata still fails
the real-time queue bar.
The first triggered play/pause payload capture strengthens this for the current
URL-track state: known public `playerInfo` notifications did not carry
Up Next/history rows.
SDK availability is now separately repeatable through
`run_music_queue_parity_matrix.sh --run-sdk`; that evidence can reject or
prioritize API surfaces, but exact product behavior still requires visible
Music.app queue/history parity.
The matrix validator now applies the same rigor to unavailable claims: a
context cannot be called unavailable without completed visible Music.app notes
and a public-probe failure or explicit visible/probe row mismatch.
The current recorded matrix intentionally fails
`validate_music_queue_parity_matrix.py --require-complete`: radio/station is
now resolved unavailable, while album, user playlist, Apple Music playlist,
local/library file, Play Next/Play Later edits, and rapid skip/previous
contexts are still missing resolved proof rows. The validator now reports that
same status directly as coverage: resolved `radio-station-url-track`, missing
the remaining six required contexts.
