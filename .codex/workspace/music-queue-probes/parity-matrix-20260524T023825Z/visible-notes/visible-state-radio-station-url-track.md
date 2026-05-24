# Visible Music.app Queue Notes

context_label: radio-station-url-track
created_utc: 20260524T023825Z
manual_outcome: pending

## Manual Setup

- Required setup: Play an Apple Music station/radio item.
- Expected proof: Probe must expose visible upcoming/history rows or mark unavailable.
- Music.app visible Up Next/history UI open: TODO yes/no
- Playback source visible in Music.app: TODO
- Current visible track: TODO
- Manual Play Next/Play Later edits present: TODO yes/no

## Visible Rows

Record exact visible row order from Music.app. Include title, artist, album when
visible, and whether each row is history/current/upcoming.

```text
TODO paste visible queue rows here
```

## Probe Comparison

- Probe output file: TODO filled by runner or by hand
- Probe classification.outcome: TODO filled by runner or by hand
- Do visible rows match probe rows by order and identity: TODO yes/no
- Mismatch notes: TODO

## Exact-Claim Gate

Only mark this context exact when:

- visible Music.app rows are recorded above;
- public probe rows are recorded in the probe output;
- visible rows and probe rows match by order and identity;
- no private storage, UI scraping, or private AppleEvent source was used.

## Runner Result

- Recorded UTC: 20260524T023857Z
- Probe output file: .codex/workspace/music-queue-probes/parity-matrix-20260524T023825Z/public-surface-radio-station-url-track-20260524T023857Z.txt
- Probe classification.outcome: unavailable_no_current_playlist
- Manual outcome recorded by runner: pending
