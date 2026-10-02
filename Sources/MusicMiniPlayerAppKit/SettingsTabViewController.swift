/**
 * [INPUT]: Depends on AppKit's NSTabViewController (tabStyle .toolbar), on
 *          SettingsWindowState (persisted selected tab) and SettingsTab
 *          (title/icon), and on a page factory (production: SettingsWindowView
 *          hosted per tab).
 * [OUTPUT]: Exports SettingsTabViewController and SettingsTab.symbolName.
 * [POS]: The settings window's page switcher. The native macOS 26 toolbar-tab
 *        strip (SF Symbol over label, accent-tinted selection pill, window
 *        title = page name) replaces the hand-drawn segmented control. The
 *        controller keeps SettingsWindowState.selectedTab and the selected
 *        toolbar item in lock-step in both directions.
 */

import AppKit
import Combine
import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - Tab icons
// ──────────────────────────────────────────────

extension SettingsTab {
    /// SF Symbol for the toolbar tab. (The Player tab is the music app itself: when that app is
    /// installed its real icon replaces the symbol, see `SettingsTabViewController.tabImage`.)
    var symbolName: String {
        switch self {
        case .player: return "music.note"
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .about: return "info.circle"
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case .diagnostics: return "stethoscope"
        #endif
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Controller
// ──────────────────────────────────────────────

@MainActor
final class SettingsTabViewController: NSTabViewController {

    /// Edge of the music app's icon in the toolbar (NSToolbarItem images are 24-32pt; the SF Symbol tabs
    /// are drawn by AppKit at its own tab size).
    static let appIconToolbarSize: CGFloat = 28

    let state: SettingsWindowState
    private let playerApp: PlayerAppIdentity
    private var stateObservation: AnyCancellable?
    /// False until the requested tab has been applied to the loaded tab view:
    /// the load-time reset to the first item must not overwrite `state`.
    private var isSettled = false

    /// `pageFactory` builds one page controller per tab (loaded lazily, when
    /// that tab is first selected).
    init(state: SettingsWindowState, playerApp: PlayerAppIdentity = .appleMusic, pageFactory: (SettingsTab) -> NSViewController) {
        self.state = state
        self.playerApp = playerApp
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.visibleCases {
            let item = NSTabViewItem(viewController: pageFactory(tab))
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = Self.tabImage(for: tab, playerApp: playerApp)
            addTabViewItem(item)
        }
        title = state.selectedTab.title
        // State → toolbar (URL routing, `openSettingsPage`).
        stateObservation = state.$selectedTab.sink { [weak self] tab in
            guard let self else { return }
            let target = self.index(of: tab)
            if self.selectedTabViewItemIndex != target { self.selectedTabViewItemIndex = target }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The tab view resets its selection to the first item while its view loads,
    // so the persisted / requested tab is applied after that.
    override func viewDidLoad() {
        super.viewDidLoad()
        let target = index(of: state.selectedTab)
        if selectedTabViewItemIndex != target { selectedTabViewItemIndex = target }
        title = state.selectedTab.title
        isSettled = true
    }

    /// The toolbar image for `tab`: every tab, Player included, is a monochrome SF Symbol so the toolbar reads as one
    /// family (founder 2026-10-02: the full-colour app icon on the Player tab broke the style). The real player-app
    /// icon stays on the General rows that name the app.
    static func tabImage(for tab: SettingsTab, playerApp: PlayerAppIdentity, provider: PlayerAppIconProvider = .shared) -> NSImage? {
        NSImage(systemSymbolName: tab == .player ? playerApp.fallbackSymbolName : tab.symbolName, accessibilityDescription: tab.title)
    }

    /// Build the pages that are not on screen, once, while the window sits idle. A hidden page's SwiftUI tree
    /// (first body, first layout, the KeyboardShortcuts recorders on Shortcuts, ...) is only instantiated when
    /// its view first reaches a window, which otherwise happens inside the click that switches to it: that is
    /// the tab-switch hitch. Each page is briefly parked in a throwaway off-screen window (never shown), laid
    /// out, and handed back. One page per run-loop turn, spaced out, so no single idle slice is long.
    func prewarmHiddenPages(initialDelay: TimeInterval = 0.6, spacing: TimeInterval = 0.15) {
        let hidden = tabViewItems.enumerated().filter { $0.offset != selectedTabViewItemIndex }.compactMap(\.element.viewController)
        for (i, page) in hidden.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay + spacing * Double(i)) { [weak self, weak page] in
                guard let self, let page, page.view.window == nil, self.tabView.selectedTabViewItem?.viewController !== page else { return }
                let size = page.preferredContentSize.height > 0 ? page.preferredContentSize : NSSize(width: SettingsMetrics.windowWidth, height: 400)
                let parking = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                       styleMask: [.borderless], backing: .buffered, defer: true)
                parking.isReleasedWhenClosed = false
                parking.appearance = self.view.window?.appearance
                let originalFrame = page.view.frame
                parking.contentView = page.view
                page.view.layoutSubtreeIfNeeded()
                page.view.displayIfNeeded()
                parking.contentView = NSView()
                page.view.frame = originalFrame
            }
        }
    }

    private func index(of tab: SettingsTab) -> Int {
        SettingsTab.visibleCases.firstIndex(of: tab) ?? 0
    }

    // Toolbar → state.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard isSettled, let raw = tabViewItem?.identifier as? String, let tab = SettingsTab(rawValue: raw) else { return }
        title = tab.title
        if state.selectedTab != tab { state.selectedTab = tab }
    }

    // MARK: window recipe

    /// Hosts one page so its fitted SwiftUI size becomes `preferredContentSize`,
    /// which is what a toolbar-style tab controller sizes the window to.
    static func hostPage<Page: View>(_ page: Page) -> NSViewController {
        let host = NSHostingController(rootView: page)
        host.sizingOptions = [.preferredContentSize]
        return host
    }

    /// The settings window: fixed size, titled + closable only (HIG Settings
    /// windows do not resize or minimise); its title is the current page's name.
    static func makeWindow(
        state: SettingsWindowState,
        autosaveName: String?,
        playerApp: PlayerAppIdentity = .appleMusic,
        prewarmHiddenPages: Bool = false,
        pageFactory: (SettingsTab) -> NSViewController
    ) -> NSWindow {
        let controller = SettingsTabViewController(state: state, playerApp: playerApp, pageFactory: pageFactory)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        window.isReleasedWhenClosed = false
        // Open at the selected page's size, not the tab view's default 500x500
        // (after the autosave restore, so a frame saved by an older layout can't win).
        controller.view.layoutSubtreeIfNeeded()
        if let page = controller.tabViewItems[safe: controller.selectedTabViewItemIndex]?.viewController,
           page.preferredContentSize.height > 0 {
            window.setContentSize(page.preferredContentSize)
        }
        if prewarmHiddenPages { controller.prewarmHiddenPages() }
        return window
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
