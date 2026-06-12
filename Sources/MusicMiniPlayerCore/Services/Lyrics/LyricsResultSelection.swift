/**
 * [INPUT]: LyricsFetchResult from LyricsFetcher's parallel pipeline (carries the write-once LyricsSelectionMemo), LyricsSourceProfile declared traits (admission ladders, mirror group, risk checks)
 * [OUTPUT]: selectBestResult — single best lyrics result after quality/identity/timing gates; 1-element pools route through the solo-verdict memo (single chokepoint); memoized per-result facts (lyricIdentityTokens(for:), result-pair lyricSimilarity, soloSelectionVerdict, scorer romaji/quality verdicts) — compute once per result, output-identical to the raw paths
 * [POS]: Result selection sub-module of LyricsFetcher — quality filtering + scoring + fallback
 * [PROTOCOL]: Changes here → update this header, then check Services/Lyrics/CLAUDE.md
 */

import Foundation

#if DEBUG
// ============================================================
// MARK: - Memo Probe (DEBUG only — compiled out of release)
// ============================================================

/// Test-visible counters proving the per-result memos prevent recomputation.
/// Release builds compile every probe touch out entirely (zero cost).
enum LyricsSelectionMemoProbe {
    /// Full `lyricIdentityTokens` tokenization passes (memo misses).
    static var tokenizationPasses = 0
    /// Full single-result selection verdicts (memo misses).
    static var soloVerdictComputations = 0
    /// Full selection-body executions (mirrors the 🔬 log line count).
    static var fullSelectionPasses = 0
    /// Drain-loop exit-facts computations (memo misses).
    static var drainFactsComputations = 0
    /// `scorer.isLikelyRomaji` analyses (memo misses).
    static var romajiAnalyses = 0
    /// `scorer.analyzeQuality` analyses (memo misses).
    static var qualityAnalyses = 0
}
#endif

// ============================================================
// MARK: - Result Selection (extension of LyricsFetcher)
// ============================================================

extension LyricsFetcher {

    // MARK: - selectBest (public convenience overloads)

    /// Select best lyrics result — unified single-pass with CJK preference.
    /// When both CJK and romanized results exist, CJK is preferred unless romaji
    /// wins by a significant margin (>15 points). This prevents syllable-sync bonus
    /// (+30) from overriding script correctness for CJK-language songs.
    public func selectBest(from results: [LyricsFetchResult]) -> [LyricLine]? {
        return selectBestResult(from: results)?.lyrics
    }

    public func selectBest(from results: [LyricsFetchResult], songDuration: TimeInterval) -> [LyricLine]? {
        return selectBestResult(from: results, songDuration: songDuration)?.lyrics
    }

    /// Same as `selectBest` but returns the full `LyricsFetchResult` so callers
    /// can read `.kind` (synced / unsynced) without re-deriving via heuristics.
    public func selectBestResult(from results: [LyricsFetchResult]) -> LyricsFetchResult? {
        return selectBestResult(from: results, songDuration: 0)
    }

    // MARK: - selectBestResult (core)

    /// Select best result with song duration for coverage analysis.
    /// Single-result pools ride the solo-verdict memo (single chokepoint,
    /// review 8b): a full selection over [r] can only return r or nil —
    /// every selection path returns an element of its input pool — which is
    /// exactly the memoized verdict. A composite child's 1-element final
    /// selection and the drain loop's later re-ask of the same result
    /// therefore share one computation instead of running two.
    public func selectBestResult(from results: [LyricsFetchResult], songDuration: TimeInterval) -> LyricsFetchResult? {
        if results.count == 1, let only = results.first {
            return soloSelectionVerdict(for: only, songDuration: songDuration) ? only : nil
        }
        return selectBestResultUnmemoized(from: results, songDuration: songDuration)
    }

