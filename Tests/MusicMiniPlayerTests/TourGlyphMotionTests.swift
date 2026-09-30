/**
 * [INPUT]: MusicMiniPlayerAppKit's TourGuidanceMotion (pure; a fake clock, no windows), TourOverlayRegion, TourCardVisual /
 *          TourOverlayVisual, TourFrameDriver.
 * [OUTPUT]: TourGlyphMotionTests — the move step's trackpad demo band (it grows in and folds away on the card's own height
 *           spring), the split card / overlay frames, the overlay's region, and the shared display link.
 * [POS]: Tests. Founder 2026-09-29 (third walk): the demo must appear only on the beat that asks for the gesture, with a short
 *        fade / scale-in, the card height springing to fit; and the tour must not redraw what did not change.
 */

import XCTest
import MusicMiniPlayerCore
@testable import MusicMiniPlayerAppKit

@MainActor
final class TourGlyphMotionTests: XCTestCase {
    private let dt = 1.0 / 60
    private let band = 10.0 + 72.0 * 1.15

    private func pose(h: Double) -> TourCardPose {
        TourCardPose(x: 100, top: 600, width: 272, height: h, beakSide: .right, beakOffset: 60)
    }

    private func settledCard(h: Double = 240, reduceMotion: Bool = false) -> TourGuidanceMotion {
        let m = TourGuidanceMotion(reduceMotion: reduceMotion)
        m.presentCard(at: pose(h: h))
        m.setGlyph(present: false, animated: false)
        m.advance(by: 1.5)
        return m
    }

    // MARK: - The band rides the card's height spring

    func test_glyphGrowsIn_onTheSameSpringAsTheCardHeight_soBandAndBubbleMoveAsOne() {
        let m = settledCard()
        XCTAssertEqual(m.makeFrame().glyphPresence, 0)
        m.relayoutCard(to: pose(h: 240 + band))
        m.setGlyph(present: true, animated: true)
        var maxGap = 0.0
        var sawPartial = false
        for _ in 0..<90 {
            m.step(dt)
            let f = m.makeFrame()
            maxGap = max(maxGap, abs((f.cardHeight - 240) - band * f.glyphPresence))
            if f.glyphPresence > 0.05, f.glyphPresence < 0.95 { sawPartial = true }
        }
        XCTAssertLessThan(maxGap, 0.01, "the card is as tall as the content it holds, every frame (to 0.01 pt): no clipped footer, no gap")
        XCTAssertTrue(sawPartial, "it grows in over several frames (a fade and scale-in), it does not pop")
        XCTAssertEqual(m.makeFrame().glyphPresence, 1, accuracy: 1e-3)
    }

    func test_glyphFoldsAway_onTheSameSpring() {
        let m = settledCard(h: 240 + band)
        m.setGlyph(present: true, animated: false)
        m.advance(by: 0.5)
        XCTAssertEqual(m.makeFrame().glyphPresence, 1)
        m.relayoutCard(to: pose(h: 240))
        m.setGlyph(present: false, animated: true)
        var maxGap = 0.0
        for _ in 0..<90 {
            m.step(dt)
            let f = m.makeFrame()
            maxGap = max(maxGap, abs((f.cardHeight - 240) - band * f.glyphPresence))
        }
        XCTAssertLessThan(maxGap, 0.01)
        XCTAssertEqual(m.makeFrame().glyphPresence, 0, accuracy: 1e-3)
    }

    func test_glyphAtOnce_whenTheCardAppearsOrItsContentSwaps() {
        let m = TourGuidanceMotion()
        m.presentCard(at: pose(h: 240 + band))
        m.setGlyph(present: true, animated: false)
        XCTAssertEqual(m.makeFrame().glyphPresence, 1, "no band animation under an appearing card: it would fight the card's own entrance")
    }

    // MARK: - The demo's own clock

