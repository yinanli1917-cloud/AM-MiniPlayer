import AppKit
import QuartzCore

final class NativeLyricsDisplayLinkScheduler {
    private let lock = NSLock()
    private var isTickQueued = false
    private var latestDisplayInterval: TimeInterval?
    private var latestDisplayTimestamp: TimeInterval?

    func enqueue(
        displayInterval: TimeInterval?,
        displayTimestamp: TimeInterval?,
        perform: @escaping (TimeInterval?, TimeInterval?) -> Void
    ) {
        var shouldQueue = false
        lock.lock()
        latestDisplayInterval = displayInterval
        latestDisplayTimestamp = displayTimestamp
        if !isTickQueued {
            isTickQueued = true
            shouldQueue = true
        }
        lock.unlock()

        guard shouldQueue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let payload = self.consumeQueuedTick()
            perform(payload.displayInterval, payload.displayTimestamp)
        }
    }

    func reset() {
        lock.lock()
        isTickQueued = false
        latestDisplayInterval = nil
        latestDisplayTimestamp = nil
        lock.unlock()
    }

    private func consumeQueuedTick() -> (displayInterval: TimeInterval?, displayTimestamp: TimeInterval?) {
        lock.lock()
        let payload: (displayInterval: TimeInterval?, displayTimestamp: TimeInterval?) = (
            latestDisplayInterval,
            latestDisplayTimestamp
        )
        latestDisplayInterval = nil
        latestDisplayTimestamp = nil
        isTickQueued = false
        lock.unlock()
        return payload
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Implicit-animation hygiene
//
// Every layer this renderer creates is INERT: property changes apply instantly, never via
// Core Animation's implicit 0.25s default actions. All intended motion comes from (a)
// per-tick property sets driven by the presentation engine, or (b) explicit CAAnimations
// added by name (the translation loading dots) — explicit adds bypass the action search,
// so they keep working.
//
// WHY layer-level and not call-site CATransaction wraps: these are manual sublayers of
// layer-backed NSViews. AppKit only suppresses implicit actions for a view's OWN backing
// layer. Text/mask/dot sublayer frames are assigned inside NSView.layout(), which AppKit
// runs in its own, un-wrapped transaction — no amount of call-site wrapping covers it.
// Un-blocked, a translation layer whose committed frame is .zero implicitly animates
// position+bounds from the origin when its real frame arrives ("drifts in from top-left"),
// reflows ghost mid-flight, and per-tick wavefront/dot sets each spawn an interrupted
// animation (smear/lag). The delegate is the FIRST stop in CA's action search, so
// returning NSNull() kills every implicit action without enumerating keys.
// Guarded by NativeLyricsImplicitAnimationTests.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsInertLayerDelegate: NSObject, CALayerDelegate {
    static let shared = NativeLyricsInertLayerDelegate()
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
}

extension CALayer {
    /// Marks this renderer-managed layer as inert (no implicit actions) and returns it,
    /// so creation sites read `CATextLayer().lyricsInert()`.
    func lyricsInert() -> Self {
        delegate = NativeLyricsInertLayerDelegate.shared
        return self
    }
}

final class NativeLyricsSweepMaskLineLayer: CALayer {
    private let solidLayer = CALayer().lyricsInert()
    private let fadeLayer = CALayer().lyricsInert()

    // Mask line layers are created in per-tick batches; short-circuit the whole action
    // search at the class level instead of relying on the delegate slot.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        masksToBounds = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        solidLayer.backgroundColor = NSColor.black.cgColor
        solidLayer.contentsScale = contentsScale
        fadeLayer.contents = Self.fadeImage
        fadeLayer.contentsGravity = .resize
        fadeLayer.minificationFilter = .linear
        fadeLayer.magnificationFilter = .linear
        fadeLayer.contentsScale = contentsScale
        addSublayer(solidLayer)
        addSublayer(fadeLayer)
    }

    @discardableResult
    func apply(wavefrontX: CGFloat, fadeHalfPoint: CGFloat, width: CGFloat) -> CGFloat {
        let width = max(1, width)
        let height = max(1, bounds.height)
        let left = wavefrontX - fadeHalfPoint
        let right = wavefrontX + fadeHalfPoint
        if right <= 0 {
            opacity = 0
            solidLayer.frame = .zero
            fadeLayer.frame = .zero
            return 0
        }

        opacity = 1
        if left >= width {
            solidLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            fadeLayer.frame = .zero
            return width
        }

        let clampedLeft = max(0, min(width, left))
        let clampedRight = max(0, min(width, right))
        solidLayer.frame = CGRect(x: 0, y: 0, width: clampedLeft, height: height)
        fadeLayer.frame = CGRect(
            x: clampedLeft,
            y: 0,
            width: max(0, clampedRight - clampedLeft),
            height: height
        )
        return (clampedLeft + clampedRight) / 2
    }

    private static let fadeImage: CGImage = {
        let width = 64
        let height = 1
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGImage.emptyMaskPixel
        }
        let colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else {
            return CGImage.emptyMaskPixel
        }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: width, y: 0),
            options: []
        )
        return context.makeImage() ?? CGImage.emptyMaskPixel
    }()
}

