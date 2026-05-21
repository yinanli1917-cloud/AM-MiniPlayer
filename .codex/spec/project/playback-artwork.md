# Playback Artwork

Current-track artwork should prefer speed, but must never leave a visibly stale
cover on a new track.

## Cache Rules

- Persistent library tracks may cache artwork by non-empty `persistentID`.
- Before ScriptingBridge backfills `persistentID`, current-track artwork may use
  a metadata cache key of normalized title, artist, and non-empty album.
- Apple Music subscription songs may present as URL tracks through
  ScriptingBridge. They may still use the title/artist/album metadata cache
  because the album disambiguates the song and restores instant artwork on
  rapid switching.
- For Apple Music subscription songs, ScriptingBridge `currentTrack.artworks`
  can be empty while Music.app already displays artwork from its playback
  session and UI artwork cache. Prefer the playback-session `mzstatic` URL and
  read `~/Library/Caches/com.apple.Music/MusicUIArtworkCache` by exact URL
  before issuing a network request. This is the correct local source for the
  artwork Music.app is already showing.
- Apple-authoritative artwork from ScriptingBridge, MusicKit, iTunes Search, or
  the playback-session/UI-cache path should be persisted into nanoPod's own
  `Application Support/nanoPod/ArtworkCache` by persistent ID and by the
  album-disambiguated metadata key. On restart or rebuild, check this disk cache
  before async fetches so previously seen tracks do not briefly black out while
  local Apple caches or web fallbacks warm up.
- Do not scan Apple Music's `SubscriptionPlayCache` on app startup or on the
  interactive artwork-fetch path. Parsing local `.m4p` metadata with
  AVFoundation is too expensive for track switches and can starve the UI even
  when CPU looks like the only visible symptom. If this source is reintroduced,
  it must be pre-indexed off the critical path with a strict file/time budget,
  persisted results, and diagnostics proving it cannot run during a switch.
- URL/radio tracks must not use a title/artist-only cache key. Those metadata
  fields can be reused by stations and cause stale covers.

## Track Switch Behavior

- On a new-track artwork request, cache hits may apply immediately.
- On cache miss, retain the previous `currentArtwork` while async SB/API fetches
  run. Do not drop to a black/empty background during the switch. If the current
  generation exhausts its fetch/retry path without applying artwork, replace the
  retained previous cover with the neutral placeholder.
- Async artwork results must still pass generation and current-track checks
  before applying. SB and Apple catalog artwork remain authoritative over web
  fallbacks.
- Playback-session artwork URL parsing must stop at the concrete image variant
  (`800x800bb.jpg`, `*.heic`, etc.) or the `{w}x{h}bb.{f}` template. The
  decompressed playback-session files contain binary bytes after strings; a
  whitespace-only URL regex can swallow that tail and force a slower web
  fallback.
- Playback-session metadata matching must not normalize the entire binary
  playback-session payload. Match bounded text fields by case/diacritic
  insensitive substring checks, then normalize only the small needle variants.
  Whole-blob normalization is slow enough to lose the race to web fallback and
  makes Music's already-local artwork look one track late.

## ScriptingBridge Lanes

- Lightweight playback-position polling must use its own `SBApplication`, serial
  queue, and timeout-runner lane. Lyrics timing depends on position updates not
  waiting behind playlist scans, metadata backfills, or artwork extraction.
- Heavyweight playlist/current-track/artwork ScriptingBridge reads may remain
  serial within their own proxy lane, but a hang in one lane must not starve an
  independent proxy lane.
- After a position-poll timeout, skip a short cooldown window and preserve the
  local interpolation clock. Do not substitute zero position/state values.

## Diagnostics

Artwork diagnostics must record the fetch generation, whether persistentID and
metadata-cache paths were available, whether previous artwork was retained,
cache miss/hit behavior, apply source, apply time, and drop reason. Slow
same-generation apply work should surface as `artworkBlocking`; stale async
results should remain `artwork.drop` events with the reason instead of silently
disappearing from the evidence trail.

Manual artwork-stale reports should export exact-track artwork evidence when it
exists. When a switch makes the relevant artwork event belong to the outgoing or
incoming track, report export may include recent artwork events/incidents by
time, but it must mark that fallback explicitly so the daily brief can separate
track-scoped evidence from switch-window evidence.

Manual blackout-during-switching reports should use the same artwork time
fallback because a temporary black background is usually a failed retain/apply
window, even when the active track has already advanced.
