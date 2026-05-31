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

## Queue Provenance

- Queue rows must carry provenance separate from the row arrays. Empty rows can
  mean an exact empty queue, an unavailable public source, or an unproven
  playlist-context scan.
- `currentPlaylist.tracks` rows are `playlistContextOnly` until a recorded
  Music.app visible Up Next/history parity pass proves exact order and identity,
  including Play Next/Play Later edits.
- If Music.app exposes no public `current playlist` for a URL/radio/station
  track, mark the queue unavailable with the current track class instead of
  showing stale or guessed rows as Up Next.
- Apple Music API recently played data is account history support, not proof of
  the live Music.app queue/history session.
- Queue UI must only render row arrays as History/Up Next when provenance is
  `exactPublicMusicQueue` or `preview`. All other provenance states should show
  an unavailable state instead of rows, even if row arrays contain data.
- The published queue/history row arrays should also drop rows for
  non-displayable provenance. Keep raw non-exact row counts only as diagnostics
  metrics; do not retain playlist-context/account-history rows in long-lived
  UI state where they can look cacheable over week-long sessions.
- Production queue/history fetches should not materialize track row payloads
  from public sources already classified as non-displayable, such as
  `playlistContextOnly` or Apple Music account recently played. Use the probe
  harness for parity evidence collection; runtime should avoid hidden playlist
  scans or account-history fetches that cannot be displayed as the real queue.
- Diagnostics must distinguish retained row counts from raw public-surface row
  counts. For non-displayable provenance, retained rows should be zero while raw
  rows can record how many playlist-context/account-history rows the public
  source returned as evidence.
- Diagnostics should include the same concise unavailable reason used by the UI
  so report bundles explain why rows were withheld without requiring enum-label
  decoding.
- Queue unavailable states should include a concise provenance reason, such as
  a missing public Music.app queue for URL-track playback, playlist-context-only
  data, or Apple Music account history not being the live Music.app session.
- Any known queue-changing signal, including user playback controls,
  distributed Music.app `playerInfo` track-change notifications, externally
  observed track/source changes, and periodic Music.app queue-hash changes,
  must invalidate retained queue/history rows immediately and mark them as
  pending public refresh. Do not keep previously exact rows visible while the
  next public Music.app snapshot is still in flight.
- If the periodic queue-hash probe cannot reach its public Music.app queue
  proxy, clear retained queue/history rows to Music.app-unavailable and reset
  the queue-hash baseline. A hash from a recovered Music.app session must be
  treated as fresh evidence, not compared against stale pre-unavailable state.
- If the periodic queue-hash probe reaches Music.app but public state cannot
  expose the current track, current playlist, or playlist tracks, do not collapse
  that into the same bucket as an IPC timeout. Clear retained queue/history rows
  to the matching public unavailable reason and reset the queue-hash baseline;
  true timeout/unresolved probe ticks may preserve state for that cycle.
- When `connect()` finds that Music.app is not running and launches it, clear
  retained queue/history rows to pending public refresh before the delayed
  state/queue read. Also reset the queue-hash baseline so the relaunched
  Music.app session is treated as fresh public evidence.
- User controls that can advance or reorder Music.app playback must schedule a
  public queue refresh after the Music.app command returns, fails, or cannot
  reach Music.app. Guard those scheduled reads by the queue generation captured
  at invalidation time so a superseded command cannot refresh a newer queue
  state.
- Playlist row playback must only target non-empty hexadecimal Music.app
  `persistent ID` values from the public scripting dictionary. Reject Apple
  Music API/catalog IDs, placeholders, whitespace, and arbitrary strings so row
  actions cannot become app-local playback or malformed AppleScript targets.
- Observed track-change paths, including `playerInfo`, full-state sync, and
  radio/backstop fallback detection, must also schedule a generation-gated
  public queue refresh. If a newer track generation supersedes the scheduled
  read, the stale refresh must not run.
- Full-state sync must also treat same-track Music.app source-context changes
  as queue-affecting. If the track stays the same but public state reports a
  different playlist name, track class, or URL-track status, clear retained
  queue/history rows to pending public refresh and schedule a fresh public read.
- Async Up Next and recent-history snapshots must both be gated by queue and
  track generation before applying. A stale Apple Music API history response or
  stale ScriptingBridge playlist-context scan must not replace a newer pending,
  unavailable, or exact queue state. Capture both generations when scheduling
  the fetch; do not recapture track generation inside the async worker.
- Unavailable-state transitions must treat an in-flight queue fetch as unsettled
  even when rows are already empty and provenance already matches the same
  unavailable reason. Advance the queue generation so the older in-flight
  snapshot cannot apply after Music.app has become no-current or public-state
  unavailable.
- Coalesced pending queue refreshes must carry the queue and track generations
  captured when they were marked pending. Throttled delayed callbacks must
  consume the pending refresh only if those generations still match current
  state; stale pending refreshes must be discarded instead of recapturing a
  newer state.
- Playlist-open cache reuse must also be provenance-aware: hidden
  playlist-context/account-history rows do not count as visible queue data and
  must not suppress a fresh queue refresh attempt.
- Nearby artwork/lyrics preloading must also be provenance-aware. Over
  week-long companion sessions, unproven playlist-context or account-history
  rows must not pollute predictive caches as if they were real upcoming queue
  rows.
- Diagnostics report bundles must include stable Up Next/recent provenance,
  row counts, and whether each row set was displayable. This preserves
  long-running session evidence for queue-unavailable states without relying on
  transient UI screenshots.
- MusicKit `ApplicationMusicPlayer.queue` must not be treated as the live
  Music.app queue unless a visible parity pass proves it. The first focused
  runtime probe saw Music.app playing while `ApplicationMusicPlayer` reported
  `stopped`, `currentEntry=nil`, and `entries_count=0`, so current product code
  should treat that surface as app-local/unbound for queue parity. Apple's
  public documentation also describes application music players as not
  affecting Music.app state.
- Playlist row playback must also stay assistant-only. Do not use
  `ApplicationMusicPlayer` as a fallback for Apple Music API row IDs (`am:*`);
  those IDs come from account/catalog APIs, not from Music.app's current
  visible session. Row playback should only target Music.app through public
  Music.app control surfaces until an exact public route is proven.
- `SystemMusicPlayer` is the only MusicKit player conceptually aligned with
  controlling Music.app, but it is unavailable in the current local macOS SDK
  and Apple's documentation says it shares only some Music.app state. If a
  future SDK exposes it on macOS, require visible Up Next/history parity proof
  before using its queue.
- Public SDK availability must stay separate from queue parity proof. The
  standalone SDK probe can show that `ApplicationMusicPlayer.queue` and
  `MusicPlayer.Queue` insertion positions compile, but that only establishes API
  shape. It does not prove read parity, edit safety, or that the target queue is
  Music.app's visible Up Next/history session.
