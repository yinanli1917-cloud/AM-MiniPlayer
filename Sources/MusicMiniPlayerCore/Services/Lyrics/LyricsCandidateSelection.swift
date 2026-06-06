/**
 * [INPUT]: Raw search results from NetEase/QQ APIs
 * [OUTPUT]: selectBestCandidate — unified priority-chain candidate matching with explicit title-evidence state
 * [POS]: Candidate selection sub-module of LyricsFetcher — SearchCandidate + matching + alias resolution
 * [NOTE]: NetEase/QQ share searchAndSelectCandidate template, confirmed CJK alias probes, query-provenance gates, provider-ranked native title evidence, bounded English-title/native pinyin aliases, compilation-artist safety, and buildCandidates generic builder
 * [PROTOCOL]: Changes here → update this header, then check Services/Lyrics/CLAUDE.md
 */

import Foundation

// ============================================================
// MARK: - Candidate Selection (extension of LyricsFetcher)
// ============================================================

extension LyricsFetcher {

    // MARK: - 统一匹配工具

    /// 搜索候选结构体（NetEase/QQ 共用）
    struct SearchCandidate<ID> {
        let id: ID
        let name: String
        let artist: String
        let album: String
        let durationDiff: Double
        let titleMatch: Bool
        let artistMatch: Bool
        /// True when candidate album matches input album (normalized + simplified,
        /// contains-either-way). Used as a version disambiguator when multiple
        /// entries share title/artist/duration (e.g. compilations, remasters,
        /// Cantonese vs Mandarin versions).
        let albumMatch: Bool
        /// Length of candidate name after normalization. Used as a tiebreaker
        /// to prefer candidates WITHOUT extra suffixes like "(国)", "(粤)",
        /// "(Live)" — a shorter normalized name means fewer version markers.
        let normalizedNameLength: Int
        /// Original provider ordering. Search engines often rank the semantic
        /// title alias ahead of same-artist duration collisions; keep that
        /// evidence as a late tiebreaker.
        let resultIndex: Int
        /// Search descriptor that produced this row. This is source evidence,
        /// not a whitelist: title-only rows are collision-prone, while
        /// artist/album-backed rows can prove cross-script aliases.
        let searchDescriptor: String
    }

    /// 统一优先级选择（消除 NetEase/QQ 的重复匹配逻辑）
    /// P1: 标题+艺术家+时长<3s → P2: 标题+艺术家+时长<20s
    /// P3: 仅艺术家+时长极精确(<0.5s) — 用于罗马字/翻译标题 vs CJK 标题的场景
    /// 🔑 No title-only tier: all matches require artist verification (three-rule principle)
    /// 🔑 Within each tier, candidates are ranked by:
    ///    (1) albumMatch — strongest version disambiguator
    ///    (2) normalizedNameLength — shorter normalized names win
    ///    (3) durationDiff — closest duration as final tiebreaker.
    struct SelectedSearchCandidate<ID> {
        let id: ID
        let title: String
        let artist: String
        let albumMatched: Bool
        let titleMatched: Bool
        let nativeAliasMatched: Bool
        let durationDiff: Double
        let matchRank: Int
    }

