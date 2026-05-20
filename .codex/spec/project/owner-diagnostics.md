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

- User labels should describe what the owner can see: wrong lyrics, timing off,
  stale lyrics, translation wrong, slow loading, visible stutter, or other.
- The app should attach hidden evidence itself: frame stalls, high CPU, memory
  spikes, ScriptingBridge latency/backlog/timeouts, fallback churn, and related
  incident metrics.
- Lyrics-page motion diagnostics must sample rendered line geometry directly,
  not infer it only from playback time. Samples should include rendered and
  target positions, active/display/target indices, per-line velocity,
  inter-line spacing error, wave offset, playback time, and manual-scroll /
  initial-load suppression flags.
- Lyrics-page motion probes must not record diagnostics directly from every
  SwiftUI geometry preference update. Preference updates may cache the latest
  frames, but actual recording belongs on the bounded sampling clock so the
  diagnostics verifier cannot add main-thread work during the animation it is
  measuring.
- Late wave-target detection must use elapsed wall-clock time since the UI first
  observed the active/display line state, not only `playbackTime - lineStart`.
  Seeking or skipping can land in the middle of a lyric line; that must not be
  reported as a several-second stuck animation unless the rendered target stays
  behind for the visual timeout after the switch is observed.
- Frame-stall capture must not create a diagnostics feedback loop. Active
  interactions should summarize overlapping stalls in the interaction trace;
  standalone frame-stall incidents must be rate-limited instead of appended on
  every slow frame while the diagnostics window is visible.
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
- Translation diagnostics must record coverage, not just a boolean. A source
  with some translated rows and missing visible rows should report translated
  line count, translatable line count, missing translation count, and a partial
  translation incident when translation display was requested.
- Manual reports must not preserve synthetic placeholder track metadata such as
  `Wrong Lyrics / Reporter / Debug` when recent credible app evidence exists.
  Resolve the report track from the latest credible event, incident, or
  interaction before exporting, and record evidence for the replacement source.
- Exported reports with a credible report track must scope track-bound lyrics
  motion samples, incidents, interactions, and line-motion baseline values to
  that track. Keep untracked system signals such as CPU and ScriptingBridge
  samples only when they are not tied to a different song.
- Exported reports must not attach stale `/tmp/nanopod_debug.log` content from
  an older CLI or app session. Attach the debug log only when it was modified
  during the current diagnostics session.
- A zero-candidate lyrics miss is an unresolved state, not automatically a
  regression. Surface it as informational diagnostics unless rejected candidate
  evidence shows fallback churn.
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
- If a completed interaction overlaps frame stalls, bridge delays, high CPU, or
  late completion, create a correlated local incident. Lyrics-page incidents
  should use a lyrics-page-specific category so they can be compared against
  album-page traces instead of treated as generic UI noise.
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

## Retention And Media

- Keep a short rolling local buffer, currently the last three sessions or 24
  hours, whichever is smaller.
- Exported reports remain until the owner deletes them.
- Do not capture screenshots or recordings automatically. Media enters reports
  only through explicit manual attachment.
