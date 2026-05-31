# Music Queue SDK Surface Evidence

created_utc: 20260531T102123Z

SDK captures are supplemental evidence. They record public macOS SDK/API
availability only; they do not prove visible Music.app Up Next/history parity.

| Context | Classification | ApplicationMusicPlayer.queue | Queue insertion | SystemMusicPlayer | MPMusicPlayerController | MP app queue | MP system player | MPNowPlayingInfoCenter | Probe output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `sdk-refresh-20260531` | `application_player_queue_only_not_music_app_session` | `PASS` | `PASS` | `FAIL` | `FAIL` | `FAIL` | `FAIL` | `PASS` | `.codex/workspace/music-queue-probes/sdk-refresh-20260531/sdk-surface-sdk-refresh-20260531-20260531T102123Z.txt` |
