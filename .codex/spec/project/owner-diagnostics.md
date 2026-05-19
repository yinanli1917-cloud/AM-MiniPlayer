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
- Track metadata is acceptable in manual reports because wrong-lyrics and timing
  bugs need title, artist, album, duration, selected source, and timing context
  to reproduce.

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

## Retention And Media

- Keep a short rolling local buffer, currently the last three sessions or 24
  hours, whichever is smaller.
- Exported reports remain until the owner deletes them.
- Do not capture screenshots or recordings automatically. Media enters reports
  only through explicit manual attachment.
