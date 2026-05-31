# Music Queue Parity Probe

This probe exists before product implementation. Its job is to prove whether a
public, App Store-compliant surface can mirror the real Music.app queue and
history that the user sees in Apple Music.

## Rule

The product bar is binary: exact real Music.app queue/history parity or
unavailable for that playback context. Playlist-neighbor scans, recently played
API results, catalog search, and cached observations can support diagnostics,
but they cannot be labeled as the real-time queue unless parity is proven.

## Public Surfaces Under Test

1. Music.app Apple Events through the public scripting dictionary, including
   `current playlist`, `current track`, public browser/playlist window `view`
   playlists, visible `selection`, and window selection properties.
2. MusicKit and MediaPlayer compiler/API availability on macOS.
3. Apple Music API history/library endpoints for metadata support only.
4. Music.app distributed notifications through Foundation
   `DistributedNotificationCenter`, limited to known Music.app notification
   names that nanoPod already treats as playback invalidation signals.

The official Apple API contract is summarized in
`.codex/workspace/music-queue-official-api-audit.md`. Keep that audit separate
from runtime parity: official docs can disqualify a surface by design, while
runtime probes prove what the current machine exposes.
For example, SiriKit Cloud Media `Queue` is a public Apple provider-side queue
payload for Siri playback fulfillment, but it is not a client-side Music.app
queue reader and therefore is not part of the local runtime parity matrix.

Private frameworks, private AppleEvents, Music.app database reads, accessibility
UI scraping, and memory inspection are out of scope.

Current nanoPod builds have a temporary read exception for Music's
`PlaybackSessions` directory for artwork discovery. That path is explicitly out
of scope for real queue proof because it is private Music.app storage, not a
public queue API.

## How To Run

Start by generating a timestamped matrix runbook and visible-note templates:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh --plan
```

After manually setting up Music.app for a context and opening the visible
Up Next/history UI, run the current-state probe through the matrix runner:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \
  --run-current \
  --session-dir ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ" \
  --context "album-playback"
```

The matrix runner never changes Music.app playback or queue state. It only
creates templates and calls the public-surface probe for the current state.
Exact parity still requires the visible rows to be written in the notes file and
manually compared against the probe rows by order and identity.

For album/playlist contexts where AppleScript track indices might depend on
Music.app's `fixed indexing` behavior, opt into the restored variant probe:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \
  --run-current \
  --session-dir ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ" \
  --context "album-playback" \
  --probe-fixed-indexing
```

This toggles only the public AppleScript `fixed indexing` setting during the
probe, records both variants, and restores the original value. It is not a
queue edit and is not proof unless the captured variant rows match the visible
Music.app Up Next/history rows. The validator rejects resolved fixed-indexing
claims unless the probe reports `fixed_indexing.restored=true`.

To attach distributed-notification payload evidence to the same matrix session,
run the supplemental notification mode:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \
  --run-notifications \
  --session-dir ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ" \
  --context "album-playback" \
  --notification-duration 15 \
  --notification-until-event-count 1 \
  --notification-trigger playpause-restore \
  --notification-mute
```

Notification captures are written to `NOTIFICATION_SUMMARY.md`, not the main
exact-claim `SUMMARY.md`. They are supplemental unless someone intentionally
adds them to `SUMMARY.md` and they pass validator gates plus visible-row parity.

To attach public SDK/API availability evidence to the same matrix session, run
the supplemental SDK mode:

```bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \
  --run-sdk \
  --session-dir ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ"
```

SDK captures are written to `SDK_SUMMARY.md`, not the main exact-claim
`SUMMARY.md`. They prove only which public SDK symbols compile or run on the
current machine; they do not prove visible Music.app queue parity.

Before relying on a matrix session, validate the recorded evidence:

```bash
python3 .codex/workspace/validate_music_queue_parity_matrix.py \
  ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ"
```

To see which required playback contexts are resolved, pending, or still
missing without turning the report into a completion gate, add
`--coverage-report`:

```bash
python3 .codex/workspace/validate_music_queue_parity_matrix.py \
  ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ" \
  --coverage-report
```

Before claiming that the read strategy covers the required product contexts,
run the strict completion gate:

