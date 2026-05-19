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
- Track metadata is acceptable in manual reports because wrong-lyrics and timing
  bugs need title, artist, album, duration, selected source, and timing context
  to reproduce.
- Manual reports must not preserve synthetic placeholder track metadata such as
  `Wrong Lyrics / Reporter / Debug` when recent credible app evidence exists.
  Resolve the report track from the latest credible event, incident, or
  interaction before exporting, and record evidence for the replacement source.

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
- Trace details belong in exported `report.json`, `summary.md`, and performance
  samples; they are still local-only until manually exported.

## Live Local Artifacts

- Codex/background diagnosis should read exported bundles directly from
  `~/Library/Application Support/nanoPod/Diagnostics/Reports`.
- While diagnostics are enabled, lyrics line-motion samples are also appended to
  `~/Library/Application Support/nanoPod/Diagnostics/Live/lyrics_line_motion_samples.csv`
  so motion latency can be inspected without waiting for a manual export.
- Exported report bundles must include the same line-motion data in
  `report.json`, `summary.md`, and `lyrics_line_motion_samples.csv`.

## Retention And Media

- Keep a short rolling local buffer, currently the last three sessions or 24
  hours, whichever is smaller.
- Exported reports remain until the owner deletes them.
- Do not capture screenshots or recordings automatically. Media enters reports
  only through explicit manual attachment.
