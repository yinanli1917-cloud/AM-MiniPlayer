#!/usr/bin/env python3
"""
nanoPod local performance evidence harness.

Runs the same lyrics workload checks used by the visual harness, routes nanoPod
to a target page, and records bounded CPU/RSS samples under tmp/perf.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import plistlib
import statistics
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import lyrics_visual_harness as visual


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "tmp" / "perf"
if os.environ.get("NANOPOD_APP_PATH"):
    visual.APP = Path(os.environ["NANOPOD_APP_PATH"]).expanduser().resolve()


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


def quit_candidate_app() -> None:
    run(["osascript", "-e", 'tell application id "com.yinanli.nanoPod" to quit'], check=False)
    deadline = time.time() + 5.0
    while time.time() < deadline:
        if visual.find_pid() is None:
            return
        time.sleep(0.25)
    run(["pkill", "-x", "nanoPod"], check=False)
    deadline = time.time() + 3.0
    while time.time() < deadline:
        if visual.find_pid() is None:
            return
        time.sleep(0.25)


def write_bool_preference_to_plist(path: Path, key: str, value: bool) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        data: dict[str, object] = {}
        if path.exists():
            with path.open("rb") as handle:
                loaded = plistlib.load(handle)
            if isinstance(loaded, dict):
                data = dict(loaded)
        data[key] = value
        with path.open("wb") as handle:
            plistlib.dump(data, handle)
    except Exception as error:
        log(f"Warning: could not write {key} to {path}: {error}")


def write_bool_preference(key: str, value: bool) -> None:
    bool_value = "true" if value else "false"
    run(["defaults", "write", "com.yinanli.nanoPod", key, "-bool", bool_value], check=False)
    for path in (
        Path.home() / "Library/Preferences/com.yinanli.nanoPod.plist",
        Path.home() / "Library/Containers/com.yinanli.nanoPod/Data/Library/Preferences/com.yinanli.nanoPod.plist",
    ):
        write_bool_preference_to_plist(path, key, value)


def enable_required_diagnostics() -> None:
    write_bool_preference("ownerDiagnosticsEnabled", True)
    write_bool_preference("ownerLineMotionGeometryEnabled", True)
    write_bool_preference("ownerLyricWaveTimelineEnabled", True)


def positive_float(parser: argparse.ArgumentParser, value: float, name: str) -> None:
    if value <= 0:
        parser.error(f"{name} must be greater than 0")


def non_negative_float(parser: argparse.ArgumentParser, value: float, name: str) -> None:
    if value < 0:
        parser.error(f"{name} must be 0 or greater")


def infer_fixture(title: str, artist: str, duration: float) -> dict[str, object] | None:
    normalized_title = title.casefold()
    normalized_artist = artist.casefold()
    for fixture in visual.FIXTURES.values():
        fixture_title = str(fixture["title"]).casefold()
        fixture_artist = str(fixture["artist"]).casefold()
        fixture_duration = float(fixture["duration"])
        if (
            fixture_title == normalized_title
            and fixture_artist == normalized_artist
            and abs(fixture_duration - duration) <= 1.0
        ):
            return fixture
    return None


def resolve_args(parser: argparse.ArgumentParser, args: argparse.Namespace) -> SimpleNamespace:
    fixture = visual.FIXTURES.get(args.fixture) if args.fixture else None
    title = args.play_title or (str(fixture["title"]) if fixture else "")
    artist = args.play_artist or (str(fixture["artist"]) if fixture else "")
    duration = args.play_duration
    if duration is None and fixture:
        duration = float(fixture["duration"])

    if not title:
        parser.error("--play-title is required unless --fixture supplies it")
    if not artist:
        parser.error("--play-artist is required unless --fixture supplies it")
    if duration is None:
        parser.error("--play-duration is required unless --fixture supplies it")

    positive_float(parser, float(duration), "--play-duration")
    positive_float(parser, args.duration, "--duration")
    positive_float(parser, args.interval, "--interval")
    positive_float(parser, args.interaction_interval, "--interaction-interval")
    non_negative_float(parser, args.warmup, "--warmup")
    if args.seek_position is not None:
        non_negative_float(parser, args.seek_position, "--seek-position")

    expect_lyrics = args.expect_lyrics
    if expect_lyrics == "fixture":
        if fixture:
            expect_lyrics = str(fixture["expect_lyrics"])
        else:
            inferred = infer_fixture(title, artist, float(duration))
            expect_lyrics = str(inferred["expect_lyrics"]) if inferred else "any"

    expect_translation = args.expect_translation
    if expect_translation is None:
        if expect_lyrics == "any":
            expect_translation = False
        else:
            inferred = fixture or infer_fixture(title, artist, float(duration))
            expect_translation = bool(inferred.get("expect_translation", False)) if inferred else False

    if expect_translation and expect_lyrics == "any":
        parser.error("--expect-translation requires --expect-lyrics line, syllable, or fixture")

    return SimpleNamespace(
        page=args.page,
        fixture=args.fixture,
        play_title=title,
        play_artist=artist,
        play_album=str(fixture.get("album", "")) if fixture else "",
        play_duration=float(duration),
        seek_position=args.seek_position if args.seek_position is not None else (
            float(fixture["sample_start_s"])
            if fixture and fixture.get("sample_start_s") is not None
            else None
        ),
        expect_lyrics=expect_lyrics,
        expect_translation=bool(expect_translation),
        expect_selected_source=fixture.get("expect_selected_source") if fixture else None,
        expect_lyrics_line_count=fixture.get("expect_lyrics_line_count") if fixture else None,
        expect_first_real_line_sha256=fixture.get("expect_first_real_line_sha256") if fixture else None,
        duration=args.duration,
        warmup=args.warmup,
        interval=args.interval,
        label=args.label,
        output_dir=Path(args.output_dir).expanduser(),
        require_music_playing=args.require_music_playing,
        skip_playback_control=args.skip_playback_control,
        allow_music_automation_unavailable=args.allow_music_automation_unavailable,
        interaction=args.interaction,
        interaction_interval=args.interaction_interval,
        dry_run=args.dry_run,
    )


def verify_workload(request: SimpleNamespace) -> dict[str, object] | None:
    has_locked_identity = any([
        request.expect_selected_source,
        request.expect_lyrics_line_count is not None,
        request.expect_first_real_line_sha256,
    ])
    if request.expect_lyrics == "any" and not has_locked_identity:
        return None
    return visual.verify_lyrics_workload(request)


def music_status() -> dict[str, object]:
    script = r'''
tell application "Music"
    if it is not running then return "not running" & tab & "" & tab & "" & tab & ""
    set stateText to player state as string
    set trackName to ""
    set trackArtist to ""
    set trackDuration to ""
    set trackAlbum to ""
    try
        set trackName to name of current track
        set trackArtist to artist of current track
        set trackDuration to duration of current track as string
        set trackAlbum to album of current track
    end try
    return stateText & tab & trackName & tab & trackArtist & tab & trackDuration & tab & trackAlbum
end tell
'''
    result = run(["osascript", "-e", script], check=False)
    if result.returncode != 0:
        raise SystemExit(f"Could not read Music.app state: {result.stderr.strip()}")
    parts = result.stdout.rstrip("\n").split("\t")
    parts += [""] * (5 - len(parts))
    duration_text = parts[3]
    try:
        duration = float(duration_text) if duration_text else None
    except ValueError:
        duration = None
    return {
        "state": parts[0] or "unknown",
        "title": parts[1],
        "artist": parts[2],
        "duration": duration,
        "album": parts[4],
    }


def track_matches_request(status: dict[str, object], request: SimpleNamespace) -> bool:
    title = str(status.get("title") or "").casefold()
    artist = str(status.get("artist") or "").casefold()
    album = str(status.get("album") or "").casefold()
    expected_album = str(getattr(request, "play_album", "") or "").casefold()
    if title != request.play_title.casefold() or artist != request.play_artist.casefold():
        return False
    return not expected_album or album == expected_album


def ensure_music_playing(request: SimpleNamespace) -> dict[str, object]:
    if not request.skip_playback_control:
        log(f'Playing Music.app track: "{request.play_title}" - {request.play_artist}')
        visual.play_music_library_track(request.play_title, request.play_artist, request.play_album)

    deadline = time.time() + 8
    try:
        last_status = music_status()
    except SystemExit as error:
        if request.require_music_playing:
            raise
        return {
            "state": "unavailable",
            "matchesRequestedTrack": False,
            "duration": None,
            "error": str(error),
        }
    while time.time() < deadline:
        try:
            last_status = music_status()
        except SystemExit as error:
            if request.require_music_playing:
                raise
            return {
                "state": "unavailable",
                "matchesRequestedTrack": False,
                "duration": None,
                "error": str(error),
            }
        if last_status["state"] == "playing":
            break
        time.sleep(0.25)

    if request.require_music_playing and last_status["state"] != "playing":
        raise SystemExit(f"Music.app is not playing; current state is {last_status['state']!r}")

    if request.require_music_playing and not track_matches_request(last_status, request):
        raise SystemExit(
            "Music.app is playing a different track than the requested performance fixture"
        )

    return {
        "state": last_status["state"],
        "matchesRequestedTrack": track_matches_request(last_status, request),
        "duration": last_status["duration"],
        "album": last_status.get("album"),
    }


def seek_music_position(position: float | None) -> None:
    if position is None:
        return
    script = f'''
tell application "Music"
    if it is running then
        set player position to {position:.3f}
        if player state is not playing then play
    end if
end tell
'''
    result = run(["osascript", "-e", script], check=False)
    if result.returncode != 0:
        raise SystemExit(f"Could not seek Music.app to {position:.3f}s: {result.stderr.strip()}")
    time.sleep(0.5)


def unverified_music_status(reason: str) -> dict[str, object]:
    return {
        "state": "unverified",
        "matchesRequestedTrack": False,
        "duration": None,
        "album": None,
        "automationUnavailableAllowed": True,
        "acceptanceEligible": False,
        "error": reason,
    }


def route_app(page: str) -> int:
    if visual.APP.exists():
        run(["open", str(visual.APP)], check=False)
    pid = visual.find_pid()
    if pid is None:
        pid = visual.launch_app()

    visual.request_page(page)
    visual.activate_app()
    time.sleep(0.5)
    pid = visual.find_pid()
    if pid is None:
        raise SystemExit("nanoPod process disappeared after launch")
    return pid


def read_process_sample(pid: int) -> dict[str, object]:
    result = run(["ps", "-p", str(pid), "-o", "%cpu=", "-o", "rss="], check=False)
    if result.returncode != 0 or not result.stdout.strip():
        raise SystemExit(f"Could not sample nanoPod process {pid}; process may have exited")
    parts = result.stdout.split()
    if len(parts) < 2:
        raise SystemExit(f"Unexpected ps output for nanoPod process {pid}: {result.stdout!r}")
    cpu = float(parts[0])
    rss_kb = int(float(parts[1]))
    return {
        "cpu_percent": cpu,
        "rss_kb": rss_kb,
        "rss_mb": rss_kb / 1024.0,
    }


def post_scroll_tap_jump(rect: tuple[int, int, int, int]) -> None:
    x, y, width, height = rect
    center_x = int(x + width * 0.48)
    scroll_y = int(y + height * 0.48)
    tap_y = scroll_y
    swift_source = f'''
import CoreGraphics
import Foundation

let source = CGEventSource(stateID: .hidSystemState)
let scrollPoint = CGPoint(x: {center_x}, y: {scroll_y})
let tapPoint = CGPoint(x: {center_x}, y: {tap_y})

if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: scrollPoint, mouseButton: .left) {{
    move.post(tap: .cghidEventTap)
}}
usleep(70_000)

for _ in 0..<3 {{
    if let event = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 1,
        wheel1: -220,
        wheel2: 0,
        wheel3: 0
    ) {{
        event.location = scrollPoint
        event.post(tap: .cghidEventTap)
    }}
    usleep(90_000)
}}

if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: tapPoint, mouseButton: .left) {{
    down.post(tap: .cghidEventTap)
}}
usleep(70_000)
if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: tapPoint, mouseButton: .left) {{
    up.post(tap: .cghidEventTap)
}}
'''
    run(["swift", "-e", swift_source], check=False)


def sample_process(
    pid: int,
    duration: float,
    interval: float,
    *,
    interaction: str = "passive",
    interaction_interval: float = 3.0,
    window_rect: tuple[int, int, int, int] | None = None,
) -> list[dict[str, object]]:
    samples: list[dict[str, object]] = []
    started = time.monotonic()
    deadline = started + duration
    next_sample = started
    next_interaction = started + min(max(interaction_interval, interval), max(duration, interval))

    while time.monotonic() < deadline or not samples:
        now = time.monotonic()
        if interaction == "scroll-tap-jump" and window_rect and now >= next_interaction:
            post_scroll_tap_jump(window_rect)
            next_interaction = time.monotonic() + interaction_interval
            now = time.monotonic()
        if now < next_sample:
            time.sleep(next_sample - now)
            now = time.monotonic()
        sample = read_process_sample(pid)
        sample["elapsed_s"] = round(now - started, 3)
        sample["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        sample["pid"] = pid
        samples.append(sample)
        next_sample += interval

    return samples


def percentile(values: list[float], percent: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    rank = (percent / 100.0) * (len(ordered) - 1)
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return ordered[int(rank)]
    weight = rank - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def summarize_samples(samples: list[dict[str, object]]) -> dict[str, object]:
    cpu = [float(sample["cpu_percent"]) for sample in samples]
    rss = [float(sample["rss_mb"]) for sample in samples]
    return {
        "sampleCount": len(samples),
        "cpuPercent": {
            "avg": round(statistics.fmean(cpu), 3),
            "median": round(statistics.median(cpu), 3),
            "p95": round(percentile(cpu, 95), 3),
            "max": round(max(cpu), 3),
        },
        "rssMB": {
            "avg": round(statistics.fmean(rss), 3),
            "median": round(statistics.median(rss), 3),
            "p95": round(percentile(rss, 95), 3),
            "max": round(max(rss), 3),
        },
    }


def write_csv(path: Path, request: SimpleNamespace, samples: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "timestamp",
                "elapsed_s",
                "pid",
                "page",
                "cpu_percent",
                "rss_kb",
                "rss_mb",
            ],
        )
        writer.writeheader()
        for sample in samples:
            writer.writerow({
                "timestamp": sample["timestamp"],
                "elapsed_s": sample["elapsed_s"],
                "pid": sample["pid"],
                "page": request.page,
                "cpu_percent": sample["cpu_percent"],
                "rss_kb": sample["rss_kb"],
                "rss_mb": round(float(sample["rss_mb"]), 3),
            })


def build_summary(
    request: SimpleNamespace,
    pid: int,
    workload: dict[str, object] | None,
    music: dict[str, object],
    samples: list[dict[str, object]],
    csv_path: Path,
) -> dict[str, object]:
    return {
        "page": request.page,
        "fixture": request.fixture,
        "track": {
            "title": request.play_title,
            "artist": request.play_artist,
            "album": request.play_album,
            "duration": request.play_duration,
        },
        "lyricsWorkload": workload,
        "expectations": {
            "lyrics": request.expect_lyrics,
            "translation": request.expect_translation,
            "selectedSource": request.expect_selected_source,
            "lyricsLineCount": request.expect_lyrics_line_count,
            "firstRealLineSHA256": request.expect_first_real_line_sha256,
            "musicPlayingRequired": request.require_music_playing,
            "allowMusicAutomationUnavailable": request.allow_music_automation_unavailable,
        },
        "featureState": {
            "pageRoute": f"nanopod://page/{request.page}",
            "skipCompletionCount": None,
            "skipCompletionCountReason": "not available without app-side opt-in instrumentation",
        },
        "process": {
            "name": "nanoPod",
            "pid": pid,
        },
        "music": music,
        "measurement": {
            "warmupSeconds": request.warmup,
            "durationSeconds": request.duration,
            "intervalSeconds": request.interval,
            "seekPositionSeconds": request.seek_position,
            "interaction": request.interaction,
            "interactionIntervalSeconds": request.interaction_interval,
            **summarize_samples(samples),
        },
        "files": {
            "csv": str(csv_path),
            "summary": str(csv_path.with_suffix(".json")),
        },
    }


def write_summary(path: Path, summary: dict[str, object]) -> None:
    path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def parse_args() -> tuple[argparse.ArgumentParser, argparse.Namespace]:
    parser = argparse.ArgumentParser(
        description="Collect local nanoPod CPU/RSS evidence for album, lyrics, or playlist pages."
    )
    parser.add_argument("--page", choices=["album", "lyrics", "playlist"], default="lyrics")
    parser.add_argument("--fixture", choices=sorted(visual.FIXTURES), help="use a visual harness fixture")
    parser.add_argument("--play-title", help="Music.app library track title to play before measuring")
    parser.add_argument("--play-artist", help="Music.app library track artist to play before measuring")
    parser.add_argument("--play-duration", type=float, help="expected track duration in seconds")
    parser.add_argument(
        "--expect-lyrics",
        choices=["fixture", "any", "line", "syllable"],
        default="fixture",
        help="lyrics workload expectation validated through LyricsVerifier",
    )
    translation_group = parser.add_mutually_exclusive_group()
    translation_group.add_argument(
        "--expect-translation",
        dest="expect_translation",
        action="store_true",
        default=None,
        help="require source or translated lyrics in the LyricsVerifier result",
    )
    translation_group.add_argument(
        "--allow-missing-translation",
        dest="expect_translation",
        action="store_false",
        help="do not require translated lyrics even when the matched fixture normally does",
    )
    parser.add_argument("--duration", type=float, default=16.0, help="measurement duration in seconds")
    parser.add_argument("--warmup", type=float, default=8.0, help="warmup seconds after routing to the page")
    parser.add_argument("--interval", type=float, default=0.5, help="sampling interval in seconds")
    parser.add_argument("--seek-position", type=float, help="Music.app playback position before warmup/sampling")
    parser.add_argument(
        "--interaction",
        choices=["passive", "scroll-tap-jump"],
        default="passive",
        help="optional telemetry-only input workload to run while sampling",
    )
    parser.add_argument(
        "--interaction-interval",
        type=float,
        default=3.0,
        help="seconds between scroll-tap-jump interaction bursts",
    )
    parser.add_argument("--label", default="perf", help="short label included in output file names")
    parser.add_argument("--output-dir", default=str(OUT_DIR), help="directory for CSV and JSON evidence")
    parser.add_argument(
        "--require-music-playing",
        action="store_true",
        help="fail unless Music.app is playing the requested track during the run",
    )
    parser.add_argument(
        "--skip-playback-control",
        action="store_true",
        help="do not ask Music.app to play the requested track before measuring",
    )
    parser.add_argument(
        "--allow-music-automation-unavailable",
        action="store_true",
        help=(
            "degraded diagnostics-only mode: when used with --skip-playback-control, "
            "sample nanoPod even if Music.app Apple Events are unavailable. "
            "This is not an acceptance gate."
        ),
    )
    parser.add_argument("--dry-run", action="store_true", help="print the resolved plan without touching apps")
    return parser, parser.parse_args()


def main() -> None:
    parser, args = parse_args()
    request = resolve_args(parser, args)
    if request.allow_music_automation_unavailable and request.require_music_playing:
        parser.error("--allow-music-automation-unavailable cannot be combined with --require-music-playing")
    if request.allow_music_automation_unavailable and not request.skip_playback_control:
        parser.error("--allow-music-automation-unavailable requires --skip-playback-control")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    file_stem = f"perf-{stamp}-{request.page}-{visual.slug(request.label)}"
    csv_path = request.output_dir / f"{file_stem}.csv"
    summary_path = csv_path.with_suffix(".json")

    if request.dry_run:
        print(json.dumps({
            "page": request.page,
            "fixture": request.fixture,
            "track": {
                "title": request.play_title,
                "artist": request.play_artist,
                "album": request.play_album,
                "duration": request.play_duration,
            },
            "expectations": {
                "lyrics": request.expect_lyrics,
                "translation": request.expect_translation,
                "selectedSource": request.expect_selected_source,
                "lyricsLineCount": request.expect_lyrics_line_count,
                "firstRealLineSHA256": request.expect_first_real_line_sha256,
                "musicPlayingRequired": request.require_music_playing,
                "allowMusicAutomationUnavailable": request.allow_music_automation_unavailable,
            },
            "measurement": {
                "warmupSeconds": request.warmup,
                "durationSeconds": request.duration,
                "intervalSeconds": request.interval,
                "seekPositionSeconds": request.seek_position,
                "interaction": request.interaction,
                "interactionIntervalSeconds": request.interaction_interval,
            },
            "files": {
                "csv": str(csv_path),
                "summary": str(summary_path),
            },
        }, indent=2, ensure_ascii=False))
        return

    log("Validating lyrics workload")
    quit_candidate_app()
    enable_required_diagnostics()
    workload = verify_workload(request)
    if request.allow_music_automation_unavailable:
        music = unverified_music_status(
            "Music.app Apple Events were intentionally skipped for diagnostics-only sampling"
        )
    else:
        music = ensure_music_playing(request)
        seek_music_position(request.seek_position)
    if request.require_music_playing:
        music = ensure_music_playing(SimpleNamespace(**{
            **request.__dict__,
            "skip_playback_control": True,
        }))

    log(f"Routing nanoPod to {request.page} page")
    pid = route_app(request.page)
    window_rect = visual.nano_window_target().rect if request.interaction == "scroll-tap-jump" else None

    if request.warmup > 0:
        log(f"Waiting {request.warmup:.1f}s warmup")
        time.sleep(request.warmup)

    log(f"Sampling process {pid} for {request.duration:.1f}s")
    samples = sample_process(
        pid,
        request.duration,
        request.interval,
        interaction=request.interaction,
        interaction_interval=request.interaction_interval,
        window_rect=window_rect,
    )

    if request.require_music_playing:
        music = ensure_music_playing(SimpleNamespace(**{
            **request.__dict__,
            "skip_playback_control": True,
        }))

    write_csv(csv_path, request, samples)
    summary = build_summary(request, pid, workload, music, samples, csv_path)
    write_summary(summary_path, summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
