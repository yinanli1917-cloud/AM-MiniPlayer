/**
 * [INPUT]: LyricsService.silentSystemTranslationConfiguration/
 *          registerPendingPieceTranslations/performPendingPieceTranslations/
 *          serveTranslationRequests/pieceTranslationSourceVersion/
 *          pieceTranslationVersion/resolvedTranslationSourceLanguageCode
 *          (Services/LyricsService.swift) + LyricPieceTranslation
 *          (UI/LyricPieceTranslation.swift) + PieceTranslationCache
 *          (Services/PieceTranslationCache.swift)
 * [OUTPUT]: Reproduces, then pins the fix for, the 2026-09-23 founder
 *           follow-up report (build 39d134a, "This Time" by Jeff Bernat):
 *           a Plan-A split line's pieces past the first NEVER got a
 *           translation when `LyricsView.makeDisplayLyricLines` ran (and
 *           found nothing to register, because `resolvedTranslationSourceLanguageCode`
 *           was still nil) BEFORE the song's translation source resolved,
 *           and nothing afterward ever asked it to run again.
 * [POS]: Tests -- exercises the real LyricsService API end to end (no fake
 *        clock; `TranslationRequestCoalescer`'s 0.05s delay and the on-device
 *        `TranslationAvailabilityMemo` status check are real, matching the
 *        existing PieceTranslationSessionWiringTests precedent). The one
 *        private-to-LyricsView piece of production logic this file cannot
 *        call directly -- `makeDisplayLyricLines`'s registration gate,
 *        `if pieceSourceCode != nil, !pendingPieceTranslationTexts.isEmpty` --
 *        is mirrored EXACTLY by `simulateDisplayLinesBuilt` below (see that
 *        function's header for the precise line references it must be kept
 *        in sync with). Likewise, LyricsView's
 *        `.onChange(of: pieceTranslationCombinedVersion)` reaction is
 *        mirrored by `reactToVersionChangesIfAny` in the permutation test.
 *        Both mirrors are intentionally thin (a handful of lines each,
 *        matching the untested-but-obviously-correct glue LyricsView
 *        already carries for `pieceTranslationVersion`) -- the SUBSTANTIVE
 *        logic under test here is entirely on the LyricsService side: when
 *        `pieceTranslationSourceVersion` bumps, and whether the serve loop
 *        drains already-registered work regardless of when it goes live.
 *
 * Root cause (2026-09-23 fix #2, see LyricsService.swift's
 * `pieceTranslationSourceVersion` doc comment and LyricsView.swift's
 * `pieceTranslationCombinedVersion` onChange): `resolvedSongTranslationSourceLanguage`
 * resolving was not an OBSERVABLE event before this fix -- nothing signaled
 * LyricsView to re-run `makeDisplayLyricLines` (and therefore re-attempt
 * registration) once it changed. A registration that happened to run before
 * resolution found `pieceSourceCode == nil` and skipped every piece for
 * good; the exact founder log order (`piece-translation tiers ... tier3Reason=
 * no session (source not resolved yet)` immediately followed by
 * `translation session ready`, then nothing) is precisely this.
 *
 * Manually verified RED before the fix (temporarily reverted
 * LyricsService.swift/LyricsView.swift to pre-fix content, with this test's
 * reactive retry neutered to match -- i.e. no signal-driven re-registration
 * at all, exactly pre-fix behavior): `test_displayLinesBuiltBeforeSourceResolves_thenSessionReady_allPiecesEventuallyTranslated`
 * failed both assertions ("the fake translator must actually have been
 * asked to translate a pending piece" / "every split piece past the first
 * must end up with its own real translation") -- pieces 1 and 2 stayed
 * stuck on tier `.none` forever, reproducing the founder's screenshot
 * exactly. GREEN after restoring the fix, both new tests pass.
 *
 * Safety: no network, no ~/Library/Application Support/nanoPod/ access --
 * same isolation as PieceTranslationSessionWiringTests (temp-file disk
 * cache, in-memory PieceTranslationCache reset via debugReset()). The one
 * real system call (`TranslationAvailabilityMemo` / on-device
 * `LanguageAvailability().status(from: en, to: zh-Hans)`) is memoized
 * process-wide after the first call, so running this many times is cheap.
 */

import XCTest
@testable import MusicMiniPlayerCore

@available(macOS 15.0, *)
@MainActor
final class PieceTranslationRebuildOrderingTests: XCTestCase {

    // MARK: - Shared fixture

