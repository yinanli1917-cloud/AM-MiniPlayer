#!/usr/bin/env bash
set -euo pipefail

probe_script=".codex/workspace/probe_music_queue_public_surface.sh"
notification_probe_script=".codex/workspace/probe_music_distributed_notifications.sh"
sdk_probe_script=".codex/workspace/probe_music_queue_sdk_surface.sh"
out_dir=".codex/workspace/music-queue-probes"
mode="plan"
context_label=""
visible_notes_file=""
session_dir=""
manual_outcome="pending"
notification_duration="15"
notification_until_event_count="1"
notification_trigger="none"
notification_restore_delay="0.8"
notification_mute="false"

usage() {
  cat <<'USAGE'
Usage:
  bash .codex/workspace/run_music_queue_parity_matrix.sh --plan
  bash .codex/workspace/run_music_queue_parity_matrix.sh --run-current --context LABEL [--visible-notes FILE]
  bash .codex/workspace/run_music_queue_parity_matrix.sh --run-notifications --context LABEL [notification options]
  bash .codex/workspace/run_music_queue_parity_matrix.sh --run-sdk [--context LABEL]

Modes:
  --plan              Create a timestamped parity runbook and visible-notes templates.
  --run-current       Run the public-surface probe against the current Music.app state.
  --run-notifications Run the Music.app distributed-notification probe as supplemental evidence.
  --run-sdk           Run the read-only public SDK/API availability probe as supplemental evidence.

Options:
  --context LABEL          Required with --run-current/--run-notifications. Use one matrix context label.
                           Optional with --run-sdk; defaults to sdk-current-state.
  --visible-notes FILE     Notes file to embed in the probe. Created if missing.
  --manual-outcome LABEL   pending|exact|partial|stale|empty|unavailable.
  --notification-duration SECONDS
  --notification-until-event-count N
  --notification-trigger MODE      none|playpause-restore.
  --notification-restore-delay SEC
  --notification-mute              Temporarily mute Music.app during trigger.
  --out-dir DIR            Probe output root. Default: .codex/workspace/music-queue-probes
  --session-dir DIR        Existing or desired matrix session directory.
  --help                   Show this help.

Safety:
  This runner never changes Music.app playback or queue state. Set up Music.app
  manually, open the visible Up Next/history UI, write visible notes, then run
  --run-current for that already-visible state. Exact parity still requires
  manual visible-row comparison; probe output alone is not proof.
  --run-notifications is passive unless --notification-trigger is set; triggered
  notification captures restore play/pause state and Music.app volume.
  --run-sdk does not talk to Music.app, request authorization, or mutate playback.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      mode="plan"
      shift
      ;;
    --run-current)
      mode="run-current"
      shift
      ;;
    --run-notifications)
      mode="run-notifications"
      shift
      ;;
    --run-sdk)
      mode="run-sdk"
      shift
      ;;
    --context)
      context_label="$2"
      shift 2
      ;;
    --visible-notes)
      visible_notes_file="$2"
      shift 2
      ;;
    --manual-outcome)
      manual_outcome="$2"
      shift 2
      ;;
    --notification-duration)
      notification_duration="$2"
      shift 2
      ;;
    --notification-until-event-count)
      notification_until_event_count="$2"
      shift 2
      ;;
    --notification-trigger)
      notification_trigger="$2"
      shift 2
      ;;
    --notification-restore-delay)
      notification_restore_delay="$2"
      shift 2
      ;;
    --notification-mute)
      notification_mute="true"
      shift
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --session-dir)
      session_dir="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$manual_outcome" in
  pending|exact|partial|stale|empty|unavailable) ;;
  *)
    echo "invalid --manual-outcome: $manual_outcome" >&2
    exit 2
    ;;
esac

if [[ ! -x "$probe_script" && ! -f "$probe_script" ]]; then
  echo "missing probe script: $probe_script" >&2
  exit 1
fi
if [[ ! -x "$notification_probe_script" && ! -f "$notification_probe_script" ]]; then
  echo "missing notification probe script: $notification_probe_script" >&2
  exit 1
fi
if [[ ! -x "$sdk_probe_script" && ! -f "$sdk_probe_script" ]]; then
  echo "missing SDK probe script: $sdk_probe_script" >&2
  exit 1
fi

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
if [[ -z "$session_dir" ]]; then
  session_dir="$out_dir/parity-matrix-$timestamp"
fi
mkdir -p "$session_dir"

context_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs '[:alnum:]' '-' \
    | sed 's/^-//; s/-$//'
}

