import CoreGraphics
import Foundation

/// Runtime A/B for the three leftover v2.8 feel residuals (founder 2026-08-27).
/// Switch live via `nanopod://debug/feel/<channel>/<v28|current|layer>`; unknown
/// values fall back to the shipping default so a typo cannot change production look.
///
/// Channels:
/// - appear: 0.8s force-snap (`current`, default) vs v2.8 natural spring (`v28`)
/// - blur: stepped depth cue (`current`, default, CPU) vs visual-spring (`v28`)
/// - sweep: Canvas-aligned whole-line dim base (`v28`, default after the
///   activation-spacing fix) vs native per-glyph dim tessellation (`layer`)
/// - wave: `LyricWaveTiming.staggerSchedule`'s top-to-bottom order (`topdown`,
///   default) vs outgoing+incoming row starting on the same frame with the
///   wave spreading outward from that pair (`sync`)
public enum NativeLyricsFeelParity {
    public static let appearDefaultsKey = "nanoPodFeelAppearWindow"
    public static let blurDefaultsKey = "nanoPodFeelBlur"
    public static let sweepDefaultsKey = "nanoPodFeelSweep"
    public static let waveDefaultsKey = "nanoPodFeelWave"
    public static let emphasisDefaultsKey = "nanoPodFeelEmphasis"
    public static let appearWindowDuration: TimeInterval = 0.8

    public enum AppearWindowMode: String, CaseIterable {
        case current = "current"
        case v28 = "v28"

        public static func resolve(from raw: String?) -> AppearWindowMode {
            guard let raw else { return .current }
            return AppearWindowMode(rawValue: raw.lowercased()) ?? .current
        }
    }

    public enum BlurMode: String, CaseIterable {
        case current = "current"
        case v28 = "v28"

        public static func resolve(from raw: String?) -> BlurMode {
            guard let raw else { return .current }
            return BlurMode(rawValue: raw.lowercased()) ?? .current
        }
    }

    /// `v28` = SwiftUI Canvas draw model (dim base is one laid-out string).
    /// `layer` = native per-glyph dim tiles (the activation 行距 jump).
    public enum SweepPathMode: String, CaseIterable {
        case v28 = "v28"
        case layer = "layer"

        public static func resolve(from raw: String?) -> SweepPathMode {
            guard let raw else { return .v28 }
            let normalized = raw.lowercased()
            if normalized == "current" { return .v28 }
            return SweepPathMode(rawValue: normalized) ?? .v28
        }
    }

    /// `topdown`: outgoing row starts at 0.16s, incoming row i+1 at 0.24s (shipping default,
    /// `LyricWaveTiming.staggerSchedule`'s original top-to-bottom order).
    /// `sync`: outgoing row i and incoming row i+1 start on the SAME frame at the boundary,
    /// with the wave spreading outward from that pair in both directions.
    public enum WaveMode: String, CaseIterable {
        case topdown = "topdown"
        case sync = "sync"

        public static func resolve(from raw: String?) -> WaveMode {
            guard let raw else { return .topdown }
            return WaveMode(rawValue: raw.lowercased()) ?? .topdown
        }
    }

    /// 2026-09-17 founder-approved contrast arm for the emphasis-word ghost (09-14/09-15/09-17
    /// reports): `current` keeps the historical two-object split — a separate `emphasisGlyphLayers`
    /// pool positioned independently of the ordinary per-word tiles in
    /// `applyMainWordFloatGlyphLayers` (`NativeLyricsRowView.swift`, fork point at the
    /// `!emphasisOrders.contains(run.order)` filter) — which is structurally ghost-prone: two
    /// separately-positioned CALayer objects for the same characters, updated by two independent
    /// formulas, can drift apart by a sub-point amount that reads as a duplicate at 24pt. `v28` and
    /// `amll` both fold emphasis words into the SAME per-glyph tile pipeline every other word uses
    /// (one positioned object per glyph, never two) and apply the scale/lift intensification as an
    /// extra transform on that SAME object — so the position can never drift. They differ only in
    /// how the glow/blur highlight is rendered: `v28` replicates the v2.8 SwiftUI engine's shape
    /// (real `CALayer.shadowOpacity/shadowRadius` on that SAME tile — a shadow cannot desync from
    /// its own layer); `amll` uses a pre-rendered (offline, non-resident) blurred bitmap sibling
    /// layer whose position/transform is copied from the sharp tile at the SAME call site (so it
    /// cannot be independently wrong), avoiding both the CIFilter-mutation trap (banned-patterns.md:
    /// a stored CIFilter's mutated inputRadius is silently ignored by the render server) and a
    /// resident live blur filter's per-frame WindowServer cost.
    public enum EmphasisMode: String, CaseIterable {
        case current = "current"
        case v28 = "v28"
        case amll = "amll"

