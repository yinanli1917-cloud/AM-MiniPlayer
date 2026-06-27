//
//  NativeLyricsGoldenTrace.swift
//
//  Deterministic, headless replay rig over the real LyricsPresentationEngine.
//
//  Build a fixed layout (rendered rows, anchor, accumulated heights), script a sequence
//  of target-index changes and fixed-delta frame advances, and read back a per-row,
//  per-frame Y trace. No display link, no wall clock, no window: every run is identical,
//  so a trace can be asserted on (no teleport, monotone settle, convergence) or diffed
//  against a golden baseline before and after a change.
//
//  Test-support code; lives in the test target and reaches the engine via @testable.
//

import Foundation
import CoreGraphics
@testable import MusicMiniPlayerCore

@MainActor
final class NativeLyricsGoldenTrace {
    private let engine = LyricsPresentationEngine()
    private let rendered: [Int]
    private let anchorY: CGFloat
    private let heights: [Int: CGFloat]

    /// One entry per captured frame: rowIndex -> presented Y at that frame.
    private(set) var frames: [[Int: CGFloat]] = []

    init(rendered: [Int], anchorY: CGFloat, heights: [Int: CGFloat]) {
        self.rendered = rendered
        self.anchorY = anchorY
        self.heights = heights
    }

    /// Point the engine at a new active/target line. Natural mode springs toward it; the
    /// first call (no prior index) snaps into position.
    func setCurrentIndex(_ index: Int) {
        engine.update(configuration(currentIndex: index, mode: .natural), onTargetsChanged: {})
    }

    /// Jump to a line the way a user seek does: direct-snap, no spring travel.
    func seek(toIndex index: Int) {
        engine.update(configuration(currentIndex: index, mode: .directSnap(.seek)), onTargetsChanged: {})
    }

    /// Advance the springs by `count` fixed-delta ticks, capturing a frame after each.
    func advance(frames count: Int, delta: TimeInterval = 1.0 / 60.0) {
        for _ in 0..<count {
            _ = engine.advance(delta: delta)
            capture()
        }
    }

    /// The Y trace for one row across all captured frames.
    func ys(row: Int) -> [CGFloat] {
        frames.compactMap { $0[row] }
    }

    // ------------------------------------------------------------------------

    private func capture() {
        var frame: [Int: CGFloat] = [:]
        for index in rendered {
            if let y = engine.presentation(for: index)?.y {
                frame[index] = y
            }
        }
        frames.append(frame)
    }

    private func configuration(
        currentIndex: Int,
        mode: LyricsPresentationPlaybackMode
    ) -> LyricsPresentationEngineConfiguration {
        LyricsPresentationEngineConfiguration(
            currentIndex: currentIndex,
            renderedIndices: rendered,
            anchorY: anchorY,
            accumulatedHeights: heights,
            lineInterval: 4,
            hasSyllableSync: false,
            trackContext: DiagnosticTrackContext(title: "T", artist: "A", album: "Al", duration: 100),
            isWaveTimelineDiagnosticsEnabled: false,
            playbackMode: mode
        )
    }
}
