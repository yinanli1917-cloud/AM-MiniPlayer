# Daily-use CPU and rapid-switch performance

## Goal

Make NanoPod feel measurably lighter during real daily use, especially:

- App open on the lyrics page while music is playing.
- Plain/line-synced lyrics and word-level lyrics measured separately.
- Rapidly switching tracks, including word-level lyrics tracks.
- Settled playback after switching stops.

The work must preserve lyric UX, layout, transitions, word-level animation, and playlist behavior. Any protected lyric-rendering change must follow `docs/lyrics_rendering_performance_plan.md`.

This task is also the continuation point for Apple Music playlist/recent-history/up-next compliance research. That work is documented in `docs/apple_music_access_compliance.md` and must stay connected to the performance roadmap because queue/history data is the approved path for preloading artwork and lyrics before the user sees a song.

## Current Status

- Compliance research has a durable document: `docs/apple_music_access_compliance.md`.
- Lyrics rendering guardrails have a durable document: `docs/lyrics_rendering_performance_plan.md`.
- Performance evidence and rejected experiments have a durable document: `docs/performance_audit_2026-05-03.md`.
- One source fix was kept and pushed: `bad9f22 perf: stabilize lyric renderer timing updates`.
- Daily-use CPU remains above target on lyrics playback, especially word-level lyrics and rapid switching.
- Album-page visual checks are not enough. Lyrics-page preservation needs its own before/after evidence before any protected lyric-surface experiment can be kept.
- Harness is taking effect: context/task/health commands work, the workflow-state hook reports this active `in_progress` task, the state resolver reports `confidence: verified`, and global backlog refresh reports fresh after being allowed to write under `/Users/yinanli/.codex/harness/backlog`.
- `nanopod://page/{album,lyrics,playlist}` and `scripts/perf_harness.py --page lyrics` now provide a reliable lyrics-page measurement entry point.
- Latest forced translated lyrics-page settled baseline: `tmp/perf/perf-20260503-225431.csv` avg 22.48%, p95 24.8%, max 26.3.
- Latest forced translated lyrics-page rapid-switch baseline: `tmp/perf/perf-20260503-225611-trials.json` median avg 42.39%, p95 80.8%, max 119.9; stack sample `tmp/perf/sample-20260503-225633.txt` measured avg 54.95%, p95 132.0%, max 139.9.
- Passive preload signposts now identify nearby preload timing without touching protected lyrics UI. Logging trace `tmp/perf/nanopod-preload-logging-20260503-2312.trace` confirmed nearby preload still fires during rapid switching; NetEase artwork spans were roughly 0.54-1.27s and lyrics preload fetch spans reached about 1.93s.

## Acceptance Criteria

- [ ] Capture fresh baseline numbers for settled playback and async rapid switching on the current branch.
- [ ] Split all lyrics-page metrics into plain/line-synced and word-level workloads.
- [ ] Use `scripts/perf_harness.py --page lyrics` for lyrics-page gates.
- [ ] Identify one concrete current hot path from stack sampling or Instruments, not old audit memory.
- [ ] Use Logging-template Instruments traces for preload signposts; SwiftUI-template trace export did not expose signposts in the latest run.
- [ ] Implement only a narrowly scoped change tied to that hot path.
- [ ] Verify `swift build`.
- [ ] Verify performance with `scripts/perf_harness.py` before/after.
- [ ] If lyric rendering is touched, capture visual parity evidence per `docs/lyrics_rendering_performance_plan.md`.
- [ ] Treat album-page UX evidence as insufficient for lyric-rendering changes; capture lyrics-page screenshots or recordings before and after.
- [ ] Preserve word-level lyric animation, line spacing, translation layout, interlude behavior, scroll position behavior, and rapid page/song-switch transitions.
- [ ] Keep playlist/recent-history/up-next compliance decisions linked to `docs/apple_music_access_compliance.md`.
- [ ] Maintain a root `HANDOFF.md` until this performance/compliance loop is complete.
- [ ] Document the before/after results in `docs/performance_audit_2026-05-03.md`.
- [ ] Commit only if the change improves daily-use CPU without p95/max regression or UX damage.

## Continuation Roadmap

1. Stabilize project state:
   - keep `HANDOFF.md` current;
   - keep using harness context/health/resolver checks during long-running work;
   - avoid staging generated app bundles, caches, or temporary profiler artifacts.
2. Establish lyrics-page proof:
   - capture a line-synced lyrics baseline;
   - capture a word-level lyrics baseline;
   - record visual evidence for the exact lyrics page, not just album page.
3. Optimize only from fresh evidence:
   - sample the current app under rapid switching;
   - use preload/artwork/lyrics signposts when the suspected hot path is nearby preloading;
   - choose one hot path;
   - patch narrowly;
   - revert and document if median, p95, max, or UX regress.
4. Use compliant queue/history data for preloading:
   - prefer Apple Music API recent history when authorized;
   - keep live Up Next ScriptingBridge access bounded;
   - preserve an App Review fallback that only exposes queues nanoPod creates or controls through approved APIs.

## Notes

- User approved pushing and continuing performance work on 2026-05-03 after noting CPU still skyrockets in daily NanoPod use.
- Current pushed branch: `codex/performance-playlist-compliance-review`.
- Latest known rapid-switch result: median avg `47.28%`, p95 `93.3%`, max `119.5%`.
- Latest sample points to SwiftUI/CoreAnimation display-list and glyph rendering.
- 2026-05-03 live word-level lyrics no-skip measurement still reproduces high CPU after the first renderer fix: `tmp/perf/perf-20260503-203254.csv` avg `40.91%`, p95 `53.4%`, max `56.6%`; sample `tmp/perf/sample-20260503-203254.txt` still points at `LyricsTextRenderer` glyph/display-list drawing.
- User explicitly clarified that both line-synced and word-level lyrics must be optimized and should outperform Apple Music.
