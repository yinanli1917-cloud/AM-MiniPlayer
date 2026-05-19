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
import statistics
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import lyrics_visual_harness as visual


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "tmp" / "perf"


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


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
    non_negative_float(parser, args.warmup, "--warmup")

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
        play_album="",
        play_duration=float(duration),
        expect_lyrics=expect_lyrics,
        expect_translation=bool(expect_translation),
        duration=args.duration,
        warmup=args.warmup,
        interval=args.interval,
        label=args.label,
        output_dir=Path(args.output_dir).expanduser(),
        require_music_playing=args.require_music_playing,
        skip_playback_control=args.skip_playback_control,
        dry_run=args.dry_run,
    )


def verify_workload(request: SimpleNamespace) -> dict[str, object] | None:
    if request.expect_lyrics == "any":
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
    try
        set trackName to name of current track
        set trackArtist to artist of current track
        set trackDuration to duration of current track as string
    end try
    return stateText & tab & trackName & tab & trackArtist & tab & trackDuration
end tell
'''
    result = run(["osascript", "-e", script], check=False)
    if result.returncode != 0:
        raise SystemExit(f"Could not read Music.app state: {result.stderr.strip()}")
    parts = result.stdout.rstrip("\n").split("\t")
    parts += [""] * (4 - len(parts))
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
    }


def track_matches_request(status: dict[str, object], request: SimpleNamespace) -> bool:
    title = str(status.get("title") or "").casefold()
    artist = str(status.get("artist") or "").casefold()
    return title == request.play_title.casefold() and artist == request.play_artist.casefold()


def ensure_music_playing(request: SimpleNamespace) -> dict[str, object]:
    if not request.skip_playback_control:
        log(f'Playing Music.app track: "{request.play_title}" - {request.play_artist}')
        visual.play_music_library_track(request.play_title, request.play_artist)

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


def sample_process(pid: int, duration: float, interval: float) -> list[dict[str, object]]:
    samples: list[dict[str, object]] = []
    started = time.monotonic()
    deadline = started + duration
    next_sample = started

    while time.monotonic() < deadline or not samples:
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
            "duration": request.play_duration,
        },
        "lyricsWorkload": workload,
        "expectations": {
            "lyrics": request.expect_lyrics,
            "translation": request.expect_translation,
            "musicPlayingRequired": request.require_music_playing,
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
    parser.add_argument("--dry-run", action="store_true", help="print the resolved plan without touching apps")
    return parser, parser.parse_args()


def main() -> None:
    parser, args = parse_args()
    request = resolve_args(parser, args)

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
                "duration": request.play_duration,
            },
            "expectations": {
                "lyrics": request.expect_lyrics,
                "translation": request.expect_translation,
                "musicPlayingRequired": request.require_music_playing,
            },
            "measurement": {
                "warmupSeconds": request.warmup,
                "durationSeconds": request.duration,
                "intervalSeconds": request.interval,
            },
            "files": {
                "csv": str(csv_path),
                "summary": str(summary_path),
            },
        }, indent=2, ensure_ascii=False))
        return

    log("Validating lyrics workload")
    workload = verify_workload(request)
    music = ensure_music_playing(request)

    log(f"Routing nanoPod to {request.page} page")
    pid = route_app(request.page)

    if request.warmup > 0:
        log(f"Waiting {request.warmup:.1f}s warmup")
        time.sleep(request.warmup)

    log(f"Sampling process {pid} for {request.duration:.1f}s")
    samples = sample_process(pid, request.duration, request.interval)

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
