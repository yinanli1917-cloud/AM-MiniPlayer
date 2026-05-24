# Music Queue Parity Matrix Run

created_utc: 20260524T023825Z

This runbook is for proving or rejecting exact Music.app queue parity through
public, App Store-safe surfaces. It does not change Music.app playback.

## Rule

Do not mark any context exact unless the visible Music.app Up Next/history rows
match the public probe output by order and identity. Probe output alone is not
proof.

## Commands

After manually setting up a context and opening Music.app's visible queue UI:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \
  --run-current \
  --session-dir ".codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z" \
  --context CONTEXT_LABEL
```

Optionally pass `--visible-notes FILE` if you already wrote notes or attached a
screenshot reference.

## Matrix

| Context | Manual setup | Exact proof required | Notes template |
| --- | --- | --- | --- |
| `album-playback` | Play an album from Music.app. | Probe rows must match visible Up Next order and identity. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-album-playback.md` |
| `user-playlist-playback` | Play a normal local/user playlist from Music.app. | Probe rows must match visible Up Next order and identity. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-user-playlist-playback.md` |
| `apple-music-playlist-playback` | Play an Apple Music playlist not owned by the user. | Probe rows must match visible Up Next order and identity. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-apple-music-playlist-playback.md` |
| `local-library-file-track` | Play an imported local file or normal library track. | Probe must not rely on unavailable private storage. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-local-library-file-track.md` |
| `radio-station-url-track` | Play an Apple Music station/radio item. | Probe must expose visible upcoming/history rows or mark unavailable. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-radio-station-url-track.md` |
| `play-next-play-later-edits` | Manually add at least two tracks using Music.app Play Next/Play Later. | Probe must reflect the edited visible queue order. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-play-next-play-later-edits.md` |
| `skip-previous-rapid-changes` | Use next/previous repeatedly after opening visible queue. | Probe must not lag or keep stale rows. | `.codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/visible-notes/visible-state-skip-previous-rapid-changes.md` |

## Rejected Sources

- private frameworks;
- private AppleEvents;
- Music.app private databases/files, including PlaybackSessions;
- Accessibility/UI scraping as a product queue source;
- memory inspection;
- Apple Music API recently played data as live local queue proof.
