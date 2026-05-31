#!/usr/bin/env bash
set -euo pipefail

out_dir=".codex/workspace/music-queue-probes"
context_label="unspecified"
visible_notes_file=""
probe_fixed_indexing="false"

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
    --visible-notes)
      visible_notes_file="$2"
      shift 2
      ;;
    --probe-fixed-indexing)
      probe_fixed_indexing="true"
      shift
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
  out_file="$out_dir/public-surface-$timestamp.txt"
  sdef_file="$out_dir/music-sdef-$timestamp.xml"
else
  out_file="$out_dir/public-surface-$context_slug-$timestamp.txt"
  sdef_file="$out_dir/music-sdef-$context_slug-$timestamp.xml"
fi
entitlements_file="Sources/MusicMiniPlayerApp/MusicMiniPlayer.entitlements"
sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
media_player_header=""
now_playing_header=""
if [[ -n "$sdk_path" ]]; then
  media_player_header="$sdk_path/System/Library/Frameworks/MediaPlayer.framework/Headers/MPMusicPlayerController.h"
  now_playing_header="$sdk_path/System/Library/Frameworks/MediaPlayer.framework/Headers/MPNowPlayingInfoCenter.h"
fi

{
  echo "# Music.app Public Queue Surface Probe"
  echo
  echo "timestamp_utc: $timestamp"
  echo "context_label: $context_label"
  echo "macos: $(sw_vers -productVersion)"
  echo "music_app: /System/Applications/Music.app"
  if [[ -n "$visible_notes_file" ]]; then
    echo "visible_notes_file: $visible_notes_file"
  fi
  echo

  echo "## Compliance preflight"
  echo
  echo "public_surface_rule: Apple Events through Music.app sdef, public MusicKit/MediaPlayer SDK symbols, and Apple Music API metadata/history only."
  echo "excluded_queue_sources: private frameworks; private AppleEvents; Music.app private databases/files; accessibility/UI scraping; memory inspection."
  echo "fixed_indexing_variant_probe: $probe_fixed_indexing"
  if [[ "$probe_fixed_indexing" == "true" ]]; then
    echo "fixed_indexing_probe_rule: probe-only public Apple Event setting toggle; original value is restored; no playback or queue mutation."
  fi
  if [[ -f "$entitlements_file" ]]; then
    echo "entitlements_file: $entitlements_file"
    if /usr/bin/plutil -p "$entitlements_file" | rg -q '"com.apple.security.automation.apple-events" => true'; then
      echo "entitlements.apple_events: true"
    else
      echo "entitlements.apple_events: false_or_unreadable"
    fi
    if /usr/bin/plutil -p "$entitlements_file" | rg -q 'temporary-exception\.files\.home-relative-path\.read-only|PlaybackSessions'; then
      echo "entitlements.private_music_storage_exception: PRESENT"
      echo "compliance.note: do not use Music.app PlaybackSessions/private files as a real queue source for App Store parity."
    else
      echo "entitlements.private_music_storage_exception: absent"
    fi
  else
    echo "entitlements_file: missing"
  fi
  echo

  echo "## MusicKit macOS compiler probes"
  echo
  echo "ApplicationMusicPlayer:"
  if swift -e 'import MusicKit; if #available(macOS 14.0, *) { print(type(of: ApplicationMusicPlayer.shared.queue)) }' 2>&1; then
    echo "ApplicationMusicPlayer compile: PASS"
  else
    echo "ApplicationMusicPlayer compile: FAIL"
  fi
  echo
  echo "SystemMusicPlayer:"
  if swift -e 'import MusicKit; if #available(macOS 14.0, *) { print(SystemMusicPlayer.shared) }' 2>&1; then
    echo "SystemMusicPlayer compile: PASS"
  else
    echo "SystemMusicPlayer compile: FAIL"
  fi
  echo

  echo "## MediaPlayer macOS compiler probes"
  echo
  echo "MPMusicPlayerController:"
  if swift -e 'import MediaPlayer; print(MPMusicPlayerController.self)' 2>&1; then
    echo "MPMusicPlayerController compile: PASS"
  else
    echo "MPMusicPlayerController compile: FAIL"
  fi
  echo
  echo "MPMusicPlayerController.applicationQueuePlayer:"
  if swift -e 'import MediaPlayer; print(MPMusicPlayerController.applicationQueuePlayer)' 2>&1; then
    echo "MPMusicPlayerController.applicationQueuePlayer compile: PASS"
  else
    echo "MPMusicPlayerController.applicationQueuePlayer compile: FAIL"
  fi
  echo
  echo "MPMusicPlayerController.systemMusicPlayer:"
  if swift -e 'import MediaPlayer; print(MPMusicPlayerController.systemMusicPlayer)' 2>&1; then
    echo "MPMusicPlayerController.systemMusicPlayer compile: PASS"
  else
    echo "MPMusicPlayerController.systemMusicPlayer compile: FAIL"
  fi
  echo
  if [[ -n "$media_player_header" && -f "$media_player_header" ]]; then
    echo "MediaPlayer public header excerpt:"
    echo "header: $media_player_header"
    nl -ba "$media_player_header" | sed -n '53,67p'
  else
    echo "MediaPlayer public header excerpt: unavailable"
  fi
  echo
  echo "MPNowPlayingInfoCenter.default:"
  if swift - <<'SWIFT' 2>&1; then
import MediaPlayer

let center = MPNowPlayingInfoCenter.default()
print("mp_now_playing.available=true")
print("mp_now_playing.info=\(String(describing: center.nowPlayingInfo))")
if #available(macOS 10.12.2, *) {
    print("mp_now_playing.playback_state=\(center.playbackState.rawValue)")
}
SWIFT
    echo "MPNowPlayingInfoCenter.default runtime: PASS"
  else
    echo "MPNowPlayingInfoCenter.default runtime: FAIL"
  fi
  echo
  if [[ -n "$now_playing_header" && -f "$now_playing_header" ]]; then
    echo "MPNowPlayingInfoCenter public header excerpt:"
    echo "header: $now_playing_header"
    nl -ba "$now_playing_header" | sed -n '13,70p'
    nl -ba "$now_playing_header" | sed -n '103,109p'
  else
    echo "MPNowPlayingInfoCenter public header excerpt: unavailable"
  fi
  echo

  echo "## Music.app scripting dictionary queue-like terms"
  echo
  sdef /System/Applications/Music.app > "$sdef_file"
  echo "captured_sdef: $sdef_file"
  echo
  rg -n -i 'queue|up next|history|recent|selection|selected|select|current playlist|current track|next track|previous track|play later|play next|once' "$sdef_file" || true
  echo
  echo "Exact public queue/history object declarations:"
  if rg -n -i 'name="(queue|up next|play next|play later|history|recent)' "$sdef_file"; then
    echo "sdef_exact_queue_terms: PRESENT"
  else
    echo "sdef_exact_queue_terms: ABSENT"
  fi
  echo

  echo "## Runtime AppleScript snapshot"
  echo
  osascript <<'APPLESCRIPT'
