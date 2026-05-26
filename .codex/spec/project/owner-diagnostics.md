# Owner Diagnostics

Owner diagnostics are local debug tooling for Codex-facing bug reports. They are
not public telemetry and should not be presented as release analytics.

## Product Boundary

- The owner diagnostics UI belongs behind debug/developer surfaces.
- Local developer bundles may expose it with the `LOCAL_DEVELOPER_BUILD`
  compile condition. Public release builds must not define that condition.
- Collection is opt-in, sticky once enabled, and local-only by default.
- Automatic incidents may be collected in the rolling local buffer, but export
  is always an explicit user action.
- The rolling local buffer must survive app restart within the same app build.
  Persist incidents, events, completed/interrupted interaction traces,
  line-motion samples, baseline values, and last warning/export references
  under local diagnostics state, and flush active traces before termination.
  Bind restored rolling state to the current app build signature; when the
  bundle changes, drop stale active counts so fixed historical incidents do not
  look like fresh regressions. Exported report bundles remain available.
- Public telemetry is separate scope and requires privacy review, explicit
  opt-in, user preview before sending, and no automatic upload.

## Report Model

Reports should separate user-visible symptoms from automatically detected
technical causes.

- User labels should describe what the owner can see: wrong lyrics, missing
  lyrics, resolver mismatch, timing off, stale lyrics, missing/wrong
  translation, slow loading, missing/late/stale artwork, interrupted switching
  animation, playback context mismatch, ScriptingBridge delay, high CPU,
  visible stutter, or other. Freeform manual-report notes may override the
  selected menu label when the note clearly names one of those symptoms.
- The app should attach hidden evidence itself: frame stalls, high CPU, memory
  spikes, ScriptingBridge latency/backlog/timeouts, fallback churn, and related
  incident metrics.
- Artwork reports need source/cache/generation evidence, not generic frame
  events. Record `artwork.fetch.start`, `artwork.cache.miss`, `artwork.apply`,
  `artwork.placeholder`, and `artwork.drop` with track context, generation,
  cache eligibility, source, apply time, placeholder reason, and drop reason so
  cover lag/blackout can be verified from the rolling state and daily brief.
- A retained-previous cover expiring into a current-track placeholder is a
  user-visible artwork failure, not just a debug event. Emit an
  `artworkBlocking` incident with the placeholder reason so missing/stale cover
  reports can be verified even when `currentArtwork` is non-nil.
- Retaining the previous cover on a cache miss is a handoff affordance, not a
  valid final state for the new track. Do not replace a retained real cover with
  a timer-driven placeholder while bounded Apple/web lanes are still running;
  that creates the visible black/empty flash immediately before a valid result
  lands. Only show a current-track placeholder after the bounded fetch/retry path
  has confirmed failure, and emit an `artworkBlocking` incident for that reason.
- Apple Music playback-session artwork is local filesystem/cache work and must
  not run on Swift's cooperative executor or behind stale serial file reads.
  Dispatch playback-session archive reads onto a dedicated concurrent utility
  queue, cache parsed artwork URLs briefly by title/artist/album/root, and poll
  briefly after a miss while retaining the previous cover. Once an exact Apple
  artwork URL is found, fetch that URL directly on the bounded artwork lane; do
  not block the visual switch path on MusicUIArtworkCache database/file reads.
  Music.app can write the playback-session archive shortly after the
  track-change notification; a single immediate scan misclassifies the local
  Apple cover as missing and makes the app fall through to placeholder/web
  paths.
- Playback-session archive matching should tolerate localized Apple Music
  metadata such as ASCII artist display names paired with CJK artist names in
  Music's cache. Use bounded Latinized token matching after exact title evidence;
  also match percent-encoded native titles inside Apple Music URLs. Do not scan
  unrelated private app state or weaken title identity.
