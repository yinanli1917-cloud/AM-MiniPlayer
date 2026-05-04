#!/usr/bin/env python3
"""
nanoPod local performance harness.

Measures nanoPod CPU and memory while optionally driving rapid Music.app skips.
This is intentionally external to the app so it can validate signed app bundles
without adding diagnostics to production code.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import statistics
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "nanoPod.app"
OUT_DIR = ROOT / "tmp" / "perf"


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True)


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


def find_pid() -> int | None:
    result = run(["pgrep", "-x", "nanoPod"], check=False)
    pids = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    return int(pids[-1]) if pids else None


def music_is_running() -> bool:
    return run(["pgrep", "-x", "Music"], check=False).returncode == 0


def music_player_state() -> str:
    result = run([
        "osascript",
        "-e",
        'tell application "Music" to if it is running then get player state as string',
    ], check=False)
    return result.stdout.strip()


def send_next_track() -> None:
    run(["osascript", "-e", 'tell application "Music" to next track'], check=False)


def sample_process(pid: int) -> tuple[float, float] | None:
    result = run(["ps", "-p", str(pid), "-o", "%cpu=,rss="], check=False)
    line = result.stdout.strip()
    if not line:
        return None
    parts = line.split()
    if len(parts) < 2:
        return None
    cpu = float(parts[0])
    rss_mb = float(parts[1]) / 1024.0
    return cpu, rss_mb


def start_stack_sample(pid: int, duration: float, output_path: Path) -> subprocess.Popen[str] | None:
    sample_tool = shutil.which("sample")
    if sample_tool is None:
        return None

    return subprocess.Popen(
        [sample_tool, str(pid), str(max(1, int(duration))), "-file", str(output_path)],
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * pct)))
    return ordered[idx]


def run_trial(args: argparse.Namespace, trial_index: int, trial_count: int) -> dict[str, object]:
    pid = launch_app()
    if args.warmup > 0:
        time.sleep(args.warmup)

    state = music_player_state() if music_is_running() else "not running"
    if args.require_music_playing and state != "playing":
        raise SystemExit(f"Music.app is {state}; start playback before rapid-switch testing")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    suffix = f"-t{trial_index}" if trial_count > 1 else ""
    csv_path = OUT_DIR / f"perf-{stamp}{suffix}.csv"
    summary_path = OUT_DIR / f"perf-{stamp}{suffix}.json"
    sample_path = OUT_DIR / f"sample-{stamp}{suffix}.txt"
    sample_proc = start_stack_sample(pid, args.duration, sample_path) if args.stack_sample else None

    samples: list[dict[str, float]] = []
    next_skip_at = time.time()
    skips_sent = 0
    started = time.time()

    with csv_path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["elapsed_s", "cpu_pct", "rss_mb", "skips_sent"])
        writer.writeheader()
        while time.time() - started < args.duration:
            now = time.time()
            if skips_sent < args.skip_count and now >= next_skip_at:
                send_next_track()
                skips_sent += 1
                next_skip_at = now + args.skip_interval

            sample = sample_process(pid)
            if sample is None:
                raise SystemExit("nanoPod exited during harness run")
            cpu, rss_mb = sample
            row = {
                "elapsed_s": round(now - started, 3),
                "cpu_pct": cpu,
                "rss_mb": round(rss_mb, 1),
                "skips_sent": skips_sent,
            }
            samples.append(row)
            writer.writerow(row)
            time.sleep(args.interval)

    cpus = [row["cpu_pct"] for row in samples]
    rss = [row["rss_mb"] for row in samples]
    if sample_proc is not None:
        try:
            # `sample` often spends several seconds symbolizing after the timed
            # capture ends. Give it enough time to finish writing the report so
            # rapid-skip runs retain the stack evidence they were asked to collect.
            sample_proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            sample_proc.terminate()
            sample_proc.wait(timeout=2)

    summary = {
        "pid": pid,
        "trial": trial_index,
        "trials": trial_count,
        "music_state_at_start": state,
        "duration_s": args.duration,
        "warmup_s": args.warmup,
        "interval_s": args.interval,
        "skip_count_requested": args.skip_count,
        "skip_count_sent": skips_sent,
        "samples": len(samples),
        "cpu_avg_pct": round(statistics.fmean(cpus), 2) if cpus else 0,
        "cpu_p95_pct": round(percentile(cpus, 0.95), 2),
        "cpu_max_pct": round(max(cpus), 2) if cpus else 0,
        "rss_avg_mb": round(statistics.fmean(rss), 1) if rss else 0,
        "rss_max_mb": round(max(rss), 1) if rss else 0,
        "csv": str(csv_path),
    }
    if args.stack_sample:
        summary["sample"] = str(sample_path) if sample_path.exists() else None
    summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def summarize_trials(trials: list[dict[str, object]]) -> dict[str, object]:
    avg_values = [float(t["cpu_avg_pct"]) for t in trials]
    p95_values = [float(t["cpu_p95_pct"]) for t in trials]
    max_values = [float(t["cpu_max_pct"]) for t in trials]
    rss_max_values = [float(t["rss_max_mb"]) for t in trials]

    return {
        "trials": len(trials),
        "cpu_avg_pct_median": round(statistics.median(avg_values), 2),
        "cpu_avg_pct_min": round(min(avg_values), 2),
        "cpu_avg_pct_max": round(max(avg_values), 2),
        "cpu_p95_pct_median": round(statistics.median(p95_values), 2),
        "cpu_p95_pct_min": round(min(p95_values), 2),
        "cpu_p95_pct_max": round(max(p95_values), 2),
        "cpu_max_pct_median": round(statistics.median(max_values), 2),
        "cpu_max_pct_min": round(min(max_values), 2),
        "cpu_max_pct_max": round(max(max_values), 2),
        "rss_max_mb_max": round(max(rss_max_values), 1),
        "trial_summaries": trials,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Measure nanoPod CPU during idle or rapid Music.app skips.")
    parser.add_argument("--duration", type=float, default=10.0, help="sampling duration in seconds")
    parser.add_argument("--warmup", type=float, default=2.0, help="seconds to wait after launch before sampling")
    parser.add_argument("--interval", type=float, default=0.2, help="sampling interval in seconds")
    parser.add_argument("--skip-count", type=int, default=0, help="number of next-track commands to send")
    parser.add_argument("--skip-interval", type=float, default=0.25, help="delay between next-track commands")
    parser.add_argument("--trials", type=int, default=1, help="number of repeated measurements to run")
    parser.add_argument("--trial-gap", type=float, default=2.0, help="seconds to wait between repeated trials")
    parser.add_argument("--require-music-playing", action="store_true", help="fail if Music.app is not currently playing")
    parser.add_argument("--stack-sample", action="store_true", help="also collect a macOS sample stack file for nanoPod")
    args = parser.parse_args()

    if args.trials < 1:
        raise SystemExit("--trials must be >= 1")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    trial_summaries: list[dict[str, object]] = []
    for trial_index in range(1, args.trials + 1):
        trial_summaries.append(run_trial(args, trial_index, args.trials))
        if trial_index < args.trials and args.trial_gap > 0:
            time.sleep(args.trial_gap)

    summary = trial_summaries[0] if args.trials == 1 else summarize_trials(trial_summaries)
    if args.trials > 1:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        summary_path = OUT_DIR / f"perf-{stamp}-trials.json"
        summary["summary"] = str(summary_path)
        summary_path.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
