#!/usr/bin/env python3
"""Evaluate lyrics line-motion CSV and related metrics for LUXB gates."""

from __future__ import annotations

import csv
import json
import math
import statistics
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass
class MotionMetrics:
    sample_count: int = 0
    target_error_y_max: float = 0.0
    target_error_y_p95: float = 0.0
    settled_target_error_y_p95: float = 0.0
    inter_line_delta_error_y_max: float = 0.0
    inter_line_delta_error_y_p95: float = 0.0
    settled_inter_line_delta_error_y_p95: float = 0.0
    active_bottom_clip_max: float = 0.0
    raw_active_bottom_clip_max: float = 0.0
    active_target_settle_time_max: float = 0.0
    active_target_settle_skipped_count: int = 0
    settled_sample_count: int = 0
    lingering_backlog_incidents: int = 0
    late_wave_fire_count: int = 0


@dataclass
class WaveTimelineMetrics:
    sample_count: int = 0
    scheduled_count: int = 0
    fired_count: int = 0
    wave_count: int = 0
    target_radius_min: int = 0
    target_radius_max: int = 0
    lead_in_rows_min: int = 0
    lead_in_rows_max: int = 0
    cadence_p50: float = 0.0
    cadence_p95: float = 0.0
    cadence_max: float = 0.0
    start_latency_max: float = 0.0
    completion_overrun_max: float = 0.0
    late_fire_count: int = 0
    order_violation_count: int = 0


@dataclass
class EvaluationResult:
    passed: bool
    metrics: MotionMetrics
    failures: list[str] = field(default_factory=list)


def _float(value: str | None, default: float = 0.0) -> float:
    if value is None or value == "":
        return default
    try:
        return float(value)
    except ValueError:
        return default


def _int(value: str | None, default: int = 0) -> int:
    if value is None or value == "":
        return default
    try:
        return int(float(value))
    except ValueError:
        return default


def load_line_motion_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return list(reader)


def load_wave_timeline_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return list(reader)


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


def compute_motion_metrics(rows: list[dict[str, str]]) -> MotionMetrics:
    metrics = MotionMetrics()
    if not rows:
        return metrics

    metrics.sample_count = len(rows)
    target_errors = [_float(r.get("targetErrorY")) for r in rows]
    inter_errors = [
        _float(r.get("interLineDeltaErrorY"))
        for r in rows
        if r.get("interLineDeltaErrorY") not in (None, "")
    ]
    metrics.target_error_y_max = max(abs(v) for v in target_errors) if target_errors else 0.0
    metrics.target_error_y_p95 = percentile([abs(v) for v in target_errors], 95)
    if inter_errors:
        metrics.inter_line_delta_error_y_max = max(abs(v) for v in inter_errors)
        metrics.inter_line_delta_error_y_p95 = percentile([abs(v) for v in inter_errors], 95)
    settled_rows, settle_times, skipped_settle_count = settled_motion_rows(rows)
    metrics.settled_sample_count = len(settled_rows)
    metrics.active_target_settle_skipped_count = skipped_settle_count
    raw_active_clips = active_bottom_clip_excess(rows)
    metrics.raw_active_bottom_clip_max = max(raw_active_clips) if raw_active_clips else 0.0
    if settled_rows:
        settled_target_errors = [_float(r.get("targetErrorY")) for r in settled_rows]
        settled_inter_errors = [
            _float(r.get("interLineDeltaErrorY"))
            for r in settled_rows
            if r.get("interLineDeltaErrorY") not in (None, "")
        ]
        metrics.settled_target_error_y_p95 = percentile([abs(v) for v in settled_target_errors], 95)
        if settled_inter_errors:
            metrics.settled_inter_line_delta_error_y_p95 = percentile([abs(v) for v in settled_inter_errors], 95)
        settled_active_clips = active_bottom_clip_excess(settled_rows)
        metrics.active_bottom_clip_max = max(settled_active_clips) if settled_active_clips else 0.0
    else:
        metrics.active_bottom_clip_max = metrics.raw_active_bottom_clip_max
    if settle_times:
        metrics.active_target_settle_time_max = max(settle_times)
    metrics.lingering_backlog_incidents = count_lingering_backlog(rows)
    return metrics


