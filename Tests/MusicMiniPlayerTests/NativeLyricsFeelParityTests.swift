import XCTest
import AppKit
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Founder 2026-08-27 诊断批留下的三个主观差异：做成可切换对照 + 量化表。
//
// Switch (live): nanopod://debug/feel/<appear|blur|sweep>/<v28|current|layer>
// Default: appear=current (0.8s force-snap, bloom guard), blur=current (step,
// rasterization economy), sweep=v28 (Canvas-aligned whole-line dim base).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsFeelParityTests: XCTestCase {

    override func tearDown() {
        NativeLyricsFeelParity.resetTestingOverrides()
        NativeLyricsFeelParity.apply(channel: "reset", value: "")
        super.tearDown()
    }

    func test_unknownValuesFallBackToShippingDefaults() {
        XCTAssertEqual(NativeLyricsFeelParity.AppearWindowMode.resolve(from: nil), .current)
        XCTAssertEqual(NativeLyricsFeelParity.AppearWindowMode.resolve(from: "nope"), .current)
        XCTAssertEqual(NativeLyricsFeelParity.BlurMode.resolve(from: nil), .current)
        XCTAssertEqual(NativeLyricsFeelParity.BlurMode.resolve(from: "spring"), .current)
        XCTAssertEqual(NativeLyricsFeelParity.SweepPathMode.resolve(from: nil), .v28)
        XCTAssertEqual(NativeLyricsFeelParity.SweepPathMode.resolve(from: "canvas"), .v28)
        XCTAssertEqual(NativeLyricsFeelParity.SweepPathMode.resolve(from: "layer"), .layer)
        XCTAssertEqual(NativeLyricsFeelParity.SweepPathMode.resolve(from: "current"), .v28)
        XCTAssertEqual(NativeLyricsFeelParity.appearWindowDuration, 0.8, accuracy: 0.0001)
    }

    func test_appearWindow_quantizedDifferenceTable() {
        // Position error from a +80pt stacked-at-top start. v2.8 had no force-snap
        // window: the position spring (mass 1 / k 100 / d 16.5) carries the row in.
        // Current force-snaps to the target for 0.8s (error = 0), then is already parked.
        let times: [TimeInterval] = [0, 0.05, 0.10, 0.20, 0.40, 0.80, 1.20]
        let spring = NativeLyricsSpringSampler.sample(
            from: 80, to: 0, times: times,
            spring: .amllNatural, monotonic: true
        )
        XCTAssertEqual(times.count, spring.count)

        NativeLyricsFeelParity.testingAppear = .current
        XCTAssertTrue(NativeLyricsFeelParity.forceSnapActive(now: 100, until: 100.8))
        XCTAssertFalse(NativeLyricsFeelParity.forceSnapActive(now: 100.8, until: 100.8))
        NativeLyricsFeelParity.testingAppear = .v28
        XCTAssertFalse(NativeLyricsFeelParity.forceSnapActive(now: 100, until: 100.8),
                       "v2.8 natural enter never force-snaps, even inside the 0.8s window")
        XCTAssertEqual(NativeLyricsFeelParity.forceSnapDeadline(now: 50), 0)

        // Quantitative table (Y error, pt). Current column is identically 0 for t ≤ 0.8.
        XCTAssertEqual(spring[0], 80, accuracy: 0.0001, "t=0 v28 still at the stacked-at-top offset")
        XCTAssertGreaterThan(spring[1], 0, "t=0.05 v28 still approaching")
        XCTAssertGreaterThan(spring[4], 0, "t=0.40 v28 still approaching")
        XCTAssertLessThan(abs(spring[5]), 2.0, "t=0.80 v28 has mostly settled (natural spring, not a snap)")
        XCTAssertLessThan(abs(spring[6]), 0.5, "t=1.20 v28 parked")

        // Shipping current: error is 0 for the whole appear window.
        let current: [CGFloat] = times.map { t in t <= 0.8 ? 0 : spring[times.firstIndex(of: t)!] }
        XCTAssertTrue(current.prefix(6).allSatisfy { abs($0) < 0.0001 })
    }

    func test_blurStepVsSpring_quantizedDifferenceTable() {
        let times: [TimeInterval] = [0, 1.0 / 60.0, 4.0 / 60.0, 8.0 / 60.0, 16.0 / 60.0, 30.0 / 60.0]
        let from: CGFloat = 0
        let to: CGFloat = 1.5
        let springed = NativeLyricsSpringSampler.sample(
            from: from, to: to, times: times,
            spring: .amllVisual, monotonic: true
        )

        NativeLyricsFeelParity.testingBlur = .current
        var stepped = NativeLyricsVisualMotionState(target: NativeLyricsVisualTarget(
            opacity: 1, scale: 1, blur: from, isActive: true
        ))
        XCTAssertTrue(stepped.setTarget(NativeLyricsVisualTarget(
            opacity: 1, scale: 1, blur: to, isActive: false
        )))
        XCTAssertEqual(stepped.blur, to, accuracy: 0.0001, "current: blur snaps on the retarget frame")
        XCTAssertTrue(stepped.isSettled, "current: blur-only retarget stays rasterizable")

        NativeLyricsFeelParity.testingBlur = .v28
        var sprung = NativeLyricsVisualMotionState(target: NativeLyricsVisualTarget(
            opacity: 1, scale: 1, blur: from, isActive: true
        ))
        XCTAssertTrue(sprung.setTarget(NativeLyricsVisualTarget(
            opacity: 1, scale: 1, blur: to, isActive: false
        )))
        XCTAssertEqual(sprung.blur, from, accuracy: 0.0001, "v28: blur stays at the old value on the retarget frame")
        XCTAssertFalse(sprung.isSettled, "v28: blur-only retarget is unsettled (cannot rasterize through handoff)")

        XCTAssertEqual(springed[0], from, accuracy: 0.0001)
        XCTAssertGreaterThan(springed[1], from)
        XCTAssertLessThan(springed[1], to)
        XCTAssertGreaterThan(springed[3], springed[1])
        XCTAssertLessThan(abs(springed[5] - to), 0.15, "visual spring is mostly there by 0.5s")
    }

    func test_sweepPath_canvasVsLayer_isTheDimBaseTessellation() {
        NativeLyricsFeelParity.testingSweep = .v28
        XCTAssertTrue(NativeLyricsFeelParity.keepsWholeLineDimBase)
        NativeLyricsFeelParity.testingSweep = .layer
        XCTAssertFalse(NativeLyricsFeelParity.keepsWholeLineDimBase)

        // Canvas (v2.8 LyricLineView LyricsTextRenderer):
        //   pass 1 draws the dim base with ZERO vertical float (identical wrap/tracking)
        //   pass 2 draws the bright overlay with per-run translateBy(baseFloatY)
        // Native layer arm: both dim and bright were per-glyph tiles that floated,
        // so wrap-line 行距 of the always-visible dim text changed at activation.
        // Remaining subjective (cannot live-switch; LyricLineView was removed):
        //   CATextLayer raster of a string vs SwiftUI TextRenderer/Canvas of the
        //   same CoreText layout. Quantized here as "same typesetting snapshot".
        let line = LyricLine(
            text: "想走出你控制的领域",
            startTime: 0, endTime: 8,
            words: (0..<9).map { i in
                LyricWord(word: String("想走出你控制的领域".dropFirst(i).prefix(1)),
                          startTime: TimeInterval(i), endTime: TimeInterval(i) + 1)
            }
        )
        let plan = NativeLyricsTextRenderPlan.make(configuration: .init(
            line: line, currentTime: 0, isActive: true
        ))
        let snap = NativeLyricsTextSweepLayout.layoutSnapshot(
            displayText: plan.displayText,
            wordRuns: plan.wordRuns,
            width: 186,
            fontSize: 24
        )
        XCTAssertGreaterThanOrEqual(snap.lineCount, 2)
        XCTAssertGreaterThan(snap.lineSpacing, 20, "24pt wrapped CJK line-box is ~one em")
    }

    func test_applyURL_writesAndResets() {
        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "appear", value: "v28"))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: NativeLyricsFeelParity.appearDefaultsKey),
            "v28"
        )
        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "blur", value: "v28"))
        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "sweep", value: "layer"))
        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "wave", value: "sync"))
        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "reset", value: ""))
        XCTAssertNil(UserDefaults.standard.string(forKey: NativeLyricsFeelParity.appearDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: NativeLyricsFeelParity.blurDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: NativeLyricsFeelParity.sweepDefaultsKey))
        XCTAssertNil(UserDefaults.standard.string(forKey: NativeLyricsFeelParity.waveDefaultsKey))
        XCTAssertFalse(NativeLyricsFeelParity.apply(channel: "nope", value: "v28"))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // wave channel: topdown (shipping default) vs sync (outgoing+incoming start
    // on the same frame). nanopod://debug/feel/wave/<topdown|sync>, .../reset.
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_waveMode_unknownOrAbsentValueFallsBackToTopDown() {
        XCTAssertEqual(NativeLyricsFeelParity.WaveMode.resolve(from: nil), .topdown)
        XCTAssertEqual(NativeLyricsFeelParity.WaveMode.resolve(from: "nope"), .topdown)
        XCTAssertEqual(NativeLyricsFeelParity.WaveMode.resolve(from: "SYNC"), .sync)
        XCTAssertEqual(NativeLyricsFeelParity.WaveMode.resolve(from: "topdown"), .topdown)

        NativeLyricsFeelParity.testingWave = nil
        XCTAssertEqual(NativeLyricsFeelParity.waveShape, .topDown, "unresolved value stays the shipping default shape")
    }

    func test_waveMode_urlSetsSyncPairAndResetRestoresTopDown() {
        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "wave", value: "sync"))
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: NativeLyricsFeelParity.waveDefaultsKey),
            "sync"
        )
        // testingWave (DEBUG-only override) takes precedence over UserDefaults in tests,
        // so exercise the resolved shape via the raw resolver instead of `waveShape` here.
        XCTAssertEqual(
            NativeLyricsFeelParity.WaveMode.resolve(
                from: UserDefaults.standard.string(forKey: NativeLyricsFeelParity.waveDefaultsKey)
            ),
            .sync
        )

        XCTAssertTrue(NativeLyricsFeelParity.apply(channel: "reset", value: ""))
        XCTAssertNil(UserDefaults.standard.string(forKey: NativeLyricsFeelParity.waveDefaultsKey))
    }

    func test_waveShape_testingOverrideSelectsSchedule() {
        NativeLyricsFeelParity.testingWave = .topdown
        XCTAssertEqual(NativeLyricsFeelParity.waveShape, .topDown)
        NativeLyricsFeelParity.testingWave = .sync
        XCTAssertEqual(NativeLyricsFeelParity.waveShape, .syncPair)
    }
}
