/**
 * [INPUT]: 无外部依赖（Foundation + CoreServices AEDeterminePermissionToAutomateTarget）
 * [OUTPUT]: 导出 OnboardingState、OnboardingAuthorizationStatus
 * [POS]: C6 引导页的纯状态层——UserDefaults 读写 + 授权状态查询，不含 UI
 */

import Foundation
import CoreServices
import MusicKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - OnboardingAuthorizationStatus
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

public enum OnboardingAuthorizationStatus: Equatable {
    case authorized
    case denied
    case notDetermined
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - OnboardingState
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
public final class OnboardingState: ObservableObject {
    public static let shared = OnboardingState()

    public static let completedKey = "nanoPodOnboardingCompleted"
    /// 引导页内容 schema 版本——以后内容大改时把这个数值加一，老用户会再看到一次。
    public static let schemaKey = "nanoPodOnboardingSchema"
    public static let currentSchema = 1
    private static let launchCountKey = "nanoPodLaunchCount"

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    /// `nanopod://debug/onboarding/show` 置位；仅调试构建生效。
    public static var debugForceShow = false
    #endif

    @Published public var isPresented = false

    private init() {}

    // MARK: 完成状态（UserDefaults 往返）

    public var hasCompletedOnboarding: Bool {
        UserDefaults.standard.bool(forKey: Self.completedKey)
            && UserDefaults.standard.integer(forKey: Self.schemaKey) >= Self.currentSchema
    }

    public func markCompleted() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.set(Self.currentSchema, forKey: Self.schemaKey)
    }

    /// 供 `nanopod://debug/onboarding/reset` 与测试使用。
    public func reset() {
        UserDefaults.standard.removeObject(forKey: Self.completedKey)
        UserDefaults.standard.removeObject(forKey: Self.schemaKey)
    }

    // MARK: 纯判定函数（无副作用，测试直接调用）

    /// - Parameters:
    ///   - hasCompleted: 当前 schema 下是否已完成过引导
    ///   - launchCount: 本次是第几次启动（从 1 开始）
    ///   - forced: 调试强制展示（`nanopod://debug/onboarding/show`）
    public static func shouldPresent(hasCompleted: Bool, launchCount: Int, forced: Bool) -> Bool {
        if forced { return true }
        guard launchCount <= 1 else { return false }
        return !hasCompleted
    }

    /// 启动次数计数——每次调用自增并返回自增后的值。
    @discardableResult
    public func incrementLaunchCount() -> Int {
        let next = UserDefaults.standard.integer(forKey: Self.launchCountKey) + 1
        UserDefaults.standard.set(next, forKey: Self.launchCountKey)
        return next
    }

    public func presentIfNeeded(launchCount: Int) {
        var forced = false
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        forced = Self.debugForceShow
        #endif
        if Self.shouldPresent(hasCompleted: hasCompletedOnboarding, launchCount: launchCount, forced: forced) {
            isPresented = true
        }
    }

    // MARK: 调试 URL 路由（由 App 层 handleAppURL 的 debug 分支调用）

    /// `path` 取 `nanopod://debug/onboarding/<show|reset>` 的最后一段（已小写、已去斜杠）。
    /// 返回 true 表示已处理。
    #if DEBUG || LOCAL_DEVELOPER_BUILD
    public func handleDebugAction(_ path: String) -> Bool {
        switch path {
        case "show":
            Self.debugForceShow = true
            isPresented = true
            return true
        case "reset":
            reset()
            Self.debugForceShow = false
            isPresented = false
            return true
        default:
            return false
        }
    }
    #endif

    // MARK: 授权状态查询（只读，永不触发系统弹窗）

    /// MusicKit 当前授权状态——与 `MusicController.musicKitAuthorized` 同一数据源
    /// (`MusicAuthorization.currentStatus`)，只读查询本身不弹窗。
    public var musicKitStatus: OnboardingAuthorizationStatus {
        switch MusicAuthorization.currentStatus {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Music.app 自动化（AppleScript/ScriptingBridge）授权状态。
    /// `askUserIfNeeded: false` 保证这次查询绝不弹系统对话框——
    /// 只有按钮点击时才允许真正触发（走既有的 `AppleScriptRunner.fetchPlayerState`）。
    public var automationStatus: OnboardingAuthorizationStatus {
        Self.queryAutomationStatus(askUserIfNeeded: false)
    }

    static func queryAutomationStatus(askUserIfNeeded: Bool) -> OnboardingAuthorizationStatus {
        var target = AEAddressDesc()
        let bundleID = "com.apple.Music"
        let status = bundleID.withCString { cString -> OSErr in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                cString,
                bundleID.utf8.count,
                &target
            )
        }
        guard status == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(kAECoreSuite),
            AEEventID(kAEGetData),
            askUserIfNeeded
        )

        switch result {
        case OSStatus(noErr):
            return .authorized
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(errAEEventNotPermitted), OSStatus(procNotFound):
            return .denied
        default:
            return .notDetermined
        }
    }

    /// 按钮点击触发：如未决定，会弹出系统 Automation 授权对话框（走既有 osascript 路径，
    /// 不新增 AppleScript）；随后重新查询状态。
    public func requestAutomationAccess() {
        _ = AppleScriptRunner.fetchPlayerState(timeout: 1.0)
    }
}
