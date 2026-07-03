import XCTest
@testable import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// The monotonic render clock — Approach A, the AMLL-faithful root fix.
//
// AMLL never flickers because its host feeds a monotonic clock; our SB poll yanks the clock
// backward on resync. This gate filters that at the renderer's input: normal playback only ever
// HOLDS or ADVANCES the time the surface sees. A backward step beyond seekThreshold, or an explicit
// seek, is a real discontinuity the clock FOLLOWS. Pure + deterministic — no window, no surface.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
final class NativeLyricsMonotonicClockTests: XCTestCase {

    private func step(
        _ previous: TimeInterval,
        _ raw: TimeInterval,
        seek: Bool = false,
        threshold: TimeInterval = 3.0
    ) -> (value: TimeInterval, step: NativeLyricsSeekClassifier.ClockStep) {
        NativeLyricsSeekClassifier.monotonicTime(
            previous: previous, rawTime: raw, explicitSeek: seek, seekThreshold: threshold
        )
    }

    // ── Forward motion tracks the raw clock ──

    func test_forward_tracksRawTime() {
        let r = step(8.0, 10.0)
        XCTAssertEqual(r.value, 10.0, accuracy: 1e-9, "forward playback must track the raw clock")
        XCTAssertEqual(r.step, .advance)
    }

    // ── A sub-threshold backward dip is jitter: HOLD, never move backward ──

    func test_backwardJitter_holdsMonotonic() {
        let r = step(10.0, 8.5, threshold: 3.0)   // 1.5s back, within threshold
        XCTAssertEqual(r.value, 10.0, accuracy: 1e-9, "a sub-threshold backward dip must hold, not rewind")
        XCTAssertEqual(r.step, .advance, "jitter is normal playback, not a seek")
    }

    func test_backwardJitter_atThresholdEdge_stillHolds() {
        let r = step(10.0, 7.0, threshold: 3.0)   // exactly 3s back = still jitter (not beyond)
        XCTAssertEqual(r.value, 10.0, accuracy: 1e-9, "a backward step at the threshold edge still holds")
        XCTAssertEqual(r.step, .advance)
    }

    // ── A backward step BEYOND threshold is a real external seek: FOLLOW it ──

    func test_backwardBeyondThreshold_followsAsSeek() {
        let r = step(10.0, 5.0, threshold: 3.0)   // 5s back = external scrub
        XCTAssertEqual(r.value, 5.0, accuracy: 1e-9, "a beyond-threshold backward jump must follow (external seek)")
        XCTAssertEqual(r.step, .seek, "beyond-threshold backward is a real discontinuity")
    }

    // ── An explicit (in-app) seek always follows, even a tiny backward one ──

    func test_explicitSeek_alwaysFollows_evenSmallBackward() {
        let r = step(10.0, 9.0, seek: true, threshold: 3.0)   // only 1s back but explicit
        XCTAssertEqual(r.value, 9.0, accuracy: 1e-9, "an explicit seek always follows the raw clock")
        XCTAssertEqual(r.step, .seek)
    }

    func test_explicitSeek_forwardJump_follows() {
        let r = step(10.0, 40.0, seek: true)
        XCTAssertEqual(r.value, 40.0, accuracy: 1e-9)
        XCTAssertEqual(r.step, .seek)
    }

    // ── The core invariant: a jittery non-seek stream comes out MONOTONE ──

    func test_jitteryStream_isMonotoneAcrossNonSeekPlayback() {
        let raw: [TimeInterval] = [1.0, 2.0, 1.8, 3.0, 2.6, 4.0, 3.9, 5.0]
        var previous = raw[0]
        var out: [TimeInterval] = [previous]
        for t in raw.dropFirst() {
            let r = step(previous, t, threshold: 3.0)
            XCTAssertEqual(r.step, .advance, "no sub-threshold dip is a seek")
            previous = r.value
            out.append(previous)
        }
        // Monotone non-decreasing, and the peak is preserved (never rewinds for jitter).
        for i in 1..<out.count {
            XCTAssertGreaterThanOrEqual(out[i], out[i - 1], "render clock must never move backward for jitter: \(out)")
        }
        XCTAssertEqual(out.last ?? -1, 5.0, accuracy: 1e-9, "forward recovery past the peak resumes tracking")
    }

    // ── Recovery: once real time climbs back past the held peak, the clock tracks again ──

    func test_holdThenRecover_resumesTrackingAfterPeak() {
        var previous = 10.0
        previous = step(previous, 8.5).value    // dip -> hold at 10
        XCTAssertEqual(previous, 10.0, accuracy: 1e-9)
        previous = step(previous, 9.8).value    // still below peak -> hold
        XCTAssertEqual(previous, 10.0, accuracy: 1e-9)
        previous = step(previous, 10.4).value   // climbs past peak -> track
        XCTAssertEqual(previous, 10.4, accuracy: 1e-9, "clock resumes tracking once raw time passes the held peak")
    }
}