def active_bottom_clip_excess(rows: list[dict[str, str]]) -> list[float]:
    values: list[float] = []
    for row in rows:
        line_index = _int(row.get("lineIndex"))
        active_index = _int(row.get("activeIndex"))
        if line_index != active_index:
            continue
        # During the protected top-to-bottom wave, the active lyric can advance
        # before that row is retargeted. Count that under target lag/settle
        # metrics, not as settled active-row clipping.
        if _int(row.get("targetIndex")) != active_index:
            continue
        visible_span = max(0.0, _float(row.get("visibleBottomY")) - _float(row.get("visibleTopY")))
        unavoidable_overflow = max(0.0, _float(row.get("renderedHeight")) - visible_span)
        values.append(max(0.0, _float(row.get("activeBottomClipY")) - unavoidable_overflow))
    return values


def _timestamp(row: dict[str, str]) -> datetime | None:
    raw = row.get("timestamp") or ""
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def settled_motion_rows(
    rows: list[dict[str, str]],
    *,
    active_error_threshold: float = 12.0,
    nearby_radius: int = 3,
    stable_after_target_change_s: float = 0.45,
    velocity_threshold: float = 30.0,
    max_active_sample_gap_s: float = 0.75,
) -> tuple[list[dict[str, str]], list[float], int]:
    parsed = [(ts, row) for row in rows if (ts := _timestamp(row)) is not None]
    parsed.sort(key=lambda item: item[0])
    if not parsed:
        return [], [], 0

    settled: list[dict[str, str]] = []
    skipped_settle_count = 0
    last_target_by_line: dict[int, int] = {}
    target_changed_at_by_line: dict[int, datetime] = {}
    for ts, row in parsed:
        line_index = _int(row.get("lineIndex"))
        active_index = _int(row.get("activeIndex"))
        target_index = _int(row.get("targetIndex"))
        if last_target_by_line.get(line_index) != target_index:
            last_target_by_line[line_index] = target_index
            target_changed_at_by_line[line_index] = ts
        changed_at = target_changed_at_by_line.get(line_index, ts)
        target_age = (ts - changed_at).total_seconds()
        if abs(line_index - active_index) > nearby_radius:
            continue
        if target_age < stable_after_target_change_s:
            continue
        if abs(_float(row.get("velocityY"))) > velocity_threshold:
            continue
        settled.append(row)

    settle_times: list[float] = []
    segment_start = 0
    while segment_start < len(parsed):
        active_index = _int(parsed[segment_start][1].get("activeIndex"))
        segment_end = segment_start + 1
        while segment_end < len(parsed) and _int(parsed[segment_end][1].get("activeIndex")) == active_index:
            segment_end += 1

        segment = parsed[segment_start:segment_end]
        settle_ts: datetime | None = None
        non_manual_rows = [
            (ts, row) for ts, row in segment
            if _int(row.get("isManualScrolling")) == 0
        ]
        if any(_int(row.get("isManualScrolling")) == 1 for _, row in segment):
            if len(non_manual_rows) < 2:
                skipped_settle_count += 1
                segment_start = segment_end
                continue
            start_ts = non_manual_rows[0][0]
        else:
            start_ts = segment[0][0]
        active_rows = [
            (ts, row) for ts, row in non_manual_rows
            if _int(row.get("lineIndex")) == active_index and _int(row.get("isManualScrolling")) == 0
        ]
        if len(active_rows) < 2:
            skipped_settle_count += 1
            segment_start = segment_end
            continue
        active_sample_gap_too_large = any(
            (current[0] - previous[0]).total_seconds() > max_active_sample_gap_s
            for previous, current in zip(active_rows, active_rows[1:])
        )
        if active_sample_gap_too_large:
            skipped_settle_count += 1
            segment_start = segment_end
            continue

        previous_active: tuple[datetime, dict[str, str]] | None = None
        for ts, row in active_rows:
            error = abs(_float(row.get("targetErrorY")))
            if error <= active_error_threshold:
                settle_ts = ts
                if previous_active is not None:
                    previous_ts, previous_row = previous_active
                    previous_error = abs(_float(previous_row.get("targetErrorY")))
                    if previous_error > active_error_threshold and previous_error != error:
                        segment_duration = (ts - previous_ts).total_seconds()
                        crossing_ratio = (previous_error - active_error_threshold) / (previous_error - error)
                        crossing_ratio = min(max(crossing_ratio, 0.0), 1.0)
                        settle_offset = (previous_ts - start_ts).total_seconds() + segment_duration * crossing_ratio
                        settle_times.append(max(0.0, settle_offset))
                        break
                settle_times.append(max(0.0, (settle_ts - start_ts).total_seconds()))
                break
            previous_active = (ts, row)

        if settle_ts is None and segment:
            if any(_int(row.get("isManualScrolling")) == 1 for _, row in segment):
                skipped_settle_count += 1
            else:
                settle_times.append(max(0.0, (segment[-1][0] - start_ts).total_seconds()))

        segment_start = segment_end

    return settled, settle_times, skipped_settle_count


