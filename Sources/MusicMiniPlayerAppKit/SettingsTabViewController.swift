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
    /// SF Symbol for the toolbar tab.
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

    let state: SettingsWindowState
    private var stateObservation: AnyCancellable?
    /// False until the requested tab has been applied to the loaded tab view:
    /// the load-time reset to the first item must not overwrite `state`.
    private var isSettled = false

    /// `pageFactory` builds one page controller per tab (loaded lazily, when
    /// that tab is first selected).
    init(state: SettingsWindowState, pageFactory: (SettingsTab) -> NSViewController) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        for tab in SettingsTab.visibleCases {
            let item = NSTabViewItem(viewController: pageFactory(tab))
            item.identifier = tab.rawValue
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
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

    /// The settings window: fixed size, titled + closable only (HIG Settings
    /// windows do not resize or minimise); its title is the current page's name.
    static func makeWindow(
        state: SettingsWindowState,
        autosaveName: String?,
        pageFactory: (SettingsTab) -> NSViewController
    ) -> NSWindow {
        let controller = SettingsTabViewController(state: state, pageFactory: pageFactory)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        // After the autosave restore: a frame saved by an older layout must not win.
        window.setContentSize(SettingsMetrics.windowSize)
        window.isReleasedWhenClosed = false
        return window
    }
}
