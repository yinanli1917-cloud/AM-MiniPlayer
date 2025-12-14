import AppKit
import SwiftUI
import MusicMiniPlayerCore

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
        fputs("[AppMain] Application launched\n", stderr)

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

        fputs("[AppMain] Setup complete\n", stderr)
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
            fputs("[AppMain] ERROR: Failed to get status item button\n", stderr)
            return
        }

        // 默认显示音符图标
        updateStatusItemIcon()

        // 点击事件
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        fputs("[AppMain] Status item created\n", stderr)
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
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            // 右键显示菜单
            showContextMenu()
        } else {
            // 左键切换显示
            if isFloatingMode {
                // 浮窗模式：切换浮窗显示/隐藏
                toggleFloatingWindow()
            } else {
                // 菜单栏模式：显示/隐藏 popover
                toggleMenuBarPopover()
            }
        }
    }

    func showContextMenu() {
        let menu = NSMenu()

        // 浮窗显示/隐藏（仅在浮窗模式下显示）
        if isFloatingMode {
            let isWindowVisible = floatingWindow?.isVisible ?? false
            let showHideItem = NSMenuItem(
                title: isWindowVisible ? "隐藏浮窗" : "显示浮窗",
                action: #selector(toggleFloatingWindowFromMenu),
                keyEquivalent: ""
            )
            menu.addItem(showHideItem)
        }

        // 模式切换
        let modeItem = NSMenuItem(
            title: isFloatingMode ? "收起到菜单栏" : "展开为浮窗",
            action: #selector(toggleMode),
            keyEquivalent: ""
        )
        menu.addItem(modeItem)

        menu.addItem(NSMenuItem.separator())

        // 播放控制
        menu.addItem(NSMenuItem(title: "播放/暂停", action: #selector(togglePlayPause), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "上一首", action: #selector(previousTrack), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "下一首", action: #selector(nextTrack), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        // Dock 图标设置
        let dockItem = NSMenuItem(
            title: showInDock ? "隐藏 Dock 图标" : "显示 Dock 图标",
            action: #selector(toggleDockIcon),
            keyEquivalent: ""
        )
        menu.addItem(dockItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "打开 Apple Music", action: #selector(openAppleMusic), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // 清除菜单以恢复点击行为
    }

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

    @objc func toggleDockIcon() {
        showInDock.toggle()
    }

    @objc func toggleFloatingWindowFromMenu() {
        toggleFloatingWindow()
    }

    @objc func togglePlayPause() { musicController.togglePlayPause() }
    @objc func previousTrack() { musicController.previousTrack() }
    @objc func nextTrack() { musicController.nextTrack() }

    @objc func openAppleMusic() {
        let url = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Floating Window (浮动窗口)

    func createFloatingWindow() {
        let windowSize = NSSize(width: 300, height: 380)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowRect = NSRect(
            x: screenFrame.maxX - windowSize.width - 20,
            y: screenFrame.maxY - windowSize.height - 20,
            width: windowSize.width,
            height: windowSize.height
        )

        floatingWindow = NSPanel(
            contentRect: windowRect,
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        guard let window = floatingWindow else { return }

        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true
        window.becomesKeyOnlyIfNeeded = true

        // 设置窗口比例和尺寸限制
        window.aspectRatio = NSSize(width: 300, height: 380)
        window.minSize = NSSize(width: 250, height: 316)
        window.maxSize = NSSize(width: 450, height: 570)

        windowDelegate = FloatingWindowDelegate()
        window.delegate = windowDelegate

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = MiniPlayerContentView(onHide: { [weak self] in
            self?.collapseToMenuBar()
        })
        .environmentObject(musicController)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        fputs("[AppMain] Floating window created\n", stderr)
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

        // 2秒后自动隐藏菜单栏弹窗
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.menuBarPopover?.close()
        }
    }

    /// 从菜单栏展开为浮窗
    func expandToFloatingWindow() {
        isFloatingMode = true
        menuBarPopover?.close()
        showFloatingWindow()
    }

    // MARK: - Menu Bar Popover (菜单栏弹出视图)

    func createMenuBarPopover() {
        menuBarPopover = NSPopover()
        menuBarPopover?.contentSize = NSSize(width: 300, height: 350)  // 高度改为 350
        menuBarPopover?.behavior = .transient
        menuBarPopover?.animates = true

        let popoverContent = MenuBarPlayerView(onExpand: { [weak self] in
            self?.expandToFloatingWindow()
        })
        .environmentObject(musicController)

        menuBarPopover?.contentViewController = NSHostingController(rootView: popoverContent)
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

/// 菜单栏弹出的播放器视图
struct MenuBarPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    var onExpand: (() -> Void)?

    var body: some View {
        ZStack {
            // 使用完整的 MiniPlayerView
            MiniPlayerView(openWindow: nil, onHide: nil, onExpand: onExpand)
        }
        .frame(width: 300, height: 350)  // 高度改为 350
        .clipShape(RoundedRectangle(cornerRadius: 10))  // 圆角 10pt
    }
}
