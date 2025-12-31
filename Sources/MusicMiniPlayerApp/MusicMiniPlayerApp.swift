import AppKit
import SwiftUI
import MusicMiniPlayerCore
import Translation

/// macOS 菜单栏迷你播放器应用
/// 支持：菜单栏迷你视图 + 浮动窗口模式切换
@main
class AppMain: NSObject, NSApplicationDelegate {
    static var shared: AppMain!

    var statusItem: NSStatusItem!
    var floatingWindow: NSPanel?
    var menuBarPopover: NSPopover?
    let musicController = MusicController.shared
    private var windowDelegate: FloatingWindowDelegate?

    // 自动隐藏计时器（可取消）
    private var autoHideWorkItem: DispatchWorkItem?

    // 状态：是否显示为浮窗（true）还是菜单栏视图（false）
    @Published var isFloatingMode: Bool = true

    // 设置：是否在 Dock 显示图标
    var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set {
            UserDefaults.standard.set(newValue, forKey: "showInDock")
            updateDockVisibility()
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = AppMain()
        AppMain.shared = delegate
        app.delegate = delegate

        // 默认显示 Dock 图标
        if !UserDefaults.standard.bool(forKey: "showInDockInitialized") {
            UserDefaults.standard.set(true, forKey: "showInDock")
            UserDefaults.standard.set(true, forKey: "showInDockInitialized")
        }

        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugPrint("[AppMain] Application launched\n")

        // 更新 Dock 可见性
        updateDockVisibility()

        // 创建菜单栏项
        setupStatusItem()

        // 创建浮动窗口
        createFloatingWindow()

        // 创建菜单栏 Popover
        createMenuBarPopover()

        // 默认显示浮窗
        showFloatingWindow()

        debugPrint("[AppMain] Setup complete\n")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Dock Visibility

    func updateDockVisibility() {
        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Status Item (菜单栏)

    func setupStatusItem() {
        // 使用可变宽度以适应迷你播放器视图
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        guard let button = statusItem.button else {
            debugPrint("[AppMain] ERROR: Failed to get status item button\n")
            return
        }

        // 默认显示音符图标
        updateStatusItemIcon()

        // 点击事件
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp])  // 只响应左键

        debugPrint("[AppMain] Status item created\n")
    }

