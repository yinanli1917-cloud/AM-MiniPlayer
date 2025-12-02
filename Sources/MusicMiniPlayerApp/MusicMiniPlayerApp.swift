import SwiftUI
import MusicMiniPlayerCore

@main
struct MusicMiniPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用一个隐藏的 Settings scene 保持 SwiftUI App 生命周期
        Settings {
            EmptyView()
        }
    }
}

// AppDelegate 管理菜单栏图标和浮动窗口
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var floatingWindow: NSPanel?
    var musicController = MusicController.shared
    var resizeHandler: WindowResizeHandler?
    private var windowDelegate: FloatingWindowDelegate?
    private var statusItemMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fputs("[AppDelegate] Application launched\n", stderr)

        // 创建菜单栏图标
        createStatusBarItem()

        // 创建浮动窗口
        createFloatingWindow()

        // 默认显示窗口
        floatingWindow?.orderFront(nil)

        // 延迟激活
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
        }

        fputs("[AppDelegate] Setup complete\n", stderr)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Bar Item

    func createStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music Mini Player")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 创建右键菜单
        createStatusItemMenu()

        fputs("[AppDelegate] Status bar item created\n", stderr)
    }

    func createStatusItemMenu() {
        statusItemMenu = NSMenu()

        let showHideItem = NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: "m")
        showHideItem.keyEquivalentModifierMask = [.command, .shift]
        showHideItem.target = self
        statusItemMenu?.addItem(showHideItem)

        statusItemMenu?.addItem(NSMenuItem.separator())

        // 播放控制
        let playPauseItem = NSMenuItem(title: musicController.isPlaying ? "Pause" : "Play", action: #selector(togglePlayPause), keyEquivalent: " ")
        playPauseItem.keyEquivalentModifierMask = []
        playPauseItem.target = self
        statusItemMenu?.addItem(playPauseItem)

        let previousItem = NSMenuItem(title: "Previous", action: #selector(previousTrack), keyEquivalent: "")
        previousItem.target = self
        statusItemMenu?.addItem(previousItem)

        let nextItem = NSMenuItem(title: "Next", action: #selector(nextTrack), keyEquivalent: "")
        nextItem.target = self
        statusItemMenu?.addItem(nextItem)

        statusItemMenu?.addItem(NSMenuItem.separator())

        let openMusicItem = NSMenuItem(title: "Open Apple Music", action: #selector(openAppleMusic), keyEquivalent: "")
        openMusicItem.target = self
        statusItemMenu?.addItem(openMusicItem)

        statusItemMenu?.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusItemMenu?.addItem(quitItem)
    }

    @objc func statusItemClicked(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // 右键显示菜单
            updateStatusItemMenu()
            statusItem?.menu = statusItemMenu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil  // 点击后移除菜单，恢复左键功能
        } else {
            // 左键切换窗口显示
            toggleWindow()
        }
    }

    func updateStatusItemMenu() {
        // 更新播放/暂停状态
        if let playPauseItem = statusItemMenu?.item(withTitle: "Play") ?? statusItemMenu?.item(withTitle: "Pause") {
            playPauseItem.title = musicController.isPlaying ? "Pause" : "Play"
        }
    }

    @objc func togglePlayPause() {
        musicController.togglePlayPause()
    }

    @objc func previousTrack() {
        musicController.previousTrack()
    }

    @objc func nextTrack() {
        musicController.nextTrack()
    }

    @objc func openAppleMusic() {
        let musicAppURL = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.openApplication(at: musicAppURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Floating Window

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

        // 配置浮动窗口属性
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

        // 设置窗口代理
        windowDelegate = FloatingWindowDelegate()
        window.delegate = windowDelegate

        // 隐藏窗口按钮
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // 创建 SwiftUI 内容视图
        let contentView = MiniPlayerContentView()
            .environmentObject(musicController)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        // 启用窗口缩放功能
        resizeHandler = WindowResizeHandler(window: window)

        fputs("[AppDelegate] Floating window created\n", stderr)
    }

    @objc func toggleWindow() {
        guard let window = floatingWindow else { return }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// 窗口代理
class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

// Helper view to access openWindow environment
struct MiniPlayerContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MiniPlayerView(openWindow: openWindow)
    }
}