def count_lingering_backlog(
    rows: list[dict[str, str]],
    *,
    stable_window_s: float = 1.0,
    nearby_radius: int = 3,
    stale_row_threshold: int = 4,
) -> int:
    """Rows still targeting old index long after display index stabilized (spec §204-208)."""
    if len(rows) < 2:
        return 0

    parsed: list[tuple[datetime, int, int, int]] = []
    for row in rows:
        ts_raw = row.get("timestamp") or ""
        try:
            ts = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
        except ValueError:
            continue
        parsed.append(
            (
                ts,
                _int(row.get("displayIndex")),
                _int(row.get("activeIndex")),
                _int(row.get("targetIndex")),
            )
        )

    if len(parsed) < 2:
        return 0

    incidents = 0
    i = 0
    while i < len(parsed):
        start_ts, display_idx, active_idx, _ = parsed[i]
        j = i + 1
        while j < len(parsed):
            ts, d_idx, a_idx, _ = parsed[j]
            if d_idx != display_idx or a_idx != active_idx:
                break
            if (ts - start_ts).total_seconds() >= stable_window_s:
                break
            j += 1

        window_end = j
        if window_end < len(parsed):
            end_ts, _, _, _ = parsed[window_end]
            if (end_ts - start_ts).total_seconds() >= stable_window_s:
                stale = 0
                for k in range(i, min(window_end + 8, len(parsed))):
                    _, d_idx, a_idx, t_idx = parsed[k]
                    if d_idx != display_idx:
                        continue
                    if abs(t_idx - display_idx) > nearby_radius and t_idx != display_idx:
                        if abs(t_idx - display_idx) >= 1:
                            stale += 1
                if stale >= stale_row_threshold:
                    incidents += 1
                i = window_end
                continue
        i += 1

    return incidents


def _is_scheduled_phase(phase: str | None) -> bool:
    return bool(phase) and str(phase).startswith("scheduled")


def _is_fired_phase(phase: str | None) -> bool:
    return bool(phase) and str(phase).startswith("fired")


