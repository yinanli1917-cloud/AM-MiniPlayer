// ──────────────────────────────────────────────
// SettingsTabSwitchPerfTests — main-thread cost of switching Settings tabs in a REAL window
// (production page factory and production permission / login-status providers, a MusicController
// in preview mode). A main-run-loop observer records every busy slice (after-waiting to
// before-waiting) around each switch, which is one frame's worth of main-thread work while the
// window-resize animation runs; the synchronous cost of the switch itself (hosting controller
// view load, first SwiftUI layout, first body evaluation) is timed separately.
//
// Opt-in measurement (set NANOPOD_TAB_SWITCH_PERF=1; results go to stdout as SGPERF lines and to
// $NANOPOD_TAB_SWITCH_PERF_OUT when set). Numbers are from the DEBUG test build, so absolute
// values run higher than the shipping app; compare before / after on the same build.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
import KeyboardShortcuts
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsTabSwitchPerfTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsPalette.accentOverride = SettingsPalette.brandAccent
    }

    override func tearDown() {
        SettingsPalette.accentOverride = nil
        L10n.languageOverride = nil
        super.tearDown()
    }

    /// Busy slices of the main run loop between `start()` and `stop()`.
    final class BusyRecorder {
        struct Slice { let offset: Double; let duration: Double }
        private(set) var slices: [Slice] = []
        private var observers: [CFRunLoopObserver] = []
        private var sliceStart: CFAbsoluteTime = 0
        private var origin: CFAbsoluteTime = 0

        /// One slice = the run loop waking (first observer in line) to just before it sleeps again (last
        /// observer in line, AFTER Core Animation's commit: layout, display and the frame's render submit).
        func start() {
            origin = CFAbsoluteTimeGetCurrent()
            slices = []
            let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
                self?.sliceStart = CFAbsoluteTimeGetCurrent()
            }
            let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
                guard let self, self.sliceStart > 0 else { return }
                self.slices.append(Slice(offset: self.sliceStart - self.origin, duration: CFAbsoluteTimeGetCurrent() - self.sliceStart))
                self.sliceStart = 0
            }
            for o in [wake, sleep].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
                observers.append(o)
            }
        }

        func stop() {
            for o in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
            observers = []
        }
    }

    struct Result {
        let label: String
        let syncMs: Double
        let slices: Int
        let maxMs: Double
        let p95Ms: Double
        let over16: Int
        let worst: [BusyRecorder.Slice]
    }

    private func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// The production window: real page factory, real providers (no test injection).
    private func makeProductionLikeWindow(state: SettingsWindowState, prewarm: Bool) -> NSWindow {
        let musicController = MusicController(preview: true)
        let window = SettingsTabViewController.makeWindow(state: state, autosaveName: nil, prewarmHiddenPages: prewarm) { tab in
            SettingsTabViewController.hostPage(
                SettingsWindowView(state: state, tab: tab).environmentObject(musicController))
        }
        if ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_NOTRANSITION"] != nil,
           let tabs = window.contentViewController as? NSTabViewController { tabs.transitionOptions = [] }
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 24, y: screen.visibleFrame.minY + 24))
        }
        window.level = .floating
        window.orderFront(nil)
        return window
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private func measureSwitch(_ label: String, to tab: SettingsTab, state: SettingsWindowState, settle: Double = 1.6) -> Result {
        let recorder = BusyRecorder()
        recorder.start()
        var syncMs = 0.0
        // As in the app: the click arrives as an event on the main run loop, so the switch's own
        // synchronous work is one busy slice (and shows up in the slice list below).
        DispatchQueue.main.async {
            let t0 = CFAbsoluteTimeGetCurrent()
            state.selectedTab = tab
            syncMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        spin(settle)
        recorder.stop()
        // Slices that carry real work (a bare timer / display-link wake is well under 0.3 ms).
        let work = recorder.slices.filter { $0.duration >= 0.0003 }
        let ms = work.map { $0.duration * 1000 }
        return Result(label: label, syncMs: syncMs, slices: work.count,
                      maxMs: ms.max() ?? 0, p95Ms: percentile(ms, 0.95),
                      over16: ms.filter { $0 > 16.7 }.count,
                      worst: Array(work.sorted { $0.duration > $1.duration }.prefix(4)))
    }

    func test_measure_tabSwitch_realWindow() throws {
        guard ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_PERF"] != nil else {
            throw XCTSkip("set NANOPOD_TAB_SWITCH_PERF=1 to measure tab-switch main-thread cost")
        }
        L10n.languageOverride = "en"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "nanopod.test.tab-perf.\(UUID().uuidString)"))
        let state = SettingsWindowState(defaults: defaults)
        state.selectedTab = .player
        let t0 = CFAbsoluteTimeGetCurrent()
        let prewarm = ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_PERF_PREWARM"] != "0"
        let window = makeProductionLikeWindow(state: state, prewarm: prewarm)
        let openMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        spin(1.5)   // let the window and the first page settle

        if let loops = ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_LOOP"].flatMap(Int.init) {
            // Profiling aid: keep switching so an external `sample` has something to look at.
            for _ in 0..<loops {
                for tab in [SettingsTab.general, .shortcuts, .player] { state.selectedTab = tab; spin(0.35) }
            }
        }
        if ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_PROBE_PREWARM"] != nil,
           let tabs = window.contentViewController as? NSTabViewController {
            for item in tabs.tabViewItems where !(item.viewController?.isViewLoaded ?? true) {
                let t = CFAbsoluteTimeGetCurrent()
                item.viewController?.loadViewIfNeeded()
                let t1 = CFAbsoluteTimeGetCurrent()
                item.viewController?.view.layoutSubtreeIfNeeded()
                print(String(format: "SGPERF prewarm %@: load %.1f ms, layout %.1f ms", item.label, (t1 - t) * 1000, (CFAbsoluteTimeGetCurrent() - t1) * 1000))
            }
        }
        var results: [Result] = []
        results.append(measureSwitch("player -> general (cold)", to: .general, state: state))
        results.append(measureSwitch("general -> shortcuts (cold)", to: .shortcuts, state: state))
        results.append(measureSwitch("shortcuts -> about (cold)", to: .about, state: state))
        results.append(measureSwitch("about -> player (warm)", to: .player, state: state))
        results.append(measureSwitch("player -> general (warm)", to: .general, state: state))
        results.append(measureSwitch("general -> shortcuts (warm)", to: .shortcuts, state: state))
        results.append(measureSwitch("shortcuts -> general (warm)", to: .general, state: state))
        window.close()

        var lines = ["SGPERF window open (sync): \(String(format: "%.1f", openMs)) ms"]
        lines.append("SGPERF " + "switch".padding(toLength: 30, withPad: " ", startingAt: 0) + "sync_ms  slices  max_ms  p95_ms  >16.7ms  worst slices (offset s: ms)")
        for r in results {
            let worst = r.worst.map { String(format: "%.2f:%.1f", $0.offset, $0.duration * 1000) }.joined(separator: " ")
            lines.append("SGPERF " + r.label.padding(toLength: 30, withPad: " ", startingAt: 0)
                + String(format: "%7.1f  %6d  %6.1f  %6.1f  %7d  ", r.syncMs, r.slices, r.maxMs, r.p95Ms, r.over16) + worst)
        }
        let all = results.flatMap { $0.worst }.count
        _ = all
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_PERF_OUT"] {
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}

