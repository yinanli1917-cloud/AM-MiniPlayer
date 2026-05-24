# Music Queue SDK Surface Evidence

created_utc: 20260524T050239Z

SDK captures are supplemental evidence. They record public macOS SDK/API
availability only; they do not prove visible Music.app Up Next/history parity.

| Context | Classification | ApplicationMusicPlayer.queue | Queue insertion | SystemMusicPlayer | MPMusicPlayerController | MP app queue | MP system player | MPNowPlayingInfoCenter | Probe output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `sdk-current-state` | `application_player_queue_only_not_music_app_session` | `PASS` | `PASS` | `FAIL` | `FAIL` | `FAIL` | `FAIL` | `PASS` | `.codex/workspace/music-queue-probes/sdk-supplemental-smoke-20260524T050239Z/sdk-surface-sdk-current-state-20260524T050239Z.txt` |
