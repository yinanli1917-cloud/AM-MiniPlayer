import Foundation

/// Runtime A/B registry for micro-interaction feel channels (buttons, hover
/// capsules, progress-bar hover, window present/dismiss). Modelled exactly on
/// `NativeLyricsFeelParity` — same pattern, different surface.
/// Switch live via `nanopod://debug/feel/<channel>/<arm>`; unknown values fall
/// back to the shipping default so a typo cannot change production look.
///
/// Channels (default arm first — default is the NEW behaviour):
/// - hoverCapsule: `.capsule` (default) vs `.off`
/// - pressScale: `.unified` (default) vs `.legacy`
/// - progressHover: `.tuned` (default) vs `.legacy`
/// - shuffleRepeat: `.critical` (default) vs `.legacy055`
/// - windowPresent: `.fade` (default) vs `.hardcut`
public enum MicroInteractionFeel {
    public static let hoverCapsuleDefaultsKey = "nanoPodFeelHoverCapsule"
    public static let pressScaleDefaultsKey = "nanoPodFeelPressScale"
    public static let progressHoverDefaultsKey = "nanoPodFeelProgressHover"
    public static let shuffleRepeatDefaultsKey = "nanoPodFeelShuffleRepeat"
    public static let windowPresentDefaultsKey = "nanoPodFeelWindowPresent"
    public static let edgeMorphDefaultsKey = "nanoPodFeelEdgeMorph"

    public enum HoverCapsuleMode: String, CaseIterable {
        case capsule = "capsule"
        case off = "off"

        public static func resolve(from raw: String?) -> HoverCapsuleMode {
            guard let raw else { return .capsule }
            return HoverCapsuleMode(rawValue: raw.lowercased()) ?? .capsule
        }
    }

    public enum PressScaleMode: String, CaseIterable {
        case unified = "unified"
        case legacy = "legacy"

        public static func resolve(from raw: String?) -> PressScaleMode {
            guard let raw else { return .unified }
            return PressScaleMode(rawValue: raw.lowercased()) ?? .unified
        }
    }

    public enum ProgressHoverMode: String, CaseIterable {
        case tuned = "tuned"
        case legacy = "legacy"

        public static func resolve(from raw: String?) -> ProgressHoverMode {
            guard let raw else { return .tuned }
            return ProgressHoverMode(rawValue: raw.lowercased()) ?? .tuned
        }
    }

    public enum ShuffleRepeatMode: String, CaseIterable {
        case critical = "critical"
        case legacy055 = "legacy055"

        public static func resolve(from raw: String?) -> ShuffleRepeatMode {
            guard let raw else { return .critical }
            return ShuffleRepeatMode(rawValue: raw.lowercased()) ?? .critical
        }
    }

    public enum WindowPresentMode: String, CaseIterable {
        case fade = "fade"
        case hardcut = "hardcut"

        public static func resolve(from raw: String?) -> WindowPresentMode {
            guard let raw else { return .fade }
            return WindowPresentMode(rawValue: raw.lowercased()) ?? .fade
        }
    }

    /// C1 贴边形变对照臂：`.morph`（默认，card↔pill Liquid Glass morph）vs `.v0`
    /// （今天的行为，字节级不变——`EdgeMorphHost` 整体不渲染）。默认是 `.morph`
    /// 而非其余 channel 惯用的 legacy 默认，因为这是「默认新行为」型 channel，
    /// 与 `NativeLyricsFeelParity` 的默认惯例一致（design doc §7）。
    public enum EdgeMorphMode: String, CaseIterable {
        case morph = "morph"
        case v0 = "v0"

        public static func resolve(from raw: String?) -> EdgeMorphMode {
            guard let raw else { return .morph }
            return EdgeMorphMode(rawValue: raw.lowercased()) ?? .morph
        }
    }

    #if DEBUG
    nonisolated(unsafe) public static var testingHoverCapsule: HoverCapsuleMode?
    nonisolated(unsafe) public static var testingPressScale: PressScaleMode?
    nonisolated(unsafe) public static var testingProgressHover: ProgressHoverMode?
    nonisolated(unsafe) public static var testingShuffleRepeat: ShuffleRepeatMode?
    nonisolated(unsafe) public static var testingWindowPresent: WindowPresentMode?
    nonisolated(unsafe) public static var testingEdgeMorph: EdgeMorphMode?

    public static func resetTestingOverrides() {
        testingHoverCapsule = nil
        testingPressScale = nil
        testingProgressHover = nil
        testingShuffleRepeat = nil
        testingWindowPresent = nil
        testingEdgeMorph = nil
    }
    #endif

    public static var hoverCapsule: HoverCapsuleMode {
        #if DEBUG
        if let testingHoverCapsule { return testingHoverCapsule }
        if isRunningTests { return .capsule }
        #endif
        return HoverCapsuleMode.resolve(
            from: UserDefaults.standard.string(forKey: hoverCapsuleDefaultsKey)
        )
    }

    public static var pressScale: PressScaleMode {
        #if DEBUG
        if let testingPressScale { return testingPressScale }
        if isRunningTests { return .unified }
        #endif
        return PressScaleMode.resolve(
            from: UserDefaults.standard.string(forKey: pressScaleDefaultsKey)
        )
    }

