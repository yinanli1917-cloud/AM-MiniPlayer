import SwiftUI
import MusicMiniPlayerCore

@main
struct MusicMiniPlayerApp: App {
    @StateObject private var musicController = MusicController.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 不使用SwiftUI Window,完全由AppDelegate管理
        Settings {
            EmptyView()
        }
    }
}

// AppDelegate to manage menu bar icon and borderless floating window
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var floatingWindow: NSPanel?
    var musicController = MusicController.shared
    var resizeHandler: WindowResizeHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Music Mini Player")
            image?.isTemplate = true  // 确保使用模板渲染
            button.image = image
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            fputs("[AppDelegate] Status bar button configured with music.note icon\n", stderr)
        } else {
            fputs("[AppDelegate] ERROR: Failed to get status bar button\n", stderr)
        }

        // Set activation policy to accessory (hide dock icon, only show menu bar icon)
        // This ensures menu bar icon is always visible even when window is hidden
        NSApp.setActivationPolicy(.accessory)

        // Create borderless floating window (Arc browser style PIP)
        createFloatingWindow()

        // Show window by default
        floatingWindow?.orderFront(nil)
    }

    @objc func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!

        if event.type == .rightMouseUp {
            // Right click - show menu
            showMenu()
        } else {
            // Left click - toggle window
            toggleWindow()
        }
    }

    func showMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Music Mini Player", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    func createFloatingWindow() {
        // Create borderless floating panel with original aspect ratio
        let windowSize = NSSize(width: 300, height: 380)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowRect = NSRect(
            x: screenFrame.maxX - windowSize.width - 20,
            y: screenFrame.maxY - windowSize.height - 20,
            width: windowSize.width,
            height: windowSize.height
        )

        // Create panel with resizable style
        // Note: .nonactivatingPanel CONFLICTS with .resizable, so we DON'T use it
        floatingWindow = NSPanel(
            contentRect: windowRect,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        guard let window = floatingWindow else { return }

        // Configure floating window properties
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true // Enable window dragging
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = true // 关键：让tracking area的mouseMoved工作

        // Hide all window buttons
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // Create SwiftUI content view (不要设置固定frame，让它自适应窗口大小)
        let contentView = MiniPlayerContentView()
            .environmentObject(musicController)

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.autoresizingMask = [.width, .height] // 关键：让hosting view自动调整大小
        window.contentView = hostingView

        // 启用窗口缩放功能
        resizeHandler = WindowResizeHandler(window: window)
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

// Helper view to access openWindow environment
struct MiniPlayerContentView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MiniPlayerView(openWindow: openWindow)
    }
}
