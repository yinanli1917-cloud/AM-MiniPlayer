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
- Implemented playback for Apple Music API recent-history rows by routing `am:` IDs through MusicKit `ApplicationMusicPlayer`; local Music.app rows still use persistent-ID AppleScript playback.
- Pushed one retained source performance fix in `bad9f22 perf: stabilize lyric renderer timing updates`.
- Added `nanopod://page/{album,lyrics,playlist}` plus `scripts/perf_harness.py --page` so lyrics-page measurements no longer depend on album-page state or blocked assistive clicking.
- Documented rejected experiments so they are not repeated blindly:
  - cached `@State Text` / syllable text experiment regressed rapid switching.
  - artwork matching input precompute regressed live rapid switching.
  - cancellable artwork preload ownership regressed live rapid switching.
- Rebuilt and relaunched the app after reverting failed experiments.

In progress:

- Daily-use CPU still reproduces high load on lyrics playback and rapid switching.
- Word-level and line-synced lyrics must be measured separately.
- Latest forced lyrics-page translated settled baseline is acceptable: `tmp/perf/perf-20260503-225431.csv` avg 22.48%, p95 24.8%, max 26.3.
- Latest forced lyrics-page rapid-switch baseline is still not acceptable: `tmp/perf/perf-20260503-225611-trials.json` median avg 42.39%, p95 80.8%, max 119.9, with all 20/20 skips completed.
- Latest rapid-switch sample `tmp/perf/sample-20260503-225633.txt` points at RenderBox/CoreGraphics glyph drawing, SwiftUI display-list/clip/geometry work, and residual nearby artwork/lyrics preload work.
- Passive preload signposts are now available in the source and built app. Logging trace `tmp/perf/nanopod-preload-logging-20260503-2312.trace` confirmed nearby preload still fires during rapid switching, with NetEase artwork spans around 0.54-1.27s and lyrics preload fetch spans up to about 1.93s.
- A cancellable artwork-preload ownership experiment was tested after that trace and reverted before commit because `tmp/perf/perf-20260503-232041-trials.json` regressed to median avg 62.54%, p95 116.1%, max 134.9.
- Lyrics-page visual baseline now exists through Computer Use screenshots, but word-level visual parity still needs a same-track before/after recording before protected renderer changes.

Not done:

- No protected lyrics layout or animation change should be made until the user explicitly approves the exact experiment and before/after lyrics-page visual evidence is captured.
- The Codex harness should still be monitored during long-running work, but the active task resolver currently verifies cleanly.

## Harness State

Current evidence:

- `python3 scripts/codex_harness.py context` finds the active task and prints its PRD/context manifests.
- `python3 scripts/codex_harness.py task current` reports `.codex/tasks/05-03-daily-use-cpu-and-rapid-switch-performance`.
- `python3 scripts/codex_harness.py health` passes generic project checks.
- `python3 .codex/hooks/inject-workflow-state.py` reports the same active `in_progress` task.
- `python3 /Users/yinanli/.codex/harness/bin/resolve_codex_state.py --cwd /Users/yinanli/Documents/MusicMiniPlayer --pretty` reports `confidence: verified`.
- Global backlog refresh works when the harness is allowed to write under `/Users/yinanli/.codex/harness/backlog`; after refresh, `context` reports `global_backlog: fresh`.

## Decisions

- App Store-compliant recent history should prefer Apple Music API when authorized.
- Live Music.app Up Next mirroring has no confirmed public reviewed API. Current implementation must keep ScriptingBridge bounded and have a fallback that only shows queues nanoPod creates or controls through approved APIs if review requires it.
- Album-page visual preservation does not prove lyrics-page preservation.
- Protected lyrics surfaces include `LyricsView.swift`, `LyricLineView.swift`, word-level timing/rendering, translation sweep, spacing, blur, wave/interlude animation, scroll behavior, and page transitions.
- Failed performance experiments must stay documented in `docs/performance_audit_2026-05-03.md` before any similar attempt is retried.

## Next Actions

1. Commit this handoff, the active PRD update, and the task context manifest updates.
2. Ask for explicit approval before touching protected lyrics rendering.
3. Capture a word-level lyrics baseline using `scripts/perf_harness.py --page lyrics`; the current fresh baseline is translated line-synced, not word-level.
4. Use the new preload signposts to test a narrower cancellation/concurrency change for nearby preloads during skip bursts.
5. Only after the preload lane is exhausted, test a narrow protected renderer experiment, likely around fade-mask / clipping / display-list invalidation, and keep it only if CPU improves without visual regression.

## Verified Commands

- `python3 scripts/codex_harness.py context`
- `python3 scripts/codex_harness.py task current`
- `python3 scripts/codex_harness.py health`
- `python3 .codex/hooks/inject-workflow-state.py`
- `python3 /Users/yinanli/.codex/harness/bin/resolve_codex_state.py --cwd /Users/yinanli/Documents/MusicMiniPlayer --pretty`
- `swift build`
- `swift test --filter RapidSwitchTests`
- `./build_app.sh`
- `python3 scripts/perf_harness.py --help`
- `python3 scripts/perf_harness.py --page lyrics --duration 12 --warmup 2 --interval 0.2 --stack-sample --require-music-playing`
- `python3 scripts/perf_harness.py --page lyrics --duration 20 --warmup 2 --interval 0.2 --skip-count 20 --skip-interval 0.2 --trials 3 --trial-gap 2 --require-music-playing`
- `python3 scripts/perf_harness.py --page lyrics --duration 20 --warmup 2 --interval 0.2 --skip-count 20 --skip-interval 0.2 --stack-sample --require-music-playing`
- `python3 /Users/yinanli/.codex/skills/swiftui-expert-skill/scripts/record_trace.py --attach nanoPod --template Logging --time-limit 22s --output /Users/yinanli/Documents/MusicMiniPlayer/tmp/perf/nanopod-preload-logging-20260503-2312.trace`
- `python3 /Users/yinanli/.codex/skills/swiftui-expert-skill/scripts/analyze_trace.py --trace /Users/yinanli/Documents/MusicMiniPlayer/tmp/perf/nanopod-preload-logging-20260503-2312.trace --list-signposts --signpost-name-contains Preload`
- `python3 /Users/yinanli/.codex/skills/swiftui-expert-skill/scripts/analyze_trace.py --trace /Users/yinanli/Documents/MusicMiniPlayer/tmp/perf/nanopod-preload-logging-20260503-2312.trace --list-signposts --signpost-name-contains Artwork`
- `scripts/perf_harness.py` runs recorded under `tmp/perf/` and summarized in `docs/performance_audit_2026-05-03.md`

## Related Files

- `.codex/tasks/05-03-daily-use-cpu-and-rapid-switch-performance/prd.md`
- `docs/performance_audit_2026-05-03.md`
- `docs/lyrics_rendering_performance_plan.md`
- `docs/apple_music_access_compliance.md`
- `scripts/perf_harness.py`
- `Sources/MusicMiniPlayerCore/UI/LyricsView.swift`
- `Sources/MusicMiniPlayerCore/UI/LyricLineView.swift`
