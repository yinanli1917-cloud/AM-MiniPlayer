#!/usr/bin/env python3
"""
nanoPod long-run performance soak harness.

Drives real Music.app playback and nanoPod page routing while sampling CPU/RSS.
Use this to reproduce long-session slowdown without guessing from short traces.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import time
from pathlib import Path
from types import SimpleNamespace

import lyrics_visual_harness as visual
import perf_harness as perf


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "tmp" / "soak"


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = int((len(ordered) - 1) * pct)
    return ordered[index]


def summarize(values: list[float]) -> dict[str, float]:
    if not values:
        return {"avg": 0, "median": 0, "p95": 0, "max": 0}
    return {
        "avg": round(sum(values) / len(values), 3),
        "median": round(statistics.median(values), 3),
        "p95": round(percentile(values, 0.95), 3),
        "max": round(max(values), 3),
    }


def value_slope_mb_per_hour(samples: list[dict[str, object]], key: str) -> float:
    samples = [sample for sample in samples if sample.get(key) not in (None, "")]
    if len(samples) < 2:
        return 0.0
    first = samples[0]
    last = samples[-1]
    elapsed = float(last["elapsedS"]) - float(first["elapsedS"])
    if elapsed <= 0:
        return 0.0
    return round((float(last[key]) - float(first[key])) / elapsed * 3600, 3)


def fixture_request(fixture_name: str, allow_unverified: bool) -> SimpleNamespace | None:
    fixture = visual.FIXTURES[fixture_name]
    request = visual.workload_args(fixture)
    if allow_unverified:
        return request
    visual.verify_lyrics_workload(request)
    return request


def resolve_fixture_requests(fixture_names: list[str], allow_unverified: bool) -> list[SimpleNamespace]:
    requests: list[SimpleNamespace] = []
    skipped: list[dict[str, str]] = []
    for name in fixture_names:
        try:
            request = fixture_request(name, allow_unverified)
            if request is None:
                continue
            visual.play_music_library_track(request.play_title, request.play_artist)
            requests.append(request)
        except SystemExit as error:
            skipped.append({"fixture": name, "reason": str(error)})

    if not requests:
        raise SystemExit(f"No playable verified fixtures found. Skipped: {skipped}")
    return requests


def write_csv(path: Path, samples: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "elapsedS",
                "wallTime",
                "pid",
                "page",
                "title",
                "artist",
                "cpuPercent",
                "rssMB",
                "physicalFootprintMB",
                "sampleDelayS",
            ],
        )
        writer.writeheader()
        writer.writerows(samples)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run a long nanoPod performance soak.")
    parser.add_argument("--duration", type=float, default=3600, help="total soak seconds")
    parser.add_argument("--sample-interval", type=float, default=5.0, help="seconds between CPU/RSS samples")
    parser.add_argument("--cycle-interval", type=float, default=180.0, help="seconds between track/page changes")
    parser.add_argument("--settle", type=float, default=3.0, help="seconds after playback/page switch before sampling")
    parser.add_argument("--fixtures", default="translated-word,word-japanese", help="comma-separated visual fixture names")
    parser.add_argument("--pages", default="lyrics,album,playlist,lyrics", help="comma-separated page route names")
    parser.add_argument("--label", default="soak", help="label used in output filenames")
    parser.add_argument("--output-dir", default=str(OUT_DIR))
    parser.add_argument("--allow-unverified", action="store_true", help="do not require LyricsVerifier fixture pass")
    args = parser.parse_args()

    if args.duration <= 0 or args.sample_interval <= 0 or args.cycle_interval <= 0:
        parser.error("duration, sample-interval, and cycle-interval must be positive")

    fixture_names = [item.strip() for item in args.fixtures.split(",") if item.strip()]
    pages = [item.strip() for item in args.pages.split(",") if item.strip()]
    unknown = [name for name in fixture_names if name not in visual.FIXTURES]
    if unknown:
        parser.error(f"unknown fixtures: {', '.join(unknown)}")
    if not pages:
        parser.error("at least one page is required")

    requests = resolve_fixture_requests(fixture_names, args.allow_unverified)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    output_dir = Path(args.output_dir).expanduser()
    csv_path = output_dir / f"soak-{stamp}-{args.label}.csv"
    summary_path = output_dir / f"soak-{stamp}-{args.label}.json"

    start = time.monotonic()
    deadline = start + args.duration
    next_cycle = start
    cycle_index = -1
    current_request = requests[0]
    current_page = pages[0]
    pid = perf.route_app(current_page)
    samples: list[dict[str, object]] = []
    events: list[dict[str, object]] = []
    last_sample_at = start

    while time.monotonic() < deadline:
        now = time.monotonic()
        if now >= next_cycle:
            cycle_index += 1
            current_request = requests[cycle_index % len(requests)]
            current_page = pages[cycle_index % len(pages)]
            event: dict[str, object] = {
                "elapsedS": round(now - start, 3),
                "page": current_page,
                "title": current_request.play_title,
                "artist": current_request.play_artist,
            }
            try:
                visual.play_music_library_track(
                    current_request.play_title,
                    current_request.play_artist,
                    current_request.play_album,
                )
                pid = perf.route_app(current_page)
                time.sleep(args.settle)
                event["status"] = "ok"
            except SystemExit as error:
                event["status"] = "error"
                event["error"] = str(error)
            events.append(event)
            next_cycle = now + args.cycle_interval

        sample_started = time.monotonic()
        delay = sample_started - last_sample_at
        try:
            raw = perf.read_process_sample(pid)
            physical_footprint = raw.get("physical_footprint_mb")
            samples.append({
                "elapsedS": round(sample_started - start, 3),
                "wallTime": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "pid": pid,
                "page": current_page,
                "title": current_request.play_title,
                "artist": current_request.play_artist,
                "cpuPercent": raw["cpu_percent"],
                "rssMB": round(float(raw["rss_mb"]), 3),
                "physicalFootprintMB": round(float(physical_footprint), 3)
                if physical_footprint is not None
                else "",
                "sampleDelayS": round(delay, 3),
            })
        except SystemExit as error:
            events.append({
                "elapsedS": round(sample_started - start, 3),
                "status": "sample_error",
                "error": str(error),
            })
            pid = perf.route_app(current_page)

        last_sample_at = sample_started
        sleep_for = max(0.1, args.sample_interval - (time.monotonic() - sample_started))
        time.sleep(min(sleep_for, max(0.1, deadline - time.monotonic())))

    write_csv(csv_path, samples)
    cpu_values = [float(sample["cpuPercent"]) for sample in samples]
    rss_values = [float(sample["rssMB"]) for sample in samples]
    physical_values = [
        float(sample["physicalFootprintMB"])
        for sample in samples
        if sample.get("physicalFootprintMB") not in (None, "")
    ]
    delay_values = [float(sample["sampleDelayS"]) for sample in samples[1:]]
    stalls = [
        sample for sample in samples[1:]
        if float(sample["sampleDelayS"]) > max(args.sample_interval * 2.5, args.sample_interval + 2.0)
    ]
    summary = {
        "durationSeconds": args.duration,
        "sampleIntervalSeconds": args.sample_interval,
        "cycleIntervalSeconds": args.cycle_interval,
        "fixtures": [request.play_title for request in requests],
        "pages": pages,
        "sampleCount": len(samples),
        "cpuPercent": summarize(cpu_values),
        "rssMB": summarize(rss_values),
        "rssSlopeMBPerHour": value_slope_mb_per_hour(samples, "rssMB"),
        "sampleDelaySeconds": summarize(delay_values),
        "stallCount": len(stalls),
        "stallSamples": stalls[:20],
        "events": events,
        "files": {
            "csv": str(csv_path),
            "summary": str(summary_path),
        },
    }
    if physical_values:
        summary["physicalFootprintMB"] = summarize(physical_values)
        summary["physicalFootprintSlopeMBPerHour"] = value_slope_mb_per_hour(samples, "physicalFootprintMB")
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
