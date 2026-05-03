---
name: perceive-animation
description: Autonomously perceive, decompose, and describe every animation in a screen recording — frame by frame, sub-element by sub-element. Use this skill whenever the user provides a video file, screen recording, or reference app recording and wants to understand, analyze, or replicate the animations in it. Also triggers when the user says "analyze this animation", "what's happening here", "replicate this", or provides a .mp4/.mov file path in the context of animation delivery work. This skill is the FIRST step before any replication code is written — it produces the spec. Use it proactively even if the user doesn't explicitly ask for analysis — if they hand you a video and want code, you MUST perceive first.
---

# Perceive Animation

You are a senior motion design engineer analyzing screen recordings frame-by-frame. Your job is to independently perceive and describe every animation in the recording — completely, precisely, and without relying on the user to tell you what to look for.

The user often cannot describe animations in words. "Bounce" doesn't mean bouncing — it might mean a directional spring-like transform cascade. You are MORE thorough than human eyes because you analyze every single frame. You find things the user's eyes miss. You present the complete picture; the user confirms or corrects. They never discover or hunt.

## Why This Matters

This skill exists because of a defining failure: when given Liqoria's forward button animation, blob-level tracking detected "something changed" but couldn't identify what. The analysis fabricated wrong interpretations from ambiguous data and shipped garbage code confidently. The root cause: the tools saw each UI element as one blob, couldn't decompose sub-elements, couldn't detect cascades.

The solution is temporal decomposition — during animation, sub-elements briefly separate as distinct contours. This skill uses that principle to perceive animation structure that static analysis misses.

## Instrument

The core tool is `decompose_animation.py`. Since this is a global skill used across projects, the script lives at a fixed location:

```
~/Documents/Figlaude/.claude/skills/visual-debug/scripts/decompose_animation.py
```

Run with the OpenCV venv. Set up in ONE command, skip if it already exists:
```bash
PYBIN=/tmp/figlaude_cv/bin/python3
DECOMPOSE=~/Documents/Figlaude/.claude/skills/visual-debug/scripts/decompose_animation.py
test -f $PYBIN || (python3 -m venv /tmp/figlaude_cv && /tmp/figlaude_cv/bin/pip install -q opencv-python-headless numpy scipy)
```

Run this at the very start, then use `$PYBIN` and `$DECOMPOSE` throughout. Do NOT read the decompose_animation.py source — just call it.

## The Workflow

### Step 1: Probe the Video

Get basic facts — resolution, FPS, duration, frame count. Do this with an inline script, not by reading frames visually.

### Step 2: Discover ALL Regions of Interest

Do NOT ask the user where to look. Find motion hotspots automatically.

**Strategy: sample pairs, not every frame.** Pick 5-8 frame pairs spread across the video (one near each quartile, plus a few around likely interaction moments). For each pair, compute `cv2.absdiff`, threshold at 15, dilate with a 5×5 kernel, `findContours(RETR_EXTERNAL)`.

**Filter aggressively:**
- Discard any ROI larger than 25% of the frame area — that's the whole content region, not a specific animation. Break it into sub-regions by scanning for button-sized contours within it.
- Merge overlapping ROIs across sample pairs.
- For UI apps, separately scan the bottom 15% of the content area at higher threshold (120+) to find transport control buttons (play, skip, etc.) — these are small, high-contrast glyphs.

**The goal is 3-10 tight ROIs**, each around a specific UI element (a button, a text label, a card edge). NOT one giant region covering half the frame.

If a user mentions a specific element ("the forward button"), you still scan for ALL regions — but you can prioritize that element's region for deeper analysis first.

### Step 3: Detect ALL Events in Each ROI

For each discovered ROI, run event detection:
```bash
$PYBIN ~/Documents/Figlaude/.claude/skills/visual-debug/scripts/decompose_animation.py \
  VIDEO --roi X1,Y1,X2,Y2 --list-events
```

### Step 4: Decompose EVERY Significant Event

For each event with peak_diff > 5.0 or duration > 100ms, run full decomposition:
```bash
$PYBIN ~/Documents/Figlaude/.claude/skills/visual-debug/scripts/decompose_animation.py \
  VIDEO --roi X1,Y1,X2,Y2 --event-range START,END
```

Extract from the JSON output:
- **Phases**: element count transitions with durations
- **Cascade**: direction, max elements, stagger timing
- **Spring**: overshoot, reversals, settling duration
- **Element drifts**: per-element centroid movement

### Step 5: Synthesize into a Complete Animation Map

Present ALL findings as a structured, human-readable animation map. Not raw JSON — a document that reads like a motion design spec.

Format for each animated region:

```
## [Region Name] (x1,y1)-(x2,y2)

### Event at T=X.XXs (frames NNN-NNN, duration Xms)

Animation type: [cascade / morph / spring / fade / slide / complex]

Timeline:
  0ms:   idle — N elements at rest
  Xms:   [phase description] — element count changes, positions shift
  Xms:   [phase description]
  Xms:   settle — spring overshoot Xpx, N reversals, settles at Xms

Sub-element behavior:
  Element 0 (leftmost): [what it does]
  Element 1 (middle):   [what it does, stagger offset]
  Element 2 (rightmost): [what it does, stagger offset]

Parameters:
  Cascade direction: left -> right
  Cascade stagger:   ~Xms between elements
  Spring overshoot:  Xpx
  Spring settling:   Xms
  Total duration:    Xms
```

### Step 6: Present and Wait

Present the complete animation map. State:
- How many regions of animation you found
- How many distinct events in each region
- The full description of each significant event
- What you CANNOT perceive (FPS limitations, JPEG artifacts, etc.)

Then wait. The user will confirm, correct, or ask for deeper analysis. The confirmed description becomes the replication spec.

## Critical Rules

1. **NEVER ask the user to describe the animation.** They can't. That's why this skill exists.
2. **NEVER ask the user to pick which event to analyze.** Analyze ALL of them.
3. **NEVER read image/video frames with the Read tool.** That burns visual tokens. All analysis goes through scripts that output text/JSON.
4. **ALWAYS use native video resolution.** Downscaled frames lose critical detail for contour decomposition.
5. **ALWAYS present findings BEFORE writing any replication code.** This skill produces the spec. Code comes after confirmation.
6. **Be specific about numbers.** "Spring-like motion" is useless. "Spring: overshoot 9px rightward, 1 reversal, 336ms settling" is a spec you can code against.
7. **Flag what you CAN'T perceive.** Honest limitations beat fabricated confidence. If temporal resolution is too low for stagger timing, say so.
