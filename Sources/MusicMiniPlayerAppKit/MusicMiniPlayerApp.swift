/**
 * [INPUT]: Depends on MusicMiniPlayerCore MusicController/LyricsService/SnappablePanel/MiniPlayerView
 *          and SettingsView SettingsWindowView; MetadataResolver.diskCache for the terminate flush.
 * [OUTPUT]: Exports AppMain, the application entry point.
 * [POS]: MusicMiniPlayerApp AppDelegate and window management.
 */

import AppKit
import SwiftUI
import MusicMiniPlayerCore
import KeyboardShortcuts

// ──────────────────────────────────────────────
// MARK: - App Entry
// ──────────────────────────────────────────────

/// macOS menu bar mini player with floating-window support.
public class AppMain: NSObject, NSApplicationDelegate, NSMenuDelegate, PanelCommands {
    static var shared: AppMain!

    /// Extra playback sources passed in by the caller of `main(extraPlaybackSources:)`
    /// (e.g. the full-edition executable). Stored only — not yet wired into any
    /// registry or launch logic; this is skeleton plumbing for a later pass.
    public static private(set) var extraPlaybackSources: [PlaybackSource] = []

    var statusItem: NSStatusItem!
    var menuBarMenu: NSMenu?
    var floatingWindow: NSPanel?
    var settingsWindow: NSWindow?
    /// "认识 nanoPod" — the interactive tour that replaced the C6 three-page
    /// OnboardingWindow (docs/design/2026-09-25-onboarding/proposal.md v3.3).
    /// Constructed once `floatingWindow`/`liquidEdge` exist (createFloatingWindow()).
    var tourController: TourController?
    #if DEBUG || LOCAL_DEVELOPER_BUILD
    var diagnosticsWindow: NSWindow?
    #endif
    let musicController = MusicController.shared
    /// C1 贴边形变（research/c1-edge-morph-design-2026-09-12.md §1/§9 commit 1）：
    /// 计划者偏离设计文档——不把呈现态挂到 `MusicController`，用独立模型，随
    /// `musicController` 一起注入给 SwiftUI 内容层。
    let edgePresentationModel = MainActor.assumeIsolated { EdgePresentationModel() }
    let settingsWindowState = SettingsWindowState()
    private var windowDelegate: FloatingWindowDelegate?
    /// Liquid edge: tucks the panel into a screen edge as one liquid object
    /// (research/spikes/edge-collapse-spike, founder-approved 2026-09-22).
    private var liquidEdge: LiquidEdgeController?
    // Internal (not `private`), and typed as the protocol rather than the
    // concrete class, so menu structure tests can inject a fake and assert
    // `menuWillOpen`/`menuDidClose` toggle it without touching real
    // KeyboardShortcuts hotkey registration (see `GlobalShortcutGating`'s doc).
    var globalShortcutRegistrar: (any GlobalShortcutGating)?
    private var settingsWindowDelegate: SettingsWindowDelegate?
    /// Bumped on every present/dismiss transition of `floatingWindow` so a
    /// pending fade-out's `orderOut` completion can detect it was superseded
    /// by a later show and skip itself (WindowPresentGeneration.shouldApply).
    private var windowPresentGeneration = 0
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