        // 2026-09-17: founder switched the shipping default to `amll` after independently
        // verifying the arm (this session's B report + the founder's own real-machine check).
        // `current`/`v28` stay fully selectable via the debug URL for A/B comparison.
        public static func resolve(from raw: String?) -> EmphasisMode {
            guard let raw else { return .amll }
            return EmphasisMode(rawValue: raw.lowercased()) ?? .amll
        }
    }

    #if DEBUG
    nonisolated(unsafe) public static var testingAppear: AppearWindowMode?
    nonisolated(unsafe) public static var testingBlur: BlurMode?
    nonisolated(unsafe) public static var testingSweep: SweepPathMode?
    nonisolated(unsafe) public static var testingWave: WaveMode?
    nonisolated(unsafe) public static var testingEmphasis: EmphasisMode?

    public static func resetTestingOverrides() {
        testingAppear = nil
        testingBlur = nil
        testingSweep = nil
        testingWave = nil
        testingEmphasis = nil
    }
    #endif

    public static var appearWindowMode: AppearWindowMode {
        #if DEBUG
        if let testingAppear { return testingAppear }
        if isRunningTests { return .current }
        #endif
        return AppearWindowMode.resolve(
            from: UserDefaults.standard.string(forKey: appearDefaultsKey)
        )
    }

    public static var blurMode: BlurMode {
        #if DEBUG
        if let testingBlur { return testingBlur }
        if isRunningTests { return .current }
        #endif
        return BlurMode.resolve(
            from: UserDefaults.standard.string(forKey: blurDefaultsKey)
        )
    }

    public static var sweepPathMode: SweepPathMode {
        #if DEBUG
        if let testingSweep { return testingSweep }
        if isRunningTests { return .v28 }
        #endif
        return SweepPathMode.resolve(
            from: UserDefaults.standard.string(forKey: sweepDefaultsKey)
        )
    }

    public static var waveMode: WaveMode {
        #if DEBUG
        if let testingWave { return testingWave }
        if isRunningTests { return .topdown }
        #endif
        return WaveMode.resolve(
            from: UserDefaults.standard.string(forKey: waveDefaultsKey)
        )
    }

    public static var emphasisMode: EmphasisMode {
        #if DEBUG
        if let testingEmphasis { return testingEmphasis }
        if isRunningTests { return .amll }
        #endif
        return EmphasisMode.resolve(
            from: UserDefaults.standard.string(forKey: emphasisDefaultsKey)
        )
    }

