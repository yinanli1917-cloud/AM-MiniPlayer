import XCTest
import MusicKit
@testable import MusicMiniPlayerCore

/// "No lyrics exist" and "the internet is down" must never be confused
/// (review #3): the ledger classifies every request outcome at the HTTP
/// choke point — a protocol response (any status) proves the network works,
/// a transport failure proves nothing about the song, and cancellation is
/// excluded from BOTH counters (the time-budget loop cancels stragglers on
/// every normal fetch). These tests pin the classification table, the
/// verdict truth table, and the default-allow task-local contract that
/// keeps the LyricsVerifier CLI behaviorally unchanged.
final class NetworkOutcomeLedgerTests: XCTestCase {

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Classification table
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Every URLError code that means "no server ever answered" — dead in
    /// DNS, TCP, radio policy, or the TLS handshake (captive portals).
    func testTransportFailureCodes() {
        let transportCodes: [URLError.Code] = [
            .timedOut,
            .cannotFindHost,
            .dnsLookupFailed,
            .cannotConnectToHost,
            .networkConnectionLost,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .dataNotAllowed,
            .secureConnectionFailed,
            .serverCertificateUntrusted,
            .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid
        ]
        for code in transportCodes {
            XCTAssertEqual(
                NetworkOutcomeLedger.classify(failure: URLError(code)),
                .transportFailure,
                "URLError(\(code.rawValue)) must classify as transport failure"
            )
        }
    }