    public static func main(extraPlaybackSources: [PlaybackSource] = []) {
        Self.extraPlaybackSources = extraPlaybackSources
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

    public func applicationDidFinishLaunching(_ notification: Notification) {
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

        let registrar = GlobalShortcutRegistrar(controller: musicController, panel: self)
        registrar.activate()
        globalShortcutRegistrar = registrar

        // ──────────────────────────────────────────────
        // 「认识 nanoPod」引导：非模态自绘卡片，不抢焦点、不改激活策略，绝不
        // 阻塞迷你播放器本身（docs/design/2026-09-25-onboarding/proposal.md）。
        // ──────────────────────────────────────────────
        let launchCount = OnboardingState.shared.incrementLaunchCount()
        tourController?.launchIfNeeded(launchCount: launchCount)

        debugPrint("[AppMain] Setup complete\n")
        E2EEventLog.emit("app_ready", [
            "pid": String(ProcessInfo.processInfo.processIdentifier)
        ])
        E2EStatusDump.writeCurrent()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    public func applicationWillTerminate(_ notification: Notification) {
        E2EEventLog.emit("app_terminating", [
            "pid": String(ProcessInfo.processInfo.processIdentifier)
        ])
        E2EEventLog.flush()
        DiagnosticsService.shared.prepareForTermination()
        // Stop the warm-up sweep BEFORE flushing so no new resolutions
        // race the final cache write (bundle swap must stay last).
        MetadataWarmupSweep.shared.cancel()
        // Metadata cache persists on a debounce — force the pending write
        // out before the process dies.
        MetadataResolver.shared.diskCache.flush()
        // Playback History persists on a debounce too, and a play that
        // crossed the listen threshold in its last second could still be
        // sitting un-committed in PendingPlaybackAccumulator — flush both
        // (2026-09-25 diagnosis fix).
        MusicController.shared.flushPlaybackHistoryForTermination()
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
        case "backdrop":
            // nanopod://backdrop/<fluid|glass|clear> — live-switch the panel backdrop
            // (glass = native Tahoe glass .regular style; clear = native Tahoe glass
            // .clear style, desktop shows through with a single solid tint;
            // unknown values clamp to fluid).
            let style = PanelBackdropStyle.resolve(from: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            UserDefaults.standard.set(style.rawValue, forKey: PanelBackdropStyle.defaultsKey)
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
        case "debug":
            // nanopod://debug/rowdump — one-shot active+previous row text-sublayer dump
            // (CJK trailing-word ghost follow-up). Deliberately available in EVERY build,
            // including plain release — see NativeLyricsRowDump.swift.
            // The remaining nanopod://debug/* paths below are DEBUG/LOCAL_DEVELOPER_BUILD only:
            // nanopod://debug/animsweep — one-shot whole-window animation census
            // (defect 5: names server-side animation survivors on a static panel).
            // nanopod://debug/feel/<appear|blur|sweep>/<v28|current|layer>
            // nanopod://debug/feel/wave/<topdown|sync>
            // nanopod://debug/feel/<hoverCapsule|pressScale|progressHover|shuffleRepeat|buttonFill|windowPresent>/<arm>
            // nanopod://debug/feel/reset — resets both NativeLyricsFeelParity and MicroInteractionFeel
            // nanopod://debug/tour/<show|reset|step/<id>> — force-show, reset, or jump the "认识 nanoPod" tour
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if path == "rowdump" {
                Task { @MainActor in NativeLyricsRowDump.dump() }
            }
            #if DEBUG || LOCAL_DEVELOPER_BUILD
            if path == "animsweep" {
                Task { @MainActor in WindowAnimationCensus.dump() }
            } else if path.hasPrefix("tour/") {
                let action = String(path.dropFirst("tour/".count))
                Task { @MainActor in _ = self.tourController?.handleDebugAction(action) }
            } else if path == "feel/reset" {
                _ = NativeLyricsFeelParity.apply(channel: "reset", value: "reset")
                MicroInteractionFeel.reset()
            } else if path.hasPrefix("feel/") {
                let parts = path.split(separator: "/").map(String.init)
                if parts.count >= 2 {
                    let channel = parts[1]
                    let value = parts.count >= 3 ? parts[2] : "reset"
                    let handled = NativeLyricsFeelParity.apply(channel: channel, value: value)
                    if !handled {
                        _ = MicroInteractionFeel.apply(channel: channel, value: value)
                    }
                }
            }
            #endif
        default:
            break
        }
    }

    /// v3.2: `appearance`/`lyrics` are pre-redesign aliases that now land on the
    /// Player tab (docs/design/2026-09-25-menu-settings/proposal.md §4.4).
    func openSettingsPage(named pageName: String) {
        switch pageName.lowercased() {
        case "", "general":
            showSettingsWindow(selectedTab: .general)
        case "player", "appearance", "lyrics":
            showSettingsWindow(selectedTab: .player)
        case "shortcuts":
            showSettingsWindow(selectedTab: .shortcuts)
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
            resetLiquidEdge()
            floatingWindow?.orderOut(nil)
            musicController.setPanelOccluded(true)
            showMenuBarMenu()
        }
    }

    // MARK: - Floating Window

    func createFloatingWindow() {
        // The window is exactly the panel (founder 2026-09-23; it used to
        // carry an invisible 32pt title-bar strip on top).
        let windowSize = PanelWindowMetrics.defaultSize
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let windowRect = NSRect(
            x: screenFrame.maxX - windowSize.width - 20,
            y: screenFrame.maxY - windowSize.height - 20,
            width: windowSize.width,
            height: windowSize.height
        )

        let snappableWindow = SnappablePanel(
            contentRect: windowRect,
            styleMask: PanelWindowMetrics.styleMask,
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

        // Founder 2026-09-27: frozen at the default size (stage 0 of the
        // resize proposal, docs/design/2026-09-26-resize/proposal.md §9) —
        // no `.resizable` in the style mask above, and min/max pinned to
        // the same size as defense in depth.
        snappableWindow.minSize = PanelWindowMetrics.defaultSize
        snappableWindow.maxSize = PanelWindowMetrics.defaultSize

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

        // C1 贴边形变 hook 接线（research/c1-edge-morph-design-2026-09-12.md §9
        // commit 1）：几何弹簧的起播/落定信号译成 `SnapEvent`，喂给独立的
        // `edgePresentationModel`（偏离设计文档 §1 的 MusicController 挂载方案）。
        snappableWindow.onGeometryMorphWillStart = { [weak self, weak snappableWindow] event, time in
            guard let self else { return }
            MainActor.assumeIsolated {
            let before = self.edgePresentationModel.presentation
            self.edgePresentationModel.apply(event)
            // commit 2 一行钩子：把 SnappablePanel 已公开的 hiddenEdge 镜像进
            // EdgePresentationModel，SnappablePanel.swift 本身不改动。
            if let hiddenEdge = snappableWindow?.hiddenEdge {
                let mirrored: SnappedEdge
                switch hiddenEdge {
                case .none: mirrored = .none
                case .left: mirrored = .left
                case .right: mirrored = .right
                }
                self.edgePresentationModel.updateSnappedEdge(mirrored)
            }
            #if DEBUG
            let after = self.edgePresentationModel.presentation
            DebugLogger.log(
                "EdgeMorph",
                "t=\(time) clock=geometry event=\(event) state=\(before)→\(after)"
            )
            #endif
            }
        }
        snappableWindow.onGeometryMorphDidSettle = { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
            let before = self.edgePresentationModel.presentation
            self.edgePresentationModel.apply(.settled)
            #if DEBUG
            let after = self.edgePresentationModel.presentation
            DebugLogger.log(
                "EdgeMorph",
                "t=\(time) clock=geometry event=settled state=\(before)→\(after)"
            )
            #endif
            }
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
        .environmentObject(edgePresentationModel)

        // Pages keep the exact layout they were tuned in (PanelWindowMetrics).
        snappableWindow.contentView = MainActor.assumeIsolated { PanelWindowMetrics.makeContentView(root: contentView) }

        MainActor.assumeIsolated {
            let liquidEdge = LiquidEdgeController(card: snappableWindow)
            liquidEdge.onPanelOccluded = { [weak self] in self?.musicController.setPanelOccluded($0) }
            snappableWindow.liquidEdgeHandler = { [weak liquidEdge] edge in
                MainActor.assumeIsolated { liquidEdge?.collapse(to: edge) ?? false }
            }
            self.liquidEdge = liquidEdge
            self.tourController = TourController(panel: snappableWindow, liquidEdge: liquidEdge)
        }

        debugPrint("[AppMain] Floating window created\n")
    }

    func showFloatingWindow(revealNearbySnapPosition: Bool = false) {
        guard let window = floatingWindow else { return }
        resetLiquidEdge()
        isFloatingMode = true
        NSApp.activate(ignoringOtherApps: true)
        presentFloatingWindow(window, makeKey: true)

        if revealNearbySnapPosition, let snappableWindow = window as? SnappablePanel {
            snappableWindow.revealAtNearbySnapPosition()
        }
        musicController.setPanelOccluded(false)
    }

    func toggleFloatingWindow() {
        guard let window = floatingWindow else { return }
        // Tucked into an edge: bring the panel back out of it.
        if MainActor.assumeIsolated({ liquidEdge?.isActive == true }) {
            MainActor.assumeIsolated { liquidEdge?.expand() }
            return
        }

        if window.isVisible {
            dismissFloatingWindow(window)
            musicController.setPanelOccluded(true)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            presentFloatingWindow(window, makeKey: false)
            musicController.setPanelOccluded(false)
        }
    }

    /// PanelCommands conformance for GlobalShortcutRegistrar (nanoPod.togglePanel).
    public func togglePanel() {
        toggleFloatingWindow()
    }

    /// PanelCommands conformance for GlobalShortcutRegistrar (nanoPod.hideToEdge).
    public func hideToEdge() {
        if MainActor.assumeIsolated({ liquidEdge?.isActive == true }) {
            MainActor.assumeIsolated { liquidEdge?.expand() }
            return
        }
        (floatingWindow as? SnappablePanel)?.hideToNearestEdge()
    }

    /// Any other hide/show path puts the panel back to normal first.
    private func resetLiquidEdge() {
        MainActor.assumeIsolated { liquidEdge?.reset() }
    }

    /// Collapses the floating window back to the menu bar.
    func collapseToMenuBar() {
        resetLiquidEdge()
        isFloatingMode = false
        if let window = floatingWindow {
            dismissFloatingWindow(window)
        }
        musicController.setPanelOccluded(true)
        showMenuBarMenu()
    }

    /// Entry point for `FloatingWindowDelegate.windowShouldClose` (a different
    /// class), which needs the same fade-out treatment as the other hide paths.
    func dismissFloatingWindowFromDelegate(_ window: NSPanel) {
        dismissFloatingWindow(window)
    }

    // MARK: - Window Present/Dismiss Animation (windowPresent feel channel)

    /// `.fade` arm fades the window in from alpha 0 (unless Reduce Motion is
    /// on, which always hard-cuts). `.hardcut` arm is the original
    /// `makeKeyAndOrderFront`/`orderFront` behaviour, untouched.
    private func presentFloatingWindow(_ window: NSPanel, makeKey: Bool) {
        let generation = WindowPresentGeneration.advance(&windowPresentGeneration)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard WindowPresentPolicy.resolve(arm: MicroInteractionFeel.windowPresent, reduceMotion: reduceMotion) else {
            window.alphaValue = 1
            if makeKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
            return
        }

        window.alphaValue = 0
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self, WindowPresentGeneration.shouldApply(token: generation, currentGeneration: self.windowPresentGeneration) else { return }
            context.duration = MicroInteractionFeel.Tokens.windowFadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// `.fade` arm fades alpha to 0 then `orderOut`s in the completion,
    /// restoring alpha to 1 afterward so no other code path ever observes a
    /// visible-but-transparent window. A show requested while the fade is
    /// still pending bumps `windowPresentGeneration`, so this completion
    /// no-ops instead of hiding the window the newer show just presented.
    private func dismissFloatingWindow(_ window: NSPanel) {
        let generation = WindowPresentGeneration.advance(&windowPresentGeneration)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard WindowPresentPolicy.resolve(arm: MicroInteractionFeel.windowPresent, reduceMotion: reduceMotion) else {
            window.orderOut(nil)
            window.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MicroInteractionFeel.Tokens.windowFadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            guard let self, let window else { return }
            guard WindowPresentGeneration.shouldApply(token: generation, currentGeneration: self.windowPresentGeneration) else { return }
            window.orderOut(nil)
            window.alphaValue = 1
        })
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

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === menuBarMenu else { return }
        populateMenuBarMenu(menu)
    }

    /// KeyboardShortcuts requires disabling the global hotkeys while an
    /// `NSMenu` is open (`NSMenu` puts the run loop in tracking mode, which
    /// would buffer the keyboard event and fire it only after the menu
    /// closes) — see `NSMenuItem.setShortcut(for:)`'s doc comment.
    public func menuWillOpen(_ menu: NSMenu) {
        guard menu === menuBarMenu else { return }
        MainActor.assumeIsolated { globalShortcutRegistrar?.deactivate() }
    }

    public func menuDidClose(_ menu: NSMenu) {
        guard menu === menuBarMenu else { return }
        MainActor.assumeIsolated { globalShortcutRegistrar?.activate() }
    }

    /// v3.2 定稿（docs/design/2026-09-25-menu-settings/proposal.md §3.1）：
    /// 4 项 3 组，零勾选（含子菜单项以外任何一行都不设 `state`），只有 #1/#2
    /// 两个功能项带图标（App 项「设置…」「退出 nanoPod」不带——CleanShot 的
    /// About/Settings/Quit 无图标惯例），没有随状态增减的临时项。
    // Internal (not `private`) so MenuBarMenuStructureTests can call it directly
    // against a hand-built NSMenu without going through applicationDidFinishLaunching.
    func populateMenuBarMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Group 1: 面板动作——显示/隐藏面板 · 翻译为 ▸
        menu.addItem(makeShowHidePlayerItem())
        menu.addItem(makeTranslationTargetSubmenuItem())

        menu.addItem(.separator())

        // Group 2: App 项——设置…
        menu.addItem(makePlainMenuItem(
            title: L10n.localized("settings"),
            action: #selector(openSettings(_:))
        ))

        menu.addItem(.separator())

        // Group 3: 退出
        //
        // Routed through a wrapper selector (not the literal
        // `#selector(NSApplication.terminate(_:))` + `target: NSApp` pair)
        // because macOS 26 pattern-matches on that exact signature and
        // silently attaches its own "Quit_app" system icon to the item —
        // which would violate "App 项不带图标" and push the measured menu
        // width from 166pt to 172pt (proposal §3.5's "若 App 项也带图标" row).
        menu.addItem(makePlainMenuItem(
            title: L10n.localized("quitApp"),
            action: #selector(quitFromMenu(_:))
        ))
    }

    @objc private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// #1 — 面板可见且未贴边 → 「Hide Player」；否则「Show Player」（动词换标题，
    /// 不留勾选）。图标 `macwindow`，键位显示用户自己录的「显示/隐藏面板」快捷键
    /// （`setShortcut(for: .togglePanel)`），未录则空——不写死 ⌥⌘P 等默认组合。
    private func makeShowHidePlayerItem() -> NSMenuItem {
        let isPanelShown = (floatingWindow?.isVisible == true) && MainActor.assumeIsolated({ liquidEdge?.isActive != true })
        let title = L10n.localized(isPanelShown ? "hidePlayer" : "showPlayer")
        let item = NSMenuItem(title: title, action: #selector(showWindowFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.setShortcut(for: .togglePanel)
        applyFunctionItemIcon(item, systemImageName: "macwindow", accessibilityDescription: title)
        return item
    }

    /// #2 — 「翻译为 ▸」子菜单：单选勾选（`state`），不带图标；父项本身带 `translate`
    /// 图标、无勾选、无快捷键。子菜单内的勾选不影响父菜单宽度（已实测，proposal §3.2）。
    private func makeTranslationTargetSubmenuItem() -> NSMenuItem {
        let currentLanguage = LyricsService.shared.translationLanguage
        let selectedCode = currentLanguage == L10n.systemLanguageCode ? "system" : currentLanguage
        let title = L10n.localized("translateTo")

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        applyFunctionItemIcon(item, systemImageName: "translate", accessibilityDescription: title)

        let submenu = NSMenu(title: title)
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

    /// App 项（设置…、退出 nanoPod）：无图标、无勾选、无 `keyEquivalent`
    /// （只在菜单打开期间生效，是个空承诺——proposal §3.3）。
    private func makePlainMenuItem(
        title: String,
        action: Selector?,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    /// 功能项图标：系统符号、`isTemplate`，不加 `SymbolConfiguration`——尺寸、
    /// 粗细全交给系统按菜单符号规格绘制（proposal §3.2「图标…不加 SymbolConfiguration」）。
    private func applyFunctionItemIcon(_ item: NSMenuItem, systemImageName: String, accessibilityDescription: String) {
        guard let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: accessibilityDescription) else { return }
        image.isTemplate = true
        item.image = image
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
        window.title = L10n.isSystemChinese ? "设置" : "Settings"
        // v3.2: no resize, no minimize (HIG Settings windows are fixed-size);
        // the content view itself is a hard 480×562 (proposal §4.2).
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 480, height: 562))
        window.setFrameAutosaveName("Settings")
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

    // MARK: - "认识 nanoPod" Tour

    /// Settings › 通用's "接着认识 nanoPod" / "重新认识 nanoPod" row.
    @MainActor
    func showTour(fromStart: Bool) {
        tourController?.requestTour(fromStart: fromStart)
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

        let aboutItem = NSMenuItem(title: "About nanoPod", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide nanoPod", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit nanoPod", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        if let panel = sender as? NSPanel, let app = AppMain.shared, panel === app.floatingWindow {
            app.dismissFloatingWindowFromDelegate(panel)
        } else {
            sender.orderOut(nil)
        }
        AppMain.shared?.musicController.setPanelOccluded(true)
        return false
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let occluded = !window.isVisible || !window.occlusionState.contains(.visible)
        MusicController.shared.setPanelOccluded(occluded)
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