on appendSelectionDescription(rows, label, itemRef)
    tell application "Music"
        try
            set itemClass to ((class of itemRef) as text)
        on error errMsg
            set itemClass to "error:" & errMsg
        end try
        set end of rows to label & ".class=" & itemClass

        try
            set end of rows to label & ".name=" & (name of itemRef)
        on error errMsg
            set end of rows to label & ".name.error=" & errMsg
        end try

        try
            set end of rows to label & ".artist=" & (artist of itemRef)
        end try
        try
            set end of rows to label & ".album=" & (album of itemRef)
        end try
        try
            set end of rows to label & ".persistent_id=" & (persistent ID of itemRef)
        end try
        try
            set end of rows to label & ".database_id=" & ((database ID of itemRef) as text)
        end try
        try
            set end of rows to label & ".index=" & ((index of itemRef) as text)
        end try
    end tell
    return rows
end appendSelectionDescription

on appendSelectionList(rows, label, selectedItems)
    try
        set selectedCount to count of selectedItems
        set end of rows to label & ".count=" & (selectedCount as text)
        repeat with i from 1 to selectedCount
            if i > 20 then
                set end of rows to label & ".truncated_after=20"
                exit repeat
            end if
            set rows to my appendSelectionDescription(rows, label & "[" & (i as text) & "]", item i of selectedItems)
        end repeat
    on error errMsg
        set end of rows to label & ".count.error=" & errMsg
        set rows to my appendSelectionDescription(rows, label, selectedItems)
    end try
    return rows
