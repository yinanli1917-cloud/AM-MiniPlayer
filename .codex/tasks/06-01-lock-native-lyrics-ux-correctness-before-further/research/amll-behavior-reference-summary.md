# AMLL Behavior Reference Summary

## Query and scope

- Query: Produce an AMLL behavior-reference summary for the active lyrics UX repair task.
- Scope: Exact behavior contracts, with source-line anchors from `tmp/amll-source`, for:
  1. `setCurrentTime(time, isSeek)` vs `update(delta)`
  2. natural playback buffering vs seek snap path
  3. manual scroll ownership / inertia / tap forwarding
  4. line blur / scale / opacity rules
  5. word emphasis sweep / glow / lift / float timing
  6. interlude dot timing and fade
  7. pointer / hover semantics relevant to interactive overlays

## Date

- 2026-06-02

## Files inspected with path references

- `.codex/tasks/06-01-lock-native-lyrics-ux-correctness-before-further/prd.md`
- `.codex/workflow.md`
- `.codex/spec/project/lyrics-renderer-performance.md`
- `.codex/spec/project/lyrics-ux-benchmark.md`
- `tmp/amll-source/packages/react/src/lyric-player.tsx:210-315`
- `tmp/amll-source/packages/vue/src/LyricPlayer.tsx:228-350`
- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:52-125`
- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:185-205`
- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:208-218`
- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:472-519`
- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:521-699`
- `tmp/amll-source/packages/core/src/lyric-player/base/index.ts:749-800`
- `tmp/amll-source/packages/core/src/lyric-player/base/timeline.ts:9-236`
- `tmp/amll-source/packages/core/src/lyric-player/base/layout.ts:14-333`
- `tmp/amll-source/packages/core/src/lyric-player/base/scroll.ts:10-220`
- `tmp/amll-source/packages/core/src/lyric-player/base/group.ts:6-141`
- `tmp/amll-source/packages/core/src/lyric-player/base/line.ts:14-84`
- `tmp/amll-source/packages/core/src/lyric-player/dom/index.ts:15-243`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-group.ts:7-172`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:56-174`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:176-266`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:281-324`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:345-650`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:657-916`
- `tmp/amll-source/packages/core/src/lyric-player/dom/lyric-line.ts:921-1033`
- `tmp/amll-source/packages/core/src/lyric-player/dom/interlude-dots.ts:18-149`
- `tmp/amll-source/packages/core/src/styles/lyric-player.module.css:1-297`

## Findings

### 1. `setCurrentTime(time, isSeek)` vs `update(delta)`

- AMLL keeps timeline commit and presentation advance separate. `setCurrentTime` rounds the input, writes `timelineState.isSeeking` and `timelineState.currentTime`, computes hot/buffered state, applies enable/disable side effects, and may reset scroll or relayout; it does not advance springs frame-by-frame. `update(delta)` is the frame loop that advances the bottom line, interlude dots, row springs, scale springs, and mask alpha interpolation. Source: `base/index.ts:480-519`, `base/index.ts:773-776`, `dom/index.ts:217-230`, `dom/lyric-line.ts:1022-1033`.
- React shell mirrors that split directly. It calls `setLyricLines(...)`, seeds `setCurrentTime(..., true)` on lyrics load, triggers a one-shot `update()`, then runs `requestAnimationFrame` calling `corePlayer.update(time - lastTime)` after `calcLayout()`. Time changes go through `setCurrentTime(currentTime, isSeeking)`, while `setIsSeeking` is also forwarded independently. Source: `react/src/lyric-player.tsx:220-253`, `react/src/lyric-player.tsx:299-315`.
- Vue shell also RAF-drives `update(delta)` and seeds `setCurrentTime(..., true)` when lyrics load, but steady-state `currentTime` updates call `setCurrentTime(props.currentTime)` without passing `props.isSeeking`. Treat the core base classes as the canonical contract, not the Vue wrapper quirk. Source: `vue/src/LyricPlayer.tsx:252-269`, `vue/src/LyricPlayer.tsx:321-346`.
- Before initial layout, non-seek time commits are ignored. AMLL only accepts early `setCurrentTime` before first layout when `isSeek` is true. Source: `base/index.ts:492-493`.

### 2. Natural playback buffering vs seek snap path

- Timeline state distinguishes `hotGroups` from `bufferedGroups`. `hotGroups` are the rows that currently cover `currentTime`; `bufferedGroups` are the rows that should still present as active while the UI wave settles. Source: `timeline.ts:14-25`.
- Natural playback keeps a buffer wave. When new hot rows appear, AMLL adds them to `bufferedGroups`, removes stale buffered rows, and scrolls to the earliest buffered row. This is the wave/follow path, not a direct snap to the latest active row. Source: `timeline.ts:190-202`.
- Seek uses a snap/reset path. When `isSeeking` is true, AMLL replaces `bufferedGroups` with the current hot set, picks `scrollToIndex` from the earliest buffered row or the first future row, disables removed rows, enables current hot rows, requests scroll reset, and forces relayout. Source: `timeline.ts:177-189`, `timeline.ts:109-121`.
- AMLL preserves position when rows simply age out and no new hot row appears. If all buffered rows are leaving and no new hot row was added, it clears non-hot buffered rows but does not change `scrollToIndex`. This is the "hold until the next real trigger" behavior described in the inline comment above `setCurrentTime`. Source: `base/index.ts:481-485`, `timeline.ts:203-213`.
- After the final lyric finishes, AMLL scrolls to the bottom content if it exists, otherwise to the last lyric row. Source: `timeline.ts:215-225`.
- Layout timing also splits seek from natural playback. Seeking or interlude uses fixed Y-spring parameters `{ stiffness: 90, damping: 15 }`; natural playback computes stiffness from the start-time gap between the current and previous rows, clamped to 100-800 ms and mapped into a 170-220 stiffness range with damping `sqrt(stiffness) * 2.2`. Source: `layout.ts:120-183`.
- Natural playback gets per-row wave delay; seek does not. In `calcLayout`, AMLL only accumulates the row delay cascade when `!timelineState.isSeeking`. The initial delay is `0.05` seconds unless `sync`, and rows at/after `scrollToIndex` slightly accelerate the remaining delay (`baseDelay /= 1.05`). Source: `base/index.ts:623-625`, `base/index.ts:679-682`.

### 3. Manual scroll ownership / inertia / tap forwarding

- Scroll ownership is explicit state: `scrollOffset`, `allowScroll`, `isScrolled`, and `isUserScrolling`. It is independent from timeline state. Source: `scroll.ts:10-26`, `base/index.ts:87-93`.
- Beginning a scroll marks the player as manually scrolled for 5 seconds and starts a timeout that clears `isScrolled` and zeroes `scrollOffset`. Source: `base/index.ts:208-218`.
- AMLL documents `resetScroll()` as the required pre-step before relayout after a user tap-to-jump. It clears `isScrolled`, `scrollOffset`, `isUserScrolling`, and the outstanding timer. Source: `base/index.ts:793-800`, `scroll.ts:48-52`.
- Touch drag path:
  - `touchstart` enters `isUserScrolling`, snapshots the starting offset and touch coordinates, zeroes velocity, and forces a synchronous/forced relayout.
  - `touchmove` updates `scrollOffset = startScrollY - deltaY`, clamps it, estimates velocity from movement/time, and relayouts synchronously/forced.
  Source: `scroll.ts:102-140`.
- Tap forwarding path:
  - On `touchend`, a movement smaller than 10 px in both axes is treated as a tap, not a scroll.
  - AMLL resolves `document.elementFromPoint(...)`, checks that the target is still inside the player, forwards the click to that target, clears `isUserScrolling`, and ends the scroll interaction.
  Source: `scroll.ts:143-159`.
- Inertia path:
  - Non-tap `touchend` starts an RAF loop.
  - If `abs(scrollSpeed) > 0.05`, AMLL applies `scrollOffset -= scrollSpeed * dt`, clamps it, decays velocity by `0.95 ** (dt / 16)`, and relayouts synchronously/forced.
  - Inertia stops once the speed drops below threshold, then `isUserScrolling` is cleared.
  Source: `scroll.ts:162-197`.
- Wheel path:
  - Pixel wheel deltas add raw `evt.deltaY` and relayout with `(sync=true, force=false)`.
  - Non-pixel wheel deltas are scaled by `50` and relayout with `(sync=false, force=false)`.
  Source: `scroll.ts:202-220`.
- Row clicks are row-owned, not per-word. The DOM player listens for bubbled `click` and `contextmenu`, resolves the nearest `.lyricLineWrapper`, maps it back to the lyric group, then dispatches `line-click` / `line-contextmenu` with line index, main line, and background line references. Source: `dom/index.ts:77-101`, `dom/index.ts:125-130`.

### 4. Line blur / scale / opacity rules

- A row is treated as active when it is explicitly buffered, or when it lies in the forward active span from `scrollToIndex` up to `latestIndex - 1`. Source: `layout.ts:249-250`.
- Blur rules:
  - Blur is forced to `0` when blur is disabled, while the user is scrolling, or when the row is active.
  - Otherwise AMLL computes a distance-based blur level: `1 + distance`, with passed rows getting an extra `+1`, and compact mode multiplying the result by `0.8`.
  Source: `layout.ts:252-260`, `layout.ts:320-332`.
- Opacity rules:
  - If `hidePassedLines` is enabled and the row is before the active/interlude anchor while playing, opacity becomes `1e-4` instead of exact zero.
  - Buffered rows use `0.85`.
  - Non-buffered non-dynamic rows use `0.2`; dynamic rows use `1`.
  Source: `layout.ts:262-280`.
- Scale/render mode rules come from the group transform stage:
  - Active rows render in `GRADIENT` mode; inactive rows render in `SOLID`.
  - If scale is enabled and playback is running, inactive main rows shrink to `97%`; inactive background rows shrink to `75%`.
  - When playback is paused, inactive rows return to full scale because the scale reduction is gated on `isPlaying`.
  Source: `base/group.ts:86-105`.
- Background vocal visibility is also tied to active/playing state. Inactive background rows slide to `-80` or `+80` percent depending on top/bottom placement, but active rows or paused playback bring them back to `0`. Source: `base/group.ts:66-83`, `dom/lyric-group.ts:143-165`, `styles/lyric-player.module.css:166-205`, `styles/lyric-player.module.css:267-274`.
- DOM/CSS layer rules:
  - Wrapper rows translate on Y, carry wrapper opacity, and apply wrapper blur via `filter`.
  - Wrapper hover adds a row highlight background.
  - Whole-player hover removes blur from `.lyricLine` and `.lyricLineWrapper` with `!important`.
  Source: `dom/lyric-group.ts:126-131`, `styles/lyric-player.module.css:15-27`, `styles/lyric-player.module.css:261-265`.

### 5. Word emphasis sweep / glow / lift / float timing

- Emphasis eligibility is lexical and duration-based:
  - CJK words qualify when duration is at least 1000 ms.
  - Non-CJK words qualify when duration is at least 1000 ms and trimmed length is 2-7 characters.
  Source: `base/line.ts:64-82`.
- AMLL can emphasize an entire merged chunk, not only a single token. If any word in the chunk qualifies, or if the merged non-CJK chunk qualifies, the chunk is built in emphasized mode. Source: `dom/lyric-line.ts:446-466`.
- Base per-word float:
  - Every word gets a float animation with `delay = word.startTime - line.startTime`.
  - Duration is `max(1000, word.endTime - word.startTime)`.
  - Transform is `translateY(0) -> translateY(-0.05em)`; background lyrics double the lift.
  - Easing is `ease-out`, `fill: both`, `composite: add`.
  Source: `dom/lyric-line.ts:510-536`.
- Extra emphasis animation is attached to the last word of an emphasized chunk but drives the chunk's grapheme spans:
  - Amount and glow strength are derived from duration, with cubic/square-root shaping.
  - If the emphasized word is also the line-ending word, AMLL boosts amount by `1.6`, blur by `1.5`, and total duration by `1.2`.
  Source: `dom/lyric-line.ts:540-571`.
- Character-level sweep timing inside emphasis:
  - Each character staggers by `du / 2.5 / anchorCharCount`.
  - The glow/lift animation runs for `du`.
  - The secondary float animation runs for `du * 1.4` and starts `400 ms` earlier (`wordDe - 400`).
  Source: `dom/lyric-line.ts:576-645`.
- Character-level emphasis motion:
  - Glow/lift frames use 32 keyframes.
  - Each frame applies matrix scaling, slight X/Y lift, and white `text-shadow` glow.
  - The secondary float uses `sin(x * PI)` for the lift arc.
  Source: `dom/lyric-line.ts:580-645`.
- Word sweep mask timing:
  - AMLL builds a mask animation per visible word.
  - `totalFadeDuration` is the max of the line end and all word ends minus the line start, so late-ending words keep the sweep alive.
  - Static pauses are inserted for gaps before each word.
  - Ruby lines are stepped per ruby character timing; non-ruby words move in one segment.
  - AMLL intentionally avoids easing on mask frames because easing would corrupt lyric timing accuracy.
  Source: `dom/lyric-line.ts:725-916`.
- Sweep geometry details:
  - `fadeWidth = word.height * wordFadeWidth`.
  - The first segment gets an extra `fadeWidth * 1.5` lead-in.
  - The last segment gets an extra `fadeWidth * 0.5` tail.
  - Mask position is clamped between fully hidden and fully revealed bounds.
  Source: `dom/lyric-line.ts:737-760`, `dom/lyric-line.ts:848-892`.
- Mask alpha is coupled to line scale:
  - Scale in the `0.97 -> 1.00` range maps to bright/dark mask alpha targets.
  - Brightening uses a fast attack speed `50`; dimming uses release speed `7`.
  - Active gradient lines get a brighter front mask than solid lines.
  Source: `dom/lyric-line.ts:921-972`.

### 6. Interlude dot timing and fade

- AMLL only creates an interlude when a lyric gap is long enough:
  - The effective gap end is `nextGroup.startTime - 250`.
  - The gap must be at least `4000 ms`.
  - AMLL checks around the current scroll target (`currentIndex - 1`, `currentIndex`, `currentIndex + 1`).
  - It tests with `currentTime + 20`, so the visible interlude window is slightly biased forward.
  Source: `layout.ts:59-92`.
- Placement contract:
  - Dots are inserted before `anchorLineIndex + 1`.
  - AMLL reserves `fontSize * 0.4` margin above and below the dot row.
  - If the next line is a duet line, the dots right-align to the player width.
  Source: `base/index.ts:573-576`, `base/index.ts:630-650`.
- Runtime timing contract in `InterludeDots`:
  - `setInterlude([start, end])` resets `currentTime` to the interlude start and toggles the enabled class.
  - `update(delta)` only advances while `playing` is true.
  Source: `dom/interlude-dots.ts:44-63`.
- Dot breathing/fade timing:
  - Target breathe cycle is `1500 ms`, but AMLL normalizes the actual breathe duration to evenly tile the real interlude length.
  - For the first `2000 ms`, scale eases in with `easeOutExpo`.
  - Global opacity is hard `0` for the first `500 ms`, then fades in linearly from `500 -> 1000 ms`.
  - In the last `750 ms`, scale eases down via `easeInOutBack`.
  - In the last `375 ms`, global opacity fades out to zero.
  Source: `dom/interlude-dots.ts:73-107`.
- Dot phase timing:
  - Each dot opacity is staggered by one third of the effective dots duration.
  - Each dot keeps a minimum local opacity floor of `0.25` before global opacity is applied.
  Source: `dom/interlude-dots.ts:109-134`.
- End-of-interlude state:
  - Once `currentDuration > interludeDuration`, AMLL forces `scale(0)` and zeroes all three dot opacities.
  Source: `dom/interlude-dots.ts:135-139`.
- CSS wrapper fade:
  - `.interludeDots` starts at `opacity: 0`.
  - `.enabled` makes it `opacity: 1` with a `0.25s` transition.
  Source: `styles/lyric-player.module.css:207-238`.

### 7. Pointer / hover semantics relevant to interactive overlays

- Hover semantics are mostly CSS, not JS:
  - Row wrappers get a translucent hover background.
  - `:active` uses a dimmer background.
  - Whole-player hover removes blur from lyric rows and wrappers.
  Source: `styles/lyric-player.module.css:21-27`, `styles/lyric-player.module.css:261-265`.
- Click semantics are row-scoped:
  - The DOM player resolves the nearest `.lyricLineWrapper`, not individual words.
  - It dispatches custom row events carrying the line index and line objects.
  Source: `dom/index.ts:77-101`.
- Touch taps are forwarded to the underlying DOM target only if the gesture stayed under the 10 px movement threshold and the target still belongs to the player. This is AMLL's touch-to-click bridge during manual scrolling. Source: `scroll.ts:147-158`.
- Hidden background-vocal wrappers cannot steal interaction:
  - Visible background wrappers use `pointer-events: auto`.
  - Hidden wrappers switch to `pointer-events: none`.
  Source: `styles/lyric-player.module.css:166-205`.
- No explicit `pointerenter`, `pointerleave`, `mouseenter`, `mouseleave`, or pointer-capture contract was found in the inspected AMLL files. Interactivity is driven by bubbled `click` / `contextmenu`, CSS hover, and the touch/wheel scroll handlers. Source: `dom/index.ts:125-130`, `scroll.ts:102-220`, `styles/lyric-player.module.css:1-297`.

## Caveats or not-found notes

- The React wrapper is the clearest end-to-end shell reference for `setCurrentTime(..., isSeeking)` plus RAF `update(delta)`. The Vue wrapper does not forward `props.isSeeking` on steady-state `currentTime` updates, so the core base classes should be treated as the canonical contract for the repair task.
- I did not find a separate AMLL pointer-hover controller. Hover behavior is CSS-only in the inspected files.
- I did not inspect non-local AMLL docs or later upstream commits; this note reflects only the checked-in `tmp/amll-source` snapshot in this repository.
