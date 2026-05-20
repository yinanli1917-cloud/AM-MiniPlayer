/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 MusicController/LyricsService/SnappablePanel/MiniPlayerView
 *          依赖 SettingsView 的 MenuBarSettingsView/SettingsWindowView
 * [OUTPUT]: 导出 AppMain（应用入口）
 * [POS]: MusicMiniPlayerApp 的 AppDelegate + 窗口管理
 */

import AppKit
import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - App Entry
// ──────────────────────────────────────────────

/// macOS 菜单栏迷你播放器应用
/// 支持：菜单栏迷你视图 + 浮动窗口模式切换
@main
class AppMain: NSObject, NSApplicationDelegate {
    static var shared: AppMain!

    var statusItem: NSStatusItem!
    var floatingWindow: NSPanel?
    var menuBarPopover: NSPopover?
    var settingsWindow: NSWindow?
    #if DEBUG || LOCAL_DEVELOPER_BUILD
    var diagnosticsWindow: NSWindow?
    #endif
    let musicController = MusicController.shared
    let settingsWindowState = SettingsWindowState()
    private var windowDelegate: FloatingWindowDelegate?
    private var settingsWindowDelegate: SettingsWindowDelegate?
    #if DEBUG || LOCAL_DEVELOPER_BUILD
    private var diagnosticsWindowDelegate: SettingsWindowDelegate?
    #endif

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

        // ──────────────────────────────────────────────
        // Heal macOS 26 ControlCenter database BEFORE registering NSStatusItem.
        // Removes stale com.yinanli.MusicMiniPlayer entries that cause the menu
        // bar icon to land at x=-1 (off-screen). Idempotent + best-effort.
        // ──────────────────────────────────────────────
        MenuBarHealer.healIfNeeded()

        updateDockVisibility()
        setupStatusItem()
        createFloatingWindow()
        createMenuBarPopover()
        createSettingsWindow()
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        createDiagnosticsWindow()
        #endif
        setupMainMenu()
        setupURLHandling()
        showFloatingWindow()

