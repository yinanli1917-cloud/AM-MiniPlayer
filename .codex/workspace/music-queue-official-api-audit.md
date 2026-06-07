# Music Queue Official API Audit

Last checked: 2026-05-24

This audit records what Apple's public documentation says about MusicKit,
Apple Music API, and Music.app control surfaces for nanoPod's real-time queue
goal. It is not a substitute for local visible parity tests. It tells us which
surfaces are worth probing and which ones are ruled out by public API contract.

## Official Sources

- MusicKit overview:
  https://developer.apple.com/documentation/musickit
- MusicPlayer.Queue:
  https://developer.apple.com/documentation/musickit/musicplayer/queue
- MusicPlayer.Queue.EntryInsertionPosition:
  https://developer.apple.com/documentation/musickit/musicplayer/queue/entryinsertionposition
- SystemMusicPlayer:
  https://developer.apple.com/documentation/musickit/systemmusicplayer
- MPMusicPlayerController.applicationMusicPlayer:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/applicationmusicplayer
- MPMusicPlayerController.applicationQueuePlayer:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/applicationqueueplayer
- MPMusicPlayerController:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller
- MPMusicPlayerController.systemMusicPlayer:
  https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/systemmusicplayer
- MPNowPlayingInfoCenter:
  https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter
- MPNowPlayingInfoCenter.default:
  https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter/1615899-default
- SiriKit Cloud Media:
  https://developer.apple.com/documentation/sirikitcloudmedia
- SiriKit Cloud Media Queue:
  https://developer.apple.com/documentation/sirikitcloudmedia/queue
- SiriKit Cloud Media Get a Media Queue:
  https://developer.apple.com/documentation/sirikitcloudmedia/get-a-media-queue

## Findings

### ApplicationMusicPlayer

Apple documents `ApplicationMusicPlayer` as playback support for an app, not a
Music.app assistant surface. The MusicKit overview describes it as the player
for playing music in a way that does not affect Music.app state. The older
MediaPlayer `applicationMusicPlayer` documentation states the same product
contract: application playback is local to the app and does not affect the
Music app's state.

Local runtime evidence matches the official contract:

- `.codex/workspace/music-queue-probes/musickit-application-player-queue-non-disruptive-current-state-20260524T025025Z.txt`
  saw Music.app playing while `ApplicationMusicPlayer` was stopped with an
  empty queue.

Decision: `ApplicationMusicPlayer.queue` is not a real Music.app queue source
for nanoPod. Using it as the source of truth would move nanoPod toward a
standalone player, which is outside the product goal.

### SystemMusicPlayer

Apple documents `SystemMusicPlayer` as the MusicKit player that controls
Music.app state. The same documentation also says it shares only some Music.app
state, including repeat mode, shuffle mode, and playback status; it explicitly
does not share other aspects of Music.app state.

Local SDK evidence remains stricter for this macOS target:

- `.codex/workspace/probe_music_queue_public_surface.sh` currently reports
  `SystemMusicPlayer.shared` as unavailable on macOS in the local SDK compiler
  probe.

Decision: `SystemMusicPlayer` is the only MusicKit player conceptually aligned
with controlling Music.app, but it is not currently available for this macOS
build. If a future SDK exposes it on macOS, nanoPod must still run a visible
parity matrix before treating `SystemMusicPlayer.queue` as exact Up
Next/history state because Apple's documentation says not all Music.app state
is shared.

### MusicPlayer.Queue

Apple documents `MusicPlayer.Queue` as the playback queue for a music player.
It exposes `currentEntry` and insertion APIs. Its insertion positions include:

- `afterCurrentEntry`, similar to Music.app's Play Next feature.
- `tail`, similar to Music.app's Play Later feature.

Decision: these insertion APIs are relevant to future edit research only after
read parity proves that the target player queue is the same visible Music.app
session. On the current macOS target, `ApplicationMusicPlayer.queue` fails that
bar and `SystemMusicPlayer` is unavailable.

### MediaPlayer MPMusicPlayerController

Apple's MediaPlayer documentation describes application music players as
app-local and says `applicationQueuePlayer` provides more queue control while
still not affecting Music.app state. The documented `systemMusicPlayer` is the
MediaPlayer surface that controls Music app state, but Apple's documentation
only lists repeat mode, shuffle mode, now-playing item, and playback state as
shared state; other Music.app state is not shared.

