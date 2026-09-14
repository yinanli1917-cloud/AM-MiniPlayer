import Foundation
import SwiftUI

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
    public static let settingsTabDefaultsKey = "nanoPodFeelSettingsTab"
    public static let settingsToggleDefaultsKey = "nanoPodFeelSettingsToggle"
    public static let pageSwitchDefaultsKey = "nanoPodFeelPageSwitch"

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

    /// C4 设置页 Tab 切换转场：`.custom`（默认，crossfade + slide）vs `.system`
    /// （今天的原样 `TabView(selection:)`，不改）。
    public enum SettingsTabMode: String, CaseIterable {
        case custom = "custom"
        case system = "system"

        public static func resolve(from raw: String?) -> SettingsTabMode {
            guard let raw else { return .custom }
            return SettingsTabMode(rawValue: raw.lowercased()) ?? .custom
        }
    }

    /// C4 设置页 Toggle/Picker 反馈：`.custom`（默认，标签轻微 scale pulse）vs
    /// `.system`（不加任何反馈，控件原样）。
    public enum SettingsToggleMode: String, CaseIterable {
        case custom = "custom"
        case system = "system"

        public static func resolve(from raw: String?) -> SettingsToggleMode {
            guard let raw else { return .custom }
            return SettingsToggleMode(rawValue: raw.lowercased()) ?? .custom
        }
    }

    /// C2 三页切换三时钟：`.split`（默认，geometry/content/material 分拆）vs
    /// `.single`（今天的行为——单一 `.spring(response:0.25, dampingFraction:0.9)`
    /// 字节级不变）。
    public enum PageSwitchMode: String, CaseIterable {
        case split = "split"
        case single = "single"

        public static func resolve(from raw: String?) -> PageSwitchMode {
            guard let raw else { return .split }
            return PageSwitchMode(rawValue: raw.lowercased()) ?? .split
        }
    }

    #if DEBUG
    nonisolated(unsafe) public static var testingHoverCapsule: HoverCapsuleMode?
    nonisolated(unsafe) public static var testingPressScale: PressScaleMode?
    nonisolated(unsafe) public static var testingProgressHover: ProgressHoverMode?
    nonisolated(unsafe) public static var testingShuffleRepeat: ShuffleRepeatMode?
    nonisolated(unsafe) public static var testingWindowPresent: WindowPresentMode?
    nonisolated(unsafe) public static var testingEdgeMorph: EdgeMorphMode?
    nonisolated(unsafe) public static var testingSettingsTab: SettingsTabMode?
    nonisolated(unsafe) public static var testingSettingsToggle: SettingsToggleMode?
    nonisolated(unsafe) public static var testingPageSwitch: PageSwitchMode?

    public static func resetTestingOverrides() {
        testingHoverCapsule = nil
        testingPressScale = nil
        testingProgressHover = nil
        testingShuffleRepeat = nil
        testingWindowPresent = nil
        testingEdgeMorph = nil
        testingSettingsTab = nil
        testingSettingsToggle = nil
        testingPageSwitch = nil
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

    public static var settingsTab: SettingsTabMode {
        #if DEBUG
        if let testingSettingsTab { return testingSettingsTab }
        if isRunningTests { return .custom }
        #endif
        return SettingsTabMode.resolve(
            from: UserDefaults.standard.string(forKey: settingsTabDefaultsKey)
        )
    }

    public static var settingsToggle: SettingsToggleMode {
        #if DEBUG
        if let testingSettingsToggle { return testingSettingsToggle }
        if isRunningTests { return .custom }
        #endif
        return SettingsToggleMode.resolve(
            from: UserDefaults.standard.string(forKey: settingsToggleDefaultsKey)
        )
    }

    public static var pageSwitch: PageSwitchMode {
        #if DEBUG
        if let testingPageSwitch { return testingPageSwitch }
        if isRunningTests { return .split }
        #endif
        return PageSwitchMode.resolve(
            from: UserDefaults.standard.string(forKey: pageSwitchDefaultsKey)
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
        case "settingstab":
            UserDefaults.standard.set(SettingsTabMode.resolve(from: value).rawValue, forKey: settingsTabDefaultsKey)
            return true
        case "settingstoggle":
            UserDefaults.standard.set(SettingsToggleMode.resolve(from: value).rawValue, forKey: settingsToggleDefaultsKey)
            return true
        case "pageswitch":
            UserDefaults.standard.set(PageSwitchMode.resolve(from: value).rawValue, forKey: pageSwitchDefaultsKey)
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
        UserDefaults.standard.removeObject(forKey: settingsTabDefaultsKey)
        UserDefaults.standard.removeObject(forKey: settingsToggleDefaultsKey)
        UserDefaults.standard.removeObject(forKey: pageSwitchDefaultsKey)
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

        // C1 edgeMorph three-clock scheduler (research/c1-edge-morph-design-2026-09-12.md §4/§9 commit 3).
        public static let edgeMorphPreSeedLead: TimeInterval = 0.02
        public static let edgeMorphContentLagMin: TimeInterval = 0.02
        public static let edgeMorphContentLagMax: TimeInterval = 0.08
        public static let edgeMorphMaterialSettle: TimeInterval = 0.31
        public static let edgeMorphContentDuration: TimeInterval = 0.14

        // C4 settings page (design doc §10).
        public static let settingsTabDuration: TimeInterval = 0.22
        public static let settingsTabReducedMotionDuration: TimeInterval = 0.12
        public static let settingsToggleBumpScale: Double = 1.03
        public static let settingsToggleBumpResponse: Double = 0.18

        // C2 page-switch three-clock scheduler (mirrors edgeMorph's pattern).
        // geometry: matchedGeometryEffect hero move + page offset.
        // content: incoming page's textual/control opacity (lags geometry slightly).
        // material: PanelBackdrop/page-overlay material crossfade — where the page
        // itself carries no independent material surface, this clock drives the
        // whole-page opacity crossfade that plays that role instead.
        public static let pageGeometryDuration: TimeInterval = 0.14
        public static let pageContentLag: TimeInterval = 0.04
        public static let pageContentDuration: TimeInterval = 0.16
        public static let pageMaterialDuration: TimeInterval = 0.31
    }
}

/// C4 设置页 Tab 切换转场的纯决策函数，从 `SettingsWindowView` 拆出以便无 UI 测试。
/// `.system` 臂 = 今天的行为，恒返回 `.none` + `nil` animation（TabView 原样，不接管转场）。
/// `.custom` 臂按 `from`/`to` 的 tab 索引推导滑动方向；Reduce Motion 恒赢，只剩 opacity。
public enum SettingsTabTransitionKind: Equatable {
    case none
    case opacity
    case slideForward
    case slideBackward
}

public enum SettingsTabTransition {
    public static func resolve(
        arm: MicroInteractionFeel.SettingsTabMode,
        from: Int,
        to: Int,
        reduceMotion: Bool
    ) -> (kind: SettingsTabTransitionKind, animation: Animation?) {
        guard arm == .custom else { return (.none, nil) }

        if reduceMotion {
            return (.opacity, .linear(duration: MicroInteractionFeel.Tokens.settingsTabReducedMotionDuration))
        }

        let animation = Animation.smooth(duration: MicroInteractionFeel.Tokens.settingsTabDuration)
        guard to != from else { return (.opacity, animation) }
        return (to > from ? .slideForward : .slideBackward, animation)
    }
}

/// C4 设置页 Toggle/Picker 反馈脉冲的纯策略函数：`.custom` 臂在非 Reduce Motion 时脉冲，
/// 否则（`.system` 臂，或 Reduce Motion）不脉冲。
public enum SettingsTogglePulsePolicy {
    public static func shouldPulse(arm: MicroInteractionFeel.SettingsToggleMode, reduceMotion: Bool) -> Bool {
        arm == .custom && !reduceMotion
    }
}

/// One ViewModifier reused on every Toggle/Picker row: on `value` change, the row's
/// label does a brief scale pulse (1.0→bump→1.0). The control itself (Toggle/Picker)
/// is never touched — only the label wrapping this modifier animates.
public struct SettingsFeedbackPulseModifier<Value: Equatable>: ViewModifier {
    let value: Value

    @State private var scale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(value: Value) {
        self.value = value
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onChange(of: value) { _, _ in
                guard SettingsTogglePulsePolicy.shouldPulse(arm: MicroInteractionFeel.settingsToggle, reduceMotion: reduceMotion) else { return }
                let response = MicroInteractionFeel.Tokens.settingsToggleBumpResponse
                withAnimation(.spring(response: response, dampingFraction: 1.0)) {
                    scale = MicroInteractionFeel.Tokens.settingsToggleBumpScale
                }
                withAnimation(.spring(response: response, dampingFraction: 1.0).delay(response)) {
                    scale = 1.0
                }
            }
    }
}

public extension View {
    /// Applies the settings-row label feedback pulse (see `SettingsFeedbackPulseModifier`).
    func settingsFeedbackPulse<V: Equatable>(value: V) -> some View {
        modifier(SettingsFeedbackPulseModifier(value: value))
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