    func test_glyphClock_runsTwoCyclesThenStops_andReplayStartsItAgain() {
        let m = settledCard()
        m.setGlyph(present: true, animated: false)
        XCTAssertTrue(m.isAnimating, "a running demo keeps the tour's one display link alive")
        m.advance(by: 1.0)
        let mid = m.makeFrame()
        XCTAssertEqual(mid.glyphElapsed ?? -1, 1.0 - TourGuidanceTokens.glyphCycleDelay, accuracy: 0.03)
        m.advance(by: TourGestureMotion.cycleDuration * 2)
        XCTAssertNil(m.makeFrame().glyphElapsed, "after two cycles it rests: no clock")
        XCTAssertFalse(m.isAnimating, "and the link can stop")
        m.replayGlyph()
        XCTAssertTrue(m.isAnimating)
        XCTAssertEqual(m.makeFrame().glyphElapsed ?? -1, 0, accuracy: 0.001)
    }

    func test_glyphRestartsWhenTheDemoChanges_butNotWhenItStays() {
        let m = settledCard()
        m.setGlyph(present: true, animated: false)
        m.advance(by: 2.0)
        m.setGlyph(present: true, animated: true)                       // the same demo again: nothing happens
        XCTAssertGreaterThan(m.makeFrame().glyphElapsed ?? 0, 1.5)
        m.setGlyph(present: true, animated: true, restart: true)        // the corner demo becomes the edge demo
        XCTAssertEqual(m.makeFrame().glyphElapsed ?? -1, 0, accuracy: 0.001)
    }

    func test_reduceMotion_glyphIsThereAtOnce_andStatic() {
        let m = settledCard(reduceMotion: true)
        m.setGlyph(present: true, animated: true)
        XCTAssertEqual(m.makeFrame().glyphPresence, 1)
        XCTAssertNil(m.makeFrame().glyphElapsed)
        XCTAssertFalse(m.isAnimating)
    }

    // MARK: - Frames are split: what did not change is not redrawn

    func test_cardVisual_ignoresRingAndGlowFrames_andOverlayVisual_ignoresCardTravel() {
        let m = settledCard()
        let quiet = m.makeFrame()
        m.showRing(TourRingGeometry(cx: 300, cy: 300, w: 40, h: 40, corner: 20), mode: .pressNow)
        m.advance(by: 0.9)                                              // the ring appears and breathes; the card does not
        let ringFrame = m.makeFrame()
        XCTAssertEqual(TourCardVisual(ringFrame), TourCardVisual(quiet), "the ring changes nothing the card draws")
        XCTAssertNotEqual(TourOverlayVisual(ringFrame), TourOverlayVisual(quiet))

        m.moveCard(to: TourCardPose(x: 700, top: 500, width: 272, height: 240, beakSide: .right, beakOffset: 60))
        m.advance(by: 0.2)
        let travelling = m.makeFrame()
        XCTAssertEqual(TourCardVisual(travelling), TourCardVisual(quiet), "a card that only travels is the same card content: its view is not re-evaluated")
        XCTAssertNotEqual(travelling.cardX, quiet.cardX)
    }

    func test_overlayVisual_hasContent_onlyWhileSomethingIsDrawn() {
        XCTAssertFalse(TourOverlayVisual.hidden.hasContent)
        var v = TourOverlayVisual.hidden
        v.panelGlow = 0.4
        XCTAssertTrue(v.hasContent)
        v = .hidden; v.ringVisible = true; v.ringOpacity = 0.6
        XCTAssertTrue(v.hasContent)
        v.ringOpacity = 0.001
        XCTAssertFalse(v.hasContent, "a ring faded to nothing parks the overlay window")
    }

    // MARK: - The overlay window covers what is drawn, not the screen

