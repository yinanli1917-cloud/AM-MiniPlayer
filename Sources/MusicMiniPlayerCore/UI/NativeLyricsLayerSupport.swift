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
    /// UserDefaults key the founder can set from a plist/`defaults write` without a terminal
    /// environment variable. Public so Settings/diagnostics UI could someday expose a toggle.
    static let userDefaultsKey = "NanoPodMaskTraceEnabled"

    private static let lock = NSLock()
    private static var lastKey: String = ""

    private static var isArmed: Bool {
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
        mainBrightOpacity: Float = 0
    ) {
        guard isArmed else { return }
        let brightUnmaskedIncomplete = mainBrightOverlayPresent
            && !perRunSweep
            && expected < 0.9
            && mainBrightOpacity > 0.2
        let key = "\(rowID)|\(wordIndex)|\(wholeLineHighlight)|\(perRunSweep)|\(brightUnmaskedIncomplete)"
        lock.lock()
        let changed = key != lastKey
        if changed { lastKey = key }
        lock.unlock()
        guard changed else { return }
        let line = String(
            format: "{\"event\":\"mask_state\",\"row\":\"%@\",\"word\":%d,\"wholeLineHighlight\":%@,\"perRunSweep\":%@,\"expected\":%.3f,\"applied\":%.3f,\"brightUnmaskedIncomplete\":%@,\"brightOpacity\":%.3f}\n",
            rowID, wordIndex,
            wholeLineHighlight ? "true" : "false",
            perRunSweep ? "true" : "false",
            Double(expected), Double(applied),
            brightUnmaskedIncomplete ? "true" : "false",
            Double(mainBrightOpacity)
        )
        let url = URL(fileURLWithPath: "/tmp/nanopod_mask_trace.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
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

    static func recordRowPosition(
        rowID: String,
        role: String,
        y: CGFloat,
        isSettled: Bool,
        shouldRasterize: Bool
    ) {
        guard isArmed else { return }
        let key = "\(rowID)|\(role)|\(String(format: "%.2f", y))|\(isSettled)|\(shouldRasterize)"
        lock.lock()
        let changed = key != lastPositionKey
        if changed { lastPositionKey = key }
        lock.unlock()
        guard changed else { return }
        let line = String(
            format: "{\"event\":\"row_position\",\"row\":\"%@\",\"role\":\"%@\",\"y\":%.2f,\"isSettled\":%@,\"shouldRasterize\":%@}\n",
            rowID, role, Double(y),
            isSettled ? "true" : "false",
            shouldRasterize ? "true" : "false"
        )
        let url = URL(fileURLWithPath: "/tmp/nanopod_mask_trace.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