known_contexts() {
  cat <<'CONTEXTS'
album-playback|Play an album from Music.app.|Probe rows must match visible Up Next order and identity.
user-playlist-playback|Play a normal local/user playlist from Music.app.|Probe rows must match visible Up Next order and identity.
apple-music-playlist-playback|Play an Apple Music playlist not owned by the user.|Probe rows must match visible Up Next order and identity.
local-library-file-track|Play an imported local file or normal library track.|Probe must not rely on unavailable private storage.
radio-station-url-track|Play an Apple Music station/radio item.|Probe must expose visible upcoming/history rows or mark unavailable.
play-next-play-later-edits|Manually add at least two tracks using Music.app Play Next/Play Later.|Probe must reflect the edited visible queue order.
skip-previous-rapid-changes|Use next/previous repeatedly after opening visible queue.|Probe must not lag or keep stale rows.
CONTEXTS
}

context_exists() {
  local wanted="$1"
  known_contexts | awk -F'|' -v wanted="$wanted" '$1 == wanted { found=1 } END { exit found ? 0 : 1 }'
}

write_notes_template() {
  local notes_file="$1"
  local label="$2"
  local setup=""
  local expected=""

  if [[ -f "$notes_file" ]]; then
    return
  fi

  while IFS='|' read -r known_label known_setup known_expected; do
    if [[ "$known_label" == "$label" ]]; then
      setup="$known_setup"
      expected="$known_expected"
      break
    fi
  done < <(known_contexts)

  cat > "$notes_file" <<EOF_NOTES
# Visible Music.app Queue Notes

context_label: $label
created_utc: $timestamp
manual_outcome: $manual_outcome

## Manual Setup

- Required setup: ${setup:-Describe the current Music.app setup.}
- Expected proof: ${expected:-Describe what visible queue parity would prove.}
- Music.app visible Up Next/history UI open: TODO yes/no
- Playback source visible in Music.app: TODO
- Current visible track: TODO
- Manual Play Next/Play Later edits present: TODO yes/no

## Visible Rows

Record exact visible row order from Music.app. Include title, artist, album when
visible, and whether each row is history/current/upcoming.

\`\`\`text
TODO paste visible queue rows here
\`\`\`

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
EOF_NOTES
}

write_runbook() {
  local runbook="$session_dir/RUNBOOK.md"
  local templates_dir="$session_dir/visible-notes"
  mkdir -p "$templates_dir"

  cat > "$runbook" <<EOF_RUNBOOK
# Music Queue Parity Matrix Run

created_utc: $timestamp

This runbook is for proving or rejecting exact Music.app queue parity through
public, App Store-safe surfaces. It does not change Music.app playback.

## Rule

Do not mark any context exact unless the visible Music.app Up Next/history rows
match the public probe output by order and identity. Probe output alone is not
proof.

## Commands

After manually setting up a context and opening Music.app's visible queue UI:

\`\`\`bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \\
  --run-current \\
  --session-dir "$session_dir" \\
  --context CONTEXT_LABEL
\`\`\`

Optionally pass \`--visible-notes FILE\` if you already wrote notes or attached a
screenshot reference.

Before using a matrix result as implementation evidence, validate the session:

\`\`\`bash
python3 .codex/workspace/validate_music_queue_parity_matrix.py "$session_dir"
\`\`\`

The validator rejects exact distributed-notification claims when the capture has
no event, metadata/context-only payloads, no row-carrier keys, or no non-empty
array/dictionary payload shape for the row-carrier keys.

When testing MusicKit as a possible read source, run the focused read-only
runtime probe for the same already-visible Music.app state:

\`\`\`bash
bash .codex/workspace/probe_musickit_application_player_queue.sh \\
  --context CONTEXT_LABEL \\
  --out-dir "$session_dir"
\`\`\`

When checking which MusicKit/MediaPlayer queue APIs exist in the current public
macOS SDK, run the supplemental SDK-surface probe:

\`\`\`bash
bash .codex/workspace/run_music_queue_parity_matrix.sh \\
  --run-sdk \\
  --session-dir "$session_dir"
\`\`\`

When testing whether Music.app distributed notifications expose queue/history
payloads, run the passive notification probe while the visible queue UI is
open:

\`\`\`bash
bash .codex/workspace/probe_music_distributed_notifications.sh \\
  --context CONTEXT_LABEL \\
  --duration 15 \\
  --until-event-count 1 \\
  --trigger playpause-restore \\
  --mute-during-trigger \\
  --out-dir "$session_dir"
\`\`\`

## Matrix

| Context | Manual setup | Exact proof required | Notes template |
| --- | --- | --- | --- |
EOF_RUNBOOK

  while IFS='|' read -r label setup expected; do
    local notes_file="$templates_dir/visible-state-$label.md"
    write_notes_template "$notes_file" "$label"
    printf '| `%s` | %s | %s | `%s` |\n' "$label" "$setup" "$expected" "$notes_file" >> "$runbook"
  done < <(known_contexts)

  cat >> "$runbook" <<'EOF_RUNBOOK'

## Rejected Sources

- private frameworks;
- private AppleEvents;
- Music.app private databases/files, including PlaybackSessions;
- Accessibility/UI scraping as a product queue source;
- memory inspection;
- Apple Music API recently played data as live local queue proof;
- Music.app distributed notification payloads unless a visible parity pass
  proves they carry every visible queue/history row by order and identity;
- MusicKit ApplicationMusicPlayer.queue unless a visible parity pass proves it
  is bound to the same Music.app session.
EOF_RUNBOOK

  printf '%s\n' "$runbook"
}

append_summary() {
  local probe_out="$1"
  local label="$2"
  local notes_file="$3"
  local classification="$4"
  local summary="$session_dir/SUMMARY.md"

  if [[ ! -f "$summary" ]]; then
    cat > "$summary" <<EOF_SUMMARY
# Music Queue Parity Matrix Summary

created_utc: $timestamp

| Context | Manual outcome | Probe classification | Probe output | Visible notes |
| --- | --- | --- | --- | --- |
EOF_SUMMARY
  fi

  printf '| `%s` | `%s` | `%s` | `%s` | `%s` |\n' \
    "$label" "$manual_outcome" "$classification" "$probe_out" "$notes_file" >> "$summary"
}

append_notes_result() {
  local probe_out="$1"
  local notes_file="$2"
  local classification="$3"

  cat >> "$notes_file" <<EOF_RESULT

## Runner Result

- Recorded UTC: $timestamp
- Probe output file: $probe_out
- Probe classification.outcome: $classification
- Manual outcome recorded by runner: $manual_outcome
EOF_RESULT
}

extract_probe_value() {
  local key="$1"
  local probe_out="$2"
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$probe_out"
}

append_notification_summary() {
  local probe_out="$1"
  local label="$2"
  local classification="$3"
  local summary="$session_dir/NOTIFICATION_SUMMARY.md"
  local event_count row_carriers context_keys trigger_mode trigger_finished

  event_count="$(extract_probe_value "capture.events_count" "$probe_out")"
  row_carriers="$(extract_probe_value "capture.row_carrier_userInfo_keys" "$probe_out")"
  context_keys="$(extract_probe_value "capture.context_only_userInfo_keys" "$probe_out")"
  trigger_mode="$(extract_probe_value "capture.trigger_mode" "$probe_out")"
  trigger_finished="$(extract_probe_value "capture.trigger_finished" "$probe_out")"
  if [[ -z "$trigger_mode" || "$trigger_mode" == "none" ]]; then
    trigger_finished="n/a"
  fi

  if [[ ! -f "$summary" ]]; then
    cat > "$summary" <<EOF_NOTIFICATION_SUMMARY
# Music Queue Notification Evidence

created_utc: $timestamp

Notification captures are supplemental evidence. They do not make a context
exact unless the capture is also added to SUMMARY.md and passes
validate_music_queue_parity_matrix.py with visible-row parity notes.

| Context | Classification | Events | Row carrier keys | Context keys | Trigger | Restored | Probe output |
| --- | --- | --- | --- | --- | --- | --- | --- |
EOF_NOTIFICATION_SUMMARY
  fi

  printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` |\n' \
    "$label" \
    "$classification" \
    "${event_count:-missing}" \
    "${row_carriers:-none}" \
    "${context_keys:-none}" \
    "${trigger_mode:-none}" \
    "${trigger_finished:-n/a}" \
    "$probe_out" >> "$summary"
}

