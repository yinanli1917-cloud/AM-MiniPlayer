/**
 * [INPUT]: Depends on MusicMiniPlayerCore MusicController/LyricsService/SnappablePanel/MiniPlayerView
 *          and SettingsView SettingsWindowView; MetadataResolver.diskCache for the terminate flush.
 * [OUTPUT]: Exports AppMain, the application entry point.
 * [POS]: MusicMiniPlayerApp AppDelegate and window management.
 */

import AppKit
import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - App Entry
// ──────────────────────────────────────────────

/// macOS menu bar mini player with floating-window support.
@main
class AppMain: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppMain!

    var statusItem: NSStatusItem!
    var menuBarMenu: NSMenu?
    var floatingWindow: NSPanel?
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

    // Whether playback is shown as a floating window instead of only through the menu bar.
    @Published var isFloatingMode: Bool = true

    // Whether the app should appear in the Dock.
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

        // First-launch defaults, used until the user changes them.
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

        // ──────────────────────────────────────────────
        // Metadata warm-up: once per disk-cache schema version, background-
        // resolve queue/recent tracks whose rows a schema bump flushed.
        // Utility priority, sequential, yields to foreground fetches; the
        // sweep itself polls until the queue snapshot populates.
        // ──────────────────────────────────────────────
        MetadataWarmupSweep.shared.startIfNeeded()

        debugPrint("[AppMain] Setup complete\n")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsService.shared.prepareForTermination()
        // Stop the warm-up sweep BEFORE flushing so no new resolutions
        // race the final cache write (bundle swap must stay last).
        MetadataWarmupSweep.shared.cancel()
        // Metadata cache persists on a debounce — force the pending write
        // out before the process dies.
        MetadataResolver.shared.diskCache.flush()
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
        case "debug-lyrics":
            openDebugLyricsFixture(named: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
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

    #if DEBUG || LOCAL_DEVELOPER_BUILD
    func openDebugLyricsFixture(named fixtureName: String) {
        guard let fixture = NativeLyricsDebugFixture.fixture(named: fixtureName) else { return }
        Task { @MainActor in
            LyricsService.shared.applyDebugFixture(fixture)
            self.musicController.applyDebugPlaybackFixture(fixture)
            self.showFloatingWindow()
        }
    }
    #endif

    // MARK: - Dock Visibility

    func updateDockVisibility() {
        if showInDock {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Status Item

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        guard statusItem.button != nil else {
            debugPrint("[AppMain] ERROR: Failed to get status item button\n")
            return
        }

        updateStatusItemIcon()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        populateMenuBarMenu(menu)
        menuBarMenu = menu
        statusItem.menu = menu

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

    // MARK: - Mode Toggle

    @objc func toggleMode() {
        isFloatingMode.toggle()

        if isFloatingMode {
            showFloatingWindow()
        } else {
            floatingWindow?.orderOut(nil)
            showMenuBarMenu()
        }
    }

    // MARK: - Floating Window

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

        // Window aspect ratio and size limits.
        snappableWindow.aspectRatio = NSSize(width: 250, height: 316)
        snappableWindow.minSize = NSSize(width: 180, height: 228)
        snappableWindow.maxSize = NSSize(width: 400, height: 506)

        // Current page provider, used to decide whether two-finger dragging applies.
        snappableWindow.currentPageProvider = { [weak self] in
            return self?.musicController.currentPage ?? .album
        }

        // Manual-scroll provider for the two-swipe interaction logic.
        snappableWindow.isManualScrollingProvider = {
            return LyricsService.shared.isManualScrolling
        }

        // Enters manual-scroll mode.
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

    func showFloatingWindow(revealNearbySnapPosition: Bool = false) {
        guard let window = floatingWindow else { return }
        isFloatingMode = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if revealNearbySnapPosition, let snappableWindow = window as? SnappablePanel {
            snappableWindow.revealAtNearbySnapPosition()
        }
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

    /// Collapses the floating window back to the menu bar.
    func collapseToMenuBar() {
        isFloatingMode = false
        floatingWindow?.orderOut(nil)
        showMenuBarMenu()
    }

    /// Shows the floating window from the menu bar; no longer toggles between menu-bar and floating modes.
    func revealFloatingWindowFromMenuBar() {
        isFloatingMode = true
        showFloatingWindow(revealNearbySnapPosition: true)
    }

    // MARK: - Menu Bar Menu

    func showMenuBarMenu() {
        guard let button = statusItem.button else { return }
        button.performClick(nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === menuBarMenu else { return }
        populateMenuBarMenu(menu)
    }

    private func populateMenuBarMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(makeMenuItem(
            title: L10n.localized("showWindow"),
            systemImageName: "macwindow",
            action: #selector(showWindowFromMenu(_:))
        ))

        menu.addItem(.separator())

        menu.addItem(makeSwitchMenuItem(
            title: L10n.localized("mb.fullscreenCover"),
            systemImageName: "rectangle.expand.vertical",
            isOn: UserDefaults.standard.bool(forKey: "fullscreenAlbumCover"),
            action: { isOn in
                UserDefaults.standard.set(isOn, forKey: "fullscreenAlbumCover")
            }
        ))

        if #available(macOS 15.0, *) {
            menu.addItem(makeSwitchMenuItem(
                title: L10n.localized("mb.translation"),
                systemImageName: "character.bubble",
                isOn: LyricsService.shared.showTranslation,
                action: { isOn in
                    LyricsService.shared.showTranslation = isOn
                }
            ))

            menu.addItem(makeTranslationTargetSubmenuItem())
        }

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: L10n.localized("settings"),
            systemImageName: "gearshape",
            action: #selector(openSettings(_:))
        ))

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: L10n.localized("quit"),
            systemImageName: "power",
            action: #selector(NSApplication.terminate(_:)),
            target: NSApp
        ))
    }

    private func makeMenuItem(
        title: String,
        systemImageName: String,
        action: Selector?,
        keyEquivalent: String = "",
        modifierMask: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target ?? self
        item.keyEquivalentModifierMask = keyEquivalent.isEmpty ? [] : modifierMask

        if let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: title) {
            let configuration = NSImage.SymbolConfiguration(pointSize: MenuBarMenuMetrics.symbolPointSize, weight: .medium)
            let configuredImage = image.withSymbolConfiguration(configuration) ?? image
            configuredImage.isTemplate = true
            item.image = configuredImage
        }

        return item
    }

    private func makeSwitchMenuItem(
        title: String,
        systemImageName: String,
        isOn: Bool,
        action: @escaping (Bool) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuBarSwitchItemView(
            title: title,
            systemImageName: systemImageName,
            isOn: isOn,
            action: action
        )
        return item
    }

    private func makeTranslationTargetSubmenuItem() -> NSMenuItem {
        let currentLanguage = LyricsService.shared.translationLanguage
        let selectedCode = currentLanguage == L10n.systemLanguageCode ? "system" : currentLanguage

        let item = makeMenuItem(
            title: L10n.localized("mb.translationTarget"),
            systemImageName: "globe",
            action: nil
        )
        let submenu = NSMenu(title: L10n.localized("mb.translationTarget"))
        for option in L10n.translationLanguageOptions {
            let optionItem = NSMenuItem(
                title: option.name,
                action: #selector(selectTranslationLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            optionItem.target = self
            optionItem.representedObject = option.code
            optionItem.state = option.code == selectedCode ? .on : .off
            submenu.addItem(optionItem)
        }
        item.submenu = submenu
        return item
    }

    @objc private func showWindowFromMenu(_ sender: NSMenuItem) {
        revealFloatingWindowFromMenuBar()
    }

    @objc private func selectTranslationLanguageFromMenu(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        LyricsService.shared.translationLanguage = code == "system" ? L10n.systemLanguageCode : code
    }

    // MARK: - Settings Window

    func createSettingsWindow() {
        guard settingsWindow == nil else { return }
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
        guard diagnosticsWindow == nil else { return }
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
        if settingsWindow == nil {
            createSettingsWindow()
        }
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
        if diagnosticsWindow == nil {
            createDiagnosticsWindow()
        }
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

    // MARK: - Main Menu

    func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
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

        // Window menu
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
        showFloatingWindow(revealNearbySnapPosition: true)
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

// ──────────────────────────────────────────────
// MARK: - Menu Bar Custom Items
// ──────────────────────────────────────────────

private enum MenuBarMenuMetrics {
    static let width: CGFloat = 206
    static let rowHeight: CGFloat = 26
    static let leftInset: CGFloat = 15
    static let rightInset: CGFloat = 9
    static let iconBoxSize: CGFloat = 19
    static let symbolPointSize: CGFloat = 15
    static let textX: CGFloat = 39
    static let controlGap: CGFloat = 8
    static let switchSize = NSSize(width: 33, height: 18)
    static let labelHeight: CGFloat = 17
}

private class MenuBarCustomItemView: NSView {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: MenuBarMenuMetrics.width, height: MenuBarMenuMetrics.rowHeight)
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    func makeIconView(systemImageName: String, accessibilityDescription: String) -> NSImageView {
        let imageView = NSImageView()
        if let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: accessibilityDescription) {
            image.isTemplate = true
            let configuration = NSImage.SymbolConfiguration(
                pointSize: MenuBarMenuMetrics.symbolPointSize,
                weight: .medium
            )
            imageView.image = image.withSymbolConfiguration(configuration) ?? image
        }
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .labelColor
        return imageView
    }

    func makeTitleLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13.5, weight: .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

private final class MenuBarSwitchItemView: MenuBarCustomItemView {
    private let iconView: NSImageView
    private let titleLabel: NSTextField
    private let switchControl = CompactSwitchControl()
    private let action: (Bool) -> Void

    init(title: String, systemImageName: String, isOn: Bool, action: @escaping (Bool) -> Void) {
        self.iconView = NSImageView()
        self.titleLabel = NSTextField(labelWithString: title)
        self.action = action

        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: MenuBarMenuMetrics.width,
            height: MenuBarMenuMetrics.rowHeight
        ))

        let configuredIcon = makeIconView(systemImageName: systemImageName, accessibilityDescription: title)
        iconView.image = configuredIcon.image
        iconView.symbolConfiguration = configuredIcon.symbolConfiguration
        iconView.contentTintColor = configuredIcon.contentTintColor

        let configuredLabel = makeTitleLabel(title)
        titleLabel.font = configuredLabel.font
        titleLabel.textColor = configuredLabel.textColor
        titleLabel.lineBreakMode = configuredLabel.lineBreakMode

        switchControl.isOn = isOn
        switchControl.target = self
        switchControl.action = #selector(switchChanged(_:))

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(switchControl)

        toolTip = title
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let boundsHeight = bounds.height
        iconView.frame = NSRect(
            x: MenuBarMenuMetrics.leftInset,
            y: (boundsHeight - MenuBarMenuMetrics.iconBoxSize) / 2,
            width: MenuBarMenuMetrics.iconBoxSize,
            height: MenuBarMenuMetrics.iconBoxSize
        )

        switchControl.frame = NSRect(
            x: bounds.maxX - MenuBarMenuMetrics.rightInset - MenuBarMenuMetrics.switchSize.width,
            y: (boundsHeight - MenuBarMenuMetrics.switchSize.height) / 2,
            width: MenuBarMenuMetrics.switchSize.width,
            height: MenuBarMenuMetrics.switchSize.height
        )

        let labelMaxX = switchControl.frame.minX - MenuBarMenuMetrics.controlGap
        titleLabel.frame = NSRect(
            x: MenuBarMenuMetrics.textX,
            y: (boundsHeight - MenuBarMenuMetrics.labelHeight) / 2,
            width: max(0, labelMaxX - MenuBarMenuMetrics.textX),
            height: MenuBarMenuMetrics.labelHeight
        )
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !switchControl.frame.contains(point) else { return }
        switchControl.setOn(!switchControl.isOn, notify: true)
    }

    @objc private func switchChanged(_ sender: CompactSwitchControl) {
        action(sender.isOn)
    }
}