```bash
python3 .codex/workspace/validate_music_queue_parity_matrix.py \
  ".codex/workspace/music-queue-probes/parity-matrix-YYYYMMDDTHHMMSSZ" \
  --require-complete
```

The validator blocks `exact` rows that still contain TODOs, lack visible
Music.app rows, lack an explicit visible/probe row match, or point to an
unavailable public probe classification.
It also blocks `unavailable` rows unless the visible notes are complete, the
visible Music.app queue UI was open, visible rows were recorded, and the public
probe either classified the surface as unavailable or the notes explicitly say
the public rows did not match the visible rows by order and identity.
With `--require-complete`, it additionally requires every manual-test matrix
context below to have at least one resolved `exact` or `unavailable` row.
That strict mode also prints the same coverage report so a failure names the
resolved, pending, and missing contexts in one place.
It also blocks `exact` rows backed by distributed-notification artifacts when
the capture observed no event, reported metadata/context-only payloads, had no
row-carrier keys, or had row-carrier keys without a non-empty array/dictionary
payload shape.

To specifically test whether MusicKit's `ApplicationMusicPlayer` is bound to
the current Music.app session, run the focused runtime probe:

```bash
bash .codex/workspace/probe_musickit_application_player_queue.sh \
  --context "non-disruptive-current-state"
```

This probe is read-only. It records public Music.app AppleScript playback state
beside public MusicKit `ApplicationMusicPlayer` state, and it never calls
MusicKit play, queue mutation, preparation, or authorization-request APIs.

To specifically test current public macOS SDK availability without touching
Music.app at all, run:

```bash
bash .codex/workspace/probe_music_queue_sdk_surface.sh \
  --context "sdk-current-state"
```

This probe compiles focused MusicKit and MediaPlayer snippets, excerpts public
headers, and records whether any system Music.app player surface exists on the
local SDK. It does not request Music authorization, mutate playback, or talk to
Music.app.

To specifically test whether Music.app distributed notification payloads expose
queue/history rows, run the passive notification probe:

```bash
bash .codex/workspace/probe_music_distributed_notifications.sh \
  --context "album-playback" \
  --duration 15 \
  --until-event-count 1 \
  --trigger playpause-restore \
  --mute-during-trigger
```

This probe is passive by default. It listens for known Music.app notification
names and records their `userInfo` keys. If no notification fires during the
capture window, the output is inconclusive; rerun it while manually causing
Music.app to emit a `playerInfo` event or use the opt-in
`playpause-restore` trigger. The trigger uses public Music.app Apple Events
after observers are installed, optionally mutes Music.app, and restores the
original play/pause state and Music.app volume. It never mutates the queue.
The probe separates possible row-carrier keys (`queue`, `Up Next`, `history`,
`tracks`, `entries`) from context-only metadata keys (`playlist`, current
track, artist, album, playback state). A metadata/context-only payload supports
using notifications as invalidation signals, not as a queue source.

For a one-off public-surface probe without a matrix session, run:

Run:

```bash
.codex/workspace/probe_music_queue_public_surface.sh
```

For a labeled visible parity pass, run:

```bash
.codex/workspace/probe_music_queue_public_surface.sh \
  --context "album-playback" \
  --visible-notes ".codex/workspace/music-queue-probes/visible-state-YYYYMMDDTHHMMSSZ.md"
```

The script writes a timestamped report under:

```text
.codex/workspace/music-queue-probes/
```

Record each run in:

```text
.codex/workspace/music-queue-parity-results.md
```

Each report includes:

- A compliance preflight that records the public-surface rule and any local
  entitlement risk, including private Music.app storage exceptions that must not
  be treated as a queue source.
- MusicKit compiler availability for `ApplicationMusicPlayer` and
  `SystemMusicPlayer`.
- MediaPlayer compiler availability for `MPMusicPlayerController`,
  `applicationQueuePlayer`, and `systemMusicPlayer`.
- MediaPlayer `MPNowPlayingInfoCenter.default()` runtime state and public
  header excerpt.
- Focused distributed-notification payload evidence from
  `.codex/workspace/probe_music_distributed_notifications.sh` when the question
  is whether `playerInfo`/playlist-change notifications carry queue rows. The
  report records `row_carrier_userInfo_keys`, `context_only_userInfo_keys`, and
  each payload value shape so context metadata cannot be overclassified as
  queue rows.
