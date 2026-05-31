#!/usr/bin/env python3
"""
Sequential reference-vs-candidate LUXB monitor.

Runs the reference app and candidate app one at a time against the same fixture,
clearing live diagnostics before each run and copying the generated CSVs into
the run artifact directory. This avoids the shared diagnostics-path ambiguity
that exists when two nanoPod processes run side by side.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import lyrics_motion_evaluator as motion
import lyrics_visual_harness as visual
import perf_harness as perf
from luxb_dual_monitor import (
    CANDIDATE_APP,
    CANDIDATE_BUNDLE_ID,
    REFERENCE_BUNDLE_ID,
    REFERENCE_CLONE,
    prepare_reference_clone,
)


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "tmp" / "benchmark" / "sequential-reference"
LIVE_DIAGNOSTICS_DIR = Path.home() / "Library" / "Application Support" / "nanoPod" / "Diagnostics" / "Live"
LIVE_LINE_MOTION_CSV = LIVE_DIAGNOSTICS_DIR / "lyrics_line_motion_samples.csv"
LIVE_WAVE_TIMELINE_CSV = LIVE_DIAGNOSTICS_DIR / "lyrics_wave_timeline.csv"


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run(cmd: list[str], *, check: bool = True, cwd: Path | None = None, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=True,
        cwd=cwd or ROOT,
        env=env,
    )


def read_bundle_id(app_path: Path, fallback: str) -> str:
    plist = app_path / "Contents" / "Info.plist"
    if not plist.is_file():
        return fallback
    try:
        with plist.open("rb") as handle:
            data = plistlib.load(handle)
        value = data.get("CFBundleIdentifier")
        return str(value) if value else fallback
    except Exception:
        return fallback


def write_bool_preference(bundle_id: str, key: str, value: bool) -> None:
    bool_value = "true" if value else "false"
    for domain in {bundle_id, CANDIDATE_BUNDLE_ID}:
        run(["defaults", "write", domain, key, "-bool", bool_value], check=False)


def enable_diagnostics_for_bundle(bundle_id: str) -> None:
    write_bool_preference(bundle_id, "ownerDiagnosticsEnabled", True)
    write_bool_preference(bundle_id, "ownerLineMotionGeometryEnabled", True)
    write_bool_preference(bundle_id, "ownerLyricWaveTimelineEnabled", True)


def kill_all_nanopod() -> None:
    run(["killall", "nanoPod"], check=False)
    deadline = time.time() + 5.0
    while time.time() < deadline:
        result = run(["pgrep", "-x", "nanoPod"], check=False)
        if not result.stdout.strip():
            return
        time.sleep(0.2)
    run(["pkill", "-x", "nanoPod"], check=False)
    time.sleep(0.5)


def clear_live_diagnostics() -> None:
    LIVE_DIAGNOSTICS_DIR.mkdir(parents=True, exist_ok=True)
    for path in (LIVE_LINE_MOTION_CSV, LIVE_WAVE_TIMELINE_CSV):
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def copy_diagnostics(role_dir: Path) -> dict[str, str | None]:
    role_dir.mkdir(parents=True, exist_ok=True)
    copied: dict[str, str | None] = {"lineMotionCsv": None, "waveTimelineCsv": None}
    for source, key, name in (
        (LIVE_LINE_MOTION_CSV, "lineMotionCsv", "lyrics_line_motion_samples.csv"),
        (LIVE_WAVE_TIMELINE_CSV, "waveTimelineCsv", "lyrics_wave_timeline.csv"),
    ):
        if source.is_file():
            destination = role_dir / name
            shutil.copy2(source, destination)
            copied[key] = str(destination)
    return copied


def parse_perf_summary(stdout: str) -> dict[str, Any] | None:
    if not stdout.strip():
        return None
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return None


def run_role(
    *,
    role: str,
    app_path: Path,
    fixture: str,
    duration: float,
    warmup: float,
    interval: float,
    interaction_interval: float,
    out_dir: Path,
) -> dict[str, Any]:
    bundle_id = read_bundle_id(
        app_path,
        REFERENCE_BUNDLE_ID if role == "reference" else CANDIDATE_BUNDLE_ID,
    )
    role_dir = out_dir / role

    log(f"[{role}] clearing diagnostics and launching {app_path}")
    kill_all_nanopod()
    clear_live_diagnostics()
    enable_diagnostics_for_bundle(bundle_id)

    cmd = [
        sys.executable,
        str(ROOT / "scripts" / "perf_harness.py"),
        "--page",
        "lyrics",
        "--fixture",
        fixture,
        "--duration",
        str(duration),
        "--warmup",
        str(warmup),
        "--interval",
        str(interval),
        "--interaction",
        "scroll-tap-jump",
        "--interaction-interval",
        str(interaction_interval),
        "--label",
        f"sequential-{role}-{fixture}",
        "--output-dir",
        str(role_dir),
        "--require-music-playing",
    ]
    env = {**os.environ, "NANOPOD_APP_PATH": str(app_path)}
    result = run(cmd, check=False, env=env)

    # Diagnostics writes are queued off the main thread. Give them a short,
    # bounded drain window before copying the isolated artifacts.
    time.sleep(1.0)
    copied = copy_diagnostics(role_dir)
    kill_all_nanopod()

    line_motion_path = Path(copied["lineMotionCsv"]) if copied["lineMotionCsv"] else role_dir / "lyrics_line_motion_samples.csv"
    motion_metrics = motion.compute_motion_metrics(motion.load_line_motion_csv(line_motion_path))

    return {
        "role": role,
        "app": str(app_path),
        "bundleID": bundle_id,
        "returncode": result.returncode,
        "passed": result.returncode == 0,
        "stdoutTail": result.stdout[-2000:] if result.stdout else "",
        "stderrTail": result.stderr[-2000:] if result.stderr else "",
        "perfSummary": parse_perf_summary(result.stdout),
        "diagnostics": copied,
        "motion": motion.metrics_to_dict(motion_metrics),
    }


def cpu_avg(run_summary: dict[str, Any]) -> float | None:
    perf_summary = run_summary.get("perfSummary")
    if not isinstance(perf_summary, dict):
        return None
    measurement = perf_summary.get("measurement")
    if not isinstance(measurement, dict):
        return None
    cpu = measurement.get("cpuPercent")
    if not isinstance(cpu, dict):
        return None
    value = cpu.get("avg")
    return float(value) if isinstance(value, (int, float)) else None


def motion_reference_comparability(metrics: motion.MotionMetrics) -> dict[str, Any]:
    if metrics.sample_count == 0:
        return {
            "comparable": False,
            "reason": "no line-motion samples",
        }
    if (
        metrics.target_error_y_max == 0
        and metrics.inter_line_delta_error_y_max == 0
        and metrics.active_target_settle_time_max == 0
    ):
        return {
            "comparable": False,
            "reason": "zero-error target-layout signal; not presentation-layer drift evidence",
        }
    return {
        "comparable": True,
        "reason": "presentation drift signal present",
    }


def resolve_reference_app(path_text: str | None) -> Path:
    if path_text:
        app_path = Path(path_text).expanduser().resolve()
        if not app_path.is_dir():
            raise SystemExit(f"Reference app does not exist: {app_path}")
        return app_path
    if not REFERENCE_CLONE.is_dir():
        prepare_reference_clone()
    if not REFERENCE_CLONE.is_dir():
        raise SystemExit(f"Reference app does not exist: {REFERENCE_CLONE}")
    return REFERENCE_CLONE


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run isolated sequential LUXB reference comparison.")
    parser.add_argument("--fixture", choices=sorted(visual.FIXTURES), default="line-winter-trip")
    parser.add_argument("--reference-app", help="reference .app to run first; defaults to prepared v2.8 clone")
    parser.add_argument("--candidate-app", default=str(CANDIDATE_APP), help="candidate .app to run second")
    parser.add_argument("--duration", type=float, default=24.0)
    parser.add_argument("--warmup", type=float, default=10.0)
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--interaction-interval", type=float, default=2.5)
    parser.add_argument("--label", default="sequential-reference")
    parser.add_argument("--output-dir", default=str(OUT_DIR))
    parser.add_argument(
        "--allow-empty-reference-motion",
        action="store_true",
        help="do not fail when the old reference app does not emit line-motion CSV",
    )
    parser.add_argument(
        "--allow-incomparable-reference-motion",
        action="store_true",
        help="do not fail when reference motion CSV exists but is target-layout-only rather than presentation drift evidence",
    )
    parser.add_argument(
        "--max-candidate-cpu-ratio",
        type=float,
        default=1.0,
        help="fail when candidate average CPU is above this ratio of reference average CPU",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    reference_app = resolve_reference_app(args.reference_app)
    candidate_app = Path(args.candidate_app).expanduser().resolve()
    if not candidate_app.is_dir():
        raise SystemExit(f"Candidate app does not exist: {candidate_app}")

    fixture = visual.FIXTURES[args.fixture]
    visual.verify_lyrics_workload(visual.workload_args(fixture))

    stamp = time.strftime("%Y%m%d-%H%M%S")
    out_dir = Path(args.output_dir).expanduser() / f"sequential-{stamp}-{visual.slug(args.label)}-{args.fixture}"
    out_dir.mkdir(parents=True, exist_ok=True)

    reference = run_role(
        role="reference",
        app_path=reference_app,
        fixture=args.fixture,
        duration=args.duration,
        warmup=args.warmup,
        interval=args.interval,
        interaction_interval=args.interaction_interval,
        out_dir=out_dir,
    )
    candidate = run_role(
        role="candidate",
        app_path=candidate_app,
        fixture=args.fixture,
        duration=args.duration,
        warmup=args.warmup,
        interval=args.interval,
        interaction_interval=args.interaction_interval,
        out_dir=out_dir,
    )

    ref_motion = motion.compute_motion_metrics(
        motion.load_line_motion_csv(Path(reference["diagnostics"]["lineMotionCsv"]))
        if reference["diagnostics"]["lineMotionCsv"] else []
    )
    cand_motion = motion.compute_motion_metrics(
        motion.load_line_motion_csv(Path(candidate["diagnostics"]["lineMotionCsv"]))
        if candidate["diagnostics"]["lineMotionCsv"] else []
    )
    reference_motion_signal = motion_reference_comparability(ref_motion)
    reference_motion_comparable = bool(reference_motion_signal["comparable"])
    motion_failures = (
        motion.compare_metrics(cand_motion, ref_motion)
        if reference_motion_comparable
        else []
    )

    failures: list[str] = []
    if not reference["passed"]:
        failures.append("reference perf harness failed")
    if not candidate["passed"]:
        failures.append("candidate perf harness failed")
    if ref_motion.sample_count == 0 and not args.allow_empty_reference_motion:
        failures.append("reference emitted no line-motion samples")
    if (
        ref_motion.sample_count > 0
        and not reference_motion_comparable
        and not args.allow_incomparable_reference_motion
    ):
        failures.append(f"reference motion is not comparable: {reference_motion_signal['reason']}")
    if cand_motion.sample_count == 0:
        failures.append("candidate emitted no line-motion samples")
    failures.extend(motion_failures)

    ref_cpu = cpu_avg(reference)
    cand_cpu = cpu_avg(candidate)
    cpu_ratio = None
    if ref_cpu is not None and cand_cpu is not None and ref_cpu > 0:
        cpu_ratio = cand_cpu / ref_cpu
        if cpu_ratio > args.max_candidate_cpu_ratio:
            failures.append(
                f"candidate avg CPU ratio {cpu_ratio:.3f} > allowed {args.max_candidate_cpu_ratio:.3f}"
            )

    summary = {
        "fixture": args.fixture,
        "track": {
            "title": fixture["title"],
            "artist": fixture["artist"],
            "album": fixture.get("album", ""),
            "duration": fixture["duration"],
        },
        "measurement": {
            "durationSeconds": args.duration,
            "warmupSeconds": args.warmup,
            "intervalSeconds": args.interval,
            "interaction": "scroll-tap-jump",
            "interactionIntervalSeconds": args.interaction_interval,
        },
        "reference": reference,
        "candidate": candidate,
        "comparison": {
            "referenceCpuAvg": ref_cpu,
            "candidateCpuAvg": cand_cpu,
            "candidateCpuRatio": cpu_ratio,
            "referenceMotionSignal": reference_motion_signal,
            "motionFailures": motion_failures,
        },
        "failures": failures,
        "passed": not failures,
    }

    summary_path = out_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if failures:
        log("FAIL:")
        for failure in failures:
            log(f"  - {failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