- ScriptingBridge timeout guards must use explicit lanes that match one
  SBApplication proxy per operation family. Full player-state sync, queue
  snapshots, current-track metadata backfill, artwork extraction, and position
  polling must not share the default timeout lane. If full player-state sync
  times out, enter a short cooldown and use the bounded AppleScript snapshot
  fallback instead of retrying the same stuck ScriptingBridge lane every timer
  tick.
- Repeated ScriptingBridge latency/timeout incidents for the same operation
  should be coalesced into a burst record with occurrence count and max read /
  queue-wait metrics. This keeps the monitor readable while preserving the
  root-cause evidence.
- Process memory diagnostics must not use RSS alone as the pressure signal.
  RSS includes shared/read-only framework residency on macOS; keep it as
  evidence, but trigger memory incidents from physical footprint, with either
  high absolute footprint or sharp short-window growth. Repeated elevated
  samples should be coalesced into one burst with occurrence count, max RSS,
  max physical footprint, and growth evidence.
- Isolated ScriptingBridge reads below the severe standalone threshold
  (currently 1000ms) are baseline evidence, not monitor incidents, unless they
  overlap an active interaction trace or back up the queue. Low queue-wait reads
  around 100-900ms are expected Apple Event jitter and should not make the owner
  monitor look stuck.
- Lyrics-page motion diagnostics must sample rendered line geometry directly,
  not infer it only from playback time. Samples should include rendered and
  target positions, active/display/target indices, per-line velocity,
  inter-line spacing error, wave offset, playback time, and manual-scroll /
  initial-load suppression flags.
- Viewport-clip diagnostics must only classify the active line or rows that can
  actually affect the visible viewport. Sampled rows that are intentionally
  offscreen are baseline geometry, not visible clipping and not motion drift.
  When repeated line-clip incidents are coalesced, the burst label must remain a
  clipping label unless the merged metrics include real target/spacing drift or
  stale target evidence.
- Lyrics-page motion probes must not record diagnostics directly from every
  SwiftUI geometry preference update, and they must not keep per-line geometry
  readers active continuously. The bounded sampling clock should request a
  one-frame geometry capture only when a sample is due; recording happens from
  that capture. This keeps continuous monitoring from becoming the animation
  workload it is trying to measure.
- While the lyrics page is visible and diagnostics are enabled, line-motion
  tracking must keep a low-duty heartbeat instead of relying only on page-switch
  or track-switch windows. Near each lyric line boundary, sampling should
  temporarily use the focused interval so intermittent line-to-line animation
  drift is captured. Diagnostic `activeIndex` should be derived from playback
  time, not only from the UI's current displayed index, so a stuck highlighter
  or stale target can be detected as drift instead of hidden by its own state.
- Late wave-target detection must use elapsed wall-clock time since the UI first
  observed the active/display line state, not only `playbackTime - lineStart`.
  Seeking or skipping can land in the middle of a lyric line; that must not be
  reported as a several-second stuck animation unless the rendered target stays
  behind for the visual timeout after the switch is observed.
- Lyrics line-motion diagnostics must also detect lingering wave backlog: if
  the active/display state has been stable for roughly a second while four or
  more nearby rendered rows still target an older lyric index, report
  `lyricsLineMotion` even when `targetErrorY` and inter-line spacing are zero.
  Otherwise a visually delayed stagger can hide behind perfectly aligned
  geometry.
- Lyrics wave animation timing must be bounded by the current lyric line's
  timing window. Preserve the default AMLL-style stagger for long lines, but
  adapt the per-line delay downward for dense lyrics so one wave settles before
  the next line advance cancels it. Layout-settlement suppression must not
  disable an already-active wave animation.
- Frame-stall capture must not create a diagnostics feedback loop. Active
  interactions should summarize overlapping stalls in the interaction trace;
  standalone frame-stall incidents must be rate-limited instead of appended on
  every slow frame while the diagnostics window is visible.
- A few standalone warning-level frame intervals during idle playback are
  detector noise, not user-visible incidents. Record a standalone warning burst
  only after six stalls with the same page/window signature inside the
  coalescing window. Critical standalone bursts can surface after three
  occurrences, and a severe standalone hang (currently 500ms or higher) still
  records immediately. Preserve all frame-stall counts inside active interaction
  traces so user-visible switch/animation stalls are still captured.
