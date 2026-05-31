#!/usr/bin/env python3
"""
Lyrics UX Benchmark (LUXB) — orchestrates unit tests, perf/visual harnesses, and motion CSV evaluation.

Reference: v2.8 / 0.28 beta (see .codex/spec/project/lyrics-ux-benchmark.md)
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import lyrics_motion_evaluator as motion
import lyrics_visual_harness as visual
import perf_harness as perf


ROOT = Path(__file__).resolve().parents[1]
BASELINE_DIR = ROOT / "tmp" / "benchmark" / "v2.8-baseline"
OUT_DIR = ROOT / "tmp" / "benchmark"

DEFAULT_FIXTURES = ["line-winter-trip", "line-breakup-truth", "word-seek-fun", "translated-word"]
V28_ZIP_SHA256 = "3eea02ae553b927c7c88aad956df8a06f1f2a82a61eafa1402a143126b77c73a"
MAIN_CPU_BASELINES = {
    "line-winter-trip": {
        "avg": 44.188,
        "p95": 70.82,
        "label": "main winter scroll-tap baseline tmp/perf/perf-20260530-024819-lyrics-main-baseline-winter-scrolltap.json",
    },
}
SCROLL_TAP_FIXTURES = {"line-winter-trip", "line-breakup-truth"}
UNIT_TEST_FILTER = (
    "LyricsScrollEngineTests|LyricWaveTiming|"
    "NativeLyricsTextRenderPlanTests|NativeLyricsUXMetricsTests|"
    "NativeLyricsRenderPlanTests|NativeLyricsSurfaceSourceTests"
)


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def run(cmd: list[str], *, check: bool = True, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True, cwd=cwd or ROOT)


def quit_candidate_app() -> None:
    run(["osascript", "-e", 'tell application "nanoPod" to quit'], check=False)
    deadline = time.time() + 5.0
    while time.time() < deadline:
        if visual.find_pid() is None:
            return
        time.sleep(0.25)


def swift_unit_tests() -> dict[str, Any]:
    result = run(
        ["swift", "test", "--filter", UNIT_TEST_FILTER],
        check=False,
    )
    return {
        "passed": result.returncode == 0,
        "stdout": result.stdout[-4000:] if result.stdout else "",
        "stderr": result.stderr[-4000:] if result.stderr else "",
    }


def build_app() -> dict[str, Any]:
    result = run(["./build_app.sh"], check=False)
    return {"passed": result.returncode == 0, "returncode": result.returncode}


def run_perf_fixture(
    fixture_name: str,
    *,
    app_path: Path,
    duration: float,
    warmup: float,
    label: str,
    output_dir: Path,
) -> dict[str, Any]:
    fixture = visual.FIXTURES[fixture_name]
    cmd = [
        sys.executable,
        str(ROOT / "scripts" / "perf_harness.py"),
        "--page",
        "lyrics",
        "--fixture",
        fixture_name,
        "--duration",
        str(duration),
        "--warmup",
        str(warmup),
        "--label",
        f"{label}-{fixture_name}",
        "--output-dir",
        str(output_dir),
        "--require-music-playing",
    ]
    if fixture_name in {"line-winter-trip", "line-breakup-truth"}:
        cmd.extend(["--interaction", "scroll-tap-jump", "--interaction-interval", "2.5"])
    env = {"NANOPOD_APP_PATH": str(app_path)}
    result = subprocess.run(
        cmd,
        cwd=ROOT,
        text=True,
        capture_output=True,
        env={**os.environ, **env},
    )
    parsed_summary: dict[str, Any] | None = None
    if result.stdout:
        try:
            parsed_summary = json.loads(result.stdout)
        except json.JSONDecodeError:
            parsed_summary = None
    return {
        "fixture": fixture_name,
        "passed": result.returncode == 0,
        "returncode": result.returncode,
        "summary": parsed_summary,
        "stdout": result.stdout[-2000:] if result.stdout else "",
        "stderr": result.stderr[-2000:] if result.stderr else "",
    }


def diagnostics_motion_path() -> Path:
    from lyrics_motion_evaluator import diagnostics_motion_path as motion_path

    return motion_path("com.yinanli.nanoPod")


def diagnostics_state_path() -> Path:
    application_support = Path.home() / "Library" / "Application Support"
    candidates = [
        application_support / "nanoPod" / "Diagnostics" / "State" / "rolling_state.json",
        application_support / "com.yinanli.nanoPod" / "Diagnostics" / "State" / "rolling_state.json",
    ]
    existing = [path for path in candidates if path.exists()]
    if existing:
        return max(existing, key=lambda path: path.stat().st_mtime)
    return candidates[0]


def parse_event_timestamp(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def load_diagnostics_events() -> list[dict[str, Any]]:
    path = diagnostics_state_path()
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    events = data.get("events", [])
    return events if isinstance(events, list) else []


def fixture_expects_syllable(fixture_name: str) -> bool:
    fixture = visual.FIXTURES[fixture_name]
    return fixture.get("expect_lyrics") == "syllable"


def fixture_uses_scroll_tap(fixture_name: str) -> bool:
    return fixture_name in SCROLL_TAP_FIXTURES


def collect_native_text_parity(
    fixture_name: str,
    *,
    started_at: datetime,
) -> dict[str, Any]:
    fixture = visual.FIXTURES[fixture_name]
    expected_title = str(fixture["title"])
    events: list[dict[str, Any]] = []
    max_metrics: dict[str, float] = {}

    def scan() -> None:
        nonlocal events, max_metrics
        events = []
        max_metrics = {
            "textPhaseSampleCount": 0.0,
            "activeSyllableSampleCount": 0.0,
            "textParityGapCount": 0.0,
            "perRunSweepGapCount": 0.0,
            "perGlyphEmphasisGapCount": 0.0,
            "maxExpectedEmphasisGlyphCount": 0.0,
            "maxAppliedEmphasisGlyphCount": 0.0,
            "maxAppliedEmphasisGlyphMotionCount": 0.0,
            "maxAppliedEmphasisScale": 0.0,
            "maxAppliedEmphasisLiftMagnitude": 0.0,
            "maxAppliedEmphasisGlowOpacity": 0.0,
            "maxAppliedEmphasisAlpha": 0.0,
            "textLayoutCoverageGapCount": 0.0,
            "visualParitySampleCount": 0.0,
            "visualOpacityErrorMax": 0.0,
            "visualScaleErrorMax": 0.0,
            "visualBlurErrorMax": 0.0,
            "activeBlurRadiusMax": 0.0,
            "manualScrollStartCount": 0.0,
            "manualScrollDeltaCount": 0.0,
            "manualScrollEndCount": 0.0,
            "manualScrollRecoveryCount": 0.0,
            "tapToLineCount": 0.0,
            "tapDirectSnapCount": 0.0,
            "manualRecoveryDirectSnapCount": 0.0,
            "hoverEnterCount": 0.0,
            "hoverExitCount": 0.0,
            "hoverBackgroundVisibleCount": 0.0,
            "mainPhaseErrorMax": 0.0,
            "translationPhaseErrorMax": 0.0,
        }
        for event in load_diagnostics_events():
            if event.get("name") != "lyrics.nativeRenderer.summary":
                continue
            event_ts = parse_event_timestamp(event.get("timestamp"))
            if event_ts is None or event_ts < started_at:
                continue
            track = event.get("track") or {}
            if track.get("title") != expected_title:
                continue
            metrics = event.get("metrics") or {}
            if not isinstance(metrics, dict):
                continue
            events.append(event)
            for key in max_metrics:
                try:
                    max_metrics[key] = max(max_metrics[key], float(metrics.get(key, 0) or 0))
                except (TypeError, ValueError):
                    pass

    deadline = time.time() + 5.0
    while True:
        scan()
        if not fixture_expects_syllable(fixture_name):
            break
        if max_metrics.get("activeSyllableSampleCount", 0) > 0:
            break
        if time.time() >= deadline:
            break
        time.sleep(0.25)

    failures: list[str] = []
    if fixture_expects_syllable(fixture_name):
        if not events:
            failures.append("no native renderer text parity summaries for syllable fixture")
        if max_metrics["activeSyllableSampleCount"] <= 0:
            failures.append("no active syllable text phase samples")
        if max_metrics["textParityGapCount"] > 0:
            failures.append(f"text parity gap count {max_metrics['textParityGapCount']:.0f}")
        if max_metrics["perRunSweepGapCount"] > 0:
            failures.append(f"per-run sweep gap count {max_metrics['perRunSweepGapCount']:.0f}")
        if max_metrics["perGlyphEmphasisGapCount"] > 0:
            failures.append(f"per-glyph emphasis gap count {max_metrics['perGlyphEmphasisGapCount']:.0f}")
        if max_metrics["textLayoutCoverageGapCount"] > 0:
            failures.append(f"text layout coverage gap count {max_metrics['textLayoutCoverageGapCount']:.0f}")
        if max_metrics["mainPhaseErrorMax"] > 0.02:
            failures.append(f"main sweep phase error max {max_metrics['mainPhaseErrorMax']:.3f} > 0.020")
        if max_metrics["translationPhaseErrorMax"] > 0.02:
            failures.append(
                f"translation sweep phase error max {max_metrics['translationPhaseErrorMax']:.3f} > 0.020"
            )
        if max_metrics["maxExpectedEmphasisGlyphCount"] > 0:
            if max_metrics["maxAppliedEmphasisGlyphMotionCount"] <= 0:
                failures.append("native emphasis glyph layers exist but no per-glyph motion was measured")
            if max_metrics["maxAppliedEmphasisScale"] <= 1.001:
                failures.append("native emphasis scale never exceeded static text")
            if max_metrics["maxAppliedEmphasisLiftMagnitude"] <= 0.001:
                failures.append("native emphasis lift/float never moved a glyph")
            if max_metrics["maxAppliedEmphasisGlowOpacity"] <= 0.001:
                failures.append("native emphasis glow never activated")
            if max_metrics["maxAppliedEmphasisAlpha"] <= 0.50:
                failures.append("native emphasis highlight alpha never reached bright range")

    if max_metrics["visualParitySampleCount"] <= 0:
        failures.append("no native visual-state parity samples")
    if max_metrics["visualOpacityErrorMax"] > 0.015:
        failures.append(f"visual opacity error max {max_metrics['visualOpacityErrorMax']:.3f} > 0.015")
    if max_metrics["visualScaleErrorMax"] > 0.005:
        failures.append(f"visual scale error max {max_metrics['visualScaleErrorMax']:.3f} > 0.005")
    if max_metrics["visualBlurErrorMax"] > 0.26:
        failures.append(f"visual blur error max {max_metrics['visualBlurErrorMax']:.3f} > 0.260")
    if max_metrics["activeBlurRadiusMax"] > 0.01:
        failures.append(f"active line blur radius max {max_metrics['activeBlurRadiusMax']:.3f} > 0.010")

    if fixture_uses_scroll_tap(fixture_name):
        if max_metrics["manualScrollStartCount"] <= 0:
            failures.append("no native manual scroll start recorded")
        if max_metrics["manualScrollDeltaCount"] <= 0:
            failures.append("no native manual scroll delta recorded")
        if max_metrics["tapToLineCount"] <= 0:
            failures.append("no native tap-to-line recorded")
        if max_metrics["tapDirectSnapCount"] <= 0:
            failures.append("no native tap direct-snap recorded")
        if max_metrics["hoverEnterCount"] <= 0:
            failures.append("no native lyric-row hover enter recorded")
        if max_metrics["hoverBackgroundVisibleCount"] <= 0:
            failures.append("no native manual-scroll hover background recorded")

    return {
        "statePath": str(diagnostics_state_path()),
        "eventCount": len(events),
        "expectedSyllable": fixture_expects_syllable(fixture_name),
        "maxMetrics": max_metrics,
        "failures": failures,
    }


def collect_native_frame_cadence(
    fixture_name: str,
    *,
    started_at: datetime,
) -> dict[str, Any]:
    fixture = visual.FIXTURES[fixture_name]
    expected_title = str(fixture["title"])
    events: list[dict[str, Any]] = []
    max_metrics = {
        "expectedFPS": 0.0,
        "effectiveFPSMin": 0.0,
        "effectiveFPSMax": 0.0,
        "frameDeltaP95MsMax": 0.0,
        "frameDeltaP99MsMax": 0.0,
        "frameDeltaMaxMsMax": 0.0,
        "longestFrameStallMsMax": 0.0,
        "droppedFramesOver1_5xRefreshMax": 0.0,
        "droppedFramesOver2xRefreshMax": 0.0,
        "tickJitterP95MsMax": 0.0,
    }
    effective_values: list[float] = []

    for event in load_diagnostics_events():
        if event.get("name") != "lyrics.presentationFrame.summary":
            continue
        event_ts = parse_event_timestamp(event.get("timestamp"))
        if event_ts is None or event_ts < started_at:
            continue
        track = event.get("track") or {}
        if track.get("title") != expected_title:
            continue
        metrics = event.get("metrics") or {}
        if not isinstance(metrics, dict):
            continue
        events.append(event)
        expected_fps = float(metrics.get("expectedFPS", 0) or 0)
        effective_fps = float(metrics.get("effectiveFPS", 0) or 0)
        if expected_fps > 0:
            max_metrics["expectedFPS"] = max(max_metrics["expectedFPS"], expected_fps)
        if effective_fps > 0:
            effective_values.append(effective_fps)
        for source_key, output_key in [
            ("frameDeltaP95Ms", "frameDeltaP95MsMax"),
            ("frameDeltaP99Ms", "frameDeltaP99MsMax"),
            ("frameDeltaMaxMs", "frameDeltaMaxMsMax"),
            ("longestFrameStallMs", "longestFrameStallMsMax"),
            ("droppedFramesOver1_5xRefresh", "droppedFramesOver1_5xRefreshMax"),
            ("droppedFramesOver2xRefresh", "droppedFramesOver2xRefreshMax"),
            ("tickJitterP95Ms", "tickJitterP95MsMax"),
        ]:
            max_metrics[output_key] = max(max_metrics[output_key], float(metrics.get(source_key, 0) or 0))

    if effective_values:
        max_metrics["effectiveFPSMin"] = min(effective_values)
        max_metrics["effectiveFPSMax"] = max(effective_values)

    failures: list[str] = []
    if not events:
        failures.append("no native presentation frame cadence summaries")
    expected_fps = max_metrics["expectedFPS"]
    expected_interval_ms = 1000.0 / expected_fps if expected_fps > 0 else 0
    if expected_fps > 0 and max_metrics["effectiveFPSMin"] < expected_fps * 0.75:
        failures.append(
            f"effective FPS min {max_metrics['effectiveFPSMin']:.1f} below 75% of display {expected_fps:.1f}"
        )
    if expected_interval_ms > 0 and max_metrics["frameDeltaP95MsMax"] > expected_interval_ms * 1.75:
        failures.append(
            f"frame delta p95 {max_metrics['frameDeltaP95MsMax']:.2f}ms exceeds 1.75x refresh interval"
        )
    if max_metrics["droppedFramesOver2xRefreshMax"] > 2:
        failures.append(
            f"dropped frames over 2x refresh {max_metrics['droppedFramesOver2xRefreshMax']:.0f} > 2"
        )

    return {
        "statePath": str(diagnostics_state_path()),
        "eventCount": len(events),
        "maxMetrics": max_metrics,
        "failures": failures,
    }


def evaluate_cpu_gate(fixture_name: str, perf_result: dict[str, Any], min_reduction: float) -> dict[str, Any]:
    baseline = MAIN_CPU_BASELINES.get(fixture_name)
    measurement = ((perf_result.get("summary") or {}).get("measurement") or {})
    cpu = measurement.get("cpuPercent") or {}
    failures: list[str] = []
    if not baseline:
        return {"baseline": None, "reduction": None, "failures": failures}
    avg = float(cpu.get("avg", 0) or 0)
    p95 = float(cpu.get("p95", 0) or 0)
    reduction = 1 - (avg / float(baseline["avg"])) if baseline["avg"] else 0
    p95_reduction = 1 - (p95 / float(baseline["p95"])) if baseline["p95"] else 0
    if reduction < min_reduction:
        failures.append(
            f"CPU avg reduction {reduction * 100:.1f}% < {min_reduction * 100:.1f}% vs {baseline['label']}"
        )
    if p95_reduction <= 0:
        failures.append("CPU p95 did not improve versus main baseline")
    return {
        "baseline": baseline,
        "candidate": {"avg": avg, "p95": p95},
        "reduction": reduction,
        "p95Reduction": p95_reduction,
        "failures": failures,
    }


def reset_diagnostics_motion_csv() -> None:
    path = diagnostics_motion_path()
    if path.exists():
        path.unlink()


def collect_motion_summary(label: str, output_dir: Path) -> dict[str, Any]:
    csv_path = diagnostics_motion_path()
    metrics = motion.compute_motion_metrics(motion.load_line_motion_csv(csv_path))
    payload = {
        "label": label,
        "csvPath": str(csv_path),
        "metrics": motion.metrics_to_dict(metrics),
    }
    out = output_dir / f"motion-{label}.json"
    motion.save_metrics(out, payload)
    return payload


def load_baseline_metrics(fixture: str) -> motion.MotionMetrics | None:
    path = BASELINE_DIR / f"motion-{fixture}.json"
    if not path.is_file():
        path = BASELINE_DIR / "motion-baseline.json"
    if not path.is_file():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    metrics_data = data.get("metrics", data)
    return motion.MotionMetrics(
        sample_count=int(metrics_data.get("sampleCount", 0)),
        target_error_y_max=float(metrics_data.get("targetErrorY", {}).get("max", 0)),
        target_error_y_p95=float(metrics_data.get("targetErrorY", {}).get("p95", 0)),
        settled_target_error_y_p95=float(metrics_data.get("settledTargetErrorY", {}).get("p95", 0)),
        inter_line_delta_error_y_max=float(metrics_data.get("interLineDeltaErrorY", {}).get("max", 0)),
        inter_line_delta_error_y_p95=float(metrics_data.get("interLineDeltaErrorY", {}).get("p95", 0)),
        settled_inter_line_delta_error_y_p95=float(metrics_data.get("settledInterLineDeltaErrorY", {}).get("p95", 0)),
        active_bottom_clip_max=float(metrics_data.get("activeBottomClipMax", 0)),
        active_target_settle_time_max=float(metrics_data.get("activeTargetSettleTimeMax", 0)),
        active_target_settle_skipped_count=int(metrics_data.get("activeTargetSettleSkippedCount", 0)),
        settled_sample_count=int(metrics_data.get("settledSampleCount", 0)),
        lingering_backlog_incidents=int(metrics_data.get("lingeringBacklogIncidents", 0)),
    )


def record_baseline(output_dir: Path, fixtures: list[str]) -> dict[str, Any]:
    output_dir.mkdir(parents=True, exist_ok=True)
    summaries = []
    for fixture in fixtures:
        summary = collect_motion_summary(fixture, output_dir)
        summaries.append(summary)
    meta = {
        "reference": "v2.8",
        "zipSha256": V28_ZIP_SHA256,
        "fixtures": fixtures,
        "recordedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "motion": summaries,
    }
    (output_dir / "baseline.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    return meta


def compare_against_baseline(candidate: motion.MotionMetrics, fixture: str) -> list[str]:
    baseline = load_baseline_metrics(fixture)
    if baseline is None:
        return [f"no baseline for {fixture}; run --record-baseline first"]
    return motion.compare_metrics(candidate, baseline)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lyrics UX Benchmark orchestrator")
    parser.add_argument("--fixtures", default=",".join(DEFAULT_FIXTURES))
    parser.add_argument("--label", default="candidate")
    parser.add_argument("--output-dir", default=str(OUT_DIR))
    parser.add_argument("--reference-app", type=Path, help="v2.8 nanoPod.app path")
    parser.add_argument("--candidate", type=Path, default=ROOT / "nanoPod.app")
    parser.add_argument("--record-baseline", action="store_true")
    parser.add_argument("--require-beat-reference", action="store_true")
    parser.add_argument(
        "--require-motion-samples",
        action="store_true",
        help="fail when diagnostics line-motion CSV is empty (app must have been running with diagnostics)",
    )
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-unit-tests", action="store_true")
    parser.add_argument("--skip-perf", action="store_true")
    parser.add_argument("--perf-duration", type=float, default=16.0)
    parser.add_argument("--perf-warmup", type=float, default=8.0)
    parser.add_argument("--min-cpu-reduction", type=float, default=0.50)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    fixtures = [name.strip() for name in args.fixtures.split(",") if name.strip()]
    unknown = [name for name in fixtures if name not in visual.FIXTURES]
    if unknown:
        log(f"Unknown fixtures: {unknown}")
        return 2

    output_dir = Path(args.output_dir).expanduser()
    stamp = time.strftime("%Y%m%d-%H%M%S")
    run_dir = output_dir / f"luxb-{stamp}-{args.label}"
    run_dir.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    summary: dict[str, Any] = {
        "label": args.label,
        "fixtures": fixtures,
        "reference": "v2.8",
        "steps": {},
    }

    if args.record_baseline:
        baseline_dir = BASELINE_DIR if args.reference_app is None else run_dir / "baseline"
        log(f"Recording baseline under {baseline_dir}")
        summary["baseline"] = record_baseline(baseline_dir, fixtures)
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        log("Baseline recorded.")
        return 0

    if not args.skip_unit_tests:
        log("Running LyricsScrollEngine / LyricWaveTiming unit tests…")
        unit = swift_unit_tests()
        summary["steps"]["unitTests"] = unit
        if not unit["passed"]:
            failures.append("unit tests failed")

    if not args.skip_build:
        log("Building candidate app…")
        build = build_app()
        summary["steps"]["build"] = build
        if not build["passed"]:
            failures.append("build_app.sh failed")

    if not args.skip_perf:
        perf_steps: dict[str, Any] = {}
        motion_steps: dict[str, Any] = {}
        text_parity_steps: dict[str, Any] = {}
        frame_cadence_steps: dict[str, Any] = {}
        cpu_gate_steps: dict[str, Any] = {}
        for fixture in fixtures:
            log(f"Running perf + motion gate for {fixture}…")
            reset_diagnostics_motion_csv()
            started_at = datetime.now(timezone.utc)
            perf_result = run_perf_fixture(
                fixture,
                app_path=args.candidate,
                duration=args.perf_duration,
                warmup=args.perf_warmup,
                label=args.label,
                output_dir=run_dir,
            )
            perf_steps[fixture] = perf_result
            if not perf_result["passed"]:
                failures.append(f"{fixture}: perf_harness failed")

            csv_path = diagnostics_motion_path()
            metrics = motion.compute_motion_metrics(motion.load_line_motion_csv(csv_path))
            eval_result = motion.evaluate_motion_csv(
                csv_path,
                max_target_error_p95=12.0,
                max_inter_line_error_p95=6.0,
                max_active_bottom_clip=8.0,
                max_lingering_backlog=0,
            )
            motion_failures = list(eval_result.failures)
            if metrics.sample_count == 0:
                motion_failures = ["no line-motion samples for fixture perf run"]
            motion_steps[fixture] = {
                "csvPath": str(csv_path),
                "metrics": motion.metrics_to_dict(metrics),
                "failures": motion_failures,
            }
            failures.extend([f"{fixture}: {failure}" for failure in motion_failures])

            quit_candidate_app()
            text_parity = collect_native_text_parity(fixture, started_at=started_at)
            text_parity_steps[fixture] = text_parity
            failures.extend([f"{fixture}: {failure}" for failure in text_parity["failures"]])

            frame_cadence = collect_native_frame_cadence(fixture, started_at=started_at)
            frame_cadence_steps[fixture] = frame_cadence
            failures.extend([f"{fixture}: {failure}" for failure in frame_cadence["failures"]])

            cpu_gate = evaluate_cpu_gate(fixture, perf_result, args.min_cpu_reduction)
            cpu_gate_steps[fixture] = cpu_gate
            failures.extend([f"{fixture}: {failure}" for failure in cpu_gate["failures"]])

            if args.require_beat_reference:
                compare_failures = compare_against_baseline(metrics, fixture)
                if compare_failures:
                    failures.extend([f"{fixture}: {msg}" for msg in compare_failures])

        summary["steps"]["perf"] = perf_steps
        summary["steps"]["motion"] = motion_steps
        summary["steps"]["textParity"] = text_parity_steps
        summary["steps"]["frameCadence"] = frame_cadence_steps
        summary["steps"]["cpuGate"] = cpu_gate_steps
    else:
        csv_path = diagnostics_motion_path()
        metrics = motion.compute_motion_metrics(motion.load_line_motion_csv(csv_path))
        eval_result = motion.evaluate_motion_csv(
            csv_path,
            max_target_error_p95=12.0,
            max_inter_line_error_p95=6.0,
            max_active_bottom_clip=8.0,
            max_lingering_backlog=0,
        )
        motion_failures = list(eval_result.failures)
        if metrics.sample_count == 0 and not args.require_motion_samples:
            motion_failures = [
                failure for failure in motion_failures
                if not failure.startswith("no line-motion samples")
            ]
            if metrics.sample_count == 0:
                log(f"Note: no line-motion samples at {csv_path} (enable diagnostics + lyrics page, or pass --require-motion-samples)")
        summary["steps"]["motion"] = {
            "csvPath": str(csv_path),
            "metrics": motion.metrics_to_dict(metrics),
            "failures": motion_failures,
        }
        failures.extend(motion_failures)

        if args.require_beat_reference:
            for fixture in fixtures:
                compare_failures = compare_against_baseline(metrics, fixture)
                if compare_failures:
                    failures.extend([f"{fixture}: {msg}" for msg in compare_failures])

    summary["passed"] = not failures
    summary["failures"] = failures
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")

    if failures:
        log("LUXB FAILED:")
        for failure in failures:
            log(f"  - {failure}")
        return 1

    log(f"LUXB passed. Summary: {run_dir / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
