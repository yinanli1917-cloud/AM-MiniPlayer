/**
 * [INPUT]: MusicMiniPlayerCore PlaybackPositionCorrectionPolicy
 * [OUTPUT]: Unit tests for slow-read clock-sync trust (drift-oscillation defect)
 * [POS]: Test module. Pins the 2026-07-17 live-log defect: a 743ms ScriptingBridge
 *        read produced drift=-0.58s then +0.60s one second later — the correction
 *        magnitude equalled the read latency, i.e. pure measurement staleness.
 *        The policy must suppress corrections smaller than the read's own
 *        uncertainty while still landing real jumps (seek, late track discovery).
 */

import XCTest
@testable import MusicMiniPlayerCore

final class PlaybackClockTrustTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Fast reads are always trusted
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_fastRead_isTrusted_regardlessOfDrift() {
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: 0.0, readLatency: 0.02))
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: 0.60, readLatency: 0.04))
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: -0.35, readLatency: 0.10))
    }

    func test_latencyExactlyAtThreshold_isTrusted() {
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: -0.58, readLatency: PlaybackPositionCorrectionPolicy.trustedReadLatency))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - The live defect case: correction within read uncertainty
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_slowRead_driftWithinUncertainty_isSuppressed() {
        // 2026-07-17 21:55:22 log: sbRead=743.5ms → drift=-0.58 (then +0.60 counter-snap)
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: -0.58, readLatency: 0.7435))
        // Mid-range slow reads with sub-uncertainty drift
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: 0.40, readLatency: 0.30))
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: -0.52, readLatency: 0.35))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Real jumps land even from slow reads
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func test_slowRead_largeDrift_isTrusted() {
        // 2026-07-17 21:49:36 log: sbRead=403.1ms → drift=+3.22 (late track discovery)
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: 3.22, readLatency: 0.4031))
        // Seek recovery through a saturated bridge
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: -12.64, readLatency: 0.70))
    }

    func test_slowRead_driftJustAboveUncertainty_isTrusted() {
        // uncertainty = readLatency + margin = 0.30 + 0.25 = 0.55
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: 0.56, readLatency: 0.30))
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldTrustPolledPositionForClockSync(
            drift: 0.55, readLatency: 0.30))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Stage bundle 3i item 2 (founder real-device log, /tmp/nanopod_debug.log
// 2026-09-18 15:01:38): playing mid-song (83.2s) then restarting the SAME
// track from 0 ("从头播", not through MusicController.seek() — e.g. the
// system Now Playing widget / Music.app itself). The SAME poll that measures
// the real 83.2s→0.0s drop already fires the app's OWN "position jumped
// back" detector (the radio-song-change backstop, `positionJumpedBack` in
// MusicController.pollPositionViaSB) — but that detector's verdict was never
// shared with `shouldDeferTransientReset`/the velocity-pause inference, which
// independently re-derive "is this poll real" from the SAME position/duration
// numbers and reach the OPPOSITE conclusion: "one-off transient glitch,
// defer" (logged 3x as "TRANSIENT POSITION RESET: ignored") and "the player
// must have silently paused" (logged as "VELOCITY PAUSE ... inferring
// pause"). Real log: three consecutive deferrals hit the
// maxConsecutiveTransientResetDeferrals cap before the clock finally landed
// ~1s late via DRIFT CORRECTION, and isPlaying flipped false in between with
// no user pause action.
//
// Fix direction: a poll that already qualifies as a confirmed backward jump
// (`positionJumpedBack`) is not "unconfirmed single-poll noise" by
// definition — it must never be deferred and must never be reinterpreted as
// a pause, regardless of which internal detector noticed it first.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension PlaybackClockTrustTests {

    // MARK: - shouldDeferTransientReset must not defer a confirmed position jump

    func test_confirmedPositionJump_isNeverDeferred_evenWithinDeferralCap() {
        // Exact real-log shape: was at 83.2s (interpolated), polled reads 0.0s,
        // duration far from ending, still playing, no seek in flight — all the
        // OLD conditions that used to defer it.
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
            polledPosition: 0.0, interpolatedPosition: 83.2, duration: 240,
            isPlaying: true, seekPending: false, consecutiveDeferrals: 0,
            positionJumpedBack: false),
            "sanity: without positionJumpedBack, the OLD heuristic still defers")

        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
            polledPosition: 0.0, interpolatedPosition: 83.2, duration: 240,
            isPlaying: true, seekPending: false, consecutiveDeferrals: 0,
            positionJumpedBack: true),
            "FIX: a poll the app's own position-jump detector already confirmed as real " +
            "must land immediately, not be deferred as transient noise")

        // Must also override on later deferral counts (0, 1, 2 — all below the cap), not
        // just the first call.
        for n in 0..<PlaybackPositionCorrectionPolicy.maxConsecutiveTransientResetDeferrals {
            XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldDeferTransientReset(
                polledPosition: 0.0, interpolatedPosition: 83.2, duration: 240,
                isPlaying: true, seekPending: false, consecutiveDeferrals: n,
                positionJumpedBack: true),
                "FIX: confirmed jump must never defer, deferral count \(n)")
        }
    }

    // MARK: - Velocity-pause inference must not fire on a confirmed position jump

    func test_velocityPauseInference_suppressedByConfirmedPositionJump() {
        // Real log shape: deficit = expected(83.2) - polled(0.0) = 83.2, way over
        // the 0.8s threshold that (alone) used to infer a silent pause.
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldInferPauseFromVelocityDeficit(
            deficit: 83.2, positionJumpedBack: false),
            "sanity: without positionJumpedBack, the OLD heuristic still infers pause")

        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldInferPauseFromVelocityDeficit(
            deficit: 83.2, positionJumpedBack: true),
            "FIX: a confirmed position jump is a restart/seek, not a silent pause — " +
            "must not flip isPlaying to false")

        // Ordinary small deficits (real transient lag, no jump detected) keep working as before.
        XCTAssertFalse(PlaybackPositionCorrectionPolicy.shouldInferPauseFromVelocityDeficit(
            deficit: 0.5, positionJumpedBack: false))
        XCTAssertTrue(PlaybackPositionCorrectionPolicy.shouldInferPauseFromVelocityDeficit(
            deficit: 0.9, positionJumpedBack: false))
    }
}
