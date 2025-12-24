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
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

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

        // 🔑 翻译目标语言设置 (仅 macOS 15+)
        if #available(macOS 15.0, *) {
            let translationMenu = NSMenuItem()
            translationMenu.title = "翻译语言"
            let translationSubmenu = NSMenu()

            // 获取当前设置的翻译语言
            let currentLang = LyricsService.shared.translationLanguage
            let systemLang = Locale.current.language.languageCode?.identifier ?? "zh"

            // 定义支持的语言列表
            let languages: [(name: String, code: String)] = [
                ("跟随系统", "system"),  // 特殊值，使用系统语言
                ("中文", "zh"),
                ("英文", "en"),
                ("日文", "ja"),
                ("韩文", "ko"),
                ("法文", "fr"),
                ("德文", "de"),
                ("西班牙文", "es"),
                ("俄文", "ru"),
                ("葡萄牙文", "pt"),
                ("意大利文", "it")
            ]

            for lang in languages {
                let item = NSMenuItem(
                    title: lang.name,
                    action: #selector(setTranslationLanguage(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = lang.code

                // 标记当前选中的语言
                let isSelected: Bool
                if lang.code == "system" {
                    isSelected = (currentLang == systemLang)
                } else {
                    isSelected = (currentLang == lang.code)
                }

                if isSelected {
                    item.state = .on
                }

                translationSubmenu.addItem(item)
            }

            translationMenu.submenu = translationSubmenu
            menu.addItem(translationMenu)

            menu.addItem(NSMenuItem.separator())
        }

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

    // MARK: - Translation Language Settings

    @objc func setTranslationLanguage(_ sender: NSMenuItem) {
        guard let langCode = sender.representedObject as? String else { return }

        let targetLangCode: String
        if langCode == "system" {
            // 使用系统语言
            targetLangCode = Locale.current.language.languageCode?.identifier ?? "zh"
            debugPrint("🌐 翻译语言设置为: 跟随系统 (\(targetLangCode))\n")
        } else {
            targetLangCode = langCode
            debugPrint("🌐 翻译语言设置为: \(targetLangCode)\n")
        }

        // 设置语言
        LyricsService.shared.translationLanguage = targetLangCode

        // 🔑 macOS 15.0+: 预先下载语言包（如果需要）
        if #available(macOS 15.0, *) {
            Task {
                await prepareTranslationLanguage(targetLangCode)
            }
        }
    }

    /// 🔑 检查并准备翻译语言包（触发系统下载 UI）
    @available(macOS 15.0, *)
    private func prepareTranslationLanguage(_ langCode: String) async {
        let targetLanguage = Locale.Language(identifier: langCode)

        // 检查语言是否可用
        let availability = LanguageAvailability()
        let status = await availability.status(from: .init(identifier: "en"), to: targetLanguage)

        switch status {
        case .installed:
            debugPrint("🌐 翻译语言包已安装: \(langCode)\n")
        case .supported:
            debugPrint("🌐 翻译语言包需要下载: \(langCode)，将在首次翻译时提示下载\n")
            // 系统会在下次使用 .translationTask() 时自动提示下载
        case .unsupported:
            debugPrint("⚠️ 翻译语言不支持: \(langCode)\n")
        @unknown default:
            break
        }
    }

    @objc func openAppleMusic() {
        let url = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    @objc func quitApp() { NSApp.terminate(nil) }

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

    // MARK: - Menu Bar Popover (菜单栏弹出视图)

    func createMenuBarPopover() {
        menuBarPopover = NSPopover()
        menuBarPopover?.contentSize = NSSize(width: 300, height: 350)  // 高度改为 350
        menuBarPopover?.behavior = .transient
        menuBarPopover?.animates = true

        let popoverContent = MenuBarPlayerView(
            onExpand: { [weak self] in
                self?.expandToFloatingWindow()
            },
            onHoverChanged: { [weak self] isHovering in
                // 用户鼠标进入时取消自动隐藏，离开时重新开始计时
                self?.userInteractingWithPopover(isHovering)
            }
        )
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
    var onHoverChanged: ((Bool) -> Void)?

    var body: some View {
        ZStack {
            // 🔑 背景取色 - 使用 LiquidBackgroundView
            LiquidBackgroundView(artwork: musicController.currentArtwork)
                .ignoresSafeArea()

            // 使用完整的 MiniPlayerView
            MiniPlayerView(openWindow: nil, onHide: nil, onExpand: onExpand)
        }
        .frame(width: 300, height: 350)  // 高度改为 350
        .clipShape(RoundedRectangle(cornerRadius: 6))  // 圆角 6pt
        .onHover { isHovering in
            // 通知 AppMain 用户是否在交互
            onHoverChanged?(isHovering)
        }
    }
}
