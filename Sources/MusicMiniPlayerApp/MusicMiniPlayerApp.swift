import AppKit
import SwiftUI
import MusicMiniPlayerCore

/// macOS Tahoe 菜单栏应用
/// 使用纯 AppKit 入口 + NSStatusItem，最可靠的方式
@main
class AppMain: NSObject, NSApplicationDelegate {
    static var shared: AppMain!

    var statusItem: NSStatusItem!
    var floatingWindow: NSPanel?
    let musicController = MusicController.shared
    private var windowDelegate: FloatingWindowDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppMain()
        AppMain.shared = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        fputs("[AppMain] Application launched\n", stderr)

        // 创建菜单栏图标
        setupStatusItem()

        // 创建浮动窗口
        createFloatingWindow()

        // 显示窗口
        showWindow()

        fputs("[AppMain] Setup complete\n", stderr)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - Status Item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true

        guard let button = statusItem.button else {
            fputs("[AppMain] ERROR: Failed to get status item button\n", stderr)
            return
        }

        // 使用 SF Symbol
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

        fputs("[AppMain] Status item created\n", stderr)
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

        // 设置窗口比例和尺寸限制
        window.aspectRatio = NSSize(width: 300, height: 380)
        window.minSize = NSSize(width: 250, height: 316)  // 250 * 380/300
        window.maxSize = NSSize(width: 450, height: 570)  // 450 * 380/300

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

        fputs("[AppMain] Window created\n", stderr)
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
