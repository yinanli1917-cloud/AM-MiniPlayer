import XCTest
import MusicKit
@testable import MusicMiniPlayerCore

/// Dev builds without the MusicKit entitlement fail EVERY AppleMusic lyrics
/// fetch with "Failed to request developer token". That capability is fixed
/// at code-signing time, so retrying within the same process is pure waste
/// (2-3 doomed requests plus error lines per song, observed in the Live log).
/// The latch records the FIRST developer-token failure and skips the source
/// for the rest of the process. Capability, not configuration: MusicKit-
/// entitled builds never throw the arming error, so they never arm it.
final class AppleMusicCapabilityLatchTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Arm / skip
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testFreshLatchIsDisarmed() {
        XCTAssertFalse(AppleMusicCapabilityLatch().isArmed)
    }

    func testDeveloperTokenFailureArmsTheLatch() {
        let latch = AppleMusicCapabilityLatch()
        XCTAssertEqual(
            latch.record(MusicTokenRequestError.developerTokenRequestFailed),
            .armed
        )
        XCTAssertTrue(latch.isArmed)
    }

    /// The `.armed` transition fires exactly once — it is the signal for the
    /// single "source disabled for this process" log line, so a second
    /// concurrent failure must report `.alreadyArmed` and stay silent.
    func testArmTransitionIsReportedExactlyOnce() {
        let latch = AppleMusicCapabilityLatch()
        XCTAssertEqual(latch.record(MusicTokenRequestError.developerTokenRequestFailed), .armed)
        XCTAssertEqual(latch.record(MusicTokenRequestError.developerTokenRequestFailed), .alreadyArmed)
        XCTAssertTrue(latch.isArmed)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Errors that must never arm
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Transient transport errors and Swift-concurrency cancellation say
    /// nothing about the process's MusicKit capability. Account-state token
    /// errors (signed out, user-token failure) can change mid-process, so
    /// they must not permanently disable the source either.
    func testNonCapabilityErrorsNeverArm() {
        let latch = AppleMusicCapabilityLatch()
        let transientErrors: [Error] = [
            URLError(.timedOut),
            URLError(.cancelled),
            CancellationError(),
            MusicTokenRequestError.userNotSignedIn,
            MusicTokenRequestError.userTokenRequestFailed
        ]
        for error in transientErrors {
            XCTAssertEqual(
                latch.record(error),
                .notCapabilityFailure,
                "\(error) must not arm the capability latch"
            )
            XCTAssertFalse(latch.isArmed)
        }
    }

    /// Live-log evidence 2026-06-12 (session 10:02): an unauthorized dev
    /// build fails EVERY request with permissionDenied — same per-fetch
    /// waste as the token failure, and the error identity DRIFTED between
    /// sessions (morning: developerTokenRequestFailed; evening:
    /// permissionDenied). Authorization is process-permanent in practice;
    /// recovery after a real grant is one relaunch away.
    func testPermissionDeniedArmsTheLatch() {
        let latch = AppleMusicCapabilityLatch()
        XCTAssertEqual(
            latch.record(MusicTokenRequestError.permissionDenied),
            .armed
        )
        XCTAssertTrue(latch.isArmed)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Reset (test seam)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testResetDisarmsAndAllowsRearming() {
        let latch = AppleMusicCapabilityLatch()
        _ = latch.record(MusicTokenRequestError.developerTokenRequestFailed)
        XCTAssertTrue(latch.isArmed)

        latch.reset()
        XCTAssertFalse(latch.isArmed)
        XCTAssertEqual(
            latch.record(MusicTokenRequestError.developerTokenRequestFailed),
            .armed,
            "after reset the arm transition must be reportable again"
        )
    }
}
