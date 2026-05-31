#!/usr/bin/env python3
"""
Run v2.8 reference and candidate nanoPod side-by-side, same Music fixture, sample both processes.

Reference app is cloned with a distinct bundle ID so both can run simultaneously.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import lyrics_motion_evaluator as motion
import lyrics_visual_harness as visual
import perf_harness as perf


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_ZIP_APP = ROOT / "tmp" / "reference-app" / "nanoPod.app"
REFERENCE_CLONE = ROOT / "tmp" / "reference-app" / "nanoPod-v28-reference.app"
REFERENCE_BUNDLE_ID = "com.yinanli.nanoPod.v28reference"
CANDIDATE_BUNDLE_ID = "com.yinanli.nanoPod"
CANDIDATE_APP = ROOT / "nanoPod.app"
OUT_DIR = ROOT / "tmp" / "benchmark" / "dual-live"


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True, cwd=ROOT)


def prepare_reference_clone() -> Path:
    if not REFERENCE_ZIP_APP.is_dir():
        raise SystemExit(f"Missing {REFERENCE_ZIP_APP}; run: gh release download v2.8 -D tmp/reference-app && unzip …")

    if REFERENCE_CLONE.is_dir():
        shutil.rmtree(REFERENCE_CLONE)
    shutil.copytree(REFERENCE_ZIP_APP, REFERENCE_CLONE)

    plist = REFERENCE_CLONE / "Contents" / "Info.plist"
    run([
        "/usr/libexec/PlistBuddy", "-c",
        f"Set :CFBundleIdentifier {REFERENCE_BUNDLE_ID}",
        str(plist),
    ])
    run([
        "/usr/libexec/PlistBuddy", "-c",
        "Set :CFBundleName nanoPod-v28-ref",
        str(plist),
    ])
    # Re-sign ad-hoc so macOS allows launch
    run(["codesign", "-f", "-s", "-", str(REFERENCE_CLONE)], check=False)
    run([
        "defaults", "write", REFERENCE_BUNDLE_ID,
        "ownerDiagnosticsEnabled", "-bool", "true",
    ], check=False)
    run([
        "defaults", "write", REFERENCE_BUNDLE_ID,
        "ownerLineMotionGeometryEnabled", "-bool", "true",
    ], check=False)
    return REFERENCE_CLONE


def launch_app(app_path: Path, label: str) -> int:
    run(["open", "-n", "-a", str(app_path)], check=False)
    name = app_path.name.replace(".app", "")
    deadline = time.time() + 15
    while time.time() < deadline:
        result = run(["pgrep", "-f", str(app_path / "Contents/MacOS")], check=False)
        pids = [int(x) for x in result.stdout.split() if x.strip().isdigit()]
        if pids:
            log(f"Launched {label} pid={pids[-1]}")
            return pids[-1]
        time.sleep(0.3)
    raise SystemExit(f"Could not launch {app_path}")


def route_lyrics(app_path: Path) -> None:
    run(["open", "-a", str(app_path), "nanopod://page/lyrics"], check=False)


def sample_both(
    reference_pid: int,
    candidate_pid: int,
    duration: float,
    interval: float,
) -> tuple[list[dict], list[dict]]:
    ref_samples: list[dict] = []
    cand_samples: list[dict] = []
    start = time.monotonic()
    deadline = start + duration
    next_t = start
    while time.monotonic() < deadline:
        now = time.monotonic()
        if now < next_t:
            time.sleep(next_t - now)
        elapsed = now - start
        for label, pid, bucket in (
            ("reference", reference_pid, ref_samples),
            ("candidate", candidate_pid, cand_samples),
        ):
            try:
                raw = perf.read_process_sample(pid)
                bucket.append({
                    "elapsed_s": round(elapsed, 3),
                    "label": label,
                    "pid": pid,
                    **raw,
                })
            except SystemExit as error:
                bucket.append({
                    "elapsed_s": round(elapsed, 3),
                    "label": label,
                    "pid": pid,
                    "error": str(error),
                })
        next_t += interval
    return ref_samples, cand_samples


def summarize(samples: list[dict]) -> dict:
    cpu = [float(s["cpu_percent"]) for s in samples if "cpu_percent" in s]
    if not cpu:
        return {"sampleCount": len(samples), "error": "no cpu samples"}
    return {
        "sampleCount": len(samples),
        "cpuAvg": round(sum(cpu) / len(cpu), 3),
        "cpuMax": round(max(cpu), 3),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Dual-app LUXB live monitor")
    parser.add_argument("--fixture", default="word-seek-fun")
    parser.add_argument("--duration", type=float, default=60)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--warmup", type=float, default=15)
    parser.add_argument(
        "--require-motion-samples",
        action="store_true",
        help="fail if candidate motion CSV has zero rows after run",
    )
    args = parser.parse_args()

    if args.fixture not in visual.FIXTURES:
        parser.error(f"unknown fixture {args.fixture}")

    fixture = visual.FIXTURES[args.fixture]
    title, artist = str(fixture["title"]), str(fixture["artist"])
    album = str(fixture.get("album", ""))
    visual.verify_lyrics_workload(visual.workload_args(fixture))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")

    ref_app = prepare_reference_clone()
    if not CANDIDATE_APP.is_dir():
        raise SystemExit("Run ./build_app.sh first")

    kill = run(["killall", "nanoPod"], check=False)
    time.sleep(1)

    log("Playing fixture in Music.app…")
    visual.play_music_library_track(title, artist, album)

    ref_pid = launch_app(ref_app, "v2.8-reference")
    cand_pid = launch_app(CANDIDATE_APP, "candidate")

    time.sleep(2)
    route_lyrics(ref_app)
    route_lyrics(CANDIDATE_APP)
    log(f"Warmup {args.warmup}s…")
    time.sleep(args.warmup)

    log(f"Sampling both apps for {args.duration}s…")
    ref_samples, cand_samples = sample_both(ref_pid, cand_pid, args.duration, args.interval)

    ref_alive = run(["ps", "-p", str(ref_pid)], check=False).returncode == 0
    cand_alive = run(["ps", "-p", str(cand_pid)], check=False).returncode == 0

    ref_motion_path = motion.diagnostics_motion_path(REFERENCE_BUNDLE_ID)
    cand_motion_path = motion.diagnostics_motion_path(CANDIDATE_BUNDLE_ID)
    ref_motion = motion.compute_motion_metrics(motion.load_line_motion_csv(ref_motion_path))
    cand_motion = motion.compute_motion_metrics(motion.load_line_motion_csv(cand_motion_path))
    motion_compare = motion.compare_metrics(cand_motion, ref_motion) if ref_motion.sample_count > 0 else []

    summary = {
        "fixture": args.fixture,
        "track": {"title": title, "artist": artist},
        "reference": {
            "app": str(ref_app),
            "pid": ref_pid,
            "alive": ref_alive,
            "motionCsv": str(ref_motion_path),
            "motion": motion.metrics_to_dict(ref_motion),
            **summarize(ref_samples),
        },
        "candidate": {
            "app": str(CANDIDATE_APP),
            "pid": cand_pid,
            "alive": cand_alive,
            "motionCsv": str(cand_motion_path),
            "motion": motion.metrics_to_dict(cand_motion),
            **summarize(cand_samples),
        },
        "motionComparisonFailures": motion_compare,
        "crashed": {
            "reference": not ref_alive,
            "candidate": not cand_alive,
        },
    }

    out_json = OUT_DIR / f"dual-{stamp}-{args.fixture}.json"
    out_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    csv_path = OUT_DIR / f"dual-{stamp}-{args.fixture}.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["elapsed_s", "label", "pid", "cpu_percent", "rss_mb", "error"])
        writer.writeheader()
        for row in ref_samples + cand_samples:
            writer.writerow({
                "elapsed_s": row.get("elapsed_s"),
                "label": row.get("label"),
                "pid": row.get("pid"),
                "cpu_percent": row.get("cpu_percent", ""),
                "rss_mb": row.get("rss_mb", ""),
                "error": row.get("error", ""),
            })

    print(json.dumps(summary, indent=2))
    if summary["crashed"]["reference"] or summary["crashed"]["candidate"]:
        log("FAIL: one or both apps exited during monitoring")
        return 1
    if args.require_motion_samples and cand_motion.sample_count == 0:
        log(f"FAIL: no line-motion samples in {cand_motion_path}")
        log("  Enable owner diagnostics + lyrics page; rebuild must use AppKit host frame sampling.")
        return 1
    if args.require_motion_samples and ref_motion.sample_count == 0:
        log(f"WARN: reference motion CSV empty at {ref_motion_path} (v2.8 may not write geometry)")
    if motion_compare:
        log("FAIL: candidate motion worse than reference:")
        for failure in motion_compare:
            log(f"  - {failure}")
        return 1
    if summary["candidate"]["cpuAvg"] > summary["reference"]["cpuAvg"] * 1.15:
        log("WARN: candidate CPU >15% above reference")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
