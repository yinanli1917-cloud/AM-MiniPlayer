// ──────────────────────────────────────────────
// SettingsLoginSceneTests — the Launch at Login demo scene (General's first scene): a low-amplitude
// power-on story that plays once when the page appears, then holds; no idle clock afterwards, a still
// under Reduce Motion, a seamless loop while the pointer rests on the row. Fake clocks only; the stage
// rules (one clock at a time, nothing ticking at rest) stay pinned.
// ──────────────────────────────────────────────

import XCTest
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsLoginSceneTests: XCTestCase {

    private let opts = DemoOptions()

    private func login(_ t: Double) -> LoginFrame {
        guard case .login(let f) = SettingsDemo.launchAtLogin.frame(at: t, options: opts) else {
            XCTFail("launchAtLogin must produce a login frame"); return LoginFrame(dim: 0, noteScale: 0, noteOpacity: 0)
        }
        return f
    }

    // MARK: the frames

    func test_quietStart_isAVeil_notABlackout() {
        let f = login(0.3)
        XCTAssertEqual(f.dim, 1)
        XCTAssertEqual(f.noteOpacity, 0)
        XCTAssertEqual(f.panel, 0)
        XCTAssertEqual(f.sweepAlpha, 0)
        XCTAssertLessThanOrEqual(LoginFrame.veil, 0.25, "the not-yet-launched dim stays a soft veil (the old one was 0.62 black)")
    }

    func test_poweredOnRest_isFullyLit_withPanelNoteAndTickedClock() {
        let f = login(SettingsDemo.launchAtLogin.timing.restTime(on: true))
        XCTAssertEqual(f.dim, 0, accuracy: 1e-6)
        XCTAssertEqual(f.panel, 1, accuracy: 1e-6)
        XCTAssertEqual(f.noteOpacity, 1, accuracy: 1e-6)
        XCTAssertEqual(f.noteScale, 1, accuracy: 1e-6)
        XCTAssertEqual(f.clockAlt, 1, accuracy: 1e-6)
        XCTAssertEqual(f.sweepAlpha, 0)
    }

    func test_motionIsVisible_inEveryQuarterSecondOfTheOpening_thenItHolds() {
        // The founder's complaint: the scene read as frozen. From 0.5s to 2.15s (veil lifts, glow sweeps, note pops,
        // clock ticks, panel arrives) something moves in every 0.25s step; after that the lit picture holds until 3.4s.
        var t = 0.5
        while t < 2.15 - 1e-9 {
            let a = login(t), b = login(t + 0.25)
            let moved = a.dim != b.dim || a.sweep != b.sweep || a.noteOpacity != b.noteOpacity
                || a.clockAlt != b.clockAlt || a.panel != b.panel
            XCTAssertTrue(moved, "nothing moves between \(t)s and \(t + 0.25)s")
            t += 0.25
        }
        XCTAssertEqual(login(2.3), login(3.3), "held")
    }

    func test_sweepGlow_travelsAndFades_midStoryOnly() {
        XCTAssertEqual(login(0.55).sweepAlpha, 0, accuracy: 1e-6)
        XCTAssertEqual(login(1.15).sweepAlpha, 1, accuracy: 1e-6, "peak at the middle of the sweep")
        XCTAssertEqual(login(1.75).sweepAlpha, 0, accuracy: 1e-6)
        XCTAssertLessThan(login(0.9).sweep, login(1.4).sweep)
    }

    func test_loop_isSeamless_endStateEqualsStartState() {
        let timing = SettingsDemo.launchAtLogin.timing
        XCTAssertEqual(timing.loop, 5.4)
        // Everything is back at its start before the loop wraps; the last second is calm.
        XCTAssertEqual(login(4.5), login(0.3))
        XCTAssertEqual(login(timing.loop - 0.01), login(0.0))
    }

    func test_replayRanges_landOnTheRestFrames() {
        let timing = SettingsDemo.launchAtLogin.timing
        XCTAssertEqual(timing.restTime(on: true), 3.0)
        XCTAssertEqual(timing.restTime(on: false), 0.3)
        XCTAssertEqual(timing.replayRange(on: true), 0.45...3.0)
        XCTAssertEqual(login(timing.replayRange(on: false)!.upperBound), login(timing.restTime(on: false)))
    }

    // MARK: the intro

    func test_onlyLaunchAtLogin_playsAnIntro() {
        XCTAssertEqual(SettingsDemo.allCases.filter(\.playsIntroOnAppear), [.launchAtLogin])
        XCTAssertEqual(SettingsTab.general.defaultDemo, .launchAtLogin)
    }

    func test_playIntro_runsOnce_endsLit_andLeavesNoIdleClock() {
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        let model = DemoStageModel()
        model.now = { clock }
        model.show(.launchAtLogin)
        XCTAssertFalse(model.hasMountedClock, "a still: no TimelineView")
        model.playIntro(.launchAtLogin)
        XCTAssertTrue(model.hasMountedClock)
        XCTAssertEqual(model.activeClockCount(at: clock), 1)
        guard case .run(let run) = model.frontSlot?.playback else { return XCTFail("intro is a run") }
        XCTAssertEqual(run.kind, .once(from: 0, to: 3.0))
        XCTAssertEqual(run.sceneTime(at: clock, timing: SettingsDemo.launchAtLogin.timing), 0, accuracy: 1e-9)
        clock = clock.addingTimeInterval(1.5)
        XCTAssertEqual(model.activeClockCount(at: clock), 1)
        clock = clock.addingTimeInterval(1.6)   // 3.1s in
        XCTAssertEqual(model.activeClockCount(at: clock), 0, "nothing ticks once the intro has reached its last frame")
        XCTAssertEqual(run.sceneTime(at: clock, timing: SettingsDemo.launchAtLogin.timing), 3.0, accuracy: 1e-9)
        XCTAssertEqual(run.endDate, Date(timeIntervalSinceReferenceDate: 1003))
    }

    func test_playIntro_isIgnored_underReduceMotion_whenAnotherSceneIsUp_orFromAnUnanimatedScene() {
        let model = DemoStageModel()
        model.reduceMotion = true
        model.show(.launchAtLogin)
        model.playIntro(.launchAtLogin)
        XCTAssertFalse(model.hasMountedClock, "Reduce Motion shows a still")

        let other = DemoStageModel()
        other.show(.showInDock)
        other.playIntro(.launchAtLogin)
        XCTAssertEqual(other.frontSlot?.demo, .showInDock)
        XCTAssertFalse(other.hasMountedClock, "never cuts across a scene that is already on stage")

        let still = DemoStageModel()
        still.show(.musicAutomation)
        still.playIntro(.musicAutomation)
        XCTAssertFalse(still.hasMountedClock)
    }

    func test_playIntro_doesNotRestartARunAlreadyPlaying() {
        var clock = Date(timeIntervalSinceReferenceDate: 50)
        let model = DemoStageModel()
        model.now = { clock }
        model.show(.launchAtLogin)
        model.begin(.launchAtLogin, isOn: false)       // the user already hovered the row: a loop
        clock = clock.addingTimeInterval(0.5)
        model.playIntro(.launchAtLogin)
        guard case .run(let run) = model.frontSlot?.playback else { return XCTFail() }
        XCTAssertEqual(run.kind, .loop, "the intro leaves the user's loop alone")
    }
}