private extension CGImage {
    static let emptyMaskPixel: CGImage = {
        var pixel: UInt32 = 0
        let data = Data(bytes: &pixel, count: MemoryLayout<UInt32>.size)
        let provider = CGDataProvider(data: data as CFData)
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider!,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }()
}

/// Mask-state probe (founder 2026-08-27; UserDefaults switch added 2026-09-14). Records only on
/// transitions so a daily session cannot balloon. Armed by any of:
///   - `NANOPOD_MASK_TRACE=1` environment variable (DEBUG / LOCAL_DEVELOPER_BUILD only — a
///     terminal-launched dev build can set this)
///   - `LOCAL_DEVELOPER_BUILD` compile flag
///   - the `NanoPodMaskTraceEnabled` UserDefaults key (checked in EVERY build configuration,
///     including plain release) — added because launching the app from Finder cannot pass an
///     environment variable, so the founder needs a way to arm this without a terminal:
///     `defaults write <bundle-id> NanoPodMaskTraceEnabled -bool YES`, then relaunch.
/// Default (no env var, not a dev build, UserDefaults key absent/false): zero I/O, the guard
/// returns before any file access — the same production-default guarantee as before, just
/// reachable by one more path. Output path unchanged: /tmp/nanopod_mask_trace.jsonl.
enum NativeLyricsMaskTrace {
    /// Cheap fixed-point formatter used on the hot record-call path instead of
    /// `String(format:)`, whose NSString-backed formatter measurably dominated the
    /// per-call cost once the file-I/O cost above it was removed (2026-09-20, 3q).
    private static func fixedPoint(_ value: Double, decimals: Int) -> String {
        guard value.isFinite else { return "0" }
        let scale = pow(10.0, Double(decimals))
        let scaled = (value * scale).rounded()
        let isNegative = scaled < 0
        let magnitude = Int64(abs(scaled))
        let divisor = Int64(scale)
        let whole = magnitude / divisor
        let fraction = magnitude % divisor
        var fractionString = String(fraction)
        while fractionString.count < decimals {
            fractionString = "0" + fractionString
        }
        return "\(isNegative ? "-" : "")\(whole).\(fractionString)"
    }

    /// UserDefaults key the founder can set from a plist/`defaults write` without a terminal
    /// environment variable. Public so Settings/diagnostics UI could someday expose a toggle.
    static let userDefaultsKey = "NanoPodMaskTraceEnabled"
    /// Public read of the (cached) arming decision for callers that batch their own lines.
    static var isArmedForProbes: Bool { isArmed }

    private static let lock = NSLock()
    private static var lastKey: String = ""

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Batched I/O (2026-09-20, stage bundle 3q)
    //
    // `sample nanoPod 5` across a real line switch showed presentationTick (main thread) spending
    // ~8% of its samples in `NativeLyricsMaskTrace.recordRowPosition` → `NSFileHandle(forWritingTo:)`
    // → `open()` — every single record opened, seeked, wrote, and closed the file SYNCHRONOUSLY on
    // the main thread. Switch-frame events (row_position/mask_state) arrive in a burst, so that
    // burst of opens landed inside the same frame as the geometry work — the "卡一下" the founder
    // reported. Same class of bug as the earlier per-frame-probe lesson (see MEMORY.md
    // lyrics_scroll_cpu_root / lyrics_rerender_churn_diagnosis): a probe must never put I/O on the
    // hot path it is trying to observe.
    //
    // Fix: every `record*` call still runs its (cheap) dedupe-key computation and string
    // formatting on the caller's thread, but instead of touching the filesystem it appends the
    // formatted line to an in-memory buffer and returns. A single background serial queue owns ONE
    // persistent FileHandle for the process lifetime and drains the buffer either when it crosses a
    // byte threshold or after a short coalescing delay — so a burst of switch-frame events becomes
    // ONE open + ONE write instead of N opens. Order is preserved because the buffer is a plain
    // array drained FIFO and the queue is serial.
    private static let ioQueue = DispatchQueue(label: "com.nanopod.masktrace.io", qos: .utility)
    private static var pendingLines: [String] = []
    private static var pendingByteCount = 0
    private static var flushScheduled = false
    private static var fileHandle: FileHandle?
    private static let outputPath = "/tmp/nanopod_mask_trace.jsonl"
    private static let flushByteThreshold = 4096
    private static let flushCoalesceDelay: DispatchTimeInterval = .milliseconds(50)