private final class CompactSwitchControl: NSControl {
    var isOn: Bool = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isOn ? "on" : "off")
        }
    }

    override var intrinsicContentSize: NSSize {
        MenuBarMenuMetrics.switchSize
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOn(_ newValue: Bool, notify: Bool) {
        guard isOn != newValue else { return }
        isOn = newValue
        if notify {
            sendAction(action, to: target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let trackRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let trackPath = NSBezierPath(
            roundedRect: trackRect,
            xRadius: trackRect.height / 2,
            yRadius: trackRect.height / 2
        )
        let trackColor = isOn
            ? NSColor.controlAccentColor.withAlphaComponent(0.82)
            : NSColor.controlColor.withAlphaComponent(0.82)
        trackColor.setFill()
        trackPath.fill()

        NSColor.separatorColor.withAlphaComponent(isOn ? 0.10 : 0.22).setStroke()
        trackPath.lineWidth = 0.5
        trackPath.stroke()

        let knobDiameter = trackRect.height - 4
        let knobX = isOn
            ? trackRect.maxX - knobDiameter - 2
            : trackRect.minX + 2
        let knobRect = NSRect(
            x: knobX,
            y: trackRect.midY - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter
        )
        let knobPath = NSBezierPath(
            roundedRect: knobRect,
            xRadius: knobDiameter / 2,
            yRadius: knobDiameter / 2
        )
        NSColor.white.withAlphaComponent(0.94).setFill()
        knobPath.fill()
    }

    override func mouseDown(with event: NSEvent) {
        setOn(!isOn, notify: true)
    }
}