    func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }

        if let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "nanoPod") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = "♪"
        }
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        // 左键点击：显示/隐藏设置 popover
        toggleMenuBarPopover()
    }

    // MARK: - Mode Toggle

    @objc func toggleMode() {
        isFloatingMode.toggle()

        if isFloatingMode {
            // 切换到浮窗模式
            menuBarPopover?.close()
            showFloatingWindow()
        } else {
            // 切换到菜单栏模式
            floatingWindow?.orderOut(nil)
            showMenuBarPopover()
        }
    }


    // MARK: - Floating Window (浮动窗口)

    func createFloatingWindow() {
        let windowSize = NSSize(width: 250, height: 316)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowRect = NSRect(
            x: screenFrame.maxX - windowSize.width - 20,
            y: screenFrame.maxY - windowSize.height - 20,
            width: windowSize.width,
            height: windowSize.height
        )

        let snappableWindow = SnappablePanel(
            contentRect: windowRect,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        floatingWindow = snappableWindow

        snappableWindow.isFloatingPanel = true
        snappableWindow.level = .floating
        snappableWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        snappableWindow.backgroundColor = .clear
        snappableWindow.isOpaque = false
        snappableWindow.hasShadow = true
        snappableWindow.isMovableByWindowBackground = false  // 🔑 禁用系统拖拽，由 SnappablePanel 接管
        snappableWindow.titlebarAppearsTransparent = true
        snappableWindow.titleVisibility = .hidden
        snappableWindow.hidesOnDeactivate = false
        snappableWindow.acceptsMouseMovedEvents = true
        snappableWindow.becomesKeyOnlyIfNeeded = true

        // 设置窗口比例和尺寸限制
        snappableWindow.aspectRatio = NSSize(width: 250, height: 316)
        snappableWindow.minSize = NSSize(width: 180, height: 228)
        snappableWindow.maxSize = NSSize(width: 400, height: 506)

        // 🔑 设置当前页面provider，用于判断双指拖拽是否生效
        snappableWindow.currentPageProvider = { [weak self] in
            return self?.musicController.currentPage ?? .album
        }

        // 🔑 设置手动滚动状态provider（用于两次滑动逻辑）
        snappableWindow.isManualScrollingProvider = {
            return LyricsService.shared.isManualScrolling
        }

        // 🔑 触发进入手动滚动状态
        snappableWindow.onTriggerManualScroll = {
            LyricsService.shared.isManualScrolling = true
        }

        windowDelegate = FloatingWindowDelegate()
        snappableWindow.delegate = windowDelegate

        snappableWindow.standardWindowButton(.closeButton)?.isHidden = true
        snappableWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        snappableWindow.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = MiniPlayerContentView(onHide: { [weak self] in
            self?.collapseToMenuBar()
        })
        .environmentObject(musicController)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        snappableWindow.contentView = hostingView

        debugPrint("[AppMain] Floating window created\n")
    }

    func showFloatingWindow() {
        guard let window = floatingWindow else { return }
        isFloatingMode = true
        NSApp.activate(ignoringOtherApps: true)
        window.orderFront(nil)
    }

    func toggleFloatingWindow() {
        guard let window = floatingWindow else { return }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFront(nil)
        }
    }

    /// 收起浮窗到菜单栏
    func collapseToMenuBar() {
        isFloatingMode = false
        floatingWindow?.orderOut(nil)
        showMenuBarPopover()

        // 开始自动隐藏计时
        scheduleAutoHide()
    }

    /// 开始 2 秒自动隐藏计时
    func scheduleAutoHide() {
        // 取消之前的计时器
        autoHideWorkItem?.cancel()

        // 创建新的计时器
        let workItem = DispatchWorkItem { [weak self] in
            self?.menuBarPopover?.close()
        }
        autoHideWorkItem = workItem

        // 2 秒后执行
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    /// 取消自动隐藏计时
    func cancelAutoHide() {
        autoHideWorkItem?.cancel()
        autoHideWorkItem = nil
    }

    /// 用户与 popover 交互时调用（鼠标进入时取消计时，离开时重新开始）
    func userInteractingWithPopover(_ isInteracting: Bool) {
        if isInteracting {
            cancelAutoHide()
        } else {
            scheduleAutoHide()
        }
    }

    /// 从菜单栏展开为浮窗
    func expandToFloatingWindow() {
        isFloatingMode = true
        menuBarPopover?.close()
        showFloatingWindow()
    }

    // MARK: - Menu Bar Popover (菜单栏弹出设置页面)

    func createMenuBarPopover() {
        menuBarPopover = NSPopover()
        menuBarPopover?.behavior = .transient
        menuBarPopover?.animates = true

        let popoverContent = MenuBarSettingsView(
            onExpand: { [weak self] in
                self?.expandToFloatingWindow()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        .environmentObject(musicController)

        let hostingController = NSHostingController(rootView: popoverContent)
        // 让 popover 自动适应内容大小
        hostingController.view.setFrameSize(hostingController.sizeThatFits(in: CGSize(width: 260, height: 600)))
        menuBarPopover?.contentViewController = hostingController
    }

    func showMenuBarPopover() {
        guard let button = statusItem.button else { return }
        menuBarPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func toggleMenuBarPopover() {
        if menuBarPopover?.isShown == true {
            menuBarPopover?.close()
        } else {
            showMenuBarPopover()
        }
    }
}

// MARK: - Window Delegate

class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// MARK: - Content Views

struct MiniPlayerContentView: View {
    @Environment(\.openWindow) private var openWindow
    var onHide: (() -> Void)?

    var body: some View {
        MiniPlayerView(openWindow: openWindow, onHide: onHide)
    }
}

/// 菜单栏弹出的设置页面 - 参照 CleanShot X 设计
struct MenuBarSettingsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    var onExpand: (() -> Void)?
    var onQuit: (() -> Void)?

    // 🔑 检测系统语言是否为中文
    private var isSystemChinese: Bool {
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        return langCode.hasPrefix("zh")
    }

    private var systemLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    // 🔑 本地化字符串
    private func localized(_ key: String) -> String {
        let strings: [String: (en: String, zh: String)] = [
            "showWindow": ("Show Window", "显示浮窗"),
            "playPause": ("Play/Pause", "播放/暂停"),
            "previous": ("Previous", "上一首"),
            "next": ("Next", "下一首"),
            "translationLang": ("Translation", "翻译语言"),
            "showInDock": ("Show in Dock", "在 Dock 显示"),
            "fullscreenCover": ("Fullscreen Cover", "全屏封面"),
            "openMusic": ("Open Music", "打开 Music"),
            "quit": ("Quit", "退出"),
            "followSystem": ("System", "跟随系统")
        ]
        return isSystemChinese ? (strings[key]?.zh ?? key) : (strings[key]?.en ?? key)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 窗口
            SettingsRow(title: localized("showWindow"), icon: "macwindow", action: { onExpand?() })

            Divider().padding(.horizontal, 12)

            // 播放控制 - 使用 .circle 版本让图标大小更一致
            SettingsRow(title: localized("playPause"), icon: "playpause.circle", shortcut: "Space", action: { musicController.togglePlayPause() })
            SettingsRow(title: localized("previous"), icon: "backward.circle", action: { musicController.previousTrack() })
            SettingsRow(title: localized("next"), icon: "forward.circle", action: { musicController.nextTrack() })

            Divider().padding(.horizontal, 12)

            // 歌词翻译 (macOS 15+)
            if #available(macOS 15.0, *) {
                SettingsPickerRow(
                    title: localized("translationLang"),
                    icon: "character.bubble",
                    currentValue: translationLanguageDisplayName,
                    options: translationLanguageOptions,
                    onSelect: { code in
                        let targetCode = code == "system" ? systemLanguageCode : code
                        lyricsService.translationLanguage = targetCode
                    }
                )

                Divider().padding(.horizontal, 12)
            }

            // 设置
            SettingsToggleRow(
                title: localized("fullscreenCover"),
                icon: "rectangle.fill",
                isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "fullscreenAlbumCover") },
                    set: { UserDefaults.standard.set($0, forKey: "fullscreenAlbumCover") }
                )
            )

            SettingsToggleRow(
                title: localized("showInDock"),
                icon: "dock.rectangle",
                isOn: Binding(
                    get: { AppMain.shared?.showInDock ?? true },
                    set: { AppMain.shared?.showInDock = $0 }
                )
            )

            Divider().padding(.horizontal, 12)

            // 其他
            SettingsRow(title: localized("openMusic"), icon: "music.note", action: {
                let url = URL(fileURLWithPath: "/System/Applications/Music.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            })

            Divider().padding(.horizontal, 12)

            SettingsRow(title: localized("quit"), icon: "power", shortcut: "⌘Q", isDestructive: true, action: { onQuit?() })
        }
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private var translationLanguageDisplayName: String {
        let currentLang = lyricsService.translationLanguage
        // 🔑 如果当前语言等于系统语言，显示 "跟随系统"
        if currentLang == systemLanguageCode {
            return localized("followSystem")
        }
        return translationLanguageOptions.first { $0.code == currentLang }?.name ?? currentLang
    }

    private var translationLanguageOptions: [(name: String, code: String)] {
        [
            (localized("followSystem"), "system"),
            ("中文", "zh"),
            ("English", "en"),
            ("日本語", "ja"),
            ("한국어", "ko"),
            ("Français", "fr"),
            ("Deutsch", "de"),
            ("Español", "es")
        ]
    }
}

// MARK: - Compact Settings Components

struct SettingsRow: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(isDestructive ? .red : .secondary)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(isDestructive ? .red : .primary)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.primary)

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }
}

struct SettingsPickerRow: View {
    let title: String
    let icon: String
    let currentValue: String
    let options: [(name: String, code: String)]
    let onSelect: (String) -> Void

    @State private var isHovering = false
    @State private var showPicker = false

    var body: some View {
        Button(action: { showPicker.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)

                Spacer()

                Text(currentValue)
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, 6)
        .popover(isPresented: $showPicker, arrowEdge: .trailing) {
            VStack(spacing: 2) {
                ForEach(options, id: \.code) { option in
                    Button(action: {
                        onSelect(option.code)
                        showPicker = false
                    }) {
                        HStack {
                            Text(option.name)
                                .font(.system(size: 12))
                            Spacer()
                            if currentValue == option.name {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .frame(width: 140)
        }
    }
}
