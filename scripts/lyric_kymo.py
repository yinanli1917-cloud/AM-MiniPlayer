#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
# lyric_kymo.py — objective visual-regression metric for the lyrics renderer.
#
# WHY: the renderer's worst glitches live in the PRESENTATION layer (the on-screen
# per-frame animation), not the model. Headless unit tests are blind to them
# (a model can be correct while the screen flashes). This tool reads a screen
# recording frame-by-frame, builds a kymograph (per-row brightness over time),
# and emits OBJECTIVE numbers — so "did the fix work?" stops being an eyeball call.
#
# It is the acceptance harness for the Stage 2 declarative-snapshot refactor.
# Record the SAME gesture before and after a change; the metrics must move:
#   - flash storm (manual scroll)        : flashes_distinct   163  -> < 5
#   - previous-line double-flicker       : spikes near prev y    2  -> 0
#   - replay/seek settle                 : active-line jumps + settle time shrinks
#
# USAGE (needs an OpenCV venv; see scripts/README or the perceive-animation skill):
#   PYBIN=/tmp/figlaude_cv/bin/python3
#   $PYBIN scripts/lyric_kymo.py --video "/path/to/SYMPTOM-....mp4"
#   $PYBIN scripts/lyric_kymo.py --video VID --json            # machine-readable
#   $PYBIN scripts/lyric_kymo.py --video VID --near-y 70       # spikes near a row
#
# [INPUT]: a screen recording (.mp4/.mov) of the mini player's lyric area.
# [OUTPUT]: flash count, active-line trajectory + jumps, brightness-spike events.
# [POS]: repo-level verification tool for Stage 2; not built into the app.
# ─────────────────────────────────────────────────────────────────────────────
import argparse
import json
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    sys.stderr.write(
        "ERROR: needs opencv + numpy. Run with the OpenCV venv, e.g.\n"
        "  python3 -m venv /tmp/figlaude_cv && /tmp/figlaude_cv/bin/pip install "
        "opencv-python-headless numpy\n"
        "  /tmp/figlaude_cv/bin/python3 scripts/lyric_kymo.py --video VID\n"
    )
    sys.exit(2)


