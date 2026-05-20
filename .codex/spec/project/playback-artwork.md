# Playback Artwork

Current-track artwork should prefer speed, but must never leave a visibly stale
cover on a new track.

## Cache Rules

- Persistent library tracks may cache artwork by non-empty `persistentID`.
- Before ScriptingBridge backfills `persistentID`, current-track artwork may use
  a metadata cache key of normalized title, artist, and album.
- URL/radio tracks must not use a title/artist cache key. Those metadata fields
  can be reused by stations and cause stale covers.

## Track Switch Behavior

- On a new-track artwork request, cache hits may apply immediately.
- On cache miss, clear the previous `currentArtwork` before async SB/API fetches
  run. Showing a neutral placeholder is preferable to leaving the prior song's
  cover indefinitely.
- Async artwork results must still pass generation and current-track checks
  before applying. SB and Apple catalog artwork remain authoritative over web
  fallbacks.

## Diagnostics Gap

Owner reports can currently say "artwork not updated", but diagnostics do not
yet capture artwork source, cache key, generation, or apply/drop reason. If this
class of bug recurs, add artwork-specific diagnostics before guessing from
frame or lyrics events.
