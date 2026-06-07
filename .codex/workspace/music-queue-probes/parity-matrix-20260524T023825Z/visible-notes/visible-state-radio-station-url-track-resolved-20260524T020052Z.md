# Visible Music.app Queue Notes

context_label: radio-station-url-track
created_utc: 20260524T020052Z
manual_outcome: unavailable

## Manual Setup

- Required setup: Play an Apple Music station/radio item.
- Expected proof: Probe must expose visible upcoming/history rows or mark unavailable.
- Music.app visible Up Next/history UI open: yes
- Playback source visible in Music.app: From 李翊楠's Station
- Current visible track: 為何又是這樣錯 / Sammi Cheng / Language of Life
- Manual Play Next/Play Later edits present: no

## Visible Rows

Record exact visible row order from Music.app. Include title, artist, album when
visible, and whether each row is history/current/upcoming.

```text
current | 為何又是這樣錯 | Sammi Cheng | Language of Life
upcoming | Jailbird | Cass Phang | Jailbird
section | Continue Playing | From 李翊楠's Station
upcoming | 愛不了多久 | Sandy Lam | Love, Sandy
upcoming | 留給這世上我最愛的人 | Joey Yung | 留給世上最愛羅文的人
```

## Probe Comparison

- Probe output file: .codex/workspace/music-queue-probes/public-surface-20260524T020052Z.txt
- Probe classification.outcome: unavailable_no_current_playlist
- Do visible rows match probe rows by order and identity: no
- Mismatch notes: The visible Music.app play queue contained station upcoming rows, but the public AppleScript probe exposed only current track metadata. `current playlist` failed, `playlists_named_up_next` was empty, and no public queue/history row carrier was present.

## Exact-Claim Gate

This context is not exact. It is resolved as unavailable for the tested public
surface because Music.app visibly had queue rows, while the public probe did
not expose those rows by order or identity.
