/**
 * [INPUT]: Raw search results from NetEase/QQ APIs
 * [OUTPUT]: selectBestCandidate — unified priority-chain candidate matching with explicit title-evidence state
 * [POS]: Candidate selection sub-module of LyricsFetcher — SearchCandidate + matching + alias resolution
 * [NOTE]: NetEase/QQ share searchAndSelectCandidate template, confirmed CJK alias probes, query-provenance gates, bounded English-title native aliases, and buildCandidates generic builder
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

    func selectBestCandidate<ID>(_ candidates: [SearchCandidate<ID>], source: String, inputTitle: String = "", inputArtist: String = "", disableCjkEscape: Bool = false, aliasConfirmedCJK: Bool = false, hasAlbumHint: Bool = false, allowNativeTitleAlias: Bool = false) -> SelectedSearchCandidate<ID>? {
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
        let hasSameArtistTitleEvidence = candidates.contains { candidate in
            candidate.titleMatch && candidate.artistMatch && !isBackingTrack(candidate)
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
                    return true
                }
                if LanguageUtils.isLikelyEnglishTitle(inputTitle),
                   !LanguageUtils.isLikelyRomanizedJapanese(inputTitle) {
                    return false
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
                guard candidate.searchDescriptor.hasPrefix("alias artist only") else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.durationDiff < 0.8 else { return false }
                return !isBackingTrack(candidate)
            }),
            ("P2d", 2, { candidate in
                guard hasAlbumHint else { return false }
                guard candidate.searchDescriptor == "artist only" else { return false }
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                guard candidate.name.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.artist.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) }) else { return false }
                guard candidate.durationDiff < 1.25 else { return false }
                return !isBackingTrack(candidate)
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
                let inputTokens = inputTitle.lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let resultTokens = LanguageUtils.normalizeTrackName(candidate.name).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                let hasTokenOverlap = inputTokens.contains { t in
                    t.count >= 3 && resultTokens.contains(where: { r in
                        r.count >= 3 && (r.contains(t) || t.contains(r))
                    })
                }
                // 🔑 Token-overlap path
                if hasTokenOverlap && candidate.durationDiff < 0.5 { return true }
                if disableCjkEscape { return false }
                // 🔑 Romanized→CJK escape
                guard LanguageUtils.isPureASCII(inputTitle) else { return false }
                let wordCount = inputTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
                let looksRomanized = wordCount >= 4 || LanguageUtils.isLikelyRomanizedJapanese(inputTitle)
                // 🔑 English title guard
                let likelyJapaneseRomaji = LanguageUtils.isLikelyRomanizedJapanese(inputTitle)
                let inputLooksEnglish = LanguageUtils.isLikelyEnglishTitle(inputTitle)
                if inputLooksEnglish && !likelyJapaneseRomaji {
                    if !(aliasConfirmedCJK && wordCount <= 3) { return false }
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
                    if wordCount <= 1 && !candidate.albumMatch && !hasSameArtistTitleEvidence {
                        return false
                    }
                    if hasAlbumHint && !candidate.albumMatch {
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
            let tierMatches = sorted.filter(predicate)
            if let best = tierMatches.sorted(by: compositeRank).first {
                tierWinners.append((label, rank, best))
            }
        }

        // If any tier produced an album-matched winner, prefer it.
        let albumMatched = tierWinners.filter { $0.candidate.albumMatch }
        let chosen: (label: String, rank: Int, candidate: SearchCandidate<ID>)?
        if !albumMatched.isEmpty {
            chosen = albumMatched.min(by: { $0.candidate.durationDiff < $1.candidate.durationDiff })
        } else {
            chosen = tierWinners.first
        }

        if let winner = chosen {
            DebugLogger.log(source, "✅ \(winner.label): '\(winner.candidate.name)' by '\(winner.candidate.artist)' alb='\(winner.candidate.album)' q='\(winner.candidate.searchDescriptor)' AL=\(winner.candidate.albumMatch) L=\(winner.candidate.normalizedNameLength) Δ\(String(format: "%.1f", winner.candidate.durationDiff))s")
            return SelectedSearchCandidate(
                id: winner.candidate.id,
                title: winner.candidate.name,
                artist: winner.candidate.artist,
                albumMatched: winner.candidate.albumMatch,
                titleMatched: winner.candidate.titleMatch || winner.candidate.albumMatch,
                nativeAliasMatched: !winner.candidate.titleMatch && (
                    (winner.rank == 1 && !winner.candidate.albumMatch)
                        || winner.label == "P2d"
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

        return cleanedInput == cleanedResult ||
               simplifiedCleanedInput == simplifiedResult ||
               (!compactInput.isEmpty && compactInput == compactResult) ||
               cleanedInput.contains(cleanedResult) || cleanedResult.contains(cleanedInput) ||
               simplifiedCleanedInput.contains(simplifiedResult) || simplifiedResult.contains(simplifiedCleanedInput)
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
        var titlePairs: [(String, String)] {
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
        var artistPairs: [(String, String)] {
            [(rawArtist, simplifiedArtist), (rawOriginalArtist, simplifiedOriginalArtist)]
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
        fetchSongs: @escaping (String) async throws -> [[String: Any]]?,
        extractSong: @escaping ([String: Any]) -> (id: ID, name: String, artist: String, duration: Double, album: String)?
    ) async -> SelectedSearchCandidate<ID>? {
        // 多关键词策略（按优先级排列）
        var keywords: [(String, String)] = [
            ("\(params.simplifiedTitle) \(params.simplifiedArtist)", "title+artist")
        ]
        for variant in Self.englishContractionVariants(params.rawTitle) {
            let normalizedVariant = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(variant))
            let kw = "\(normalizedVariant) \(params.simplifiedArtist)"
            if !keywords.contains(where: { $0.0 == kw }) {
                keywords.append((kw, "contraction+artist"))
            }
        }
        if params.simplifiedOriginalTitle != params.simplifiedTitle ||
           params.simplifiedOriginalArtist != params.simplifiedArtist {
            keywords.append(("\(params.simplifiedOriginalTitle) \(params.simplifiedOriginalArtist)", "original"))
        }
        for titleVariant in Self.titlePunctuationVariants(params.rawTitle) {
            let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(titleVariant))
            let kw = "\(simplified) \(params.simplifiedArtist)"
            if !keywords.contains(where: { $0.0 == kw }) {
                keywords.append((kw, "punctuation-title+artist"))
            }
        }
        for variant in Self.englishContractionVariants(params.rawOriginalTitle) {
            let normalizedVariant = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(variant))
            let kw = "\(normalizedVariant) \(params.simplifiedOriginalArtist)"
            if !keywords.contains(where: { $0.0 == kw }) {
                keywords.append((kw, "contraction-original"))
            }
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
            if !keywords.contains(where: { $0.0 == kw }) {
                keywords.append((kw, label))
            }
        }
        if params.artistPairs.contains(where: { LanguageUtils.containsCJK($0.0) }) {
            for raw in [params.rawTitle, params.rawOriginalTitle] {
                guard let stem = japaneseRomanizedParticleStem(raw) else { continue }
                let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(stem))
                let kw = "\(simplified) \(params.simplifiedArtist)"
                if !keywords.contains(where: { $0.0 == kw }) {
                    keywords.append((kw, "romaji-stem+artist"))
                }
            }
        }
        // 🔑 双标题拆分
        for raw in [params.rawTitle, params.rawOriginalTitle] {
            if let halves = MetadataResolver.shared.splitDualTitle(raw) {
                for (half, label) in [(halves.second, "dual-2nd"), (halves.first, "dual-1st")] {
                    let simplified = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(half))
                    let kw = "\(simplified) \(params.simplifiedArtist)"
                    if !keywords.contains(where: { $0.0 == kw }) {
                        keywords.append((kw, label))
                    }
                }
            }
        }
        // 🔑 Title-only keyword
        let titleHasCJK = LanguageUtils.containsCJK(params.rawTitle)
        let artistIsASCII = LanguageUtils.isPureASCII(params.rawArtist)
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
            for (kw, label) in albumKeywords where !keywords.contains(where: { $0.0 == kw }) {
                keywords.append((kw, label))
            }
            for (rawArtist, simplifiedArtist) in params.artistPairs {
                guard LanguageUtils.containsCJK(rawArtist)
                    || LanguageUtils.containsCJK(simplifiedArtist)
                    || LanguageUtils.isPureASCII(rawArtist) else { continue }
                let albumArtist = "\(params.normalizedAlbum) \(simplifiedArtist)"
                if !keywords.contains(where: { $0.0 == albumArtist }) {
                    keywords.append((albumArtist, "album+artist"))
                }
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

        // 🔑 Parallel keyword search — fire ALL rounds simultaneously.
        return await withTaskGroup(of: (SelectedSearchCandidate<ID>, String, Int)?.self) { group in
            // 🔑 Alias-resolved keyword
            let originalArtistIsASCII = LanguageUtils.isPureASCII(params.rawOriginalArtist)
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
                                if let m = self.selectBestCandidate(candidates, source: source, inputTitle: params.simplifiedTitle, inputArtist: params.rawArtist, disableCjkEscape: params.disableCjkEscapeInP3, aliasConfirmedCJK: true, hasAlbumHint: !params.normalizedAlbum.isEmpty, allowNativeTitleAlias: true) {
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
                            || desc.hasPrefix("romaji-stem+artist")
                        if let match = self.selectBestCandidate(candidates, source: source, inputTitle: params.simplifiedTitle, inputArtist: params.rawArtist, disableCjkEscape: params.disableCjkEscapeInP3, hasAlbumHint: !params.normalizedAlbum.isEmpty, allowNativeTitleAlias: allowNativeTitleAlias) {
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
                if r.0.matchRank == 0,
                   r.0.titleMatched,
                   r.0.durationDiff < 1.5,
                   (r.2 <= 1 || r.0.albumMatched) {
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
            // 🔑 Album match (fuzzy, contains-either-way)
            let normalizedAlbum = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(s.album)
            ).lowercased().replacingOccurrences(of: "-", with: " ")
            let albumMatch: Bool = {
                guard !params.normalizedAlbum.isEmpty, !normalizedAlbum.isEmpty else { return false }
                if params.normalizedAlbum == normalizedAlbum { return true }
                if params.normalizedAlbum.contains(normalizedAlbum) { return true }
                if normalizedAlbum.contains(params.normalizedAlbum) { return true }
                let inputLatin = LanguageUtils.toLatinLower(params.normalizedAlbum)
                let resultLatin = LanguageUtils.toLatinLower(normalizedAlbum)
                if !inputLatin.isEmpty, !resultLatin.isEmpty,
                   inputLatin.count >= 3, resultLatin.count >= 3 {
                    if inputLatin == resultLatin { return true }
                    if inputLatin.contains(resultLatin) { return true }
                    if resultLatin.contains(inputLatin) { return true }
                }
                // 🔑 Pinyin/Romaji album cross-script match
                let inputHasCJK = LanguageUtils.containsCJK(params.normalizedAlbum)
                let resultHasCJK = LanguageUtils.containsCJK(normalizedAlbum)
                if inputHasCJK != resultHasCJK {
                    guard !inputLatin.isEmpty, !resultLatin.isEmpty,
                          inputLatin.count >= 3, resultLatin.count >= 3 else { return false }
                    if inputLatin == resultLatin { return true }
                    if inputLatin.contains(resultLatin) { return true }
                    if resultLatin.contains(inputLatin) { return true }
                }
                return false
            }()

            // 🔑 Cross-script tolerance tiers
            let resultTitleIsCJK = LanguageUtils.containsCJK(s.name)
            if !artistMatch && isCrossScriptArtist && !inputHasBothScripts {
                if (albumMatch && titleMatch) ||
                   (titleMatch && durationDiff < 1.0) ||
                   (compactTitleMatch && searchDescriptor.hasPrefix("title+artist") && durationDiff < 20.0) ||
                   (!titleMatch && resultTitleIsCJK && durationDiff < 1.0) {
                    artistMatch = true
                }
            }
            if !artistMatch,
               albumMatch,
               titleMatch,
               durationDiff < 1.5,
               isCompilationArtistName(s.artist) {
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

    private func isCompilationArtistName(_ artist: String) -> Bool {
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
        var probes: [String] = [input]
        // 🔑 Multi-artist splitting
        let multiArtistSeparators = [" & ", ", ", " feat. ", " feat ", " featuring ", " Feat. ", " with ", " and ", " x ", " X "]
        for sep in multiArtistSeparators {
            if input.contains(sep) {
                let parts = input.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                for part in parts where part != input && !probes.contains(part) {
                    probes.append(part)
                }
            }
        }
        let lower = " " + input.lowercased() + " "
        let rules: [(String, String)] = [
            // HK/TW surname variants
            (" lee ", " li "),
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
        var variant = lower
        for (a, b) in rules { variant = variant.replacingOccurrences(of: a, with: b) }
        variant = variant.trimmingCharacters(in: .whitespaces)
        if variant != input.lowercased() { probes.append(variant) }
        // Also try a no-space compact form
        let compact = variant.replacingOccurrences(of: " ", with: "")
        if compact != variant && !compact.isEmpty { probes.append(compact) }
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
                            let isConfirmed = Self.isConfirmedArtistAlias(asciiArtist: inputLower, providerAliases: aliasList)
                            if isConfirmed {
                                confirmed.append(cjkName)
                            } else if allowUnconfirmedCatalogMatches,
                                      probe.lowercased() != inputLower {
                                catalog.append(cjkName)
                            }
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