    /// Mirrors the founder's screenshot: a long English line split into
    /// three pieces at a narrow width, with a whole-line Chinese translation
    /// from the lyrics source that does NOT split at the same cut points
    /// (so tier 1 -- clause alignment -- never applies here, matching the
    /// real log's `tier1_clauseAligned=0`). Pieces are fixed strings rather
    /// than run through `LyricDisplaySegmenter.realWrapPieces` at some
    /// narrow width -- deterministic, and the SPLIT itself is not what this
    /// bug is about (LongLineEvalTests already covers that machinery).
    private static let fixturePieces = [
        "It just didn't seem fair,",
        "wasn't going to be something",
        "that were a part of me",
    ]
    private static let fixtureFullTranslation = "看起来世事不公 可世界本就如此 哪都一样"

    private final class FakeExecutor: LyricsTranslationExecuting {
        private(set) var calls: [[String]] = []
        func translateBatch(_ texts: [String]) async throws -> [String] {
            calls.append(texts)
            return texts.map { "译:" + $0 }
        }
    }

    private var savedShowTranslation = false
    private var savedTranslationLanguage = "zh-Hans"
    private var savedDiskCache: TranslationDiskCache?

    override func setUp() {
        super.setUp()
        let service = LyricsService.shared
        savedShowTranslation = service.showTranslation
        savedTranslationLanguage = service.translationLanguage
        savedDiskCache = service.translationDiskCache
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation_cache_rebuild_ordering_test_\(UUID().uuidString).json")
        service.translationDiskCache = TranslationDiskCache(fileURL: tmp, persistDebounce: 0.05)
        #if DEBUG
        PieceTranslationCache.shared.debugReset()
        #endif
    }

    override func tearDown() async throws {
        let service = LyricsService.shared
        service.showTranslation = savedShowTranslation
        service.translationLanguage = savedTranslationLanguage
        if let savedDiskCache { service.translationDiskCache = savedDiskCache }
        service.resetTranslationRequestStream()
        #if DEBUG
        PieceTranslationCache.shared.debugReset()
        #endif
        try await super.tearDown()
    }

    /// Stand-in for `LyricsView.makeDisplayLyricLines`'s piece-translation
    /// registration slice (LyricsView.swift, the `pieceSourceCode`/
    /// `pieceCacheLookup` setup near the top of that function, and the
    /// `if pieceSourceCode != nil, !pendingPieceTranslationTexts.isEmpty`
    /// gate near its end). Must stay in exact behavioral sync with that
    /// code: given the piece texts and the whole line's translation, decide
    /// each piece's tier via the real `LyricPieceTranslation.pieceTranslations`
    /// pure function, and register (only) the pieces that came back tier
    /// `.none` -- but ONLY when a source language has already resolved,
    /// exactly like the production gate.
    private func simulateDisplayLinesBuilt(
        service: LyricsService,
        originalPieces: [String],
        fullTranslation: String?
    ) {
        let pieceSourceCode = service.resolvedTranslationSourceLanguageCode
        let targetCode = LyricsService.normalizedSystemTranslationLanguage(service.translationLanguage)
        let cache: (String) -> String? = { text in
            guard let pieceSourceCode else { return nil }
            return PieceTranslationCache.shared.translation(for: text, source: pieceSourceCode, target: targetCode)
        }
        let (_, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: originalPieces, fullTranslation: fullTranslation, cache: cache
        )
        let pending = zip(originalPieces, tiers).filter { $0.1 == .none }.map(\.0)
        if pieceSourceCode != nil, !pending.isEmpty {
            service.registerPendingPieceTranslations(pending)
        }
    }

    /// True once every piece except possibly the first (which tier 3 may
    /// legitimately fill with the whole-line translation) carries its own
    /// translation via a REAL tier (clause-aligned or per-piece cache) --
    /// the founder's acceptance bar: "every split piece eventually has its
    /// own translation".
    private func allNonFirstPiecesTranslated(
        service: LyricsService,
        pieces: [String],
        fullTranslation: String?
    ) -> Bool {
        let pieceSourceCode = service.resolvedTranslationSourceLanguageCode
        let targetCode = LyricsService.normalizedSystemTranslationLanguage(service.translationLanguage)
        let cache: (String) -> String? = { text in
            guard let pieceSourceCode else { return nil }
            return PieceTranslationCache.shared.translation(for: text, source: pieceSourceCode, target: targetCode)
        }
        let (translations, tiers) = LyricPieceTranslation.pieceTranslations(
            originalPieces: pieces, fullTranslation: fullTranslation, cache: cache
        )
        for index in pieces.indices where index > 0 {
            guard tiers[index] == .clauseAligned || tiers[index] == .perPieceCache,
                  translations[index] != nil else { return false }
        }
        return true
    }

    private func seed(service: LyricsService, title: String, pieces: [String], fullTranslation: String) {
        let line = LyricLine(
            text: pieces.joined(separator: " "),
            startTime: 0,
            endTime: 6,
            translation: fullTranslation
        )
        service.debugSeedDisplayedLyricsForTesting(
            [line], title: title, artist: "Founder-Repro", duration: 200, isUnsynced: false
        )
    }

