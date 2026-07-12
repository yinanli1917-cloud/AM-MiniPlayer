import XCTest
@testable import MusicMiniPlayerCore

/// Bounded time-to-terminal for the lyrics miss path (review #6+#7 merged).
///
/// A track with no lyrics anywhere used to hold the spinner ~18s: the
/// authoritative backfill drained ALL children with no ceiling, and the
/// alias-witness child was never wrapped in a timeout. These tests pin the
/// corrected budget arithmetic (every child bounded end-to-end, an overall
/// sentinel sized ABOVE the longest legitimate chain), the unclamped
/// evidence-window rule for marker-only foreground exits, and the #7
/// requirement that the parallel alias-discovery merge reproduces the serial
/// code's result order exactly.
final class AuthoritativeBackfillBudgetTests: XCTestCase {

    private typealias Budget = LyricsFetcher.AuthoritativeBackfillBudget

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Corrected budget arithmetic (review #6)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// The composites must equal the sum of their phases. If someone widens
    /// an inner phase without rethinking the outer wrap, the end-to-end cap
    /// would silently clip the inner work — this test makes that a failure.
    func testCompositeBudgetsEqualTheirPhaseSums() {
        XCTAssertEqual(
            Budget.albumScopedComposite,
            Budget.albumScopedMetadataResolve + Budget.albumScopedProbe,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            Budget.resolvedComposite,
            Budget.resolvedMetadataResolve + Budget.resolvedProbe,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            Budget.witnessComposite,
            Budget.witnessDiscovery + Budget.witnessProbe,
            accuracy: 0.0001
        )
    }

    /// The corrected numbers themselves: album-scoped 7.7 (3.2 + 4.5),
    /// resolved 6.0 (2.8 + 3.2), witness 9.0 (3.0 discovery + 6.0 probe —
    /// the review correction "discovery cap plus probe time, ~3s + 6s").
    func testCorrectedPhaseValues() {
        XCTAssertEqual(Budget.albumScopedMetadataResolve, 3.2, accuracy: 0.0001)
        XCTAssertEqual(Budget.albumScopedProbe, 4.5, accuracy: 0.0001)
        XCTAssertEqual(Budget.albumScopedComposite, 7.7, accuracy: 0.0001)
        XCTAssertEqual(Budget.resolvedMetadataResolve, 2.8, accuracy: 0.0001)
        XCTAssertEqual(Budget.resolvedProbe, 3.2, accuracy: 0.0001)
        XCTAssertEqual(Budget.resolvedComposite, 6.0, accuracy: 0.0001)
        XCTAssertEqual(Budget.witnessDiscovery, 3.0, accuracy: 0.0001)
        XCTAssertEqual(Budget.witnessProbe, 6.0, accuracy: 0.0001)
        XCTAssertEqual(Budget.witnessComposite, 9.0, accuracy: 0.0001)
    }

    /// The sentinel must sit ABOVE the longest legitimate chain (the
    /// album-scoped composite, 7.7s) — review correction: "size the sentinel
    /// above the longest legitimate chain (~8-10s)" — and must never
    /// undercut ANY individually bounded child, or it would clip work the
    /// child wrapper explicitly allows.
    func testOverallSentinelSitsAboveEveryLegitimateChain() {
        XCTAssertGreaterThan(Budget.overall, Budget.albumScopedComposite)
        XCTAssertGreaterThanOrEqual(Budget.overall, Budget.longestChildCeiling)
        XCTAssertGreaterThanOrEqual(Budget.overall, 8.0)
        XCTAssertLessThanOrEqual(Budget.overall, 10.0)
        // With every child wrapped, the group's structural drain ceiling IS
        // the largest child cap — the sentinel should match it exactly so a
        // total miss never idles past the slowest legitimate child.
        XCTAssertEqual(Budget.overall, Budget.longestChildCeiling, accuracy: 0.0001)
    }

    /// Simple source children keep their existing per-source timeouts — the
    /// bounded-deadline change must not shrink any source's legitimate
    /// chance to answer ("WITHOUT cutting any source's chance").
    func testSimpleSourceChildCapsAreUnchanged() {
        XCTAssertEqual(Budget.lrclibChild, 3.2, accuracy: 0.0001)
        XCTAssertEqual(Budget.lrclibSearchChild, 3.2, accuracy: 0.0001)
        XCTAssertEqual(Budget.netEaseChild, 4.8, accuracy: 0.0001)
        XCTAssertEqual(Budget.qqChild, 3.2, accuracy: 0.0001)
        XCTAssertEqual(Budget.albumTitleEchoChild, 2.9, accuracy: 0.0001)
        for cap in [Budget.lrclibChild, Budget.lrclibSearchChild,
                    Budget.netEaseChild, Budget.qqChild,
                    Budget.albumTitleEchoChild] {
            XCTAssertLessThanOrEqual(cap, Budget.overall)
        }
    }

    func testClippedOrTransportDegradedSweepIsIncomplete() {
        XCTAssertFalse(LyricsFetcher.backfillSweepIsIncomplete(
            deadlineClipped: false,
            hadTransportFailures: false
        ))
        XCTAssertTrue(LyricsFetcher.backfillSweepIsIncomplete(
            deadlineClipped: true,
            hadTransportFailures: false
        ))
        XCTAssertTrue(LyricsFetcher.backfillSweepIsIncomplete(
            deadlineClipped: false,
            hadTransportFailures: true
        ))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Marker-only fast exit: unclamped evidence windows (review #7)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// A truly-empty result set keeps the historical clamp: nothing answered
    /// by the empty deadline, the fetch is over — pending branch or not.
    func testTrulyEmptySetClampsEvidenceWindowToEmptyDeadline() {
        XCTAssertEqual(
            LyricsFetcher.emptyPathEvidenceWindow(
                landingDeadline: 2.85,
                emptyResultDeadline: 2.2,
                resultSetIsTrulyEmpty: true
            ),
            2.2,
            accuracy: 0.0001
        )
        // When the landing window is the shorter one, the clamp is inert.
        XCTAssertEqual(
            LyricsFetcher.emptyPathEvidenceWindow(
                landingDeadline: 2.2,
                emptyResultDeadline: 2.95,
                resultSetIsTrulyEmpty: true
            ),
            2.2,
            accuracy: 0.0001
        )
    }

    /// Marker-only sets use the UNCLAMPED window (required correction from
    /// the #6 adversarial review): a provider answered "track found, no
    /// lyric text", and a fired album-scoped / native-title branch keeps its
    /// full landing chance — real lyrics may still land under an alias.
    func testMarkerOnlySetKeepsUnclampedEvidenceWindow() {
        XCTAssertEqual(
            LyricsFetcher.emptyPathEvidenceWindow(
                landingDeadline: 2.85,
                emptyResultDeadline: 2.2,
                resultSetIsTrulyEmpty: false
            ),
            2.85,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            LyricsFetcher.emptyPathEvidenceWindow(
                landingDeadline: 2.95,
                emptyResultDeadline: 2.2,
                resultSetIsTrulyEmpty: false
            ),
            2.95,
            accuracy: 0.0001
        )
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Parallel alias-discovery merge order (review #7 required test)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// The factorization claim behind the parallel discovery: per-search
    /// extraction with per-slice dedup, followed by the ordered merge, must
    /// produce the IDENTICAL alias list the old serial loop produced with
    /// its single running dedup over the same response streams.
    func testParallelAliasMergeMatchesSerialOrderForFixtureResponses() {
        // Raw per-search alias streams exactly as the old serial loop saw
        // them — duplicates inside one search and across searches, plus an
        // empty search response.
        let rawSearchStreams: [[String]] = [
            ["初恋", "初戀", "初恋"],
            [],
            ["快节奏", "初恋", "二十岁的浪漫"],
            ["二十岁的浪漫", "快节奏", "告白气球"]
        ]

        // Serial oracle — the exact running-dedup fold the old code applied
        // while walking search responses one at a time.
        var serial: [String] = []
        for stream in rawSearchStreams {
            for alias in stream where !serial.contains(alias) {
                serial.append(alias)
            }
        }

        // New pipeline: each search extracts its slice independently
        // (deduped within the slice, encounter order kept) ...
        let slices = rawSearchStreams.map { stream -> [String] in
            var slice: [String] = []
            for alias in stream where !slice.contains(alias) {
                slice.append(alias)
            }
            return slice
        }

        // ... and the ordered merge reassembles them.
        XCTAssertEqual(LyricsFetcher.mergeOrderedDiscoveryPasses(slices), serial)
        XCTAssertEqual(serial, ["初恋", "初戀", "快节奏", "二十岁的浪漫", "告白气球"])
    }

    /// Same property one level up: per-pass probe lists merged across passes
    /// must equal the old `appendProbes` fold (cross-pass dedup keeping the
    /// first occurrence, pass order preserved).
    func testParallelProbeMergeMatchesSerialAppendProbesFold() {
        typealias Probe = LyricsFetcher.NativeTitleAliasProbe
        let passProbes: [[Probe]] = [
            [Probe(title: "初恋", artist: "宇多田光"), Probe(title: "初戀", artist: "宇多田光")],
            [Probe(title: "初恋", artist: "宇多田光"), Probe(title: "光", artist: "宇多田光")],
            [],
            [Probe(title: "光", artist: "宇多田光"), Probe(title: "Flavor Of Life", artist: "宇多田光")]
        ]

        // Serial oracle — the old appendProbes loop.
        var serial: [Probe] = []
        for probes in passProbes {
            for probe in probes where !serial.contains(probe) {
                serial.append(probe)
            }
        }

        XCTAssertEqual(LyricsFetcher.mergeOrderedDiscoveryPasses(passProbes), serial)
        XCTAssertEqual(serial.map(\.title), ["初恋", "初戀", "光", "Flavor Of Life"])
    }

    /// Degenerate inputs the deadline can produce: all slices empty (every
    /// search clipped) and no passes at all.
    func testMergeHandlesClippedAndEmptyDiscovery() {
        XCTAssertEqual(LyricsFetcher.mergeOrderedDiscoveryPasses([[String]]()), [])
        XCTAssertEqual(LyricsFetcher.mergeOrderedDiscoveryPasses([[], [], []] as [[String]]), [])
    }
}
