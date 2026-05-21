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
