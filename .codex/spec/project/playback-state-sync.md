# Playback State Sync

## Music Repeat Mode

- Music.app's `song repeat` enum values come from the app SDEF:
  - off: `kRpO` / `0x6B52704F`
  - one: `kRp1` / `0x6B527031`
  - all: `kAll` / `0x6B416C6C`
- Read and write repeat state through one shared mapping. Do not use `kRAl`
  (`0x6B52416C`) for playlist repeat; Music reports playlist repeat as `kAll`,
  and mismatched read/write values desynchronize the UI from system state.

## Diagnostics Context

- Full ScriptingBridge state sync must preserve the current track class instead
  of leaving it blank. Use the current track's Apple Event `objectClass`
  descriptor to map `cURL` to `URL track`, `cFlT` to `file track`, and `cShT`
  to `shared track`; this keeps radio/stream/library context available to
  diagnostics without spawning AppleScript on every normal state poll.
- Current playlist name is public Apple Event state and should be carried into
  diagnostics context alongside the inferred playback context. More specific
  Music.app navigation origins, such as whether a song came from a search view
  versus another private UI route, are not exposed through the public API and
  should be reported as unavailable rather than guessed.

## Lyrics Interaction Budget

- User seek and lyric tap-to-jump should apply an optimistic local clock update
  immediately and set a short position-poll cooldown. The next backend poll must
  not collide with the visible tap recovery animation.
- While native lyrics manual-scroll ownership is active, defer lightweight
  ScriptingBridge position polling briefly. Manual-scroll recovery and tap
  recovery are presentation-critical; backend correction can resume after the
  gesture settles.
- Full state sync should avoid re-reading stable track metadata when the
  persistent ID matches the current non-URL library track. Preserve the current
  audio-quality badge for that same-track fast path by using negative
  bitrate/sample-rate sentinels internally.
