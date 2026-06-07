# Visible Music.app Queue Notes

context_label: skip-previous-rapid-changes
created_utc: 20260524T023825Z
manual_outcome: pending

## Manual Setup

- Required setup: Use next/previous repeatedly after opening visible queue.
- Expected proof: Probe must not lag or keep stale rows.
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