    /// The full selection body — quality/identity/timing gates over the
    /// whole pool. Coverage = (lastLineEnd - firstLineStart) / songDuration.
    /// When an album-matched source has drastically lower coverage than a
    /// non-matched one, its content is likely mistimed (same recording
    /// tagged under different albums → metadata match, not timing match).
    private func selectBestResultUnmemoized(from results: [LyricsFetchResult], songDuration: TimeInterval) -> LyricsFetchResult? {
        #if DEBUG
        LyricsSelectionMemoProbe.fullSelectionPasses += 1
        #endif
        // 🔑 Reject unsynced-only low-score results.
        // Unsynced lyrics (lyrics.ovh plain text, Genius HTML) don't support
        // auto-scroll or tap-to-jump in the UI — LyricsService.updateCurrentTime
        // short-circuits on isUnsyncedLyrics. Displaying them creates a
        // broken-feeling UX (static text pane, nothing responds).
        //
        // Policy: prefer trustworthy synced lyrics over unsynced, but do not
        // let a heavily-penalized synced result drive the UI. Low positive
        // scores usually mean the scorer detected a wrong master, large gaps,
        // or severe timing coverage problems. Word-level candidates stay in
        // the pool because their structure is a strong signal and later
        // identity/timing gates can still reject them.
        var syncedResults = results.filter { result in
            guard result.kind == .synced else { return false }
            if result.scriptMismatchSuspected { return false }
            if isLikelyRomanizedCJKLyricsCandidate(result) { return false }
            if hasWordLevelSync(result) && result.score > 0 { return true }
            if hasIndependentLyricAgreement(for: result, allResults: results) { return true }
            // Per-source admission ladder, declared in the trait profile.
            // (The legacy `default:` arm re-checked independent agreement, but
            // the universal check above already admitted every such result —
            // the duplicate call was pure and is dropped, not re-declared.)
            let admission = result.source.profile.syncedAdmission
            for rung in admission.exactRungs {
                if result.titleMatched, (result.matchedDurationDiff.map { $0 < rung.maxDurationDiff } ?? false) {
                    return result.score >= rung.minScore && result.lyrics.count >= rung.minLineCount
                }
            }
            return result.score >= admission.baseFloor
        }
        let versionSafeSynced = syncedResults.filter {
            !hasLooseCatalogVersionMismatch($0, songDuration: songDuration)
        }
        if !versionSafeSynced.isEmpty && versionSafeSynced.count < syncedResults.count {
            DebugLogger.log("🏆 Catalog-version filter: kept \(versionSafeSynced.map(\.source)), dropped \(syncedResults.filter { r in !versionSafeSynced.contains(where: { $0.source == r.source && $0.score == r.score }) }.map(\.source))")
            syncedResults = versionSafeSynced
        } else if versionSafeSynced.isEmpty && !syncedResults.isEmpty {
            DebugLogger.log("🏆 Catalog-version rejection: all synced candidates are loose duration matches")
            syncedResults = []
        }
        let timelineSafeSynced = syncedResults.filter {
            !hasSevereTimelineMismatch($0, songDuration: songDuration, allResults: results)
        }
        if !timelineSafeSynced.isEmpty && timelineSafeSynced.count < syncedResults.count {
            DebugLogger.log("🏆 Timeline filter: kept \(timelineSafeSynced.map(\.source)), dropped \(syncedResults.filter { r in !timelineSafeSynced.contains(where: { $0.source == r.source && $0.score == r.score }) }.map(\.source))")
            syncedResults = timelineSafeSynced
        } else if timelineSafeSynced.isEmpty && !syncedResults.isEmpty {
            DebugLogger.log("🏆 Timeline rejection: all synced candidates have severe timeline mismatch for \(Int(songDuration))s track")
            syncedResults = []
        }
        DebugLogger.log("🔬 selectBestResult: \(results.count) results, \(syncedResults.count) synced (\(results.map { "\($0.source):\($0.kind.rawValue)/\(Int($0.score))" }.joined(separator: ",")))")

        // 🔑 Cross-source timing consensus.
        // When multiple sources disagree on first-vocal timestamp, prefer
        // the MAJORITY cluster. A single outlier (e.g., one source timed
        // for a different edit) is filtered out. If no majority cluster
        // exists (all sources spread apart), every source is suspect →
        // reject (better than guessing).
        var usableSynced = syncedResults
        // Long-song single-source quality floor: for songs ≥ 8 min, a single
        // synced source scoring < 50 is unreliable (likely the single-edit
        // lyrics mislabeled to the extended master). Require consensus OR
        // high confidence.
        if songDuration >= 480, syncedResults.count == 1, let only = syncedResults.first, only.score < 50 {
            DebugLogger.log("🏆 Long-song single-source too low-score: \(only.source)=\(Int(only.score)) < 50")
            return nil
        }
        if syncedResults.count >= 2 && songDuration >= 480 {
            var seenSources = Set<LyricsSource>()
            let sourceTimes: [(src: LyricsSource, t: Double)] = syncedResults.compactMap { r in
                guard !seenSources.contains(r.source) else { return nil }
                guard let t = r.lyrics.first(where: { $0.startTime > 0 })?.startTime else { return nil }
                seenSources.insert(r.source)
                return (r.source, t)
            }
            DebugLogger.log("📊 Long-song timing check (dur=\(Int(songDuration))s): \(sourceTimes.map { "\($0.src)@\(String(format: "%.1f", $0.t))" })")

            if sourceTimes.count >= 2 {
                let tolerance: Double = 5.0
                var bestCluster: [(src: LyricsSource, t: Double)] = []
                for anchor in sourceTimes {
                    let cluster = sourceTimes.filter { abs($0.t - anchor.t) <= tolerance }
                    if cluster.count > bestCluster.count { bestCluster = cluster }
                }
                if bestCluster.count >= 2 {
                    // ≥2 sources cluster — keep those, drop outliers.
                    let clusterSources = Set(bestCluster.map { $0.src })
                    let filtered = syncedResults.filter { clusterSources.contains($0.source) }
                    if filtered.count < syncedResults.count {
                        DebugLogger.log("📊 Long-song outlier filter: kept \(clusterSources.sorted()), dropped \(syncedResults.filter { !clusterSources.contains($0.source) }.map(\.source))")
                        usableSynced = filtered
                    }
                } else {
                    // No ≥2 consensus. Every source is isolated → reject.
                    DebugLogger.log("🏆 Long-song rejection (no consensus): \(sourceTimes.map { "\($0.src)@\(String(format: "%.1f", $0.t))" })")
                    return nil
                }
            }
        }

        let contentConsensus = filterSyncedByLyricIdentityConsensus(
            syncedResults: usableSynced,
            allResults: results
        )
        if contentConsensus.applied {
            usableSynced = contentConsensus.syncedResults
        }

        if usableSynced.isEmpty {
            DebugLogger.log("🏆 No trustworthy synced results available: \(results.map { "\($0.source):\(Int($0.score))/\($0.kind.rawValue)" })")
            if let unsynced = selectUnsyncedFallback(from: results) {
                DebugLogger.log("🏆 Conservative unsynced fallback: \(unsynced.source) \(Int(unsynced.score))")
                return unsynced
            }
            return nil
        }
        // Word-level priority is conditional. Album catalog evidence is a
        // version signal, but it must not degrade same-identity syllable sync
        // to line sync. A line-level album hit can beat word-level only when
        // the word-level candidate lacks comparable catalog evidence and does
        // not match the album candidate's lyric identity.
        let albumMatchedCandidates = usableSynced.filter { $0.albumMatched }
        let wordLevelPool = usableSynced.filter { r in
            guard !r.lyrics.isEmpty else { return false }
            let syllableCount = r.lyrics.filter { $0.hasSyllableSync }.count
            guard Double(syllableCount) / Double(r.lyrics.count) >= 0.3 else { return false }
            guard !albumMatchedCandidates.isEmpty, !r.albumMatched else { return true }
            if r.titleMatched, (r.matchedDurationDiff.map { $0 < 1.5 } ?? false) {
                return true
            }
            return albumMatchedCandidates.contains { albumCandidate in
                lyricSimilarity(r, albumCandidate) >= 0.28
            }
        }
        if !wordLevelPool.isEmpty {
            DebugLogger.log("🎯 Word-level pre-filter: keeping \(wordLevelPool.map(\.source)), dropping \(usableSynced.filter { r in !wordLevelPool.contains(where: { $0.source == r.source && $0.score == r.score }) }.map(\.source))")
            return selectReliable(wordLevelPool, songDuration: songDuration)
        }
        return selectReliable(usableSynced, songDuration: songDuration)
    }