end appendSelectionList

on appendPlaylistSummary(rows, label, playlistRef)
    tell application "Music"
        try
            set end of rows to label & ".name=" & (name of playlistRef)
        on error errMsg
            set end of rows to label & ".name.error=" & errMsg
        end try
        try
            set end of rows to label & ".class=" & ((class of playlistRef) as text)
        end try
        try
            set end of rows to label & ".special_kind=" & ((special kind of playlistRef) as text)
        end try
        try
            set end of rows to label & ".visible=" & ((visible of playlistRef) as text)
        end try
        try
            set end of rows to label & ".track_count=" & ((count of tracks of playlistRef) as text)
        end try
    end tell
    return rows
end appendPlaylistSummary

on playlistContainsPersistentID(playlistRef, currentID)
    if currentID is "" then return false

    tell application "Music"
        try
            set trackTotal to count of tracks of playlistRef
            if trackTotal > 5000 then return false
            repeat with i from 1 to trackTotal
                try
                    if persistent ID of track i of playlistRef is currentID then return true
                end try
            end repeat
        end try
    end tell
    return false
end playlistContainsPersistentID

on isQueueLikePlaylistName(playlistName)
    set candidateName to playlistName as text
    set queuePatterns to {"Up Next", "up next", "Playing Next", "playing next", "Play Queue", "play queue", "Queue", "queue", "队列", "待播", "接着播放", "播放队列", "次に再生", "다음"}
    repeat with queuePattern in queuePatterns
        try
            if candidateName contains (queuePattern as text) then return true
        end try
    end repeat
    return false
end isQueueLikePlaylistName

on appendPlaylistNeighborWindow(rows, label, playlistRef, currentID)
    tell application "Music"
        try
            set trackTotal to count of tracks of playlistRef
            if currentID is "" then
                set end of rows to label & ".neighbors.skipped=no_current_persistent_id"
                return rows
            end if

            if trackTotal > 5000 then
                set end of rows to label & ".neighbors.skipped=track_count_exceeds_probe_limit"
                return rows
            end if

            set foundIndex to 0
            set foundCount to 0
            repeat with i from 1 to trackTotal
                try
                    if persistent ID of track i of playlistRef is currentID then
                        set foundCount to foundCount + 1
                        if foundIndex is 0 then set foundIndex to i
                    end if
                end try
            end repeat
            set end of rows to label & ".current_id_occurrences=" & (foundCount as text)

            if foundIndex is 0 then
                set end of rows to label & ".neighbors.skipped=current_not_in_view"
                return rows
            end if

            set lowerBound to foundIndex - 5
            if lowerBound < 1 then set lowerBound to 1
            set upperBound to foundIndex + 10
            if upperBound > trackTotal then set upperBound to trackTotal
            set end of rows to label & ".neighbor_window=" & (lowerBound as text) & ".." & (upperBound as text) & " current=" & (foundIndex as text)

            repeat with i from lowerBound to upperBound
                try
                    set t to track i of playlistRef
                    set marker to " "
                    if i is foundIndex then set marker to "*"
                    set end of rows to label & ".neighbor[" & (i as text) & "]=" & marker & "|" & (name of t) & "|" & (artist of t) & "|" & (album of t) & "|" & (persistent ID of t)
                on error errMsg
                    set end of rows to label & ".neighbor[" & (i as text) & "].error=" & errMsg
                end try
            end repeat
        on error errMsg
            set end of rows to label & ".neighbors.error=" & errMsg
        end try
    end tell
    return rows
end appendPlaylistNeighborWindow

