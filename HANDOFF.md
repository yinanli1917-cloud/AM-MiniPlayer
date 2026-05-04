# nanoPod Performance Handoff

Updated: 2026-05-03 22:43 PDT

## Current Task

Active Codex task: `.codex/tasks/05-03-daily-use-cpu-and-rapid-switch-performance`

Goal: reduce daily-use CPU during lyrics playback and rapid song switching while preserving the existing lyrics UX, word-level animation, page transitions, playlist behavior, and App Store compliance.

Resume method:

1. Run `python3 scripts/codex_harness.py context`.
2. Read this file, the active task PRD, `docs/performance_audit_2026-05-03.md`, `docs/lyrics_rendering_performance_plan.md`, and `docs/apple_music_access_compliance.md`.
3. Run `python3 scripts/codex_harness.py health` before claiming completion.

## Completion State

Done:

- Created and pushed branch `codex/performance-playlist-compliance-review`.
- Researched Apple Music / MusicKit compliance for playlist, recent-history, and up-next behavior.
- Documented the compliance result in `docs/apple_music_access_compliance.md`.
- Pushed one retained source performance fix in `bad9f22 perf: stabilize lyric renderer timing updates`.
- Documented rejected experiments so they are not repeated blindly:
  - cached `@State Text` / syllable text experiment regressed rapid switching.
  - artwork matching input precompute regressed live rapid switching.
- Rebuilt and relaunched the app after reverting failed experiments.

In progress:

- Daily-use CPU still reproduces high load on lyrics playback and rapid switching.
- Word-level and line-synced lyrics must be measured separately.
- Remaining sampled hot path points at SwiftUI/CoreAnimation display-list, text/glyph drawing, clipping, and fade-mask work around lyrics rendering.
- Lyrics-page visual parity is not yet documented with the same strength as album-page UX preservation.

Not done:

- No protected lyrics layout or animation change should be made until the user explicitly approves the exact experiment and before/after lyrics-page visual evidence is captured.
- The Codex harness has a state mismatch: `scripts/codex_harness.py task current` reports an active task, while `.codex/workflow.md` still contains a static `no_task` block.
- Global backlog refresh currently fails inside `/Users/yinanli/.codex/harness/bin/init_global_backlog.py`.

## Harness State

Current evidence:

- `python3 scripts/codex_harness.py context` finds the active task and prints its PRD/context manifests.
- `python3 scripts/codex_harness.py task current` reports `.codex/tasks/05-03-daily-use-cpu-and-rapid-switch-performance`.
- `python3 scripts/codex_harness.py health` passes generic project checks.
- The harness is taking effect as a pull-based context layer, but the workflow-state and global backlog failures must be fixed before calling it fully healthy.

## Decisions

- App Store-compliant recent history should prefer Apple Music API when authorized.
- Live Music.app Up Next mirroring has no confirmed public reviewed API. Current implementation must keep ScriptingBridge bounded and have a fallback that only shows queues nanoPod creates or controls through approved APIs if review requires it.
- Album-page visual preservation does not prove lyrics-page preservation.
- Protected lyrics surfaces include `LyricsView.swift`, `LyricLineView.swift`, word-level timing/rendering, translation sweep, spacing, blur, wave/interlude animation, scroll behavior, and page transitions.
- Failed performance experiments must stay documented in `docs/performance_audit_2026-05-03.md` before any similar attempt is retried.

## Next Actions

1. Commit this handoff, the active PRD update, and the task context manifest updates.
2. Fix or document the harness state mismatch and global backlog failure.
3. Ask for explicit approval before touching protected lyrics rendering.
4. Capture lyrics-page baseline visual evidence and CPU evidence for both line-synced and word-level workloads.
5. Only then test a narrow protected experiment, likely around fade-mask / clipping / display-list invalidation, and keep it only if CPU improves without visual regression.

## Verified Commands

- `python3 scripts/codex_harness.py context`
- `python3 scripts/codex_harness.py task current`
- `python3 scripts/codex_harness.py health`
- `swift build`
- `swift test --filter RapidSwitchTests`
- `./build_app.sh`
- `scripts/perf_harness.py` runs recorded under `tmp/perf/` and summarized in `docs/performance_audit_2026-05-03.md`

## Related Files

- `.codex/tasks/05-03-daily-use-cpu-and-rapid-switch-performance/prd.md`
- `docs/performance_audit_2026-05-03.md`
- `docs/lyrics_rendering_performance_plan.md`
- `docs/apple_music_access_compliance.md`
- `scripts/perf_harness.py`
- `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricLineView.swift`
