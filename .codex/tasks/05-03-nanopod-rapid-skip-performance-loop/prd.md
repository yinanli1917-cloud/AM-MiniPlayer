# nanoPod rapid-skip lyrics performance loop

## Goal

Continue the active `Optimize playback performance` Codex thread for MusicMiniPlayer/nanoPod without losing its measured evidence. The immediate product goal is to reduce the remaining rapid-skip CPU spikes on the lyrics page while preserving lyric animation/layout parity and App Store-safe Apple Music behavior.

## Acceptance Criteria

- [ ] Treat `docs/performance_audit_2026-05-03.md` as the current truth source before changing performance code.
- [ ] Do not repeat the failed foreground lyric-fetch debounce, low-cost lyric renderer, or throttled controls experiments unless new lower-level evidence justifies it.
- [ ] Add or use direct evidence for the lyrics-page rapid-skip path, especially signposts/samples around lyrics apply, artwork apply, page redraw, and non-lyric overlay invalidation.
- [ ] Preserve lyric animation/layout visual parity; renderer or cadence changes need visual comparison proof before they are kept.
- [ ] Reduce or explicitly defer the remaining SwiftUI rendering/invalidation/fetch-apply contention gap.
- [ ] Coordinate with the active heartbeat automation `continue-nanopod-performance-loop` so duplicate Codex sessions do not make contradictory commits.
- [ ] Run the project harness health check and the relevant build/performance checks before completion, then record measurements in the audit doc or task journal.

## Notes

Promoted from global backlog, Codex automation registry, `session_index.jsonl`, and the visible active Codex window on 2026-05-03. The active heartbeat points to thread `019deca1-7a40-7990-b700-62149c7f7600` named `Optimize playback performance`.