    /// Main-thread-cheap: format + lock + array append only. Never touches the filesystem.
    private static func enqueue(_ line: String) {
        var shouldFlushNow = false
        var shouldScheduleFlush = false
        lock.lock()
        pendingLines.append(line)
        pendingByteCount += line.utf8.count
        if pendingByteCount >= flushByteThreshold {
            shouldFlushNow = true
        } else if !flushScheduled {
            flushScheduled = true
            shouldScheduleFlush = true
        }
        lock.unlock()

        if shouldFlushNow {
            ioQueue.async { performFlush() }
        } else if shouldScheduleFlush {
            ioQueue.asyncAfter(deadline: .now() + flushCoalesceDelay) { performFlush() }
        }
    }

    /// Runs on `ioQueue` only. Drains the buffer FIFO into one write, reusing the cached
    /// FileHandle (opened once, kept open) — never per-line open/close.
    private static func performFlush() {
        lock.lock()
        flushScheduled = false
        guard !pendingLines.isEmpty else { lock.unlock(); return }
        let lines = pendingLines
        pendingLines.removeAll(keepingCapacity: true)
        pendingByteCount = 0
        lock.unlock()

        guard let data = lines.joined().data(using: .utf8) else { return }
        writeToDisk(data)
    }

    /// Runs on `ioQueue` only. Recreates the handle only if the target path no longer exists
    /// (e.g. a test removed it), so steady-state operation costs one `write()` — no per-call
    /// `open()`/`close()`.
    private static func writeToDisk(_ data: Data) {
        if fileHandle == nil || !FileManager.default.fileExists(atPath: outputPath) {
            try? fileHandle?.close()
            fileHandle = nil
            if !FileManager.default.fileExists(atPath: outputPath) {
                FileManager.default.createFile(atPath: outputPath, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
            _ = try? fileHandle?.seekToEnd()
        }
        guard let handle = fileHandle else { return }
        try? handle.write(contentsOf: data)
    }

    /// Test-only: blocks until every buffered line as of this call has been written to disk.
    static func flushForTesting() {
        ioQueue.sync { performFlush() }
    }

    /// Test-only: drops the cached handle and buffer so a fresh test run (usually after removing
    /// the output file) starts clean, and resets the dedupe keys so the next `record*` call is
    /// always treated as a transition.
    static func resetForTesting() {
        ioQueue.sync {
            lock.lock()
            pendingLines.removeAll()
            pendingByteCount = 0
            flushScheduled = false
            lock.unlock()
            try? fileHandle?.close()
            fileHandle = nil
        }
        lock.lock()
        lastKey = ""
        lastPositionKey = ""
        lastWordFloatDesyncKey = ""
        lock.unlock()
        tickLock.lock()
        tickAggCount = 0
        tickAggDtSum = 0
        tickAggDtMax = 0
        tickAggPhaseSums.removeAll()
        tickLock.unlock()
        resetArmedForTesting()
    }

    // 2026-09-20 (stage bundle 3r): `isArmed` was re-reading `UserDefaults.standard.bool` on
    // EVERY call — recordTick once per frame plus recordRowPosition per row per frame — which
    // is itself a hot-path cost even in the (overwhelmingly common) disarmed case, since
    // `UserDefaults` synchronizes through a lock. Compute the answer once per process and cache
    // it; `resetArmedForTesting()` clears the cache so a test that flips the UserDefaults key
    // between setUp/tearDown observes the new value on its next call.
    private static let armedLock = NSLock()
    private static var cachedArmed: Bool?

    private static var isArmed: Bool {
        armedLock.lock()
        if let cached = cachedArmed {
            armedLock.unlock()
            return cached
        }
        armedLock.unlock()
        let computed = computeArmed()
        armedLock.lock()
        cachedArmed = computed
        armedLock.unlock()
        return computed
    }

    private static func computeArmed() -> Bool {
        if UserDefaults.standard.bool(forKey: userDefaultsKey) { return true }
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        if ProcessInfo.processInfo.environment["NANOPOD_MASK_TRACE"] == "1" { return true }
        #if LOCAL_DEVELOPER_BUILD
        return true
        #else
        return false
        #endif
        #else
        return false
        #endif
    }

    /// Test-only: drops the cached armed decision so the next `isArmed` call re-reads
    /// UserDefaults/environment. `resetForTesting()` calls this too so existing test setUp/
    /// tearDown pairs (which flip the UserDefaults key per test) keep working unchanged.
    static func resetArmedForTesting() {
        armedLock.lock()
        cachedArmed = nil
        armedLock.unlock()
    }

    // 2026-09-18 addition (stage bundle 3g item 2, research/repro-2026-09-18-lyrics-render-3g.md):
    // `wholeLineHighlight` never flipped true across the founder's 710-record session even though
    // he visually saw a whole-line-lit-no-mask frame — it is a probe BLIND SPOT (it only catches
    // the exact "expectsPerRunSweep but appliedPerRunSweep=false while bright is visible" shape at
    // the instant `updatePlaybackPhase` runs, which can already have advanced past a one-frame
    // glitch by the time it's read). `brightUnmaskedIncomplete` is a second, independently-computed
    // field using the SAME predicate `NativeLyricsSeekLandingMaskTests.isMaskLost` exercises
    // (bright overlay visibly opaque + no per-run sweep engaged + expected progress still
    // incomplete) — a real repro attempt for this exact shape found 0 violations across 66+
    // synthetic seek points, so this field exists to catch whatever real-device condition those
    // synthetic seeks don't reproduce, without waiting for another full investigation cycle.
    static func record(
        rowID: String,
        wordIndex: Int,
        wholeLineHighlight: Bool,
        perRunSweep: Bool,
        expected: CGFloat,
        applied: CGFloat,
        mainBrightOverlayPresent: Bool = false,
        mainBrightOpacity: Float = 0,
        brightHiddenWhileSweeping: Bool = false
    ) {
        guard isArmed else { return }
        let brightUnmaskedIncomplete = mainBrightOverlayPresent
            && !perRunSweep
            && expected < 0.9
            && mainBrightOpacity > 0.2
        let key = "\(rowID)|\(wordIndex)|\(wholeLineHighlight)|\(perRunSweep)|\(brightUnmaskedIncomplete)|\(brightHiddenWhileSweeping)"
        lock.lock()
        let changed = key != lastKey
        if changed { lastKey = key }
        lock.unlock()
        guard changed else { return }
        let line = "{\"event\":\"mask_state\",\"row\":\"\(rowID)\",\"word\":\(wordIndex),\"wholeLineHighlight\":\(wholeLineHighlight),\"perRunSweep\":\(perRunSweep),\"expected\":\(fixedPoint(Double(expected), decimals: 3)),\"applied\":\(fixedPoint(Double(applied), decimals: 3)),\"brightUnmaskedIncomplete\":\(brightUnmaskedIncomplete),\"brightOpacity\":\(fixedPoint(Double(mainBrightOpacity), decimals: 3)),\"brightHiddenWhileSweeping\":\(brightHiddenWhileSweeping)}\n"
        enqueue(line)
    }

    /// Row-position probe (founder 2026-09-17, defect C investigation: "刚变为非激活的那一行又
    /// 挪 1-2px" — a row jumping a SECOND time after it already looks settled). Records the
    /// FRAME-carried `y` (never a layer-transform translation — see the "frame not transform"
    /// banned pattern in `applyFrame`, since AppKit resets a layer-backed view's transform
    /// translation on every commit) for the ACTIVE row and, separately, for the row currently
    /// held in deferred-deactivation (the one that just went inactive and is fading out), plus
    /// the row's own `shouldRasterize`/`isSettled` state so a jump can be correlated with the
    /// blur-economy rasterization snapshot (`applyRasterizationPolicy`). Same discipline as
    /// `record` above: shares its `isArmed` gate and output file, and writes ONLY when the
    /// (rowID, role, y, isSettled, shouldRasterize) tuple actually changes — never per frame.
    /// Instrumentation only; does not read or alter any positioning/rasterization decision.
    private static var lastPositionKey: String = ""

    // 2026-09-20 (stage bundle 3r): `recordTick` used to write ONE `tick` event line per
    // presentation tick unconditionally — 209,673 lines across a 200s founder session (120Hz *
    // 200s ≈ 24000 actual ticks measured, but every one of them formatted + enqueued a line
    // regardless of whether anything happened). A line-level (no syllable) song spends the
    // overwhelming majority of its ticks completely idle between line switches: nothing to
    // report. Only two cases are worth a full `tick` line:
    //   - a line switch (`activeBefore != activeAfter`)
    //   - a real hitch (`dtMs` over `tickHitchThresholdMs`)
    // Every OTHER tick still needs to be visible in the trace for cost accounting, so it folds
    // into a cheap running aggregate (count/sum/max dt + per-phase sums) that gets flushed as
    // ONE `tick_summary` line every `tickAggregateFlushEvery` ticks — the analysis scripts that
    // computed "phase totals over 200s" from summed `dt_ms`/`phases` fields can sum the
    // `tick_summary` lines instead of every individual `tick` line. Field names on the `tick`
    // event itself are unchanged so any script that greps for `"event":"tick"` still parses the
    // (now rarer) lines it does see.
    private static let tickHitchThresholdMs = 4.0
    private static let tickAggregateFlushEvery = 600
    private static let tickLock = NSLock()
    private static var tickAggCount = 0
    private static var tickAggDtSum: Double = 0
    private static var tickAggDtMax: Double = 0
    private static var tickAggPhaseSums: [String: Double] = [:]

    /// Frame-cost probe (2026-09-20): records a `tick` line only on a line switch or a real
    /// hitch (>`tickHitchThresholdMs`); every other tick is folded into a running aggregate
    /// flushed as one `tick_summary` line every `tickAggregateFlushEvery` ticks. `dtMs` is the
    /// main-thread time spent inside the tick; `intervalMs` the display link interval.
    static func recordTick(
        dtMs: Double,
        intervalMs: Double,
        activeBefore: Int?,
        activeAfter: Int?,
        mountedRows: Int,
        phases: [String: Double] = [:]
    ) {
        guard isArmed else { return }
        let didSwitch = activeBefore != activeAfter
        let isHitch = dtMs > tickHitchThresholdMs

        if didSwitch || isHitch {
            let wall = Date().timeIntervalSince1970
            let phaseText = phases.map { "\"\($0.key)\":\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: ",")
            let line = String(
                format: "{\"event\":\"tick\",\"wall\":%.3f,\"dt_ms\":%.2f,\"interval_ms\":%.2f,\"activeBefore\":%d,\"activeAfter\":%d,\"mountedRows\":%d,\"phases\":{%@}}\n",
                wall, dtMs, intervalMs, activeBefore ?? -1, activeAfter ?? -1, mountedRows, phaseText
            )
            enqueue(line)
        }

        var summaryLine: String?
        tickLock.lock()
        tickAggCount += 1
        tickAggDtSum += dtMs
        if dtMs > tickAggDtMax { tickAggDtMax = dtMs }
        for (key, value) in phases {
            tickAggPhaseSums[key, default: 0] += value
        }
        if tickAggCount >= tickAggregateFlushEvery {
            let wall = Date().timeIntervalSince1970
            let phaseText = tickAggPhaseSums.map { "\"\($0.key)\":\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: ",")
            summaryLine = String(
                format: "{\"event\":\"tick_summary\",\"wall\":%.3f,\"count\":%d,\"dt_ms_sum\":%.2f,\"dt_ms_max\":%.2f,\"phases\":{%@}}\n",
                wall, tickAggCount, tickAggDtSum, tickAggDtMax, phaseText
            )
            tickAggCount = 0
            tickAggDtSum = 0
            tickAggDtMax = 0
            tickAggPhaseSums.removeAll()
        }
        tickLock.unlock()

        if let summaryLine {
            enqueue(summaryLine)
        }
    }

    /// 2026-09-21 switch-window geometry probe: model values vs CA presentation values per row.
    static func recordRowGeometry(tickSinceSwitch: Int, active: Int, rowIndex: Int,
                                  frameY: CGFloat, frameH: CGFloat, modelA: CGFloat, modelTy: CGFloat,
                                  presY: CGFloat, presA: CGFloat, presTy: CGFloat,
                                  engineY: CGFloat, scale: CGFloat, opacity: CGFloat, blur: CGFloat,
                                  mainY: CGFloat = 0, mainH: CGFloat = 0, presMainY: CGFloat = 0, presMainH: CGFloat = 0,
                                  drawY: CGFloat = 0, drawHidden: Bool = true, mainHidden: Bool = false, rasterized: Bool = false) -> String? {
        guard isArmed else { return nil }
        let line = "{\"event\":\"row_geom\",\"k\":\(tickSinceSwitch),\"active\":\(active),\"row\":\(rowIndex),\"frameY\":\(fixedPoint(Double(frameY), decimals: 2)),\"frameH\":\(fixedPoint(Double(frameH), decimals: 2)),\"a\":\(fixedPoint(Double(modelA), decimals: 4)),\"ty\":\(fixedPoint(Double(modelTy), decimals: 2)),\"presY\":\(fixedPoint(Double(presY), decimals: 2)),\"presA\":\(fixedPoint(Double(presA), decimals: 4)),\"presTy\":\(fixedPoint(Double(presTy), decimals: 2)),\"engineY\":\(fixedPoint(Double(engineY), decimals: 2)),\"scale\":\(fixedPoint(Double(scale), decimals: 4)),\"opacity\":\(fixedPoint(Double(opacity), decimals: 3)),\"blur\":\(fixedPoint(Double(blur), decimals: 2)),\"mainY\":\(fixedPoint(Double(mainY), decimals: 2)),\"mainH\":\(fixedPoint(Double(mainH), decimals: 2)),\"presMainY\":\(fixedPoint(Double(presMainY), decimals: 2)),\"presMainH\":\(fixedPoint(Double(presMainH), decimals: 2)),\"drawY\":\(fixedPoint(Double(drawY), decimals: 2)),\"drawHidden\":\(drawHidden),\"mainHidden\":\(mainHidden),\"raster\":\(rasterized)}\n"
        return line
    }

    static func enqueueLines(_ lines: [String]) {
        guard isArmed else { return }
        for l in lines { enqueue(l) }
    }

    static func recordRowPosition(
        rowID: String,
        role: String,
        y: CGFloat,
        isSettled: Bool,
        shouldRasterize: Bool
    ) {
        guard isArmed else { return }
        let key = "\(rowID)|\(role)|\(fixedPoint(Double(y), decimals: 2))|\(isSettled)|\(shouldRasterize)"
        lock.lock()
        let changed = key != lastPositionKey
        if changed { lastPositionKey = key }
        lock.unlock()
        guard changed else { return }
        let line = "{\"event\":\"row_position\",\"row\":\"\(rowID)\",\"role\":\"\(role)\",\"y\":\(fixedPoint(Double(y), decimals: 2)),\"isSettled\":\(isSettled),\"shouldRasterize\":\(shouldRasterize)}\n"
        enqueue(line)
    }

    // 2026-09-18 (stage bundle 3g item 3): see the call site's doc comment in
    // NativeLyricsRowView.applyMainWordFloatGlyphLayers for the exact desync this catches — a
    // word's DIM tile is treated as "not floating" (per `floatingOrders`/`run.baseFloatY`) while
    // its BRIGHT tile still receives a nonzero `floatY` (per `plan.perWordFloatY`), which would
    // visibly separate the two — the founder's reported "duplicate offset down-right". Not
    // reproduced synthetically as of this commit; this is on-device evidence collection for
    // whenever it next happens, not a confirmed root cause.
    private static var lastWordFloatDesyncKey: String = ""

    static func recordWordFloatDesync(
        rowID: String,
        glyphIndex: Int,
        glyphText: String,
        floatY: CGFloat
    ) {
        guard isArmed else { return }
        let key = "\(rowID)|\(glyphIndex)|\(fixedPoint(Double(floatY), decimals: 2))"
        lock.lock()
        let changed = key != lastWordFloatDesyncKey
        if changed { lastWordFloatDesyncKey = key }
        lock.unlock()
        guard changed else { return }
        let line = "{\"event\":\"word_float_desync\",\"row\":\"\(rowID)\",\"glyphIndex\":\(glyphIndex),\"glyphText\":\"\(glyphText)\",\"floatY\":\(fixedPoint(Double(floatY), decimals: 3))}\n"
        enqueue(line)
    }
}
