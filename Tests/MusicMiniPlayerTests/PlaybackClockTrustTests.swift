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