Local SDK evidence is stricter for nanoPod's macOS target. The Xcode 26.2
macOS SDK marks `MPMusicPlayerController` unavailable on macOS, and compile
probes fail for:

- `MPMusicPlayerController`
- `MPMusicPlayerController.applicationQueuePlayer`
- `MPMusicPlayerController.systemMusicPlayer`

The local public header also states that `applicationMusicPlayer` does not
affect Music's playback state, `applicationQueuePlayer` is similar but allows
direct queue manipulation, and `systemMusicPlayer` replaces the user's current
Music state.

Decision: MediaPlayer is not an implementation path for nanoPod on the current
macOS target. If a future SDK exposes `MPMusicPlayerController.systemMusicPlayer`
on macOS, it would still need visible Up Next/history parity proof before any
read or edit feature can use it as the real Music.app queue.

### MediaPlayer MPNowPlayingInfoCenter

Apple documents `MPNowPlayingInfoCenter` as the surface an app uses to provide
its own Now Playing metadata and playback state. The default center is for the
app designated to receive remote control events, not a general reader for the
system Music.app session. The local public header is consistent with that
contract: `defaultCenter` holds Now Playing info about the current application,
and playback-queue keys describe the application's playback queue.

Local runtime evidence also rejects it as a Music.app queue source:

- `.codex/workspace/music-queue-probes/public-surface-now-playing-center-current-state-20260524T034454Z.txt`
  reported `mp_now_playing.info=nil` and `mp_now_playing.playback_state=0`
  while Music.app still had separate public AppleScript playback state.

Decision: `MPNowPlayingInfoCenter` can help nanoPod publish its own Now Playing
metadata only if nanoPod ever becomes an audio playback app, which is outside
this goal. It is not a read path for Music.app's visible Up Next/history queue.

### SiriKit Cloud Media Queue

Apple documents SiriKit Cloud Media as a cloud media service-provider surface:
after a user asks Siri on a compatible device such as HomePod to play media, the
device contacts the developer's web service for playback fulfillment. The
`Queue` object and "Get a Media Queue" endpoint describe the queue or queue
segment that the developer's service returns to that device.

This is a different direction from nanoPod's goal. It is not a macOS client API
for reading another app's local Music.app Up Next/history panel, and it does
not provide evidence that a third-party Music.app assistant can inspect or edit
Apple Music's current queue. Using it would require nanoPod to act as a media
service/provider for playback fulfillment, which is outside the product goal.

Decision: SiriKit Cloud Media `Queue` is rejected as a Music.app queue
read/edit path for nanoPod. It should stay in the audit only to prevent its
name from being mistaken for the local Apple Music queue surface we need.

### Apple Music API

Apple Music API and MusicKit authorization are useful for catalog, library,
and account metadata. They do not by themselves expose the live local
Music.app Up Next/history panel.

Decision: Apple Music API data can support metadata enrichment and account
history labels. It cannot be labeled as nanoPod's real-time Music.app queue.

## Product Implications

- Do not implement read parity on `ApplicationMusicPlayer.queue`.
- Keep queue editing locked. `MusicPlayer.Queue.insert` is public, but on the
  current macOS target it is not proven to mutate Music.app's visible queue.
- A future Apple SDK change can reopen `SystemMusicPlayer` investigation, but
  only under the same proof standard: public runtime read, visible Music.app
  row comparison, and a post-edit readback if editing is tested.
- A future Apple SDK change can also reopen MediaPlayer
  `MPMusicPlayerController.systemMusicPlayer` investigation, but current macOS
  SDK availability blocks it before runtime parity testing.
- Do not use `MPNowPlayingInfoCenter` as a queue source. Its public contract is
  current-application Now Playing metadata, and local runtime returns no
  Music.app queue rows.
- Do not use SiriKit Cloud Media `Queue` as a queue source. It is a
  service-provider fulfillment API, not a client-side Music.app queue reader.
- The current honest UI states remain `exact`, `playlistContextOnly`, or
  `unavailable`; there is no official-doc basis for showing a synthetic queue
  as exact.
