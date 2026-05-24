# Distribution And Compliance

## Product Variants

- GitHub builds may support Apple Music plus third-party sources such as NetEase
  Music and QQ Music.
- The Mac App Store variant is Apple Music-only and should use official Apple
  Music API/MusicKit authorization for Apple Music account access.

## Shared System Features

- System-level features that are not tied to a music source should stay
  source-agnostic so they can be reused by both variants.
- Audio output switching belongs in shared Core logic, not in Apple Music,
  NetEase, QQ Music, or any player-specific integration.
- Audio output switching must use public Core Audio APIs only and should not add
  microphone/audio-input, Bluetooth, Accessibility, helper tool, shell
  automation, System Settings automation, private framework, or private selector
  requirements.

## Review Notes

- For App Store review, describe the output switcher as a user-initiated selector
  for macOS-detected output-capable devices. It changes the system-wide default
  output and follows macOS when devices appear, disappear, or the default changes
  elsewhere.
- Do not infer App Store readiness from the source entitlement file alone. Verify
  the signed app bundle entitlements; the current local GitHub build script signs
  its ad-hoc bundle with App Sandbox disabled, while the App Store variant must be
  sandboxed.

## Apple Music Queue Sync

- Real-time Music.app queue sync must use public, reviewable surfaces only:
  Music.app Apple Events from the public scripting dictionary, MusicKit public
  SDK APIs, Apple Music API endpoints, and Foundation
  `DistributedNotificationCenter` for known Music.app notification names.
- Do not use private Music.app databases, playback-session archives, caches,
  private AppleEvents, Accessibility/UI scraping, or memory inspection as a
  queue source for the App Store variant.
- `Library/Application Support/Music/PlaybackSessions/` may exist in local
  artwork code, but it is private Music.app storage and must not be used as
  proof of Up Next/history parity.
- MusicKit `ApplicationMusicPlayer.queue` is a public SDK surface, but current
  runtime evidence shows it can be stopped and empty while Music.app is playing.
  Apple's public documentation also says application music players do not affect
  Music.app state. Do not use it as the App Store queue source.
- MusicKit `MusicPlayer.Queue.insert` positions map conceptually to Play
  Next/Play Later, but queue editing remains locked until read parity proves
  the target queue is the same visible Music.app session and a public edit API
  is proven by post-edit readback.
- SDK/API availability probes for this feature must be read-only and limited
  to public macOS SDK symbols, public framework headers, and non-mutating
  compiler/runtime checks. Record their output as supplemental evidence only;
  API availability alone is not an App Store-safe proof that nanoPod can read
  or edit the visible Music.app queue.
- Music.app distributed notifications may be used as invalidation or
  now-playing metadata signals. They must not be used as a queue source unless
  a captured payload is proven to match the visible Up Next/history rows by
  order and identity. Playlist/current-track metadata keys are context-only;
  they are not queue-row carriers.
- Probe-only notification triggers must use public Music.app Apple Events,
  restore the original play/pause state and Music.app volume, and never mutate
  the queue. Product code must not depend on trigger behavior.