tell application "Music"
    if it is not running then
        return "Music.app is not running"
    end if

    set AppleScript's text item delimiters to linefeed
    set rows to {}
    set publicQueueCandidate to "unknown"
    set currentPlaylistAvailable to "unknown"
    set currentTrackClassValue to "unknown"
    set currentTrackPersistentIDValue to ""
    set windowViewSurfaceCandidate to "none"

    set end of rows to "player_state=" & ((player state) as text)
    set end of rows to "shuffle_enabled=" & ((shuffle enabled) as text)
    set end of rows to "song_repeat=" & ((song repeat) as text)
    set end of rows to "player_position=" & ((player position) as text)
    try
        set end of rows to "current_stream_title=" & ((current stream title) as text)
    end try
    try
        set end of rows to "current_stream_url=" & ((current stream URL) as text)
    end try

    try
        set end of rows to "current_track.name=" & (name of current track)
        set end of rows to "current_track.artist=" & (artist of current track)
        set end of rows to "current_track.album=" & (album of current track)
        set currentTrackPersistentIDValue to persistent ID of current track
        set currentTrackClassValue to ((class of current track) as text)
        set end of rows to "current_track.persistent_id=" & currentTrackPersistentIDValue
        set end of rows to "current_track.class=" & currentTrackClassValue
        set end of rows to "current_track.index=" & ((index of current track) as text)
    on error errMsg
        set end of rows to "current_track.error=" & errMsg
    end try

    try
        set cp to current playlist
        set end of rows to "current_playlist.name=" & (name of cp)
        set end of rows to "current_playlist.class=" & ((class of cp) as text)
        set end of rows to "current_playlist.special_kind=" & ((special kind of cp) as text)
        set end of rows to "current_playlist.visible=" & ((visible of cp) as text)
        set end of rows to "current_playlist.track_count=" & ((count of tracks of cp) as text)
        set currentPlaylistAvailable to "true"
    on error errMsg
        set end of rows to "current_playlist.error=" & errMsg
        set currentPlaylistAvailable to "false"
    end try

    try
        set browserViews to {}
        repeat with wIndex from 1 to (count of browser windows)
            try
                set viewPlaylist to view of browser window wIndex
                set end of browserViews to (name of viewPlaylist)
                set rows to my appendPlaylistSummary(rows, "browser_window[" & (wIndex as text) & "].view", viewPlaylist)
                set rows to my appendPlaylistNeighborWindow(rows, "browser_window[" & (wIndex as text) & "].view", viewPlaylist, currentTrackPersistentIDValue)
                if windowViewSurfaceCandidate is "none" and my playlistContainsPersistentID(viewPlaylist, currentTrackPersistentIDValue) then
                    set windowViewSurfaceCandidate to "browser_window_view_contains_current_track"
                end if
            on error errMsg
                set end of rows to "browser_window[" & (wIndex as text) & "].view.error=" & errMsg
                set end of browserViews to "error:" & errMsg
            end try
        end repeat
        set end of rows to "browser_window.views=" & (browserViews as text)
    on error errMsg
        set end of rows to "browser_window.views.error=" & errMsg
    end try

    try
        set playlistWindowViews to {}
        repeat with wIndex from 1 to (count of playlist windows)
            try
                set viewPlaylist to view of playlist window wIndex
                set end of playlistWindowViews to (name of viewPlaylist)
                set rows to my appendPlaylistSummary(rows, "playlist_window[" & (wIndex as text) & "].view", viewPlaylist)
                set rows to my appendPlaylistNeighborWindow(rows, "playlist_window[" & (wIndex as text) & "].view", viewPlaylist, currentTrackPersistentIDValue)
                if windowViewSurfaceCandidate is "none" and my playlistContainsPersistentID(viewPlaylist, currentTrackPersistentIDValue) then
                    set windowViewSurfaceCandidate to "playlist_window_view_contains_current_track"
                end if
            on error errMsg
                set end of rows to "playlist_window[" & (wIndex as text) & "].view.error=" & errMsg
                set end of playlistWindowViews to "error:" & errMsg
            end try
        end repeat
        set end of rows to "playlist_window.views=" & (playlistWindowViews as text)
    on error errMsg
        set end of rows to "playlist_window.views.error=" & errMsg
    end try

    set selectionSurfaceCandidate to "none"
    try
        set selectedItems to selection
        set end of rows to "application.selection.raw_class=" & ((class of selectedItems) as text)
        set rows to my appendSelectionList(rows, "application.selection", selectedItems)
        try
            if (count of selectedItems) > 0 then set selectionSurfaceCandidate to "selected_visible_items_only"
        end try
    on error errMsg
        set end of rows to "application.selection.error=" & errMsg
    end try

    try
        repeat with wIndex from 1 to (count of browser windows)
            try
                set selectedItems to selection of browser window wIndex
                set rows to my appendSelectionList(rows, "browser_window[" & (wIndex as text) & "].selection", selectedItems)
            on error errMsg
                set end of rows to "browser_window[" & (wIndex as text) & "].selection.error=" & errMsg
            end try
        end repeat
    on error errMsg
        set end of rows to "browser_window.selection_scan.error=" & errMsg
    end try

    try
        repeat with wIndex from 1 to (count of playlist windows)
            try
                set selectedItems to selection of playlist window wIndex
                set rows to my appendSelectionList(rows, "playlist_window[" & (wIndex as text) & "].selection", selectedItems)
            on error errMsg
                set end of rows to "playlist_window[" & (wIndex as text) & "].selection.error=" & errMsg
            end try
        end repeat
    on error errMsg
        set end of rows to "playlist_window.selection_scan.error=" & errMsg
    end try

    try
        set upNextNamedPlaylists to {}
        set queueLikePlaylistNames to {}
        repeat with p in (get every playlist)
            try
                set playlistName to name of p
                if playlistName contains "Up Next" then set end of upNextNamedPlaylists to playlistName
                if my isQueueLikePlaylistName(playlistName) then
                    set end of queueLikePlaylistNames to playlistName
                    set candidateIndex to count of queueLikePlaylistNames
                    set candidateLabel to "queue_like_playlist[" & (candidateIndex as text) & "]"
                    set rows to my appendPlaylistSummary(rows, candidateLabel, p)
                    set rows to my appendPlaylistNeighborWindow(rows, candidateLabel, p, currentTrackPersistentIDValue)
                end if
            end try
        end repeat
        set end of rows to "playlists_named_up_next=" & (upNextNamedPlaylists as text)
        set end of rows to "queue_like_playlists=" & (queueLikePlaylistNames as text)
        set end of rows to "queue_like_playlist_count=" & ((count of queueLikePlaylistNames) as text)
        if (count of queueLikePlaylistNames) > 0 then
            set publicQueueCandidate to "queue_like_named_playlist"
        else
            set publicQueueCandidate to "none"
        end if
    on error errMsg
        set end of rows to "playlists_named_up_next.error=" & errMsg
    end try

    try
        set hiddenPlaylists to {}
        repeat with p in (get every playlist)
            try
                if visible of p is false then set end of hiddenPlaylists to (name of p)
            end try
        end repeat
        set end of rows to "hidden_playlists=" & (hiddenPlaylists as text)
    on error errMsg
        set end of rows to "hidden_playlists.error=" & errMsg
    end try

    try
        set cp to current playlist
        set currentID to persistent ID of current track
        set trackTotal to count of tracks of cp
        set foundIndex to 0
        repeat with i from 1 to trackTotal
            try
                if persistent ID of track i of cp is currentID then
                    set foundIndex to i
                    exit repeat
                end if
            end try
        end repeat

        set lowerBound to foundIndex - 5
        if lowerBound < 1 then set lowerBound to 1
        set upperBound to foundIndex + 10
        if upperBound > trackTotal then set upperBound to trackTotal
        set end of rows to "current_playlist.neighbor_window=" & (lowerBound as text) & ".." & (upperBound as text) & " current=" & (foundIndex as text)

        repeat with i from lowerBound to upperBound
            try
                set t to track i of cp
                set marker to " "
                if i is foundIndex then set marker to "*"
                set end of rows to "neighbor[" & (i as text) & "]=" & marker & "|" & (name of t) & "|" & (artist of t) & "|" & (album of t) & "|" & (persistent ID of t)
            on error errMsg
                set end of rows to "neighbor[" & (i as text) & "].error=" & errMsg
            end try
        end repeat
    on error errMsg
        set end of rows to "current_playlist.neighbors.error=" & errMsg
    end try

    set outcome to "partial"
    if publicQueueCandidate is "queue_like_named_playlist" then
        set outcome to "manual_compare_required_queue_like_named_playlist"
    else if windowViewSurfaceCandidate is not "none" then
        set outcome to "partial_window_view_neighbors_only"
    else if currentPlaylistAvailable is "false" then
        set outcome to "unavailable_no_current_playlist"
    else if currentTrackClassValue is "URL track" then
        set outcome to "unavailable_url_track_without_public_queue"
    else
        set outcome to "partial_current_playlist_neighbors_only"
    end if

    set end of rows to "classification.public_queue_candidate=" & publicQueueCandidate
    set end of rows to "classification.selection_surface_candidate=" & selectionSurfaceCandidate
    set end of rows to "classification.window_view_surface_candidate=" & windowViewSurfaceCandidate
    set end of rows to "classification.current_playlist_available=" & currentPlaylistAvailable
    set end of rows to "classification.track_class=" & currentTrackClassValue
    set end of rows to "classification.outcome=" & outcome

    return rows as text
