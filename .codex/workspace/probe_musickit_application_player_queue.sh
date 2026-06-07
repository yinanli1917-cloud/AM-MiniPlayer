#!/usr/bin/env bash
set -euo pipefail

out_dir=".codex/workspace/music-queue-probes"
context_label="unspecified"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --context)
      context_label="$2"
      shift 2
      ;;
    --help|-h)
      cat <<'USAGE'
Usage:
  bash .codex/workspace/probe_musickit_application_player_queue.sh [--context LABEL] [--out-dir DIR]

This probe is read-only. It compares public Music.app AppleScript playback
state with public MusicKit ApplicationMusicPlayer queue state. It never calls
play, pause, skip, setQueue, insert, prepareToPlay, or MusicAuthorization.request.
USAGE
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      exit 2
      ;;
    *)
      out_dir="$1"
      shift
      ;;
  esac
done

mkdir -p "$out_dir"

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
context_slug="$(printf '%s' "$context_label" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//; s/-$//')"
if [[ -z "$context_slug" || "$context_slug" == "unspecified" ]]; then
  out_file="$out_dir/musickit-application-player-queue-$timestamp.txt"
else
  out_file="$out_dir/musickit-application-player-queue-$context_slug-$timestamp.txt"
fi

music_snapshot="$(mktemp)"
musickit_snapshot="$(mktemp)"
trap 'rm -f "$music_snapshot" "$musickit_snapshot"' EXIT

if ! osascript >"$music_snapshot" 2>&1 <<'APPLESCRIPT'; then
tell application "Music"
    if it is not running then
        return "music_app.running=false"
    end if

    set AppleScript's text item delimiters to linefeed
    set rows to {}
    set end of rows to "music_app.running=true"
    set end of rows to "music_app.player_state=" & ((player state) as text)
    set end of rows to "music_app.player_position=" & ((player position) as text)

    try
        set end of rows to "music_app.current_track.name=" & (name of current track)
        set end of rows to "music_app.current_track.artist=" & (artist of current track)
        set end of rows to "music_app.current_track.album=" & (album of current track)
        set end of rows to "music_app.current_track.class=" & ((class of current track) as text)
        set end of rows to "music_app.current_track.persistent_id=" & (persistent ID of current track)
    on error errMsg
        set end of rows to "music_app.current_track.error=" & errMsg
    end try

    try
        set cp to current playlist
        set end of rows to "music_app.current_playlist.available=true"
        set end of rows to "music_app.current_playlist.name=" & (name of cp)
        set end of rows to "music_app.current_playlist.track_count=" & ((count of tracks of cp) as text)
    on error errMsg
        set end of rows to "music_app.current_playlist.available=false"
        set end of rows to "music_app.current_playlist.error=" & errMsg
    end try

    return rows as text
end tell
APPLESCRIPT
  {
    echo "music_app.snapshot_error=true"
    sed -n '1,80p' "$music_snapshot"
  } > "${music_snapshot}.failed"
  mv "${music_snapshot}.failed" "$music_snapshot"
fi

if ! swift - >"$musickit_snapshot" 2>&1 <<'SWIFT'; then
import Foundation
import MusicKit

print("musickit.authorization=\(MusicAuthorization.currentStatus)")
if #available(macOS 14.0, *) {
    let player = ApplicationMusicPlayer.shared
    let state = player.state
    let queue = player.queue
    print("musickit.application_player.available=true")
    print("musickit.application_player.playback_status=\(state.playbackStatus)")
    print("musickit.application_player.playback_rate=\(state.playbackRate)")
    print("musickit.application_player.repeat_mode=\(String(describing: state.repeatMode))")
    print("musickit.application_player.shuffle_mode=\(String(describing: state.shuffleMode))")
    print("musickit.application_player.queue.current_entry=\(String(describing: queue.currentEntry))")
    print("musickit.application_player.queue.entries_count=\(queue.entries.count)")
    for (index, entry) in queue.entries.prefix(10).enumerated() {
        print("musickit.application_player.queue.entry[\(index)]=\(String(describing: entry))")
    }
} else {
    print("musickit.application_player.available=false")
}
SWIFT
  {
    echo "musickit.snapshot_error=true"
    sed -n '1,120p' "$musickit_snapshot"
  } > "${musickit_snapshot}.failed"
  mv "${musickit_snapshot}.failed" "$musickit_snapshot"