def compute_wave_timeline_metrics(rows: list[dict[str, str]], tolerance_s: float = 0.05) -> WaveTimelineMetrics:
    metrics = WaveTimelineMetrics(sample_count=len(rows))
    if not rows:
        return metrics

    scheduled = [row for row in rows if _is_scheduled_phase(row.get("phase"))]
    fired = [row for row in rows if _is_fired_phase(row.get("phase"))]
    metrics.scheduled_count = len(scheduled)
    metrics.fired_count = len(fired)
    wave_ids = sorted({_int(row.get("waveID")) for row in rows})
    metrics.wave_count = len(wave_ids)
    radii = [_int(row.get("targetRadius")) for row in scheduled if row.get("targetRadius") not in (None, "")]
    if radii:
        metrics.target_radius_min = min(radii)
        metrics.target_radius_max = max(radii)

    cadences: list[float] = []
    lead_ins: list[int] = []
    start_latencies: list[float] = []
    completion_overruns: list[float] = []
    late_fire_count = 0
    order_violations = 0

    for wave_id in wave_ids:
        wave_scheduled = sorted(
            [row for row in scheduled if _int(row.get("waveID")) == wave_id],
            key=lambda row: (_float(row.get("scheduledDelay")), _int(row.get("lineIndex"))),
        )
        wave_fired = sorted(
            [row for row in fired if _int(row.get("waveID")) == wave_id],
            key=lambda row: (_float(row.get("actualDelay")), _int(row.get("lineIndex"))),
        )
        if wave_scheduled:
            new_index = _int(wave_scheduled[0].get("newIndex"))
            zero_delay_pre_active_rows = [
                _int(row.get("lineIndex"))
                for row in wave_scheduled
                if _int(row.get("lineIndex")) <= new_index
                and abs(_float(row.get("scheduledDelay"))) <= 0.001
            ]
            if zero_delay_pre_active_rows:
                lead_ins.append(max(0, new_index - max(zero_delay_pre_active_rows)))
            delays = sorted({_float(row.get("scheduledDelay")) for row in wave_scheduled})
            cadences.extend(
                delay - previous
                for previous, delay in zip(delays, delays[1:])
                if delay - previous > 0.001
            )
            line_by_delay = [_int(row.get("lineIndex")) for row in wave_scheduled]
            order_violations += sum(
                1 for previous, current in zip(line_by_delay, line_by_delay[1:])
                if current < previous
            )
        if wave_fired:
            start_latencies.append(
                max(0.0, min(_float(row.get("actualDelay")) for row in wave_fired)
                    - min(_float(row.get("scheduledDelay")) for row in wave_fired))
            )
            completion_overruns.append(
                max(0.0, max(_float(row.get("actualDelay")) for row in wave_fired)
                    - max(_float(row.get("scheduledDelay")) for row in wave_fired))
            )
            late_fire_count += sum(
                1 for row in wave_fired
                if _float(row.get("actualDelay")) - _float(row.get("scheduledDelay")) > tolerance_s
            )
            fired_lines = [_int(row.get("lineIndex")) for row in wave_fired]
            order_violations += sum(
                1 for previous, current in zip(fired_lines, fired_lines[1:])
                if current < previous
            )

    if lead_ins:
        metrics.lead_in_rows_min = min(lead_ins)
        metrics.lead_in_rows_max = max(lead_ins)
    if cadences:
        metrics.cadence_p50 = percentile(cadences, 50)
        metrics.cadence_p95 = percentile(cadences, 95)
        metrics.cadence_max = max(cadences)
    metrics.start_latency_max = max(start_latencies) if start_latencies else 0.0
    metrics.completion_overrun_max = max(completion_overruns) if completion_overruns else 0.0
    metrics.late_fire_count = late_fire_count
    metrics.order_violation_count = order_violations
    return metrics


def load_wave_timeline_late_fires(path: Path, tolerance_s: float = 0.05) -> int:
    return compute_wave_timeline_metrics(load_wave_timeline_csv(path), tolerance_s=tolerance_s).late_fire_count