    func selectBestCandidate<ID>(_ candidates: [SearchCandidate<ID>], source: String, inputTitle: String = "", inputArtist: String = "", disableCjkEscape: Bool = false, aliasConfirmedCJK: Bool = false, hasAlbumHint: Bool = false, allowNativeTitleAlias: Bool = false, allowCompilationAlbumFallback: Bool = false) -> SelectedSearchCandidate<ID>? {
        // Debug view: sorted purely by durationDiff so the log reads naturally.
        let sortedByDelta = candidates.sorted { $0.durationDiff < $1.durationDiff }
        let desc = sortedByDelta.prefix(5).map { "'\($0.name)' by '\($0.artist)' alb='\($0.album)' q='\($0.searchDescriptor)' T=\($0.titleMatch) A=\($0.artistMatch) AL=\($0.albumMatch) L=\($0.normalizedNameLength) Δ\(String(format: "%.1f", $0.durationDiff))s" }
        DebugLogger.log(source, "🎯 候选: \(desc.joined(separator: ", "))")
        // Composite rank applied WITHIN each priority tier below:
        //   (1) albumMatch desc  — strongest version disambiguator
        //   (2) nameLength asc   — prefer titles without "(国)"/"(粤)"/"(Live)"
        //   (3) durationDiff asc — closest duration as final tiebreaker
        let compositeRank: (SearchCandidate<ID>, SearchCandidate<ID>) -> Bool = { a, b in
            if a.albumMatch != b.albumMatch { return a.albumMatch && !b.albumMatch }
            // 🔑 For a romanized input, a track whose CJK title romanizes to the
            // input outranks one that doesn't — otherwise a sibling album track
            // ('快节奏') beats the real title track ('二十岁的浪漫') on the shorter-
            // name / closer-duration tiebreakers. Graceful: when neither (or both)
            // corroborate, this is a no-op and the existing order applies.
            if LanguageUtils.isPureASCII(inputTitle) {
                let aCorroborates = LanguageUtils.isRomanizedTitleCorroborated(input: inputTitle, candidateTitle: a.name)
                let bCorroborates = LanguageUtils.isRomanizedTitleCorroborated(input: inputTitle, candidateTitle: b.name)
                if aCorroborates != bCorroborates { return aCorroborates && !bCorroborates }
            }
            if a.normalizedNameLength != b.normalizedNameLength {
                return a.normalizedNameLength < b.normalizedNameLength
            }
            if a.durationDiff != b.durationDiff { return a.durationDiff < b.durationDiff }
            return a.resultIndex < b.resultIndex
        }
        let sorted = sortedByDelta  // P3 predicates still read `sorted` as the Δ-ordered pool
        let isBackingTrack: (SearchCandidate<ID>) -> Bool = { candidate in
            let lower = (candidate.name + " " + candidate.album).lowercased()
            return lower.contains("karaoke")
                || lower.contains("instrumental")
                || lower.contains("伴奏")
                || lower.contains("カラオケ")
                || lower.contains("オリジナル・カラオケ")
        }
        let inputArtistIsSpecific = !inputArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCompilationArtistName(inputArtist)
        let isUnsafeGenericCompilationArtist: (SearchCandidate<ID>) -> Bool = { candidate in
            guard inputArtistIsSpecific else { return false }
            guard candidate.albumMatch || candidate.searchDescriptor.lowercased().contains("album") else { return false }
            return self.isCompilationArtistName(candidate.artist)
        }
        let isSafeCompilationAlbumFallback: (SearchCandidate<ID>) -> Bool = { candidate in
            guard allowCompilationAlbumFallback else { return false }
            guard inputArtistIsSpecific else { return false }
            guard candidate.titleMatch, candidate.albumMatch else { return false }
            guard candidate.durationDiff < 1.5 else { return false }
            guard candidate.searchDescriptor.lowercased().contains("album") else { return false }
            guard self.isCompilationArtistName(candidate.artist) else { return false }
            return !isBackingTrack(candidate)
        }
        let isSafeCatalogExactTitleFallback: (SearchCandidate<ID>) -> Bool = { candidate in
            guard allowCompilationAlbumFallback else { return false }
            guard hasAlbumHint, inputArtistIsSpecific else { return false }
            guard candidate.titleMatch else { return false }
            guard candidate.durationDiff < 1.5 else { return false }
            guard candidate.resultIndex < 24 else { return false }
            guard self.isCompilationArtistName(candidate.artist) else { return false }
            guard self.isDistinctiveCatalogExactTitle([inputTitle]) else { return false }
            return !isBackingTrack(candidate)
        }
        let hasSameArtistTitleEvidence = candidates.contains { candidate in
            candidate.titleMatch
                && candidate.artistMatch
                && !isBackingTrack(candidate)
                && !isUnsafeGenericCompilationArtist(candidate)
        }
        let inputTokens = inputTitle.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let inputWordCount = inputTokens.count
        let likelyJapaneseRomaji = LanguageUtils.isLikelyRomanizedJapanese(inputTitle)
        let inputLooksEnglish = LanguageUtils.isLikelyEnglishTitle(inputTitle)
        let sourceIsQQ = source.range(of: "qq", options: [.caseInsensitive, .diacriticInsensitive]) != nil
        let isRiskyUnscopedNativeTitleOnly: (SearchCandidate<ID>) -> Bool = { candidate in
            guard sourceIsQQ else { return false }
            guard candidate.searchDescriptor == "title only" else { return false }
            guard !candidate.albumMatch else { return false }
            guard LanguageUtils.isPureASCII(inputTitle), inputWordCount >= 4 else { return false }
            return candidate.name.unicodeScalars.contains { LanguageUtils.isCJKScalar($0) }
        }
        let normalizedInputArtist = LanguageUtils.normalizeArtistName(inputArtist)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let directASCIIArtistMatch: (SearchCandidate<ID>) -> Bool = { candidate in
            guard !normalizedInputArtist.isEmpty,
                  LanguageUtils.isPureASCII(inputArtist),
                  LanguageUtils.isPureASCII(candidate.artist),
                  !self.isCompilationArtistName(candidate.artist) else { return false }
            let normalizedCandidate = LanguageUtils.normalizeArtistName(candidate.artist)
                .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            let artistParts = normalizedCandidate
                .split(whereSeparator: { "/,&".contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            return normalizedCandidate == normalizedInputArtist || artistParts.contains(normalizedInputArtist)
        }
        let providerLocalizedTitleAlias: (SearchCandidate<ID>) -> Bool = { candidate in
            guard allowNativeTitleAlias,
                  inputLooksEnglish,
                  !likelyJapaneseRomaji,
                  candidate.artistMatch,
                  directASCIIArtistMatch(candidate),
                  candidate.searchDescriptor.hasPrefix("title+artist"),
                  candidate.resultIndex <= 1,
                  candidate.durationDiff < 0.35,
                  candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }),
                  !hasSameArtistTitleEvidence,
                  !isBackingTrack(candidate) else {
                return false
            }
            return true
        }
        let inputIsShortASCIIAlias = LanguageUtils.isPureASCII(inputTitle)
            && inputWordCount >= 2
            && inputWordCount <= 4
            && !likelyJapaneseRomaji
        let providerRankedNativeTitleAlias: (SearchCandidate<ID>) -> Bool = { candidate in
            let candidateArtistHasCJK = candidate.artist.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) })
            guard allowNativeTitleAlias,
                  (aliasConfirmedCJK || candidateArtistHasCJK),
                  inputIsShortASCIIAlias,
                  candidate.artistMatch,
                  candidate.resultIndex <= 1,
                  candidate.durationDiff < 1.0,
                  candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }),
                  !hasSameArtistTitleEvidence,
                  !isBackingTrack(candidate),
                  !isUnsafeGenericCompilationArtist(candidate) else {
                return false
            }
            return candidate.searchDescriptor.hasPrefix("title+artist")
                || candidate.searchDescriptor.hasPrefix("title+album+artist")
        }
        let exactTopNativeTitleAlias: (SearchCandidate<ID>) -> Bool = { candidate in
            let candidateArtistHasCJK = candidate.artist.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) })
            guard allowNativeTitleAlias,
                  (aliasConfirmedCJK || candidateArtistHasCJK),
                  inputIsShortASCIIAlias,
                  candidate.artistMatch,
                  candidate.resultIndex == 0,
                  candidate.normalizedNameLength <= 8,
                  candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }),
                  !hasSameArtistTitleEvidence,
                  !isBackingTrack(candidate),
                  !isUnsafeGenericCompilationArtist(candidate) else {
                return false
            }
            if candidate.searchDescriptor == "title only" {
                return sourceIsQQ && inputWordCount >= 3 && candidate.durationDiff < 1.0
            }
            guard candidate.durationDiff < 0.35 else { return false }
            return candidate.searchDescriptor == "artist only"
                || candidate.searchDescriptor.hasPrefix("alias artist only")
        }

        // 按优先级递减尝试
        let priorities: [(String, Int, (SearchCandidate<ID>) -> Bool)] = [
            ("P1", 0, { $0.titleMatch && $0.artistMatch && $0.durationDiff < 3 }),
            ("P1a", 1, { candidate in
                guard candidate.artistMatch else { return false }
                guard candidate.albumMatch else { return false }
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                guard candidate.durationDiff < 1.5 else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                return !isBackingTrack(candidate)
            }),
            ("P1c", 0, { candidate in
                isSafeCompilationAlbumFallback(candidate)
            }),
            ("P1e", 0, { candidate in
                isSafeCatalogExactTitleFallback(candidate)
            }),
            ("P1d", 0, { candidate in
                providerLocalizedTitleAlias(candidate)
            }),
            ("P1f", 1, { candidate in
                providerRankedNativeTitleAlias(candidate)
            }),
            ("P1b", 1, { candidate in
                guard allowNativeTitleAlias else { return false }
                guard candidate.artistMatch else { return false }
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                if candidate.durationDiff < 1.0, candidate.albumMatch {
                    return true
                }
                let artistIsCJK = candidate.artist.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) })
                    || aliasConfirmedCJK
                guard artistIsCJK else { return false }
                if isBackingTrack(candidate) { return false }
                guard !hasSameArtistTitleEvidence else { return false }
                if aliasConfirmedCJK,
                   LanguageUtils.isLikelyEnglishTitle(inputTitle),
                   !LanguageUtils.isLikelyRomanizedJapanese(inputTitle),
                   candidate.durationDiff < 3.0,
                   candidate.searchDescriptor.hasPrefix("alias+title") {
                    if hasAlbumHint, !candidate.albumMatch {
                        guard self.localizedEnglishTitleAliasMatches(
                            inputTitle: inputTitle,
                            nativeTitle: candidate.name
                        ) else { return false }
                    }
                    return true
                }
                if LanguageUtils.isLikelyEnglishTitle(inputTitle),
                   !LanguageUtils.isLikelyRomanizedJapanese(inputTitle) {
                    if inputWordCount >= 2,
                       candidate.searchDescriptor == "artist only",
                       !hasAlbumHint,
                       candidate.durationDiff < 1.0 {
                        return true
                    }
                    return false
                }
                if inputWordCount <= 1 && !candidate.albumMatch {
                    return candidate.searchDescriptor.hasPrefix("alias artist only")
                        && candidate.durationDiff < 1.5
                }
                if hasAlbumHint, !candidate.albumMatch {
                    return candidate.searchDescriptor.hasPrefix("alias artist only")
                        && candidate.durationDiff < 1.25
                }
                return candidate.durationDiff < 20
            }),
            ("P2", 2, { $0.titleMatch && $0.artistMatch && $0.durationDiff < 20 }),
            ("P2a", 2, { candidate in
                guard candidate.titleMatch else { return false }
                guard inputTitle.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.searchDescriptor == "artist only"
                    || candidate.searchDescriptor.hasPrefix("alias artist only")
                    || candidate.searchDescriptor.hasPrefix("album+artist") else { return false }
                guard candidate.durationDiff < 1.25 else { return false }
                return !isBackingTrack(candidate)
            }),
            ("P2b", 2, { candidate in
                guard allowNativeTitleAlias else { return false }
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                guard candidate.albumMatch else { return false }
                guard candidate.searchDescriptor.hasPrefix("album+artist")
                    || candidate.searchDescriptor.hasPrefix("alias album+artist") else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.durationDiff < 2.0 else { return false }
                return !isBackingTrack(candidate)
            }),
            ("P2c", 2, { candidate in
                guard allowNativeTitleAlias else { return false }
                guard aliasConfirmedCJK else { return false }
                guard hasAlbumHint else { return false }
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                guard !LanguageUtils.isLikelyEnglishTitle(inputTitle)
                    || LanguageUtils.isLikelyRomanizedJapanese(inputTitle) else { return false }
                guard candidate.searchDescriptor.hasPrefix("alias artist only") else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.durationDiff < 0.8 else { return false }
                return !isBackingTrack(candidate)
            }),
            ("P2d", 2, { candidate in
                guard hasAlbumHint else { return false }
                guard candidate.searchDescriptor == "artist only" else { return false }
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                guard !LanguageUtils.isLikelyEnglishTitle(inputTitle)
                    || LanguageUtils.isLikelyRomanizedJapanese(inputTitle) else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.artist.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.durationDiff < 1.25 else { return false }
                return !isBackingTrack(candidate)
            }),
            ("P2e", 2, { candidate in
                exactTopNativeTitleAlias(candidate)
            }),
            ("P2loose", 2, { candidate in
                guard candidate.titleMatch,
                      candidate.artistMatch,
                      candidate.durationDiff >= 20,
                      candidate.durationDiff < (hasAlbumHint ? 45 : 35) else { return false }
                let hasCJKIdentity = LanguageUtils.containsCJK(inputTitle)
                    || LanguageUtils.containsCJK(candidate.name)
                    || LanguageUtils.containsCJK(candidate.artist)
                return (candidate.albumMatch || hasCJKIdentity) && !isBackingTrack(candidate)
            }),
            // 🔑 P3: 仅艺术家匹配 + 时长极精确 — 覆盖罗马字/翻译标题场景
            ("P3", 3, { candidate in
                guard candidate.artistMatch else { return false }
                guard !inputTitle.isEmpty else { return false }
                let resultTokens = LanguageUtils.normalizeTrackName(candidate.name).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let genericTitleTokens: Set<String> = [
                    "the", "and", "with", "feat", "featuring", "from", "to",
                    "a", "an", "of", "in", "on", "for", "me", "my", "you"
                ]
                let hasTokenOverlap = inputTokens.contains { t in
                    guard !genericTitleTokens.contains(t) else { return false }
                    return t.count >= 3 && resultTokens.contains(where: { r in
                        guard !genericTitleTokens.contains(r) else { return false }
                        return r.count >= 3 && (r.contains(t) || t.contains(r))
                    })
                }
                // 🔑 Token-overlap path
                if hasTokenOverlap && candidate.durationDiff < 0.5 { return true }
                if disableCjkEscape { return false }
                // 🔑 Romanized→CJK escape
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                let looksRomanized = inputWordCount >= 4 || likelyJapaneseRomaji
                // 🔑 English title guard
                if inputLooksEnglish && !likelyJapaneseRomaji {
                    if !(aliasConfirmedCJK && inputWordCount <= 3) { return false }
                }
                let resultTitleHasCJK = candidate.name.unicodeScalars.contains { LanguageUtils.isCJKScalar($0) }
                if resultTitleHasCJK && candidate.albumMatch && aliasConfirmedCJK && candidate.durationDiff < 5.0 {
                    return true
                }
                if inputLooksEnglish && aliasConfirmedCJK {
                    return false
                }
                if resultTitleHasCJK && candidate.durationDiff < 1.0 {
                    guard looksRomanized || aliasConfirmedCJK || candidate.albumMatch else { return false }
                    if inputWordCount <= 1 && !candidate.albumMatch && !hasSameArtistTitleEvidence {
                        return false
                    }
                    if hasAlbumHint && !candidate.albumMatch {
                        guard candidate.searchDescriptor == "artist only"
                            || candidate.searchDescriptor.hasPrefix("alias artist only") else { return false }
                        guard looksRomanized || aliasConfirmedCJK else { return false }
                    }
                    return true
                }
                return false
            }),
        ]

        // 🔑 Cross-tier albumMatch priority
        var tierWinners: [(label: String, rank: Int, candidate: SearchCandidate<ID>)] = []
        for (label, rank, predicate) in priorities {
            var best: SearchCandidate<ID>?
            for candidate in sorted where (!isUnsafeGenericCompilationArtist(candidate) || isSafeCompilationAlbumFallback(candidate) || isSafeCatalogExactTitleFallback(candidate)) && !isRiskyUnscopedNativeTitleOnly(candidate) && predicate(candidate) {
                if let current = best {
                    if compositeRank(candidate, current) { best = candidate }
                } else {
                    best = candidate
                }
            }
            if let best {
                tierWinners.append((label, rank, best))
            }
        }

        // If any tier produced an album-matched winner, prefer it.
        let chosen: (label: String, rank: Int, candidate: SearchCandidate<ID>)?
        if let albumMatched = tierWinners
            .filter({ $0.candidate.albumMatch })
            .min(by: { $0.candidate.durationDiff < $1.candidate.durationDiff }) {
            chosen = albumMatched
        } else {
            chosen = tierWinners.first
        }

        if let winner = chosen {
            DebugLogger.log(source, "✅ \(winner.label): '\(winner.candidate.name)' by '\(winner.candidate.artist)' alb='\(winner.candidate.album)' q='\(winner.candidate.searchDescriptor)' AL=\(winner.candidate.albumMatch) L=\(winner.candidate.normalizedNameLength) Δ\(String(format: "%.1f", winner.candidate.durationDiff))s")
            let nativeAliasLabels: Set<String> = ["P1d", "P1f", "P2d", "P2e"]
            return SelectedSearchCandidate(
                id: winner.candidate.id,
                title: winner.candidate.name,
                artist: winner.candidate.artist,
                albumMatched: winner.candidate.albumMatch,
                titleMatched: winner.candidate.titleMatch || winner.candidate.albumMatch || nativeAliasLabels.contains(winner.label),
                nativeAliasMatched: !winner.candidate.titleMatch && (
                    (winner.rank == 1 && !winner.candidate.albumMatch)
                        || nativeAliasLabels.contains(winner.label)
                        || winner.candidate.searchDescriptor.hasPrefix("alias artist only")
                        || winner.candidate.searchDescriptor.hasPrefix("alias album+artist")
                ),
                durationDiff: winner.candidate.durationDiff,
                matchRank: winner.rank
            )
        }

        if !sorted.isEmpty { DebugLogger.log(source, "❌ 无匹配") }
        return nil
    }

    // MARK: - Title / Artist Matching

    /// 统一标题匹配（消除 NetEase/QQ 各自的内联清理逻辑）
    func isTitleMatch(input: String, result: String, simplifiedInput: String) -> Bool {
        let cleanedInput = LanguageUtils.normalizeTrackName(input).lowercased()
        let cleanedResult = LanguageUtils.normalizeTrackName(result).lowercased()
        let simplifiedResult = LanguageUtils.toSimplifiedChinese(cleanedResult)
        let simplifiedCleanedInput = LanguageUtils.toSimplifiedChinese(cleanedInput)
        let compactInput = compactTitleIdentity(cleanedInput)
        let compactResult = compactTitleIdentity(cleanedResult)
        let romanizedAliases = japaneseRomanizedTitleAliases(for: compactInput)
        let hasJapaneseRomanizedAlias = romanizedAliases.contains(compactResult)
        let hasNativePinyinAlias = nativePinyinTitleAliasesMatch(
            input: cleanedInput,
            result: cleanedResult,
            compactInput: compactInput,
            compactResult: compactResult
        )

        return cleanedInput == cleanedResult ||
               simplifiedCleanedInput == simplifiedResult ||
               (!compactInput.isEmpty && compactInput == compactResult) ||
               hasJapaneseRomanizedAlias ||
               hasNativePinyinAlias ||
               cleanedInput.contains(cleanedResult) || cleanedResult.contains(cleanedInput) ||
               simplifiedCleanedInput.contains(simplifiedResult) || simplifiedResult.contains(simplifiedCleanedInput)
    }

    private func nativePinyinTitleAliasesMatch(
        input: String,
        result: String,
        compactInput: String,
        compactResult: String
    ) -> Bool {
        let inputHasCJK = LanguageUtils.containsCJK(input)
        let resultHasCJK = LanguageUtils.containsCJK(result)
        guard inputHasCJK != resultHasCJK else { return false }

        let latinInput = LanguageUtils.toLatinLower(input)
        let latinResult = LanguageUtils.toLatinLower(result)
        let asciiCompact = inputHasCJK ? compactResult : compactInput
        let nativeLatin = inputHasCJK ? latinInput : latinResult
        guard asciiCompact.count >= 4,
              nativeLatin.count >= 4,
              asciiCompact == nativeLatin else { return false }

        let cjkText = inputHasCJK ? input : result
        let cjkCount = cjkText.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count
        guard cjkCount >= 2 else { return false }

        let asciiText = inputHasCJK ? result : input
        let asciiWordCount = asciiText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        let nativeHasKana = cjkText.unicodeScalars.contains { LanguageUtils.isJapaneseKana($0) }
        if nativeHasKana {
            return asciiWordCount >= 1 && cjkCount <= 8
        }
        return asciiWordCount >= 2 || cjkCount <= 3
    }

    private func japaneseRomanizedTitleAliases(for compactInput: String) -> Set<String> {
        switch compactInput {
        case "hatsukoi":
            return ["初恋"]
        case "koibito", "koibitotachi":
            return ["恋人", "恋人たち"]
        case "mayonaka":
            return ["真夜中"]
        case "namida":
            return ["涙", "泪"]
        case "yumeno", "yume":
            return ["夢", "梦"]
        case "sora":
            return ["空"]
        case "kaze":
            return ["風", "风"]
        case "hoshi":
            return ["星"]
        default:
            return []
        }
    }

    private func compactTitleIdentity(_ value: String) -> String {
        let normalized = LanguageUtils.toSimplifiedChinese(
            LanguageUtils.normalizeTrackName(value)
        ).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return String(normalized.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || LanguageUtils.isCJKScalar($0)
        })
    }

    private func localizedEnglishTitleAliasMatches(inputTitle: String, nativeTitle: String) -> Bool {
        guard LanguageUtils.isPureASCII(inputTitle),
              LanguageUtils.isLikelyEnglishTitle(inputTitle),
              nativeTitle.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else {
            return false
        }
        let genericTitleTokens: Set<String> = [
            "the", "and", "with", "feat", "featuring", "from", "to",
            "a", "an", "of", "in", "on", "for", "me", "my", "you"
        ]
        let meaningfulTokens = inputTitle.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !genericTitleTokens.contains($0) && $0.count >= 3 }
        guard !meaningfulTokens.isEmpty, meaningfulTokens.count <= 3 else { return false }

        let simplifiedNative = LanguageUtils.toSimplifiedChinese(nativeTitle)
        let traditionalNative = LanguageUtils.toTraditionalChinese(nativeTitle)
        let semanticTokens: [String: [String]] = [
            "key": ["关键", "關鍵", "钥匙", "鑰匙"],
            "keyword": ["关键词", "關鍵詞", "关键", "關鍵"],
            "keywords": ["关键词", "關鍵詞", "关键", "關鍵"],
            "distance": ["距离", "距離"]
        ]
        return meaningfulTokens.allSatisfy { token in
            guard let aliases = semanticTokens[token] else { return false }
            return aliases.contains { alias in
                simplifiedNative.contains(LanguageUtils.toSimplifiedChinese(alias))
                    || traditionalNative.contains(LanguageUtils.toTraditionalChinese(alias))
            }
        }
    }

    /// 统一艺术家匹配（简繁体 + CJK 跨语言 + normalized 去后缀）
    func isArtistMatch(input: String, result: String, simplifiedInput: String) -> Bool {
        let inputLower = input.lowercased()
        let resultLower = result.lowercased()
        let simplifiedInputLower = simplifiedInput.lowercased()
        let simplifiedResult = LanguageUtils.toSimplifiedChinese(result).lowercased()
        let hasCJKIdentity = LanguageUtils.containsCJK(input)
            || LanguageUtils.containsCJK(result)
            || LanguageUtils.containsCJK(simplifiedInput)
            || LanguageUtils.containsCJK(simplifiedResult)

        // 直接匹配或包含匹配
        if inputLower == resultLower || simplifiedInputLower == simplifiedResult { return true }
        if hasCJKIdentity {
            let inputParts = artistIdentityParts(input) + artistIdentityParts(simplifiedInput)
            let resultParts = artistIdentityParts(result) + artistIdentityParts(simplifiedResult)
            if inputParts.contains(where: { inputPart in
                resultParts.contains { resultPart in inputPart == resultPart }
            }) { return true }
        } else {
            if inputLower.contains(resultLower) || resultLower.contains(inputLower) { return true }
            if simplifiedInputLower.contains(simplifiedResult) || simplifiedResult.contains(simplifiedInputLower) { return true }
        }

        // 🔑 normalized 后再匹配
        let normalizedInput = LanguageUtils.normalizeArtistName(input).lowercased()
        let normalizedResult = LanguageUtils.normalizeArtistName(result).lowercased()
        if !normalizedInput.isEmpty && !normalizedResult.isEmpty {
            if normalizedInput == normalizedResult { return true }
            if !hasCJKIdentity,
               normalizedInput.contains(normalizedResult) || normalizedResult.contains(normalizedInput) { return true }
        }

        // 🔑 去空格匹配
        let inputNoSpace = inputLower.replacingOccurrences(of: " ", with: "")
        let resultNoSpace = resultLower.replacingOccurrences(of: " ", with: "")
        if inputNoSpace == resultNoSpace { return true }
        if !hasCJKIdentity,
           inputNoSpace.contains(resultNoSpace) || resultNoSpace.contains(inputNoSpace) { return true }

        // 🔑 CJK surname match: 中原明子 vs 中原めいこ (kanji→hiragana given name)
        let inputCJK = inputNoSpace.filter { $0.unicodeScalars.allSatisfy { LanguageUtils.isCJKScalar($0) } }
        let resultCJK = resultNoSpace.filter { $0.unicodeScalars.allSatisfy { LanguageUtils.isCJKScalar($0) } }
        if inputCJK.count >= 2 && resultCJK.count >= 2 {
            let prefix = inputCJK.commonPrefix(with: resultCJK)
            if prefix.count >= 2 && abs(inputCJK.count - resultCJK.count) <= 2 { return true }
        }

        return false
    }

    private func artistIdentityParts(_ value: String) -> [String] {
        var normalized = LanguageUtils.toSimplifiedChinese(
            LanguageUtils.normalizeArtistName(value)
        ).lowercased()
        let textualSeparators = [
            " featuring ", " feat. ", " feat ", " ft. ", " ft ",
            " with ", " and ", " x "
        ]
        for separator in textualSeparators {
            normalized = normalized.replacingOccurrences(of: separator, with: "/")
        }
        let separators = CharacterSet(charactersIn: "/／&＆,，、;；|｜+＋")
        return normalized
            .components(separatedBy: separators)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .filter { ch in
                        ch.unicodeScalars.allSatisfy {
                            CharacterSet.alphanumerics.contains($0) || LanguageUtils.isCJKScalar($0)
                        }
                    }
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - NetEase / QQ Music 共用搜索模板

    /// 搜索参数（normalized 后的标题/艺术家对）
    struct SearchParams {
        let simplifiedTitle: String
        let simplifiedArtist: String
        let simplifiedOriginalTitle: String
        let simplifiedOriginalArtist: String
        let rawTitle: String
        let rawArtist: String
        let rawOriginalTitle: String
        let rawOriginalArtist: String
        let duration: TimeInterval
        /// Normalized album name for fuzzy matching against result albums.
        let normalizedAlbum: String
        /// True when iTunes confirms the original `(title, artist, duration)` as
        /// an exact match in some region. When true, downstream matchers MUST
        /// NOT apply the romanized→CJK P3 escape.
        let disableCjkEscapeInP3: Bool

        /// resolved + original + dual-title halves 的标题/艺术家对（供 buildCandidates 匹配）
        let titlePairs: [(String, String)]
        let artistPairs: [(String, String)]

        private static func buildTitlePairs(
            rawTitle: String,
            rawOriginalTitle: String,
            simplifiedTitle: String,
            simplifiedOriginalTitle: String
        ) -> [(String, String)] {
            var pairs = [(rawTitle, simplifiedTitle), (rawOriginalTitle, simplifiedOriginalTitle)]
            for raw in [rawTitle, rawOriginalTitle] {
                for variant in LyricsFetcher.englishContractionVariants(raw) {
                    let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(variant))
                    pairs.append((variant, simplified))
                }
            }
            // 🔑 双标题
            for raw in [rawTitle, rawOriginalTitle] {
                if let halves = MetadataResolver.shared.splitDualTitle(raw) {
                    for half in [halves.first, halves.second] {
                        let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(half))
                        pairs.append((half, simplified))
                    }
                }
            }
            return pairs
        }

        init(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, album: String = "", disableCjkEscapeInP3: Bool = false) {
            let ct = LanguageUtils.normalizeTrackName(title)
            let cot = LanguageUtils.normalizeTrackName(originalTitle)
            self.simplifiedTitle = LanguageUtils.toSimplifiedChinese(ct)
            self.simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
            self.simplifiedOriginalTitle = LanguageUtils.toSimplifiedChinese(cot)
            self.simplifiedOriginalArtist = LanguageUtils.toSimplifiedChinese(originalArtist)
            self.rawTitle = title; self.rawArtist = artist
            self.rawOriginalTitle = originalTitle; self.rawOriginalArtist = originalArtist
            self.duration = duration
            self.normalizedAlbum = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(album)
            ).lowercased().replacingOccurrences(of: "-", with: " ")
            self.disableCjkEscapeInP3 = disableCjkEscapeInP3
            self.titlePairs = Self.buildTitlePairs(
                rawTitle: title,
                rawOriginalTitle: originalTitle,
                simplifiedTitle: self.simplifiedTitle,
                simplifiedOriginalTitle: self.simplifiedOriginalTitle
            )
            self.artistPairs = [
                (artist, self.simplifiedArtist),
                (originalArtist, self.simplifiedOriginalArtist)
            ]
        }
    }

    /// Keyword priority for deterministic ranking of parallel search results.
    static func keywordPriority(_ desc: String) -> Int {
        if desc.hasPrefix("title+artist") { return 0 }
        if desc.hasPrefix("original") { return 1 }
        if desc.hasPrefix("punctuation-title+artist") { return 2 }
        if desc.hasPrefix("traditional") { return 3 }
        if desc.hasPrefix("dual-") { return 4 }
        if desc.hasPrefix("contraction") { return 4 }
        if desc == "title only" { return 5 }
        if desc.hasPrefix("title+album") { return 6 }
        if desc.hasPrefix("album+artist") { return 7 }
        if desc.hasPrefix("alias album+artist") { return 7 }
        if desc.hasPrefix("alias+title") { return 8 }
        if desc.hasPrefix("alias artist only") { return 9 }
        if desc == "artist only" { return 10 }
        return 10
    }

    static func englishContractionVariants(_ input: String) -> [String] {
        guard LanguageUtils.isPureASCII(input) else { return [] }
        let replacements: [(String, String)] = [
            (#"\bits\b"#, "it's"),
            (#"\bim\b"#, "i'm"),
            (#"\bid\b"#, "i'd"),
            (#"\bill\b"#, "i'll"),
            (#"\bive\b"#, "i've"),
            (#"\byoure\b"#, "you're"),
            (#"\byoud\b"#, "you'd"),
            (#"\byoull\b"#, "you'll"),
            (#"\byouve\b"#, "you've"),
            (#"\bdont\b"#, "don't"),
            (#"\bcant\b"#, "can't"),
            (#"\bwont\b"#, "won't"),
            (#"\bdidnt\b"#, "didn't"),
            (#"\bdoesnt\b"#, "doesn't"),
            (#"\bisnt\b"#, "isn't"),
            (#"\barent\b"#, "aren't"),
            (#"\bwasnt\b"#, "wasn't"),
            (#"\bwerent\b"#, "weren't"),
            (#"\bhavent\b"#, "haven't"),
            (#"\bhasnt\b"#, "hasn't"),
            (#"\bhadnt\b"#, "hadn't"),
            (#"\bcouldnt\b"#, "couldn't"),
            (#"\bwouldnt\b"#, "wouldn't"),
            (#"\bshouldnt\b"#, "shouldn't")
        ]
        let lower = input.lowercased()
        var variants: [String] = []
        for (pattern, replacement) in replacements {
            guard lower.range(of: pattern, options: .regularExpression) != nil else { continue }
            let variant = input.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
            if variant != input, !variants.contains(variant) {
                variants.append(variant)
            }
        }
        return variants
    }

    /// 统一搜索模板：构建关键词 → 逐轮调 API → 构建候选 → 选择最佳
    func searchAndSelectCandidate<ID>(
        params: SearchParams,
        source: String,
        extraKeywords: [(String, String)] = [],
        enableAliasResolve: Bool = true,
        allowCompilationAlbumFallback: Bool = false,
        fetchSongs: @escaping (String) async throws -> [[String: Any]]?,
        extractSong: @escaping ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double, album: String)?
    ) async -> SelectedSearchCandidate<ID>? {
        // 多关键词策略（按优先级排列）
        var keywords: [(String, String)] = [
            ("\(params.simplifiedTitle) \(params.simplifiedArtist)", "title+artist")
        ]
        var seenKeywords = Set(keywords.map(\.0))
        func appendKeyword(_ keyword: String, _ label: String) {
            if seenKeywords.insert(keyword).inserted {
                keywords.append((keyword, label))
            }
        }
        if let collaborationQuery = Self.collaborationEvidenceTitleQuery(from: params.rawTitle) {
            appendKeyword("\(collaborationQuery) \(params.rawArtist)", "title+artist-collaboration")
        }
        if params.rawOriginalTitle != params.rawTitle,
           let collaborationQuery = Self.collaborationEvidenceTitleQuery(from: params.rawOriginalTitle) {
            appendKeyword("\(collaborationQuery) \(params.rawOriginalArtist)", "original-collaboration")
        }
        if let descriptorTerms = Self.cjkMediaDescriptorSearchTerms(from: params.rawTitle) {
            appendKeyword("\(params.simplifiedTitle) \(descriptorTerms) \(params.simplifiedArtist)", "title+media-descriptor+artist")
        }
        if params.rawOriginalTitle != params.rawTitle,
           let descriptorTerms = Self.cjkMediaDescriptorSearchTerms(from: params.rawOriginalTitle) {
            appendKeyword("\(params.simplifiedOriginalTitle) \(descriptorTerms) \(params.simplifiedOriginalArtist)", "original-media-descriptor")
        }
        for variant in Self.englishContractionVariants(params.rawTitle) {
            let normalizedVariant = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(variant))
            let kw = "\(normalizedVariant) \(params.simplifiedArtist)"
            appendKeyword(kw, "contraction+artist")
        }
        if params.simplifiedOriginalTitle != params.simplifiedTitle ||
           params.simplifiedOriginalArtist != params.simplifiedArtist {
            appendKeyword("\(params.simplifiedOriginalTitle) \(params.simplifiedOriginalArtist)", "original")
        }
        for titleVariant in Self.titlePunctuationVariants(params.rawTitle) {
            let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(titleVariant))
            let kw = "\(simplified) \(params.simplifiedArtist)"
            appendKeyword(kw, "punctuation-title+artist")
        }
        for variant in Self.englishContractionVariants(params.rawOriginalTitle) {
            let normalizedVariant = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(variant))
            let kw = "\(normalizedVariant) \(params.simplifiedOriginalArtist)"
            appendKeyword(kw, "contraction-original")
        }
        let traditionalPairs = [
            (
                LanguageUtils.toTraditionalChinese(LanguageUtils.normalizeTrackName(params.rawTitle)),
                LanguageUtils.toTraditionalChinese(params.rawArtist),
                "traditional"
            ),
            (
                LanguageUtils.toTraditionalChinese(LanguageUtils.normalizeTrackName(params.rawOriginalTitle)),
                LanguageUtils.toTraditionalChinese(params.rawOriginalArtist),
                "traditional-original"
            )
        ]
        for (title, artist, label) in traditionalPairs where LanguageUtils.containsCJK(title + artist) {
            let kw = "\(title) \(artist)"
            appendKeyword(kw, label)
        }
        if params.artistPairs.contains(where: { LanguageUtils.containsCJK($0.0) }) {
            for raw in [params.rawTitle, params.rawOriginalTitle] {
                guard let stem = japaneseRomanizedParticleStem(raw) else { continue }
                let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(stem))
                let kw = "\(simplified) \(params.simplifiedArtist)"
                appendKeyword(kw, "romaji-stem+artist")
            }
        }
        // 🔑 双标题拆分
        for raw in [params.rawTitle, params.rawOriginalTitle] {
            if let halves = MetadataResolver.shared.splitDualTitle(raw) {
                for (half, label) in [(halves.second, "dual-2nd"), (halves.first, "dual-1st")] {
                    let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(half))
                    let kw = "\(simplified) \(params.simplifiedArtist)"
                    appendKeyword(kw, label)
                }
            }
        }
        // 🔑 Title-only keyword
        let titleHasCJK = LanguageUtils.containsCJK(params.rawTitle)
        let artistIsASCII = LanguageUtils.isPureASCII(params.rawArtist)
        let originalArtistIsASCII = LanguageUtils.isPureASCII(params.rawOriginalArtist)
        if titleHasCJK {
            keywords.append((params.simplifiedTitle, "title only"))
        }
        // 🔑 Title+album keyword. ASCII album aliases from Apple Music are
        // useful evidence for localized native-title rows.
        if !params.normalizedAlbum.isEmpty {
            let albumKeywords = [
                ("\(params.simplifiedTitle) \(params.normalizedAlbum)", "title+album"),
                ("\(params.simplifiedTitle) \(params.normalizedAlbum) \(params.simplifiedArtist)", "title+album+artist")
            ]
            for (kw, label) in albumKeywords {
                appendKeyword(kw, label)
            }
            for (rawArtist, simplifiedArtist) in params.artistPairs {
                guard LanguageUtils.containsCJK(rawArtist)
                    || LanguageUtils.containsCJK(simplifiedArtist)
                    || LanguageUtils.isPureASCII(rawArtist) else { continue }
                let albumArtist = "\(params.normalizedAlbum) \(simplifiedArtist)"
                appendKeyword(albumArtist, "album+artist")
            }
        }
        let isResolvedCJKTitleArtist = LanguageUtils.containsCJK(params.rawTitle)
            && LanguageUtils.containsCJK(params.rawArtist)
            && LanguageUtils.isPureASCII(params.rawOriginalTitle)
        if isResolvedCJKTitleArtist {
            keywords.removeAll { _, desc in
                desc == "original" || desc == "artist only"
            }
        } else {
            keywords.append((params.simplifiedArtist, "artist only"))
        }
        keywords.append(contentsOf: extraKeywords)
        DebugLogger.log(source, "🔑 关键词: \(keywords.map(\.0))")

        // Fast path before parallel fan-out. A strict title+artist+duration hit
        // should not wait for slower album/title/artist-only probes to cancel.
        if let (keyword, desc) = keywords.first {
            DebugLogger.log(source, "🔎 \(desc): '\(keyword)'")
            do {
                if let songs = try await fetchSongs(keyword) {
                    DebugLogger.log(source, "📦 \(desc): \(songs.count) 个候选")
                    let candidates = self.buildCandidates(
                        songs: songs, params: params, searchDescriptor: desc, extractSong: extractSong
                    )
                    if let match = self.selectBestCandidate(
                        candidates,
                        source: source,
                        inputTitle: params.rawTitle,
                        inputArtist: params.rawArtist,
                        disableCjkEscape: params.disableCjkEscapeInP3,
                        hasAlbumHint: !params.normalizedAlbum.isEmpty,
                        allowNativeTitleAlias: true,
                        allowCompilationAlbumFallback: allowCompilationAlbumFallback
                    ) {
                        let strictExactMatch = match.matchRank == 0
                            && match.titleMatched
                            && match.durationDiff < 1.5
                        let cjkTitleArtistP2Match = LanguageUtils.containsCJK(params.rawTitle)
                            && match.matchRank <= 2
                            && match.titleMatched
                            && match.durationDiff < 3.5
                        if strictExactMatch || cjkTitleArtistP2Match {
                            DebugLogger.log(source, "⚡ Preflight exact match via '\(desc)' (albumMatch=\(match.albumMatched), Δ\(String(format: "%.1f", match.durationDiff))s)")
                            return match
                        }
                    }
                } else {
                    DebugLogger.log(source, "⚠️ \(desc): fetchSongs returned nil (parse failure)")
                }
            } catch {
                DebugLogger.log(source, "⚠️ \(desc) HTTP error: \(error)")
            }
        }

        if enableAliasResolve,
           LanguageUtils.isPureASCII(params.rawTitle),
           !LanguageUtils.isLikelyEnglishTitle(params.rawTitle),
           (artistIsASCII || originalArtistIsASCII) {
            let asciiProbe = artistIsASCII ? params.rawArtist : params.rawOriginalArtist
            let aliases = await self.resolveArtistCJKAliases(
                asciiArtist: asciiProbe,
                allowUnconfirmedCatalogMatches: false
            )
            for cjkArtist in aliases.prefix(3) {
                let aliasParams = SearchParams(
                    title: params.rawTitle,
                    artist: cjkArtist,
                    originalTitle: params.rawOriginalTitle,
                    originalArtist: params.rawOriginalArtist,
                    duration: params.duration,
                    album: params.normalizedAlbum,
                    disableCjkEscapeInP3: params.disableCjkEscapeInP3
                )
                let probes = [
                    ("\(params.simplifiedTitle) \(cjkArtist)", "alias+title:\(cjkArtist)"),
                    (cjkArtist, "alias artist only:\(cjkArtist)")
                ]
                for (keyword, desc) in probes {
                    DebugLogger.log(source, "🔎 \(desc): '\(keyword)'")
                    do {
                        guard let songs = try await fetchSongs(keyword) else { continue }
                        DebugLogger.log(source, "📦 \(desc): \(songs.count) 个候选")
                        let candidates = self.buildCandidates(
                            songs: songs, params: aliasParams, searchDescriptor: desc, extractSong: extractSong
                        )
                        if let match = self.selectBestCandidate(
                            candidates,
                            source: source,
                            inputTitle: params.rawTitle,
                            inputArtist: params.rawArtist,
                            disableCjkEscape: params.disableCjkEscapeInP3,
                            aliasConfirmedCJK: true,
                            hasAlbumHint: !params.normalizedAlbum.isEmpty,
                            allowNativeTitleAlias: true,
                            allowCompilationAlbumFallback: allowCompilationAlbumFallback
                        ), match.titleMatched,
                           match.durationDiff < 1.5 {
                            DebugLogger.log(source, "⚡ Preflight alias exact match via '\(desc)' (albumMatch=\(match.albumMatched), Δ\(String(format: "%.1f", match.durationDiff))s)")
                            return match
                        }
                    } catch {
                        DebugLogger.log(source, "⚠️ \(desc) HTTP error: \(error)")
                    }
                }
            }
        }

        // 🔑 Parallel keyword search — fire ALL rounds simultaneously.
        return await withTaskGroup(of: (SelectedSearchCandidate<ID>, String, Int)?.self) { group in
            // 🔑 Alias-resolved keyword
            if enableAliasResolve && (artistIsASCII || originalArtistIsASCII) {
                group.addTask {
                    let asciiProbe = artistIsASCII ? params.rawArtist : params.rawOriginalArtist
                    let aliases = await self.resolveArtistCJKAliases(
                        asciiArtist: asciiProbe,
                        allowUnconfirmedCatalogMatches: titleHasCJK
                    )
                    for cjkArtist in aliases.prefix(5) {
                        let probes = [
                            ("\(params.simplifiedTitle) \(cjkArtist)", "alias+title:\(cjkArtist)"),
                            (cjkArtist, "alias artist only:\(cjkArtist)")
                        ]
                        var aliasProbes = probes
                        if let collaborationQuery = Self.collaborationEvidenceTitleQuery(from: params.rawTitle) {
                            aliasProbes.insert(("\(collaborationQuery) \(asciiProbe)", "alias+title-collaboration:\(cjkArtist)"), at: 0)
                        }
                        if !params.normalizedAlbum.isEmpty {
                            aliasProbes.append(("\(params.normalizedAlbum) \(cjkArtist)", "alias album+artist:\(cjkArtist)"))
                        }
                        for (kw, desc) in aliasProbes {
                            DebugLogger.log(source, "🔎 \(desc): '\(kw)'")
                            do {
                                guard let songs = try await fetchSongs(kw) else { continue }
                                DebugLogger.log(source, "📦 \(desc): \(songs.count) 个候选")
                                let aliasParams = SearchParams(
                                    title: params.rawTitle, artist: cjkArtist,
                                    originalTitle: params.rawOriginalTitle,
                                    originalArtist: params.rawOriginalArtist,
                                    duration: params.duration,
                                    album: params.normalizedAlbum,
                                    disableCjkEscapeInP3: params.disableCjkEscapeInP3
                                )
                                let candidates = self.buildCandidates(
                                    songs: songs, params: aliasParams, searchDescriptor: desc, extractSong: extractSong
                                )
                                if let m = self.selectBestCandidate(candidates, source: source, inputTitle: params.rawTitle, inputArtist: params.rawArtist, disableCjkEscape: params.disableCjkEscapeInP3, aliasConfirmedCJK: true, hasAlbumHint: !params.normalizedAlbum.isEmpty, allowNativeTitleAlias: true, allowCompilationAlbumFallback: allowCompilationAlbumFallback) {
                                    return (m, desc, Self.keywordPriority(desc))
                                }
                            } catch {
                                DebugLogger.log(source, "⚠️ \(desc) HTTP error: \(error)")
                            }
                        }
                    }
                    return nil
                }
            }
            for (keyword, desc) in keywords {
                group.addTask {
                    DebugLogger.log(source, "🔎 \(desc): '\(keyword)'")
                    do {
                        guard let songs = try await fetchSongs(keyword) else {
                            DebugLogger.log(source, "⚠️ \(desc): fetchSongs returned nil (parse failure)")
                            return nil
                        }
                        DebugLogger.log(source, "📦 \(desc): \(songs.count) 个候选")
                        let candidates = self.buildCandidates(
                            songs: songs, params: params, searchDescriptor: desc, extractSong: extractSong
                        )
                        let allowNativeTitleAlias = desc.hasPrefix("title+artist")
                            || desc.hasPrefix("original")
                            || desc.hasPrefix("traditional")
                            || desc.hasPrefix("dual-")
                            || desc == "title only"
                            || desc == "artist only"
                            || desc.hasPrefix("romaji-stem+artist")
                        if let match = self.selectBestCandidate(candidates, source: source, inputTitle: params.rawTitle, inputArtist: params.rawArtist, disableCjkEscape: params.disableCjkEscapeInP3, hasAlbumHint: !params.normalizedAlbum.isEmpty, allowNativeTitleAlias: allowNativeTitleAlias, allowCompilationAlbumFallback: allowCompilationAlbumFallback) {
                            return (match, desc, Self.keywordPriority(desc))
                        }
                    } catch {
                        DebugLogger.log(source, "⚠️ \(desc) HTTP error: \(error)")
                    }
                    return nil
                }
            }
            // Collect ALL results, pick the best deterministically.
            var allResults: [(SelectedSearchCandidate<ID>, String, Int)] = []
            for await result in group {
                guard let r = result else { continue }
                let nativeScriptTitleMatch = r.0.title.unicodeScalars.contains {
                    LanguageUtils.isCJKScalar($0) || LanguageUtils.isJapaneseKana($0)
                }
                let exactNativeAliasMatch = LanguageUtils.isPureASCII(params.rawTitle)
                    && nativeScriptTitleMatch
                    && (
                        r.1 == "artist only"
                        || r.1.hasPrefix("alias artist only")
                        || r.1.hasPrefix("alias+title")
                        || r.1.hasPrefix("album+artist")
                        || r.1.hasPrefix("alias album+artist")
                    )
                if r.0.matchRank == 0,
                   r.0.titleMatched,
                   r.0.durationDiff < 1.5,
                   (r.2 <= 1 || r.0.albumMatched || exactNativeAliasMatch) {
                    DebugLogger.log(source, "⚡ Fast exact match via '\(r.1)' (albumMatch=\(r.0.albumMatched), Δ\(String(format: "%.1f", r.0.durationDiff))s)")
                    group.cancelAll()
                    return r.0
                }
                allResults.append(r)
            }
            guard !allResults.isEmpty else { return nil }
            let best = allResults.min { a, b in
                if a.0.albumMatched != b.0.albumMatched { return a.0.albumMatched && !b.0.albumMatched }
                if a.0.titleMatched != b.0.titleMatched { return a.0.titleMatched && !b.0.titleMatched }
                if a.0.matchRank != b.0.matchRank { return a.0.matchRank < b.0.matchRank }
                if a.0.durationDiff != b.0.durationDiff { return a.0.durationDiff < b.0.durationDiff }
                return a.2 < b.2
            }!
            let matchType = best.0.albumMatched ? "albumMatch=true" : "no album match"
            let titleType = best.0.titleMatched ? "titleMatch=true" : "titleMatch=false"
            DebugLogger.log(source, "⚡ Best match via '\(best.1)' (\(matchType), \(titleType), rank=\(best.0.matchRank), Δ\(String(format: "%.1f", best.0.durationDiff))s) from \(allResults.count) rounds")
            return best.0
        }
    }

    static func titlePunctuationVariants(_ title: String) -> [String] {
        let stripped = title.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        var variants: [String] = []

        if stripped != title {
            variants.append(stripped)
        }

        let contractions: [(String, String)] = [
            (#"\bIts\b"#, "It's"),
            (#"\bIm\b"#, "I'm"),
            (#"\bId\b"#, "I'd"),
            (#"\bIll\b"#, "I'll"),
            (#"\bIve\b"#, "I've"),
            (#"\bDont\b"#, "Don't"),
            (#"\bCant\b"#, "Can't"),
            (#"\bWont\b"#, "Won't"),
            (#"\bYoure\b"#, "You're"),
            (#"\bYoull\b"#, "You'll"),
            (#"\bTheyre\b"#, "They're"),
            (#"\bTheres\b"#, "There's"),
            (#"\bThats\b"#, "That's")
        ]
        var contracted = title
        for (pattern, replacement) in contractions {
            contracted = contracted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        if contracted != title {
            variants.append(contracted)
        }

        return Array(NSOrderedSet(array: variants).compactMap { $0 as? String }).prefix(4).map { $0 }
    }

    static func collaborationEvidenceTitleQuery(from title: String) -> String? {
        guard LanguageUtils.isPureASCII(title) else { return nil }
        let lower = title.lowercased()
        let markers = [" feat. ", " feat ", " featuring ", " ft. ", " ft ", " with ", "(feat.", "(feat ", "(featuring ", "(ft.", "(ft ", "[feat.", "[feat "]
        guard let markerRange = markers
            .compactMap({ marker -> Range<String.Index>? in lower.range(of: marker) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        let primary = String(title[..<markerRange.lowerBound])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "([{-–—")))
        guard primary.count >= 2 else { return nil }
        var suffix = String(title[markerRange.upperBound...])
        if let end = suffix.firstIndex(where: { [")", "]", "}", "）"].contains(String($0)) }) {
            suffix = String(suffix[..<end])
        }
        let separators = [" & ", " and ", " x ", " X ", ",", "/", "+", "、", "，"]
        var parts = [suffix]
        for separator in separators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        let collaborators = parts
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".:-–—()[]{}"))) }
            .filter { !$0.isEmpty }
        guard !collaborators.isEmpty else { return nil }
        return ([primary] + collaborators).joined(separator: " ")
    }

    static func cjkMediaDescriptorSearchTerms(from title: String) -> String? {
        let mediaMarkers = ["电视剧", "電視劇", "电影", "電影", "原声", "原聲", "插曲", "主题曲", "主題曲", "片头", "片頭", "片尾", "片名曲", "ost"]
        let pattern = #"[（(]([^）)]{2,})[）)]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsTitle = title as NSString
        let matches = regex.matches(in: title, range: NSRange(location: 0, length: nsTitle.length))
        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let segment = nsTitle.substring(with: match.range(at: 1))
            let lower = segment.lowercased()
            guard LanguageUtils.containsCJK(segment),
                  mediaMarkers.contains(where: { lower.contains($0.lowercased()) }) else { continue }
            if let quoted = firstQuotedCJKPhrase(in: segment) {
                return quoted
            }
            let cleaned = mediaMarkers.reduce(segment) { partial, marker in
                partial.replacingOccurrences(of: marker, with: " ")
            }
            let tokens = cleaned
                .components(separatedBy: CharacterSet(charactersIn: "《》「」『』【】[]·・:：_-—–/|｜"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { token in
                    token.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count >= 2
                }
            if let first = tokens.first {
                return first
            }
        }
        return nil
    }

    private static func firstQuotedCJKPhrase(in text: String) -> String? {
        let patterns = [#"《([^》]{2,})》"#, #"「([^」]{2,})」"#, #"『([^』]{2,})』"#]
        let nsText = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
                  match.numberOfRanges >= 2 else { continue }
            let phrase = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if phrase.unicodeScalars.filter({ LanguageUtils.isCJKScalar($0) }).count >= 2 {
                return phrase
            }
        }
        return nil
    }

    // MARK: - Romaji Particle Stem

    func japaneseRomanizedParticleStem(_ title: String) -> String? {
        guard LanguageUtils.isPureASCII(title) else { return nil }
        let particles: Set<String> = ["ga", "no", "ni", "wo", "wa", "na", "de", "to"]
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let particleIndex = words.firstIndex(where: { particles.contains($0) }),
              particleIndex > 0 else { return nil }
        let stem = words[..<particleIndex].joined(separator: " ")
        guard stem.count >= 4 else { return nil }
        return stem
    }

    // MARK: - Candidate Builder

    /// 统一候选构建（消除 NetEase/QQ 各自的 buildXxxCandidates）
    func buildCandidates<ID>(
        songs: [[String: Any]],
        params: SearchParams,
        searchDescriptor: String = "",
        extractSong: ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double, album: String)?
    ) -> [SearchCandidate<ID>] {
        songs.enumerated().compactMap { index, song in
            guard let s = extractSong(song) else { return nil }
            let durationDiff = abs(s.duration - params.duration)

            // 🔑 Cover/Live rejection
            let coverMarkers = ["cover", "翻唱", "翻奏", "翻自", "demo", "demo版", "试唱"]
            let liveMarkers = ["live", "現場", "现场", "live版", "演唱会"]
            let localizedVersionMarkers = [
                "japanese version", "japanese ver", "korean version", "korean ver",
                "english version", "english ver", "chinese version", "chinese ver",
                "mandarin version", "cantonese version",
                "日文版", "日语版", "日本語バージョン",
                "韩文版", "韓文版", "韩国语版", "韓国語バージョン",
                "英文版", "英语版", "中文版", "国语版", "國語版", "粤语版", "粵語版"
            ]
            let resultNameLower = s.name.lowercased()
            let resultAlbumLower = s.album.lowercased()
            let inputHasCover = params.titlePairs.contains { pair in
                coverMarkers.contains(where: { pair.0.lowercased().contains($0) })
            }
            let resultHasCover = coverMarkers.contains(where: { resultNameLower.contains($0) })
            if resultHasCover && !inputHasCover { return nil }
            let inputHasLive = params.titlePairs.contains { pair in
                liveMarkers.contains(where: { pair.0.lowercased().contains($0) })
            }
            let resultHasLive = liveMarkers.contains(where: { resultNameLower.contains($0) })
            if resultHasLive && !inputHasLive { return nil }
            let inputHasLocalizedVersion = params.titlePairs.contains { pair in
                localizedVersionMarkers.contains(where: { pair.0.lowercased().contains($0) })
            }
            let resultHasLocalizedVersion = localizedVersionMarkers.contains(where: { resultNameLower.contains($0) })
            if resultHasLocalizedVersion && !inputHasLocalizedVersion { return nil }
            let backingTrackMarkers = ["karaoke", "instrumental", "伴奏", "カラオケ", "オリジナル・カラオケ"]
            let inputHasBackingTrack = params.titlePairs.contains { pair in
                backingTrackMarkers.contains(where: { pair.0.lowercased().contains($0) })
            }
            let resultHasBackingTrack = backingTrackMarkers.contains {
                resultNameLower.contains($0) || resultAlbumLower.contains($0)
            }
            if resultHasBackingTrack && !inputHasBackingTrack { return nil }

            let titleMatch = params.titlePairs.contains { isTitleMatch(input: $0.0, result: s.name, simplifiedInput: $0.1) }
            let compactTitleMatch = params.titlePairs.contains { pair in
                let inputCompact = compactTitleIdentity(pair.0)
                let resultCompact = compactTitleIdentity(s.name)
                return !inputCompact.isEmpty && inputCompact == resultCompact
            }
            var artistMatch = params.artistPairs.contains { isArtistMatch(input: $0.0, result: s.artist, simplifiedInput: $0.1) }

            // 🔑 Cross-script tolerance
            let inputArtistIsASCII = params.artistPairs.contains { LanguageUtils.isPureASCII($0.0) }
            let resultArtistIsCJK = LanguageUtils.containsCJK(s.artist)
            let resultArtistIsASCII = LanguageUtils.isPureASCII(s.artist)
            let inputArtistIsCJK = params.artistPairs.contains { LanguageUtils.containsCJK($0.0) }
            let isCrossScriptArtist = (inputArtistIsASCII && resultArtistIsCJK) || (inputArtistIsCJK && resultArtistIsASCII)

            let inputHasBothScripts = inputArtistIsASCII && inputArtistIsCJK
            let inputTitleHasCJK = params.titlePairs.contains { LanguageUtils.containsCJK($0.0) }
            let inputArtistIsCompilation = params.artistPairs.contains {
                isCompilationArtistName($0.0) || isCompilationArtistName($0.1)
            }
            let resultArtistIsCompilation = isCompilationArtistName(s.artist)
            // 🔑 Album match (fuzzy, contains-either-way)
            let albumMatch = providerAlbumMatches(
                inputNormalizedAlbum: params.normalizedAlbum,
                resultAlbum: s.album
            )

            // 🔑 Cross-script tolerance tiers
            let resultTitleIsCJK = LanguageUtils.containsCJK(s.name)
            if !artistMatch,
               isCrossScriptArtist,
               !inputHasBothScripts,
               !(inputTitleHasCJK && inputArtistIsASCII && resultArtistIsCJK),
               (!resultArtistIsCompilation || inputArtistIsCompilation) {
                if (albumMatch && titleMatch) ||
                   (titleMatch && durationDiff < 1.0) ||
                   (compactTitleMatch && searchDescriptor.hasPrefix("title+artist") && durationDiff < 20.0) ||
                   (!titleMatch && resultTitleIsCJK && durationDiff < 1.0) {
                    artistMatch = true
                }
            }
            if !artistMatch,
               inputArtistIsCompilation,
               albumMatch,
               titleMatch,
               durationDiff < 1.5,
               resultArtistIsCompilation {
                artistMatch = true
            }
            let hasCJKIdentity = params.titlePairs.contains { LanguageUtils.containsCJK($0.0) }
                || params.artistPairs.contains { LanguageUtils.containsCJK($0.0) }
                || LanguageUtils.containsCJK(s.name)
                || LanguageUtils.containsCJK(s.artist)
            let exactIdentityDurationLimit: Double = {
                if albumMatch { return 45 }
                if hasCJKIdentity { return 35 }
                return 20
            }()
            let durationLimit = titleMatch && artistMatch ? exactIdentityDurationLimit : 20
            guard durationDiff < durationLimit else { return nil }

            let normalizedNameLength = LanguageUtils.normalizeTrackName(s.name).count

            return SearchCandidate(
                id: s.id, name: s.name, artist: s.artist, album: s.album,
                durationDiff: durationDiff,
                titleMatch: titleMatch, artistMatch: artistMatch,
                albumMatch: albumMatch,
                normalizedNameLength: normalizedNameLength,
                resultIndex: index,
                searchDescriptor: searchDescriptor
            )
        }
    }

    func providerAlbumMatches(inputNormalizedAlbum: String, resultAlbum: String) -> Bool {
        let normalizedAlbum = LanguageUtils.toSimplifiedChinese(
            LanguageUtils.normalizeTrackName(resultAlbum)
        ).lowercased().replacingOccurrences(of: "-", with: " ")
        guard !inputNormalizedAlbum.isEmpty, !normalizedAlbum.isEmpty else { return false }
        if inputNormalizedAlbum == normalizedAlbum { return true }
        if inputNormalizedAlbum.contains(normalizedAlbum) { return true }
        if normalizedAlbum.contains(inputNormalizedAlbum) { return true }

        let inputLatin = LanguageUtils.toLatinLower(inputNormalizedAlbum)
        let resultLatin = LanguageUtils.toLatinLower(normalizedAlbum)
        if !inputLatin.isEmpty, !resultLatin.isEmpty,
           inputLatin.count >= 3, resultLatin.count >= 3 {
            if inputLatin == resultLatin { return true }
            if inputLatin.contains(resultLatin) { return true }
            if resultLatin.contains(inputLatin) { return true }
        }

        // Pinyin/Romaji album cross-script match.
        let inputHasCJK = LanguageUtils.containsCJK(inputNormalizedAlbum)
        let resultHasCJK = LanguageUtils.containsCJK(normalizedAlbum)
        if inputHasCJK != resultHasCJK {
            guard !inputLatin.isEmpty, !resultLatin.isEmpty,
                  inputLatin.count >= 3, resultLatin.count >= 3 else { return false }
            if inputLatin == resultLatin { return true }
            if inputLatin.contains(resultLatin) { return true }
            if resultLatin.contains(inputLatin) { return true }
        }
        return false
    }

    func isSafeCompilationAlbumFallbackCandidate(
        params: SearchParams,
        candidateTitle: String,
        candidateArtist: String,
        candidateAlbum: String,
        candidateDuration: Double,
        resultIndex: Int,
        searchDescriptor: String
    ) -> Bool {
        guard !params.normalizedAlbum.isEmpty else { return false }
        guard !isCompilationArtistName(params.rawArtist),
              !isCompilationArtistName(params.rawOriginalArtist) else { return false }
        guard isCompilationArtistName(candidateArtist) else { return false }
        guard resultIndex < 12 else { return false }
        guard searchDescriptor.lowercased().contains("album") else { return false }

        let lowerTitle = candidateTitle.lowercased()
        let lowerAlbum = candidateAlbum.lowercased()
        let backingTrackMarkers = ["karaoke", "instrumental", "伴奏", "カラオケ", "オリジナル・カラオケ"]
        guard !backingTrackMarkers.contains(where: {
            lowerTitle.contains($0) || lowerAlbum.contains($0)
        }) else { return false }

        let durationDiff = abs(candidateDuration - params.duration)
        guard durationDiff < 1.5 else { return false }
        let titleOK = params.titlePairs.contains {
            isTitleMatch(input: $0.0, result: candidateTitle, simplifiedInput: $0.1)
        }
        guard titleOK else { return false }
        return providerAlbumMatches(
            inputNormalizedAlbum: params.normalizedAlbum,
            resultAlbum: candidateAlbum
        )
    }

    func isSafeCompilationAlbumDiscoveryCandidate(
        params: SearchParams,
        candidateTitle: String,
        candidateArtist: String,
        candidateAlbum: String,
        candidateDuration: Double,
        resultIndex: Int
    ) -> Bool {
        guard !params.normalizedAlbum.isEmpty else { return false }
        guard !isCompilationArtistName(params.rawArtist),
              !isCompilationArtistName(params.rawOriginalArtist) else { return false }
        guard isDistinctiveCatalogExactTitleInput(params) else { return false }
        guard isCompilationArtistName(candidateArtist) else { return false }
        guard resultIndex < 80 else { return false }

        let cleanAlbum = candidateAlbum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanAlbum.isEmpty,
              LanguageUtils.containsCJK(cleanAlbum) else { return false }
        guard !providerAlbumMatches(inputNormalizedAlbum: params.normalizedAlbum, resultAlbum: cleanAlbum) else {
            return false
        }

        let lowerTitle = candidateTitle.lowercased()
        let lowerAlbum = cleanAlbum.lowercased()
        let backingTrackMarkers = ["karaoke", "instrumental", "伴奏", "カラオケ", "オリジナル・カラオケ"]
        guard !backingTrackMarkers.contains(where: {
            lowerTitle.contains($0) || lowerAlbum.contains($0)
        }) else { return false }

        let durationDiff = abs(candidateDuration - params.duration)
        guard durationDiff < 1.5 else { return false }
        return params.titlePairs.contains {
            isTitleMatch(input: $0.0, result: candidateTitle, simplifiedInput: $0.1)
        }
    }

    func isDistinctiveCatalogExactTitleInput(_ params: SearchParams) -> Bool {
        isDistinctiveCatalogExactTitle([
            params.rawTitle,
            params.rawOriginalTitle,
            params.simplifiedTitle,
            params.simplifiedOriginalTitle
        ])
    }

    func isDistinctiveCatalogExactTitle(_ titleVariants: [String]) -> Bool {
        for title in titleVariants {
            let normalized = LanguageUtils.normalizeTrackName(title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            let simplified = LanguageUtils.toSimplifiedChinese(normalized)
            let cjkCount = simplified.unicodeScalars.filter {
                LanguageUtils.isCJKScalar($0)
            }.count
            if cjkCount >= 4 { return true }

            let tokens = normalized.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            let compact = tokens.joined()
            let lower = normalized.lowercased()
            let hasFeaturedArtistMarker = [
                " feat. ", " feat ", " featuring ", " ft. ", " ft ",
                "(feat.", "(feat ", "(featuring ", "(ft.", "(ft "
            ].contains { lower.contains($0) }
            if LanguageUtils.isPureASCII(normalized),
               tokens.count >= 4,
               compact.count >= 10,
               !hasFeaturedArtistMarker {
                return true
            }

            let compactNonASCII = simplified.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || LanguageUtils.isCJKScalar($0)
            }
            if !LanguageUtils.isPureASCII(normalized),
               compactNonASCII.count >= 6 {
                return true
            }
        }

        return false
    }

    func isCompilationArtistName(_ artist: String) -> Bool {
        let normalized = LanguageUtils.normalizeArtistName(artist)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        let simplified = LanguageUtils.toSimplifiedChinese(normalized)
        return [
            "variousartists", "various", "va", "群星", "合辑", "合輯",
            "multipleartists", "originalsoundtrack", "soundtrack"
        ].contains(simplified)
    }

    // MARK: - Artist Alias Resolution

    /// Split a name string into a token set for order-insensitive comparison.
    static func nameTokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    static func isConfirmedArtistAlias(asciiArtist: String, providerAliases: [String]) -> Bool {
        let inputTokens = Self.nameTokens(asciiArtist)
        guard !inputTokens.isEmpty else { return false }
        return providerAliases.contains {
            Self.nameTokens($0) == inputTokens
        }
    }

    actor ArtistAliasCache {
        private var cache: [String: [String]] = [:]
        func get(_ key: String) -> [String]? { cache[key] }
        func set(_ key: String, _ value: [String]) { cache[key] = value }
    }

    /// Generate plausible Pinyin-style probe strings from an ASCII artist name.
    func artistProbeVariants(_ input: String) -> [String] {
        var probes: [String] = []
        func addProbe(_ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            guard !probes.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { return }
            probes.append(clean)
        }

        addProbe(input)
        // 🔑 Multi-artist splitting
        let multiArtistSeparators = [" & ", ", ", " feat. ", " feat ", " featuring ", " Feat. ", " with ", " and ", " x ", " X "]
        for sep in multiArtistSeparators {
            if input.contains(sep) {
                let parts = input.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for part in parts where part != input {
                    addProbe(part)
                }
            }
        }

        let rules: [(String, String)] = [
            // HK/TW surname variants
            (" lee ", " li "),
            (" chang ", " zhang "),
            (" hung ", " hong "),
            // Wade-Giles → Pinyin syllable bodies
            ("chih", "zhi"), ("chieh", "jie"), ("chien", "jian"),
            ("ching", "qin"), ("chung", "zhong"), ("chiang", "jiang"),
            ("chou", "zhou"), ("chun", "zhun"), ("chuan", "zhuan"),
            ("tsung", "zong"), ("tse", "ze"), ("tsao", "cao"),
            ("hsieh", "xie"), ("hsi", "xi"), ("hsin", "xin"), ("hsu", "xu"),
            ("kuo", "guo"), ("keng", "geng"), ("kang", "gang"),
            // Jyutping → Pinyin (Cantonese romanization)
            ("eung", "iang"), ("oeng", "iang"), ("yuen", "yuan"),
            ("cheung", "zhang"), ("leung", "liang"), ("wong", "wang"),
        ]
        let baseProbes = probes
        for probe in baseProbes {
            var variant = " " + probe.lowercased() + " "
            for (a, b) in rules { variant = variant.replacingOccurrences(of: a, with: b) }
            variant = variant.trimmingCharacters(in: .whitespaces)
            if variant != probe.lowercased() {
                addProbe(variant)
            }
            // Also try a no-space compact form
            let compact = variant.replacingOccurrences(of: " ", with: "")
            if compact != variant {
                addProbe(compact)
            }
        }
        return probes
    }

    /// Resolve an ASCII artist name to CJK catalog names. Strict mode only
    /// accepts provider-declared aliases. When the title is already CJK, the
    /// caller may also allow lower-confidence CJK artist probes; those probes
    /// still have to survive the normal title+artist+duration candidate gates.
    func resolveArtistCJKAliases(
        asciiArtist: String,
        allowUnconfirmedCatalogMatches: Bool = false
    ) async -> [String] {
        let key = "\(asciiArtist.lowercased())|\(allowUnconfirmedCatalogMatches ? "loose" : "strict")"
        if let cached = await artistAliasCache.get(key) { return cached }
        guard LanguageUtils.isPureASCII(asciiArtist) else {
            await artistAliasCache.set(key, []); return []
        }
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                       "Referer": "https://music.163.com"]
        let inputLower = asciiArtist.lowercased()
        var seen: Set<String> = []
        var aliases: [String] = []
        var catalogCandidates: [String] = []
        let probes = artistProbeVariants(asciiArtist)
        let resolvedBatches = await withTaskGroup(of: (Int, [String], [String]).self) { group in
            for (index, probe) in probes.enumerated() {
                group.addTask {
                    guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                        "s": probe, "type": "100", "limit": "5"
                    ]) else { return (index, [], []) }
                    do {
                        let (data, _) = try await HTTPClient.getData(url: url, headers: headers, timeout: 1.2, retry: false)
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let result = json["result"] as? [String: Any],
                              let artists = result["artists"] as? [[String: Any]] else { return (index, [], []) }
                        var confirmed: [String] = []
                        var catalog: [String] = []
                        for artist in artists.prefix(5) {
                            guard let cjkName = artist["name"] as? String,
                                  LanguageUtils.containsCJK(cjkName) else { continue }
                            let aliasList = artist["alias"] as? [String] ?? []
                            let isConfirmed = Self.isConfirmedArtistAlias(asciiArtist: probe.lowercased(), providerAliases: aliasList)
                                || Self.isConfirmedArtistAlias(asciiArtist: inputLower, providerAliases: aliasList)
                            if isConfirmed {
                                confirmed.append(cjkName)
                            } else if allowUnconfirmedCatalogMatches,
                                      probe.lowercased() != inputLower {
                                catalog.append(cjkName)
                            }
                        }
                        if !confirmed.isEmpty {
                            catalog.removeAll()
                        }
                        return (index, confirmed, catalog)
                    } catch {
                        return (index, [], [])
                    }
                }
            }
            if allowUnconfirmedCatalogMatches {
                group.addTask {
                    let wikiAliases = await self.resolveWikipediaChineseArtistAliases(asciiArtist: asciiArtist)
                    return (-1, wikiAliases, [])
                }
            }

            var batches: [(Int, [String], [String])] = []
            for await batch in group {
                batches.append(batch)
                if !allowUnconfirmedCatalogMatches, !batch.1.isEmpty {
                    group.cancelAll()
                    break
                }
            }
            return batches.sorted { lhs, rhs in
                if lhs.0 == -1 { return false }
                if rhs.0 == -1 { return true }
                return lhs.0 < rhs.0
            }
        }

        for (_, confirmed, catalog) in resolvedBatches {
            for cjkName in confirmed where !seen.contains(cjkName) {
                aliases.append(cjkName)
                seen.insert(cjkName)
            }
            for cjkName in catalog where !catalogCandidates.contains(cjkName) {
                catalogCandidates.append(cjkName)
            }
        }
        if allowUnconfirmedCatalogMatches {
            for cjkName in catalogCandidates.prefix(5) where !seen.contains(cjkName) {
                aliases.append(cjkName)
                seen.insert(cjkName)
            }
        }
        if !aliases.isEmpty {
            DebugLogger.log("NetEase", "🔗 CJK artist resolve: '\(asciiArtist)' → \(aliases.prefix(5))")
        }
        await artistAliasCache.set(key, aliases)
        return aliases
    }

    private func resolveWikipediaChineseArtistAliases(asciiArtist: String) async -> [String] {
        guard let encoded = asciiArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&srlimit=5&format=json") else {
            return []
        }
        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "nanoPod/1.0 (artist-alias lookup)"
            ], timeout: 1.2, retry: false)
            guard let query = json["query"] as? [String: Any],
                  let results = query["search"] as? [[String: Any]] else { return [] }
            var aliases: [String] = []
            for result in results {
                guard let title = result["title"] as? String,
                      title.lowercased().contains(asciiArtist.lowercased()) else { continue }
                if let snippet = result["snippet"] as? String {
                    aliases.append(contentsOf: extractChineseNames(fromWikipediaSnippet: snippet))
                }
                aliases.append(contentsOf: await fetchWikipediaChineseLanglink(title: title))
                if !aliases.isEmpty { break }
            }
            return aliases
        } catch {
            return []
        }
    }

    private func fetchWikipediaChineseLanglink(title: String) async -> [String] {
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&prop=langlinks&lllang=zh&titles=\(encoded)&format=json") else {
            return []
        }
        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "nanoPod/1.0 (artist-alias lookup)"
            ], timeout: 1.2, retry: false)
            guard let query = json["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any] else { return [] }
            return pages.values.compactMap { value in
                guard let page = value as? [String: Any],
                      let links = page["langlinks"] as? [[String: Any]],
                      let zh = links.first?["*"] as? String,
                      LanguageUtils.containsCJK(zh) else { return nil }
                return zh
            }
        } catch {
            return []
        }
    }

    private func extractChineseNames(fromWikipediaSnippet snippet: String) -> [String] {
        let decoded = snippet
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let range = decoded.range(of: #"Chinese:\s*([^;,\)\(]+)"#, options: .regularExpression) else {
            return []
        }
        let match = String(decoded[range])
        guard let colon = match.firstIndex(of: ":") else { return [] }
        let name = match[match.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard LanguageUtils.containsCJK(name) else { return [] }
        return [name]
    }
}
