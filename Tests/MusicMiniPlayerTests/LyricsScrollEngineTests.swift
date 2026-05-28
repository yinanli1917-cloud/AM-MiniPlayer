import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class LyricsScrollEngineTests: XCTestCase {
    func testStaggerScheduleMatchesLegacyThreeRowLeadIn() {
        let indices = Array(0...20)
        let schedule = LyricScrollWaveTiming.staggerSchedule(for: indices, newIndex: 12)
        let activeDelay = schedule.first(where: { $0.lineIndex == 12 })?.delay
        XCTAssertEqual(activeDelay ?? 0, LyricScrollWaveTiming.defaultBaseDelay * 3, accuracy: 0.001)
    }

    func testNaturalWaveSchedulesPendingFlipsWithoutSwiftUI() {
        let engine = LyricsScrollEngine()
        engine.setLayout(LyricsScrollEngine.LayoutSnapshot(
            anchorY: 200,
            accumulatedHeights: Dictionary(uniqueKeysWithValues: (0...10).map { ($0, CGFloat($0) * 40) })
        ))
        engine.seedTargets(indices: Array(0...10), oldIndex: 4)
        engine.scheduleNaturalWave(
            from: 4,
            to: 5,
            renderedIndices: Array(0...10),
            lineInterval: 1.2,
            hasSyllableSync: false
        )
        XCTAssertTrue(engine.isWaveActive)
        XCTAssertEqual(engine.lineTargetIndices[4], 4)
        engine.tick(at: 0)
        XCTAssertTrue(engine.isWaveActive)
    }

    func testSnapAllTargetsClearsWave() {
        let engine = LyricsScrollEngine()
        engine.setLayout(LyricsScrollEngine.LayoutSnapshot(
            anchorY: 100,
            accumulatedHeights: [0: 0, 1: 40, 2: 80]
        ))
        engine.scheduleNaturalWave(
            from: 0,
            to: 2,
            renderedIndices: [0, 1, 2],
            lineInterval: nil,
            hasSyllableSync: false
        )
        engine.snapAllTargets(to: 2, indices: [0, 1, 2])
        XCTAssertFalse(engine.isWaveActive)
        XCTAssertEqual(engine.targetLineIndex(forRow: 0, fallback: 2), 2)
    }

    func testSpringAdvancesTowardTargetOnTick() {
        let engine = LyricsScrollEngine()
        engine.setLayout(LyricsScrollEngine.LayoutSnapshot(
            anchorY: 300,
            accumulatedHeights: [0: 0, 1: 50]
        ))
        engine.seedTargets(indices: [0, 1], oldIndex: 0)
        engine.scheduleNaturalWave(
            from: 0,
            to: 1,
            renderedIndices: [0, 1],
            lineInterval: nil,
            hasSyllableSync: false
        )
        let y0 = engine.fullOffsetY(forRow: 0, displayIndex: 1, manualScrollFrozenTarget: nil)
        engine.tick(at: 0.05)
        let y1 = engine.fullOffsetY(forRow: 0, displayIndex: 1, manualScrollFrozenTarget: nil)
        XCTAssertNotEqual(y0, y1, accuracy: 0.01)
    }
}
