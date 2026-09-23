#!/usr/bin/env python3
"""probe_analyze.py — parses probe.sh's [EdgeCollapse] probe log and checks,
per transition label ("collapse" / "expand"), that the tracked glass layer's
bounds changed over >=12 distinct consecutive frame-steps with no single step
larger than 25% of the transition's total delta — top-level task instruction
#7's code-level (no screen) proof of one continuous motion.

Per frame, several glass-class layers may be logged simultaneously (e.g.
`body` + `control` during a floating-adjacent transition); this script
tracks, for each frame, the layer with the LARGEST bounds area as the
transition's primary ("body") shape — body is the largest glass shape in
every state this spike renders (card 250x316, tucked 8x96, floating bar
>=100x32) — then measures continuity on that (width, height) trajectory.
"""
import re
import sys

LINE_RE = re.compile(
    r"\[EdgeCollapse\] probe frame=(?P<frame>\d+) t=(?P<t>\d+) label=(?P<label>\S+) "
    r"layer=(?P<layer>\S+) boundsW=(?P<w>[-\d.eE]+) boundsH=(?P<h>[-\d.eE]+) "
    r"posX=(?P<x>[-\d.eE]+) posY=(?P<y>[-\d.eE]+)"
)

EPSILON = 0.05
MIN_STEPS = 12
MAX_STEP_FRACTION = 0.25


def parse(path):
    by_label_frame = {}
    with open(path) as f:
        for line in f:
            m = LINE_RE.search(line)
            if not m:
                continue
            label = m.group("label")
            frame = int(m.group("frame"))
            w = float(m.group("w"))
            h = float(m.group("h"))
            key = (label, frame)
            area = w * h
            existing = by_label_frame.get(key)
            if existing is None or area > existing[0]:
                by_label_frame[key] = (area, w, h)
    by_label = {}
    for (label, frame), (area, w, h) in by_label_frame.items():
        by_label.setdefault(label, []).append((frame, w, h))
    for label in by_label:
        by_label[label].sort(key=lambda t: t[0])
    return by_label


def analyze(trajectory):
    if len(trajectory) < 2:
        return {
            "verdict": "FAIL",
            "reason": f"only {len(trajectory)} frame(s) recorded",
            "frameCount": len(trajectory),
        }
    first = trajectory[0]
    last = trajectory[-1]
    total_delta = ((last[1] - first[1]) ** 2 + (last[2] - first[2]) ** 2) ** 0.5

    steps = 0
    max_step = 0.0
    for i in range(1, len(trajectory)):
        a = trajectory[i - 1]
        b = trajectory[i]
        d = ((b[1] - a[1]) ** 2 + (b[2] - a[2]) ** 2) ** 0.5
        if d > EPSILON:
            steps += 1
        max_step = max(max_step, d)

    if total_delta <= EPSILON:
        return {
            "verdict": "FAIL",
            "reason": "no net bounds change recorded (total_delta ~= 0)",
            "frameCount": len(trajectory),
            "steps": steps,
            "totalDelta": total_delta,
        }

    max_step_fraction = max_step / total_delta
    ok_steps = steps >= MIN_STEPS
    ok_jump = max_step_fraction <= MAX_STEP_FRACTION
    verdict = "PASS" if (ok_steps and ok_jump) else "FAIL"
    reason = (
        f"steps={steps} (need >={MIN_STEPS}, {'ok' if ok_steps else 'FAIL'}); "
        f"max_single_step={max_step:.2f} = {max_step_fraction * 100:.1f}% of total_delta={total_delta:.2f} "
        f"(need <={MAX_STEP_FRACTION * 100:.0f}%, {'ok' if ok_jump else 'FAIL'})"
    )
    return {
        "verdict": verdict,
        "reason": reason,
        "frameCount": len(trajectory),
        "steps": steps,
        "totalDelta": total_delta,
        "maxStepFraction": max_step_fraction,
    }


def main():
    if len(sys.argv) != 2:
        print("usage: probe_analyze.py <log-file>")
        return 2
    path = sys.argv[1]
    by_label = parse(path)

    if not by_label:
        print("FAIL: no [EdgeCollapse] probe frame= lines found in the log — "
              "either EDGECOLLAPSE_PROBE wasn't set, the notifications never "
              "arrived, or no glass/backdrop-class layer was ever found.")
        return 1

    overall_pass = True
    for label in ("collapse", "expand"):
        trajectory = by_label.get(label, [])
        result = analyze(trajectory)
        print(f"{result['verdict']}: {label} — {result['reason']} (frames={result['frameCount']})")
        if result["verdict"] != "PASS":
            overall_pass = False

    unexpected_labels = sorted(set(by_label.keys()) - {"collapse", "expand"})
    if unexpected_labels:
        print(f"(also saw labels: {unexpected_labels} — not part of the PASS/FAIL gate)")

    print()
    print("PROBE OVERALL: " + ("PASS" if overall_pass else "FAIL"))
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
