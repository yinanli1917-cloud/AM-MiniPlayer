#!/bin/bash
# READ-ONLY probe of Music.app's current playback/queue state via osascript.
# Prints player state, current track identity/class, current playlist
# readability + shape, and Up Next (tracks after current in currentPlaylist).
# Never mutates playback, playlists, shuffle, or repeat.
#
# Usage: scripts/probe_queue_source.sh [label]

LABEL="${1:-probe}"
TS() { date "+%H:%M:%S.%3N"; }

ms_now() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

run_osa() {
  local desc="$1"
  local script="$2"
  local t0 t1
  t0=$(ms_now)
  local out
  out=$(osascript -e "$script" 2>&1)
  local rc=$?
  t1=$(ms_now)
  printf '  [%s] (%dms, rc=%d): %s\n' "$desc" "$((t1 - t0))" "$rc" "$out"
}

echo "===== probe_queue_source: $LABEL @ $(TS) ====="

run_osa "player state" \
  'tell application "Music" to return player state as string'

run_osa "current track name" \
  'tell application "Music" to return name of current track'

run_osa "current track class" \
  'tell application "Music" to return class of current track as string'

run_osa "current track persistent ID" \
  'tell application "Music" to return persistent ID of current track'

run_osa "current track database ID" \
  'tell application "Music" to return database ID of current track'

run_osa "current track cloud status" \
  'try
     tell application "Music" to return cloud status of current track as string
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current stream title (radio)" \
  'try
     tell application "Music" to return current stream title
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current playlist exists" \
  'try
     tell application "Music"
       if (exists current playlist) then
         return "true"
       else
         return "false"
       end if
     end tell
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current playlist name" \
  'try
     tell application "Music" to return name of current playlist
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current playlist class" \
  'try
     tell application "Music" to return class of current playlist as string
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current playlist special kind" \
  'try
     tell application "Music" to return special kind of current playlist as string
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current playlist track count" \
  'try
     tell application "Music" to return count of tracks of current playlist
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "current track index in current playlist" \
  'try
     tell application "Music"
       set cp to current playlist
       set ct to current track
       set idx to 0
       set i to 0
       repeat with t in tracks of cp
         set i to i + 1
         if (persistent ID of t is persistent ID of ct) then
           set idx to i
           exit repeat
         end if
       end repeat
       return idx
     end tell
   on error errMsg
     return "ERROR: " & errMsg
   end try'

run_osa "tracks after current (Up Next count)" \
  'try
     tell application "Music"
       set cp to current playlist
       set ct to current track
       set total to count of tracks of cp
       set idx to 0
       set i to 0
       repeat with t in tracks of cp
         set i to i + 1
         if (persistent ID of t is persistent ID of ct) then
           set idx to i
           exit repeat
         end if
       end repeat
       if idx is 0 then
         return "current track not found in playlist tracks"
       else
         return (total - idx) as string
       end if
     end tell
   on error errMsg
     return "ERROR: " & errMsg
   end try'

echo "===== end $LABEL @ $(TS) ====="
echo