def wave_metrics_to_dict(metrics: WaveTimelineMetrics) -> dict[str, Any]:
    return {
        "sampleCount": metrics.sample_count,
        "scheduledCount": metrics.scheduled_count,
        "firedCount": metrics.fired_count,
        "waveCount": metrics.wave_count,
        "targetRadiusMin": metrics.target_radius_min,
        "targetRadiusMax": metrics.target_radius_max,
        "leadInRowsMin": metrics.lead_in_rows_min,
        "leadInRowsMax": metrics.lead_in_rows_max,
        "cadence": {
            "p50": metrics.cadence_p50,
            "p95": metrics.cadence_p95,
            "max": metrics.cadence_max,
        },
        "startLatencyMax": metrics.start_latency_max,
        "completionOverrunMax": metrics.completion_overrun_max,
        "lateFireCount": metrics.late_fire_count,
        "orderViolationCount": metrics.order_violation_count,
    }


def evaluate_wave_timeline_csv(
    path: Path,
    *,
    expected_cadence_s: float = 0.08,
    cadence_tolerance_s: float = 0.025,
    max_lead_in_rows: int = 3,
    max_late_fire_count: int = 0,
    max_order_violations: int = 0,
) -> EvaluationResult:
    metrics = compute_wave_timeline_metrics(load_wave_timeline_csv(path))
    failures: list[str] = []
    if metrics.sample_count == 0:
        failures.append(f"no wave timeline samples in {path}")
    if metrics.scheduled_count > 0 and metrics.fired_count == 0:
        failures.append("wave timeline has scheduled rows but no fired rows")
    if metrics.target_radius_max and metrics.target_radius_max != 14:
        failures.append(f"wave target radius max {metrics.target_radius_max} != 14")
    if metrics.lead_in_rows_max > max_lead_in_rows:
        failures.append(f"wave lead-in rows max {metrics.lead_in_rows_max} > {max_lead_in_rows}")
    if metrics.cadence_max > 0 and abs(metrics.cadence_max - expected_cadence_s) > cadence_tolerance_s:
        failures.append(
            f"wave cadence max {metrics.cadence_max:.3f}s outside {expected_cadence_s:.3f}s ± {cadence_tolerance_s:.3f}s"
        )
    if metrics.late_fire_count > max_late_fire_count:
        failures.append(f"late wave fires {metrics.late_fire_count} > {max_late_fire_count}")
    if metrics.order_violation_count > max_order_violations:
        failures.append(f"wave order violations {metrics.order_violation_count} > {max_order_violations}")
    return EvaluationResult(passed=not failures, metrics=metrics, failures=failures)



def evaluate_motion_csv(
    path: Path,
    *,
    max_target_error_p95: float | None = None,
    max_inter_line_error_p95: float | None = None,
    max_active_bottom_clip: float | None = None,
    max_active_settle_s: float | None = 0.45,
    max_lingering_backlog: int = 0,
) -> EvaluationResult:
    rows = load_line_motion_csv(path)
    metrics = compute_motion_metrics(rows)
    failures: list[str] = []

    if metrics.sample_count == 0:
        failures.append(f"no line-motion samples in {path}")

    target_error_p95 = metrics.settled_target_error_y_p95 if metrics.settled_sample_count > 0 else metrics.target_error_y_p95
    inter_line_error_p95 = (
        metrics.settled_inter_line_delta_error_y_p95
        if metrics.settled_sample_count > 0
        else metrics.inter_line_delta_error_y_p95
    )

    if max_target_error_p95 is not None and target_error_p95 > max_target_error_p95:
        failures.append(
            f"settled targetErrorY p95 {target_error_p95:.2f} > {max_target_error_p95:.2f}"
        )
    if max_inter_line_error_p95 is not None and inter_line_error_p95 > max_inter_line_error_p95:
        failures.append(
            f"settled interLineDeltaErrorY p95 {inter_line_error_p95:.2f} > {max_inter_line_error_p95:.2f}"
        )
    if max_active_settle_s is not None and metrics.active_target_settle_time_max > max_active_settle_s:
        failures.append(
            f"active target settle max {metrics.active_target_settle_time_max:.3f}s > {max_active_settle_s:.3f}s"
        )
    if max_active_bottom_clip is not None and metrics.active_bottom_clip_max > max_active_bottom_clip:
        failures.append(
            f"activeBottomClipY max {metrics.active_bottom_clip_max:.2f} > {max_active_bottom_clip:.2f}"
        )
    if metrics.lingering_backlog_incidents > max_lingering_backlog:
        failures.append(
            f"lingering backlog incidents {metrics.lingering_backlog_incidents} > {max_lingering_backlog}"
        )

    return EvaluationResult(passed=not failures, metrics=metrics, failures=failures)


