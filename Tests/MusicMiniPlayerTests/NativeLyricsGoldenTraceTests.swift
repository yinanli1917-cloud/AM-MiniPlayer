//
//  NativeLyricsGoldenTraceTests.swift
//
//  Stage 2 verification foundation — a deterministic, headless golden-trace rig.
//
//  The on-screen lyric glitches live in motion: a flicker storm while scrolling, a
//  jump after a seek, a line that dims out of step. Catching them objectively means
//  replaying a FIXED input sequence frame by frame and asserting every frame's state,
//  not eyeballing a recording. The motion source, LyricsPresentationEngine, integrates
//  springs from an explicit time delta, so it can be driven deterministically with no
//  display link, no wall clock, and no window. This rig drives the REAL engine over a
//  scripted frame sequence and records each row's per-frame Y into a trace we assert on.
//  As the Stage 2 snapshot refactor grows, the same rig will capture the snapshot the
//  renderer consumes, making it authoritative for the paint-level glitches too.
//

import XCTest
import CoreGraphics
@testable import MusicMiniPlayerCore

@MainActor
final class NativeLyricsGoldenTraceTests: XCTestCase {

    func testNaturalLineAdvanceNeverTeleportsARow() {
        // Four evenly spaced rows; the active line advances from 0 to 1 in natural mode.
        let trace = NativeLyricsGoldenTrace(
            rendered: [0, 1, 2, 3],
            anchorY: 200,
            heights: [0: 0, 1: 60, 2: 120, 3: 180]
        )
        trace.setCurrentIndex(0)        // initial snap to position
        trace.advance(frames: 2)        // settle
        trace.setCurrentIndex(1)        // line advance (schedules a natural wave)
        trace.advance(frames: 40)       // ~0.66s of spring motion

        // A natural adjacent advance must spring smoothly: no single frame may move a row
        // farther than the teleport threshold the renderer guards against (60pt/tick).
        for row in [0, 1, 2, 3] {
            let ys = trace.ys(row: row)
            let maxStep = zip(ys, ys.dropFirst()).map { abs($1 - $0) }.max() ?? 0
            XCTAssertLessThan(maxStep, 60, "row \(row) must not teleport during a natural line advance")
        }
    }

    func testActiveRowMovesFromOldPositionAndSettlesAtAnchor() {
        // Guards against a degenerate (constant / empty) trace passing the no-teleport check:
        // the active row must actually travel and converge. With the current line at index 1,
        // its snap target is the anchor (anchorY - h[1] + h[1] = anchorY). Before the advance
        // it sat at anchorY - h[0] + h[1] = 260.
        let trace = NativeLyricsGoldenTrace(
            rendered: [0, 1, 2, 3],
            anchorY: 200,
            heights: [0: 0, 1: 60, 2: 120, 3: 180]
        )
        trace.setCurrentIndex(0)
        trace.advance(frames: 2)
        trace.setCurrentIndex(1)
        trace.advance(frames: 150)      // 2.5s — comfortably past spring settle

        let ys = trace.ys(row: 1)
        XCTAssertGreaterThan(ys.count, 100, "the trace must capture every advanced frame")
        XCTAssertGreaterThan(ys.first ?? 0, 250, "row 1 starts near its old position (260)")
        XCTAssertEqual(ys.last ?? 0, 200, accuracy: 1.0, "row 1 settles at the anchor")
        XCTAssertGreaterThan(abs((ys.first ?? 0) - (ys.last ?? 0)), 40, "row 1 genuinely moved")
    }
}
