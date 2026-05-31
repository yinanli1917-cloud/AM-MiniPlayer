#!/usr/bin/env bash
set -euo pipefail

out_dir=".codex/workspace/music-queue-probes"
context_label="unspecified"
duration_seconds="12"
until_event_count="0"
trigger_mode="none"
restore_delay_seconds="0.8"
mute_during_trigger="false"

usage() {
  cat <<'USAGE'
Usage:
  bash .codex/workspace/probe_music_distributed_notifications.sh [options]

Options:
  --context LABEL       Label for the current Music.app setup.
  --duration SECONDS    Passive listening duration. Default: 12.
  --until-event-count N Stop early after N observed notifications. Default: 0.
  --trigger MODE        none|playpause-restore. Default: none.
  --restore-delay SEC   Delay before restoring play/pause state. Default: 0.8.
  --mute-during-trigger Temporarily set Music.app volume to 0 during trigger.
  --out-dir DIR         Probe output directory. Default: .codex/workspace/music-queue-probes
  --help                Show this help.

Safety:
  By default this probe is passive. It listens to public Foundation
  DistributedNotificationCenter notifications that nanoPod already observes and
  does not change Music.app playback or queue state. The optional
  playpause-restore trigger uses public Music.app Apple Events to create one
  play/pause notification after the listener is installed, then restores the
  original play/pause state. With --mute-during-trigger, it also restores the
  original Music.app volume. It never mutates the queue.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      context_label="$2"
      shift 2
      ;;
    --duration)
      duration_seconds="$2"
      shift 2
      ;;
    --until-event-count)
      until_event_count="$2"
      shift 2
      ;;
    --trigger)
      trigger_mode="$2"
      shift 2
      ;;
    --restore-delay)
      restore_delay_seconds="$2"
      shift 2
      ;;
    --mute-during-trigger)
      mute_during_trigger="true"
      shift
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

if ! [[ "$duration_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "invalid --duration: $duration_seconds" >&2
  exit 2
fi
if ! [[ "$until_event_count" =~ ^[0-9]+$ ]]; then
  echo "invalid --until-event-count: $until_event_count" >&2
  exit 2
fi
case "$trigger_mode" in
  none|playpause-restore) ;;
  *)
    echo "invalid --trigger: $trigger_mode" >&2
    exit 2
    ;;
