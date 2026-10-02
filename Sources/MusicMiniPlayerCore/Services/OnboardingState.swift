/**
 * [INPUT]: 无外部依赖（Foundation + CoreServices AEDeterminePermissionToAutomateTarget）
 * [OUTPUT]: 导出 OnboardingState、OnboardingAuthorizationStatus
 * [POS]: Automation/MusicKit 授权状态查询——原 C6 引导页的完成度/schema 记录
 *        （nanoPodOnboardingCompleted/Schema、shouldPresent、isPresented、调试
 *        show/reset 路由）已随 C6 三页向导一起移除，由新引导的
 *        MusicMiniPlayerCore/Onboarding/TourPersistence.swift 取代
 *        （docs/design/2026-09-25-onboarding/proposal.md v3.3）；本文件只保留
 *        两条授权查询，新引导的「和 Music 打招呼」步骤仍在用
 *        automationStatus/requestAutomationAccess。
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

    /// App launch counter — unrelated to onboarding completion; carried over
    /// as-is (§5.3's persistence table: "沿用"). The new tour's own launch
    /// gating (`TourPersistence.shouldPresent`) reads this value too.
    private static let launchCountKey = "nanoPodLaunchCount"

    private init() {}

    /// 启动次数计数——每次调用自增并返回自增后的值。
    @discardableResult
    public func incrementLaunchCount() -> Int {
        let next = UserDefaults.standard.integer(forKey: Self.launchCountKey) + 1
        UserDefaults.standard.set(next, forKey: Self.launchCountKey)
        return next
    }

    // MARK: 授权状态查询（只读，永不触发系统弹窗）

    /// MusicKit 当前授权状态——与 `MusicController.musicKitAuthorized` 同一数据源
    /// (`MusicAuthorization.currentStatus`)，只读查询本身不弹窗。
    public var musicKitStatus: OnboardingAuthorizationStatus { Self.queryMusicKitStatus() }

    /// The same read as `musicKitStatus`, callable from any thread (a synchronous system query, ~10 ms:
    /// UI code that must not block the main thread calls this from a background queue).
    public nonisolated static func queryMusicKitStatus() -> OnboardingAuthorizationStatus {
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

    /// Callable from any thread (a synchronous TCC query, ~10 ms; never prompts).
    public nonisolated static func queryAutomationStatus() -> OnboardingAuthorizationStatus {
        queryAutomationStatus(askUserIfNeeded: false)
    }

    nonisolated static func queryAutomationStatus(askUserIfNeeded: Bool) -> OnboardingAuthorizationStatus {
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
