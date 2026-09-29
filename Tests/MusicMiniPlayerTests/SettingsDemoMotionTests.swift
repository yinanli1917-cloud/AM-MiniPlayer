// ──────────────────────────────────────────────
// SettingsDemoMotionTests — the settings demo stage's motion contract
// (docs/design/2026-09-29-motion-prototype/spec.md §A.4 / §A.6 / §A.8 / §A.10).
//
//  - render(t): scenes are pure functions of scene time; keyframe values equal the
//    prototype's, rest frames are the effect's end / start state, loops are seamless;
//  - idle = zero animation and zero timers; a hover commit mounts exactly one clock,
//    switching rows freezes the outgoing scene, leaving lets the loop finish on its
//    rest frame and the clock's schedule then ENDS;
//  - Reduce Motion: stills only.
// Fake clock throughout — nothing sleeps.
// ──────────────────────────────────────────────

import XCTest
import SwiftUI
@testable import MusicMiniPlayerAppKit
@testable import MusicMiniPlayerCore

@MainActor
final class SettingsDemoMotionTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let animated: [SettingsDemo] = SettingsDemo.allCases.filter { $0.timing.isAnimated }

    // MARK: easing + keyframes

    func test_easing_matchesThePrototypeCurves() {
        XCTAssertEqual(DemoEase.io.value(0.5), 0.5, accuracy: 1e-4)
        XCTAssertEqual(DemoEase.io.value(0), 0)
        XCTAssertEqual(DemoEase.io.value(1), 1)
        XCTAssertEqual(DemoEase.out.value(0.219), 0.72, accuracy: 0.01, "cubic-bezier(.2,.8,.2,1) at x=.219")
        var last = 0.0
        for i in 0...100 {   // monotonic: no overshoot
            let v = DemoEase.io.value(Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, last)
            last = v
        }
    }

    private func cover(_ t: Double) -> CoverFrame {
        guard case .cover(let f) = SettingsDemo.fullscreenCover.frame(at: t, options: DemoOptions()) else { fatalError() }
        return f
    }

    func test_cover_keyframes() {
        XCTAssertEqual(cover(0.9).s, 0)
        XCTAssertEqual(cover(1.35).s, 0.5, accuracy: 1e-3, "middle of the 0.9s ease")
        XCTAssertEqual(cover(1.8).s, 1, accuracy: 1e-9)
        XCTAssertEqual(cover(3.9).s, 1)
        XCTAssertEqual(cover(4.35).s, 0.5, accuracy: 1e-3)
        XCTAssertEqual(cover(4.8).s, 0, accuracy: 1e-9)
        // Derived geometry at both ends (em): inset cover with margins, filled cover, fade band 0 → 40%.
        XCTAssertEqual(cover(0.3).artSide, 0.68, accuracy: 1e-9)
        XCTAssertEqual(cover(0.3).artTop, 0.075, accuracy: 1e-9)
        XCTAssertEqual(cover(0.3).fadeBand, 0, accuracy: 1e-9)
        XCTAssertEqual(cover(2.7).artSide, 1, accuracy: 1e-9)
        XCTAssertEqual(cover(2.7).artTop, 0, accuracy: 1e-9)
        XCTAssertEqual(cover(2.7).fadeBand, 0.4, accuracy: 1e-9)
        XCTAssertEqual(cover(2.7).artOpacityAtBottom, 0, accuracy: 1e-9, "the cover's bottom dissolves into the colour underlay")
        XCTAssertEqual(cover(2.7).blurUnderlayOpacity, 1, accuracy: 1e-9)
        XCTAssertFalse(cover(2.7).artHasShadow)
    }

    func test_peek_keyframes() {
        func frame(_ t: Double, on: Bool = true) -> PeekFrame {
            var o = DemoOptions(); o.isOn = on
            guard case .peek(let f) = SettingsDemo.edgeShowSongOnTrackChange.frame(at: t, options: o) else { fatalError() }
            return f
        }
        XCTAssertEqual(frame(0.3).panelOffsetX, 0)
        XCTAssertEqual(frame(2.0).panelOffsetX, 170, "tucked past the screen edge")
        XCTAssertEqual(frame(2.0).stripOpacity, 1)
        XCTAssertEqual(frame(2.8).pulse, 1, accuracy: 1e-9, "the strip lights at the track change")
        XCTAssertEqual(frame(4.5).cp, 1, "the card holds 2.5s (3.2 → 5.7)")
        XCTAssertEqual(frame(3.2).cp, 1)
        XCTAssertEqual(frame(5.7).cp, 1)
        XCTAssertEqual(frame(4.5, on: false).cp, 0, "switch off: no card, the strip alone")
        XCTAssertEqual(frame(4.5, on: false).stripOpacity, 1)
        XCTAssertEqual(frame(0.3).fillPercent, 62)
        XCTAssertEqual(frame(2.4).fillPercent, 8, accuracy: 1e-9, "new song: the progress light restarts")
    }

    func test_translation_keyframes() {
        func frame(_ t: Double) -> LyricsFrame {
            guard case .lyrics(let f) = SettingsDemo.showTranslation.frame(at: t, options: DemoOptions()) else { fatalError() }
            return f
        }
        XCTAssertEqual(frame(1.0).s, 0)
        XCTAssertEqual(frame(1.0).followingLinesOffsetY, 0)
        XCTAssertEqual(frame(1.0).translationBlur, 1.6, accuracy: 1e-9)
        XCTAssertEqual(frame(2.0).s, 1, accuracy: 1e-6)
        XCTAssertEqual(frame(2.0).followingLinesOffsetY, 20, accuracy: 1e-4, "the two lines below make room for one translation line")
        XCTAssertEqual(frame(2.0).translationOffsetY, 0, accuracy: 1e-4)
    }

    func test_translateTo_cyclesLanguagesWithAShortCrossFade() {
        let texts = DemoOptions.defaultTranslations
        func frame(_ t: Double) -> LyricsFrame {
            guard case .lyrics(let f) = SettingsDemo.translateTo.frame(at: t, options: DemoOptions()) else { fatalError() }
            return f
        }
        XCTAssertEqual(frame(1.2).textA, texts[0])
        XCTAssertEqual(frame(1.2).opacityA, 1)
        XCTAssertEqual(frame(1.7 + 1.2).textA, texts[1])
        XCTAssertEqual(frame(1.7 + 1.2).textB, texts[0])
        XCTAssertEqual(frame(1.7 + 0.15).opacityA, 0.5, accuracy: 0.05, "mid cross-fade")
        XCTAssertEqual(frame(1.7 + 0.5).opacityA, 1, "0.3s fade done, then a hold")
        XCTAssertEqual(frame(3 * 1.7 + 1).textA, texts[3])
    }

    func test_showHide_keyPressAndPanelFade() {
        func frame(_ t: Double) -> ShowHideFrame {
            var o = DemoOptions(); o.keyLabels = ["\u{2325}", "\u{2318}", "P"]
            guard case .showHide(let f) = SettingsDemo.showHidePlayerShortcut.frame(at: t, options: o) else { fatalError() }
            return f
        }
        XCTAssertEqual(frame(0.3).press, 0)
        XCTAssertEqual(frame(1.07).press, 1, accuracy: 1e-9, "key bottoms out 0.17s into the 0.34s press")
        XCTAssertEqual(frame(1.6).panelOpacity, 0, accuracy: 1e-6)
        XCTAssertEqual(frame(1.6).panelScale, 0.955, accuracy: 1e-6)
        XCTAssertEqual(frame(3.57).press, 1, accuracy: 1e-9, "second press")
        XCTAssertEqual(frame(5.0).panelOpacity, 1, accuracy: 1e-6)
        XCTAssertEqual(frame(0.3).keys, ["\u{2325}", "\u{2318}", "P"])
    }

    func test_keyLabels_splitModifiersFromTheKey() {
        XCTAssertEqual(DemoOptions.keyLabels(from: "\u{2325}\u{2318}P"), ["\u{2325}", "\u{2318}", "P"])
        XCTAssertEqual(DemoOptions.keyLabels(from: "\u{21E7}Space"), ["\u{21E7}", "Space"])
        XCTAssertEqual(DemoOptions.keyLabels(from: ""), [])
        XCTAssertEqual(DemoOptions.translations(startingWith: "Hola").count, 4)
        XCTAssertEqual(DemoOptions.translations(startingWith: "Hola").first, "Hola")
        XCTAssertEqual(DemoOptions.translations(startingWith: DemoOptions.defaultTranslations[0]), DemoOptions.defaultTranslations)
    }

    // MARK: rest frames + seamless loops

    func test_restFrames_areTheEffectsEndAndStartStates() {
        XCTAssertEqual(cover(SettingsDemo.fullscreenCover.timing.restTime(on: true)).s, 1)
        XCTAssertEqual(cover(SettingsDemo.fullscreenCover.timing.restTime(on: false)).s, 0)
        for on in [true, false] {
            var o = DemoOptions(); o.isOn = on
            guard case .peek(let p) = SettingsDemo.edgeShowSongOnTrackChange.frame(at: SettingsDemo.edgeShowSongOnTrackChange.timing.restTime(on: on), options: o),
                  case .lyrics(let l) = SettingsDemo.showTranslation.frame(at: SettingsDemo.showTranslation.timing.restTime(on: on), options: o)
            else { return XCTFail() }
            XCTAssertEqual(p.cp, on ? 1 : 0, accuracy: 1e-9)
            XCTAssertEqual(l.s, on ? 1 : 0, accuracy: 1e-6)
        }
        guard case .showHide(let s) = SettingsDemo.showHidePlayerShortcut.frame(at: SettingsDemo.showHidePlayerShortcut.timing.restTime(on: true), options: DemoOptions()) else { return XCTFail() }
        XCTAssertEqual(s.press, 0)
        XCTAssertEqual(s.panelOpacity, 1)
    }

    func test_everyLoop_isSeamless() {
        for demo in animated {
            let loop = demo.timing.loop
            var o = DemoOptions(); o.keyLabels = ["\u{2318}"]
            let start = demo.frame(at: 0, options: o), end = demo.frame(at: loop, options: o)
            if case .lyrics(let a) = start, case .lyrics(let b) = end, demo == .translateTo {
                // The last language is fully shown at both ends (as the fading-out B at 0, as A at the end).
                let last = DemoOptions.defaultTranslations[3]
                XCTAssertEqual(b.textA == last ? b.opacityA : b.opacityB, 1, accuracy: 1e-6)
                XCTAssertEqual(a.textB == last ? a.opacityB : a.opacityA, 1, accuracy: 1e-6)
            } else if case .peek(let a) = start, case .peek(let b) = end {
                // Only the progress light differs, and the strip carrying it is invisible at both ends.
                XCTAssertEqual(a.stripOpacity, 0); XCTAssertEqual(b.stripOpacity, 0)
                XCTAssertEqual(a.panelOffsetX, b.panelOffsetX, accuracy: 1e-9)
                XCTAssertEqual(a.cardOpacity, b.cardOpacity, accuracy: 1e-9)
            } else {
                XCTAssertEqual(start, end, "\(demo.rawValue): frame(0) must equal frame(loop)")
            }
        }
    }

    func test_nextRest_landsOnTheRestPhase_strictlyAfterNow() {
        for demo in animated {
            let timing = demo.timing
            for on in [true, false] {
                for t in stride(from: 0.0, through: timing.loop * 2.5, by: 0.37) {
                    let stop = timing.nextRest(after: t, on: on)
                    XCTAssertGreaterThan(stop, t)
                    let phase = (stop - timing.restTime(on: on)) / timing.loop
                    XCTAssertEqual(phase, phase.rounded(), accuracy: 1e-9, "\(demo.rawValue) t=\(t)")
                    XCTAssertLessThanOrEqual(stop - t, timing.loop + 1e-9)
                }
            }
        }
    }

    func test_switchReplay_neverRunsPastItsRestFrame() {
        for demo in animated {
            for on in [true, false] {
                guard let range = demo.timing.replayRange(on: on) else { continue }
                XCTAssertLessThan(range.lowerBound, range.upperBound)
                if on { XCTAssertLessThanOrEqual(range.upperBound, max(demo.timing.restTime(on: true), range.lowerBound), demo.rawValue) }
            }
        }
        // The prototype's peek range overshoots (…5.9) its own rest frame (5.0), where the card is already leaving.
        XCTAssertEqual(SettingsDemo.edgeShowSongOnTrackChange.timing.replayRange(on: true), 1.9...5.0)
        XCTAssertNil(SettingsDemo.translateTo.timing.replayRange(on: true))
    }

    // MARK: DemoRun

    func test_loopRun_repeatsUntilLeftThenStopsOnTheRestFrame() {
        let demo = SettingsDemo.fullscreenCover, timing = demo.timing
        var run = DemoRun(kind: .loop, start: t0, isOn: true, stopAt: nil)
        XCTAssertNil(run.endDate)
        XCTAssertFalse(run.isFinished(at: t0.addingTimeInterval(500)))
        XCTAssertEqual(run.sceneTime(at: t0.addingTimeInterval(6.2 + 1.0), timing: timing), 1.0, accuracy: 1e-9, "second lap")

        run.leave(at: t0.addingTimeInterval(1.0), timing: timing)   // mid-motion
        XCTAssertEqual(run.stopAt, 2.7, "the next rest instant (t ≡ 2.7 mod 6.2)")
        XCTAssertEqual(run.sceneTime(at: t0.addingTimeInterval(2.0), timing: timing), 2.0, accuracy: 1e-9, "still playing until then")
        XCTAssertFalse(run.isFinished(at: t0.addingTimeInterval(2.69)))
        XCTAssertTrue(run.isFinished(at: t0.addingTimeInterval(2.7)))
        XCTAssertEqual(run.sceneTime(at: t0.addingTimeInterval(9), timing: timing), 2.7)
        XCTAssertEqual(run.endDate, t0.addingTimeInterval(2.7))
    }

    func test_onceRun_playsItsRangeAndHoldsTheLastFrame() {
        let timing = SettingsDemo.fullscreenCover.timing
        let run = DemoRun(kind: .once(from: 0.7, to: 2.7), start: t0, isOn: true, stopAt: nil)
        XCTAssertEqual(run.sceneTime(at: t0, timing: timing), 0.7)
        XCTAssertEqual(run.sceneTime(at: t0.addingTimeInterval(1), timing: timing), 1.7, accuracy: 1e-9)
        XCTAssertEqual(run.sceneTime(at: t0.addingTimeInterval(60), timing: timing), 2.7)
        XCTAssertTrue(run.isFinished(at: t0.addingTimeInterval(2.0)))
        XCTAssertFalse(run.isFinished(at: t0.addingTimeInterval(1.99)))
    }

    // MARK: schedule

    func test_timelineSchedule_endsExactlyAtTheRunsEnd() {
        let end = t0.addingTimeInterval(1)
        let dates = Array(DemoTimelineSchedule(end: end).entries(from: t0, mode: .normal))
        XCTAssertEqual(dates.first, t0)
        XCTAssertEqual(dates.last, end, "the last tick is the rest frame")
        XCTAssertTrue(dates.dropLast().allSatisfy { $0 < end })
        XCTAssertLessThan(dates.count, 200, "bounded: a finished run costs no more ticks")
        // A run already over yields one tick (to paint the rest frame) and stops.
        XCTAssertEqual(Array(DemoTimelineSchedule(end: t0).entries(from: t0.addingTimeInterval(5), mode: .normal)).count, 1)
        // An unbounded loop keeps ticking.
        var endless = DemoTimelineSchedule(end: nil).entries(from: t0, mode: .normal)
        for _ in 0..<1000 { XCTAssertNotNil(endless.next()) }
    }

    // MARK: stage model — idle, one clock, reduce motion

    private func makeModel(reduceMotion: Bool = false) -> (DemoStageModel, Clock) {
        let clock = Clock(now: t0)
        let model = DemoStageModel()
        model.reduceMotion = reduceMotion
        model.now = { clock.now }
        return (model, clock)
    }

    private final class Clock { var now: Date; init(now: Date) { self.now = now } }

    func test_idleStage_mountsNoClock() {
        let (model, clock) = makeModel()
        XCTAssertFalse(model.hasMountedClock)
        model.show(.fullscreenCover)
        XCTAssertFalse(model.hasMountedClock, "a shown scene at rest is a static view")
        XCTAssertEqual(model.activeClockCount(at: clock.now), 0)
        XCTAssertFalse(DemoStage.usesTimeline(.rest))
        XCTAssertFalse(DemoStage.usesTimeline(.frozen(1)))
        XCTAssertTrue(DemoStage.usesTimeline(.run(DemoRun(kind: .loop, start: t0, isOn: true, stopAt: nil))))
    }

    func test_onlyOneSceneMovesAtATime_acrossRowSwitches() {
        let (model, clock) = makeModel()
        model.show(.fullscreenCover)
        model.begin(.fullscreenCover)
        XCTAssertEqual(model.activeClockCount(at: clock.now), 1)
        clock.now = t0.addingTimeInterval(1.0)
        model.begin(.showTranslation)   // another row rested on: cross-fade
        XCTAssertEqual(model.activeClockCount(at: clock.now), 1)
        let outgoing = model.slots[1 - model.front]
        XCTAssertEqual(outgoing?.demo, .fullscreenCover)
        XCTAssertEqual(outgoing?.playback, .frozen(1.0), "the fading scene stops dead on its last frame")
        clock.now = t0.addingTimeInterval(2.0)
        model.begin(.translateTo)
        XCTAssertEqual(model.activeClockCount(at: clock.now), 1)
        XCTAssertEqual(model.slots.compactMap { $0 }.filter { DemoStage.usesTimeline($0.playback) }.count, 1, "only one TimelineView is ever mounted")
    }

    func test_leavingTheRow_letsTheLoopFinishOnRest_thenTheClockIsGone() {
        let (model, clock) = makeModel()
        model.begin(.fullscreenCover, isOn: true)
        clock.now = t0.addingTimeInterval(1.0)
        model.pointerMoved(to: nil)
        guard case .run(let run)? = model.frontSlot?.playback else { return XCTFail() }
        XCTAssertEqual(run.stopAt, 2.7)
        XCTAssertEqual(model.activeClockCount(at: t0.addingTimeInterval(2.0)), 1)
        XCTAssertEqual(model.activeClockCount(at: t0.addingTimeInterval(2.7)), 0, "no motion after the rest frame")
        XCTAssertEqual(((run.stopAt ?? 0) - 2.7).truncatingRemainder(dividingBy: 6.2), 0, accuracy: 1e-9)
    }

    func test_pointerOnAnotherRow_doesNotStopTheLoopOfItsOwnRow() {
        let (model, _) = makeModel()
        model.begin(.showTranslation)
        model.pointerMoved(to: .showTranslation)
        if case .run(let run)? = model.frontSlot?.playback { XCTAssertNil(run.stopAt) } else { XCTFail() }
        model.pointerMoved(to: .translateTo)
        if case .run(let run)? = model.frontSlot?.playback { XCTAssertNotNil(run.stopAt) } else { XCTFail() }
    }

    func test_returningToTheRowWhileItFinishes_keepsTheLoopGoing() {
        let (model, clock) = makeModel()
        model.begin(.fullscreenCover)
        clock.now = t0.addingTimeInterval(1.0)
        model.pointerMoved(to: nil)
        clock.now = t0.addingTimeInterval(1.5)
        model.begin(.fullscreenCover)
        guard case .run(let run)? = model.frontSlot?.playback else { return XCTFail() }
        XCTAssertNil(run.stopAt, "same row, still moving: the stop is cancelled, no restart")
        XCTAssertEqual(run.start, t0)
        XCTAssertEqual(model.slots.compactMap { $0 }.count, 1, "no cross-fade to itself")
    }

    func test_restingAgainAfterTheLoopStopped_restartsFromTheTop() {
        let (model, clock) = makeModel()
        model.begin(.fullscreenCover)
        clock.now = t0.addingTimeInterval(1.0)
        model.pointerMoved(to: nil)
        clock.now = t0.addingTimeInterval(20)
        model.begin(.fullscreenCover)
        guard case .run(let run)? = model.frontSlot?.playback else { return XCTFail() }
        XCTAssertEqual(run.start, clock.now)
        XCTAssertNil(run.stopAt)
    }

    func test_switchFlip_replaysOnceToTheNewState() {
        let (model, clock) = makeModel()
        model.replay(.fullscreenCover, isOn: true)
        guard case .run(let run)? = model.frontSlot?.playback else { return XCTFail() }
        XCTAssertEqual(run.kind, .once(from: 0.7, to: 2.7))
        XCTAssertEqual(model.activeClockCount(at: clock.now), 1)
        XCTAssertEqual(model.activeClockCount(at: clock.now.addingTimeInterval(2.0)), 0)
        model.replay(.translateTo, isOn: true)   // no motion to replay: just shows the scene
        XCTAssertEqual(model.frontSlot?.demo, .translateTo)
        XCTAssertEqual(model.frontSlot?.playback, .rest)
    }

    func test_reduceMotion_showsOnlyStills() {
        let (model, clock) = makeModel(reduceMotion: true)
        model.begin(.fullscreenCover)
        XCTAssertEqual(model.frontSlot?.playback, .rest)
        model.replay(.edgeShowSongOnTrackChange, isOn: true)
        XCTAssertEqual(model.frontSlot?.playback, .rest)
        XCTAssertFalse(model.hasMountedClock)
        XCTAssertEqual(model.activeClockCount(at: clock.now), 0)
        XCTAssertNil(DemoStage.crossFade(reduceMotion: true), "rows swap without a fade")
    }

    func test_settle_dropsTheClockAtOnce() {
        let (model, clock) = makeModel()
        model.begin(.showHidePlayerShortcut)
        XCTAssertTrue(model.hasMountedClock)
        model.settle()   // window hidden / closed
        XCTAssertFalse(model.hasMountedClock)
        XCTAssertEqual(model.activeClockCount(at: clock.now), 0)
    }

    func test_scenesWithoutMotion_justFadeIn() {
        let (model, _) = makeModel()
        model.show(.fullscreenCover)
        model.begin(.playbackHistory)
        XCTAssertEqual(model.frontSlot?.demo, .playbackHistory)
        XCTAssertEqual(model.frontSlot?.playback, .rest)
        XCTAssertFalse(model.hasMountedClock)
    }

    /// The real TimelineView, real clock: a one-shot replay paints moving frames, then holds the last one.
    func test_liveReplay_paintsMotion_thenHoldsTheLastFrame() throws {
        let model = DemoStageModel()
        let view = DemoStage(model: model, context: SettingsDemoContext(translationSampleText: "x", shortcutDescriptions: [:]))
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 169)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        model.show(.fullscreenCover)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rest = SettingsWindowRenderTests.capture(hosting)

        model.replay(.fullscreenCover, isOn: true)   // scene time 0.7 → 2.7 over 2.0s; the cover grows 0.9 → 1.8
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let early = SettingsWindowRenderTests.capture(hosting)
        RunLoop.main.run(until: Date().addingTimeInterval(1.9))
        let end = SettingsWindowRenderTests.capture(hosting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let later = SettingsWindowRenderTests.capture(hosting)

        func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool { a.tiffRepresentation == b.tiffRepresentation }
        XCTAssertFalse(same(early, end), "half a second in, the cover is still growing")
        XCTAssertTrue(same(end, rest), "the replay lands exactly on the switch-on rest frame")
        XCTAssertTrue(same(end, later), "after the run's end nothing changes any more")
        XCTAssertEqual(model.activeClockCount(at: Date()), 0)
    }

    func test_windowClose_settlesARunningStage() throws {
        let (model, _) = makeModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let observer = DemoWindowVisibilityObserver.ObserverView()
        observer.onHidden = { model.settle() }
        window.contentView?.addSubview(observer)
        model.begin(.hideToEdgeShortcut)
        XCTAssertTrue(model.hasMountedClock)
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(model.hasMountedClock)
    }
}
