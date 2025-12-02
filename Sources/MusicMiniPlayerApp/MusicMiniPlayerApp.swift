import AppKit
import SwiftUI
import MusicMiniPlayerCore

// 使用纯 AppKit 入口，避免 SwiftUI App 生命周期问题
@main
class AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // 设置为 accessory app（无 Dock 图标）
        app.setActivationPolicy(.accessory)

        app.run()
    }
}

// AppDelegate 管理菜单栏图标和浮动窗口
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var floatingWindow: NSPanel?
    var musicController = MusicController.shared
    var resizeHandler: WindowResizeHandler?
    private var windowDelegate: FloatingWindowDelegate?
    private var statusItemMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fputs("[AppDelegate] Application launched\n", stderr)

        // 创建菜单栏图标 - 必须在主线程且应用启动后
        createStatusBarItem()

        // 创建浮动窗口
        createFloatingWindow()

        // 默认显示窗口
        floatingWindow?.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        fputs("[AppDelegate] Setup complete - statusItem: \(statusItem != nil), window: \(floatingWindow != nil)\n", stderr)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Bar Item

    func createStatusBarItem() {
        // 创建状态栏项目 - 使用固定长度确保显示
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else {
            fputs("[AppDelegate] ERROR: Failed to get status item button\n", stderr)
            return
        }

        // 使用 SF Symbol 图标
        if let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music Mini Player") {
            image.isTemplate = true  // 让系统自动适配深色/浅色模式
            button.image = image
        } else {
            // 备用：使用文字
            button.title = "♪"
        }

        button.action = #selector(statusItemClicked(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // 创建右键菜单
        createStatusItemMenu()

        fputs("[AppDelegate] Status bar item created successfully\n", stderr)
    }

    func createStatusItemMenu() {
        statusItemMenu = NSMenu()

        let showHideItem = NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: "m")
        showHideItem.keyEquivalentModifierMask = [.command, .shift]
        showHideItem.target = self
        statusItemMenu?.addItem(showHideItem)

        statusItemMenu?.addItem(NSMenuItem.separator())

        // 播放控制
        let playPauseItem = NSMenuItem(title: "Play/Pause", action: #selector(togglePlayPause), keyEquivalent: " ")
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
        guard let event = NSApp.currentEvent else {
            toggleWindow()
            return
        }

        if event.type == .rightMouseUp {
            // 右键显示菜单
            statusItem.menu = statusItemMenu
            statusItem.button?.performClick(nil)
            // 延迟清除菜单，让菜单有机会显示
            DispatchQueue.main.async {
                self.statusItem.menu = nil
            }
        } else {
            // 左键切换窗口显示
            toggleWindow()
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