    func test_overlayRegion_isTheUnionOfWhatIsDrawn_andNothingWhenNothingIs() {
        let panel = CGRect(x: 2300, y: 1100, width: 250, height: 284)
        XCTAssertNil(TourOverlayRegion.needed(for: .hidden, panel: panel))

        var glow = TourOverlayVisual.hidden
        glow.panelGlow = 1
        let g = TourOverlayRegion.needed(for: glow, panel: panel)!
        XCTAssertTrue(g.contains(panel.insetBy(dx: -28, dy: -28)), "the outer glow is inside the window")
        XCTAssertLessThan(g.width * g.height, 0.1 * 2560 * 1440, "a glow is ~5% of the screen, not all of it")

        var ring = TourOverlayVisual.hidden
        ring.ringVisible = true
        ring.ringOpacity = 1
        ring.ring = TourRingGeometry(cx: 2400, cy: 1200, w: 64, h: 64, corner: 32)
        let r = TourOverlayRegion.needed(for: ring, panel: panel)!
        let biggestRing = 64 * TourOverlayRegion.maxRingScale
        XCTAssertGreaterThan(r.width, biggestRing + 2 * 40, "room for the pulse, the sonar ripple and the soft glow")
        XCTAssertLessThan(r.width, 400)
    }

    func test_overlayWindowFrame_isKept_whileItStillCoversTheDrawing_andGrowsWithThePanelNeighbourhood() {
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let panel = CGRect(x: 2294, y: 1110, width: 250, height: 284)
        var ring = TourOverlayVisual.hidden
        ring.ringVisible = true; ring.ringOpacity = 1
        ring.ring = TourRingGeometry(cx: 2400, cy: 1200, w: 40, h: 40, corner: 20)
        let needed = TourOverlayRegion.needed(for: ring, panel: panel)!
        let first = TourOverlayRegion.windowFrame(current: .zero, needed: needed, panel: panel, screen: screen)
        XCTAssertTrue(first.contains(panel.insetBy(dx: -100, dy: -100).intersection(screen)), "it takes in the panel's neighbourhood: the ring hops between controls inside it")
        // The ring hops to another control: the same window still covers it, so it is NOT resized.
        ring.ring = TourRingGeometry(cx: 2420, cy: 1290, w: 40, h: 40, corner: 20)
        let hop = TourOverlayRegion.needed(for: ring, panel: panel)!
        XCTAssertEqual(TourOverlayRegion.windowFrame(current: first, needed: hop, panel: panel, screen: screen), first)
        // A ring somewhere else entirely (the tucked strip) needs a new window.
        ring.ring = TourRingGeometry(cx: 2540, cy: 400, w: 18, h: 90, corner: 9)
        let strip = TourOverlayRegion.needed(for: ring, panel: panel)!
        let moved = TourOverlayRegion.windowFrame(current: first, needed: strip, panel: panel, screen: screen)
        XCTAssertNotEqual(moved, first)
        XCTAssertTrue(moved.contains(strip.intersection(screen)))
        XCTAssertTrue(screen.contains(moved))
    }

    // MARK: - One display link for the tour

    func test_oneDisplayLink_forEveryActiveClock() {
        let driver = TourFrameDriver.shared
        let a = TourFeedbackTicker(), b = TourFeedbackTicker()
        var ticksA = 0, ticksB = 0
        a.onTick = { ticksA += 1 }
        b.onTick = { ticksB += 1 }
        a.start(); b.start()
        XCTAssertEqual(driver.activeClientCount, 2)
        let before = driver.callbackCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let callbacks = driver.callbackCount - before
        XCTAssertGreaterThan(callbacks, 3)
        XCTAssertEqual(ticksA, callbacks, "each callback ticks every active clock once…")
        XCTAssertEqual(ticksB, callbacks, "…in one pass: two clocks do not mean two callbacks per refresh")
        a.stop()
        XCTAssertTrue(driver.isRunning, "still running for the other clock")
        b.stop()
        XCTAssertFalse(driver.isRunning, "and gone when the last one stops: a resting tour owns no display link")
    }
}
