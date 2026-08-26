#!/usr/bin/env python3
"""nanoPod real-app end-to-end smoke.

Opens the signed nanoPod.app, drives Apple Music via osascript, and asserts
from JSONL events / status snapshots. No screen recording, no computer use.

Always archives system + Music volume, mutes for the run, and restores
playback + volume in a finally block.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "nanoPod.app"
APP_BIN = APP / "Contents" / "MacOS" / "nanoPod"
BUNDLE_ID = "com.yinanli.nanoPod"
LYRICS_BUDGET_S = 3.0
# A-rule 2026-08-26: original lyrics ≤ 3s is the hard fail. Translation is a
# sidecar — if it lands inside 3s it ships with the original; if later, the
# original still PASSES and translation is recorded as a hot-insert.

# Visual-harness fixtures already known to live in the founder's library.
TRACK_TRANSLATION = {
    "id": "cold_translation",
    "title": "Stardust Night",
    "artist": "JADOES",
    "expect_translation": True,
}
TRACK_CHURN_A = {
    "id": "churn_a",
    "title": "冬天一個遊",
    "artist": "Gordon Flanders",
    "expect_translation": False,
}
TRACK_CHURN_B = {
    "id": "churn_b",
    "title": "尋開心",
    "artist": "Bondy Chiu",
    "expect_translation": False,
}
NO_LYRICS_CANDIDATES = [
    {"title": "Tangerine Bossa", "artist": "Don Tung"},
    {"title": "Oceanside Café", "artist": "CinCin Lee"},
    {"title": "Oceanside Cafe", "artist": "CinCin Lee"},
    {"title": "Fresh Trip", "artist": "CinCin Lee"},
    {"title": "Gentle Wave", "artist": "Jiro Inagaki and His Soul Media"},
    {"title": "Love Is Free", "artist": "Brenton Wood"},
]


def now_ms() -> int:
    return int(time.time() * 1000)


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def run(
    cmd: list[str],
    check: bool = True,
    timeout: float | None = 30,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=True,
        timeout=timeout,
        env=env,
    )


def osa(script: str, *args: str, check: bool = True, timeout: float = 30) -> str:
    cmd = ["osascript", "-e", script, *args]
    result = run(cmd, check=check, timeout=timeout)
    if result.returncode != 0 and check:
        raise SystemExit(f"osascript failed: {result.stderr.strip() or result.stdout.strip()}")
    return (result.stdout or "").strip()


def pids_named(name: str) -> list[int]:
    result = run(["pgrep", "-x", name], check=False)
    return [int(line) for line in result.stdout.splitlines() if line.strip().isdigit()]


def find_music_track(title: str, artist: str) -> str | None:
    script = r'''
on run argv
    set targetTitle to item 1 of argv
    set targetArtist to item 2 of argv
    tell application "Music"
        if it is not running then run
        try
            set searchResults to search library playlist 1 for targetTitle only songs
        on error
            return "NOT_FOUND"
        end try
        repeat with candidateTrack in searchResults
            if (name of candidateTrack is targetTitle) and (artist of candidateTrack is targetArtist) then
                return (persistent ID of candidateTrack)
            end if
        end repeat
        repeat with candidateTrack in searchResults
            if (name of candidateTrack contains targetTitle) and (artist of candidateTrack contains targetArtist) then
                return (persistent ID of candidateTrack)
            end if
        end repeat
        return "NOT_FOUND"
    end tell
end run
'''
    output = osa(script, title, artist, check=False)
    if not output or output == "NOT_FOUND":
        return None
    return output


def play_music_track(title: str, artist: str) -> str | None:
    script = r'''
on run argv
    set targetTitle to item 1 of argv
    set targetArtist to item 2 of argv
    tell application "Music"
        if it is not running then run
        try
            set shuffle enabled to false
        end try
        try
            set song repeat to one
        end try
        set targetTrack to missing value
        try
            set searchResults to search library playlist 1 for targetTitle only songs
        on error
            set searchResults to {}
        end try
        repeat with candidateTrack in searchResults
            if (name of candidateTrack is targetTitle) and (artist of candidateTrack is targetArtist) then
                set targetTrack to candidateTrack
                exit repeat
            end if
        end repeat
        if targetTrack is missing value then
            repeat with candidateTrack in searchResults
                if (name of candidateTrack contains targetTitle) and (artist of candidateTrack contains targetArtist) then
                    set targetTrack to candidateTrack
                    exit repeat
                end if
            end repeat
        end if
        if targetTrack is missing value then return "NOT_FOUND"
        set harnessPlaylistName to "nanoPod E2E Smoke"
        if not (exists user playlist harnessPlaylistName) then
            make new user playlist with properties {name:harnessPlaylistName}
        end if
        set harnessPlaylist to user playlist harnessPlaylistName
        try
            delete every track of harnessPlaylist
        end try
        duplicate targetTrack to harnessPlaylist
        play harnessPlaylist
        delay 0.5
        if player state is not playing then play
        set waitCount to 0
        repeat while waitCount < 10
            try
                if (name of current track is (name of targetTrack)) then exit repeat
            end try
            delay 0.2
            play harnessPlaylist
            set waitCount to waitCount + 1
        end repeat
        set trackID to persistent ID of targetTrack
        set trackName to name of targetTrack
        set trackArtist to artist of targetTrack
        return trackID & "	" & trackName & "	" & trackArtist
    end tell
end run
'''
    output = osa(script, title, artist, timeout=45, check=False)
    if not output or output == "NOT_FOUND":
        return None
    return output


def set_player_position(seconds: float) -> str:
    script = f'''
tell application "Music"
    if it is not running then return "MUSIC_NOT_RUNNING"
    if player state is not playing then play
    set tries to 0
    repeat while tries < 20
        try
            set currentPos to player position
            if currentPos is not missing value and currentPos > 1 then exit repeat
        end try
        delay 0.25
        set tries to tries + 1
    end repeat
    set player position to {int(seconds)}
    delay 0.4
    try
        set afterPos to player position
        if afterPos is missing value or afterPos < ({int(seconds)} - 8) then
            delay 0.5
            set player position to {int(seconds)}
            delay 0.4
            set afterPos to player position
        end if
        if player state is not playing then play
        return afterPos as text
    on error
        return "POSITION_UNREADABLE"
    end try
end tell
'''
    return osa(script, check=False)


def snapshot_system_and_music() -> dict[str, Any]:
    script = r'''
set sysMuted to output muted of (get volume settings)
set sysVol to output volume of (get volume settings)
set musicRunning to false
set musicVol to ""
set musicState to "not_running"
set musicPid to ""
set musicPos to ""
set musicName to ""
set musicArtist to ""
set musicShuffle to ""
set musicRepeat to ""
tell application "System Events"
    set musicRunning to (exists process "Music")
end tell
if musicRunning then
    tell application "Music"
        set musicVol to sound volume as text
        set musicState to player state as text
        try
            set musicShuffle to shuffle enabled as text
        end try
        try
            set musicRepeat to song repeat as text
        end try
        try
            set musicPid to persistent ID of current track
            set musicName to name of current track
            set musicArtist to artist of current track
            set musicPos to player position as text
        end try
    end tell
end if
return (sysVol as text) & "	" & (sysMuted as text) & "	" & (musicRunning as text) & "	" & musicVol & "	" & musicState & "	" & musicPid & "	" & musicPos & "	" & musicName & "	" & musicArtist & "	" & musicShuffle & "	" & musicRepeat
'''
    raw = osa(script)
    parts = raw.split("\t")
    while len(parts) < 11:
        parts.append("")
    return {
        "system_volume": parts[0],
        "system_muted": parts[1].lower() == "true",
        "music_running": parts[2].lower() == "true",
        "music_volume": parts[3],
        "music_state": parts[4],
        "music_persistent_id": parts[5],
        "music_position": parts[6],
        "music_title": parts[7],
        "music_artist": parts[8],
        "music_shuffle": parts[9] if len(parts) > 9 else "",
        "music_repeat": parts[10] if len(parts) > 10 else "",
        "raw": raw,
    }


def mute_for_test() -> None:
    osa("set volume output muted true")
    osa(
        '''
tell application "System Events"
    if exists process "Music" then
        tell application "Music" to set sound volume to 0
    end if
end tell
''',
        check=False,
    )


def restore_system_and_music(snap: dict[str, Any]) -> str:
    notes: list[str] = []
    # Keep the system muted until the very end so restore play cannot blast.
    osa("set volume output muted true", check=False)

    if snap.get("music_running"):
        osa('tell application "Music" to run', check=False)
        vol = snap.get("music_volume") or "50"
        osa(f'tell application "Music" to set sound volume to {vol}', check=False)
        repeat_mode = (snap.get("music_repeat") or "off").strip().lower()
        if repeat_mode not in {"off", "one", "all"}:
            repeat_mode = "off"
        osa(f'tell application "Music" to set song repeat to {repeat_mode}', check=False)
        shuffle_val = (snap.get("music_shuffle") or "false").strip().lower()
        if shuffle_val not in {"true", "false"}:
            shuffle_val = "false"
        osa(f'tell application "Music" to set shuffle enabled to {shuffle_val}', check=False)
        pid = snap.get("music_persistent_id") or ""
        pos = snap.get("music_position") or ""
        if pid:
            restore_script = r'''
on run argv
    set targetPid to item 1 of argv
    set targetPos to item 2 of argv
    set targetState to item 3 of argv
    tell application "Music"
        try
            set targetTrack to (some track of library playlist 1 whose persistent ID is targetPid)
            play targetTrack
            delay 1.0
            if targetPos is not "" then
                try
                    set player position to (targetPos as integer)
                on error
                    delay 0.6
                    play
                    delay 1.0
                    try
                        set player position to (targetPos as integer)
                    end try
                end try
            end if
            delay 0.2
            if targetState is not "playing" then
                pause
                delay 0.3
                pause
            end if
            try
                return "restored:" & (name of current track) & " state=" & (player state as text) & " pos=" & (player position as text)
            on error
                return "restored:ok"
            end try
        on error errMsg
            return "RESTORE_TRACK_FAILED:" & errMsg
        end try
    end tell
end run
'''
            notes.append(osa(
                restore_script,
                pid,
                str(int(float(pos))) if pos else "0",
                snap.get("music_state") or "paused",
                check=False,
            ))
            try:
                want = float(pos) if pos else 0.0
            except ValueError:
                want = 0.0
            if want >= 5:
                actual_raw = osa(
                    'tell application "Music" to player position as text',
                    check=False,
                )
                try:
                    actual = float(actual_raw)
                except ValueError:
                    actual = -1.0
                if actual >= 0 and abs(actual - want) > 8:
                    retry = osa(
                        f'''
tell application "Music"
    play (some track of library playlist 1 whose persistent ID is "{pid}")
    delay 1.2
    set player position to {int(want)}
    delay 0.25
    pause
    delay 0.3
    pause
    return (player state as text) & " | pos=" & (player position as text)
end tell
''',
                        check=False,
                    )
                    notes.append("position_retry " + retry)
            repeat_mode = (snap.get("music_repeat") or "").strip().lower()
            if repeat_mode in {"off", "one", "all"}:
                osa(f'tell application "Music" to set song repeat to {repeat_mode}', check=False)
            shuffle_val = (snap.get("music_shuffle") or "").strip().lower()
            if shuffle_val in {"true", "false"}:
                osa(
                    f'tell application "Music" to set shuffle enabled to {shuffle_val}',
                    check=False,
                )
        else:
            notes.append("no previous Music track to restore")
    else:
        # We may have launched Music for the smoke run. Put it back to not-running.
        osa('tell application "Music" to quit', check=False)
        notes.append("Music was not running; quit after test")

    sys_vol = snap.get("system_volume") or "50"
    osa(f"set volume output volume {sys_vol}", check=False)
    if snap.get("system_muted"):
        osa("set volume output muted true", check=False)
        notes.append("system remained muted (that was the prior state)")
    else:
        osa("set volume output muted false", check=False)
        notes.append(f"system unmuted, volume={sys_vol}")
    return " | ".join(notes)


def defaults_read(key: str) -> str | None:
    result = run(["defaults", "read", BUNDLE_ID, key], check=False)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def defaults_write_bool(key: str, value: bool) -> None:
    run(["defaults", "write", BUNDLE_ID, key, "-bool", "true" if value else "false"])


def defaults_delete(key: str) -> None:
    run(["defaults", "delete", BUNDLE_ID, key], check=False)


def quit_nanopod(timeout_s: float = 8.0) -> None:
    osa('tell application "nanoPod" to quit', check=False)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if not pids_named("nanoPod"):
            return
        time.sleep(0.2)
    for pid in pids_named("nanoPod"):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    time.sleep(0.5)
    for pid in pids_named("nanoPod"):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def launch_app(event_log: Path, status_path: Path, stdout_path: Path, stderr_path: Path) -> int:
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stdout_path.write_text("", encoding="utf-8")
    stderr_path.write_text("", encoding="utf-8")
    cmd = [
        "open", "-a", str(APP),
        "--stdout", str(stdout_path),
        "--stderr", str(stderr_path),
        "--env", "NANOPOD_E2E=1",
        "--env", f"NANOPOD_E2E_LOG={event_log}",
        "--env", f"NANOPOD_E2E_STATUS={status_path}",
        "--env", "NANOPOD_START_LYRICS=1",
        "--env", "NANOPOD_DEBUG_LOG=1",
        "--env", "NANOPOD_DISABLE_AUTO_UPDATE=1",
    ]
    result = run(cmd, check=False)
    if result.returncode != 0:
        raise SystemExit(f"open nanoPod.app failed: {result.stderr.strip()}")
    deadline = time.time() + 15
    while time.time() < deadline:
        live = pids_named("nanoPod")
        if live:
            return live[-1]
        time.sleep(0.2)
    raise SystemExit("nanoPod did not appear in process list within 15s")


def load_events(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    events: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def load_status(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def wait_for_event(
    event_log: Path,
    name: str,
    timeout_s: float,
    after_seq: int = 0,
    predicate: Any = None,
) -> dict[str, Any] | None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        for event in load_events(event_log):
            try:
                seq = int(event.get("seq") or 0)
            except (TypeError, ValueError):
                seq = 0
            if seq <= after_seq:
                continue
            if event.get("event") != name:
                continue
            if predicate is None or predicate(event):
                return event
        time.sleep(0.1)
    return None


def title_matches(event: dict[str, Any], title: str) -> bool:
    got = str(event.get("title") or "")
    return title.lower() in got.lower() or got.lower() in title.lower()


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def leftover_processes() -> dict[str, list[str]]:
    nano = run(["pgrep", "-ax", "nanoPod"], check=False).stdout.strip().splitlines()
    mini = run(["pgrep", "-ax", "MusicMiniPlayer"], check=False).stdout.strip().splitlines()
    return {
        "nanoPod": [line for line in nano if line.strip()],
        "MusicMiniPlayer": [line for line in mini if line.strip()],
    }


def build_app() -> str:
    result = subprocess.run(
        ["./build_app.sh"],
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        check=False,
    )
    tail = "\n".join((result.stdout or "").splitlines()[-20:])
    if result.returncode != 0:
        raise SystemExit(f"build_app.sh failed ({result.returncode}):\n{result.stderr[-2000:]}\n{tail}")
    if not APP_BIN.exists():
        raise SystemExit(f"missing {APP_BIN} after build")
    return tail


class ScenarioResult:
    def __init__(self, name: str) -> None:
        self.name = name
        self.passed = False
        self.detail = ""
        self.evidence: list[str] = []
        self.metrics: dict[str, Any] = {}

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "passed": self.passed,
            "detail": self.detail,
            "metrics": self.metrics,
            "evidence": self.evidence,
        }


def scenario_cold_start(
    event_log: Path,
    pid: int,
    after_seq: int,
) -> tuple[ScenarioResult, int]:
    result = ScenarioResult("cold_start_original_lyrics")
    track = TRACK_TRANSLATION
    play_ms = now_ms()
    play_out = play_music_track(track["title"], track["artist"])
    play_return_ms = now_ms()
    if play_out is None:
        result.detail = f'Music library missing "{track["title"]}" / {track["artist"]}'
        return result, after_seq
    result.evidence.append(f"PLAY {iso_now()} {play_out}")

    fetch = applied = trans = None
    deadline = time.time() + 20
    while time.time() < deadline:
        for event in load_events(event_log):
            try:
                seq = int(event.get("seq") or 0)
            except (TypeError, ValueError):
                seq = 0
            if seq <= after_seq:
                continue
            if event.get("event") == "fetch_start" and title_matches(event, track["title"]):
                fetch = event
            elif event.get("event") == "lyrics_applied" and title_matches(event, track["title"]):
                applied = event
            elif event.get("event") == "translation_complete" and title_matches(event, track["title"]):
                trans = event
        if applied and (str(applied.get("hasTranslation") or "") == "true" or trans is not None):
            break
        if applied and time.time() > deadline - 8 and trans is None:
            # Original is up; keep waiting a bit for the sidecar, but do not
            # hold the 3s original budget for it.
            pass
        time.sleep(0.1)

    if fetch:
        result.evidence.append(json.dumps(fetch, ensure_ascii=False))
        after_seq = max(after_seq, int(fetch.get("seq") or 0))
    if applied:
        result.evidence.append(json.dumps(applied, ensure_ascii=False))
        after_seq = max(after_seq, int(applied.get("seq") or 0))
    if trans:
        result.evidence.append(json.dumps(trans, ensure_ascii=False))
        after_seq = max(after_seq, int(trans.get("seq") or 0))

    if not process_alive(pid):
        result.detail = "nanoPod died during cold-start lyrics"
        return result, after_seq
    if not applied:
        result.detail = "no lyrics_applied event within 20s"
        return result, after_seq

    has_trans = str(applied.get("hasTranslation") or "") == "true" or trans is not None
    fetch_ms = int(fetch["ts_ms"]) if fetch and fetch.get("ts_ms") is not None else play_return_ms
    original_ms = int(applied["ts_ms"])
    original_s = (original_ms - fetch_ms) / 1000.0
    original_play_s = (original_ms - play_return_ms) / 1000.0
    trans_s = None
    if trans and trans.get("ts_ms") is not None:
        trans_s = (int(trans["ts_ms"]) - fetch_ms) / 1000.0
    elif str(applied.get("hasTranslation") or "") == "true":
        trans_s = original_s
    result.metrics = {
        "play_issued_ms": play_ms,
        "play_return_ms": play_return_ms,
        "fetch_ts_ms": fetch.get("ts_ms") if fetch else None,
        "lyrics_ts_ms": applied.get("ts_ms"),
        "translation_ts_ms": trans.get("ts_ms") if trans else None,
        "original_from_fetch_s": round(original_s, 3),
        "original_from_play_return_s": round(original_play_s, 3),
        "translation_from_fetch_s": round(trans_s, 3) if trans_s is not None else None,
        "has_translation": has_trans,
        "sidecar": trans_s is not None and trans_s > LYRICS_BUDGET_S,
        "budget_s": LYRICS_BUDGET_S,
    }
    if original_s > LYRICS_BUDGET_S:
        result.detail = (
            f"original lyrics {original_s:.3f}s after fetch_start "
            f"(budget {LYRICS_BUDGET_S:.1f}s)"
        )
        return result, after_seq
    if not has_trans:
        result.detail = "lyrics appeared but translation path produced no translation"
        return result, after_seq
    result.passed = True
    if trans_s is not None and trans_s > LYRICS_BUDGET_S:
        result.detail = (
            f"original {original_s:.3f}s from fetch_start "
            f"(budget {LYRICS_BUDGET_S:.1f}s); translation sidecar {trans_s:.3f}s"
        )
    else:
        result.detail = (
            f"original+translation in {original_s:.3f}s from fetch_start "
            f"({original_play_s:.3f}s from play return)"
        )
    return result, after_seq


def scenario_churn(event_log: Path, pid: int, after_seq: int) -> tuple[ScenarioResult, int]:
    result = ScenarioResult("consecutive_track_changes")
    evidence_ok = True
    for track in (TRACK_CHURN_A, TRACK_CHURN_B):
        play_out = play_music_track(track["title"], track["artist"])
        if play_out is None:
            evidence_ok = False
            result.detail = f'Music library missing "{track["title"]}" / {track["artist"]}'
            break
        result.evidence.append(f"PLAY {iso_now()} {play_out}")
        applied = wait_for_event(
            event_log, "lyrics_applied", 20, after_seq,
            lambda e, title=track["title"]: title_matches(e, title),
        )
        if applied:
            result.evidence.append(json.dumps(applied, ensure_ascii=False))
            after_seq = max(after_seq, int(applied.get("seq") or 0))
        else:
            evidence_ok = False
            result.detail = f"no lyrics_applied for {track['title']}"
            break
        if not process_alive(pid):
            evidence_ok = False
            result.detail = f"nanoPod died after switching to {track['title']}"
            break
    if evidence_ok and process_alive(pid):
        result.passed = True
        result.detail = f"got lyrics_applied for {TRACK_CHURN_A['title']} then {TRACK_CHURN_B['title']}"
    return result, after_seq


def scenario_seek(event_log: Path, status_path: Path, pid: int, after_seq: int) -> tuple[ScenarioResult, int]:
    result = ScenarioResult("seek")
    time.sleep(1.0)
    osa('tell application "Music" to set song repeat to one', check=False)
    status_before = load_status(status_path)
    target = 60.0
    duration = float(status_before.get("duration") or 0)
    if duration and duration < 70:
        target = max(10.0, duration * 0.4)
    pos_before = set_player_position(target)
    result.evidence.append(f"SEEK {iso_now()} osascript player position -> {pos_before} (target={target})")
    observed = wait_for_event(
        event_log, "seek_observed", 15, after_seq,
        lambda e: abs(float(e.get("to") or 0) - target) < 8.0,
    )
    status_after = load_status(status_path)
    if observed:
        result.evidence.append(json.dumps(observed, ensure_ascii=False))
        after_seq = max(after_seq, int(observed.get("seq") or 0))
    if status_after:
        result.evidence.append("STATUS " + json.dumps(status_after, ensure_ascii=False))

    if not process_alive(pid):
        result.detail = "nanoPod died during seek"
        return result, after_seq
    if observed is None:
        # Fallback: status snapshot jumped.
        try:
            pos = float(status_after.get("position") or 0)
        except (TypeError, ValueError):
            pos = 0.0
        if abs(pos - target) < 8.0 and status_after.get("displayState") in {"content", "noLyrics"}:
            result.passed = True
            result.detail = f"no seek_observed event; status position={pos:.3f} near target {target:.1f}"
            return result, after_seq
        result.detail = f"no seek_observed near {target:.1f}s and status did not jump"
        return result, after_seq
    result.passed = True
    result.detail = (
        f"seek_observed from={observed.get('from')} to={observed.get('to')} "
        f"displayState={status_after.get('displayState')}"
    )
    return result, after_seq


def scenario_no_lyrics(event_log: Path, pid: int, after_seq: int) -> tuple[ScenarioResult, int]:
    result = ScenarioResult("no_lyrics_no_crash")
    chosen = None
    for candidate in NO_LYRICS_CANDIDATES:
        if find_music_track(candidate["title"], candidate["artist"]):
            chosen = candidate
            break
    if chosen is None:
        result.detail = "no no-lyrics candidate present in Music library"
        result.evidence.append("CANDIDATES " + json.dumps(NO_LYRICS_CANDIDATES, ensure_ascii=False))
        return result, after_seq

    osa('tell application "Music" to set song repeat to one', check=False)
    play_out = play_music_track(chosen["title"], chosen["artist"])
    if play_out is None:
        result.detail = f'found then lost {chosen["title"]} / {chosen["artist"]}'
        return result, after_seq
    result.evidence.append(f"PLAY {iso_now()} {play_out}")
    terminal = None
    deadline = time.time() + 18
    replays = 0
    while time.time() < deadline:
        jumped_away = False
        for event in load_events(event_log):
            try:
                seq = int(event.get("seq") or 0)
            except (TypeError, ValueError):
                seq = 0
            if seq <= after_seq:
                continue
            if event.get("event") in {"no_lyrics", "lyrics_applied"} and title_matches(event, chosen["title"]):
                terminal = event
                break
            if event.get("event") == "track_change" and not title_matches(event, chosen["title"]):
                jumped_away = True
        if terminal:
            break
        if jumped_away and replays < 2:
            osa('tell application "Music" to set song repeat to one', check=False)
            retry = play_music_track(chosen["title"], chosen["artist"])
            replays += 1
            result.evidence.append(f"REPLAY {iso_now()} n={replays} {retry}")
        if not process_alive(pid):
            break
        time.sleep(0.15)

    if terminal:
        result.evidence.append(json.dumps(terminal, ensure_ascii=False))
        after_seq = max(after_seq, int(terminal.get("seq") or 0))

    if not process_alive(pid):
        result.detail = f"nanoPod died on no-lyrics candidate {chosen['title']}"
        return result, after_seq
    if terminal is None:
        result.detail = (
            f"played {chosen['title']} / {chosen['artist']} but neither "
            "no_lyrics nor lyrics_applied arrived within 18s"
        )
        return result, after_seq
    result.passed = True
    kind = terminal.get("event")
    result.detail = (
        f"terminal {kind} for {chosen['title']} / {chosen['artist']} "
        f"(verdict={terminal.get('verdict', '')}); process still alive"
    )
    result.metrics = {"candidate": chosen, "terminal_event": kind}
    return result, after_seq


def scenario_clean_exit(pid: int) -> ScenarioResult:
    result = ScenarioResult("clean_exit_no_leftover")
    quit_nanopod(timeout_s=8)
    time.sleep(0.4)
    leftover = leftover_processes()
    result.evidence.append("LEFTOVER " + json.dumps(leftover, ensure_ascii=False))
    result.evidence.append(f"pid_alive_after_quit={process_alive(pid)}")
    if leftover["nanoPod"] or process_alive(pid):
        result.detail = f"nanoPod still present: {leftover}"
        return result
    result.passed = True
    result.detail = "nanoPod process list empty after quit"
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="nanoPod real-app e2e smoke")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--out-dir", type=Path, default=None)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = args.out_dir or (ROOT / "tmp" / "e2e" / stamp)
    out_dir.mkdir(parents=True, exist_ok=True)
    event_log = out_dir / "events.jsonl"
    status_path = out_dir / "status.json"
    report_path = out_dir / "report.json"

    snapshot = snapshot_system_and_music()
    (out_dir / "playback_snapshot.json").write_text(
        json.dumps(snapshot, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    prev_translation = defaults_read("showTranslation")
    nanopod_was_running = bool(pids_named("nanoPod"))
    restore_note = ""
    results: list[ScenarioResult] = []
    app_pid: int | None = None

    try:
        mute_for_test()
        if nanopod_was_running:
            quit_nanopod()
        if not args.skip_build:
            build_tail = build_app()
            (out_dir / "build_tail.txt").write_text(build_tail + "\n", encoding="utf-8")
        elif not APP_BIN.exists():
            raise SystemExit(f"missing {APP_BIN}; run without --skip-build")

        defaults_write_bool("showTranslation", True)
        event_log.write_text("", encoding="utf-8")
        app_pid = launch_app(
            event_log, status_path, out_dir / "app.stdout", out_dir / "app.stderr"
        )
        ready = wait_for_event(event_log, "app_ready", 15)
        if ready is None:
            raise RuntimeError("app_ready never appeared in e2e event log")
        (out_dir / "app_ready.json").write_text(
            json.dumps(ready, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        connected = wait_for_event(event_log, "music_connected", 15, int(ready.get("seq") or 0))
        if connected:
            (out_dir / "music_connected.json").write_text(
                json.dumps(connected, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
            after_seq = int(connected.get("seq") or 0)
        else:
            after_seq = int(ready.get("seq") or 0)
        time.sleep(0.8)

        cold, after_seq = scenario_cold_start(event_log, app_pid, after_seq)
        results.append(cold)
        seek, after_seq = scenario_seek(event_log, status_path, app_pid, after_seq)
        results.append(seek)
        churn, after_seq = scenario_churn(event_log, app_pid, after_seq)
        results.append(churn)
        missing, after_seq = scenario_no_lyrics(event_log, app_pid, after_seq)
        results.append(missing)
        results.append(scenario_clean_exit(app_pid))
        app_pid = None
    except Exception as exc:
        failed = ScenarioResult("harness")
        failed.detail = f"{type(exc).__name__}: {exc}"
        results.append(failed)
    finally:
        if app_pid is not None:
            quit_nanopod()
        restore_note = restore_system_and_music(snapshot)
        if prev_translation is None:
            defaults_delete("showTranslation")
        else:
            defaults_write_bool("showTranslation", prev_translation in {"1", "true", "TRUE"})
        if nanopod_was_running and not pids_named("nanoPod"):
            subprocess.Popen(["open", str(APP)], cwd=str(ROOT))

    leftover = leftover_processes()
    passed = bool(results) and all(item.passed for item in results)
    report = {
        "stamp": stamp,
        "passed": passed,
        "pid": app_pid,
        "lyrics_budget_s": LYRICS_BUDGET_S,
        "nanopod_was_running": nanopod_was_running,
        "restore_note": restore_note,
        "leftover": leftover,
        "scenarios": [item.to_dict() for item in results],
        "event_log": str(event_log),
        "status": str(status_path),
    }
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"E2E_OUT={out_dir}")
    print(f"E2E_PASSED={str(passed).lower()}")
    for item in results:
        flag = "PASS" if item.passed else "FAIL"
        print(f"  [{flag}] {item.name}: {item.detail}")
        for line in item.evidence:
            print(f"    EVIDENCE {line}")
    print(f"RESTORE {restore_note}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
