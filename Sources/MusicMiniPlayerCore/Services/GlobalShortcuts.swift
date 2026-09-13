/**
 * [INPUT]: KeyboardShortcuts 3.0.1 (sindresorhus/KeyboardShortcuts, exact pin) + MusicController
 *          (Services/MusicController+Playback.swift: togglePlayPause/nextTrack/previousTrack)
 *          + PanelCommands (implemented by the app's window owner, see MusicMiniPlayerApp.swift).
 * [OUTPUT]: KeyboardShortcuts.Name registry, GlobalShortcutAction, PanelCommands protocol,
 *           GlobalShortcutRegistrar — Core owns action names + registration; the Settings
 *           recorder UI (WT-C) is out of scope here.
 * [POS]: MusicMiniPlayerCore/Services. No default key combos — users record their own.
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import KeyboardShortcuts

public extension KeyboardShortcuts.Name {
    static let togglePlayPause = Self("nanoPod.togglePlayPause")
    static let nextTrack = Self("nanoPod.nextTrack")
    static let previousTrack = Self("nanoPod.previousTrack")
    static let togglePanel = Self("nanoPod.togglePanel")
    static let hideToEdge = Self("nanoPod.hideToEdge")
}

/// 全局快捷键动作枚举，供设置界面（WT-C）枚举展示 + 注册中心（本文件）分发。
public enum GlobalShortcutAction: String, CaseIterable, Identifiable {
    case togglePlayPause
    case nextTrack
    case previousTrack
    case togglePanel
    case hideToEdge

    public var id: String { rawValue }

    public var name: KeyboardShortcuts.Name {
        switch self {
        case .togglePlayPause: return .togglePlayPause
        case .nextTrack: return .nextTrack
        case .previousTrack: return .previousTrack
        case .togglePanel: return .togglePanel
        case .hideToEdge: return .hideToEdge
        }
    }

    public var localizedTitle: String {
        Self.isSystemChinese ? (Self.titles[self]?.zh ?? rawValue) : (Self.titles[self]?.en ?? rawValue)
    }

    private static var isSystemChinese: Bool {
        (Locale.current.language.languageCode?.identifier ?? "en").hasPrefix("zh")
    }

    private static let titles: [GlobalShortcutAction: (en: String, zh: String)] = [
        .togglePlayPause: ("Play/Pause", "播放/暂停"),
        .nextTrack:       ("Next Track", "下一首"),
        .previousTrack:   ("Previous Track", "上一首"),
        .togglePanel:     ("Show/Hide Panel", "显示/隐藏面板"),
        .hideToEdge:      ("Hide to Edge", "贴边隐藏")
    ]
}

/// 悬浮面板的命令面——App 层（AppMain / 窗口所有者）实现，Core 只依赖协议。
public protocol PanelCommands: AnyObject {
    func togglePanel()
    func hideToEdge()
}

/// 全局快捷键注册中心：把 KeyboardShortcuts 的按键事件分发到 MusicController / PanelCommands。
/// Core 层持有；App 层在 MusicController 与面板都就绪后调用一次 `activate()`。
public final class GlobalShortcutRegistrar {
    private weak var controller: MusicController?
    private weak var panel: PanelCommands?
    private var isActive = false
    private var hasRegisteredHandlers = false

    public init(controller: MusicController, panel: PanelCommands) {
        self.controller = controller
        self.panel = panel
    }

    /// 纯分发座——测试可以不注册真实热键、直接调用返回的闭包验证路由。
    public static func handler(
        for action: GlobalShortcutAction,
        controller: MusicController?,
        panel: PanelCommands?
    ) -> () -> Void {
        switch action {
        case .togglePlayPause:
            return { controller?.togglePlayPause() }
        case .nextTrack:
            return { controller?.nextTrack() }
        case .previousTrack:
            return { controller?.previousTrack() }
        case .togglePanel:
            return { panel?.togglePanel() }
        case .hideToEdge:
            return { panel?.hideToEdge() }
        }
    }

    /// 注册全部五个动作的按键回调（仅首次调用生效，幂等）；随后总是启用快捷键。
    /// 处理器注册与启用分离——`deactivate()` 只需 `disable(_:)`，无需担心重复注册处理器。
    @MainActor
    public func activate() {
        assert(Thread.isMainThread, "GlobalShortcutRegistrar must activate on the main thread")
        if !hasRegisteredHandlers {
            hasRegisteredHandlers = true
            for action in GlobalShortcutAction.allCases {
                KeyboardShortcuts.onKeyDown(
                    for: action.name,
                    action: Self.handler(for: action, controller: controller, panel: panel)
                )
            }
        }
        KeyboardShortcuts.enable(GlobalShortcutAction.allCases.map(\.name))
        isActive = true
    }

    /// 停用全部五个快捷键。KeyboardShortcuts 3.0.1 没有移除单个 onKeyDown 处理器的 API，
    /// 因此用 `disable(_:)` 让快捷键停止触发——处理器闭包仍留在库内部表中，但不会再被调用。
    @MainActor
    public func deactivate() {
        assert(Thread.isMainThread, "GlobalShortcutRegistrar must deactivate on the main thread")
        guard isActive else { return }
        isActive = false
        KeyboardShortcuts.disable(GlobalShortcutAction.allCases.map(\.name))
    }
}