- Standalone frame-stall incidents should ignore the short app/session startup
  settlement window, currently 5 seconds. Cold launch, rebuild relaunch, or diagnostics session
  initialization can produce an unscoped first-frame delay that should not count
  as a recurring user-visible interaction bug; stalls during active interactions
  must still be captured in the trace.
- Clearing diagnostics from the owner UI should suppress immediate standalone
  frame-stall noise from the clear/window-refresh action itself. The clear
  operation should leave a genuinely clean monitor unless a new issue occurs
  after that short UI-settlement window.
- High-frequency diagnostics buffers, especially lyrics line-motion samples,
  must not be published wholesale to SwiftUI debug panels. Keep the full sample
  buffer available for export, but expose only low-frequency summary values to
  the live diagnostics UI so opening the monitor cannot create its own CPU/stall
  feedback loop.
- Track metadata is acceptable in manual reports because wrong-lyrics and timing
  bugs need title, artist, album, duration, selected source, and timing context
  to reproduce.
- Manual reports and scoped diagnostics should include Music.app playback
  context when public Apple Events expose it: track class, current playlist
  name, inferred playback context, and nanoPod page. Public ScriptingBridge can
  distinguish library/shared/file/URL-track style state and current playlist
  name, but it cannot fully expose private Music.app navigation origins such as
  the exact search result page.
- Translation diagnostics must record coverage, not just a boolean. A source
  with some translated rows and missing visible rows should report translated
  line count, translatable line count, and missing translation count as a local
  event first. Do not create a user-visible partial-translation incident merely
  because the provider source is sparse; create the incident only after the
  system-fill path is requested and fails or is unavailable.
- Translation coverage is not enough to verify the visible UI. When translation
  display is enabled and visible neighboring lyric lines have translations, a
  current highlighted/displayed line with no translation must emit a
  `lyricsPartialTranslation` incident with display/active line index, visible
  translated/missing counts, playback time, and whether the line was excluded
  from aggregate coverage as a vocable/ad-lib. This catches "current line lacks
  translation" screenshots without requiring the owner to attach a screenshot.
- Translation manual reports must be able to distinguish three states:
  provider lyrics with source translations, provider lyrics that need system
  translation, and system translation skipped/failed. Record the target
  language and skip/failure reason, then clear the incident when system
  translation fills the same track.
- Manual reports must not preserve synthetic placeholder track metadata such as
  `Wrong Lyrics / Reporter / Debug` when recent credible app evidence exists.
  Resolve the report track from the latest credible event, incident, or
  interaction before exporting, and record evidence for the replacement source.
- Exported reports with a credible report track must scope track-bound lyrics
  motion samples, incidents, interactions, and line-motion baseline values to
  that track. Keep untracked system signals such as CPU and ScriptingBridge
  samples only when they are not tied to a different song.
- Artwork-stale reports are switch-bound and the useful evidence may belong to
  the outgoing or incoming track rather than the exact current report track. If
  exact-track artwork rows are absent, include recent `artwork.*` events and
  `artworkBlocking` incidents by report time, with an explicit fallback marker,
  instead of exporting a manual artwork report with no source/cache/apply
  evidence.
- Exported reports must not attach stale or unrelated debug logs from an older
  CLI or app session. App diagnostics debug logs belong under the diagnostics
  live directory; `/tmp/nanopod_debug.log` may be used by CLI verifier runs and
  must not be treated as report evidence for the app.
- A zero-candidate lyrics miss is an unresolved state, not automatically a
  regression. Surface it as an informational event, not an incident, unless
  rejected candidate evidence shows fallback churn.
- A lyrics miss where every foreground candidate is a terminal
  `instrumental`/`unavailable` candidate is pending authoritative availability
  classification, not fallback churn. Keep it as a local event and let
  authoritative backfill record the final unavailable/instrumental state.