    // MARK: - Solo Selection Verdict

    /// Would `selectBestResult` accept this result on its own? The drain
    /// loop's exit decisions ask this for every accumulated result on every
    /// loop event, yet the answer is a pure function of the immutable result
    /// plus the fetch-constant song duration — computed once, then reused
    /// from the result's write-once memo (keyed by duration, so a result
    /// re-judged against a different duration recomputes).
    func soloSelectionVerdict(for result: LyricsFetchResult, songDuration: TimeInterval) -> Bool {
        if let memo = result.selectionMemo.soloVerdict, memo.songDuration == songDuration {
            return memo.isSelectable
        }
        #if DEBUG
        LyricsSelectionMemoProbe.soloVerdictComputations += 1
        #endif
        let isSelectable = selectBestResultUnmemoized(from: [result], songDuration: songDuration) != nil
        result.selectionMemo.soloVerdict = (songDuration, isSelectable)
        return isSelectable
    }

    // MARK: - Unsynced Fallback

    private func selectUnsyncedFallback(from results: [LyricsFetchResult]) -> LyricsFetchResult? {
        let plainCandidates = uniqueSourceResults(results).filter {
            $0.kind == .unsynced &&
            $0.score > 0 &&
            !$0.lyrics.isEmpty &&
            lyricIdentityTokens(for: $0).count >= 6
        }
        guard !plainCandidates.isEmpty else { return nil }

        if plainCandidates.count >= 2 {
            let threshold = 0.24
            let clusters: [[LyricsFetchResult]] = plainCandidates.map { anchor in
                plainCandidates.filter { lyricSimilarity(anchor, $0) >= threshold }
            }
            if let bestCluster = clusters.max(by: { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                let lhsScore = lhs.map(\.score).max() ?? 0
                let rhsScore = rhs.map(\.score).max() ?? 0
                return lhsScore < rhsScore
            }), bestCluster.count >= 2,
               (bestCluster.map(\.score).max() ?? 0) >= 12,
               bestCluster.contains(where: { $0.lyrics.count >= 20 }) {
                return bestCluster.max(by: { $0.score < $1.score })
            }
        }

        let candidates = plainCandidates.filter { result in
            if result.score >= 28 { return true }
            // Per-source relaxed floor, declared in the trait profile
            // (lyrics.ovh: 24 with >= 16 lines; Genius: 24).
            guard let relaxed = result.source.profile.unsyncedFallbackRelaxation else { return false }
            return result.score >= relaxed.minScore && result.lyrics.count >= relaxed.minLineCount
        }
        return candidates.max(by: { $0.score < $1.score })
    }

    // MARK: - Lyric Identity Helpers