- Focused MusicKit runtime evidence from
  `.codex/workspace/probe_musickit_application_player_queue.sh` when the
  question is whether `ApplicationMusicPlayer.queue` is the same session as
  Music.app's visible queue.
- Focused public SDK availability evidence from
  `.codex/workspace/probe_music_queue_sdk_surface.sh` when the question is
  whether the current macOS SDK exposes MusicKit or MediaPlayer queue APIs that
  could plausibly target Music.app. This remains supplemental unless paired
  with visible Up Next/history parity proof.
- Music.app scripting dictionary matches for queue-like terms.
- An exact declaration check for public queue/history objects.
- A runtime AppleScript snapshot, including the public `selection` surface.
- Public browser/playlist window `view` playlist summaries and neighbor rows
  around the current track when those views expose the current item.
- Public queue-like playlist-name candidates, including `Up Next`,
  `Playing Next`, `Play Queue`, localized queue terms, and their summaries plus
  current-track neighbor windows when present. These are discovery candidates
  only; they still require visible row coverage before they can support an
  exact claim.
- Optional restored `fixed indexing` variant rows for current-playlist probes,
  used to test whether public AppleScript play-order indexing can explain
  album/playlist Up Next order. These rows still require visible parity proof.
- A coarse `classification.outcome` value that tells whether the current
  public surface is exact-ready, partial, or unavailable before manual visual
  comparison.
- Optional visible Music.app notes copied into the probe report so the public
  data and UI observation stay together.
- Validator coverage from
  `.codex/workspace/validate_music_queue_parity_matrix.py`, which rejects
  exact notification claims unless they contain observed events, row-carrier
  keys, and non-empty row-like payload shapes in addition to visible Music.app
  parity notes. It also rejects unverified unavailable claims so missing public
  rows cannot be accepted without visible Music.app evidence.
  It also rejects resolved fixed-indexing claims if the probe did not restore
  Music.app's original `fixed indexing` value.
  Its `--coverage-report` mode prints each required playback context as
  resolved, pending, or missing without failing only because coverage is still
  incomplete.
  Its `--require-complete` mode rejects any read-strategy completion claim that
  omits a required playback context or leaves that context pending/partial, and
  prints the same coverage report before the errors.

## Manual Test Matrix

For each row, open Music.app's visible Up Next/history UI and compare it to the
probe output.

| Context | Setup | Expected proof |
| --- | --- | --- |
| Album playback | Play an album from Music.app | Probe order must match visible Up Next exactly |
| User playlist | Play a normal local/user playlist | Probe order must match visible Up Next exactly |
| Apple Music playlist | Play an Apple Music playlist not owned by the user | Probe order must match visible Up Next exactly |
| Local file/library track | Play an imported local file or library song | Probe order must match visible Up Next exactly |
| Radio/station | Play an Apple Music station/radio item | Probe must expose the actual upcoming/history rows, not empty or unrelated playlist neighbors |
| Play Next/Play Later | Add two songs using Music.app queue actions | Probe must reflect the edited Music.app queue order |
| Skip/previous | Use next/previous repeatedly | Probe must remain current and not show stale rows |

For every run, also save the visible Music.app state in the notes: what source
was playing, whether Up Next was open, whether Play Next/Play Later edits were
present, and whether the visible rows matched the probe output.

The public `selection` surface is useful evidence but not proof by itself. If
manual testing selects rows in Music.app's visible queue, the probe records the
selected objects. That only proves selected visible items are reachable; exact
queue proof still requires every visible history/current/upcoming row in order.

Distributed notification payloads are also useful evidence but not proof by
themselves. A notification must expose every visible queue/history row by order
and identity before it can be considered a read path; context-only fields such
as playlist/current track metadata remain invalidation or now-playing metadata
signals.

## Outcome Labels

- `exact`: public surface matches visible Music.app queue/history.
- `partial`: surface exposes only a containing playlist, limited history, or
  metadata.
- `stale`: surface lags or keeps old rows after Music.app changes.
- `empty`: surface returns no useful rows.
- `unavailable`: public surface cannot represent this context honestly.

Implementation may start only after the chosen strategy has enough `exact`
coverage for the product claim, or after the UI is redesigned to show
`unavailable` for non-exact contexts.
