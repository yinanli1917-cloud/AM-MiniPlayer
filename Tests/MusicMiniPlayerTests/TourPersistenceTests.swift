import XCTest
@testable import MusicMiniPlayerCore

/// TourPersistence round-trips (§5.3), the legacy-C6-key one-time read
/// (§5.6), and the `shouldPresent` precondition gate (§5.5) — all against an
/// isolated `UserDefaults` suite, never the real domain.
final class TourPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TourPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_roundTrip_statusAndCompletedSteps() {
        var state = TourState()
        state.status = .inProgress
        state.stepStates[.connect] = .completed
        state.stepStates[.reveal] = .completed
        state.stepStates[.corners] = .skipped
        state.resumeCount = 2

        TourPersistence.save(state, to: defaults)
        let loaded = TourPersistence.load(from: defaults)

        XCTAssertEqual(loaded.status, .inProgress)
        XCTAssertEqual(loaded.completedSteps, [.connect, .reveal])
        XCTAssertEqual(loaded.resumeCount, 2)
        XCTAssertEqual(defaults.integer(forKey: TourPersistence.schemaKey), TourPersistence.currentSchema)
    }

    func test_roundTrip_deferredTranslate_carriesAttemptsAndRearmsIdle() {
        var state = TourState()
        state.status = .completed
        state.stepStates[.translate] = .deferred
        state.deferredAttempts = 2

        TourPersistence.save(state, to: defaults)
        let loaded = TourPersistence.load(from: defaults)

        XCTAssertEqual(loaded.stepStates[.translate], .deferred)
        XCTAssertEqual(loaded.deferredAttempts, 2)
        XCTAssertEqual(loaded.phase, .idle(deferredArmed: true))
    }

    func test_save_clearsDeferredKey_onceResolved() {
        var state = TourState()
        state.stepStates[.translate] = .deferred
        state.deferredAttempts = 1
        TourPersistence.save(state, to: defaults)
        XCTAssertNotNil(defaults.dictionary(forKey: TourPersistence.deferredKey))

        state.stepStates[.translate] = .completed
        TourPersistence.save(state, to: defaults)
        XCTAssertNil(defaults.dictionary(forKey: TourPersistence.deferredKey))
    }

    func test_load_freshDefaults_isNotStarted() {
        let loaded = TourPersistence.load(from: defaults)
        XCTAssertEqual(loaded.status, .notStarted)
        XCTAssertTrue(loaded.completedSteps.isEmpty)
    }

    func test_legacyOnboardingKeys_readOnlyOnce_doesNotBlockFreshSchemaWrite() {
        defaults.set(true, forKey: "nanoPodOnboardingCompleted")
        defaults.set(1, forKey: "nanoPodOnboardingSchema")

        let loaded = TourPersistence.load(from: defaults)
        // All v3 steps are introducedIn == 2 (new relative to C6's schema 1)
        // — a completed C6 run does not exempt the user from any v3 step.
        XCTAssertEqual(loaded.status, .notStarted)
        XCTAssertEqual(defaults.integer(forKey: TourPersistence.schemaKey), TourPersistence.currentSchema)

        // The migration only ever runs once — writing a DIFFERENT status
        // after the schema key exists must not be clobbered by a second read.
        var inProgress = loaded
        inProgress.status = .inProgress
        TourPersistence.save(inProgress, to: defaults)
        XCTAssertEqual(TourPersistence.load(from: defaults).status, .inProgress)
    }

    func test_reset_clearsAllKeys() {
        var state = TourState()
        state.status = .completed
        TourPersistence.save(state, to: defaults)
        TourPersistence.reset(defaults)
        // Check the raw keys are gone BEFORE calling load() — load() itself
        // re-stamps the schema key (the one-time migration guard), which is
        // correct behavior but would make this assertion pass vacuously if
        // checked afterward.
        XCTAssertNil(defaults.object(forKey: TourPersistence.schemaKey))
        XCTAssertNil(defaults.object(forKey: TourPersistence.statusKey))
        XCTAssertEqual(TourPersistence.load(from: defaults).status, .notStarted)
    }

    // MARK: - shouldPresent (§5.5)

    func test_shouldPresent_table() {
        XCTAssertTrue(TourPersistence.shouldPresent(status: .notStarted, resumeCount: 0, forced: false))
        XCTAssertTrue(TourPersistence.shouldPresent(status: .inProgress, resumeCount: 0, forced: false))
        XCTAssertTrue(TourPersistence.shouldPresent(status: .inProgress, resumeCount: 2, forced: false))
        XCTAssertFalse(TourPersistence.shouldPresent(status: .inProgress, resumeCount: 3, forced: false))
        XCTAssertFalse(TourPersistence.shouldPresent(status: .completed, resumeCount: 0, forced: false))
        XCTAssertFalse(TourPersistence.shouldPresent(status: .skipped, resumeCount: 0, forced: false))
        XCTAssertTrue(TourPersistence.shouldPresent(status: .completed, resumeCount: 0, forced: true))
        XCTAssertTrue(TourPersistence.shouldPresent(status: .skipped, resumeCount: 99, forced: true))
    }
}