- If foreground lyrics search records a rejected-candidate miss and background
  backfill later returns a low-confidence result for the same track, keep one
  fallback incident and attach the low-confidence evidence as an event instead
  of double-counting the same root cause.
- If foreground lyrics search records a zero-candidate unresolved entry and
  authoritative backfill later classifies the same track as instrumental or
  source-unavailable, retain an event instead. If authoritative backfill proves
  an instrumental track after a rejected-candidate miss, clear that miss because
  the source has proven there are no visible lyrics. Non-instrumental rejected
  misses must stay visible until the selector/source bug is resolved.
- Authoritative lyrics backfill must have its own diagnostics, not be hidden
  behind the foreground `lyrics.fetch.finish` duration. Record
  `lyrics.backfill.start` and `lyrics.backfill.finish` with foreground fetch
  seconds, backfill seconds, total resolver seconds, result, source, score, and
  line count. If backfill exceeds the slow threshold or foreground+backfill
  exceeds the visible resolver budget, emit a `lyricsSlowFetch` incident titled
  `Slow lyrics authoritative backfill`. Daily diagnostics must include this even
  when the foreground resolver was under 3s, because English-title CJK/native
  rescue can otherwise look fast in the monitor while the app keeps working for
  7-10 seconds in the background.
- Lyrics low-confidence diagnostics must stay aligned with the source-specific
  result-selection thresholds. Exact LRCLIB synced results with enough lyric
  lines can be trusted below the generic 30-point threshold, while weak sparse
  LRCLIB rows, unsynced results, and generic low-score sources should still
  surface as fallback churn.
- Authoritative instrumental classifications should clear same-track fallback
  incidents and then be cached as terminal availability. Trusted unavailable
  classifications may also be cached with a short TTL. Repeat visits should
  produce a fast availability event/state instead of another slow-fetch or
  fallback-churn monitor entry.
- A trusted successful lyrics result must also clear an earlier same-track
  fallback incident. Keep the cleanup visible as a local event so the monitor
  reflects the current state instead of showing an unresolved incident after a
  later `lyrics.fetch.finish` has selected high-confidence synced lyrics.
- Unit tests that export diagnostics bundles or live diagnostics CSVs must
  isolate storage under a temporary test directory. Tests must never pollute the
  owner's real `~/Library/Application Support/nanoPod/Diagnostics` folder.

## Diagnostics Review

- Daily diagnostics jobs must enumerate and read the latest local report bundles
  under `~/Library/Application Support/nanoPod/Diagnostics/Reports` before
  diagnosing. Treat unreadable reports as a capture/permission bug, not as "no
  data".
- Diagnostics jobs should state the model and reasoning configuration they are
  using. Owner-requested diagnostics should use the strongest available model
  profile unless explicitly overridden.

## Interaction Traces

- User-visible interactions with known motion windows should open a diagnostic
  trace while the motion is expected to run.
- Skip/previous replacement-flow animations, page switches, and lyrics refreshes
  should record start, expected duration, completion/interruption status, page,
  track context, lyrics workload context, and overlapping frame/CPU/bridge
  samples.
- If another interaction replaces a still-active animation, record the first
  trace as `interrupted` and create a local animation-incomplete incident.
- If a skip/previous replacement animation view disappears before its natural
  completion window, record the trace as `interrupted`. Track changes and lyrics
  loading may replace the control subtree; diagnostics must capture that as an
  incomplete visible animation instead of reporting a false completed state.
- If a completed interaction overlaps frame stalls, bridge delays, high CPU, or
  late completion, create a correlated local incident. Lyrics-page incidents
  should use a lyrics-page-specific category so they can be compared against
  album-page traces instead of treated as generic UI noise.
- A page switch into the lyrics page while lyrics are still an empty loading
  state (`lyricLineCount == 0`, no current active line) is not evidence of a
  broken lyric-line animation. Record it as a baseline loading-page-switch
  event unless it also overlaps bridge timeouts/backlog or high CPU.
