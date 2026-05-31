#!/usr/bin/env python3
"""
nanoPod lyrics-page visual evidence harness.

Captures repeatable screenshots or screen recordings for protected lyrics UI
checks. The harness is intentionally local: it drives Music.app, opens nanoPod's
lyrics page, validates the expected lyrics workload, and writes artifacts under
tmp/visual.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import time
from pathlib import Path
from types import SimpleNamespace
from typing import NamedTuple


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "nanoPod.app"
OUT_DIR = ROOT / "tmp" / "visual"


class WindowCaptureTarget(NamedTuple):
    rect: tuple[int, int, int, int]
    window_id: int | None

FIXTURES: dict[str, dict[str, object]] = {
    "translated-word": {
        "title": "Stardust Night",
        "artist": "JADOES",
        "duration": 234,
        "expect_lyrics": "syllable",
        "expect_translation": True,
        "expect_selected_source": "NetEase",
        "expect_lyrics_line_count": 25,
        "expect_first_real_line_sha256": "43180988879b1854dfbdc28c2eac68f223c2b4210bda87cd87fed3897fd772e8",
        "purpose": "deterministic translated word-level sweep, active-word timing, spacing, blur, and translation layout",
        "settle_s": 8.0,
    },
    "word-english-dense": {
        "title": "Shape of You",
        "artist": "Ed Sheeran",
        "duration": 234,
        "expect_lyrics": "line",
        "purpose": "dense English line-synced fallback layout and active-line anchoring",
        "settle_s": 6.0,
    },
    "word-english-sparse": {
        "title": "Bad Guy",
        "artist": "Billie Eilish",
        "duration": 194,
        "expect_lyrics": "line",
        "purpose": "sparser English line-synced phrases, blur, and fallback layout",
        "settle_s": 6.0,
    },
    "word-japanese": {
        "title": "Namidanokatachino Earring",
        "artist": "Akina Nakamori",
        "duration": 276,
        "expect_lyrics": "syllable",
        "expect_translation": True,
        "purpose": "Japanese word-level timing, CJK glyph metrics, and translated line alignment",
        "settle_s": 8.0,
    },
    "word-level-alt": {
        "title": "Stardust Night",
        "artist": "JADOES",
        "duration": 234,
        "expect_lyrics": "syllable",
        "expect_translation": True,
        "purpose": "alternate translated word-level workload with Japanese catalog behavior",
        "settle_s": 8.0,
    },
    "line-english": {
        "title": "Uptown Funk",
        "artist": "Mark Ronson",
        "duration": 270,
        "expect_lyrics": "line",
        "purpose": "English line-synced layout, active-line anchoring, and translation baseline",
        "settle_s": 6.0,
    },
    "line-cjk": {
        "title": "女爵",
        "artist": "杨乃文",
        "duration": 252,
        "expect_lyrics": "line",
        "purpose": "CJK line wrapping, font metrics, active/non-active emphasis",
        "settle_s": 6.0,
    },
    "interlude": {
        "title": "Bohemian Rhapsody",
        "artist": "Queen",
        "duration": 355,
        "expect_lyrics": "line",
        "purpose": "long gaps, interlude/prelude dots, and scroll continuity",
        "settle_s": 10.0,
    },
    "line-winter-trip": {
        "title": "冬天一個遊",
        "artist": "Gordon Flanders",
        "album": "冬天一個遊 - Single",
        "genre": "R&B/Soul",
        "duration": 256,
        "expect_lyrics": "syllable",
        "expect_translation": False,
        "expect_selected_source": "NetEase",
        "expect_lyrics_line_count": 67,
        "expect_first_real_line_sha256": "15ce6b4d94c2f2b4f016cbd746a807825b26fa90608465af1dbb623ad645fee9",
        "purpose": "mandatory winter word-level fixture for passive playback plus scroll-tap-jump CPU, drift, and refresh telemetry",
        "sample_start_s": 42.0,
        "settle_s": 8.0,
    },
    "line-breakup-truth": {
        "title": "分手真相",
        "artist": "Alvin Kwok",
        "album": "Steel Box Collection: Alvin Kwok",
        "genre": "Cantopop/HK-Pop",
        "duration": 250,
        "expect_lyrics": "line",
        "expect_translation": False,
        "expect_selected_source": "NetEase",
        "expect_lyrics_line_count": 42,
        "expect_first_real_line_sha256": "c3925990fd25b5c0a4891ef23968b2acd3d7db1e4d71fbb9cfdfeefdd2231ae9",
        "purpose": "owner-provided Cantonese line-level workload for lag/drift regression gating without word or syllable sync",
        "settle_s": 8.0,
    },
    "word-seek-fun": {
        "title": "尋開心",
        "artist": "Bondy Chiu",
        "duration": 265,
        "expect_lyrics": "syllable",
        "expect_translation": False,
        "expect_selected_source": "NetEase",
        "expect_lyrics_line_count": 44,
        "expect_first_real_line_sha256": "8b9a2fd7d0bc2de6d45adeb5758c5f11492b018c1900b67a6afe4002fbda4f3b",
        "purpose": "word-level seek/tap recovery fixture for sweep phase and active-word animation telemetry",
        "settle_s": 8.0,
    },
}


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def slug(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9]+", "-", value.strip().lower()).strip("-")
    return normalized or "capture"


def workload_args(fixture: dict[str, object]) -> SimpleNamespace:
    return SimpleNamespace(
        expect_lyrics=str(fixture["expect_lyrics"]),
        expect_translation=bool(fixture.get("expect_translation", False)),
        play_title=str(fixture["title"]),
        play_artist=str(fixture["artist"]),
        play_album=str(fixture.get("album", "")),
        play_duration=float(fixture["duration"]),
        expect_selected_source=fixture.get("expect_selected_source"),
        expect_lyrics_line_count=fixture.get("expect_lyrics_line_count"),
        expect_first_real_line_sha256=fixture.get("expect_first_real_line_sha256"),
    )


def find_pid() -> int | None:
    result = run(["pgrep", "-x", "nanoPod"], check=False)
    pids = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return int(pids[-1]) if pids else None


def launch_app() -> int:
    if not APP.exists():
        raise SystemExit(f"Missing {APP}; run ./build_app.sh first")

    run(["open", str(APP)])
    deadline = time.time() + 10
    while time.time() < deadline:
        pid = find_pid()
        if pid is not None:
            return pid
        time.sleep(0.2)
    raise SystemExit("nanoPod did not launch within 10s")


def request_page(page: str) -> None:
    if APP.exists():
        run(["open", "-a", str(APP), f"nanopod://page/{page}"], check=False)
    else:
        run(["open", f"nanopod://page/{page}"], check=False)


def activate_app() -> None:
    run(["osascript", "-e", 'tell application "nanoPod" to activate'], check=False)


def play_music_library_track(title: str, artist: str, album: str = "") -> str:
    script = r'''
on run argv
    set targetTitle to item 1 of argv
    set targetArtist to item 2 of argv
    set targetAlbum to ""
    if (count of argv) >= 3 then set targetAlbum to item 3 of argv
    tell application "Music"
        if it is not running then run
        set targetTrack to missing value
        try
            set searchResults to search library playlist 1 for targetTitle only songs
        on error
            set searchResults to {}
        end try
        repeat with candidateTrack in searchResults
            set candidateAlbum to ""
            try
                set candidateAlbum to album of candidateTrack
            end try
            if (name of candidateTrack is targetTitle) and (artist of candidateTrack is targetArtist) and (targetAlbum is "" or candidateAlbum is targetAlbum) then
                set targetTrack to candidateTrack
                exit repeat
            end if
        end repeat
        if targetTrack is missing value then
            repeat with candidateTrack in searchResults
                set candidateAlbum to ""
                try
                    set candidateAlbum to album of candidateTrack
                end try
                if (name of candidateTrack contains targetTitle) and (artist of candidateTrack contains targetArtist) and (targetAlbum is "" or candidateAlbum is targetAlbum) then
                    set targetTrack to candidateTrack
                    exit repeat
                end if
            end repeat
        end if
        if targetTrack is missing value then return "NOT_FOUND"
        play targetTrack
        delay 0.2
        if player state is not playing then play
        delay 0.3
        set currentMatchesTarget to false
        try
            set currentAlbum to ""
            try
                set currentAlbum to album of current track
            end try
            set currentMatchesTarget to (name of current track is targetTitle) and (artist of current track is targetArtist) and (targetAlbum is "" or currentAlbum is targetAlbum)
        end try
        if currentMatchesTarget is false then
            set harnessPlaylistName to "nanoPod Test Playback"
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
        end if
        set trackID to persistent ID of targetTrack
        set trackName to name of targetTrack
        set trackArtist to artist of targetTrack
        set trackAlbum to ""
        try
            set trackAlbum to album of targetTrack
        end try
        return trackID & "\t" & trackName & "\t" & trackArtist & "\t" & trackAlbum
    end tell
end run
'''
    result = run(["osascript", "-e", script, title, artist, album], check=False)
    output = result.stdout.strip()
    if result.returncode != 0:
        raise SystemExit(f"Music.app failed to play requested track: {result.stderr.strip()}")
    if output == "NOT_FOUND" or not output:
        raise SystemExit(f'Music.app library track not found: "{title}" - {artist}')
    return output


def verify_lyrics_workload(args: SimpleNamespace) -> dict[str, object] | None:
    if args.expect_lyrics == "any":
        return None

    cmd = [
        "swift", "run", "LyricsVerifier", "check",
        args.play_title,
        args.play_artist,
        str(args.play_duration),
    ]
    result = run(cmd, check=False)
    if result.returncode != 0:
        raise SystemExit(f"LyricsVerifier failed:\n{result.stderr.strip()}")

    records = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    if not records:
        raise SystemExit("LyricsVerifier produced no JSON result")

    record = records[-1]
    if not bool(record.get("passed")):
        failures = record.get("failures") or []
        joined = "; ".join(str(item) for item in failures) or "unknown verifier failure"
        raise SystemExit(
            f'Lyrics identity validation failed for "{args.play_title}" - {args.play_artist}: {joined}'
        )

    has_syllable = bool(record.get("hasSyllableSync"))
    has_translation = bool(record.get("hasTranslation"))
    if args.expect_lyrics == "syllable" and not has_syllable:
        raise SystemExit(
            f'Expected word-level/syllable lyrics for "{args.play_title}" - {args.play_artist}, '
            f"but verifier selected {record.get('selectedSource')} without syllable sync"
        )
    if args.expect_lyrics == "line" and has_syllable:
        raise SystemExit(
            f'Expected line-synced/non-syllable lyrics for "{args.play_title}" - {args.play_artist}, '
            f"but verifier selected word-level lyrics from {record.get('selectedSource')}"
        )
    if args.expect_translation and not has_translation:
        raise SystemExit(
            f'Expected translated lyrics for "{args.play_title}" - {args.play_artist}, '
            f"but verifier selected {record.get('selectedSource')} without translation"
        )
    expected_source = getattr(args, "expect_selected_source", None)
    if expected_source and record.get("selectedSource") != expected_source:
        raise SystemExit(
            f'Expected lyrics source {expected_source} for "{args.play_title}" - {args.play_artist}, '
            f"but verifier selected {record.get('selectedSource')}"
        )
    expected_line_count = getattr(args, "expect_lyrics_line_count", None)
    if expected_line_count is not None and record.get("lyricsLineCount") != int(expected_line_count):
        raise SystemExit(
            f'Expected {expected_line_count} lyric lines for "{args.play_title}" - {args.play_artist}, '
            f"but verifier selected {record.get('lyricsLineCount')}"
        )
    expected_first_real_sha = getattr(args, "expect_first_real_line_sha256", None)
    if expected_first_real_sha and record.get("firstRealLineSHA256") != expected_first_real_sha:
        raise SystemExit(
            f'Expected first real line SHA {expected_first_real_sha} for "{args.play_title}" - {args.play_artist}, '
            f"but verifier selected {record.get('firstRealLineSHA256')}"
        )
    return {
        "expectation": args.expect_lyrics,
        "expectTranslation": args.expect_translation,
        "expectSelectedSource": expected_source,
        "expectLyricsLineCount": expected_line_count,
        "expectFirstRealLineSHA256": expected_first_real_sha,
        "title": record.get("title"),
        "artist": record.get("artist"),
        "selectedSource": record.get("selectedSource"),
        "hasSyllableSync": has_syllable,
        "hasTranslation": has_translation,
        "lyricsLineCount": record.get("lyricsLineCount"),
        "firstRealLine": record.get("firstRealLine"),
        "firstRealLineSHA256": record.get("firstRealLineSHA256"),
        "elapsedMs": record.get("elapsedMs"),
    }


def nano_window_rect() -> tuple[int, int, int, int]:
    script = r'''
tell application "System Events"
    if not (exists process "nanoPod") then return "NO_PROCESS"
    tell process "nanoPod"
        if (count of windows) is 0 then return "NO_WINDOW"
        set p to position of window 1
        set s to size of window 1
        return (item 1 of p as integer) & "," & (item 2 of p as integer) & "," & (item 1 of s as integer) & "," & (item 2 of s as integer)
    end tell
end tell
'''
    result = run(["osascript", "-e", script], check=False)
    output = result.stdout.strip()
    if result.returncode != 0:
        raise SystemExit(f"Could not read nanoPod window bounds: {result.stderr.strip()}")
    if output in {"NO_PROCESS", "NO_WINDOW", ""}:
        raise SystemExit(f"Could not find a visible nanoPod window: {output or 'empty response'}")
    try:
        parts = [int(part.strip()) for part in output.split(",")]
    except ValueError as error:
        raise SystemExit(f"Unexpected nanoPod window bounds: {output}") from error
    if len(parts) != 4:
        raise SystemExit(f"Unexpected nanoPod window bounds: {output}")
    return parts[0], parts[1], parts[2], parts[3]


def nano_window_target() -> WindowCaptureTarget:
    try:
        return WindowCaptureTarget(nano_window_rect(), None)
    except SystemExit:
        pass

    swift_source = r'''
import CoreGraphics
import Foundation

let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    guard owner == "nanoPod" else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { continue }
    let x = bounds["X"] as? Int ?? 0
    let y = bounds["Y"] as? Int ?? 0
    let width = bounds["Width"] as? Int ?? 0
    let height = bounds["Height"] as? Int ?? 0
    print("\(number)\t\(x)\t\(y)\t\(width)\t\(height)")
    exit(0)
}

exit(1)
'''
    result = run(["swift", "-e", swift_source], check=False)
    output = result.stdout.strip()
    if result.returncode != 0 or not output:
        raise SystemExit(f"Could not find nanoPod window through CoreGraphics: {result.stderr.strip()}")
    parts = output.split("\t")
    if len(parts) != 5:
        raise SystemExit(f"Unexpected nanoPod CoreGraphics window output: {output}")
    window_id, x, y, width, height = [int(part) for part in parts]
    return WindowCaptureTarget((x, y, width, height), window_id)


def capture_screen(mode: str, output: Path, duration: float) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if mode == "screenshot":
        run(["screencapture", "-x", str(output)])
        return
    run(["screencapture", "-x", "-v", "-V", str(duration), str(output)])


def capture_window(mode: str, window_id: int, output: Path, duration: float) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    if mode == "screenshot":
        run(["screencapture", "-x", "-l", str(window_id), str(output)])
        return
    run(["screencapture", "-x", "-v", "-V", str(duration), "-l", str(window_id), str(output)])


def capture_rect(mode: str, rect: tuple[int, int, int, int], output: Path, duration: float) -> None:
    x, y, width, height = rect
    output.parent.mkdir(parents=True, exist_ok=True)
    rect_arg = f"{x},{y},{width},{height}"
    if mode == "screenshot":
        run(["screencapture", "-x", "-R", rect_arg, str(output)])
        return
    run(["screencapture", "-x", "-v", "-V", str(duration), "-R", rect_arg, str(output)])


def validate_capture(output: Path, mode: str) -> None:
    if mode != "screenshot":
        return
    try:
        from PIL import Image, ImageStat
    except ImportError:
        return

    with Image.open(output) as image:
        sample = image.convert("RGB")
        sample.thumbnail((320, 200))
        if hasattr(sample, "get_flattened_data"):
            pixels = list(sample.get_flattened_data())
        else:
            pixels = list(sample.getdata())
        if not pixels:
            raise SystemExit(f"Capture is empty: {output}")
        stat = ImageStat.Stat(sample)
        mean_luma = sum(stat.mean) / len(stat.mean)
        non_dark = sum(1 for red, green, blue in pixels if max(red, green, blue) > 20)
        non_dark_ratio = non_dark / len(pixels)

    if mean_luma < 1.0 and non_dark_ratio < 0.001:
        raise SystemExit(
            "Screenshot capture is effectively blank. Grant Screen Recording "
            "permission or keep the display awake, then rerun the visual harness."
        )


def list_fixtures() -> None:
    print(json.dumps(FIXTURES, indent=2, ensure_ascii=False))


def run_capture(args: argparse.Namespace) -> None:
    fixture = FIXTURES[args.fixture]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    ext = "png" if args.mode == "screenshot" else "mov"
    output = OUT_DIR / f"{stamp}-{args.fixture}-{slug(args.label)}.{ext}"

    if args.dry_run:
        print(json.dumps({
            "fixture": args.fixture,
            "mode": args.mode,
            "output": str(output),
            "fixture_details": fixture,
        }, indent=2, ensure_ascii=False))
        return

    play_music_library_track(str(fixture["title"]), str(fixture["artist"]))
    time.sleep(float(fixture.get("settle_s", args.settle)))
    workload = verify_lyrics_workload(workload_args(fixture))
    launch_app()
    request_page("lyrics")
    activate_app()
    time.sleep(args.settle)
    capture_scope = "window"
    window_id = None
    try:
        target = nano_window_target()
        rect = target.rect
        window_id = target.window_id
        if target.window_id is not None:
            capture_window(args.mode, target.window_id, output, args.record_duration)
            capture_scope = "window-id"
        else:
            capture_rect(args.mode, target.rect, output, args.record_duration)
    except SystemExit:
        if not args.allow_fullscreen_fallback:
            raise
        rect = None
        capture_scope = "fullscreen"
        capture_screen(args.mode, output, args.record_duration)

    validate_capture(output, args.mode)

    summary = {
        "fixture": args.fixture,
        "mode": args.mode,
        "label": args.label,
        "output": str(output),
        "capture_scope": capture_scope,
        "window_rect": rect,
        "window_id": window_id,
        "lyrics_workload": workload,
        "checklist": [
            "lyrics page, not album page",
            "active line position and spacing unchanged",
            "word or line highlight timing matches baseline",
            "translation sweep and layout unchanged when visible",
            "blur, scale, opacity, wave/interlude behavior unchanged",
            "no stale lyrics after rapid song/page switching",
        ],
    }
    summary_path = output.with_suffix(".json")
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="Capture nanoPod lyrics-page visual regression evidence.")
    parser.add_argument("--list-fixtures", action="store_true", help="print fixture definitions and exit")
    parser.add_argument("--fixture", choices=sorted(FIXTURES), default="translated-word")
    parser.add_argument("--mode", choices=["screenshot", "record"], default="screenshot")
    parser.add_argument("--label", default="baseline", help="baseline, after, or a short experiment label")
    parser.add_argument("--settle", type=float, default=3.0, help="seconds to wait after opening the lyrics page")
    parser.add_argument("--record-duration", type=float, default=12.0, help="seconds for --mode record")
    parser.add_argument(
        "--allow-fullscreen-fallback",
        action="store_true",
        help="capture the full screen if macOS blocks nanoPod window bounds access",
    )
    parser.add_argument("--dry-run", action="store_true", help="show planned capture without touching Music.app")
    args = parser.parse_args()

    if args.list_fixtures:
        list_fixtures()
        return
    run_capture(args)


if __name__ == "__main__":
    main()
