import AppKit
import SwiftUI
import MusicMiniPlayerCore

/// macOS Tahoe 菜单栏应用
/// 使用纯 AppKit 入口确保稳定性
/// 菜单栏图标可能需要在系统设置中手动启用：设置 > 菜单栏 > 找到应用 > 启用
@main
class AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // 设置为 accessory app（无 Dock 图标）
        // 注意：macOS Tahoe 可能需要用户在系统设置中启用菜单栏图标
        app.setActivationPolicy(.accessory)

        // 保持强引用
        _ = delegate

        app.run()
    }
}

/// AppDelegate 管理菜单栏图标和浮动窗口
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var floatingWindow: NSPanel?
    let musicController = MusicController.shared
    var resizeHandler: WindowResizeHandler?
    private var windowDelegate: FloatingWindowDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fputs("[AppDelegate] Application launched\n", stderr)

        // 创建菜单栏图标
        setupStatusItem()

        // 创建浮动窗口
        createFloatingWindow()

        // 显示窗口
        showWindow()

        fputs("[AppDelegate] Setup complete\n", stderr)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        fputs("[AppDelegate] applicationShouldTerminateAfterLastWindowClosed - returning false\n", stderr)
        return false
    }

    // MARK: - Status Item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else {
            fputs("[AppDelegate] ERROR: Failed to get status item button\n", stderr)
            return
        }

        // 使用 SF Symbol，设为 template 自动适应深色/浅色
        if let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music Mini Player") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "♪"
        }

        // 设置菜单
        let menu = NSMenu()

        let showHideItem = NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: "m")
        showHideItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(showHideItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Play/Pause", action: #selector(togglePlayPause), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Previous", action: #selector(previousTrack), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Next", action: #selector(nextTrack), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Open Apple Music", action: #selector(openAppleMusic), keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu

        fputs("[AppDelegate] Status item created\n", stderr)
    }

    @objc func togglePlayPause() { musicController.togglePlayPause() }
    @objc func previousTrack() { musicController.previousTrack() }
    @objc func nextTrack() { musicController.nextTrack() }

    @objc func openAppleMusic() {
        let url = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Window

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

        windowDelegate = FloatingWindowDelegate()
        window.delegate = windowDelegate

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let contentView = MiniPlayerContentView()
            .environmentObject(musicController)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        resizeHandler = WindowResizeHandler(window: window)

        fputs("[AppDelegate] Window created\n", stderr)
    }

    func showWindow() {
        guard let window = floatingWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.orderFront(nil)
    }

    @objc func toggleWindow() {
        guard let window = floatingWindow else { return }

        if window.isVisible {
            window.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFront(nil)
        }
    }
}

class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

struct MiniPlayerContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MiniPlayerView(openWindow: openWindow)
    }
}