    // MARK: - Test 1: exact real-world order from the log

    /// `/tmp/nanopod_debug.log` order: piece-translation tiers logged with
    /// `tier3Reason=no session (source not resolved yet)` (display lines
    /// built, source still nil) -- THEN `🈺 translation session ready` --
    /// THEN `🈺 translation config update gen=1` (source resolves AFTER).
    /// Nothing in the pre-fix code ever asked for a rebuild once the source
    /// caught up, so every piece past the first stayed untranslated forever.
    func test_displayLinesBuiltBeforeSourceResolves_thenSessionReady_allPiecesEventuallyTranslated() async throws {
        let service = LyricsService.shared
        service.showTranslation = true
        service.translationLanguage = "zh-Hans"
        let title = "PieceOrderRepro-exact-\(UUID().uuidString.prefix(8))"
        seed(service: service, title: title, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)

        // Step 1: display lines built BEFORE the source resolves.
        XCTAssertNil(
            service.resolvedTranslationSourceLanguageCode,
            "sanity: matches the real log order -- source not resolved yet at build time"
        )
        simulateDisplayLinesBuilt(service: service, originalPieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
        // Sanity: the pure tier decision itself, unmodified by this task,
        // reproduces the founder's screenshot exactly (tier1 never applies
        // here; piece 0 gets the fallback, pieces 1/2 get none).
        XCTAssertFalse(
            allNonFirstPiecesTranslated(service: service, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
        )

        // Step 2: source resolves, THEN the session becomes ready -- same
        // order as the log ("no session" line, then "session ready").
        let config = await service.silentSystemTranslationConfiguration()
        XCTAssertNotNil(config)
        XCTAssertNotNil(service.resolvedTranslationSourceLanguageCode)
        XCTAssertGreaterThan(
            service.pieceTranslationSourceVersion, 0,
            "the fix's signal must bump exactly when the source resolves"
        )

        let executor = FakeExecutor()
        let serveTask = Task { await service.serveTranslationRequests(with: executor) }

        // Nothing re-registers on its own unless something reacts to
        // `pieceTranslationSourceVersion` the way LyricsView's onChange
        // does. Play that role here explicitly, gated on the SAME published
        // signal the production onChange watches -- this is what actually
        // proves the fix's contract, not just that translation eventually
        // "happens somehow".
        var lastSeenSourceVersion = 0
        let deadline = Date().addingTimeInterval(3.0)
        while !allNonFirstPiecesTranslated(service: service, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation),
              Date() < deadline {
            if service.pieceTranslationSourceVersion != lastSeenSourceVersion {
                lastSeenSourceVersion = service.pieceTranslationSourceVersion
                simulateDisplayLinesBuilt(service: service, originalPieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(
            executor.calls.contains { $0.contains("wasn't going to be something") || $0.contains("that were a part of me") },
            "the fake translator must actually have been asked to translate a pending piece"
        )
        XCTAssertTrue(
            allNonFirstPiecesTranslated(service: service, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation),
            "every split piece past the first must end up with its own real translation, not stuck on tier 3/none forever"
        )

        // Fully retire the serve loop before returning -- see the matching
        // comment in the permutation test below for why a bare `.cancel()`
        // is not enough to keep this from leaking into the NEXT test.
        service.resetTranslationRequestStream()
        serveTask.cancel()
        await serveTask.value
    }

    // MARK: - Test 2: order-permutation property test

    private enum SimEvent: String, CaseIterable {
        case lyricsArrive
        case displayLinesBuilt
        case widthChangeResplit
        case sourceResolved
        case sessionReady
        case serveStreamReset
        case songChangeAndBack
        case translationToggleOffOn
    }

    /// Minimal seeded RNG (splitmix64) so permutations are reproducible from
    /// the seed alone -- no dependency on Swift's SystemRandomNumberGenerator
    /// implementation, which is not guaranteed stable across OS versions.
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Seeded permutations of the 8 events named in the task, over several
    /// hundred seeds. Invariant: once the language pair is installed and
    /// the fixture song stays current at the end of the sequence, every
    /// split piece eventually has its own translation within bounded time,
    /// with no duplicate work storms (checked via never re-requesting the
    /// same piece text) and no whole-line source translation replaced (the
    /// seeded fixture's `line.translation` is never mutated by this pass --
    /// only per-piece cache entries are ever written).
    func test_eventOrderPermutations_allPiecesEventuallyTranslated() async throws {
        let service = LyricsService.shared
        let seedCount = 300

        for seedValue in 0..<seedCount {
            var rng = SplitMix64(seed: UInt64(seedValue) &+ 1)
            var order = SimEvent.allCases
            order.shuffle(using: &rng)

            service.showTranslation = true
            service.translationLanguage = "zh-Hans"
            #if DEBUG
            PieceTranslationCache.shared.debugReset()
            #endif
            service.resetTranslationRequestStream()

            let title = "PieceOrderPermutation-\(seedValue)-\(UUID().uuidString.prefix(6))"
            let decoyTitle = "PieceOrderPermutationDecoy-\(seedValue)-\(UUID().uuidString.prefix(6))"
            seed(service: service, title: title, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)

            let executor = FakeExecutor()
            var serveTask: Task<Void, Never>?
            var lastSeenSourceVersion = service.pieceTranslationSourceVersion
            var lastSeenPieceVersion = service.pieceTranslationVersion

            // Mirrors LyricsView's `.onChange(of: pieceTranslationCombinedVersion)`
            // -- re-run the registration pass whenever either published
            // counter moved since we last looked, exactly the reaction the
            // production onChange performs via `refreshDisplayLineCache(forceRebuild: true)`.
            func reactToVersionChangesIfAny() {
                let sourceChanged = service.pieceTranslationSourceVersion != lastSeenSourceVersion
                let pieceChanged = service.pieceTranslationVersion != lastSeenPieceVersion
                guard sourceChanged || pieceChanged else { return }
                lastSeenSourceVersion = service.pieceTranslationSourceVersion
                lastSeenPieceVersion = service.pieceTranslationVersion
                simulateDisplayLinesBuilt(service: service, originalPieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
            }

            for event in order {
                switch event {
                case .lyricsArrive:
                    seed(service: service, title: title, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
                case .displayLinesBuilt, .widthChangeResplit:
                    simulateDisplayLinesBuilt(service: service, originalPieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
                case .sourceResolved:
                    _ = await service.silentSystemTranslationConfiguration()
                case .sessionReady:
                    if serveTask == nil {
                        serveTask = Task { await service.serveTranslationRequests(with: executor) }
                    }
                case .serveStreamReset:
                    service.resetTranslationRequestStream()
                case .songChangeAndBack:
                    seed(service: service, title: decoyTitle, pieces: ["A short unrelated line"], fullTranslation: "一句无关的短行")
                    seed(service: service, title: title, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation)
                    // A real track change always re-schedules translation
                    // config resolution (LyricsView's onChange(currentTrackTitle)
                    // path) -- not modeled as a separate standalone event
                    // because it is an unconditional part of "song changes"
                    // in the real app, never optional.
                    _ = await service.silentSystemTranslationConfiguration()
                case .translationToggleOffOn:
                    service.showTranslation = false
                    service.showTranslation = true
                }
                reactToVersionChangesIfAny()
            }

            // The song must stay current for the invariant to be
            // achievable at all -- `songChangeAndBack` (wherever it lands
            // in the shuffle) always finishes by reseeding the SAME
            // fixture title, so the song is always current by the time the
            // permutation loop above ends.
            if serveTask == nil {
                serveTask = Task { await service.serveTranslationRequests(with: executor) }
            }

            let deadline = Date().addingTimeInterval(1.5)
            while !allNonFirstPiecesTranslated(service: service, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation),
                  Date() < deadline {
                reactToVersionChangesIfAny()
                try await Task.sleep(nanoseconds: 15_000_000)
            }

            XCTAssertTrue(
                allNonFirstPiecesTranslated(service: service, pieces: Self.fixturePieces, fullTranslation: Self.fixtureFullTranslation),
                "seed \(seedValue) order \(order.map(\.rawValue)) must eventually translate every split piece"
            )
            // No duplicate work storm: the same piece text should never be
            // re-requested (ChunkedTranslationRunner + the cache-hit filter
            // in `performPendingPieceTranslations` are what guarantee this).
            let allRequestedTexts = executor.calls.flatMap { $0 }
            XCTAssertEqual(
                allRequestedTexts.count, Set(allRequestedTexts).count,
                "seed \(seedValue) order \(order.map(\.rawValue)) must never re-request the same piece text"
            )

            // Fully retire this iteration's serve loop BEFORE starting the
            // next one -- `resetTranslationRequestStream()` unblocks a loop
            // parked in `for await` (cancellation alone does not), and
            // `await serveTask?.value` forces the (MainActor-serialized)
            // task to actually run to completion before this method
            // continues. Without this, a `Task { ... }` that had not yet
            // been GIVEN A TURN by the scheduler could still be sitting
            // queued when this test method returns, and later clobber
            // `translationServeToken` while a LATER test's own serve loop
            // is mid-flight -- exactly what caused
            // PieceTranslationSessionWiringTests to flake when run directly
            // after this test in the same process (diagnosed during this
            // task; fixed here, not by touching Sources).
            service.resetTranslationRequestStream()
            serveTask?.cancel()
            await serveTask?.value
        }
    }
}