end tell
APPLESCRIPT
  echo

  if [[ "$probe_fixed_indexing" == "true" ]]; then
    echo "## Runtime AppleScript fixed-indexing variant probe"
    echo
    osascript <<'APPLESCRIPT'
on appendNeighborRows(rows, label, playlistRef, currentID)
    tell application "Music"
        try
            set trackTotal to count of tracks of playlistRef
            set end of rows to label & ".track_count=" & (trackTotal as text)
            if currentID is "" then
                set end of rows to label & ".neighbors.skipped=no_current_persistent_id"
                return rows
            end if
            if trackTotal > 5000 then
                set end of rows to label & ".neighbors.skipped=track_count_exceeds_probe_limit"
                return rows
            end if

            set foundIndex to 0
            set foundCount to 0
            repeat with i from 1 to trackTotal
                try
                    if persistent ID of track i of playlistRef is currentID then
                        set foundCount to foundCount + 1
                        if foundIndex is 0 then set foundIndex to i
                    end if
                end try
            end repeat
            set end of rows to label & ".current_id_occurrences=" & (foundCount as text)
            if foundIndex is 0 then
                set end of rows to label & ".neighbors.skipped=current_not_in_playlist"
                return rows
            end if

            set lowerBound to foundIndex - 5
            if lowerBound < 1 then set lowerBound to 1
            set upperBound to foundIndex + 10
            if upperBound > trackTotal then set upperBound to trackTotal
            set end of rows to label & ".neighbor_window=" & (lowerBound as text) & ".." & (upperBound as text) & " current=" & (foundIndex as text)

            repeat with i from lowerBound to upperBound
                try
                    set t to track i of playlistRef
                    set marker to " "
                    if i is foundIndex then set marker to "*"
                    set end of rows to label & ".neighbor[" & (i as text) & "]=" & marker & "|" & (name of t) & "|" & (artist of t) & "|" & (album of t) & "|" & (persistent ID of t)
                on error errMsg
                    set end of rows to label & ".neighbor[" & (i as text) & "].error=" & errMsg
                end try
            end repeat
        on error errMsg
            set end of rows to label & ".neighbors.error=" & errMsg
        end try
    end tell
    return rows