    /// The `LyricWaveTiming.Shape` this arm resolves to — the single seam
    /// `LyricsPresentationEngine.makeNaturalWavePlan` reads to pick a schedule.
    /// (`LyricWaveTiming.Shape` is module-internal, so this stays internal too.)
    static var waveShape: LyricWaveTiming.Shape {
        waveMode == .sync ? .syncPair : .topDown
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// `now < until` only in the shipping force-snap mode. v2.8 never had this window.
    public static func forceSnapActive(now: CFTimeInterval, until: CFTimeInterval) -> Bool {
        guard appearWindowMode == .current else { return false }
        return now < until
    }

    public static func forceSnapDeadline(now: CFTimeInterval) -> CFTimeInterval {
        switch appearWindowMode {
        case .current:
            return now + appearWindowDuration
        case .v28:
            return 0
        }
    }

    /// Dim base stays a single CATextLayer string (v2.8 Canvas pass 1). The
    /// `layer` arm retessellates dim into per-glyph tiles — that is the
    /// activation 行距/字距 jump.
    public static var keepsWholeLineDimBase: Bool {
        sweepPathMode != .layer
    }

    @discardableResult
    public static func apply(channel: String, value: String) -> Bool {
        let channel = channel.lowercased()
        let value = value.lowercased()
        if channel == "reset" || value == "reset" {
            UserDefaults.standard.removeObject(forKey: appearDefaultsKey)
            UserDefaults.standard.removeObject(forKey: blurDefaultsKey)
            UserDefaults.standard.removeObject(forKey: sweepDefaultsKey)
            UserDefaults.standard.removeObject(forKey: waveDefaultsKey)
            UserDefaults.standard.removeObject(forKey: emphasisDefaultsKey)
            #if DEBUG
            resetTestingOverrides()
            #endif
            return true
        }
        switch channel {
        case "appear":
            UserDefaults.standard.set(AppearWindowMode.resolve(from: value).rawValue, forKey: appearDefaultsKey)
            return true
        case "blur":
            UserDefaults.standard.set(BlurMode.resolve(from: value).rawValue, forKey: blurDefaultsKey)
            return true
        case "sweep":
            UserDefaults.standard.set(SweepPathMode.resolve(from: value).rawValue, forKey: sweepDefaultsKey)
            return true
        case "wave":
            UserDefaults.standard.set(WaveMode.resolve(from: value).rawValue, forKey: waveDefaultsKey)
            return true
        case "emphasis":
            UserDefaults.standard.set(EmphasisMode.resolve(from: value).rawValue, forKey: emphasisDefaultsKey)
            return true
        default:
            return false
        }
    }
}

/// v2.8 `LyricLineView` used `.scaleEffect(scale, anchor: .leading)` — left
/// edge, vertical center of the row. Scaling a flipped CALayer about its
/// origin (top-left) made wrapped CJK lines appear to gain 行距 as scale
/// sprang 0.95 → 1, because the first wrap-line stayed put while later
/// wrap-lines dropped.
enum NativeLyricsRowScale {
    static func leadingTransform(scale: CGFloat, height: CGFloat) -> CGAffineTransform {
        guard abs(scale - 1) > 0.0001, height > 0 else { return .identity }
        let pivotY = height / 2
        return CGAffineTransform(translationX: 0, y: pivotY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: 0, y: -pivotY)
    }
}

/// The singing line stays text-active while paused. `isPlaying` only freezes
/// the playback clock and stops the 60 Hz tick; gating text activity on it
/// snapped karaoke progress to 1 (暂停变全行).
enum NativeLyricsTextActivation {
    static func isLineTextActive(rowIndex: Int, textActiveIndex: Int) -> Bool {
        rowIndex == textActiveIndex
    }
}

/// Integrates the same spring `NativeLyricsVisualMotionState` uses, so the
/// feel-parity tables are sampled from the live formula rather than a
/// restated bezier.
enum NativeLyricsSpringSampler {
    static func sample(
        from value: CGFloat,
        to target: CGFloat,
        times: [TimeInterval],
        spring: LyricsPresentationSpringParameters,
        monotonic: Bool = true
    ) -> [CGFloat] {
        var current = value
        var velocity: CGFloat = 0
        var t: TimeInterval = 0
        var out: [CGFloat] = []
        let step: TimeInterval = 1.0 / 60.0
        for sampleAt in times {
            while t + 1e-12 < sampleAt {
                let dt = min(step, sampleAt - t)
                current = NativeLyricsVisualMotionState.advanceScalarForSampling(
                    value: current,
                    target: target,
                    velocity: &velocity,
                    step: CGFloat(dt),
                    spring: spring,
                    monotonic: monotonic
                )
                t += dt
            }
            out.append(current)
        }
        return out
    }
}