esac
if ! [[ "$restore_delay_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "invalid --restore-delay: $restore_delay_seconds" >&2
  exit 2
fi

mkdir -p "$out_dir"

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
context_slug="$(printf '%s' "$context_label" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//; s/-$//')"
if [[ -z "$context_slug" || "$context_slug" == "unspecified" ]]; then
  out_file="$out_dir/distributed-notifications-$timestamp.txt"
else
  out_file="$out_dir/distributed-notifications-$context_slug-$timestamp.txt"
fi

{
  echo "# Music.app Distributed Notification Probe"
  echo
  echo "timestamp_utc: $timestamp"
  echo "context_label: $context_label"
  echo "duration_seconds: $duration_seconds"
  echo "until_event_count: $until_event_count"
  echo "trigger_mode: $trigger_mode"
  echo "restore_delay_seconds: $restore_delay_seconds"
  echo "mute_during_trigger: $mute_during_trigger"
  echo "macos: $(sw_vers -productVersion)"
  echo

  echo "## Compliance preflight"
  echo
  echo "public_surface_rule: Foundation DistributedNotificationCenter, observing known Music.app notification names only."
  echo "observed_names: com.apple.Music.playerInfo, com.apple.iTunes.playerInfo, com.apple.Music.playlistChanged, com.apple.iTunes.playlistChanged"
  echo "excluded_queue_sources: private frameworks; private notification frameworks; private AppleEvents; Music.app private files/databases; accessibility/UI scraping; memory inspection."
  echo "contract_note: these notifications are treated as invalidation/metadata evidence only unless a payload exposes every visible queue row and passes a visible parity check."
  echo "row_carrier_key_rule: only queue/up-next/history/recent/tracks/entries-like keys are treated as possible row carriers; playlist/current-track metadata is context-only."
  echo "trigger_rule: default is passive; playpause-restore uses public Music.app Apple Events after observers are active and restores the original play/pause state; optional muting restores the original Music.app volume."
  echo

  echo "## Current Music.app AppleScript snapshot"
  echo
  osascript <<'APPLESCRIPT'
if application "Music" is not running then
    return "music.running=false"
end if

tell application "Music"
    set AppleScript's text item delimiters to linefeed
    set rows to {}
    set end of rows to "music.running=true"
    try
        set end of rows to "player_state=" & ((player state) as text)
    on error errMsg
        set end of rows to "player_state.error=" & errMsg
    end try
    try
        set end of rows to "current_track.name=" & (name of current track)
        set end of rows to "current_track.artist=" & (artist of current track)
        set end of rows to "current_track.album=" & (album of current track)
        set end of rows to "current_track.class=" & ((class of current track) as text)
        set end of rows to "current_track.persistent_id=" & (persistent ID of current track)
    on error errMsg
        set end of rows to "current_track.error=" & errMsg
    end try
    try
        set cp to current playlist
        set end of rows to "current_playlist.name=" & (name of cp)
        set end of rows to "current_playlist.class=" & ((class of cp) as text)
        set end of rows to "current_playlist.track_count=" & ((count of tracks of cp) as text)
    on error errMsg
        set end of rows to "current_playlist.error=" & errMsg
    end try
    return rows as text
end tell
APPLESCRIPT
  echo

  echo "## Notification capture"
  echo
  swift - "$duration_seconds" "$until_event_count" "$trigger_mode" "$restore_delay_seconds" "$mute_during_trigger" <<'SWIFT' 2>&1
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let duration = Double(args.first ?? "") ?? 12.0
let untilEventCount = Int(args.dropFirst().first ?? "") ?? 0
let triggerMode = args.dropFirst(2).first ?? "none"
let restoreDelay = Double(args.dropFirst(3).first ?? "") ?? 0.8
let muteDuringTrigger = (args.dropFirst(4).first ?? "false") == "true"
let names = [
    "com.apple.Music.playerInfo",
    "com.apple.iTunes.playerInfo",
    "com.apple.Music.playlistChanged",
    "com.apple.iTunes.playlistChanged"
]
let rowCarrierTerms = [
    "queue",
    "up next",
    "upnext",
    "history",
    "recent",
    "track list",
    "tracks",
    "entries"
]
let contextOnlyTerms = [
    "playlist",
    "current",
    "track",
    "artist",
    "album",
    "name",
    "player state",
    "persistent id",
    "persistentid",
    "total time",
    "store",
    "location",
    "genre",
    "rating"
]

let formatter = ISO8601DateFormatter()
var eventCount = 0
var allUserInfoKeys = Set<String>()
var rowCarrierUserInfoKeys = Set<String>()
var contextOnlyUserInfoKeys = Set<String>()
var triggerStarted = false
var triggerFinished = false

func sanitize(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

func describe(_ value: Any) -> String {
    if let string = value as? String {
        return sanitize(string)
    }
    if let number = value as? NSNumber {
        return number.stringValue
    }
    if let date = value as? Date {
        return formatter.string(from: date)
    }
    return sanitize(String(describing: value))
}

func shape(_ value: Any) -> String {
    if let array = value as? NSArray {
        return "array[count=\(array.count)]"
    }
    if let dictionary = value as? NSDictionary {
        return "dictionary[count=\(dictionary.count)]"
    }
    if value is String {
        return "string"
    }
    if value is NSNumber {
        return "number"
    }
    if value is Date {
        return "date"
    }
    return String(describing: type(of: value))
}

func containsAnyTerm(_ key: String, terms: [String]) -> Bool {
    let normalized = key.lowercased()
    return terms.contains { normalized.contains($0) }
}

@discardableResult
func runAppleScript(_ script: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, sanitize(output.trimmingCharacters(in: .whitespacesAndNewlines)))
    } catch {
        return (-1, sanitize(String(describing: error)))
    }
}

func currentMusicPlayerState() -> String {
    let result = runAppleScript("""
if application "Music" is running then
    tell application "Music" to return (player state as text)
else
    return "not running"
end if
""")
    if result.status == 0 {
        return result.output
    }
    return "error:\(result.output)"
}

func playPauseMusic() -> (status: Int32, output: String) {
    runAppleScript("tell application \"Music\" to playpause")
}

func currentMusicVolume() -> String {
    let result = runAppleScript("""
if application "Music" is running then
    tell application "Music" to return (sound volume as text)
else
    return "not running"
end if
""")
    if result.status == 0 {
        return result.output
    }
    return "error:\(result.output)"
}

func setMusicVolume(_ volume: String) -> (status: Int32, output: String) {
    runAppleScript("tell application \"Music\" to set sound volume to \(volume)")
}

func restoreMusicState(_ originalState: String) -> (status: Int32, output: String) {
    switch originalState.lowercased() {
    case "playing":
        return runAppleScript("tell application \"Music\" to play")
    case "paused", "stopped":
        return runAppleScript("tell application \"Music\" to pause")
    default:
        return (0, "restore_skipped_unrecognized_state=\(sanitize(originalState))")
    }
}

print("capture.started_at=\(formatter.string(from: Date()))")
print("capture.observer_names=\(names.joined(separator: ","))")
print("capture.duration_seconds=\(String(format: "%.3f", duration))")
print("capture.until_event_count=\(untilEventCount)")
print("capture.trigger_mode=\(triggerMode)")
print("capture.restore_delay_seconds=\(String(format: "%.3f", restoreDelay))")
print("capture.mute_during_trigger=\(muteDuringTrigger)")

let center = DistributedNotificationCenter.default()
var tokens: [NSObjectProtocol] = []

for rawName in names {
    let token = center.addObserver(
        forName: Notification.Name(rawName),
        object: nil,
        queue: .main
    ) { notification in
        eventCount += 1
        let prefix = "event[\(eventCount)]"
        print("\(prefix).received_at=\(formatter.string(from: Date()))")
        print("\(prefix).name=\(notification.name.rawValue)")
        print("\(prefix).object=\(notification.object.map { describe($0) } ?? "nil")")

        let userInfo = notification.userInfo ?? [:]
        let keys = userInfo.keys.map { String(describing: $0) }.sorted()
        keys.forEach { key in
            allUserInfoKeys.insert(key)
            if containsAnyTerm(key, terms: rowCarrierTerms) {
                rowCarrierUserInfoKeys.insert(key)
            } else if containsAnyTerm(key, terms: contextOnlyTerms) {
                contextOnlyUserInfoKeys.insert(key)
            }
        }

        print("\(prefix).userInfo.keys=\(keys.joined(separator: ","))")
        if keys.isEmpty {
            print("\(prefix).userInfo.empty=true")
        }
        for key in keys {
            if let value = userInfo.first(where: { String(describing: $0.key) == key })?.value {
                print("\(prefix).userInfoShape[\(key)]=\(shape(value))")
                print("\(prefix).userInfo[\(key)]=\(describe(value))")
            }
        }
    }
    tokens.append(token)
}

if triggerMode == "playpause-restore" {
    triggerStarted = true
    DispatchQueue.global().async {
        let originalState = currentMusicPlayerState()
        let originalVolume = currentMusicVolume()
        print("trigger.original_player_state=\(originalState)")
        print("trigger.original_volume=\(originalVolume)")
        print("trigger.started_at=\(formatter.string(from: Date()))")
        if muteDuringTrigger, Int(originalVolume) != nil {
            let muteResult = setMusicVolume("0")
            print("trigger.mute.status=\(muteResult.status)")
            if !muteResult.output.isEmpty {
                print("trigger.mute.output=\(muteResult.output)")
            }
        }
        let triggerResult = playPauseMusic()
        print("trigger.playpause.status=\(triggerResult.status)")
        if !triggerResult.output.isEmpty {
            print("trigger.playpause.output=\(triggerResult.output)")
        }
        Thread.sleep(forTimeInterval: restoreDelay)
        let restoreResult = restoreMusicState(originalState)
        print("trigger.restore.status=\(restoreResult.status)")
        if !restoreResult.output.isEmpty {
            print("trigger.restore.output=\(restoreResult.output)")
        }
        if muteDuringTrigger, Int(originalVolume) != nil {
            let volumeResult = setMusicVolume(originalVolume)
            print("trigger.volume_restore.status=\(volumeResult.status)")
            if !volumeResult.output.isEmpty {
                print("trigger.volume_restore.output=\(volumeResult.output)")
            }
        }
        print("trigger.final_player_state=\(currentMusicPlayerState())")
        print("trigger.final_volume=\(currentMusicVolume())")
        print("trigger.finished_at=\(formatter.string(from: Date()))")
        triggerFinished = true
    }
} else if triggerMode != "none" {
    print("trigger.error=unsupported_mode:\(triggerMode)")
}

let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    let nextTick = Date().addingTimeInterval(0.1)
    RunLoop.main.run(until: nextTick < deadline ? nextTick : deadline)
    if triggerStarted && !triggerFinished {
        continue
    }
    if untilEventCount > 0 && eventCount >= untilEventCount {
        break
    }
}

for token in tokens {
    center.removeObserver(token)
}

let allKeys = allUserInfoKeys.sorted()
let rowCarrierKeys = rowCarrierUserInfoKeys.sorted()
let contextKeys = contextOnlyUserInfoKeys.sorted()

print("capture.finished_at=\(formatter.string(from: Date()))")
print("capture.events_count=\(eventCount)")
print("capture.trigger_finished=\(triggerFinished)")
print("capture.userInfo.keys=\(allKeys.joined(separator: ","))")
print("capture.row_carrier_userInfo_keys=\(rowCarrierKeys.joined(separator: ","))")
print("capture.context_only_userInfo_keys=\(contextKeys.joined(separator: ","))")

if eventCount == 0 {
    print("classification.outcome=no_notifications_observed")
    print("classification.reason=No known Music.app distributed notification fired during the passive capture window.")
} else if rowCarrierKeys.isEmpty {
    print("classification.outcome=metadata_or_context_only_no_queue_row_keys_observed")
    print("classification.reason=Observed notification payloads had no queue/history/up-next/tracks/entries-like row carrier keys.")
} else {
    print("classification.outcome=queue_row_keys_present_manual_review_required")
    print("classification.reason=Observed notification payloads contained possible queue-row carrier keys; compare shapes and values against visible Music.app queue rows before any exact claim.")
}
SWIFT
  echo

  echo "## Interpretation checklist"
  echo
  echo "- A no-notification run is only an inconclusive passive capture; rerun while manually causing Music.app to emit a playerInfo event."
  echo "- A playpause-restore run is evidence for notification payload shape, not queue editing. It should restore the original play/pause state and, when muted, the original Music.app volume. It must never mutate the queue."
  echo "- Metadata/context-only keys support using distributed notifications as invalidation signals, not as queue/history row data."
  echo "- Row-carrier keys are not exact proof by name alone; their shapes and values must expose every visible Up Next/history row by order and identity."
  echo "- Do not use private notification frameworks or broad system notification scraping as an App Store queue source."
} > "$out_file" 2>&1

echo "$out_file"