end appendNeighborRows

tell application "Music"
    if it is not running then
        return "fixed_indexing_variant.music_running=false"
    end if

    set AppleScript's text item delimiters to linefeed
    set rows to {}
    set originalFixedIndexing to missing value
    set restoredFixedIndexing to "false"
    set currentID to ""

    try
        set originalFixedIndexing to fixed indexing
        set end of rows to "fixed_indexing.original=" & ((originalFixedIndexing) as text)
    on error errMsg
        set end of rows to "fixed_indexing.original.error=" & errMsg
    end try

    try
        set currentID to persistent ID of current track
        set end of rows to "fixed_indexing.current_track=" & (name of current track) & "|" & (artist of current track) & "|" & currentID
    on error errMsg
        set end of rows to "fixed_indexing.current_track.error=" & errMsg
    end try

    repeat with variantValue in {false, true}
        set variantFlag to contents of variantValue
        if variantFlag is true then
            set variantLabel to "true"
        else
            set variantLabel to "false"
        end if

        try
            set fixed indexing to variantFlag
            set end of rows to "fixed_indexing.variant[" & variantLabel & "].set=ok"
            try
                set cp to current playlist
                set end of rows to "fixed_indexing.variant[" & variantLabel & "].current_playlist.name=" & (name of cp)
                set rows to my appendNeighborRows(rows, "fixed_indexing.variant[" & variantLabel & "].current_playlist", cp, currentID)
            on error errMsg
                set end of rows to "fixed_indexing.variant[" & variantLabel & "].current_playlist.error=" & errMsg
            end try
        on error errMsg
            set end of rows to "fixed_indexing.variant[" & variantLabel & "].set.error=" & errMsg
        end try
    end repeat

    if originalFixedIndexing is not missing value then
        try
            set fixed indexing to originalFixedIndexing
            set restoredFixedIndexing to "true"
            set end of rows to "fixed_indexing.restored=true"
        on error errMsg
            set end of rows to "fixed_indexing.restored.error=" & errMsg
        end try
    end if

    if restoredFixedIndexing is "true" then
        set end of rows to "fixed_indexing_variant.outcome=restored_compare_visible_required"
    else
        set end of rows to "fixed_indexing_variant.outcome=restore_failed_do_not_use"
    end if

    return rows as text