    /// Cancellation says nothing about the network. Both spellings —
    /// URLSession's URLError(.cancelled) and Swift concurrency's
    /// CancellationError — must be excluded.
    func testCancellationIsExcluded() {
        XCTAssertEqual(NetworkOutcomeLedger.classify(failure: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(NetworkOutcomeLedger.classify(failure: CancellationError()), .cancelled)
    }

    /// Errors that imply the server DID answer (garbled body, redirect
    /// loops) or are local programming errors must stay indeterminate —
    /// an unknown error must never be able to flip the verdict to
    /// "network unreachable".
    func testNonTransportErrorsAreIndeterminate() {
        let indeterminateCodes: [URLError.Code] = [
            .badURL,
            .unsupportedURL,
            .badServerResponse,
            .cannotParseResponse,
            .httpTooManyRedirects,
            .zeroByteResource
        ]
        for code in indeterminateCodes {
            XCTAssertEqual(
                NetworkOutcomeLedger.classify(failure: URLError(code)),
                .indeterminate,
                "URLError(\(code.rawValue)) must stay indeterminate"
            )
        }
        // HTTP status errors are raised AFTER the protocol response was
        // already recorded at the choke point — classifying them again must
        // contribute nothing.
        XCTAssertEqual(NetworkOutcomeLedger.classify(failure: HTTPClient.HTTPError.notFound), .indeterminate)
        XCTAssertEqual(NetworkOutcomeLedger.classify(failure: HTTPClient.HTTPError.httpError(statusCode: 503)), .indeterminate)
        XCTAssertEqual(NetworkOutcomeLedger.classify(failure: HTTPClient.HTTPError.decodingFailed), .indeterminate)
        // Arbitrary non-URL errors (e.g. thrown by JSON handling).
        XCTAssertEqual(
            NetworkOutcomeLedger.classify(failure: NSError(domain: "test", code: 1)),
            .indeterminate
        )
    }

    /// Provider-CONFIG failures (latency-regression item D verification pin).
    /// MusicKit token errors never route through the ledger at all — the only
    /// recording sites are HTTPClient's two URLSession choke points, and
    /// MusicKit owns its own transport. But even if a future refactor ever
    /// forwarded them, a missing-entitlement config failure proves nothing
    /// about the network: it must classify as indeterminate, never count as
    /// a transport death (which would block the negative-verdict quorum),
    /// and never fake a "network unreachable" verdict.
    func testMusicKitTokenConfigFailureIsIndeterminate() {
        XCTAssertEqual(
            NetworkOutcomeLedger.classify(failure: MusicTokenRequestError.developerTokenRequestFailed),
            .indeterminate
        )

        let ledger = NetworkOutcomeLedger()
        ledger.record(failure: MusicTokenRequestError.developerTokenRequestFailed)
        XCTAssertEqual(ledger.transportFailures, 0)
        XCTAssertFalse(ledger.hadTransportFailures, "config failure must not block the quorum")
        XCTAssertFalse(ledger.indicatesNetworkUnreachable)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Counter routing
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    func testRecordingRoutesByClassification() {
        let ledger = NetworkOutcomeLedger()

        ledger.recordProtocolResponse()
        ledger.record(failure: URLError(.timedOut))            // transport
        ledger.record(failure: URLError(.cancelled))           // excluded
        ledger.record(failure: CancellationError())            // excluded
        ledger.record(failure: HTTPClient.HTTPError.notFound)  // excluded
        ledger.record(failure: URLError(.badServerResponse))   // excluded

        XCTAssertEqual(ledger.protocolResponses, 1)
        XCTAssertEqual(ledger.transportFailures, 1, "only the timeout may count as a transport failure")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Verdict truth table
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Zero traffic is NOT "unreachable" — a fully cache-served fetch must
    /// never claim the internet is down.
    func testFreshLedgerIsNotUnreachable() {
        let ledger = NetworkOutcomeLedger()
        XCTAssertFalse(ledger.indicatesNetworkUnreachable)
        XCTAssertFalse(ledger.hadTransportFailures)
    }

    func testZeroResponsesPlusTransportDeathsMeansUnreachable() {
        let ledger = NetworkOutcomeLedger()
        ledger.record(failure: URLError(.notConnectedToInternet))
        ledger.record(failure: URLError(.timedOut))
        XCTAssertTrue(ledger.indicatesNetworkUnreachable)
        XCTAssertTrue(ledger.hadTransportFailures)
    }

    /// One real answer disproves "network unreachable" — even with six dead
    /// requests around it (the flaky-network case from the review). The
    /// transport deaths still block the 24h negative verdict via the quorum.
    func testAnyProtocolResponseDisprovesUnreachable() {
        let ledger = NetworkOutcomeLedger()
        ledger.recordProtocolResponse()
        for _ in 0..<6 { ledger.record(failure: URLError(.cannotConnectToHost)) }
        XCTAssertFalse(ledger.indicatesNetworkUnreachable)
        XCTAssertTrue(ledger.hadTransportFailures, "quorum must still report the deaths")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Task-local binding + default-allow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// The contract that keeps LyricsVerifier behaviorally unchanged: no
    /// binding → no ledger → recording no-ops and the persistence quorum
    /// passes, exactly as before the ledger existed.
    func testUnboundDefaultsAllowEverything() {
        XCTAssertNil(NetworkOutcomeLedger.current, "no ledger may be bound by default")
        XCTAssertTrue(
            LyricsFetcher.shared.negativeVerdictQuorumMet,
            "unbound fetches must persist availability verdicts exactly as before"
        )
    }

    func testBoundLedgerGatesQuorumOnTransportFailures() async {
        let ledger = NetworkOutcomeLedger()
        await NetworkOutcomeLedger.$current.withValue(ledger) {
            XCTAssertTrue(LyricsFetcher.shared.negativeVerdictQuorumMet, "clean fetch → quorum met")
            ledger.record(failure: URLError(.timedOut))
            XCTAssertFalse(LyricsFetcher.shared.negativeVerdictQuorumMet, "transport death → quorum unmet")
        }
        XCTAssertNil(NetworkOutcomeLedger.current, "binding must not leak past withValue")
    }

    /// fetchAllSources fans out via task groups — child tasks must inherit
    /// the binding so their request outcomes land in the SAME ledger.
    func testChildTasksInheritBinding() async {
        let ledger = NetworkOutcomeLedger()
        await NetworkOutcomeLedger.$current.withValue(ledger) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        NetworkOutcomeLedger.current?.record(failure: URLError(.timedOut))
                    }
                }
                await group.waitForAll()
            }
        }
        XCTAssertEqual(ledger.transportFailures, 4)
    }

    /// Detached tasks do NOT inherit task-locals — this is why the backfill
    /// binds its own ledger, and why a foreground binding can never bleed
    /// into the detached preload/backfill pipelines.
    func testDetachedTasksDoNotInheritBinding() async {
        let ledger = NetworkOutcomeLedger()
        await NetworkOutcomeLedger.$current.withValue(ledger) {
            await Task.detached {
                XCTAssertNil(NetworkOutcomeLedger.current)
            }.value
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Choke-point wiring (live URLSession, no internet required)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// End-to-end through the real HTTPClient.getData choke point.
    /// 192.0.2.1 is RFC 5737 TEST-NET — reserved, never routable — so the
    /// request must die in transport (timedOut / cannotConnectToHost /
    /// notConnectedToInternet, ALL transport rows) in every network
    /// condition, online or offline. This pins the recording wiring that
    /// the pure-table tests above cannot see.
    func testChokePointRecordsTransportDeathIntoBoundLedger() async {
        let ledger = NetworkOutcomeLedger()
        await NetworkOutcomeLedger.$current.withValue(ledger) {
            _ = try? await HTTPClient.getData(
                url: URL(string: "http://192.0.2.1/lyrics")!,
                timeout: 1.0,
                retry: false
            )
        }
        XCTAssertEqual(ledger.protocolResponses, 0)
        XCTAssertGreaterThanOrEqual(ledger.transportFailures, 1)
        XCTAssertTrue(ledger.indicatesNetworkUnreachable)
    }

    /// Recordings arrive concurrently from parallel source fetchers — the
    /// counters must not lose increments.
    func testConcurrentRecordingIsLossless() async {
        let ledger = NetworkOutcomeLedger()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    if i.isMultiple(of: 2) {
                        ledger.recordProtocolResponse()
                    } else {
                        ledger.record(failure: URLError(.networkConnectionLost))
                    }
                }
            }
            await group.waitForAll()
        }
        XCTAssertEqual(ledger.protocolResponses, 100)
        XCTAssertEqual(ledger.transportFailures, 100)
    }
}