    public static var progressHover: ProgressHoverMode {
        #if DEBUG
        if let testingProgressHover { return testingProgressHover }
        if isRunningTests { return .tuned }
        #endif
        return ProgressHoverMode.resolve(
            from: UserDefaults.standard.string(forKey: progressHoverDefaultsKey)
        )
    }

    public static var shuffleRepeat: ShuffleRepeatMode {
        #if DEBUG
        if let testingShuffleRepeat { return testingShuffleRepeat }
        if isRunningTests { return .critical }
        #endif
        return ShuffleRepeatMode.resolve(
            from: UserDefaults.standard.string(forKey: shuffleRepeatDefaultsKey)
        )
    }

    public static var windowPresent: WindowPresentMode {
        #if DEBUG
        if let testingWindowPresent { return testingWindowPresent }
        if isRunningTests { return .fade }
        #endif
        return WindowPresentMode.resolve(
            from: UserDefaults.standard.string(forKey: windowPresentDefaultsKey)
        )
    }

    public static var edgeMorph: EdgeMorphMode {
        #if DEBUG
        if let testingEdgeMorph { return testingEdgeMorph }
        if isRunningTests { return .morph }
        #endif
        return EdgeMorphMode.resolve(
            from: UserDefaults.standard.string(forKey: edgeMorphDefaultsKey)
        )
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    @discardableResult
    public static func apply(channel: String, value: String) -> Bool {
        let channel = channel.lowercased()
        let value = value.lowercased()
        if channel == "reset" || value == "reset" {
            reset()
            return true
        }
        switch channel {
        case "hovercapsule":
            UserDefaults.standard.set(HoverCapsuleMode.resolve(from: value).rawValue, forKey: hoverCapsuleDefaultsKey)
            return true
        case "pressscale":
            UserDefaults.standard.set(PressScaleMode.resolve(from: value).rawValue, forKey: pressScaleDefaultsKey)
            return true
        case "progresshover":
            UserDefaults.standard.set(ProgressHoverMode.resolve(from: value).rawValue, forKey: progressHoverDefaultsKey)
            return true
        case "shufflerepeat":
            UserDefaults.standard.set(ShuffleRepeatMode.resolve(from: value).rawValue, forKey: shuffleRepeatDefaultsKey)
            return true
        case "windowpresent":
            UserDefaults.standard.set(WindowPresentMode.resolve(from: value).rawValue, forKey: windowPresentDefaultsKey)
            return true
        case "edgemorph":
            UserDefaults.standard.set(EdgeMorphMode.resolve(from: value).rawValue, forKey: edgeMorphDefaultsKey)
            return true
        default:
            return false
        }
    }

    public static func reset() {
        UserDefaults.standard.removeObject(forKey: hoverCapsuleDefaultsKey)
        UserDefaults.standard.removeObject(forKey: pressScaleDefaultsKey)
        UserDefaults.standard.removeObject(forKey: progressHoverDefaultsKey)
        UserDefaults.standard.removeObject(forKey: shuffleRepeatDefaultsKey)
        UserDefaults.standard.removeObject(forKey: windowPresentDefaultsKey)
        UserDefaults.standard.removeObject(forKey: edgeMorphDefaultsKey)
        #if DEBUG
        resetTestingOverrides()
        #endif
    }

    /// Numeric tokens the call sites consume. Do not restate these values
    /// at call sites — read them from here so the A/B tables and the actual
    /// UI never drift apart.
    public enum Tokens {
        public static let hoverCapsuleDuration: TimeInterval = 0.22
        public static let hoverCapsuleOpacity: Double = 0.12

        public static let pressScaleFactor: Double = 0.92
        public static let pressSpringResponse: Double = 0.18
        public static let pressSpringDamping: Double = 1.0

        public static let progressHoverDuration: TimeInterval = 0.16

        public static let shuffleReboundResponse: Double = 0.30
        public static let shuffleReboundDamping: Double = 1.0

        public static let windowFadeInDuration: TimeInterval = 0.18
        public static let windowFadeOutDuration: TimeInterval = 0.14
    }
}

/// Pure decision function for the window present/dismiss animation, factored
/// out of the AppKit call sites so it is testable without a real NSWindow.
/// Reduce Motion always wins, regardless of the configured arm.
public enum WindowPresentPolicy {
    /// Returns `true` when the caller should run the fade animation,
    /// `false` when it should hard-cut (order in/out with no animation).
    public static func resolve(arm: MicroInteractionFeel.WindowPresentMode, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        return arm == .fade
    }
}

/// Pure generation-counter cancellation logic for the fade-out → orderOut
/// completion handler: a show requested after a hide was queued must cancel
/// that pending orderOut so the window never gets hidden after being shown
/// again. Factored out for testability.
public enum WindowPresentGeneration {
    /// Call when starting a new present/dismiss transition; returns the new
    /// generation token to close over in the animation completion handler.
    public static func advance(_ current: inout Int) -> Int {
        current += 1
        return current
    }

    /// In a pending hide's completion handler, only apply the orderOut if no
    /// newer transition (e.g. a show) has started since.
    public static func shouldApply(token: Int, currentGeneration: Int) -> Bool {
        token == currentGeneration
    }
}
