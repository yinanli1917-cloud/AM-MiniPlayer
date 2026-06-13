#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import lyrics_motion_evaluator as m


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, default=None)
    parser.add_argument("--track-title", default=None)
    parser.add_argument("--timestamp-prefix", action="append", default=[])
    args = parser.parse_args()
    if args.csv:
        path = args.csv
    else:
        path = m.diagnostics_motion_path()
        if not path.exists():
            alt = Path.home() / "Library/Application Support/nanoPod/Diagnostics/Live/lyrics_line_motion_samples.csv"
            if alt.exists():
                path = alt
    rows = m.load_line_motion_csv(path)
    print(f"loaded {len(rows)} rows from {path}")
    if rows:
        print(f"  last: {rows[-1].get('timestamp')} {rows[-1].get('trackTitle')!r}")
    legacy_prefixes = ("2026-05-29T23:17", "2026-05-29T23:18", "2026-05-29T23:19")
    prefixes = tuple(args.timestamp_prefix) or legacy_prefixes
    session = [r for r in rows if (r.get("timestamp") or "").startswith(prefixes)]
    if not session:
        track_title = args.track_title or (rows[-1].get("trackTitle") if rows else None)
        if track_title:
            session = [r for r in rows if r.get("trackTitle") == track_title]
    print(f"session rows: {len(session)}")
    metrics = m.compute_motion_metrics(session)
    print("metrics:", m.metrics_to_dict(metrics))

    bad = sorted(
        session,
        key=lambda row: abs(float(row.get("targetErrorY") or 0)),
        reverse=True,
    )[:5]
    for row in bad:
        print(
            "  err",
            row.get("playbackTime"),
            "line",
            row.get("lineIndex"),
            "display",
            row.get("displayIndex"),
            "target",
            row.get("targetIndex"),
            "targetErrorY",
            row.get("targetErrorY"),
            "waveOffsetY",
            row.get("waveOffsetY"),
        )

    ahead = 0
    for row in session:
        line_index = int(float(row.get("lineIndex", -1)))
        display_index = int(float(row.get("displayIndex", -2)))
        target_index = int(float(row.get("targetIndex", -2)))
        if line_index == display_index and target_index != display_index:
            ahead += 1
    print(f"active highlight ahead of target: {ahead}")

    aligned = sum(
        1
        for row in session
        if int(float(row.get("targetIndex", 0))) == int(float(row.get("displayIndex", 0)))
    )
    print(f"aligned samples: {aligned}/{len(session)}")

    failures: list[str] = []
    if metrics.target_error_y_p95 > 18:
        failures.append(f"targetErrorY p95 {metrics.target_error_y_p95:.1f} > 18")
    if metrics.inter_line_delta_error_y_p95 > 18:
        failures.append(
            f"interLineDeltaErrorY p95 {metrics.inter_line_delta_error_y_p95:.1f} > 18"
        )
    if metrics.lingering_backlog_incidents > 2:
        failures.append(f"lingering backlog {metrics.lingering_backlog_incidents} > 2")
    print("SESSION GATE:", failures or "PASS")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