def compare_metrics(candidate: MotionMetrics, baseline: MotionMetrics) -> list[str]:
    """Return failure messages when candidate is worse than baseline (beat-v2.8)."""
    failures: list[str] = []
    candidate_target = candidate.settled_target_error_y_p95 or candidate.target_error_y_p95
    baseline_target = baseline.settled_target_error_y_p95 or baseline.target_error_y_p95
    candidate_inter = candidate.settled_inter_line_delta_error_y_p95 or candidate.inter_line_delta_error_y_p95
    baseline_inter = baseline.settled_inter_line_delta_error_y_p95 or baseline.inter_line_delta_error_y_p95
    if candidate_target > baseline_target + 0.25:
        failures.append(
            f"settled targetErrorY p95 {candidate_target:.2f} worse than baseline {baseline_target:.2f}"
        )
    if candidate_inter > baseline_inter + 0.25:
        failures.append(
            "settled interLineDeltaErrorY p95 worse than baseline"
        )
    baseline_has_usable_settle_time = not (
        baseline.active_target_settle_time_max == 0
        and baseline.active_target_settle_skipped_count > 0
    )
    if (
        baseline_has_usable_settle_time
        and candidate.active_target_settle_time_max > baseline.active_target_settle_time_max + 0.05
    ):
        failures.append("active target settle time worse than baseline")
    if candidate.lingering_backlog_incidents > baseline.lingering_backlog_incidents:
        failures.append("lingering backlog worse than baseline")
    if candidate.active_bottom_clip_max > baseline.active_bottom_clip_max + 1.0:
        failures.append("active bottom clip worse than baseline")
    return failures


def metrics_to_dict(metrics: MotionMetrics) -> dict[str, Any]:
    return {
        "sampleCount": metrics.sample_count,
        "targetErrorY": {"max": metrics.target_error_y_max, "p95": metrics.target_error_y_p95},
        "settledTargetErrorY": {"p95": metrics.settled_target_error_y_p95},
        "interLineDeltaErrorY": {
            "max": metrics.inter_line_delta_error_y_max,
            "p95": metrics.inter_line_delta_error_y_p95,
        },
        "settledInterLineDeltaErrorY": {
            "p95": metrics.settled_inter_line_delta_error_y_p95,
        },
        "activeTargetSettleTimeMax": metrics.active_target_settle_time_max,
        "activeTargetSettleSkippedCount": metrics.active_target_settle_skipped_count,
        "settledSampleCount": metrics.settled_sample_count,
        "activeBottomClipMax": metrics.active_bottom_clip_max,
        "rawActiveBottomClipMax": metrics.raw_active_bottom_clip_max,
        "lingeringBacklogIncidents": metrics.lingering_backlog_incidents,
        "lateWaveFireCount": metrics.late_wave_fire_count,
    }


def save_metrics(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def diagnostics_motion_path(bundle_id: str = "com.yinanli.nanoPod") -> Path:
    """Rolling live line-motion CSV under Application Support/{bundle_id}/."""
    application_support = Path.home() / "Library" / "Application Support"
    if bundle_id == "com.yinanli.nanoPod":
        app_names = ["nanoPod", bundle_id]
    else:
        app_names = [bundle_id, "nanoPod"]
    candidates = [
        application_support / app_name / "Diagnostics" / "Live" / "lyrics_line_motion_samples.csv"
        for app_name in app_names
    ]
    existing = [path for path in candidates if path.exists()]
    if existing:
        return max(existing, key=lambda path: path.stat().st_mtime)
    return candidates[0]
