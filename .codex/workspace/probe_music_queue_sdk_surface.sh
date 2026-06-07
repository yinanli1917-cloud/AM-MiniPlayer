#!/usr/bin/env bash
set -euo pipefail

out_dir=".codex/workspace/music-queue-probes"
context_label="sdk-current-state"

usage() {
  cat <<'USAGE'
Usage:
  bash .codex/workspace/probe_music_queue_sdk_surface.sh [--context LABEL] [--out-dir DIR]

This probe is read-only. It checks public macOS SDK compiler/runtime
availability for MusicKit and MediaPlayer queue-related surfaces. It does not
talk to Music.app, request authorization, or mutate playback.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context_label="$2"
      shift 2
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --help|-h)
      usage
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
  out_file="$out_dir/sdk-surface-$timestamp.txt"
else
  out_file="$out_dir/sdk-surface-$context_slug-$timestamp.txt"
fi

sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
media_player_header=""
now_playing_header=""
if [[ -n "$sdk_path" ]]; then
  media_player_header="$sdk_path/System/Library/Frameworks/MediaPlayer.framework/Headers/MPMusicPlayerController.h"
  now_playing_header="$sdk_path/System/Library/Frameworks/MediaPlayer.framework/Headers/MPNowPlayingInfoCenter.h"
fi

run_swift_probe() {
  local label="$1"
  local source="$2"
  local output

  if output="$(swift -e "$source" 2>&1)"; then
    printf '%s\n' "probe.$label.compile=PASS"
  else
    printf '%s\n' "probe.$label.compile=FAIL"
  fi
  printf '%s\n' "probe.$label.output<<EOF"
  printf '%s\n' "$output"
  printf '%s\n' "EOF"
}

app_queue_source='import MusicKit; if #available(macOS 14.0, *) { print(type(of: ApplicationMusicPlayer.shared.queue)) } else { print("unavailable_before_macos_14") }'
app_insert_source='import MusicKit; if #available(macOS 14.0, *) { print(MusicPlayer.Queue.EntryInsertionPosition.afterCurrentEntry); print(MusicPlayer.Queue.EntryInsertionPosition.tail) } else { print("unavailable_before_macos_14") }'
system_player_source='import MusicKit; if #available(macOS 14.0, *) { print(SystemMusicPlayer.shared) } else { print("unavailable_before_macos_14") }'
mp_controller_source='import MediaPlayer; print(MPMusicPlayerController.self)'
mp_application_queue_source='import MediaPlayer; print(MPMusicPlayerController.applicationQueuePlayer)'
mp_system_source='import MediaPlayer; print(MPMusicPlayerController.systemMusicPlayer)'
now_playing_source='import MediaPlayer; let center = MPNowPlayingInfoCenter.default(); print("mp_now_playing.available=true"); print("mp_now_playing.info=\(String(describing: center.nowPlayingInfo))"); if #available(macOS 10.12.2, *) { print("mp_now_playing.playback_state=\(center.playbackState.rawValue)") }'

app_queue_status="FAIL"
if swift -e "$app_queue_source" >/dev/null 2>&1; then app_queue_status="PASS"; fi
app_insert_status="FAIL"
if swift -e "$app_insert_source" >/dev/null 2>&1; then app_insert_status="PASS"; fi
system_player_status="FAIL"
if swift -e "$system_player_source" >/dev/null 2>&1; then system_player_status="PASS"; fi
mp_controller_status="FAIL"
if swift -e "$mp_controller_source" >/dev/null 2>&1; then mp_controller_status="PASS"; fi
mp_application_queue_status="FAIL"
if swift -e "$mp_application_queue_source" >/dev/null 2>&1; then mp_application_queue_status="PASS"; fi
mp_system_status="FAIL"
if swift -e "$mp_system_source" >/dev/null 2>&1; then mp_system_status="PASS"; fi
now_playing_status="FAIL"
if swift -e "$now_playing_source" >/dev/null 2>&1; then now_playing_status="PASS"; fi