append_sdk_summary() {
  local probe_out="$1"
  local label="$2"
  local classification="$3"
  local summary="$session_dir/SDK_SUMMARY.md"
  local app_queue queue_insert system_player mp_controller mp_app_queue mp_system now_playing

  app_queue="$(extract_probe_value "classification.musickit_application_player_queue_compile" "$probe_out")"
  queue_insert="$(extract_probe_value "classification.musickit_queue_insertion_position_compile" "$probe_out")"
  system_player="$(extract_probe_value "classification.musickit_system_music_player_compile" "$probe_out")"
  mp_controller="$(extract_probe_value "classification.mediaplayer_music_player_controller_compile" "$probe_out")"
  mp_app_queue="$(extract_probe_value "classification.mediaplayer_application_queue_player_compile" "$probe_out")"
  mp_system="$(extract_probe_value "classification.mediaplayer_system_music_player_compile" "$probe_out")"
  now_playing="$(extract_probe_value "classification.mediaplayer_now_playing_center_compile" "$probe_out")"

  if [[ ! -f "$summary" ]]; then
    cat > "$summary" <<EOF_SDK_SUMMARY
# Music Queue SDK Surface Evidence

created_utc: $timestamp

SDK captures are supplemental evidence. They record public macOS SDK/API
availability only; they do not prove visible Music.app Up Next/history parity.

| Context | Classification | ApplicationMusicPlayer.queue | Queue insertion | SystemMusicPlayer | MPMusicPlayerController | MP app queue | MP system player | MPNowPlayingInfoCenter | Probe output |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
EOF_SDK_SUMMARY
  fi

  printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` |\n' \
    "$label" \
    "$classification" \
    "${app_queue:-missing}" \
    "${queue_insert:-missing}" \
    "${system_player:-missing}" \
    "${mp_controller:-missing}" \
    "${mp_app_queue:-missing}" \
    "${mp_system:-missing}" \
    "${now_playing:-missing}" \
    "$probe_out" >> "$summary"
}

if [[ "$mode" == "plan" ]]; then
  write_runbook
  exit 0
fi

if [[ "$mode" == "run-current" ]]; then
  if [[ -z "$context_label" ]]; then
    echo "--context is required with --run-current" >&2
    exit 2
  fi
  if ! context_exists "$context_label"; then
    echo "unknown context: $context_label" >&2
    echo "known contexts:" >&2
    known_contexts | awk -F'|' '{ print "  " $1 }' >&2
    exit 2
  fi

  slug="$(context_slug "$context_label")"
  if [[ -z "$visible_notes_file" ]]; then
    visible_notes_file="$session_dir/visible-notes/visible-state-$slug.md"
  fi
  mkdir -p "$(dirname "$visible_notes_file")"
  write_notes_template "$visible_notes_file" "$context_label"

  probe_out="$(bash "$probe_script" --out-dir "$session_dir" --context "$context_label" --visible-notes "$visible_notes_file")"
  classification="$(awk -F= '/classification\.outcome=/{ value=$2 } END { if (value == "") { print "missing" } else { print value } }' "$probe_out")"
  append_summary "$probe_out" "$context_label" "$visible_notes_file" "$classification"
  append_notes_result "$probe_out" "$visible_notes_file" "$classification"

  echo "$probe_out"
  exit 0
fi

if [[ "$mode" == "run-notifications" ]]; then
  if [[ -z "$context_label" ]]; then
    echo "--context is required with --run-notifications" >&2
    exit 2
  fi
  if ! context_exists "$context_label"; then
    echo "unknown context: $context_label" >&2
    echo "known contexts:" >&2
    known_contexts | awk -F'|' '{ print "  " $1 }' >&2
    exit 2
  fi

  notification_args=(
    "$notification_probe_script"
    --out-dir "$session_dir"
    --context "$context_label"
    --duration "$notification_duration"
    --until-event-count "$notification_until_event_count"
    --trigger "$notification_trigger"
    --restore-delay "$notification_restore_delay"
  )
  if [[ "$notification_mute" == "true" ]]; then
    notification_args+=(--mute-during-trigger)
  fi

  probe_out="$(bash "${notification_args[@]}")"
  classification="$(extract_probe_value "classification.outcome" "$probe_out")"
  if [[ -z "$classification" ]]; then
    classification="missing"
  fi
  append_notification_summary "$probe_out" "$context_label" "$classification"

  echo "$probe_out"
  exit 0
fi

if [[ "$mode" == "run-sdk" ]]; then
  if [[ -z "$context_label" ]]; then
    context_label="sdk-current-state"
  fi

  probe_out="$(bash "$sdk_probe_script" --out-dir "$session_dir" --context "$context_label")"
  classification="$(extract_probe_value "classification.outcome" "$probe_out")"
  if [[ -z "$classification" ]]; then
    classification="missing"
  fi
  append_sdk_summary "$probe_out" "$context_label" "$classification"

  echo "$probe_out"
  exit 0
fi

echo "unsupported mode: $mode" >&2
exit 2