- Standalone ScriptingBridge slow reads are baseline evidence until they either
  overlap an active interaction, back up the queue, time out, or cross a severe
  threshold. Local playback interpolation preserves lyric timing across
  isolated position-poll hiccups, and isolated subsecond full-state reads also
  must not refill the incident monitor without user-visible correlation.
- Repeated `pollPositionViaSB` timeouts are a lane-health problem, not a reason
  to keep hammering Music.app every timer tick. Position polling must enter
  progressive cooldown after timeouts and use a bounded AppleScript state
  fallback at a low rate; local playback interpolation should keep lyrics moving
  while the ScriptingBridge position lane recovers.
- Low-context standalone frame-stall ticks must not be allowed to fill the
  incident buffer. Coalesce repeated standalone stalls by page and short time
  window into a burst incident that preserves occurrence count, max interval,
  and page signature while leaving correlated interaction incidents intact.
- Repeated lyrics line-motion drift incidents must also be coalesced by track
  into burst incidents that preserve occurrence count and max error metrics.
  Do not present dozens of same-track motion samples as separate root causes.
- SwiftUI render paths must not perform NaturalLanguage detection or other
  heavyweight analysis per lyric line. Compute translation availability when
  lyrics or target language changes, then expose a cached boolean to the view.
- High-CPU incidents should report the peak recent CPU that caused the alert as
  `cpuPercent`/`maxRecentCPUPercent`, and keep the triggering sample separately
  as `currentCPUPercent` when those differ.
- Trace details belong in exported `report.json`, `summary.md`, and performance
  samples; they are still local-only until manually exported.

## Live Local Artifacts

- Codex/background diagnosis should read exported bundles directly from
  `~/Library/Application Support/nanoPod/Diagnostics/Reports`.
- While diagnostics are enabled, lyrics line-motion samples are also appended to
  `~/Library/Application Support/nanoPod/Diagnostics/Live/lyrics_line_motion_samples.csv`
  so motion latency can be inspected without waiting for a manual export.
  Repair or normalize this live CSV once at session start, not on every append;
  append-time work must stay O(new samples), not O(full file).
- While diagnostics are enabled, the rolling in-app diagnostics buffer is also
  snapshotted to
  `~/Library/Application Support/nanoPod/Diagnostics/State/rolling_state.json`
  so rebuilds and restarts do not erase unexported evidence.
- `Clear Diagnostics` must clear both the rolling in-app snapshot and the live
  line-motion CSV. Otherwise old motion samples survive a clear and make the
  diagnostics monitor look like already-fixed incidents are still recurring.
  Exported report bundles are retained until explicitly deleted.
- Exported report bundles must include the same line-motion data in
  `report.json`, `summary.md`, and `lyrics_line_motion_samples.csv`.
- Motion/stutter reports are allowed to fall back to recent lyrics-page
  line-motion samples by report time when exact current-track samples are
  absent. This covers next/previous track switches where the visible broken
  animation still belongs to the outgoing track. Non-motion reports such as
  wrong-lyrics or missing-lyrics must keep strict track scoping so unrelated
  old samples do not contaminate the bundle.
- Manual symptom selection should expose the recurring user-visible categories
  directly, including missing translation, resolver mismatch, ScriptingBridge
  delay, playback context wrong, artwork stale after switching, animation
  interrupted, and blackout during switching. When the owner types a note before
  manually choosing a different symptom, diagnostics may infer and select the
  matching category so reports are not silently stored as the default
  `wrong lyrics` bucket.
- A blackout-during-switching report is both a motion report and an artwork
  report for export scoping: include recent lyrics line-motion samples and
  artwork apply/drop/cache evidence by report time when exact current-track rows
  are absent, and mark both fallbacks explicitly.

## Retention And Media

- Keep a short rolling local buffer, currently the last three sessions or 24
  hours, whichever is smaller.
- Exported reports remain until the owner deletes them.
- Do not capture screenshots or recordings automatically. Media enters reports
  only through explicit manual attachment.