extension SettingsTabSwitchPerfTests {

    /// What the General page's body reads on EVERY evaluation, timed one by one on the main thread.
    func test_measure_generalPageBodyReads() throws {
        guard ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_PERF"] != nil else {
            throw XCTSkip("set NANOPOD_TAB_SWITCH_PERF=1 to measure tab-switch main-thread cost")
        }
        func time(_ label: String, repeats: Int = 20, _ body: () -> Void) -> String {
            body()   // warm
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<repeats { body() }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(repeats)
            return "SGPERF read  " + label.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%7.3f ms/call", ms)
        }
        var lines: [String] = []
        lines.append(time("OnboardingState.automationStatus (AE TCC query)") { _ = OnboardingState.shared.automationStatus })
        lines.append(time("OnboardingState.musicKitStatus") { _ = OnboardingState.shared.musicKitStatus })
        lines.append(time("LaunchAtLoginBridge.status (SMAppService)") { _ = LaunchAtLoginBridge.status })
        lines.append(time("KeyboardShortcuts.getShortcut x5") {
            for action in GlobalShortcutAction.allCases { _ = KeyboardShortcuts.getShortcut(for: action.name) }
        })
        lines.append(time("TourPersistence.load()") { _ = TourPersistence.load() })
        let text = lines.joined(separator: "\n")
        print(text)
        if let out = ProcessInfo.processInfo.environment["NANOPOD_TAB_SWITCH_PERF_OUT"] {
            try text.write(toFile: out + ".reads", atomically: true, encoding: .utf8)
        }
    }
}
