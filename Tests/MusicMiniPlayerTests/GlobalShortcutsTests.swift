/**
 * [INPUT]: MusicMiniPlayerCore GlobalShortcuts (KeyboardShortcuts.Name registry,
 *          GlobalShortcutAction, PanelCommands, GlobalShortcutRegistrar).
 * [OUTPUT]: Verifies no default key combos + dispatch seam routes correctly.
 * [POS]: Tests/MusicMiniPlayerTests.
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import XCTest
import KeyboardShortcuts
@testable import MusicMiniPlayerCore

private final class FakePanelCommands: PanelCommands {
    var togglePanelCallCount = 0
    var hideToEdgeCallCount = 0

    func togglePanel() { togglePanelCallCount += 1 }
    func hideToEdge() { hideToEdgeCallCount += 1 }
}

final class GlobalShortcutsTests: XCTestCase {

    func test_allActionsHaveNoDefaultShortcut() {
        let names = GlobalShortcutAction.allCases.map(\.name)
        KeyboardShortcuts.reset(names)
        for name in names {
            XCTAssertNil(
                KeyboardShortcuts.getShortcut(for: name),
                "\(name.rawValue) must have no default key combo — users record their own"
            )
        }
    }

    func test_allCasesCountAndDistinctNames() {
        XCTAssertEqual(GlobalShortcutAction.allCases.count, 5)
        let names = Set(GlobalShortcutAction.allCases.map(\.name.rawValue))
        XCTAssertEqual(names.count, 5, "all five actions must map to distinct KeyboardShortcuts.Name values")
    }

    func test_dispatchSeam_routesPlaybackActionsToController() {
        let controller = MusicController(preview: true)
        let panel = FakePanelCommands()

        GlobalShortcutRegistrar.handler(for: .togglePlayPause, controller: controller, panel: panel)()
        GlobalShortcutRegistrar.handler(for: .nextTrack, controller: controller, panel: panel)()
        GlobalShortcutRegistrar.handler(for: .previousTrack, controller: controller, panel: panel)()

        // Preview MusicController short-circuits playback side effects; the seam must not crash.
        XCTAssertEqual(panel.togglePanelCallCount, 0)
        XCTAssertEqual(panel.hideToEdgeCallCount, 0)
    }

    func test_dispatchSeam_routesPanelActionsToPanelCommands() {
        let controller = MusicController(preview: true)
        let panel = FakePanelCommands()

        GlobalShortcutRegistrar.handler(for: .togglePanel, controller: controller, panel: panel)()
        GlobalShortcutRegistrar.handler(for: .hideToEdge, controller: controller, panel: panel)()

        XCTAssertEqual(panel.togglePanelCallCount, 1)
        XCTAssertEqual(panel.hideToEdgeCallCount, 1)
    }

    func test_dispatchSeam_toleratesNilControllerAndPanel() {
        // Weak references may already be nil by the time a key fires during teardown.
        GlobalShortcutRegistrar.handler(for: .togglePlayPause, controller: nil, panel: nil)()
        GlobalShortcutRegistrar.handler(for: .togglePanel, controller: nil, panel: nil)()
    }
}
