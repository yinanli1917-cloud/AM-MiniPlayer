// ──────────────────────────────────────────────
// MenuBarMenuStructureTests — v3.2 menu redesign
// (docs/design/2026-09-25-menu-settings/proposal.md §3, §5)
//
// Verifies `AppMain.populateMenuBarMenu` produces exactly the native
// NSMenuItem structure the design doc pins: 4 items / 2 separators / 3
// groups, zero checkmarks on the main menu, icons on function items only
// (never alongside a checkmark), a verb-swapped Show/Hide Player title, a
// single-select "Translate To" submenu, and a size ceiling that stands in
// for the doc's own `NSMenu.size` measurements (166×128 EN, no screenshots
// needed — AppKit computes `NSMenu.size` without ever showing the menu).
// ──────────────────────────────────────────────

import XCTest
import AppKit
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore
import KeyboardShortcuts

final class MenuBarMenuStructureTests: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated {
            KeyboardShortcuts.reset(.togglePanel)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    private func makeMenu(app: AppMain) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        app.populateMenuBarMenu(menu)
        return menu
    }

    /// Recursively collects every item in `menu` and its submenus.
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu {
                return [item] + allItems(submenu)
            }
            return [item]
        }
    }

    // MARK: - Structure: 4 items, 2 separators, 3 groups

    @MainActor
    func test_menu_hasFourItemsAndTwoSeparatorsInThreeGroups() {
        let app = AppMain()
        let menu = makeMenu(app: app)

        XCTAssertEqual(menu.items.count, 6, "4 real items + 2 separators")
        XCTAssertFalse(menu.items[0].isSeparatorItem) // Show/Hide Player
        XCTAssertFalse(menu.items[1].isSeparatorItem) // Translate To
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertFalse(menu.items[3].isSeparatorItem) // Settings…
        XCTAssertTrue(menu.items[4].isSeparatorItem)
        XCTAssertFalse(menu.items[5].isSeparatorItem) // Quit nanoPod
    }

    @MainActor
    func test_menu_titlesMatchDesignDoc() {
        let app = AppMain()
        let menu = makeMenu(app: app)

        XCTAssertEqual(menu.items[1].title, L10n.localized("translateTo"))
        XCTAssertEqual(menu.items[3].title, L10n.localized("settings"))
        XCTAssertEqual(menu.items[5].title, L10n.localized("quitApp"))
    }

    /// English copy uses the real ellipsis character (U+2026), never three
    /// literal dots (proposal §5 test 8).
    @MainActor
    func test_titles_useEllipsisCharacter_notThreeLiteralDots() {
        let app = AppMain()
        let menu = makeMenu(app: app)
        let settingsTitle = menu.items[3].title

        XCTAssertFalse(settingsTitle.contains("..."))
        if settingsTitle.contains("Settings") || settingsTitle.contains("设置") {
            XCTAssertTrue(settingsTitle.contains("\u{2026}"))
        }
    }

    // MARK: - Icons: function items only, App items never

    @MainActor
    func test_functionItems_haveTemplateIcons_appItemsDoNot() {
        let app = AppMain()
        let menu = makeMenu(app: app)

        let showHide = menu.items[0]
        let translateTo = menu.items[1]
        let settings = menu.items[3]
        let quit = menu.items[5]

        XCTAssertNotNil(showHide.image, "Show/Hide Player must carry the macwindow icon")
        XCTAssertEqual(showHide.image?.isTemplate, true)
        XCTAssertNotNil(translateTo.image, "Translate To must carry the translate icon")
        XCTAssertEqual(translateTo.image?.isTemplate, true)

        XCTAssertNil(settings.image, "App items (Settings…) never carry an icon")
        XCTAssertNil(quit.image, "App items (Quit) never carry an icon")
    }

    // MARK: - Zero checkmarks on the main menu; never image+checkmark together

    @MainActor
    func test_mainMenuItems_neverChecked() {
        let app = AppMain()
        let menu = makeMenu(app: app)

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertEqual(item.state, .off, "\(item.title) must not be checked — the main menu is zero-checkmark")
        }
    }

    @MainActor
    func test_noItemAnywhere_hasImageAndCheckmarkTogether() {
        let app = AppMain()
        let menu = makeMenu(app: app)

        for item in allItems(menu) where !item.isSeparatorItem {
            let hasImage = item.image != nil
            let isChecked = item.state != .off
            XCTAssertFalse(hasImage && isChecked, "\(item.title) has both an icon and a checkmark")
        }
    }

    // MARK: - "Translate To" submenu: single-select, no icons, tracks translationLanguage

    @MainActor
    func test_translateSubmenu_isSingleSelect_andHasNoIcons() {
        let app = AppMain()
        let menu = makeMenu(app: app)
        guard let submenu = menu.items[1].submenu else {
            return XCTFail("Translate To must have a submenu")
        }

        XCTAssertEqual(submenu.items.count, L10n.translationLanguageOptions.count)
        for item in submenu.items {
            XCTAssertNil(item.image, "Submenu language items carry no icon")
        }

        let checked = submenu.items.filter { $0.state == .on }
        XCTAssertEqual(checked.count, 1, "Exactly one language must be checked")
    }

    @MainActor
    func test_translateSubmenu_checkedItem_matchesCurrentTranslationLanguage() {
        let app = AppMain()
        let previous = LyricsService.shared.translationLanguage
        defer { LyricsService.shared.translationLanguage = previous }

        LyricsService.shared.translationLanguage = "ja"
        let menu = makeMenu(app: app)
        guard let submenu = menu.items[1].submenu else {
            return XCTFail("Translate To must have a submenu")
        }
        let checkedCodes = submenu.items.filter { $0.state == .on }.compactMap { $0.representedObject as? String }
        XCTAssertEqual(checkedCodes, ["ja"])
    }

    // MARK: - Show/Hide Player: verb swap by panel visibility

    @MainActor
    func test_showHidePlayerTitle_defaultsToShow_whenPanelNotVisible() {
        let app = AppMain()
        let menu = makeMenu(app: app)
        XCTAssertEqual(menu.items[0].title, L10n.localized("showPlayer"))
    }

    @MainActor
    func test_showHidePlayerTitle_switchesToHide_whenPanelVisible() {
        let app = AppMain()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        app.floatingWindow = panel

        let menu = makeMenu(app: app)
        XCTAssertEqual(menu.items[0].title, L10n.localized("hidePlayer"))
    }

    // MARK: - keyEquivalent: only Show/Hide Player may carry one, mirroring the user's own recording

    @MainActor
    func test_onlyShowHidePlayer_mayHaveKeyEquivalent_whenNoneRecorded() {
        KeyboardShortcuts.reset(.togglePanel)
        let app = AppMain()
        let menu = makeMenu(app: app)

        XCTAssertEqual(menu.items[0].keyEquivalent, "")
        XCTAssertEqual(menu.items[3].keyEquivalent, "", "Settings… never carries ⌘,")
        XCTAssertEqual(menu.items[5].keyEquivalent, "", "Quit never carries ⌘Q in this menu")
    }

    @MainActor
    func test_showHidePlayer_keyEquivalent_appearsAfterUserRecordsShortcut() {
        KeyboardShortcuts.setShortcut(KeyboardShortcuts.Shortcut(.p, modifiers: [.command, .option]), for: .togglePanel)
        defer { KeyboardShortcuts.reset(.togglePanel) }

        let app = AppMain()
        let menu = makeMenu(app: app)
        XCTAssertNotEqual(menu.items[0].keyEquivalent, "")
    }

    // MARK: - menuWillOpen/menuDidClose gate the global hotkeys

    // NOTE: these tests inject `FakeGlobalShortcutGating` rather than a real
    // `GlobalShortcutRegistrar` — exercising real `KeyboardShortcuts.enable/
    // disable` against an actually-recorded shortcut inside XCTest, outside a
    // full app context, crashes in the library's Carbon HotKey teardown path
    // (verified 2026-09-27: SIGABRT / malloc heap corruption). The fake is the
    // safe, direct observable for "did menuWillOpen/menuDidClose call
    // deactivate()/activate()".

    @MainActor
    func test_menuWillOpen_deactivatesGlobalShortcuts_menuDidClose_reactivates() {
        let app = AppMain()
        let menu = makeMenu(app: app)
        app.menuBarMenu = menu

        let registrar = FakeGlobalShortcutGating()
        app.globalShortcutRegistrar = registrar

        XCTAssertEqual(registrar.activateCount, 0)
        app.menuWillOpen(menu)
        XCTAssertEqual(registrar.deactivateCount, 1)
        XCTAssertEqual(registrar.activateCount, 0)
        app.menuDidClose(menu)
        XCTAssertEqual(registrar.activateCount, 1)
        XCTAssertEqual(registrar.deactivateCount, 1)
    }

    @MainActor
    func test_menuWillOpen_ignoresMenusThatAreNotTheMenuBarMenu() {
        let app = AppMain()
        let menu = makeMenu(app: app)
        app.menuBarMenu = menu

        let registrar = FakeGlobalShortcutGating()
        app.globalShortcutRegistrar = registrar

        let otherMenu = NSMenu()
        app.menuWillOpen(otherMenu)
        XCTAssertEqual(registrar.deactivateCount, 0, "An unrelated menu must not gate global shortcuts")

        app.menuDidClose(otherMenu)
        XCTAssertEqual(registrar.activateCount, 0, "An unrelated menu must not gate global shortcuts")
    }

    // MARK: - Size ceiling (stand-in for the doc's `NSMenu.size` measurements, §3.5)

    @MainActor
    func test_menuSize_staysUnderDesignDocCeiling_whenNoShortcutRecorded() {
        KeyboardShortcuts.reset(.togglePanel)
        let app = AppMain()
        let menu = makeMenu(app: app)

        let size = menu.size
        XCTAssertLessThanOrEqual(size.width, 170, "proposal §3.5 pins 166pt EN/ZH")
        XCTAssertLessThanOrEqual(size.height, 130, "proposal §3.5 pins 128pt")
    }

    // MARK: - No orphaned onboarding entry (proposal §3.6: menu never reads tour state)

    @MainActor
    func test_menu_itemCount_isStable_regardlessOfTourStatus() {
        let app = AppMain()
        let originalStatus = UserDefaults.standard.string(forKey: TourPersistence.statusKey)
        defer {
            if let originalStatus { UserDefaults.standard.set(originalStatus, forKey: TourPersistence.statusKey) }
            else { UserDefaults.standard.removeObject(forKey: TourPersistence.statusKey) }
        }

        UserDefaults.standard.set(TourRunStatus.notStarted.rawValue, forKey: TourPersistence.statusKey)
        let incomplete = makeMenu(app: app)
        UserDefaults.standard.set(TourRunStatus.completed.rawValue, forKey: TourPersistence.statusKey)
        let completed = makeMenu(app: app)

        XCTAssertEqual(incomplete.items.count, completed.items.count)
    }
}

/// Records activate/deactivate calls without ever touching real
/// `KeyboardShortcuts` state — see the crash note above the tests that use it.
@MainActor
private final class FakeGlobalShortcutGating: GlobalShortcutGating {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0

    func activate() { activateCount += 1 }
    func deactivate() { deactivateCount += 1 }
}