outcome="no_public_system_music_queue_sdk_surface"
if [[ "$system_player_status" == "PASS" || "$mp_system_status" == "PASS" ]]; then
  outcome="system_music_player_candidate_manual_visible_parity_required"
elif [[ "$app_queue_status" == "PASS" || "$mp_application_queue_status" == "PASS" ]]; then
  outcome="application_player_queue_only_not_music_app_session"
fi

{
  echo "# Public SDK Music Queue Surface Probe"
  echo
  echo "timestamp_utc: $timestamp"
  echo "context_label: $context_label"
  echo "macos: $(sw_vers -productVersion)"
  echo "swift: $(swift -version | head -1)"
  echo "xcode:"
  xcodebuild -version 2>/dev/null | sed 's/^/  /' || echo "  unavailable"
  echo "sdk_path: ${sdk_path:-unavailable}"
  echo

  echo "## Compliance preflight"
  echo
  echo "public_surface_rule: public macOS SDK symbols and public framework headers only."
  echo "excluded_queue_sources: private frameworks; private headers; private AppleEvents; Music.app private databases/files; accessibility/UI scraping; memory inspection."
  echo "mutating_calls: none"
  echo "authorization_request: none"
  echo

  echo "## MusicKit compiler probes"
  echo
  run_swift_probe "musickit.ApplicationMusicPlayer.queue" "$app_queue_source"
  echo
  run_swift_probe "musickit.MusicPlayer.Queue.EntryInsertionPosition" "$app_insert_source"
  echo
  run_swift_probe "musickit.SystemMusicPlayer.shared" "$system_player_source"
  echo

  echo "## MediaPlayer compiler/runtime probes"
  echo
  run_swift_probe "mediaplayer.MPMusicPlayerController" "$mp_controller_source"
  echo
  run_swift_probe "mediaplayer.MPMusicPlayerController.applicationQueuePlayer" "$mp_application_queue_source"
  echo
  run_swift_probe "mediaplayer.MPMusicPlayerController.systemMusicPlayer" "$mp_system_source"
  echo
  run_swift_probe "mediaplayer.MPNowPlayingInfoCenter.default" "$now_playing_source"
  echo

  echo "## Public header excerpts"
  echo
  if [[ -n "$media_player_header" && -f "$media_player_header" ]]; then
    echo "header.mediaplayer.MPMusicPlayerController=$media_player_header"
    nl -ba "$media_player_header" | sed -n '53,67p'
  else
    echo "header.mediaplayer.MPMusicPlayerController=unavailable"
  fi
  echo
  if [[ -n "$now_playing_header" && -f "$now_playing_header" ]]; then
    echo "header.mediaplayer.MPNowPlayingInfoCenter=$now_playing_header"
    nl -ba "$now_playing_header" | sed -n '13,70p'
    nl -ba "$now_playing_header" | sed -n '103,109p'
  else
    echo "header.mediaplayer.MPNowPlayingInfoCenter=unavailable"
  fi
  echo

  echo "## Classification"
  echo
  echo "classification.outcome=$outcome"
  echo "classification.musickit_application_player_queue_compile=$app_queue_status"
  echo "classification.musickit_queue_insertion_position_compile=$app_insert_status"
  echo "classification.musickit_system_music_player_compile=$system_player_status"
  echo "classification.mediaplayer_music_player_controller_compile=$mp_controller_status"
  echo "classification.mediaplayer_application_queue_player_compile=$mp_application_queue_status"
  echo "classification.mediaplayer_system_music_player_compile=$mp_system_status"
  echo "classification.mediaplayer_now_playing_center_compile=$now_playing_status"
  echo

  echo "## Interpretation"
  echo
  echo "- ApplicationMusicPlayer queue availability is not Music.app session parity by itself; visible Up Next/history proof is still required."
  echo "- SystemMusicPlayer or MediaPlayer systemMusicPlayer availability would only make a future candidate; visible parity proof is still required before using it."
  echo "- MPNowPlayingInfoCenter is current-app now-playing metadata, not a Music.app queue reader."
} > "$out_file" 2>&1

echo "$out_file"
