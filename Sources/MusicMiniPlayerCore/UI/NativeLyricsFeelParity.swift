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
public enum NativeLyricsFeelParity {
    public static let appearDefaultsKey = "nanoPodFeelAppearWindow"
    public static let blurDefaultsKey = "nanoPodFeelBlur"
    public static let sweepDefaultsKey = "nanoPodFeelSweep"
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

    #if DEBUG
    nonisolated(unsafe) public static var testingAppear: AppearWindowMode?
    nonisolated(unsafe) public static var testingBlur: BlurMode?
    nonisolated(unsafe) public static var testingSweep: SweepPathMode?

    public static func resetTestingOverrides() {
        testingAppear = nil
        testingBlur = nil
        testingSweep = nil
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
