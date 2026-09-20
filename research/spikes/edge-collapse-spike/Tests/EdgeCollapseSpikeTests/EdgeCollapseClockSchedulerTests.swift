import XCTest
@testable import EdgeCollapseSpike

/// (b) scheduler: hero settle > geometry settle for collapsing/expanding;
/// reduce-motion plan contains only the material/opacity clock; tempo 1.5
/// scales all durations — top-level task instruction #10(b).
final class EdgeCollapseClockSchedulerTests: XCTestCase {

    // MARK: - Hero settles after geometry (design §7.1 "全程最后停下" / §7.3 "封面落回...最后")

    func test_collapsing_heroSettlesAfterGeometry() {
        let plan = EdgeCollapseClockScheduler.plan(kind: .collapsing, reduceMotion: false, tempo: .normal)
        let hero = try! XCTUnwrap(plan.hero)
        XCTAssertGreaterThan(hero.settle, plan.geometry.settle)
    }

    func test_expanding_heroSettlesAfterGeometry() {
        let plan = EdgeCollapseClockScheduler.plan(kind: .expanding, reduceMotion: false, tempo: .normal)
        let hero = try! XCTUnwrap(plan.hero)
        XCTAssertGreaterThan(hero.settle, plan.geometry.settle)
    }

    func test_floatingMoves_haveNoHeroClock() {
        // Design §7.2: floating only fades the artwork dot in/out, it never
        // runs the matchedGeometryEffect flight.
        XCTAssertNil(EdgeCollapseClockScheduler.plan(kind: .floatingOut, reduceMotion: false, tempo: .normal).hero)
        XCTAssertNil(EdgeCollapseClockScheduler.plan(kind: .floatingRetract, reduceMotion: false, tempo: .normal).hero)
    }

    func test_expanding_hasNoGooClock() {
        // Design §8: the metaball Canvas mounts only for collapsing 200–320ms
        // and the two floating moves — never expanding.
        XCTAssertNil(EdgeCollapseClockScheduler.plan(kind: .expanding, reduceMotion: false, tempo: .normal).goo)
    }

    func test_collapsingAndFloating_haveGooClock() {
        XCTAssertNotNil(EdgeCollapseClockScheduler.plan(kind: .collapsing, reduceMotion: false, tempo: .normal).goo)
        XCTAssertNotNil(EdgeCollapseClockScheduler.plan(kind: .floatingOut, reduceMotion: false, tempo: .normal).goo)
        XCTAssertNotNil(EdgeCollapseClockScheduler.plan(kind: .floatingRetract, reduceMotion: false, tempo: .normal).goo)
    }

    // MARK: - Reduce Motion: opacity-only plan (design §8/§9)

    func test_reduceMotion_planIsOpacityOnly_forEveryKind() {
        for kind: EdgeCollapseTransitionKind in [.collapsing, .expanding, .floatingOut, .floatingRetract] {
            let plan = EdgeCollapseClockScheduler.plan(kind: kind, reduceMotion: true, tempo: .normal)
            XCTAssertNil(plan.hero, "\(kind): reduceMotion plan must have no hero clock")
            XCTAssertNil(plan.goo, "\(kind): reduceMotion plan must have no goo clock")
            XCTAssertEqual(plan.geometry.duration, 0, "\(kind): reduceMotion geometry must be an instant snap, not an animated duration")
            XCTAssertGreaterThan(plan.material.duration, 0, "\(kind): reduceMotion material (opacity) clock must still run")
            XCTAssertEqual(plan.material.duration, EdgeCollapseTokens.reduceMotionCrossfadeDuration)
        }
    }

    func test_reduceMotion_tempoStillScalesTheCrossfade() {
        let normal = EdgeCollapseClockScheduler.plan(kind: .collapsing, reduceMotion: true, tempo: .normal)
        let slow = EdgeCollapseClockScheduler.plan(kind: .collapsing, reduceMotion: true, tempo: .slow)
        XCTAssertEqual(slow.material.duration, normal.material.duration * 1.5, accuracy: 0.0001)
    }

    // MARK: - Tempo 1.5 scales every duration, for every kind and every clock

    func test_tempoSlow_scalesAllDurationsByOneAndHalf_everyKindEveryClock() {
        for kind: EdgeCollapseTransitionKind in [.collapsing, .expanding, .floatingOut, .floatingRetract] {
            let normal = EdgeCollapseClockScheduler.plan(kind: kind, reduceMotion: false, tempo: .normal)
            let slow = EdgeCollapseClockScheduler.plan(kind: kind, reduceMotion: false, tempo: .slow)

            assertScaled(normal.geometry, slow.geometry, kind: kind, clock: "geometry")
            assertScaled(normal.material, slow.material, kind: kind, clock: "material")
            if let normalHero = normal.hero, let slowHero = slow.hero {
                assertScaled(normalHero, slowHero, kind: kind, clock: "hero")
            } else {
                XCTAssertNil(normal.hero, "\(kind): hero nil-ness must match between tempos")
                XCTAssertNil(slow.hero, "\(kind): hero nil-ness must match between tempos")
            }
            if let normalGoo = normal.goo, let slowGoo = slow.goo {
                assertScaled(normalGoo, slowGoo, kind: kind, clock: "goo")
            } else {
                XCTAssertNil(normal.goo, "\(kind): goo nil-ness must match between tempos")
                XCTAssertNil(slow.goo, "\(kind): goo nil-ness must match between tempos")
            }
            XCTAssertEqual(slow.totalDuration, normal.totalDuration * 1.5, accuracy: 0.0001, "\(kind): totalDuration must scale by tempo")
        }
    }

    private func assertScaled(_ normal: EdgeCollapseClock, _ slow: EdgeCollapseClock, kind: EdgeCollapseTransitionKind, clock: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(slow.start, normal.start * 1.5, accuracy: 0.0001, "\(kind).\(clock).start not scaled", file: file, line: line)
        XCTAssertEqual(slow.duration, normal.duration * 1.5, accuracy: 0.0001, "\(kind).\(clock).duration not scaled", file: file, line: line)
    }

    // MARK: - Generation cancel logic (mirrors EdgeMorphClockScheduler.shouldApply)

    func test_shouldApply_onlyWhenGenerationStillCurrent() {
        XCTAssertTrue(EdgeCollapseClockScheduler.shouldApply(generation: 3, current: 3))
        XCTAssertFalse(EdgeCollapseClockScheduler.shouldApply(generation: 2, current: 3))
    }
}