    private func lyricsContainCJK(_ lyrics: [LyricLine]) -> Bool {
        lyrics.contains { LanguageUtils.containsCJK($0.text) }
    }

    private func isLikelyRomanizedCJKLyricsCandidate(_ result: LyricsFetchResult) -> Bool {
        // Risk check declared per profile — the LRCLIB pair only, never AMLL.
        guard result.source.profile.appliesRomanizedCJKLyricsCheck else { return false }
        let lines = result.lyrics.map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "..." && $0 != "…" && $0 != "⋯" }
            .prefix(12)
        guard lines.count >= 4 else { return false }
        if lines.contains(where: { LanguageUtils.containsCJK($0) }) { return false }
        let syllables: Set<String> = [
            "ai", "an", "ang", "ba", "bei", "bu", "cai", "de", "di", "dui",
            "fei", "ge", "guo", "hai", "hen", "hui", "ji", "jian", "kai",
            "kan", "li", "man", "me", "mei", "men", "ni", "qing", "shi",
            "shuo", "sui", "ta", "wo", "xin", "xing", "yan", "ye", "yi",
            "you", "zai", "zha", "zhi", "zhong"
        ]
        let tokens = lines.joined(separator: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 2 }
        guard tokens.count >= 12 else { return false }
        let hits = tokens.filter { syllables.contains($0) }.count
        return Double(hits) / Double(tokens.count) >= 0.45
    }

    /// Low-score synced catalog hits can still be correct when the scorer
    /// penalizes sparse vocals or long outros. Admit them only with exact
    /// title/duration evidence plus an independent lyric-text witness.
    func hasIndependentLyricAgreement(for result: LyricsFetchResult, allResults: [LyricsFetchResult]) -> Bool {
        guard result.kind == .synced,
              result.score >= 10,
              result.lyrics.count >= 12,
              lyricIdentityTokens(for: result).count >= 6 else { return false }

        return uniqueSourceResults(allResults).contains { witness in
            areIndependentLyricSources(result.source, witness.source)
                && witness.score > 0
                && !witness.lyrics.isEmpty
                && lyricIdentityTokens(for: witness).count >= 6
                && (lyricSimilarity(result, witness) >= 0.18
                    || firstComparableLyricLine(result.lyrics) == firstComparableLyricLine(witness.lyrics))
        }
    }

    private func areIndependentLyricSources(_ lhs: LyricsSource, _ rhs: LyricsSource) -> Bool {
        LyricsSource.areIndependentWitnesses(lhs, rhs)
    }

    /// Use independent source agreement as an output-side identity oracle.
    private func filterSyncedByLyricIdentityConsensus(
        syncedResults: [LyricsFetchResult],
        allResults: [LyricsFetchResult]
    ) -> (applied: Bool, syncedResults: [LyricsFetchResult]) {
        guard syncedResults.count >= 2 || allResults.count >= 3 else {
            return (false, syncedResults)
        }

        let candidates = uniqueSourceResults(allResults).filter {
            $0.score > 0 && !$0.lyrics.isEmpty && lyricIdentityTokens(for: $0).count >= 6
        }
        guard candidates.count >= 3 else { return (false, syncedResults) }

        let threshold = 0.34
        let clusters: [[LyricsFetchResult]] = candidates.map { anchor in
            candidates.filter { lyricSimilarity(anchor, $0) >= threshold }
        }
        guard let bestCluster = clusters.max(by: { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            let lhsSynced = lhs.filter { $0.kind == .synced }.count
            let rhsSynced = rhs.filter { $0.kind == .synced }.count
            return lhsSynced < rhsSynced
        }) else {
            return (false, syncedResults)
        }

        guard bestCluster.count >= 2 else {
            return (false, syncedResults)
        }

        let clusterSources = Set(bestCluster.map(\.source))
        let filteredSynced = syncedResults.filter { clusterSources.contains($0.source) }
        guard filteredSynced.count < syncedResults.count else {
            return (false, syncedResults)
        }

        let rejected = syncedResults.filter { !clusterSources.contains($0.source) }
        let clusterHasSynced = bestCluster.contains { $0.kind == .synced }
        let clusterHasStrongSynced = bestCluster.contains { result in
            result.kind == .synced
                && (result.score >= 65 || hasWordLevelSync(result))
                && (result.albumMatched || (result.matchedDurationDiff ?? .greatestFiniteMagnitude) < 1.0 || result.titleMatched)
        }
        let strongCatalogSyncedRejected = rejected.contains { result in
            result.kind == .synced
                && result.score >= 70
                && (result.albumMatched || (result.matchedDurationDiff ?? .greatestFiniteMagnitude) < 1.0)
                && (result.titleMatched || hasWordLevelSync(result))
        }
        if strongCatalogSyncedRejected && !clusterHasStrongSynced {
            return (false, syncedResults)
        }
        if !clusterHasSynced {
            let strongSyncedRejected = rejected.contains { result in
                result.score >= 75 || hasWordLevelSync(result)
            }
            if strongSyncedRejected {
                return (false, syncedResults)
            }
        }
        let rejectedAreOutliers = rejected.allSatisfy { rejectedResult in
            let bestSimilarity = bestCluster
                .map { lyricSimilarity(rejectedResult, $0) }
                .max() ?? 0
            return bestSimilarity < 0.18
        }
        guard rejectedAreOutliers else { return (false, syncedResults) }

        DebugLogger.log("🏆 Lyric identity consensus: kept \(clusterSources.sorted()), dropped \(rejected.map(\.source))")
        return (true, filteredSynced)
    }

    // MARK: - Validators

    private func hasWordLevelSync(_ result: LyricsFetchResult) -> Bool {
        guard !result.lyrics.isEmpty else { return false }
        let syllableCount = result.lyrics.filter { $0.hasSyllableSync }.count
        return Double(syllableCount) / Double(result.lyrics.count) >= 0.3
    }

    private func hasLooseCatalogVersionMismatch(_ result: LyricsFetchResult, songDuration: TimeInterval) -> Bool {
        guard songDuration > 0,
              result.kind == .synced,
              !result.albumMatched,
              let durationDiff = result.matchedDurationDiff else { return false }
        let allowed = max(16.0, songDuration * 0.06)
        return durationDiff > allowed && result.score < 65
    }

    private func hasSevereTimelineMismatch(_ result: LyricsFetchResult, songDuration: TimeInterval, allResults: [LyricsFetchResult]) -> Bool {
        guard songDuration > 0,
              result.kind == .synced,
              let lastStart = result.lyrics.last?.startTime else { return false }
        let maxEnd = result.lyrics.map(\.endTime).max() ?? lastStart
        if maxEnd > songDuration {
            if isBoundedAlternateMasterTimeline(result, songDuration: songDuration, maxEnd: maxEnd) {
                return false
            }
            return (maxEnd - songDuration) > max(8.0, songDuration * 0.05)
        }
        guard songDuration >= 180 else { return false }
        if hasIndependentLyricAgreement(for: result, allResults: allResults) {
            return false
        }
        let firstRealStart = result.lyrics.first {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }?.startTime ?? result.lyrics.first?.startTime ?? 0
        if lastStart > songDuration {
            return (lastStart - songDuration) > max(10.0, songDuration * 0.05)
        }
        let tailGap = songDuration - lastStart
        let realLines = result.lyrics.filter {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }
        let firstText = realLines.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let startsWithCatalogMarker = firstText.contains("******")
            || firstText.localizedCaseInsensitiveContains("music")
        let isExactLongIntro = result.titleMatched
            && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true)
            && result.score >= 45
            && realLines.count >= 12
            && !startsWithCatalogMarker
            && tailGap <= max(65.0, songDuration * 0.20)
            && maxInternalGap(result.lyrics) <= max(55.0, songDuration * 0.16)
        let firstStartLimit = min(90.0, max(45.0, songDuration * 0.30))
        if firstRealStart > firstStartLimit {
            let longIntroLimit = min(115.0, max(firstStartLimit, songDuration * 0.34))
            if !(isExactLongIntro && firstRealStart <= longIntroLimit) {
                return true
            }
        }
        let isExactSparseLongTail = result.titleMatched
            && (result.matchedDurationDiff.map { $0 < 2.0 } ?? true)
            && realLines.count >= 35
            && !startsWithCatalogMarker
        if result.score < 65,
           !hasWordLevelSync(result),
           tailGap > max(42.0, songDuration * 0.20) {
            if !isExactSparseLongTail && (firstRealStart < 4.0 || startsWithCatalogMarker) {
                return true
            }
        }
        if result.albumMatched,
           result.titleMatched,
           result.score >= 30,
           tailGap <= max(225.0, songDuration * 0.56) {
            return false
        }
        if result.titleMatched,
           result.score >= 45,
           result.lyrics.count >= 20,
           result.matchedDurationDiff.map({ $0 < 2.0 }) ?? false,
           tailGap <= max(160.0, songDuration * 0.55) {
            return false
        }
        if isExactSparseLongTail {
            return false
        }
        if result.score < 50,
           tailGap > min(180.0, max(120.0, songDuration * 0.45)) {
            return true
        }
        if result.score < 30,
           maxInternalGap(result.lyrics) > min(120.0, max(90.0, songDuration * 0.30)) {
            return true
        }
        let instrumentalOutroRatio = songDuration >= 360 ? 0.55 : 0.40
        return tailGap > max(140.0, songDuration * instrumentalOutroRatio)
    }

    private func isBoundedAlternateMasterTimeline(
        _ result: LyricsFetchResult,
        songDuration: TimeInterval,
        maxEnd: TimeInterval
    ) -> Bool {
        guard result.kind == .synced,
              result.titleMatched,
              result.score >= 65,
              let catalogDurationDiff = result.matchedDurationDiff,
              catalogDurationDiff >= 2.0,
              catalogDurationDiff < 35.0 else { return false }
        let overshoot = maxEnd - songDuration
        guard overshoot > 0 else { return false }
        return overshoot <= catalogDurationDiff + 5.0
    }

    // MARK: - Deduplication

    func uniqueSourceResults(_ results: [LyricsFetchResult]) -> [LyricsFetchResult] {
        var bestBySource: [LyricsSource: LyricsFetchResult] = [:]
        for result in results {
            if let existing = bestBySource[result.source], existing.score >= result.score { continue }
            bestBySource[result.source] = result
        }
        return Array(bestBySource.values)
    }

    // MARK: - Lyric Similarity / Identity

    /// Memoized identity tokens — computed once per result instance, ever.
    /// Lyric text is immutable (`lyrics` is `let`), so the cached set can
    /// never go stale; struct copies share the same write-once box.
    func lyricIdentityTokens(for result: LyricsFetchResult) -> Set<String> {
        if let cached = result.selectionMemo.identityTokens { return cached }
        let tokens = lyricIdentityTokens(result.lyrics)
        result.selectionMemo.identityTokens = tokens
        return tokens
    }

    /// Result-pair similarity through the per-result token memo. All
    /// result-to-result comparisons in selection go through this overload;
    /// the array overload remains for raw candidate text not yet wrapped
    /// in a result.
    func lyricSimilarity(_ lhs: LyricsFetchResult, _ rhs: LyricsFetchResult) -> Double {
        tokenSimilarity(lyricIdentityTokens(for: lhs), lyricIdentityTokens(for: rhs))
    }

    func lyricSimilarity(_ lhs: [LyricLine], _ rhs: [LyricLine]) -> Double {
        tokenSimilarity(lyricIdentityTokens(lhs), lyricIdentityTokens(rhs))
    }

    private func tokenSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        return Double(intersection) / Double(min(a.count, b.count))
    }

    func lyricIdentityTokens(_ lyrics: [LyricLine]) -> Set<String> {
        #if DEBUG
        LyricsSelectionMemoProbe.tokenizationPasses += 1
        #endif
        let lines = lyrics.filter {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }.prefix(24)
        let raw = lines.map(\.text).joined(separator: " ")
        let folded = LanguageUtils.toSimplifiedChinese(raw)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.append(Character(scalar))
            } else {
                if current.count >= 2 { words.append(current) }
                current = ""
            }
        }
        if current.count >= 2 { words.append(current) }

        if words.count >= 8 {
            var tokens = Set<String>()
            for i in 0..<(words.count - 1) {
                tokens.insert(words[i] + " " + words[i + 1])
            }
            return tokens
        }

        let compact = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }.map(String.init).joined()
        let chars = Array(compact)
        guard chars.count >= 4 else { return Set(words) }
        var tokens = Set<String>()
        for i in 0..<(chars.count - 1) {
            tokens.insert(String(chars[i...i + 1]))
        }
        return tokens
    }

    private func firstComparableLyricLine(_ lyrics: [LyricLine]) -> String? {
        lyrics.lazy
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "..." && $0 != "…" && $0 != "⋯" }
            .map {
                LanguageUtils.toSimplifiedChinese($0)
                    .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber }
            }
    }

    private func maxInternalGap(_ lyrics: [LyricLine]) -> Double {
        guard lyrics.count >= 2 else { return 0 }
        return (1..<lyrics.count).map { lyrics[$0].startTime - lyrics[$0 - 1].startTime }.max() ?? 0
    }

    // MARK: - Coverage

    /// Coverage ratio: what fraction of the song's duration the lyrics span.
    /// 91% = lyrics cover nearly the whole song (proper master match).
    /// 13% = lyrics cover a tiny fraction (likely wrong edit's timings).
    private func lyricCoverage(_ r: LyricsFetchResult, songDuration: TimeInterval) -> Double {
        guard songDuration > 0, !r.lyrics.isEmpty else { return 0 }
        let firstStart = r.lyrics.first?.startTime ?? 0
        let lastEnd = r.lyrics.last?.endTime ?? (r.lyrics.last?.startTime ?? 0)
        let span = max(0, lastEnd - firstStart)
        return min(span / songDuration, 1.0)
    }

    private func isLibraryFallbackSourceName(_ source: LyricsSource) -> Bool {
        source.profile.isLibraryFallback
    }

    private func isPreferredHumanCuratedSource(_ source: LyricsSource) -> Bool {
        source.profile.isPreferredHumanCurated
    }

    private func hasComparableCatalogEvidence(_ result: LyricsFetchResult) -> Bool {
        result.albumMatched
            || result.titleMatched
            || (result.matchedDurationDiff.map { $0 < 1.5 } ?? false)
            || result.nativeAliasMatched
    }

    // MARK: - Memoized Scorer Facts (per-result, pure)

    /// Memoized `scorer.isLikelyRomaji` — pure unicode-scalar analysis of
    /// the immutable lyric lines, computed once per result instance, ever.
    private func isLikelyRomajiResult(_ result: LyricsFetchResult) -> Bool {
        if let cached = result.selectionMemo.isLikelyRomaji { return cached }
        #if DEBUG
        LyricsSelectionMemoProbe.romajiAnalyses += 1
        #endif
        let value = scorer.isLikelyRomaji(result.lyrics)
        result.selectionMemo.isLikelyRomaji = value
        return value
    }

    /// Memoized `scorer.analyzeQuality(...).isValid` — text/timing analysis
    /// of the immutable lyric lines; selection only ever consumes the Bool.
    private func hasValidQualityAnalysis(_ result: LyricsFetchResult) -> Bool {
        if let cached = result.selectionMemo.qualityIsValid { return cached }
        #if DEBUG
        LyricsSelectionMemoProbe.qualityAnalyses += 1
        #endif
        let value = scorer.analyzeQuality(result.lyrics).isValid
        result.selectionMemo.qualityIsValid = value
        return value
    }

    // MARK: - selectReliable (CJK vs romaji + album preference)

    func selectReliable(_ reliable: [LyricsFetchResult], songDuration: TimeInterval = 0) -> LyricsFetchResult? {
        guard !reliable.isEmpty else { return nil }

        // Partition into CJK and romaji results
        let cjk = reliable.filter { !isLikelyRomajiResult($0) }
        let romaji = reliable.filter { isLikelyRomajiResult($0) }

        // 🔑 Album match is the strongest cross-source version signal.
        func pickWithAlbumPreference(_ pool: [LyricsFetchResult]) -> LyricsFetchResult? {
            let valid = pool.filter { hasValidQualityAnalysis($0) }
            let workingPool = valid.isEmpty ? pool : valid
            guard let top = workingPool.first else { return nil }

            if top.score < 30,
               let exactLRCLIB = workingPool.first(where: {
                   $0.source.profile.isLibraryFallback &&
                   $0.titleMatched &&
                   ($0.matchedDurationDiff.map { $0 < 1.0 } ?? false) &&
                   $0.score >= 20
               }) {
                DebugLogger.log("🏆 Exact LRCLIB preferred over low-score source: \(exactLRCLIB.source) (\(String(format: "%.1f", exactLRCLIB.score))) over \(top.source) (\(String(format: "%.1f", top.score)))")
                return exactLRCLIB
            }

            if isLibraryFallbackSourceName(top.source),
               let curated = workingPool.first(where: {
                   isPreferredHumanCuratedSource($0.source)
                       && $0.kind == .synced
                       && $0.score + 12 >= top.score
                       && hasComparableCatalogEvidence($0)
               }) {
                DebugLogger.log("🏆 Human-curated source preferred: \(curated.source) (\(String(format: "%.1f", curated.score))) over library fallback \(top.source) (\(String(format: "%.1f", top.score)))")
                return curated
            }

            // Direct title evidence beats a small score lead from a loose
            // cross-script duration escape.
            let topHasStrongNativeAlias = top.nativeAliasMatched
                && top.kind == .synced
                && top.score >= 60
                && (top.matchedDurationDiff.map { $0 < 3.0 } ?? false)
            if !top.titleMatched,
               !topHasStrongNativeAlias,
               let titleMatched = workingPool.first(where: { $0.titleMatched }),
               titleMatched.score + 20 >= top.score {
                DebugLogger.log("🏆 Title-evidence preferred: \(titleMatched.source) (\(String(format: "%.1f", titleMatched.score))) over loose \(top.source) (\(String(format: "%.1f", top.score)))")
                return titleMatched
            }

            // Completeness gate: a candidate with a massive internal gap
            // loses to a more complete competitor within 20 points.
            // Prevents translation bonus (+15) from overriding completeness
            // (POSTM-007: incomplete NetEase 63pts beat complete QQ 58pts).
            if top.lyrics.count >= 5 {
                let topMaxGap = maxInternalGap(top.lyrics)
                if topMaxGap > 45, let alt = workingPool.dropFirst().first(where: {
                    $0.score + 20 >= top.score && maxInternalGap($0.lyrics) < 10
                }) {
                    DebugLogger.log("🏆 Completeness gate: \(alt.source) (gap \(String(format: "%.0f", maxInternalGap(alt.lyrics)))s) over \(top.source) (gap \(String(format: "%.0f", topMaxGap))s)")
                    return alt
                }
            }

            // If top (score winner) is album-matched, it USUALLY wins — but
            // first check if a non-album-matched source has decisively better
            // lyric coverage.
            if top.albumMatched {
                if songDuration >= 120,
                   let alt = workingPool.first(where: { !$0.albumMatched }) {
                    let topCoverage = lyricCoverage(top, songDuration: songDuration)
                    let altCoverage = lyricCoverage(alt, songDuration: songDuration)
                    if altCoverage - topCoverage >= 0.40 {
                        DebugLogger.log("🏆 Coverage gap decisive — non-album-matched wins: \(alt.source) cov=\(Int(altCoverage * 100))% over album-matched \(top.source) cov=\(Int(topCoverage * 100))%")
                        return alt
                    }
                }
                return top
            }
            // Only consider album-matched candidates that ALSO passed validity.
            if let albumMatched = valid.first(where: { $0.albumMatched }) {
                if top.nativeAliasMatched,
                   !top.albumMatched,
                   !top.titleMatched,
                   albumMatched.score >= 30 {
                    DebugLogger.log("🏆 Album identity preferred over loose native alias: \(albumMatched.source) (\(String(format: "%.1f", albumMatched.score))) over \(top.source) (\(String(format: "%.1f", top.score)))")
                    return albumMatched
                }
                // 🔑 Timing sanity gate: album-matched lyrics with large timeline
                // overshoot vs the other contender's score-based winner indicate
                // wrong-master timing data.
                if albumMatched.score + 20 < top.score {
                    DebugLogger.log("🏆 Score gap too large — score wins: \(top.source) (\(String(format: "%.1f", top.score))) over album-matched \(albumMatched.source) (\(String(format: "%.1f", albumMatched.score)))")
                    return top
                }
                // 🔑 Coverage gap gate
                if songDuration >= 120 {
                    let amCoverage = lyricCoverage(albumMatched, songDuration: songDuration)
                    let topCoverage = lyricCoverage(top, songDuration: songDuration)
                    DebugLogger.log("📊 Coverage: \(top.source)=\(Int(topCoverage*100))% vs \(albumMatched.source)=\(Int(amCoverage*100))% (dur=\(Int(songDuration))s)")
                    if topCoverage - amCoverage >= 0.40 {
                        DebugLogger.log("🏆 Coverage gap decisive — non-album-matched wins: \(top.source) cov=\(Int(topCoverage * 100))% over \(albumMatched.source) cov=\(Int(amCoverage * 100))%")
                        return top
                    }
                }
                DebugLogger.log("🏆 Album-match preferred: \(albumMatched.source) (\(String(format: "%.1f", albumMatched.score))) over \(top.source) (\(String(format: "%.1f", top.score)))")
                return albumMatched
            }
            return top
        }
        let bestCJK = pickWithAlbumPreference(cjk)
        let bestRomaji = pickWithAlbumPreference(romaji)

        let chosen: LyricsFetchResult?
        if let cjkResult = bestCJK, let romajiResult = bestRomaji {
            // CJK preferred: romaji only wins with decisive margin
            if romajiResult.score > cjkResult.score + 15 {
                DebugLogger.log("🏆 Romaji wins decisively: \(romajiResult.source) (\(String(format: "%.1f", romajiResult.score))) > CJK \(cjkResult.source) (\(String(format: "%.1f", cjkResult.score))) + 15")
                chosen = romajiResult
            } else {
                DebugLogger.log("🏆 CJK preferred: \(cjkResult.source) (\(String(format: "%.1f", cjkResult.score))) over romaji \(romajiResult.source) (\(String(format: "%.1f", romajiResult.score)))")
                chosen = cjkResult
            }
        } else {
            chosen = bestCJK ?? bestRomaji
        }

        if let best = chosen {
            DebugLogger.log("🏆 Final selection: \(best.source) (score=\(String(format: "%.1f", best.score)), kind=\(best.kind.rawValue))")
            return best
        }
        return nil
    }

    // MARK: - Timestamp Rescaling (Last Resort)

    /// Rescale lyrics timestamps when they overshoot the song duration.
    /// Only used as a fallback after scoring — means no source had the right version.
    /// Assumes tempo difference, not structural difference.
    public func rescaleTimestamps(_ lyrics: [LyricLine], duration: TimeInterval) -> [LyricLine] {
        guard lyrics.count >= 2, duration > 0 else { return lyrics }

        // Trigger on startTime OR endTime overshoot
        let lastStart = lyrics.last!.startTime
        let lastEnd = lyrics.last!.endTime
        guard lastStart > duration || lastEnd > duration + 1.0 else { return lyrics }

        let firstStart = lyrics.first!.startTime
        let lyricsSpan = lastStart - firstStart
        guard lyricsSpan > 0 else { return lyrics }

        // Target: last line lands ~5s before song ends
        let buffer = min(5.0, duration * 0.05)
        let targetLastStart = duration - buffer
        let scale = (targetLastStart - firstStart) / lyricsSpan

        DebugLogger.log("⏱️ Timestamp rescale: \(String(format: "%.1f", lastStart))s → \(String(format: "%.1f", targetLastStart))s (×\(String(format: "%.3f", scale)))")

        return lyrics.map { line in
            let newStart = firstStart + (line.startTime - firstStart) * scale
            let newEnd = firstStart + (line.endTime - firstStart) * scale
            let newWords = line.words.map { word in
                LyricWord(
                    word: word.word,
                    startTime: firstStart + (word.startTime - firstStart) * scale,
                    endTime: firstStart + (word.endTime - firstStart) * scale
                )
            }
            return LyricLine(
                text: line.text, startTime: newStart, endTime: newEnd,
                words: newWords, translation: line.translation
            )
        }
    }

    // MARK: - Artist Token Overlap (used by Genius matching)

    func hasDistinctiveArtistTokenOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let stopwords: Set<String> = ["the", "and", "feat", "ft", "with", "dj"]
        func tokens(_ value: String) -> Set<String> {
            let normalized = LanguageUtils.normalizeUnicode(value).lowercased()
            return Set(normalized.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter {
                $0.count >= 4 && !stopwords.contains($0)
            })
        }
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return !left.intersection(right).isEmpty
    }
}