def load_brightness_profile(path, top_frac, bottom_frac, left_frac, right_frac):
    """Return (profile [T, rows], fps, T, r0, r1). profile[t, i] = mean brightness
    of absolute row (r0 + i) over the central column band, for frame t."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        sys.stderr.write(f"ERROR: cannot open video: {path}\n")
        sys.exit(2)
    fps = cap.get(cv2.CAP_PROP_FPS) or 60.0
    frames = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        frames.append(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY))
    cap.release()
    if not frames:
        sys.stderr.write("ERROR: no frames decoded.\n")
        sys.exit(2)
    F = np.array(frames).astype(np.float32)  # (T, H, W)
    T, H, W = F.shape
    r0, r1 = int(H * top_frac), int(H * bottom_frac)
    c0, c1 = int(W * left_frac), int(W * right_frac)
    prof = F[:, r0:r1, c0:c1].mean(axis=2)  # (T, rows)
    return prof, fps, T, r0, r1


def count_flashes(prof, fps, r0, rise_thresh, window_s):
    """A flash = a row whose brightness rises sharply (> rise_thresh in one frame)
    then falls back near baseline within window_s. Returns distinct events."""
    T, rows = prof.shape
    win = max(2, int(window_s * fps))
    events = []
    for ri in range(rows):
        s = prof[:, ri]
        d = np.diff(s)
        for t in range(1, T - win):
            if d[t - 1] > rise_thresh:
                base, peak = s[t - 1], s[t]
                if peak - base <= rise_thresh:
                    continue
                fell = any(s[u] < base + 6 for u in range(t + 1, min(T, t + win)))
                if fell:
                    events.append((t, r0 + ri, float(peak - base)))
    events.sort(key=lambda e: -e[2])
    distinct = []
    for t, y, m in events:
        if all(abs(t - tt) > 3 or abs(y - yy) > 10 for tt, yy, _ in distinct):
            distinct.append((t, y, m))
    return events, distinct


def active_trajectory(prof, jump_thresh):
    """Per-frame brightest-row index (proxy for the active/scroll position) and the
    frames where it jumps by >= jump_thresh rows (discontinuities)."""
    traj = prof.argmax(axis=1).astype(int)
    jumps = [
        (int(i), int(traj[i]), int(traj[i + 1]))
        for i in range(len(traj) - 1)
        if abs(int(traj[i + 1]) - int(traj[i])) >= jump_thresh
    ]
    return traj, jumps


def main():
    ap = argparse.ArgumentParser(description="Objective lyrics-renderer visual-regression metric.")
    ap.add_argument("--video", required=True)
    ap.add_argument("--top-frac", type=float, default=0.10, help="lyric area top (frac of height)")
    ap.add_argument("--bottom-frac", type=float, default=0.74, help="lyric area bottom (excludes progress bar)")
    ap.add_argument("--left-frac", type=float, default=0.10)
    ap.add_argument("--right-frac", type=float, default=0.90)
    ap.add_argument("--rise-thresh", type=float, default=14.0, help="brightness rise that counts as a flash")
    ap.add_argument("--flash-window", type=float, default=0.35, help="max seconds for a flash to fall back")
    ap.add_argument("--jump-thresh", type=int, default=8, help="active-line row jump to flag")
    ap.add_argument("--near-y", type=int, default=None, help="report spike events near this absolute y (±12)")
    ap.add_argument("--json", action="store_true", help="emit JSON metrics only")
    args = ap.parse_args()

    prof, fps, T, r0, r1 = load_brightness_profile(
        args.video, args.top_frac, args.bottom_frac, args.left_frac, args.right_frac
    )
    gb = prof.mean(axis=1)
    events, distinct = count_flashes(prof, fps, r0, args.rise_thresh, args.flash_window)
    traj, jumps = active_trajectory(prof, args.jump_thresh)

    near = []
    if args.near_y is not None:
        for t, y, m in distinct:
            if abs(y - args.near_y) <= 12:
                near.append({"frame": int(t), "t": round(t / fps, 2), "y": int(y), "mag": round(m, 1)})

    metrics = {
        "video": args.video.split("/")[-1],
        "fps": round(fps, 1),
        "frames": T,
        "duration_s": round(T / fps, 2),
        "lyric_rows_abs": [r0, r1],
        "global_brightness": {"min": round(float(gb.min()), 1), "max": round(float(gb.max()), 1)},
        "flashes_total": len(events),
        "flashes_distinct": len(distinct),
        "flashes_per_sec": round(len(distinct) / (T / fps), 1),
        "active_line_jumps": len(jumps),
        "active_line_jump_detail": jumps[:20],
    }
    if args.near_y is not None:
        metrics["near_y"] = args.near_y
        metrics["spikes_near_y"] = near

    if args.json:
        print(json.dumps(metrics, indent=2))
        return

    print(f"VIDEO {metrics['video']}  {T} frames @ {fps:.1f}fps = {metrics['duration_s']}s  "
          f"lyric rows abs[{r0}:{r1}]")
    print(f"  flashes: distinct={len(distinct)}  total={len(events)}  "
          f"per_sec={metrics['flashes_per_sec']}   (target after fix: < 5 distinct on a scroll)")
    print(f"  active-line jumps (>= {args.jump_thresh} rows): {len(jumps)}  {jumps[:8]}")
    if distinct:
        print("  top flash events (frame, t, y_abs, magnitude):")
        for t, y, m in distinct[:8]:
            print(f"    f{t:4d} t={t/fps:4.2f}s y={y:3d} mag={m:.1f}")
    if args.near_y is not None:
        print(f"  spikes near y={args.near_y} (±12): {len(near)}  {near}")


if __name__ == "__main__":
    main()