fi

value_for_key() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key { value=$0; sub("^[^=]*=", "", value); print value }' "$file" | tail -1
}

music_running="$(value_for_key "music_app.running" "$music_snapshot")"
music_player_state="$(value_for_key "music_app.player_state" "$music_snapshot")"
music_track_name="$(value_for_key "music_app.current_track.name" "$music_snapshot")"
music_track_artist="$(value_for_key "music_app.current_track.artist" "$music_snapshot")"
music_track_class="$(value_for_key "music_app.current_track.class" "$music_snapshot")"
app_player_available="$(value_for_key "musickit.application_player.available" "$musickit_snapshot")"
app_player_status="$(value_for_key "musickit.application_player.playback_status" "$musickit_snapshot")"
app_player_current_entry="$(value_for_key "musickit.application_player.queue.current_entry" "$musickit_snapshot")"
app_player_entries_count="$(value_for_key "musickit.application_player.queue.entries_count" "$musickit_snapshot")"

classification="inconclusive"
if [[ "$music_running" != "true" ]]; then
  classification="inconclusive_music_app_not_running"
elif [[ "$app_player_available" != "true" ]]; then
  classification="unavailable_application_player_not_available"
elif [[ "$music_player_state" == "playing" && "$app_player_status" == "stopped" && "$app_player_entries_count" == "0" && "$app_player_current_entry" == "nil" ]]; then
  classification="not_music_app_session_music_playing_application_player_empty"
elif [[ "$music_player_state" == "playing" && "$app_player_entries_count" == "0" && "$app_player_current_entry" == "nil" ]]; then
  classification="not_exact_music_app_queue_application_player_empty"
else
  classification="manual_visible_compare_required"
fi

{
  echo "# MusicKit ApplicationMusicPlayer Queue Runtime Probe"
  echo
  echo "timestamp_utc: $timestamp"
  echo "context_label: $context_label"
  echo "macos: $(sw_vers -productVersion)"
  echo

  echo "## Compliance preflight"
  echo
  echo "public_surface_rule: public Music.app AppleScript read state plus public MusicKit ApplicationMusicPlayer read state only."
  echo "excluded_queue_sources: private frameworks; private AppleEvents; Music.app private databases/files; accessibility/UI scraping; memory inspection."
  echo "mutating_calls: none"
  echo "authorization_request: none"
  echo

  echo "## Music.app public AppleScript snapshot"
  echo
  sed -n '1,140p' "$music_snapshot"
  echo

  echo "## MusicKit ApplicationMusicPlayer snapshot"
  echo
  sed -n '1,160p' "$musickit_snapshot"
  echo

  echo "## Relationship classification"
  echo
  echo "classification.outcome=$classification"
  echo "classification.music_app_running=${music_running:-unknown}"
  echo "classification.music_app_player_state=${music_player_state:-unknown}"
  echo "classification.music_app_track=${music_track_name:-unknown}|${music_track_artist:-unknown}|${music_track_class:-unknown}"
  echo "classification.application_player_status=${app_player_status:-unknown}"
  echo "classification.application_player_current_entry=${app_player_current_entry:-unknown}"
  echo "classification.application_player_entries_count=${app_player_entries_count:-unknown}"
  echo

  echo "## Interpretation"
  echo
  echo "- If Music.app is playing while ApplicationMusicPlayer is stopped with an empty queue, ApplicationMusicPlayer is not evidence of the user's visible Music.app session."
  echo "- If ApplicationMusicPlayer has entries, compare them against Music.app's visible Up Next/history UI before any exact claim."
  echo "- This probe does not test queue editing. Editing remains locked until a public edit API is proven to modify the same visible Music.app session and the read path proves the result."
} > "$out_file"

echo "$out_file"