        // ──────────────────────────────────────────────
        // Seamless auto-update: silent background check 5s after launch.
        // Any newer release is downloaded + SHA256-verified + staged; the
        // actual bundle swap happens on applicationWillTerminate.
        // ──────────────────────────────────────────────
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            UpdateService.shared.checkInBackground()
        }

        debugPrint("[AppMain] Setup complete\n")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsService.shared.prepareForTermination()
        UpdateApplier.applyIfStaged()
    }

    // MARK: - URL Handling

    func setupURLHandling() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString)
        else { return }

        handleAppURL(url)
    }

    func handleAppURL(_ url: URL) {
        guard url.scheme?.lowercased() == "nanopod" else { return }

        switch url.host?.lowercased() {
        case "page":
            openPage(named: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        case "settings":
            openSettingsPage(named: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case "diagnostics":
            let action = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if action == "clear" {
                Task { @MainActor in
                    DiagnosticsService.shared.clear(suppressImmediateStandaloneFrameStalls: true)
                    self.showDiagnosticsWindow()
                }
            } else {
                showDiagnosticsWindow()
            }
        #endif
        default:
            break
        }
    }

    func openSettingsPage(named pageName: String) {
        switch pageName.lowercased() {
        case "", "general":
            showSettingsWindow(selectedTab: .general)
        case "appearance":
            showSettingsWindow(selectedTab: .appearance)
        case "about":
            showSettingsWindow(selectedTab: .about)
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case "diagnostics":
            showDiagnosticsWindow()
        #endif
        default:
            showSettingsWindow()
        }
    }

    func openPage(named pageName: String) {
        let page: PlayerPage?
        switch pageName.lowercased() {
        case "album", "":
            page = .album
        case "lyrics":
            page = .lyrics
        case "playlist", "queue":
            page = .playlist
        default:
            page = nil
        }

        guard let page else { return }
        showFloatingWindow()
        musicController.currentPage = page
        musicController.userManuallyOpenedLyrics = page == .lyrics
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        guard let button = statusItem.button else {
            debugPrint("[AppMain] ERROR: Failed to get status item button\n")
            return
        }

        updateStatusItemIcon()

        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp])

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
        toggleMenuBarPopover()
    }

    // MARK: - Mode Toggle

    @objc func toggleMode() {
        isFloatingMode.toggle()

        if isFloatingMode {
            menuBarPopover?.close()
            showFloatingWindow()
        } else {
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
        snappableWindow.isMovableByWindowBackground = false
        snappableWindow.titlebarAppearsTransparent = true
        snappableWindow.titleVisibility = .hidden
        snappableWindow.hidesOnDeactivate = false
        snappableWindow.acceptsMouseMovedEvents = true
        snappableWindow.becomesKeyOnlyIfNeeded = false

        // 窗口比例和尺寸限制
        snappableWindow.aspectRatio = NSSize(width: 250, height: 316)
        snappableWindow.minSize = NSSize(width: 180, height: 228)
        snappableWindow.maxSize = NSSize(width: 400, height: 506)

        // 当前页面 provider（判断双指拖拽是否生效）
        snappableWindow.currentPageProvider = { [weak self] in
            return self?.musicController.currentPage ?? .album
        }

        // 手动滚动状态 provider（两次滑动逻辑）
        snappableWindow.isManualScrollingProvider = {
            return LyricsService.shared.isManualScrolling
        }

        // 触发进入手动滚动状态
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
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        snappableWindow.contentView = hostingView

        debugPrint("[AppMain] Floating window created\n")
    }

    func showFloatingWindow() {
        guard let window = floatingWindow else { return }
        isFloatingMode = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        scheduleAutoHide()
    }

    /// 开始 2 秒自动隐藏计时
    func scheduleAutoHide() {
        autoHideWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.menuBarPopover?.close()
        }
        autoHideWorkItem = workItem

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
        let settingsContent = SettingsWindowView(state: settingsWindowState)
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

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    func createDiagnosticsWindow() {
        let diagnosticsContent = DiagnosticsDebugPanel(musicController: musicController)
            .frame(minWidth: 680, minHeight: 620)

        let hostingController = NSHostingController(rootView: diagnosticsContent)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "nanoPod Diagnostics"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 720))
        window.minSize = NSSize(width: 620, height: 520)
        window.center()
        window.isReleasedWhenClosed = false

        diagnosticsWindowDelegate = SettingsWindowDelegate()
        window.delegate = diagnosticsWindowDelegate

        diagnosticsWindow = window
    }
    #endif

    func showSettingsWindow(selectedTab: SettingsTab? = nil) {
        guard let window = settingsWindow else { return }
        if let selectedTab {
            settingsWindowState.selectedTab = selectedTab
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    func showDiagnosticsWindow() {
        guard let window = diagnosticsWindow else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif

    @objc func openSettings(_ sender: Any?) {
        showSettingsWindow()
    }

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    @objc func openDiagnostics(_ sender: Any?) {
        showDiagnosticsWindow()
    }
    #endif

    // MARK: - Main Menu (主菜单)

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(title: "About Music Mini Player", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide Music Mini Player", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)

        appMenu.addItem(NSMenuItem.separator())

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

        #if DEBUG || LOCAL_DEVELOPER_BUILD
        let showDiagnosticsItem = NSMenuItem(title: "Diagnostics", action: #selector(openDiagnostics(_:)), keyEquivalent: "d")
        showDiagnosticsItem.keyEquivalentModifierMask = [.command, .option]
        showDiagnosticsItem.target = self
        windowMenu.addItem(showDiagnosticsItem)
        #endif

        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func showFloatingWindowAction(_ sender: Any?) {
        showFloatingWindow()
    }
}

// ──────────────────────────────────────────────
// MARK: - Window Delegates
// ──────────────────────────────────────────────

class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// ──────────────────────────────────────────────
// MARK: - Content View Wrapper
// ──────────────────────────────────────────────

struct MiniPlayerContentView: View {
    @Environment(\.openWindow) private var openWindow
    var onHide: (() -> Void)?

    var body: some View {
        MiniPlayerView(openWindow: openWindow, onHide: onHide)
    }
}
