#!/usr/bin/env python3
"""
LUXB continuous compare loop: build → dual-monitor per fixture → motion/CPU diff vs v2.8.

Exits non-zero when any gate fails. Re-run until green or --max-iterations reached.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURES = ["word-seek-fun", "line-winter-trip", "line-breakup-truth"]


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def run(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=check)


def main() -> int:
    parser = argparse.ArgumentParser(description="Continuous LUXB compare loop")
    parser.add_argument("--fixtures", default=",".join(DEFAULT_FIXTURES))
    parser.add_argument("--duration", type=float, default=55.0)
    parser.add_argument("--warmup", type=float, default=12.0)
    parser.add_argument("--max-iterations", type=int, default=1)
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()

    fixtures = [f.strip() for f in args.fixtures.split(",") if f.strip()]
    failures: list[str] = []
    stamp = time.strftime("%Y%m%d-%H%M%S")
    run_dir = ROOT / "tmp" / "benchmark" / f"luxb-loop-{stamp}"
    run_dir.mkdir(parents=True, exist_ok=True)

    for iteration in range(1, args.max_iterations + 1):
        log(f"=== LUXB iteration {iteration}/{args.max_iterations} ===")
        if not args.skip_build:
            log("Building candidate…")
            build = run(["./build_app.sh"])
            if build.returncode != 0:
                failures.append(f"iter{iteration}: build failed")
                log(build.stderr[-2000:] if build.stderr else "")
                continue

        log("Unit tests (wave engine)…")
        unit = run(
            [
                "swift",
                "test",
                "--filter",
                "LyricsScrollEngineTests|LyricWaveTiming",
            ]
        )
        if unit.returncode != 0:
            failures.append(f"iter{iteration}: unit tests failed")

        iter_summary: dict = {"iteration": iteration, "fixtures": {}}
        for fixture in fixtures:
            log(f"Dual monitor: {fixture}")
            dual = run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "luxb_dual_monitor.py"),
                    "--fixture",
                    fixture,
                    "--duration",
                    str(args.duration),
                    "--warmup",
                    str(args.warmup),
                    "--require-motion-samples",
                ]
            )
            fixture_out = run_dir / f"iter{iteration}-{fixture}-dual.stderr.txt"
            fixture_out.write_text(dual.stderr or "", encoding="utf-8")
            if dual.returncode != 0:
                failures.append(f"iter{iteration}/{fixture}: dual monitor failed")
                log(dual.stderr[-1500:] if dual.stderr else "dual monitor failed")
            if dual.stdout:
                try:
                    payload = json.loads(dual.stdout)
                    iter_summary["fixtures"][fixture] = payload
                except json.JSONDecodeError:
                    failures.append(f"iter{iteration}/{fixture}: invalid dual JSON")

        (run_dir / f"iter{iteration}-summary.json").write_text(
            json.dumps(iter_summary, indent=2) + "\n",
            encoding="utf-8",
        )

    summary = {
        "runDir": str(run_dir),
        "iterations": args.max_iterations,
        "passed": not failures,
        "failures": failures,
    }
    (run_dir / "loop-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )

    if failures:
        log("LUXB LOOP FAILED:")
        for failure in failures:
            log(f"  - {failure}")
        log(f"Artifacts: {run_dir}")
        return 1

    log(f"LUXB loop passed. Artifacts: {run_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