end tell
APPLESCRIPT
    echo
  fi

  echo "## Interpretation checklist"
  echo
  echo "- Context label is only a test label; it is not proof of playback origin."
  echo "- Compare the visible Music.app Up Next panel manually against neighbor[...] rows."
  echo "- Compare queue_like_playlist[*].neighbor[...] rows when testing whether public queue-like named playlists expose the visible queue."
  echo "- Compare browser_window[*].view.neighbor[...] and playlist_window[*].view.neighbor[...] rows when testing whether public window views expose the visible queue."
  echo "- Compare application.selection[...] and window selection rows when testing whether Music.app exposes visible queue selections through public AppleEvents."
  echo "- When --probe-fixed-indexing is used, compare fixed_indexing.variant[...] rows against visible Up Next before considering whether AppleScript play-order indexing helps a context."
  echo "- The fixed-indexing variant is probe-only and must restore the original fixed indexing value before its output can be considered."
  echo "- A window view surface is still only a public playlist view; it is not exact queue proof unless it exposes every visible history/current/upcoming row by order and identity."
  echo "- A queue-like named playlist is still only a candidate public playlist; it is not exact queue proof unless it exposes every visible history/current/upcoming row by order and identity."
  echo "- A selection surface is selected visible items only; it is not exact queue proof unless it exposes every visible history/current/upcoming row by order and identity."
  echo "- If Play Next / Play Later edits appear in Music.app but not in this snapshot, currentPlaylist scanning is not a real queue mirror."
  echo "- If radio/station playback has no current playlist tracks or unrelated neighbors, mark that context unavailable."
  echo "- Treat ApplicationMusicPlayer.queue as app-local unless a separate proof shows it targets the same Music.app playback session on macOS."
  echo "- For focused ApplicationMusicPlayer runtime evidence, run .codex/workspace/probe_musickit_application_player_queue.sh."
  echo "- Treat SystemMusicPlayer as unavailable on macOS unless the local SDK compiler probe changes."
  echo "- Treat MediaPlayer MPMusicPlayerController as unavailable on macOS unless the local SDK compiler probe changes."
  echo "- Treat MPNowPlayingInfoCenter as current-application now-playing metadata, not system Music.app queue state."
  echo "- Do not treat Apple Music recently played API data as live queue proof."

  if [[ -n "$visible_notes_file" ]]; then
    echo
    echo "## Visible Music.app notes"
    echo
    if [[ -f "$visible_notes_file" ]]; then
      sed -n '1,220p' "$visible_notes_file"
    else
      echo "visible_notes.error=missing file: $visible_notes_file"
    fi
  fi
} > "$out_file" 2>&1

echo "$out_file"
