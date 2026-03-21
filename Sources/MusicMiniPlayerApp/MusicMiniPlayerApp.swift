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
    var settingsWindow: NSWindow?
    let musicController = MusicController.shared
    private var windowDelegate: FloatingWindowDelegate?
    private var settingsWindowDelegate: SettingsWindowDelegate?

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

        // 首次启动默认值（用户未手动设置前生效）
        UserDefaults.standard.register(defaults: [
            "showInDock": true,
            "fullscreenAlbumCover": true
        ])

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

        // 创建设置窗口
        createSettingsWindow()

        // 设置主菜单（支持 ⌘, 快捷键）
        setupMainMenu()

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
        snappableWindow.becomesKeyOnlyIfNeeded = false  // 🔑 允许窗口成为 key window

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
        window.makeKeyAndOrderFront(nil)  // 🔑 让窗口成为 key window
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

    // MARK: - Settings Window (设置窗口)

    func createSettingsWindow() {
        let settingsContent = SettingsWindowView()
            .environmentObject(musicController)

        let hostingController = NSHostingController(rootView: settingsContent)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Music Mini Player Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 450, height: 400))
        window.center()
        window.isReleasedWhenClosed = false

        settingsWindowDelegate = SettingsWindowDelegate()
        window.delegate = settingsWindowDelegate

        settingsWindow = window
    }

    func showSettingsWindow() {
        guard let window = settingsWindow else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings(_ sender: Any?) {
        showSettingsWindow()
    }

    // MARK: - Main Menu (主菜单)

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        // About
        let aboutItem = NSMenuItem(title: "About Music Mini Player", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        // Settings (⌘,)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        // Hide
        let hideItem = NSMenuItem(title: "Hide Music Mini Player", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)

        appMenu.addItem(NSMenuItem.separator())

        // Quit (⌘Q)
        let quitItem = NSMenuItem(title: "Quit Music Mini Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        mainMenu.addItem(appMenuItem)

        // Window 菜单
        let windowMenu = NSMenu(title: "Window")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu

        let showWindowItem = NSMenuItem(title: "Show Player", action: #selector(showFloatingWindowAction(_:)), keyEquivalent: "1")
        showWindowItem.target = self
        windowMenu.addItem(showWindowItem)

        let showSettingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings(_:)), keyEquivalent: ",")
        showSettingsItem.target = self
        windowMenu.addItem(showSettingsItem)

        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func showFloatingWindowAction(_ sender: Any?) {
        showFloatingWindow()
    }
}

// MARK: - Window Delegates

class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // 🔑 窗口成为 key window 时，临时切换到 regular 策略以显示 menu bar
    func windowDidBecomeKey(_ notification: Notification) {
        // 即使 showInDock 为 false，也临时切换到 regular 以显示菜单
        if !UserDefaults.standard.bool(forKey: "showInDock") {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // 🔑 窗口失去 key window 时，恢复原来的激活策略
    func windowDidResignKey(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: "showInDock") {
            // 延迟一点恢复，避免闪烁
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // 只有在没有其他窗口是 key 的情况下才恢复
                if NSApp.keyWindow == nil {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

class SettingsWindowDelegate: NSObject, NSWindowDelegate {
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
            "settings": ("Settings...", "设置..."),
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

            SettingsRow(title: localized("settings"), icon: "gear", shortcut: "⌘,", action: {
                AppMain.shared?.showSettingsWindow()
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

// MARK: - Settings Window View (独立设置窗口)

struct SettingsWindowView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared

    // 检测系统语言是否为中文
    private var isSystemChinese: Bool {
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        return langCode.hasPrefix("zh")
    }

    private var systemLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    private func localized(_ key: String) -> String {
        let strings: [String: (en: String, zh: String)] = [
            "general": ("General", "通用"),
            "playback": ("Playback", "播放"),
            "appearance": ("Appearance", "外观"),
            "about": ("About", "关于"),
            "showInDock": ("Show in Dock", "在 Dock 显示"),
            "showInDockDesc": ("Show app icon in the Dock", "在 Dock 中显示应用图标"),
            "fullscreenCover": ("Fullscreen Cover Mode", "全屏封面模式"),
            "fullscreenCoverDesc": ("Enable immersive album cover display", "启用沉浸式专辑封面显示"),
            "translationLang": ("Lyrics Translation", "歌词翻译"),
            "translationLangDesc": ("Target language for lyrics translation", "歌词翻译的目标语言"),
            "followSystem": ("Follow System", "跟随系统"),
            "version": ("Version", "版本"),
            "developer": ("Developer", "开发者"),
            "website": ("Website", "网站"),
            "musicKit": ("Apple Music Access", "Apple Music 访问"),
            "musicKitDesc": ("Required for album artwork and song info", "用于获取专辑封面和歌曲信息"),
            "musicKitRequest": ("Request Access", "请求访问"),
            "musicKitOpen": ("Open Settings", "打开设置")
        ]
        return isSystemChinese ? (strings[key]?.zh ?? key) : (strings[key]?.en ?? key)
    }

    var body: some View {
        TabView {
            // 通用设置
            generalTab
                .tabItem {
                    Label(localized("general"), systemImage: "gear")
                }

            // 外观设置
            appearanceTab
                .tabItem {
                    Label(localized("appearance"), systemImage: "paintbrush")
                }

            // 关于
            aboutTab
                .tabItem {
                    Label(localized("about"), systemImage: "info.circle")
                }
        }
        .padding(20)
        .frame(minWidth: 450, minHeight: 350)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            // MusicKit 授权
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized("musicKit"))
                        Text(localized("musicKitDesc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        // 状态指示
                        Circle()
                            .fill(musicController.musicKitAuthorized ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)

                        Text(musicController.musicKitAuthStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // 按钮
                        if !musicController.musicKitAuthorized {
                            Button(localized("musicKitRequest")) {
                                Task {
                                    await musicController.requestMusicKitAccess()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        } else {
                            Button(localized("musicKitOpen")) {
                                // 打开系统隐私设置
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { AppMain.shared?.showInDock ?? true },
                    set: { AppMain.shared?.showInDock = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized("showInDock"))
                        Text(localized("showInDockDesc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "fullscreenAlbumCover") },
                    set: { UserDefaults.standard.set($0, forKey: "fullscreenAlbumCover") }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized("fullscreenCover"))
                        Text(localized("fullscreenCoverDesc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if #available(macOS 15.0, *) {
                Section {
                    Picker(selection: Binding(
                        get: {
                            let currentLang = lyricsService.translationLanguage
                            return currentLang == systemLanguageCode ? "system" : currentLang
                        },
                        set: { code in
                            let targetCode = code == "system" ? systemLanguageCode : code
                            lyricsService.translationLanguage = targetCode
                        }
                    )) {
                        ForEach(translationLanguageOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localized("translationLang"))
                            Text(localized("translationLangDesc"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Music Mini Player")
                .font(.title)
                .fontWeight(.semibold)

            Text("\(localized("version")) 1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 20) {
                Link(destination: URL(string: "https://github.com/YinanLi/MusicMiniPlayer")!) {
                    Label("GitHub", systemImage: "link")
                }
                .buttonStyle(.link)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
