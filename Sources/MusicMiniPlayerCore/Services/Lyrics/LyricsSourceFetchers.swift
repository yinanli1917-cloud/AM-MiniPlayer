/**
 * [INPUT]: Song metadata (title, artist, duration) + SearchParams from candidate selection + LyricsSource typed registry
 * [OUTPUT]: LyricsFetchResult from each of the 8 sources (AppleMusic, AMLL, NetEase, QQ, LRCLIB, LRCLIB-Search, Genius, lyrics.ovh), stamped with typed LyricsSource cases
 * [POS]: Source fetcher sub-module of LyricsFetcher — HTTP calls + parsing for all 8 lyric sources; provider catalog aliases stay behind strict title/artist/duration/context evidence
 * [PROTOCOL]: Changes here → update this header, then check Services/Lyrics/CLAUDE.md
 */

import Foundation
import MusicKit

// ============================================================
// MARK: - Source Fetchers (extension of LyricsFetcher)
// ============================================================

extension LyricsFetcher {

    private func joinedProviderArtists(_ artists: [[String: Any]], nameKey: String = "name") -> String {
        artists.compactMap { artist in
            (artist[nameKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
    }

    private func scoreWithCatalogEvidence(
        baseScore: Double,
        lyrics: [LyricLine],
        kind: LyricsKind,
        albumMatched: Bool,
        titleMatched: Bool,
        durationDiff: Double?,
        nativeAliasMatched: Bool = false
    ) -> Double {
        guard kind != .unsynced,
              let durationDiff,
              durationDiff < 2.0 else {
            return baseScore
        }

        let realLineCount = lyrics.filter {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }.count
        guard realLineCount >= 5 else { return baseScore }

        if albumMatched && baseScore >= 20 {
            return max(baseScore, 32)
        }
        if titleMatched && durationDiff < 1.0 && baseScore >= 10 {
            return max(baseScore, 30)
        }
        if nativeAliasMatched && durationDiff < 1.5 && baseScore >= 10 {
            return max(baseScore, 35)
        }
        return baseScore
    }

    private func hasRiskyUnprovedNativeAliasTiming(_ lyrics: [LyricLine]) -> Bool {
        let firstReal = lyrics.first {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }
        guard let firstReal else { return false }
        return firstReal.startTime < 2.0
    }

    private func shouldFlagEnglishMetadataCJKDominantLyrics(
        _ lyrics: [LyricLine],
        title: String,
        artist: String,
        originalTitle: String,
        originalArtist: String,
        nativeAliasMatched: Bool
    ) -> Bool {
        guard !nativeAliasMatched else { return false }
        let visibleTitle = originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : originalTitle
        let visibleArtist = originalArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? artist : originalArtist
        guard !LanguageUtils.containsCJK(visibleTitle),
              !LanguageUtils.containsCJK(visibleArtist),
              LanguageUtils.isLikelyEnglishTitle(visibleTitle),
              looksLikeNaturalEnglishArtistPhrase(visibleArtist) else {
            return false
        }

        let realLines = lyrics
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "..." && $0 != "…" && $0 != "⋯" }
        guard realLines.count >= 8 else { return false }
        let cjkLines = realLines.filter { LanguageUtils.containsCJK($0) }.count
        return Double(cjkLines) / Double(realLines.count) >= 0.55
    }

    private func looksLikeNaturalEnglishArtistPhrase(_ artist: String) -> Bool {
        guard LanguageUtils.isPureASCII(artist),
              LanguageUtils.containsEnglishFunctionWord(artist) else {
            return false
        }
        let words = artist
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return words.count >= 2
    }

    func fetchAlbumTitleEchoNativeNetEase(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        guard !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              LanguageUtils.isPureASCII(title),
              LanguageUtils.isPureASCII(artist),
              LanguageUtils.isLikelyEnglishTitle(title),
              isAlbumTitleEchoNativeAliasProbeInput(title: title, album: album) else {
            return nil
        }
        let cjkArtists = await resolveArtistCJKAliases(
            asciiArtist: artist,
            allowUnconfirmedCatalogMatches: true
        )
        guard let cjkArtist = cjkArtists.first else { return nil }
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            "Referer": "https://music.163.com"
        ]
        guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
            "s": cjkArtist, "type": "1", "limit": "30"
        ]) else { return nil }
        guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 1.4, retry: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return nil
        }

        struct EchoCandidate {
            let id: Int
            let name: String
            let artist: String
            let durationDiff: Double
            let resultIndex: Int
        }

        let candidates = songs.prefix(30).enumerated().compactMap { index, song -> EchoCandidate? in
            guard let id = song["id"] as? Int,
                  let name = song["name"] as? String,
                  let albumName = (song["album"] as? [String: Any])?["name"] as? String,
                  let artists = song["artists"] as? [[String: Any]],
                  let durMS = song["duration"] as? Double else { return nil }
            let artistName = joinedProviderArtists(artists)
            guard isArtistMatch(
                input: cjkArtist,
                result: artistName,
                simplifiedInput: LanguageUtils.toSimplifiedChinese(cjkArtist)
            ) else { return nil }
            let normalizedTitle = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(name))
            let normalizedAlbum = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(albumName))
            guard !normalizedTitle.isEmpty,
                  normalizedTitle == normalizedAlbum else { return nil }
            let cjkCount = normalizedTitle.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count
            guard cjkCount >= 2, cjkCount <= 14 else { return nil }
            let lower = normalizedTitle.lowercased()
            let disallowedMarkers = [
                "live", "dj", "remix", "cover", "instrumental", "伴奏",
                "翻唱", "翻自", "翻奏", "现场", "現場", "演唱会", "演唱會",
                "纯音乐", "純音樂", "カラオケ"
            ]
            guard !disallowedMarkers.contains(where: { lower.contains($0) }) else { return nil }
            let delta = abs((durMS / 1000.0) - duration)
            guard delta < 1.5 else { return nil }
            return EchoCandidate(
                id: id,
                name: name,
                artist: artistName,
                durationDiff: delta,
                resultIndex: index
            )
        }
        .sorted {
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        guard let candidate = candidates.first,
              let fetched = await fetchNetEaseLyrics(
                songId: candidate.id,
                duration: duration,
                expectedTitle: candidate.name,
                expectedArtist: candidate.artist
              ) else {
            return nil
        }
        let lyrics = removingLeadingCatalogCreditLines(
            fetched.lyrics,
            title: candidate.name,
            artist: candidate.artist
        )
        guard fetched.kind == .synced,
              lyrics.count >= 8 else { return nil }
        let rawScore = scorer.calculateScore(
            lyrics,
            source: .netEase,
            duration: duration,
            translationEnabled: translationEnabled,
            kind: fetched.kind
        )
        let score = scoreWithCatalogEvidence(
            baseScore: rawScore,
            lyrics: lyrics,
            kind: fetched.kind,
            albumMatched: true,
            titleMatched: false,
            durationDiff: candidate.durationDiff,
            nativeAliasMatched: true
        )
        DebugLogger.log("NetEase", "✅ album-title echo native hit: '\(candidate.name)' by '\(candidate.artist)' Δ\(String(format: "%.1f", candidate.durationDiff))s")
        return LyricsFetchResult(
            lyrics: lyrics,
            source: .netEase,
            score: score,
            kind: fetched.kind,
            albumMatched: true,
            titleMatched: false,
            matchedDurationDiff: candidate.durationDiff,
            nativeAliasMatched: true
        )
    }

    func fetchNativeArtistAliasNetEaseDirect(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        guard LanguageUtils.isPureASCII(title),
              LanguageUtils.isPureASCII(artist),
              !LanguageUtils.isLikelyEnglishTitle(title) else {
            return nil
        }
        let cjkArtists = await resolveArtistCJKAliases(
            asciiArtist: artist,
            allowUnconfirmedCatalogMatches: false
        )
        guard let cjkArtist = cjkArtists.first else { return nil }
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            "Referer": "https://music.163.com"
        ]
        guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
            "s": cjkArtist, "type": "1", "limit": "24"
        ]) else { return nil }
        guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 1.35, retry: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return nil
        }

        let aliasParams = SearchParams(
            title: title,
            artist: cjkArtist,
            originalTitle: title,
            originalArtist: artist,
            duration: duration,
            album: album
        )
        let candidates: [SearchCandidate<Int>] = buildCandidates(
            songs: songs,
            params: aliasParams,
            searchDescriptor: "alias artist only:\(cjkArtist)",
            extractSong: { song in
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let albumName = (song["album"] as? [String: Any])?["name"] as? String,
                      let artists = song["artists"] as? [[String: Any]],
                      let durMS = song["duration"] as? Double else {
                    return nil
                }
                return (id, name, self.joinedProviderArtists(artists), durMS / 1000.0, albumName)
            }
        )
        guard let match = selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: aliasParams.simplifiedTitle,
            inputArtist: artist,
            aliasConfirmedCJK: true,
            hasAlbumHint: !aliasParams.normalizedAlbum.isEmpty,
            allowNativeTitleAlias: true
        ), match.titleMatched,
           match.durationDiff < 1.5,
           match.title.unicodeScalars.contains(where: { LanguageUtils.isCJKScalar($0) || LanguageUtils.isJapaneseKana($0) }),
           let fetched = await fetchNetEaseLyrics(
                songId: match.id,
                duration: duration,
                expectedTitle: match.title,
                expectedArtist: match.artist
           ) else {
            return nil
        }
        let lyrics = removingLeadingCatalogCreditLines(
            fetched.lyrics,
            title: match.title,
            artist: match.artist
        )
        guard fetched.kind == .synced,
              lyrics.count >= 8 else { return nil }
        let rawScore = scorer.calculateScore(
            lyrics,
            source: .netEase,
            duration: duration,
            translationEnabled: translationEnabled,
            kind: fetched.kind
        )
        let score = scoreWithCatalogEvidence(
            baseScore: rawScore,
            lyrics: lyrics,
            kind: fetched.kind,
            albumMatched: match.albumMatched,
            titleMatched: match.titleMatched,
            durationDiff: match.durationDiff,
            nativeAliasMatched: true
        )
        DebugLogger.log("NetEase", "✅ native artist alias direct hit: '\(match.title)' by '\(match.artist)' Δ\(String(format: "%.1f", match.durationDiff))s")
        return LyricsFetchResult(
            lyrics: lyrics,
            source: .netEase,
            score: score,
            kind: fetched.kind,
            albumMatched: match.albumMatched,
            titleMatched: match.titleMatched,
            matchedDurationDiff: match.durationDiff,
            nativeAliasMatched: true
        )
    }

    private func isSuspiciousCompressedLineTiming(_ result: LyricsFetchResult, duration: TimeInterval) -> Bool {
        guard duration >= 180,
              result.kind == .synced,
              result.score < 65,
              !result.lyrics.isEmpty else { return false }

        let syllableCount = result.lyrics.filter { $0.hasSyllableSync }.count
        if Double(syllableCount) / Double(result.lyrics.count) >= 0.3 {
            return false
        }

        let realLines = result.lyrics.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }
        guard let firstReal = realLines.first,
              let lastStart = result.lyrics.last?.startTime else { return false }

        let firstText = firstReal.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let startsWithCatalogMarker = firstText.contains("******") || firstText.localizedCaseInsensitiveContains("music")
        let startsTooEarly = firstReal.startTime < 4.0
        let tailGap = duration - lastStart
        let leavesLargeTail = tailGap > max(42.0, duration * 0.20)
        return leavesLargeTail && (startsTooEarly || startsWithCatalogMarker)
    }

    private func realLyricLines(_ lyrics: [LyricLine]) -> [LyricLine] {
        lyrics.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "..." && text != "…" && text != "⋯"
        }
    }

    private func hasSyllableSync(_ result: LyricsFetchResult) -> Bool {
        result.lyrics.contains(where: { $0.hasSyllableSync })
    }

    private func hasCJKLyricOrMetadataContext(params: SearchParams, lyrics: [LyricLine]) -> Bool {
        LanguageUtils.containsCJK(params.rawTitle)
            || LanguageUtils.containsCJK(params.rawOriginalTitle)
            || LanguageUtils.containsCJK(params.normalizedAlbum)
            || lyrics.contains(where: { LanguageUtils.containsCJK($0.text) })
    }

    private func looksLikeOpeningCatalogCreditLine(_ result: LyricsFetchResult) -> Bool {
        guard let firstReal = realLyricLines(result.lyrics).first,
              firstReal.startTime <= 45.0 else {
            return false
        }
        let simplified = LanguageUtils.toSimplifiedChinese(firstReal.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard simplified.count <= 32 else { return false }
        let creditKeywords = [
            "作词", "作曲", "编曲", "制作", "制作人", "监制", "混音", "录音",
            "母带", "母帶", "后期", "後期", "企划", "企劃", "出品", "发行",
            "發行", "统筹", "統籌", "producer", "mix", "master", "record"
        ]
        guard creditKeywords.contains(where: { simplified.contains($0) }) else {
            return false
        }
        let hasCreditSeparator = simplified.contains(":")
            || simplified.contains("：")
            || simplified.contains(";")
            || simplified.contains("；")
            || simplified.contains("@")
        return hasCreditSeparator || simplified.count <= 12
    }

    private func shouldProbeNetEaseAuthoritativeSibling(
        primary: LyricsFetchResult,
        params: SearchParams,
        match: SelectedSearchCandidate<Int>,
        duration: TimeInterval
    ) -> Bool {
        guard primary.kind == .synced,
              !hasSyllableSync(primary),
              match.durationDiff < 3.0,
              match.albumMatched || match.titleMatched || match.nativeAliasMatched,
              hasCJKLyricOrMetadataContext(params: params, lyrics: primary.lyrics) else {
            return false
        }

        if match.albumMatched && !params.normalizedAlbum.isEmpty {
            return true
        }
        if looksLikeOpeningCatalogCreditLine(primary) {
            return true
        }
        return false
    }

    private func isGenericSingleAlbumEcho(params: SearchParams) -> Bool {
        let album = params.normalizedAlbum
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        guard !album.isEmpty else { return false }
        let titleKeys = [
            params.simplifiedTitle,
            params.simplifiedOriginalTitle,
            LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(params.rawTitle)),
            LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(params.rawOriginalTitle))
        ]
        .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let genericTokens: Set<String> = ["single", "ep", "单曲", "單曲", "singles"]
        for title in titleKeys where album.contains(title) {
            let remainder = album
                .replacingOccurrences(of: title, with: " ")
                .split { !$0.isLetter && !$0.isNumber }
                .map { String($0).lowercased() }
            if !remainder.isEmpty && remainder.allSatisfy({ genericTokens.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func shouldProbeNetEaseCanonicalWordLevelSibling(
        primary: LyricsFetchResult,
        params: SearchParams,
        match: SelectedSearchCandidate<Int>
    ) -> Bool {
        guard primary.kind == .synced,
              hasSyllableSync(primary),
              match.albumMatched,
              match.durationDiff < 3.0,
              hasCJKLyricOrMetadataContext(params: params, lyrics: primary.lyrics) else {
            return false
        }
        return isGenericSingleAlbumEcho(params: params) || match.durationDiff >= 1.5
    }

    private func shouldPreferNetEaseAuthoritativeSibling(
        _ sibling: LyricsFetchResult,
        over primary: LyricsFetchResult,
        duration: TimeInterval
    ) -> Bool {
        let siblingHasSyllableSync = hasSyllableSync(sibling)
        let primaryHasSyllableSync = hasSyllableSync(primary)
        guard sibling.kind == .synced,
              siblingHasSyllableSync,
              sibling.score >= 35,
              !isSuspiciousCompressedLineTiming(sibling, duration: duration) else {
            return false
        }

        let primaryRealCount = realLyricLines(primary.lyrics).count
        let siblingRealCount = realLyricLines(sibling.lyrics).count
        if primaryHasSyllableSync {
            guard hasCJKLyricOverlap(primary.lyrics, sibling.lyrics) else { return false }
            let primaryDurationDiff = primary.matchedDurationDiff ?? .greatestFiniteMagnitude
            let siblingDurationDiff = sibling.matchedDurationDiff ?? .greatestFiniteMagnitude
            if sibling.score >= primary.score - 8,
               siblingDurationDiff + 0.25 < primaryDurationDiff {
                return true
            }
            if primaryRealCount >= siblingRealCount + 3,
               sibling.score >= primary.score - 3,
               siblingDurationDiff <= primaryDurationDiff + 0.5 {
                return true
            }
            return false
        }

        if sibling.score >= primary.score - 12 {
            return true
        }
        if siblingRealCount >= primaryRealCount {
            return true
        }
        return looksLikeOpeningCatalogCreditLine(primary)
    }

    func shouldPreferNetEaseAuthoritativeSiblingForTesting(
        sibling: LyricsFetchResult,
        primary: LyricsFetchResult,
        duration: TimeInterval
    ) -> Bool {
        shouldPreferNetEaseAuthoritativeSibling(sibling, over: primary, duration: duration)
    }

    func shouldProbeNetEaseAuthoritativeSiblingForTesting(
        primary: LyricsFetchResult,
        title: String,
        artist: String,
        duration: TimeInterval,
        album: String = "",
        albumMatched: Bool = false,
        titleMatched: Bool = true,
        nativeAliasMatched: Bool = false,
        durationDiff: Double = 0.2
    ) -> Bool {
        let params = SearchParams(
            title: title,
            artist: artist,
            originalTitle: title,
            originalArtist: artist,
            duration: duration,
            album: album
        )
        let match = SelectedSearchCandidate<Int>(
            id: 0,
            title: title,
            artist: artist,
            albumMatched: albumMatched,
            titleMatched: titleMatched,
            nativeAliasMatched: nativeAliasMatched,
            durationDiff: durationDiff,
            matchRank: 0
        )
        return shouldProbeNetEaseAuthoritativeSibling(
            primary: primary,
            params: params,
            match: match,
            duration: duration
        )
    }

    private struct NetEaseSiblingQualityCandidate: Sendable {
        let id: Int
        let name: String
        let artist: String
        let durationDiff: Double
        let keywordPriority: Int
        let resultIndex: Int
    }

    private struct NetEaseCompilationAlbumCandidate: Sendable {
        let id: Int
        let name: String
        let artist: String
        let album: String
        let durationDiff: Double
        let keywordPriority: Int
        let resultIndex: Int
    }

    func shouldForegroundNetEaseCatalogExactTitleDiscovery(
        title: String,
        artist: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        album: String
    ) -> Bool {
        let params = SearchParams(
            title: title,
            artist: artist,
            originalTitle: originalTitle,
            originalArtist: originalArtist,
            duration: duration,
            album: album
        )
        return shouldForegroundNetEaseCatalogExactTitleDiscovery(params: params)
    }

    func shouldForegroundNetEaseCatalogExactTitleDiscovery(params: SearchParams) -> Bool {
        guard !params.normalizedAlbum.isEmpty else { return false }
        guard !isCompilationArtistName(params.rawArtist),
              !isCompilationArtistName(params.rawOriginalArtist) else { return false }
        guard LanguageUtils.isPureASCII(params.rawTitle),
              LanguageUtils.isPureASCII(params.rawArtist),
              LanguageUtils.isPureASCII(params.rawOriginalArtist),
              LanguageUtils.isLikelyEnglishTitle(params.rawTitle) else {
            return false
        }
        guard latinEvidenceKey(params.rawTitle) != latinEvidenceKey(params.normalizedAlbum) else {
            return false
        }
        return isDistinctiveCatalogExactTitleInput(params)
    }

    func fetchForegroundNetEaseCatalogExactTitleDiscovery(
        title: String,
        artist: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        let params = SearchParams(
            title: title,
            artist: artist,
            originalTitle: originalTitle,
            originalArtist: originalArtist,
            duration: duration,
            album: album
        )
        guard shouldForegroundNetEaseCatalogExactTitleDiscovery(params: params) else { return nil }

        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            "Referer": "https://music.163.com"
        ]
        let candidates = await discoverNetEaseCompilationAlbumCandidates(
            params: params,
            headers: headers,
            duration: duration,
            returnOnFirstSafeBatch: true
        )
        return await fetchBestNetEaseCompilationAlbumResult(
            candidates: candidates,
            duration: duration,
            translationEnabled: translationEnabled,
            logLabel: "foreground catalog exact-title discovery"
        )
    }

    private func fetchNetEaseSiblingQualityFallback(
        params: SearchParams,
        headers: [String: String],
        duration: TimeInterval,
        translationEnabled: Bool,
        excludingSongID: Int?,
        catalogTitle: String? = nil,
        catalogArtist: String? = nil,
        skipAliasResolution: Bool = false
    ) async -> LyricsFetchResult? {
        var artistEvidence = params.artistPairs.map(\.0)
        if let catalogArtist {
            artistEvidence.insert(catalogArtist, at: 0)
        }
        if !skipAliasResolution, LanguageUtils.isPureASCII(params.rawArtist) {
            artistEvidence.append(contentsOf: await resolveArtistCJKAliases(
                asciiArtist: params.rawArtist,
                allowUnconfirmedCatalogMatches: true
            ))
        }
        if params.rawOriginalArtist != params.rawArtist,
           !skipAliasResolution,
           LanguageUtils.isPureASCII(params.rawOriginalArtist) {
            artistEvidence.append(contentsOf: await resolveArtistCJKAliases(
                asciiArtist: params.rawOriginalArtist,
                allowUnconfirmedCatalogMatches: true
            ))
        }
        artistEvidence = Array(Set(artistEvidence.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })).filter { !$0.isEmpty }

        let titleVariants = Array(Set([
            catalogTitle ?? "",
            params.rawTitle,
            params.rawOriginalTitle,
            params.simplifiedTitle,
            params.simplifiedOriginalTitle,
            LanguageUtils.toTraditionalChinese(params.rawTitle),
            LanguageUtils.toTraditionalChinese(params.rawOriginalTitle)
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).filter { !$0.isEmpty }

        var keywordPairs: [(String, Int)] = []
        func addKeyword(_ keyword: String, priority: Int) {
            let clean = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !keywordPairs.contains(where: { $0.0 == clean }) else { return }
            keywordPairs.append((clean, priority))
        }
        if let catalogTitle,
           let catalogArtist,
           !catalogTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !catalogArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addKeyword("\(catalogTitle) \(catalogArtist)", priority: -1)
            addKeyword("\(LanguageUtils.toSimplifiedChinese(catalogTitle)) \(catalogArtist)", priority: -1)
        }
        addKeyword("\(params.rawTitle) \(params.rawArtist)", priority: 0)
        addKeyword("\(params.simplifiedTitle) \(params.rawArtist)", priority: 0)
        addKeyword("\(LanguageUtils.toTraditionalChinese(params.rawTitle)) \(params.rawArtist)", priority: 1)
        for alias in artistEvidence where LanguageUtils.containsCJK(alias) {
            addKeyword("\(params.simplifiedTitle) \(alias)", priority: 1)
            addKeyword("\(LanguageUtils.toTraditionalChinese(params.rawTitle)) \(alias)", priority: 1)
        }
        addKeyword(params.simplifiedTitle, priority: 2)

        var candidatesByID: [Int: NetEaseSiblingQualityCandidate] = [:]
        await withTaskGroup(of: [NetEaseSiblingQualityCandidate].self) { group in
            for (keyword, priority) in keywordPairs.prefix(6) {
                group.addTask {
                    guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                        "s": keyword, "type": "1", "limit": "20"
                    ]) else { return [] }
                    guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = json["result"] as? [String: Any],
                          let songs = result["songs"] as? [[String: Any]] else { return [] }
                    return songs.enumerated().compactMap { index, song -> NetEaseSiblingQualityCandidate? in
                        guard let id = song["id"] as? Int,
                              id != excludingSongID,
                              let name = song["name"] as? String,
                              let durMS = song["duration"] as? Double else { return nil }
                        let artistName = (song["artists"] as? [[String: Any]]).map { self.joinedProviderArtists($0) } ?? ""
                        let delta = abs((durMS / 1000.0) - duration)
                        guard delta < 5.0 else { return nil }
                        let titleOK = titleVariants.contains { title in
                            self.isTitleMatch(input: title, result: name, simplifiedInput: LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(title)))
                        }
                        guard titleOK else { return nil }
                        let artistOK = artistEvidence.contains { artist in
                            self.isArtistMatch(
                                input: artist,
                                result: artistName,
                                simplifiedInput: LanguageUtils.toSimplifiedChinese(artist)
                            )
                        }
                        guard artistOK else { return nil }
                        let lowerName = name.lowercased()
                        let looksBackingTrack = lowerName.contains("karaoke")
                            || lowerName.contains("instrumental")
                            || lowerName.contains("伴奏")
                            || lowerName.contains("オリジナル・カラオケ")
                        guard !looksBackingTrack else { return nil }
                        return NetEaseSiblingQualityCandidate(
                            id: id,
                            name: name,
                            artist: artistName,
                            durationDiff: delta,
                            keywordPriority: priority,
                            resultIndex: index
                        )
                    }
                }
            }
            for await batch in group {
                for candidate in batch {
                    if let existing = candidatesByID[candidate.id] {
                        if existing.keywordPriority < candidate.keywordPriority { continue }
                        if existing.keywordPriority == candidate.keywordPriority,
                           existing.resultIndex <= candidate.resultIndex { continue }
                    }
                    candidatesByID[candidate.id] = candidate
                }
            }
        }

        let candidates = candidatesByID.values.sorted {
            if $0.keywordPriority != $1.keywordPriority { return $0.keywordPriority < $1.keywordPriority }
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        guard !candidates.isEmpty else { return nil }
        DebugLogger.log("NetEase", "🔁 sibling quality fallback: \(candidates.prefix(5).map { "'\($0.name)' by '\($0.artist)' Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", "))")

        var scoredResults: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            for candidate in candidates.prefix(8) {
                group.addTask {
                    guard let fetched = await self.fetchNetEaseLyrics(
                        songId: candidate.id,
                        duration: duration,
                        expectedTitle: candidate.name,
                        expectedArtist: candidate.artist
                    ), !fetched.lyrics.isEmpty, fetched.lyrics.count >= 5 else {
                        return nil
                    }
                    let candidateLyrics = self.removingLeadingCatalogCreditLines(
                        fetched.lyrics,
                        title: candidate.name,
                        artist: candidate.artist
                    )
                    let rawScore = self.scorer.calculateScore(
                        candidateLyrics,
                        source: .netEase,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        kind: fetched.kind
                    )
                    let score = self.scoreWithCatalogEvidence(
                        baseScore: rawScore,
                        lyrics: candidateLyrics,
                        kind: fetched.kind,
                        albumMatched: false,
                        titleMatched: true,
                        durationDiff: candidate.durationDiff
                    )
                    let result = LyricsFetchResult(
                        lyrics: candidateLyrics,
                        source: .netEase,
                        score: score,
                        kind: fetched.kind,
                        albumMatched: false,
                        titleMatched: true,
                        matchedDurationDiff: candidate.durationDiff,
                        nativeAliasMatched: true
                    )
                    guard !self.isSuspiciousCompressedLineTiming(result, duration: duration) else { return nil }
                    return result
                }
            }
            for await result in group {
                if let result, result.kind == .synced, result.score >= 35 {
                    scoredResults.append(result)
                }
            }
        }

        guard let best = scoredResults.sorted(by: { lhs, rhs in
            if lhs.lyrics.contains(where: { $0.hasSyllableSync }) != rhs.lyrics.contains(where: { $0.hasSyllableSync }) {
                return lhs.lyrics.contains(where: { $0.hasSyllableSync })
            }
            return lhs.score > rhs.score
        }).first else { return nil }
        DebugLogger.log("NetEase", "✅ sibling quality fallback hit: score=\(String(format: "%.1f", best.score)) lines=\(best.lyrics.count)")
        return best
    }

    private func fetchNetEaseCompilationAlbumFallback(
        params: SearchParams,
        headers: [String: String],
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> LyricsFetchResult? {
        guard !params.normalizedAlbum.isEmpty else { return nil }

        var artistEvidence = params.artistPairs.map(\.0)
        if LanguageUtils.isPureASCII(params.rawArtist) {
            artistEvidence.append(contentsOf: await resolveArtistCJKAliases(
                asciiArtist: params.rawArtist,
                allowUnconfirmedCatalogMatches: true
            ))
        }
        if params.rawOriginalArtist != params.rawArtist,
           LanguageUtils.isPureASCII(params.rawOriginalArtist) {
            artistEvidence.append(contentsOf: await resolveArtistCJKAliases(
                asciiArtist: params.rawOriginalArtist,
                allowUnconfirmedCatalogMatches: true
            ))
        }
        artistEvidence = Array(Set(artistEvidence.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })).filter { !$0.isEmpty }

        let albumVariants = Array(Set([
            params.normalizedAlbum,
            LanguageUtils.toTraditionalChinese(params.normalizedAlbum)
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }
        let titleVariants = Array(Set([
            params.simplifiedTitle,
            params.simplifiedOriginalTitle,
            params.rawTitle,
            params.rawOriginalTitle
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }

        var keywordPairs: [(String, String, Int)] = []
        func addKeyword(_ keyword: String, descriptor: String, priority: Int) {
            let clean = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty,
                  !keywordPairs.contains(where: { $0.0 == clean && $0.1 == descriptor }) else { return }
            keywordPairs.append((clean, descriptor, priority))
        }

        for album in albumVariants {
            for artist in artistEvidence {
                addKeyword("\(album) \(artist)", descriptor: "compilation album+artist", priority: LanguageUtils.containsCJK(artist) ? 0 : 1)
            }
            for title in titleVariants.prefix(3) {
                addKeyword("\(title) \(album)", descriptor: "compilation title+album", priority: 2)
                for artist in artistEvidence.prefix(4) {
                    addKeyword("\(title) \(album) \(artist)", descriptor: "compilation title+album+artist", priority: 3)
                }
            }
        }

        var candidatesByID: [Int: NetEaseCompilationAlbumCandidate] = [:]
        await withTaskGroup(of: [NetEaseCompilationAlbumCandidate].self) { group in
            for (keyword, descriptor, priority) in keywordPairs.prefix(10) {
                group.addTask {
                    guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                        "s": keyword, "type": "1", "limit": "30"
                    ]) else { return [] }
                    guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = json["result"] as? [String: Any],
                          let songs = result["songs"] as? [[String: Any]] else { return [] }

                    return songs.enumerated().compactMap { index, song -> NetEaseCompilationAlbumCandidate? in
                        guard let id = song["id"] as? Int,
                              let name = song["name"] as? String,
                              let durMS = song["duration"] as? Double else { return nil }
                        let artistName = (song["artists"] as? [[String: Any]]).map { self.joinedProviderArtists($0) } ?? ""
                        var albumName = ""
                        if let album = song["album"] as? [String: Any] {
                            var albumParts: [String] = []
                            if let n = album["name"] as? String { albumParts.append(n) }
                            if let aliases = album["alia"] as? [String] { albumParts.append(contentsOf: aliases) }
                            albumName = albumParts.joined(separator: " ")
                        }
                        let songDuration = durMS / 1000.0
                        guard self.isSafeCompilationAlbumFallbackCandidate(
                            params: params,
                            candidateTitle: name,
                            candidateArtist: artistName,
                            candidateAlbum: albumName,
                            candidateDuration: songDuration,
                            resultIndex: index,
                            searchDescriptor: descriptor
                        ) else { return nil }
                        return NetEaseCompilationAlbumCandidate(
                            id: id,
                            name: name,
                            artist: artistName,
                            album: albumName,
                            durationDiff: abs(songDuration - duration),
                            keywordPriority: priority,
                            resultIndex: index
                        )
                    }
                }
            }

            for await batch in group {
                for candidate in batch {
                    if let existing = candidatesByID[candidate.id] {
                        if existing.keywordPriority < candidate.keywordPriority { continue }
                        if existing.keywordPriority == candidate.keywordPriority,
                           existing.resultIndex <= candidate.resultIndex { continue }
                    }
                    candidatesByID[candidate.id] = candidate
                }
            }
        }

        if candidatesByID.isEmpty {
            let discovered = await discoverNetEaseCompilationAlbumCandidates(
                params: params,
                headers: headers,
                duration: duration
            )
            for candidate in discovered {
                candidatesByID[candidate.id] = candidate
            }
        }

        let candidates = candidatesByID.values.sorted {
            if $0.keywordPriority != $1.keywordPriority { return $0.keywordPriority < $1.keywordPriority }
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        return await fetchBestNetEaseCompilationAlbumResult(
            candidates: candidates,
            duration: duration,
            translationEnabled: translationEnabled,
            logLabel: "compilation album fallback"
        )
    }

    private func fetchBestNetEaseCompilationAlbumResult(
        candidates: [NetEaseCompilationAlbumCandidate],
        duration: TimeInterval,
        translationEnabled: Bool,
        logLabel: String = "compilation album fallback"
    ) async -> LyricsFetchResult? {
        let candidates = candidates.sorted {
            if $0.keywordPriority != $1.keywordPriority { return $0.keywordPriority < $1.keywordPriority }
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        guard !candidates.isEmpty else { return nil }
        DebugLogger.log("NetEase", "🔁 \(logLabel): \(candidates.prefix(5).map { "'\($0.name)' by '\($0.artist)' alb='\($0.album)' Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", "))")
        var scoredResults: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            for candidate in candidates.prefix(3) {
                group.addTask {
                    guard let fetched = await self.fetchNetEaseLyrics(
                        songId: candidate.id,
                        duration: duration,
                        expectedTitle: candidate.name,
                        expectedArtist: candidate.artist
                    ), !fetched.lyrics.isEmpty, fetched.lyrics.count >= 8 else {
                        return nil
                    }
                    let candidateLyrics = self.removingLeadingCatalogCreditLines(
                        fetched.lyrics,
                        title: candidate.name,
                        artist: candidate.artist
                    )
                    guard candidateLyrics.count >= 8 else { return nil }
                    let rawScore = self.scorer.calculateScore(
                        candidateLyrics,
                        source: .netEase,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        kind: fetched.kind
                    )
                    var score = self.scoreWithCatalogEvidence(
                        baseScore: rawScore,
                        lyrics: candidateLyrics,
                        kind: fetched.kind,
                        albumMatched: true,
                        titleMatched: true,
                        durationDiff: candidate.durationDiff
                    )
                    if fetched.kind == .synced {
                        score = max(score, 45)
                    }
                    let result = LyricsFetchResult(
                        lyrics: candidateLyrics,
                        source: .netEase,
                        score: score,
                        kind: fetched.kind,
                        albumMatched: true,
                        titleMatched: true,
                        matchedDurationDiff: candidate.durationDiff
                    )
                    guard !self.isSuspiciousCompressedLineTiming(result, duration: duration) else { return nil }
                    return result
                }
            }
            for await result in group {
                if let result, result.kind == .synced, result.score >= 35 {
                    scoredResults.append(result)
                }
            }
        }

        guard let best = scoredResults.sorted(by: { lhs, rhs in
            if lhs.lyrics.count != rhs.lyrics.count { return lhs.lyrics.count > rhs.lyrics.count }
            return lhs.score > rhs.score
        }).first else { return nil }
        DebugLogger.log("NetEase", "✅ \(logLabel) hit: score=\(String(format: "%.1f", best.score)) lines=\(best.lyrics.count)")
        return best
    }

    private func discoverNetEaseCompilationAlbumCandidates(
        params: SearchParams,
        headers: [String: String],
        duration: TimeInterval,
        returnOnFirstSafeBatch: Bool = false
    ) async -> [NetEaseCompilationAlbumCandidate] {
        guard !params.normalizedAlbum.isEmpty else { return [] }

        let titleQueries = netEaseCompilationAlbumDiscoveryQueries(params: params)

        var candidatesByID: [Int: NetEaseCompilationAlbumCandidate] = [:]
        await withTaskGroup(of: [NetEaseCompilationAlbumCandidate].self) { group in
            for query in titleQueries.prefix(8) {
                group.addTask {
                    let searchLimit = query.contains("群星") ? "20" : "100"
                    guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                        "s": query, "type": "1", "limit": searchLimit
                    ]) else { return [] }
                    guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let result = json["result"] as? [String: Any],
                          let songs = result["songs"] as? [[String: Any]] else { return [] }

                    return songs.enumerated().compactMap { index, song -> NetEaseCompilationAlbumCandidate? in
                        guard let id = song["id"] as? Int,
                              let name = song["name"] as? String,
                              let durMS = song["duration"] as? Double else { return nil }
                        let artistName = (song["artists"] as? [[String: Any]]).map { self.joinedProviderArtists($0) } ?? ""
                        var albumName = ""
                        if let album = song["album"] as? [String: Any] {
                            var albumParts: [String] = []
                            if let n = album["name"] as? String { albumParts.append(n) }
                            if let aliases = album["alia"] as? [String] { albumParts.append(contentsOf: aliases) }
                            albumName = albumParts.joined(separator: " ")
                        }
                        let songDuration = durMS / 1000.0
                        guard self.isSafeCompilationAlbumDiscoveryCandidate(
                            params: params,
                            candidateTitle: name,
                            candidateArtist: artistName,
                            candidateAlbum: albumName,
                            candidateDuration: songDuration,
                            resultIndex: index
                        ) else { return nil }
                        return NetEaseCompilationAlbumCandidate(
                            id: id,
                            name: name,
                            artist: artistName,
                            album: albumName,
                            durationDiff: abs(songDuration - duration),
                            keywordPriority: 4,
                            resultIndex: index
                        )
                    }
                }
            }

            for await batch in group {
                for candidate in batch {
                    if let existing = candidatesByID[candidate.id],
                       existing.resultIndex <= candidate.resultIndex {
                        continue
                    }
                    candidatesByID[candidate.id] = candidate
                }
                if returnOnFirstSafeBatch && !batch.isEmpty {
                    group.cancelAll()
                    break
                }
            }
        }

        let candidates = candidatesByID.values.sorted {
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        if !candidates.isEmpty {
            DebugLogger.log("NetEase", "🔎 native compilation album discovery: \(candidates.prefix(5).map { "'\($0.name)' by '\($0.artist)' alb='\($0.album)' Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", "))")
        }
        return candidates
    }

    func netEaseCompilationAlbumDiscoveryQueriesForTesting(params: SearchParams) -> [String] {
        netEaseCompilationAlbumDiscoveryQueries(params: params)
    }

    private func netEaseCompilationAlbumDiscoveryQueries(params: SearchParams) -> [String] {
        var queries: [String] = []
        func add(_ value: String) {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty,
                  !queries.contains(clean) else { return }
            queries.append(clean)
        }

        add(params.rawTitle)
        add(params.rawOriginalTitle)
        add(params.simplifiedTitle)
        add(params.simplifiedOriginalTitle)

        let exactTitleQueries = queries
        for title in exactTitleQueries {
            add("\(title) 华语群星")
            add("\(title) 華語群星")
            add("\(title) 群星")
        }
        return queries
    }

    private func hasCJKLyricOverlap(_ lhs: [LyricLine], _ rhs: [LyricLine]) -> Bool {
        func grams(_ lines: [LyricLine]) -> Set<String> {
            let compact = lines.prefix(24).map(\.text).joined()
                .unicodeScalars
                .filter { LanguageUtils.isCJKScalar($0) }
                .map(String.init)
                .joined()
            let chars = Array(compact)
            guard chars.count >= 4 else { return [] }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let a = grams(lhs)
        let b = grams(rhs)
        guard min(a.count, b.count) >= 4 else { return false }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count)) >= 0.12
    }

    private func removingLeadingCatalogCreditLines(_ lyrics: [LyricLine], title: String, artist: String) -> [LyricLine] {
        let titleKey = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(title)).lowercased()
        let artistKey = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeArtistName(artist)).lowercased()
        var result = lyrics
        var removed = 0
        while removed < 2, let first = result.first, first.startTime < 8.0 {
            let textKey = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(first.text)).lowercased()
            guard textKey == titleKey || textKey == artistKey else { break }
            result.removeFirst()
            removed += 1
        }
        return result
    }

    private func catalogUnavailableResult(
        source: LyricsSource,
        albumMatched: Bool,
        titleMatched: Bool,
        durationDiff: Double?
    ) -> LyricsFetchResult {
        LyricsFetchResult(
            lyrics: [],
            source: source,
            score: -80,
            kind: .unavailable,
            albumMatched: albumMatched,
            titleMatched: titleMatched,
            matchedDurationDiff: durationDiff
        )
    }

    // MARK: - AMLL-TTML-DB

    func fetchFromAMLL(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        // 尝试通过 Apple Music Track ID 直接获取
        if let trackId = await getAppleMusicTrackId(title: title, artist: artist, duration: duration),
           let lyrics = await fetchAMLLTTML(platform: "am-lyrics", filename: "\(trackId).ttml") {
            let score = scorer.calculateScore(lyrics, source: .amll, duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: .amll, score: score, kind: .synced)
        }

        // 🔑 检查是否在冷却期内
        if let lastFail = amllIndexLoadFailed,
           Date().timeIntervalSince(lastFail) < amllIndexFailureCooldown {
            return nil
        }

        // Index search is useful when warm, but the bulk JSONL load must not
        // block playback. Warm it in the background and let other sources race.
        if amllIndex.isEmpty {
            Task { await loadAMLLIndex() }
            return nil
        }
        guard !amllIndex.isEmpty else { return nil }

        let titleLower = title.lowercased()
        let artistLower = artist.lowercased()
        var bestMatch: (entry: AMLLIndexEntry, score: Int)?

        for entry in amllIndex {
            var score = 0
            var artistMatched = false

            let entryTitleLower = entry.musicName.lowercased()
            if entryTitleLower == titleLower { score += 100 }
            else if entryTitleLower.contains(titleLower) || titleLower.contains(entryTitleLower) { score += 50 }
            else { continue }

            for entryArtist in entry.artists.map({ $0.lowercased() }) {
                if entryArtist == artistLower { score += 80; artistMatched = true; break }
                else if entryArtist.contains(artistLower) || artistLower.contains(entryArtist) { score += 40; artistMatched = true; break }
            }

            // Title-only AMLL index matches are unsafe for short/ASCII titles
            // because the global index has many exact-title collisions. Require
            // artist evidence unless the title is distinctive CJK/non-ASCII text.
            if !artistMatched {
                guard score >= 100,
                      title.count >= 4,
                      !LanguageUtils.isPureASCII(title) else { continue }
            }
            if score > 0 && (bestMatch == nil || score > bestMatch!.score) {
                bestMatch = (entry, score)
            }
        }

        guard let match = bestMatch else { return nil }

        if let lyrics = await fetchAMLLTTML(platform: match.entry.platform, filename: "\(match.entry.id).ttml") {
            let score = scorer.calculateScore(lyrics, source: .amll, duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: .amll, score: score, kind: .synced)
        }

        return nil
    }

    /// 从 AMLL 镜像获取 TTML（共用镜像循环逻辑）
    private func fetchAMLLTTML(platform: String, filename: String) async -> [LyricLine]? {
        let maxInteractiveMirrorAttempts = min(1, amllMirrorBaseURLs.count)
        for i in 0..<maxInteractiveMirrorAttempts {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]
            guard let url = URL(string: "\(mirror.baseURL)\(platform)/\(filename)") else { continue }

            do {
                let content = try await HTTPClient.getString(url: url, timeout: 2.4, retry: false)
                self.currentMirrorIndex = mirrorIndex
                return parser.parseTTML(content)
            } catch HTTPClient.HTTPError.notFound {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    private func getAppleMusicTrackId(title: String, artist: String, duration: TimeInterval) async -> Int? {
        let searchTerm = "\(title) \(artist)"
        guard let encodedTerm = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedTerm)&entity=song&limit=10") else { return nil }
        do {
            let json = try await HTTPClient.getJSON(url: url, timeout: 2.4, retry: false)
            guard let results = json["results"] as? [[String: Any]] else { return nil }
            let titleLower = title.lowercased(), artistLower = artist.lowercased()
            var bestMatch: (trackId: Int, score: Int)?
            for result in results {
                guard let trackId = result["trackId"] as? Int,
                      let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String else { continue }
                let trackDuration = (result["trackTimeMillis"] as? Double ?? 0) / 1000.0
                var score = 0
                let tLow = trackName.lowercased()
                if tLow == titleLower { score += 100 }
                else if tLow.contains(titleLower) || titleLower.contains(tLow) { score += 50 }
                else { continue }
                let aLow = artistName.lowercased()
                if aLow == artistLower { score += 80 }
                else if aLow.contains(artistLower) || artistLower.contains(aLow) { score += 40 }
                let dd = abs(trackDuration - duration)
                if dd < 1 { score += 50 } else if dd < 3 { score += 30 } else if dd < 5 { score += 10 } else { score -= 30 }
                if score >= 80 && (bestMatch == nil || score > bestMatch!.score) { bestMatch = (trackId, score) }
            }
            return bestMatch?.trackId
        } catch { return nil }
    }

    func loadAMLLIndex() async {
        if let lastUpdate = amllIndexLastUpdate,
           Date().timeIntervalSince(lastUpdate) < amllIndexCacheDuration,
           !amllIndex.isEmpty { return }
        if amllIndexLoading { return }
        amllIndexLoading = true
        defer { amllIndexLoading = false }

        var allEntries: [AMLLIndexEntry] = []

        for i in 0..<amllMirrorBaseURLs.count {
            let mirrorIndex = (currentMirrorIndex + i) % amllMirrorBaseURLs.count
            let mirror = amllMirrorBaseURLs[mirrorIndex]
            var platformEntries: [AMLLIndexEntry] = []

            for platform in amllPlatforms {
                guard let url = URL(string: "\(mirror.baseURL)\(platform)/index.jsonl") else { continue }

                do {
                    let content = try await HTTPClient.getString(url: url, timeout: 3.0, retry: false)
                    let entries = parseAMLLIndex(content, platform: platform)
                    platformEntries.append(contentsOf: entries)
                } catch {
                    continue
                }
            }

            if !platformEntries.isEmpty {
                allEntries = platformEntries
                self.currentMirrorIndex = mirrorIndex
                break
            }
        }

        // 🔑 记录加载结果
        if allEntries.isEmpty {
            self.amllIndexLoadFailed = Date()
        } else {
            self.amllIndexLoadFailed = nil
        }

        self.amllIndex = allEntries
        self.amllIndexLastUpdate = Date()
    }

    private func parseAMLLIndex(_ content: String, platform: String) -> [AMLLIndexEntry] {
        var entries: [AMLLIndexEntry] = []
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let metadata = json["metadata"] as? [[Any]],
                  let rawLyricFile = json["rawLyricFile"] as? String else { continue }

            var musicName = "", artists: [String] = [], album = ""
            for item in metadata {
                guard item.count >= 2, let key = item[0] as? String, let values = item[1] as? [String] else { continue }
                switch key {
                case "musicName": musicName = values.first ?? ""
                case "artists": artists = values
                case "album": album = values.first ?? ""
                default: break
                }
            }

            if !musicName.isEmpty {
                entries.append(AMLLIndexEntry(id: id, musicName: musicName, artists: artists, album: album, rawLyricFile: rawLyricFile, platform: platform))
            }
        }
        return entries
    }

    // MARK: - NetEase

    /// Validate lyrics content against expected song
    func validateLyricsContent(_ rawText: String, expectedTitle: String, expectedArtist: String) -> Bool {
        let lines = rawText.components(separatedBy: .newlines).prefix(8)
        let normalizedExpectedTitle = normalizedLyricsIdentity(expectedTitle, isArtist: false)
        let normalizedExpectedArtist = normalizedLyricsIdentity(expectedArtist, isArtist: true)
        for line in lines {
            let text = line.replacingOccurrences(of: "\\[\\d{2}:\\d{2}\\.\\d{2,3}\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard text.contains(" - ") else { continue }
            if text.contains(":") || text.contains("：") { continue }
            let parts = text.components(separatedBy: " - ")
            guard parts.count == 2 else { continue }
            let left = parts[0].trimmingCharacters(in: .whitespaces)
            let right = parts[1].trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty else { continue }

            let normalizedLeftTitle = normalizedLyricsIdentity(left, isArtist: false)
            let normalizedRightTitle = normalizedLyricsIdentity(right, isArtist: false)
            let normalizedLeftArtist = normalizedLyricsIdentity(left, isArtist: true)
            let normalizedRightArtist = normalizedLyricsIdentity(right, isArtist: true)

            let titleArtistOrder = lyricsIdentityMatches(normalizedLeftTitle, normalizedExpectedTitle)
                && (normalizedExpectedArtist.isEmpty || lyricsIdentityMatches(normalizedRightArtist, normalizedExpectedArtist))
            let artistTitleOrder = (normalizedExpectedArtist.isEmpty || lyricsIdentityMatches(normalizedLeftArtist, normalizedExpectedArtist))
                && lyricsIdentityMatches(normalizedRightTitle, normalizedExpectedTitle)
            if !titleArtistOrder && !artistTitleOrder {
                DebugLogger.log("NetEase", "⚠️ Content mismatch: lyrics say '\(left) - \(right)' but expected '\(expectedTitle)' by '\(expectedArtist)'")
                return false
            }
        }
        return true
    }

    private func normalizedLyricsIdentity(_ value: String, isArtist: Bool) -> String {
        let normalized = isArtist
            ? LanguageUtils.normalizeArtistName(value)
            : LanguageUtils.normalizeTrackName(value)
        return LanguageUtils.toSimplifiedChinese(normalized)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func lyricsIdentityMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs)
    }

    func fetchFromNetEase(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        DebugLogger.log("NetEase", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s) album='\(album)'")
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration, album: album, disableCjkEscapeInP3: false)
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                       "Referer": "https://music.163.com"]

        let match: SelectedSearchCandidate<Int>? = await searchAndSelectCandidate(
            params: params, source: .netEase,
            allowCompilationAlbumFallback: true,
            fetchSongs: { keyword in
                guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                    "s": keyword, "type": "1", "limit": "20"
                ]) else { return nil }
                let (data, _) = try await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let songs = result["songs"] as? [[String: Any]] else { return nil }
                return songs
            },
            extractSong: { song in
                guard let id = song["id"] as? Int, let name = song["name"] as? String else { return nil }
                var artist = ""
                if let artists = song["artists"] as? [[String: Any]] {
                    artist = self.joinedProviderArtists(artists)
                }
                let dur = (song["duration"] as? Double ?? 0) / 1000.0
                var albumName = ""
                if let album = song["album"] as? [String: Any] {
                    var albumParts: [String] = []
                    if let n = album["name"] as? String { albumParts.append(n) }
                    if let aliases = album["alia"] as? [String] { albumParts.append(contentsOf: aliases) }
                    albumName = albumParts.joined(separator: " ")
                }
                return (id, name, artist, dur, albumName)
            }
        )

        var primaryResult: LyricsFetchResult?
        if let match {
            DebugLogger.log("NetEase", "✅ 找到 songId=\(match.id) albumMatch=\(match.albumMatched)")
            if let result = await fetchNetEaseLyrics(songId: match.id, duration: duration, expectedTitle: match.title, expectedArtist: match.artist) {
                let lyrics = result.lyrics
                let kind = result.kind
                let rawScore = scorer.calculateScore(lyrics, source: .netEase, duration: duration, translationEnabled: translationEnabled, kind: kind)
                let score = scoreWithCatalogEvidence(baseScore: rawScore, lyrics: lyrics, kind: kind, albumMatched: match.albumMatched, titleMatched: match.titleMatched, durationDiff: match.durationDiff, nativeAliasMatched: match.nativeAliasMatched)
                let scriptMismatchSuspected = shouldFlagEnglishMetadataCJKDominantLyrics(
                    lyrics,
                    title: title,
                    artist: artist,
                    originalTitle: originalTitle,
                    originalArtist: originalArtist,
                    nativeAliasMatched: match.nativeAliasMatched
                )
                if scriptMismatchSuspected {
                    DebugLogger.log("NetEase", "⚠️ Script mismatch: English metadata matched CJK-dominant lyrics for '\(match.title)' by '\(match.artist)'")
                }
                let fetched = LyricsFetchResult(
                    lyrics: lyrics,
                    source: .netEase,
                    score: score,
                    kind: kind,
                    albumMatched: match.albumMatched,
                    titleMatched: match.titleMatched,
                    matchedDurationDiff: match.durationDiff,
                    nativeAliasMatched: match.nativeAliasMatched,
                    scriptMismatchSuspected: scriptMismatchSuspected
                )
                let shouldProbeSiblingRows = isSuspiciousCompressedLineTiming(fetched, duration: duration)
                let shouldProbeLineTimedAuthoritativeSibling = shouldProbeNetEaseAuthoritativeSibling(
                    primary: fetched,
                    params: params,
                    match: match,
                    duration: duration
                )
                let shouldProbeCanonicalWordLevelSibling = shouldProbeNetEaseCanonicalWordLevelSibling(
                    primary: fetched,
                    params: params,
                    match: match
                )
                if shouldProbeSiblingRows || shouldProbeLineTimedAuthoritativeSibling || shouldProbeCanonicalWordLevelSibling {
                    primaryResult = fetched
                    let reason: String
                    if shouldProbeSiblingRows {
                        reason = "compressed line-timed version"
                    } else if shouldProbeLineTimedAuthoritativeSibling {
                        reason = "line-timed album match with possible word-level sibling"
                    } else {
                        reason = "generic album word-level match with possible canonical sibling"
                    }
                    DebugLogger.log("NetEase", "⚠️ Primary lyrics look like a \(reason) (score=\(String(format: "%.1f", score))) — probing sibling catalog rows")
                    if let siblingResult = await fetchNetEaseSiblingQualityFallback(
                        params: params,
                        headers: headers,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        excludingSongID: match.id,
                        catalogTitle: match.title,
                        catalogArtist: match.artist,
                        skipAliasResolution: true
                    ), shouldProbeSiblingRows || shouldPreferNetEaseAuthoritativeSibling(
                        siblingResult,
                        over: fetched,
                        duration: duration
                    ) {
                        return siblingResult
                    }
                }
                if score >= 35
                    || (params.normalizedAlbum.isEmpty && result.kind == .synced && match.matchRank == 0 && match.titleMatched && match.durationDiff < 1.0 && lyrics.count >= 8 && score >= 30)
                    || (result.kind == .synced && match.albumMatched && (match.titleMatched || match.nativeAliasMatched) && match.durationDiff < 2.0 && score >= 30)
                    || result.kind == .synced && result.lyrics.contains(where: { $0.hasSyllableSync }) {
                    if !shouldProbeSiblingRows {
                        return fetched
                    }
                }
                primaryResult = fetched
                DebugLogger.log("NetEase", "⚠️ Primary lyrics low quality (score=\(String(format: "%.1f", score))) — probing sibling catalog rows")
                if result.kind == .synced,
                   match.titleMatched,
                   match.durationDiff < 3.0,
                   score < 35,
                   let siblingResult = await fetchNetEaseSiblingQualityFallback(
                        params: params,
                        headers: headers,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        excludingSongID: match.id,
                        catalogTitle: match.title,
                        catalogArtist: match.artist,
                        skipAliasResolution: true
                   ) {
                    return siblingResult
                }
            }
        } else {
            DebugLogger.log("NetEase", "❌ 未找到歌曲 — trying artist-discography fallback")
        }
        DebugLogger.log("NetEase", "❌ 获取歌词失败/低质 — trying parallel fallback probes")
        let fallbackResult: LyricsFetchResult? = await withTaskGroup(of: (Int, LyricsFetchResult?).self) { group in
            group.addTask {
                (0, await self.fetchNetEaseTitleOnlyAliasFallback(
                    params: params, headers: headers,
                    duration: duration, translationEnabled: translationEnabled))
            }
            group.addTask {
                (1, await self.fetchNetEaseCompilationAlbumFallback(
                    params: params, headers: headers,
                    duration: duration, translationEnabled: translationEnabled))
            }
            group.addTask {
                (2, await self.fetchNetEaseOrphanExactTitleFallback(
                    params: params, headers: headers,
                    duration: duration, translationEnabled: translationEnabled))
            }
            group.addTask {
                (3, await self.fetchNetEaseArtistDiscographyFallback(
                    params: params, headers: headers,
                    duration: duration, translationEnabled: translationEnabled,
                    primaryResult: primaryResult, match: match))
            }
            var results: [(Int, LyricsFetchResult)] = []
            for await (priority, result) in group {
                guard let result else { continue }
                results.append((priority, result))
                if result.kind == .synced, result.score >= 45 {
                    group.cancelAll()
                    break
                }
            }
            return results.min(by: { $0.0 < $1.0 })?.1
        }
        if let fallbackResult {
            return fallbackResult
        }
        if primaryResult == nil, let match {
            return catalogUnavailableResult(
                source: .netEase,
                albumMatched: match.albumMatched,
                titleMatched: match.titleMatched,
                durationDiff: match.durationDiff
            )
        }
        return primaryResult
    }

    func shouldForegroundNetEaseArtistDiscographyAliasFallback(
        title: String,
        artist: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        album: String
    ) -> Bool {
        let params = SearchParams(
            title: title,
            artist: artist,
            originalTitle: originalTitle,
            originalArtist: originalArtist,
            duration: duration,
            album: album
        )
        return shouldRaceNetEaseArtistDiscographyFallback(params: params)
    }

    func fetchForegroundNetEaseArtistDiscographyAliasFallback(
        title: String,
        artist: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        let params = SearchParams(
            title: title,
            artist: artist,
            originalTitle: originalTitle,
            originalArtist: originalArtist,
            duration: duration,
            album: album
        )
        guard shouldRaceNetEaseArtistDiscographyFallback(params: params) else { return nil }
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            "Referer": "https://music.163.com"
        ]
        return await fetchNetEaseArtistDiscographyFallback(
            params: params,
            headers: headers,
            duration: duration,
            translationEnabled: translationEnabled,
            primaryResult: nil,
            match: nil
        )
    }

    private func shouldRaceNetEaseArtistDiscographyFallback(params: SearchParams) -> Bool {
        guard params.normalizedAlbum.isEmpty else { return false }
        guard LanguageUtils.isPureASCII(params.rawTitle),
              LanguageUtils.isPureASCII(params.rawArtist),
              !isCompilationArtistName(params.rawArtist),
              !isCompilationArtistName(params.rawOriginalArtist) else {
            return false
        }
        return isPotentialSingleWordEnglishCatalogAlias(params.rawTitle)
            || isPotentialSingleWordEnglishCatalogAlias(params.rawOriginalTitle)
    }

    private func fetchNetEaseArtistDiscographyFallback(
        params: SearchParams,
        headers: [String: String],
        duration: TimeInterval,
        translationEnabled: Bool,
        primaryResult: LyricsFetchResult?,
        match: SelectedSearchCandidate<Int>?
    ) async -> LyricsFetchResult? {
        // Empty-lyrics fallback: same-artist discography rescue for provider
        // catalogs that expose the real track under an alternate native title.
        let cjkArtistForFallback = await resolveArtistCJKAliases(asciiArtist: params.rawArtist).first
            ?? (LanguageUtils.containsCJK(params.rawArtist) ? params.rawArtist : params.rawOriginalArtist)
        guard !cjkArtistForFallback.isEmpty else { return nil }
        let altURL = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
            "s": cjkArtistForFallback, "type": "1", "limit": "50"
        ])
        guard let url2 = altURL,
              let (data, _) = try? await HTTPClient.getData(url: url2, headers: headers, timeout: 2.4, retry: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result2 = json["result"] as? [String: Any],
              let songs = result2["songs"] as? [[String: Any]] else { return nil }
        let simplifiedInputTitle = params.simplifiedTitle
        struct Cand { let id: Int; let name: String; let artist: String; let dur: Double; let delta: Double; let titleMatched: Bool; let sourceTitleAlias: Bool; let riskyNativeAlias: Bool }
        let cands: [Cand] = songs.compactMap { s in
            guard let id = s["id"] as? Int,
                  let name = s["name"] as? String,
                  let dur = (s["duration"] as? Double).map({ $0 / 1000.0 }) else { return nil }
            if let primaryId = match?.id, id == primaryId, primaryResult != nil { return nil }
            let artistName = (s["artists"] as? [[String: Any]]).map { joinedProviderArtists($0) } ?? cjkArtistForFallback
            let delta = abs(dur - duration)
            guard delta < 20.0 else { return nil }
            let titleOK = isTitleMatch(input: params.rawTitle, result: name, simplifiedInput: simplifiedInputTitle)
                || isTitleMatch(input: params.rawOriginalTitle, result: name, simplifiedInput: params.simplifiedOriginalTitle)
            let inputTitleIsASCII = LanguageUtils.isPureASCII(params.rawTitle)
                || LanguageUtils.isPureASCII(params.rawOriginalTitle)
            let sameArtistIsCJK = LanguageUtils.containsCJK(cjkArtistForFallback)
            let candidateArtistOK = isArtistMatch(
                input: cjkArtistForFallback,
                result: artistName,
                simplifiedInput: LanguageUtils.toSimplifiedChinese(cjkArtistForFallback)
            )
            let resultTitleHasCJK = LanguageUtils.containsCJK(name)
            let lowerName = name.lowercased()
            let looksBackingTrack = lowerName.contains("karaoke")
                || lowerName.contains("instrumental")
                || lowerName.contains("伴奏")
                || lowerName.contains("オリジナル・カラオケ")
            let inputLooksEnglish = LanguageUtils.isLikelyEnglishTitle(params.rawTitle)
                || LanguageUtils.isLikelyEnglishTitle(params.rawOriginalTitle)
            let inputLooksRomanizedJapanese = LanguageUtils.isLikelyRomanizedJapanese(params.rawTitle)
                || LanguageUtils.isLikelyRomanizedJapanese(params.rawOriginalTitle)
            let inputWordCount = [params.rawTitle, params.rawOriginalTitle]
                .map { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count }
                .max() ?? 0
            let sourceTitleAlias = inputTitleIsASCII
                && sameArtistIsCJK
                && candidateArtistOK
                && resultTitleHasCJK
                && (inputLooksRomanizedAlias(params) || inputLooksEnglishTranslationAlias(params))
                && !looksBackingTrack
                && (inputWordCount >= 2 || inputLooksEnglish || !inputLooksRomanizedJapanese)
                && (!inputLooksRomanizedJapanese || inputWordCount >= 2)
                && (inputLooksEnglish ? delta < 1.5 : delta < 20.0)
            let riskyNativeAlias = inputTitleIsASCII
                && sameArtistIsCJK
                && candidateArtistOK
                && resultTitleHasCJK
                && !looksBackingTrack
                && inputLooksRomanizedJapanese
                && inputWordCount <= 1
                && delta < 20.0
            return Cand(id: id, name: name, artist: artistName, dur: dur, delta: delta, titleMatched: titleOK, sourceTitleAlias: sourceTitleAlias, riskyNativeAlias: riskyNativeAlias)
        }
        .filter { c in
            if c.titleMatched { return true }
            // If the provider already found the requested catalog row but that
            // row has no usable lyrics, do not jump to a different same-artist
            // CJK title just because the duration is nearby. That turns
            // instrumental/no-lyrics tracks into unrelated vocal lyrics.
            if c.sourceTitleAlias { return match == nil && params.normalizedAlbum.isEmpty }
            if c.riskyNativeAlias { return params.normalizedAlbum.isEmpty }
            let inputLooksRomanized = LanguageUtils.isPureASCII(params.rawTitle)
                && (params.rawTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count >= 4
                    || LanguageUtils.isLikelyRomanizedJapanese(params.rawTitle))
                && !LanguageUtils.isLikelyEnglishTitle(params.rawTitle)
            return match == nil && inputLooksRomanized && LanguageUtils.containsCJK(c.name) && c.delta < 1.0
        }
        .sorted {
            if $0.sourceTitleAlias != $1.sourceTitleAlias { return $0.sourceTitleAlias && !$1.sourceTitleAlias }
            if $0.riskyNativeAlias != $1.riskyNativeAlias { return !$0.riskyNativeAlias && $1.riskyNativeAlias }
            if $0.titleMatched != $1.titleMatched { return $0.titleMatched && !$1.titleMatched }
            return $0.delta < $1.delta
        }
        DebugLogger.log("NetEase", "🔁 artist-disco fallback: \(cands.count) candidates within ±15s (by title match)")
        var bestFallback: LyricsFetchResult?
        let fallbackProbeLimit = cands.contains(where: { $0.riskyNativeAlias }) ? 20 : 8
        let needsTextWitness = cands.prefix(fallbackProbeLimit).contains(where: { $0.riskyNativeAlias })
        async let pendingTextWitness: LyricsFetchResult? = needsTextWitness
            ? fetchFromLyricsOVH(
                title: params.rawOriginalTitle,
                artist: params.rawOriginalArtist,
                duration: duration,
                translationEnabled: false
            )
            : nil
        for c in cands.prefix(fallbackProbeLimit) {
            if let r = await fetchNetEaseLyrics(songId: c.id, duration: duration, expectedTitle: c.name, expectedArtist: c.artist),
               !r.lyrics.isEmpty, r.lyrics.count >= 5 {
                let candidateLyrics = removingLeadingCatalogCreditLines(r.lyrics, title: c.name, artist: c.artist)
                if c.riskyNativeAlias {
                    guard let witness = await pendingTextWitness,
                          lyricIdentityTokens(witness.lyrics).count >= 6,
                          (lyricSimilarity(candidateLyrics, witness.lyrics) >= 0.10
                           || hasCJKLyricOverlap(candidateLyrics, witness.lyrics)) else {
                        DebugLogger.log("NetEase", "⏭️ risky native alias rejected without text witness: '\(c.name)' Δ\(String(format: "%.1f", c.delta))s")
                        continue
                    }
                }
                if c.sourceTitleAlias && hasRiskyUnprovedNativeAliasTiming(candidateLyrics) {
                    DebugLogger.log("NetEase", "⏭️ native alias rejected by unproved immediate-vocal timing: '\(c.name)' Δ\(String(format: "%.1f", c.delta))s")
                    continue
                }
                let rawScore = scorer.calculateScore(candidateLyrics, source: .netEase, duration: duration, translationEnabled: translationEnabled, kind: r.kind)
                var score = scoreWithCatalogEvidence(
                    baseScore: rawScore,
                    lyrics: candidateLyrics,
                    kind: r.kind,
                    albumMatched: false,
                    titleMatched: c.titleMatched,
                    durationDiff: c.delta,
                    nativeAliasMatched: c.sourceTitleAlias || c.riskyNativeAlias
                )
                if c.riskyNativeAlias {
                    score = max(score, 45)
                }
                let fetched = LyricsFetchResult(lyrics: candidateLyrics, source: .netEase, score: score, kind: r.kind, albumMatched: false, titleMatched: c.titleMatched, matchedDurationDiff: c.delta, nativeAliasMatched: c.sourceTitleAlias || c.riskyNativeAlias)
                DebugLogger.log("NetEase", "✅ fallback hit: id=\(c.id) '\(c.name)' Δ\(String(format: "%.1f", c.delta))s \(candidateLyrics.count)L")
                if bestFallback == nil || score > bestFallback!.score {
                    bestFallback = fetched
                }
                if c.riskyNativeAlias && r.kind == .synced && score >= 45 {
                    break
                }
                if score >= 80 && r.lyrics.contains(where: { $0.hasSyllableSync }) {
                    break
                }
            }
        }
        if let bestFallback,
           bestFallback.score >= max(30, (primaryResult?.score ?? 0) + 10) {
            return bestFallback
        }
        if LanguageUtils.isPureASCII(params.rawTitle),
           let witness = await fetchFromLyricsOVH(
                title: params.rawOriginalTitle,
                artist: params.rawOriginalArtist,
                duration: duration,
                translationEnabled: false
           ),
           let cjkProbe = firstCJKLyricProbe(witness.lyrics) {
            let probeKeyword = "\(cjkProbe) \(cjkArtistForFallback)"
            if let rescued = await fetchNetEaseWitnessMatchedResult(
                keyword: probeKeyword,
                witness: witness,
                headers: headers,
                duration: duration,
                translationEnabled: translationEnabled
            ) {
                return rescued
            }
        }
        if primaryResult == nil, let match {
            return catalogUnavailableResult(
                source: .netEase,
                albumMatched: match.albumMatched,
                titleMatched: match.titleMatched,
                durationDiff: match.durationDiff
            )
        }
        return primaryResult
    }

    private func firstCJKLyricProbe(_ lyrics: [LyricLine]) -> String? {
        for line in lyrics {
            let compact = line.text.unicodeScalars
                .filter { LanguageUtils.isCJKScalar($0) }
                .map(String.init)
                .joined()
            if compact.count >= 4 {
                return String(compact.prefix(8))
            }
        }
        return nil
    }

    private func fetchNetEaseWitnessMatchedResult(
        keyword: String,
        witness: LyricsFetchResult,
        headers: [String: String],
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> LyricsFetchResult? {
        guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
            "s": keyword, "type": "1", "limit": "10"
        ]) else { return nil }
        guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return nil }

        for song in songs.prefix(8) {
            guard let id = song["id"] as? Int,
                  let name = song["name"] as? String else { continue }
            let artistName = (song["artists"] as? [[String: Any]]).map { joinedProviderArtists($0) } ?? ""
            guard let fetched = await fetchNetEaseLyrics(songId: id, duration: duration, expectedTitle: name, expectedArtist: artistName),
                  !fetched.lyrics.isEmpty,
                  hasCJKLyricOverlap(fetched.lyrics, witness.lyrics) else { continue }
            let rawScore = scorer.calculateScore(fetched.lyrics, source: .netEase, duration: duration, translationEnabled: translationEnabled, kind: fetched.kind)
            let score = max(rawScore, 45)
            DebugLogger.log("NetEase", "✅ witness-probe rescue: '\(name)' by '\(artistName)'")
            return LyricsFetchResult(
                lyrics: fetched.lyrics,
                source: .netEase,
                score: score,
                kind: fetched.kind,
                albumMatched: false,
                titleMatched: false,
                matchedDurationDiff: nil,
                nativeAliasMatched: true
            )
        }
        return nil
    }

    private func inputLooksRomanizedAlias(_ params: SearchParams) -> Bool {
        let title = params.rawTitle
        guard LanguageUtils.isPureASCII(title),
              !LanguageUtils.isLikelyEnglishTitle(title) else { return false }
        let tokenCount = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        return tokenCount >= 4 || LanguageUtils.isLikelyRomanizedJapanese(title)
    }

    private func inputLooksEnglishTranslationAlias(_ params: SearchParams) -> Bool {
        let title = params.rawTitle
        guard LanguageUtils.isPureASCII(title) else { return false }
        if LanguageUtils.isLikelyEnglishTitle(title) { return true }
        return isPotentialSingleWordEnglishCatalogAlias(title)
    }

    private func isPotentialSingleWordEnglishCatalogAlias(_ title: String) -> Bool {
        let normalized = LanguageUtils.normalizeTrackName(title)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let words = normalized
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard words.count == 1,
              let word = words.first,
              word.count >= 4,
              word.count <= 12,
              !LanguageUtils.isLikelyRomanizedJapanese(title) else {
            return false
        }
        let letters = word.filter(\.isLetter)
        let vowels = Set("aeiouy")
        let vowelCount = letters.filter { vowels.contains($0) }.count
        let consonantCount = letters.count - vowelCount
        return vowelCount >= 1 && consonantCount >= 2
    }

    private struct NetEaseLooseTitleCandidate: Sendable {
        let id: Int
        let name: String
        let artist: String
        let albumMatched: Bool
        let normalizedNameLength: Int
        let durationDiff: Double
        let resultIndex: Int
    }

    func isSafeNetEaseOrphanExactTitleCandidate(
        inputTitle: String,
        originalTitle: String,
        candidateTitle: String,
        durationDiff: Double
    ) -> Bool {
        guard durationDiff < 1.25 else { return false }
        let normalizedTitle = LanguageUtils.normalizeTrackName(inputTitle)
        let normalizedOriginalTitle = LanguageUtils.normalizeTrackName(originalTitle)
        let inputHasCJK = LanguageUtils.containsCJK(normalizedTitle)
            || LanguageUtils.containsCJK(normalizedOriginalTitle)
        guard inputHasCJK else { return false }

        let distinctiveCJKCount = [normalizedTitle, normalizedOriginalTitle]
            .map { title in
                LanguageUtils.toSimplifiedChinese(title)
                    .unicodeScalars
                    .filter { LanguageUtils.isCJKScalar($0) }
                    .count
            }
            .max() ?? 0
        guard distinctiveCJKCount >= 4 else { return false }

        return isTitleMatch(
            input: inputTitle,
            result: candidateTitle,
            simplifiedInput: LanguageUtils.toSimplifiedChinese(normalizedTitle)
        ) || isTitleMatch(
            input: originalTitle,
            result: candidateTitle,
            simplifiedInput: LanguageUtils.toSimplifiedChinese(normalizedOriginalTitle)
        )
    }

    private struct NetEaseOrphanExactTitleCandidate: Sendable {
        let id: Int
        let name: String
        let artist: String
        let durationDiff: Double
        let resultIndex: Int
    }

    private func fetchNetEaseOrphanExactTitleFallback(
        params: SearchParams,
        headers: [String: String],
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> LyricsFetchResult? {
        let titleTerms = Array(Set([
            params.simplifiedTitle,
            params.simplifiedOriginalTitle,
            LanguageUtils.toTraditionalChinese(params.rawTitle),
            LanguageUtils.toTraditionalChinese(params.rawOriginalTitle)
        ].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }))
            .filter { !$0.isEmpty }

        var candidates: [NetEaseOrphanExactTitleCandidate] = []
        for term in titleTerms {
            guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
                "s": term, "type": "1", "limit": "20"
            ]) else { continue }
            guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]] else { continue }

            for (index, song) in songs.enumerated() {
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let durMS = song["duration"] as? Double else { continue }
                let artistName = (song["artists"] as? [[String: Any]]).map { joinedProviderArtists($0) } ?? ""
                let lowerName = name.lowercased()
                let looksBackingTrack = lowerName.contains("karaoke")
                    || lowerName.contains("instrumental")
                    || lowerName.contains("伴奏")
                    || lowerName.contains("オリジナル・カラオケ")
                guard !looksBackingTrack else { continue }

                let delta = abs((durMS / 1000.0) - duration)
                guard isSafeNetEaseOrphanExactTitleCandidate(
                    inputTitle: params.rawTitle,
                    originalTitle: params.rawOriginalTitle,
                    candidateTitle: name,
                    durationDiff: delta
                ) else { continue }
                candidates.append(NetEaseOrphanExactTitleCandidate(
                    id: id,
                    name: name,
                    artist: artistName,
                    durationDiff: delta,
                    resultIndex: index
                ))
            }
        }

        let uniqueCandidates = candidates.reduce(into: [Int: NetEaseOrphanExactTitleCandidate]()) { partial, candidate in
            if let existing = partial[candidate.id], existing.durationDiff <= candidate.durationDiff { return }
            partial[candidate.id] = candidate
        }
        .values
        .sorted {
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        guard !uniqueCandidates.isEmpty else { return nil }
        DebugLogger.log("NetEase", "🔁 orphan exact-title fallback: \(uniqueCandidates.prefix(5).map { "'\($0.name)' by '\($0.artist)' Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", "))")

        var fallbackResults: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            for candidate in uniqueCandidates.prefix(3) {
                group.addTask {
                    guard let fetched = await self.fetchNetEaseLyrics(
                        songId: candidate.id,
                        duration: duration,
                        expectedTitle: candidate.name,
                        expectedArtist: candidate.artist
                    ) else {
                        return nil
                    }
                    let lyrics = self.removingLeadingCatalogCreditLines(
                        fetched.lyrics,
                        title: candidate.name,
                        artist: candidate.artist
                    )
                    guard fetched.kind == .synced,
                          lyrics.count >= 8,
                          lyrics.contains(where: { LanguageUtils.containsCJK($0.text) }) else {
                        return nil
                    }
                    let rawScore = self.scorer.calculateScore(
                        lyrics,
                        source: .netEase,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        kind: fetched.kind
                    )
                    var score = self.scoreWithCatalogEvidence(
                        baseScore: rawScore,
                        lyrics: lyrics,
                        kind: fetched.kind,
                        albumMatched: false,
                        titleMatched: true,
                        durationDiff: candidate.durationDiff
                    )
                    score = max(score, 45)
                    let result = LyricsFetchResult(
                        lyrics: lyrics,
                        source: .netEase,
                        score: score,
                        kind: fetched.kind,
                        albumMatched: false,
                        titleMatched: true,
                        matchedDurationDiff: candidate.durationDiff
                    )
                    if self.isSuspiciousCompressedLineTiming(result, duration: duration) {
                        return nil
                    }
                    return result
                }
            }
            for await result in group {
                if let result { fallbackResults.append(result) }
            }
        }

        guard let best = fallbackResults.sorted(by: { $0.score > $1.score }).first else { return nil }
        DebugLogger.log("NetEase", "✅ orphan exact-title fallback hit: score=\(String(format: "%.1f", best.score)) Δ\(String(format: "%.1f", best.matchedDurationDiff ?? 0))s")
        return best
    }

    private func fetchNetEaseTitleOnlyAliasFallback(
        params: SearchParams,
        headers: [String: String],
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> LyricsFetchResult? {
        let inputHasCJKTitle = LanguageUtils.containsCJK(params.rawTitle)
            || LanguageUtils.containsCJK(params.rawOriginalTitle)
        let inputHasASCIIArtist = params.artistPairs.contains { LanguageUtils.isPureASCII($0.0) }
        guard inputHasCJKTitle, inputHasASCIIArtist, !params.normalizedAlbum.isEmpty else { return nil }

        guard let url = HTTPClient.buildURL(base: "https://music.163.com/api/search/get", queryItems: [
            "s": params.simplifiedTitle, "type": "1", "limit": "20"
        ]) else { return nil }
        guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 2.4, retry: false),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else { return nil }

        let durationLimit = params.normalizedAlbum.isEmpty ? 35.0 : 45.0
        let candidates: [NetEaseLooseTitleCandidate] = songs.enumerated().compactMap { index, song in
            guard let id = song["id"] as? Int,
                  let name = song["name"] as? String,
                  let durMS = song["duration"] as? Double else { return nil }
            let artistName = (song["artists"] as? [[String: Any]]).map { joinedProviderArtists($0) } ?? ""
            guard LanguageUtils.containsCJK(artistName) else { return nil }
            let dur = durMS / 1000.0
            let delta = abs(dur - duration)
            guard delta < durationLimit else { return nil }
            let titleOK = isTitleMatch(input: params.rawTitle, result: name, simplifiedInput: params.simplifiedTitle)
                || isTitleMatch(input: params.rawOriginalTitle, result: name, simplifiedInput: params.simplifiedOriginalTitle)
            guard titleOK else { return nil }
            let lowerName = name.lowercased()
            let looksBackingTrack = lowerName.contains("karaoke")
                || lowerName.contains("instrumental")
                || lowerName.contains("伴奏")
                || lowerName.contains("オリジナル・カラオケ")
            guard !looksBackingTrack else { return nil }
            let albumName = (song["album"] as? [String: Any])?["name"] as? String ?? ""
            let normalizedAlbum = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(albumName)
            ).lowercased().replacingOccurrences(of: "-", with: " ")
            let albumMatched = !params.normalizedAlbum.isEmpty
                && !normalizedAlbum.isEmpty
                && (params.normalizedAlbum == normalizedAlbum
                    || params.normalizedAlbum.contains(normalizedAlbum)
                    || normalizedAlbum.contains(params.normalizedAlbum))
            guard albumMatched else { return nil }
            return NetEaseLooseTitleCandidate(
                id: id,
                name: name,
                artist: artistName,
                albumMatched: albumMatched,
                normalizedNameLength: LanguageUtils.normalizeTrackName(name).count,
                durationDiff: delta,
                resultIndex: index
            )
        }
        .sorted {
            if $0.albumMatched != $1.albumMatched { return $0.albumMatched && !$1.albumMatched }
            if $0.normalizedNameLength != $1.normalizedNameLength {
                return $0.normalizedNameLength < $1.normalizedNameLength
            }
            if $0.resultIndex != $1.resultIndex { return $0.resultIndex < $1.resultIndex }
            return $0.durationDiff < $1.durationDiff
        }
        guard !candidates.isEmpty else { return nil }
        DebugLogger.log("NetEase", "🔁 title-only alias fallback: \(candidates.prefix(5).map { "'\($0.name)' by '\($0.artist)' Δ\(String(format: "%.1f", $0.durationDiff))s" }.joined(separator: ", "))")

        var fallbackResults: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            for candidate in candidates.prefix(3) {
                group.addTask {
                    guard let fetched = await self.fetchNetEaseLyrics(
                        songId: candidate.id,
                        duration: duration,
                        expectedTitle: candidate.name,
                        expectedArtist: candidate.artist
                    ), !fetched.lyrics.isEmpty, fetched.lyrics.count >= 5 else {
                        return nil
                    }
                    let rawScore = self.scorer.calculateScore(
                        fetched.lyrics,
                        source: .netEase,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        kind: fetched.kind
                    )
                    let score = self.scoreWithCatalogEvidence(
                        baseScore: rawScore,
                        lyrics: fetched.lyrics,
                        kind: fetched.kind,
                        albumMatched: candidate.albumMatched,
                        titleMatched: true,
                        durationDiff: candidate.durationDiff
                    )
                    return LyricsFetchResult(
                        lyrics: fetched.lyrics,
                        source: .netEase,
                        score: score,
                        kind: fetched.kind,
                        albumMatched: candidate.albumMatched,
                        titleMatched: true,
                        matchedDurationDiff: candidate.durationDiff
                    )
                }
            }
            for await result in group {
                if let result { fallbackResults.append(result) }
            }
        }

        let usable = fallbackResults.filter {
            $0.kind == .synced && !$0.lyrics.isEmpty && $0.score >= 25
        }
        guard let best = usable.sorted(by: { $0.score > $1.score }).first else { return nil }
        DebugLogger.log("NetEase", "✅ title-only alias fallback hit: score=\(String(format: "%.1f", best.score)) Δ\(String(format: "%.1f", best.matchedDurationDiff ?? 0))s")
        return best
    }

    func fetchNetEaseLyrics(songId: Int, duration: TimeInterval, expectedTitle: String = "", expectedArtist: String = "") async -> (lyrics: [LyricLine], kind: LyricsKind)? {
        // 🔑 yv=1 requests YRC (word-level) lyrics alongside LRC/tlyric
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&tv=1&yv=1") else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Referer": "https://music.163.com"
            ], timeout: 2.4, retry: false)

            // 🔑 Content validation
            if !expectedTitle.isEmpty {
                let rawLRC = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
                if !rawLRC.isEmpty && !validateLyricsContent(rawLRC, expectedTitle: expectedTitle, expectedArtist: expectedArtist) {
                    return nil
                }
            }

            // 🔑 Prefer YRC (word-level) over LRC
            var lyrics: [LyricLine]
            var isYRC = false
            var resultKind: LyricsKind = .synced

            if let yrc = json["yrc"] as? [String: Any],
               let yrcText = yrc["lyric"] as? String, !yrcText.isEmpty,
               let yrcLines = parser.parseYRC(yrcText, timeOffset: 0) {
                lyrics = parser.stripMetadataLines(yrcLines)
                isYRC = true
                DebugLogger.log("NetEase", "🎯 YRC word-level: \(lyrics.count) lines, \(lyrics.filter { $0.hasSyllableSync }.count) synced")
            } else if let lrc = json["lrc"] as? [String: Any],
                      let lyricText = lrc["lyric"] as? String, !lyricText.isEmpty {
                if isInstrumentalNotice(lyricText) {
                    return ([LyricLine(text: lyricText, startTime: 0, endTime: duration)], .instrumental)
                }
                let parsed = parser.parseLRC(lyricText)
                if parsed.isEmpty {
                    lyrics = parser.createUnsyncedLyrics(lyricText, duration: duration)
                    resultKind = .unsynced
                    DebugLogger.log("NetEase", "🚫 LRC has no timestamps — using unsynced fallback (\(lyrics.count) lines)")
                } else {
                    lyrics = parser.stripMetadataLines(parsed)
                    resultKind = parser.detectKind(lyrics)
                    if resultKind == .unsynced {
                        DebugLogger.log("NetEase", "🚫 detectKind = .unsynced (degenerate timestamps) (\(lyrics.count) lines)")
                    }
                }
            } else {
                return nil
            }

            // 🔑 YRC is authoritative word-level data
            if !isYRC {
                let (extracted, isInterleaved) = parser.extractInterleavedTranslations(lyrics)
                if isInterleaved {
                    lyrics = extracted
                }
            }

            // Merge translations
            let translationSource: String? = {
                if isYRC, let ytlrc = json["ytlrc"] as? [String: Any],
                   let text = ytlrc["lyric"] as? String, !text.isEmpty { return text }
                if let tlyric = json["tlyric"] as? [String: Any],
                   let text = tlyric["lyric"] as? String, !text.isEmpty { return text }
                return nil
            }()
            if let translatedText = translationSource {
                let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(translatedText))
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            // 🔑 最后一道防线：剥离非中文歌曲中的中文翻译。
            // NetEase can leak translations into both LRC and YRC original
            // text while also providing tlyric/ytlrc, so this must run for
            // every parsed kind after source translations are merged.
            lyrics = parser.stripChineseTranslations(lyrics)

            let final = resultKind == .synced
                ? parser.applyTimeOffset(to: lyrics, offset: netEaseTimeOffset)
                : lyrics
            return (final, resultKind)
        } catch {
            return nil
        }
    }

    // MARK: - QQ Music

    /// Probe QQ for the CJK artist name when given an ASCII artist.
    func probeQQForCJKArtist(title: String, artist: String, duration: TimeInterval) async -> String? {
        guard LanguageUtils.isPureASCII(artist) else { return nil }
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        let keyword = "\(title) \(artist)"
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1845],
            "req": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                    "param": ["num_per_page": 5, "page_num": 1, "query": keyword, "search_type": 0] as [String: Any]
            ] as [String: Any]
        ]
        do {
            let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 2.4)
            guard let reqDict = json["req"] as? [String: Any],
                  let dataDict = reqDict["data"] as? [String: Any],
                  let bodyDict = dataDict["body"] as? [String: Any],
                  let songDict = bodyDict["song"] as? [String: Any],
                  let songs = songDict["list"] as? [[String: Any]] else { return nil }
            let simplifiedInputTitle = LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName(title))
            var preciseBest: (artist: String, dur: Double)? = nil
            for song in songs.prefix(10) {
                guard let name = song["name"] as? String,
                      let singers = song["singer"] as? [[String: Any]],
                      let firstSinger = singers.first,
                      let singerName = firstSinger["name"] as? String,
                      let intervalInt = song["interval"] as? Int else { continue }
                let dur = Double(intervalInt)
                let titleOK = isTitleMatch(input: title, result: name, simplifiedInput: simplifiedInputTitle)
                guard titleOK else { continue }
                guard LanguageUtils.containsCJK(singerName) else { continue }
                let thisDelta = abs(dur - duration)
                if thisDelta < 3.0 {
                    if let b = preciseBest, abs(b.dur - duration) <= thisDelta { continue }
                    preciseBest = (singerName, dur)
                    continue
                }
            }
            return preciseBest?.artist
        } catch { }
        return nil
    }

    func fetchFromQQMusic(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        DebugLogger.log("QQMusic", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s) album='\(album)'")
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration, album: album, disableCjkEscapeInP3: false)
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }

        guard let qqMatch: SelectedSearchCandidate<String> = await searchAndSelectCandidate(
            params: params, source: .qq,
            extraKeywords: [(params.simplifiedTitle, "title only")],
            fetchSongs: { keyword in
                let body: [String: Any] = [
                    "comm": ["ct": 19, "cv": 1845],
                    "req": ["method": "DoSearchForQQMusicDesktop", "module": "music.search.SearchCgiService",
                            "param": ["num_per_page": 20, "page_num": 1, "query": keyword, "search_type": 0] as [String: Any]
                    ] as [String: Any]
                ]
                let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 2.4)
                guard let reqDict = json["req"] as? [String: Any],
                      let dataDict = reqDict["data"] as? [String: Any],
                      let bodyDict = dataDict["body"] as? [String: Any],
                      let songDict = bodyDict["song"] as? [String: Any],
                      let songs = songDict["list"] as? [[String: Any]] else { return nil }
                return songs
            },
            extractSong: { song in
                guard let mid = song["mid"] as? String, let name = song["name"] as? String else { return nil }
                let songID = song["id"] as? Int
                var artist = ""
                if let singers = song["singer"] as? [[String: Any]] {
                    artist = self.joinedProviderArtists(singers)
                }
                let dur = Double(song["interval"] as? Int ?? 0)
                let albumName = (song["album"] as? [String: Any])?["name"] as? String ?? ""
                let providerID = songID.map { "\(mid)|\($0)" } ?? mid
                return (providerID, name, artist, dur, albumName)
            }
        ) else {
            DebugLogger.log("QQMusic", "❌ 未找到歌曲")
            return nil
        }
        let idParts = qqMatch.id.split(separator: "|", maxSplits: 1).map(String.init)
        let songMid = idParts.first ?? qqMatch.id
        let songID = idParts.dropFirst().first.flatMap(Int.init)

        DebugLogger.log("QQMusic", "✅ 找到 songMid=\(songMid) albumMatch=\(qqMatch.albumMatched)")
        let primaryLyrics: (lyrics: [LyricLine], kind: LyricsKind)?
        if let songID {
            primaryLyrics = await fetchQQMusicLyricsViaMusicu(songMid: songMid, songID: songID, duration: duration)
        } else {
            primaryLyrics = nil
        }
        let fallbackLyrics: (lyrics: [LyricLine], kind: LyricsKind)?
        if primaryLyrics == nil {
            fallbackLyrics = await fetchQQMusicLyrics(songMid: songMid, duration: duration)
        } else {
            fallbackLyrics = nil
        }
        guard let result = primaryLyrics ?? fallbackLyrics else {
            DebugLogger.log("QQMusic", "❌ 获取歌词失败")
            return catalogUnavailableResult(
                source: .qq,
                albumMatched: qqMatch.albumMatched,
                titleMatched: qqMatch.titleMatched,
                durationDiff: qqMatch.durationDiff
            )
        }
        let lyrics = result.lyrics
        let kind = result.kind
        let rawScore = scorer.calculateScore(lyrics, source: .qq, duration: duration, translationEnabled: translationEnabled, kind: kind)
        let score = scoreWithCatalogEvidence(baseScore: rawScore, lyrics: lyrics, kind: kind, albumMatched: qqMatch.albumMatched, titleMatched: qqMatch.titleMatched, durationDiff: qqMatch.durationDiff, nativeAliasMatched: qqMatch.nativeAliasMatched)
        return LyricsFetchResult(lyrics: lyrics, source: .qq, score: score, kind: kind, albumMatched: qqMatch.albumMatched, titleMatched: qqMatch.titleMatched, matchedDurationDiff: qqMatch.durationDiff, nativeAliasMatched: qqMatch.nativeAliasMatched)
    }

    private func fetchQQMusicLyrics(songMid: String, duration: TimeInterval) async -> (lyrics: [LyricLine], kind: LyricsKind)? {
        guard let url = HTTPClient.buildURL(base: "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", queryItems: [
            "songmid": songMid, "format": "json", "nobase64": "1"
        ]) else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                "Referer": "https://y.qq.com/portal/player.html"
            ], timeout: 2.4, retry: false)

            guard let lyricText = json["lyric"] as? String, !lyricText.isEmpty else { return nil }
            if isInstrumentalNotice(lyricText) {
                return ([LyricLine(text: lyricText, startTime: 0, endTime: duration)], .instrumental)
            }

            let parsed = parser.parseLRC(lyricText)
            var lyrics: [LyricLine]
            var resultKind: LyricsKind = .synced
            if parsed.isEmpty {
                lyrics = parser.createUnsyncedLyrics(lyricText, duration: duration)
                resultKind = .unsynced
                DebugLogger.log("QQMusic", "🚫 lyric has no timestamps — using unsynced fallback (\(lyrics.count) lines)")
            } else {
                lyrics = parser.stripMetadataLines(parsed)
                resultKind = parser.detectKind(lyrics)
                if resultKind == .unsynced {
                    DebugLogger.log("QQMusic", "🚫 detectKind = .unsynced (degenerate timestamps) (\(lyrics.count) lines)")
                }
            }

            let (extracted, isInterleaved) = parser.extractInterleavedTranslations(lyrics)
            if isInterleaved {
                lyrics = extracted
            } else if let transText = json["trans"] as? String, !transText.isEmpty {
                let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(transText))
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            lyrics = removingStandaloneSpeakerLabelLines(lyrics)
            lyrics = parser.stripChineseTranslations(lyrics)

            let final = resultKind == .synced
                ? parser.applyTimeOffset(to: lyrics, offset: qqTimeOffset)
                : lyrics
            return (final, resultKind)
        } catch {
            return nil
        }
    }

    // MARK: - LRCLIB

    func fetchFromLRCLIB(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("LRCLIB", "🔍 /get '\(title)' by '\(artist)' (\(Int(duration))s)")
        let normalizedTitle = LanguageUtils.normalizeTrackName(title)
        let normalizedArtist = LanguageUtils.normalizeArtistName(artist)

        // Boundary mapping: cache rows store the source as a string — map once,
        // then require the LRCLIB case. Unknown strings simply miss the cache.
        if let cached = lyricsDiskCache.get(title: title, artist: artist, duration: duration),
           LyricsSource(rawValue: cached.source) == .lrclib,
           let cachedLines = cached.lines {
            let lyrics = LyricsDiskCache.lyricLines(from: cachedLines)
            if !lyrics.isEmpty {
                let score = scorer.calculateScore(lyrics, source: .lrclib, duration: duration, translationEnabled: translationEnabled)
                return LyricsFetchResult(
                    lyrics: lyrics,
                    source: .lrclib,
                    score: score,
                    kind: .synced,
                    matchedDurationDiff: cached.matchedDurationDiff
                )
            }
        }

        let headers = [
            "Accept": "application/json",
            "User-Agent": "nanoPod/1.0 (https://github.com/yinanli1917-cloud/AM-MiniPlayer)"
        ]
        guard let url = HTTPClient.buildURL(base: "https://lrclib.net/api/get", queryItems: [
            "artist_name": normalizedArtist, "track_name": normalizedTitle, "duration": String(Int(duration))
        ]) else { return nil }

        do {
            let json = try await HTTPClient.getJSON(url: url, headers: headers, timeout: 5.0, retry: false)

            guard let syncedLyrics = json["syncedLyrics"] as? String, !syncedLyrics.isEmpty else {
                DebugLogger.log("LRCLIB", "❌ /get no synced lyrics for '\(title)' by '\(artist)'")
                return nil
            }
            let resultTitle = json["trackName"] as? String ?? normalizedTitle
            let resultArtist = json["artistName"] as? String ?? normalizedArtist
            let resultDuration = Self.jsonDouble(json["duration"]) ?? duration
            let matchResult = MatchingUtils.calculateMatch(
                targetTitle: title, targetArtist: artist, targetDuration: duration,
                actualTitle: resultTitle, actualArtist: resultArtist, actualDuration: resultDuration
            )
            guard matchResult.isAcceptable else {
                DebugLogger.log("LRCLIB", "❌ /get rejected '\(resultTitle)' by '\(resultArtist)' Δ\(String(format: "%.1f", matchResult.durationDiff)) score=\(String(format: "%.1f", matchResult.score))")
                return nil
            }

            let lyrics = parser.parseLRC(syncedLyrics)
            let score = scorer.calculateScore(lyrics, source: .lrclib, duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(
                lyrics: lyrics,
                source: .lrclib,
                score: score,
                kind: .synced,
                titleMatched: matchResult.titleMatch,
                matchedDurationDiff: matchResult.durationDiff
            )
        } catch {
            DebugLogger.log("LRCLIB", "❌ /get error for '\(title)' by '\(artist)': \(error)")
            return nil
        }
    }

    func fetchFromLRCLIBSearch(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        DebugLogger.log("LRCLIB", "🔍 /search '\(title)' by '\(artist)' (\(Int(duration))s)")
        // Boundary mapping: same one-shot string→case mapping as /get above.
        if let cached = lyricsDiskCache.get(title: title, artist: artist, duration: duration),
           LyricsSource(rawValue: cached.source) == .lrclibSearch,
           let cachedLines = cached.lines {
            let lyrics = LyricsDiskCache.lyricLines(from: cachedLines)
            if !lyrics.isEmpty {
                let score = scorer.calculateScore(lyrics, source: .lrclibSearch, duration: duration, translationEnabled: translationEnabled)
                return LyricsFetchResult(
                    lyrics: lyrics,
                    source: .lrclibSearch,
                    score: score,
                    kind: .synced,
                    matchedDurationDiff: cached.matchedDurationDiff
                )
            }
        }

        do {
            let headers = [
                "Accept": "application/json",
                "User-Agent": "nanoPod/1.0 (https://github.com/yinanli1917-cloud/AM-MiniPlayer)"
            ]
            var results: [[String: Any]] = []
            if let structuredURL = HTTPClient.buildURL(base: "https://lrclib.net/api/search", queryItems: [
                "track_name": title,
                "artist_name": artist
            ]),
               let (data, _) = try? await HTTPClient.getData(url: structuredURL, headers: headers, timeout: 5.0, retry: false),
               let structuredResults = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                results.append(contentsOf: structuredResults)
            }

            if results.isEmpty,
               let broadURL = HTTPClient.buildURL(base: "https://lrclib.net/api/search", queryItems: ["q": "\(title) \(artist)"]) {
                let (data, _) = try await HTTPClient.getData(url: broadURL, headers: headers, timeout: 5.0, retry: false)
                if let broadResults = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    results.append(contentsOf: broadResults)
                }
            }

            guard !results.isEmpty else {
                DebugLogger.log("LRCLIB", "❌ /search empty for '\(title)' by '\(artist)'")
                return nil
            }

            var bestMatch: (lyrics: String, score: Double, titleMatched: Bool, durationDiff: Double)?

            for result in results {
                guard let syncedLyrics = result["syncedLyrics"] as? String, !syncedLyrics.isEmpty else { continue }

                let resultTitle = result["trackName"] as? String ?? ""
                let resultArtist = result["artistName"] as? String ?? ""
                let resultDuration = Self.jsonDouble(result["duration"]) ?? 0

                let matchResult = MatchingUtils.calculateMatch(
                    targetTitle: title, targetArtist: artist, targetDuration: duration,
                    actualTitle: resultTitle, actualArtist: resultArtist, actualDuration: resultDuration
                )

                if matchResult.isAcceptable && (bestMatch == nil || matchResult.score > bestMatch!.score) {
                    bestMatch = (syncedLyrics, matchResult.score, matchResult.titleMatch, matchResult.durationDiff)
                }
            }

            guard let match = bestMatch else {
                DebugLogger.log("LRCLIB", "❌ /search no acceptable synced match for '\(title)' by '\(artist)' (\(results.count) rows)")
                return nil
            }

            let lyrics = parser.parseLRC(match.lyrics)
            let score = scorer.calculateScore(lyrics, source: .lrclibSearch, duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(
                lyrics: lyrics,
                source: .lrclibSearch,
                score: score,
                kind: .synced,
                titleMatched: match.titleMatched,
                matchedDurationDiff: match.durationDiff
            )
        } catch {
            DebugLogger.log("LRCLIB", "❌ /search error for '\(title)' by '\(artist)': \(error)")
            return nil
        }
    }

    func fetchLibraryNativeTitleAliasForeground(
        title: String,
        artist: String,
        duration: TimeInterval,
        translationEnabled: Bool,
        album: String
    ) async -> LyricsFetchResult? {
        guard LanguageUtils.isPureASCII(title),
              LanguageUtils.isPureASCII(artist),
              LanguageUtils.isLikelyEnglishTitle(title) else {
            return nil
        }
        let cachedMetadata = metadataResolver.diskCache.get(
            title: title,
            artist: artist,
            duration: duration
        )
        let cachedNativeTitle = cachedMetadata.flatMap { cached -> String? in
            guard LanguageUtils.containsCJK(cached.resolvedTitle),
                  cached.resolvedTitle != title else { return nil }
            return LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(cached.resolvedTitle)
            )
        }
        let cachedNativeArtist = cachedMetadata.flatMap { cached -> String? in
            LanguageUtils.containsChinese(cached.resolvedArtist)
                ? cached.resolvedArtist
                : nil
        }
        let discoveredNativeTitle: String?
        if let cachedNativeTitle {
            discoveredNativeTitle = cachedNativeTitle
        } else {
            discoveredNativeTitle = await discoverLibraryNativeTitleAlias(
                title: title,
                artist: artist,
                duration: duration
            )
        }
        guard let nativeTitle = discoveredNativeTitle else {
            return nil
        }

        DebugLogger.log("LRCLIB", "🧭 catalog native-title bridge: '\(title)' -> '\(nativeTitle)'")
        if let directQQ = await withHardSourceTimeout(seconds: cachedNativeTitle == nil ? 2.35 : 1.8, operation: {
            await self.fetchQQMusicUsingLibraryNativeTitleAlias(
                title: nativeTitle,
                originalTitle: title,
                originalArtist: cachedNativeArtist ?? artist,
                duration: duration,
                translationEnabled: translationEnabled
            )
        }) {
            return directQQ
        }

        var results: [LyricsFetchResult] = []
        await withTaskGroup(of: LyricsFetchResult?.self) { group in
            group.addTask {
                await self.withHardSourceTimeout(seconds: 2.35) {
                    await self.fetchQQMusicUsingLibraryNativeTitleAlias(
                        title: nativeTitle,
                        originalTitle: title,
                        originalArtist: artist,
                        duration: duration,
                        translationEnabled: translationEnabled
                    )
                }
            }
            group.addTask {
                await self.withHardSourceTimeout(seconds: 2.35) {
                    await self.fetchResolvedTitleKeyedSources(
                        title: nativeTitle,
                        artist: artist,
                        originalTitle: title,
                        originalArtist: artist,
                        duration: duration,
                        translationEnabled: translationEnabled,
                        album: album
                    )
                }
            }

            for await result in group {
                guard let result else { continue }
                results.append(result)
                if result.kind == .synced,
                   result.score >= 35,
                   (result.titleMatched || result.nativeAliasMatched || (result.matchedDurationDiff.map { $0 < 1.5 } ?? false)) {
                    group.cancelAll()
                    break
                }
            }
        }
        return selectBestResult(from: results, songDuration: duration)
    }

    func fetchQQMusicUsingLibraryNativeTitleAlias(
        title nativeTitle: String,
        originalTitle: String,
        originalArtist: String,
        duration: TimeInterval,
        translationEnabled: Bool
    ) async -> LyricsFetchResult? {
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        let keyword = "\(nativeTitle) \(originalArtist)"
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1845],
            "req": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": ["num_per_page": 10, "page_num": 1, "query": keyword, "search_type": 0] as [String: Any]
            ] as [String: Any]
        ]

        struct AliasQQCandidate {
            let songMid: String
            let songID: Int
            let title: String
            let artist: String
            let album: String
            let durationDiff: Double
            let resultIndex: Int
        }

        do {
            let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 2.4)
            guard let reqDict = json["req"] as? [String: Any],
                  let dataDict = reqDict["data"] as? [String: Any],
                  let bodyDict = dataDict["body"] as? [String: Any],
                  let songDict = bodyDict["song"] as? [String: Any],
                  let songs = songDict["list"] as? [[String: Any]] else {
                return nil
            }
            let simplifiedNativeTitle = LanguageUtils.toSimplifiedChinese(
                LanguageUtils.normalizeTrackName(nativeTitle)
            )
            let backingTrackMarkers = ["karaoke", "instrumental", "伴奏", "カラオケ", "オリジナル・カラオケ"]
            let candidates = songs.prefix(10).enumerated().compactMap { index, song -> AliasQQCandidate? in
                guard let songMid = song["mid"] as? String,
                      let songID = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let interval = song["interval"] as? Int else { return nil }
                let artist = (song["singer"] as? [[String: Any]]).map { self.joinedProviderArtists($0) } ?? ""
                let album = (song["album"] as? [String: Any])?["name"] as? String ?? ""
                let lowerIdentity = (name + " " + album).lowercased()
                guard !backingTrackMarkers.contains(where: { lowerIdentity.contains($0) }) else { return nil }
                guard isTitleMatch(input: nativeTitle, result: name, simplifiedInput: simplifiedNativeTitle) else {
                    return nil
                }
                let durationDiff = abs(Double(interval) - duration)
                guard durationDiff < 1.5 else { return nil }
                let artistOK = isArtistMatch(
                    input: originalArtist,
                    result: artist,
                    simplifiedInput: LanguageUtils.toSimplifiedChinese(originalArtist)
                )
                let crossScriptArtistOK = LanguageUtils.isPureASCII(originalArtist)
                    && LanguageUtils.containsCJK(artist)
                    && LanguageUtils.containsCJK(name)
                guard artistOK || crossScriptArtistOK else { return nil }
                return AliasQQCandidate(
                    songMid: songMid,
                    songID: songID,
                    title: name,
                    artist: artist,
                    album: album,
                    durationDiff: durationDiff,
                    resultIndex: index
                )
            }
            .sorted {
                if $0.durationDiff != $1.durationDiff { return $0.durationDiff < $1.durationDiff }
                return $0.resultIndex < $1.resultIndex
            }
            guard let candidate = candidates.first else {
                DebugLogger.log("QQMusic", "❌ library native-title bridge found no safe row for '\(nativeTitle)' by '\(originalArtist)'")
                return nil
            }
            let musicuLyrics = await fetchQQMusicLyricsViaMusicu(
                songMid: candidate.songMid,
                songID: candidate.songID,
                duration: duration
            )
            let legacyLyrics = musicuLyrics == nil
                ? await fetchQQMusicLyrics(songMid: candidate.songMid, duration: duration)
                : nil
            guard let result = musicuLyrics ?? legacyLyrics else {
                DebugLogger.log("QQMusic", "❌ library native-title bridge lyrics unavailable for songMid=\(candidate.songMid)")
                return catalogUnavailableResult(
                    source: .qq,
                    albumMatched: false,
                    titleMatched: true,
                    durationDiff: candidate.durationDiff
                )
            }
            let rawScore = scorer.calculateScore(
                result.lyrics,
                source: .qq,
                duration: duration,
                translationEnabled: translationEnabled,
                kind: result.kind
            )
            let score = scoreWithCatalogEvidence(
                baseScore: rawScore,
                lyrics: result.lyrics,
                kind: result.kind,
                albumMatched: false,
                titleMatched: true,
                durationDiff: candidate.durationDiff,
                nativeAliasMatched: true
            )
            DebugLogger.log("QQMusic", "✅ library native-title bridge hit: '\(candidate.title)' by '\(candidate.artist)' Δ\(String(format: "%.1f", candidate.durationDiff))s")
            return LyricsFetchResult(
                lyrics: result.lyrics,
                source: .qq,
                score: score,
                kind: result.kind,
                albumMatched: false,
                titleMatched: true,
                matchedDurationDiff: candidate.durationDiff,
                nativeAliasMatched: true
            )
        } catch {
            DebugLogger.log("QQMusic", "❌ library native-title bridge error for '\(nativeTitle)' by '\(originalArtist)': \(error)")
            return nil
        }
    }

    private func fetchQQMusicLyricsViaMusicu(
        songMid: String,
        songID: Int,
        duration: TimeInterval
    ) async -> (lyrics: [LyricLine], kind: LyricsKind)? {
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }
        let body: [String: Any] = [
            "comm": ["ct": 19, "cv": 1845],
            "lyric": [
                "method": "GetPlayLyricInfo",
                "module": "music.musichallSong.PlayLyricInfo",
                "param": ["songMID": songMid, "songID": songID] as [String: Any]
            ] as [String: Any]
        ]

        do {
            let json = try await HTTPClient.postJSON(url: apiURL, body: body, timeout: 1.8)
            guard let lyricDict = json["lyric"] as? [String: Any],
                  let dataDict = lyricDict["data"] as? [String: Any],
                  let encodedLyric = dataDict["lyric"] as? String,
                  !encodedLyric.isEmpty,
                  let lyricData = Data(base64Encoded: encodedLyric),
                  let lyricText = String(data: lyricData, encoding: .utf8),
                  !lyricText.isEmpty else {
                return nil
            }
            if isInstrumentalNotice(lyricText) {
                return ([LyricLine(text: lyricText, startTime: 0, endTime: duration)], .instrumental)
            }

            let parsed = parser.parseLRC(lyricText)
            var lyrics: [LyricLine]
            var resultKind: LyricsKind = .synced
            if parsed.isEmpty {
                lyrics = parser.createUnsyncedLyrics(lyricText, duration: duration)
                resultKind = .unsynced
            } else {
                lyrics = parser.stripMetadataLines(parsed)
                resultKind = parser.detectKind(lyrics)
            }

            if let encodedTrans = dataDict["trans"] as? String,
               !encodedTrans.isEmpty,
               let transData = Data(base64Encoded: encodedTrans),
               let transText = String(data: transData, encoding: .utf8),
               !transText.isEmpty {
                let translatedLyrics = parser.stripMetadataLines(parser.parseLRC(transText))
                if !translatedLyrics.isEmpty {
                    lyrics = parser.mergeLyricsWithTranslation(original: lyrics, translated: translatedLyrics)
                }
            }

            lyrics = removingStandaloneSpeakerLabelLines(lyrics)
            lyrics = parser.stripChineseTranslations(lyrics)
            let final = resultKind == .synced
                ? parser.applyTimeOffset(to: lyrics, offset: qqTimeOffset)
                : lyrics
            return (final, resultKind)
        } catch {
            return nil
        }
    }

    private func removingStandaloneSpeakerLabelLines(_ lyrics: [LyricLine]) -> [LyricLine] {
        lyrics.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasSuffix(":") || text.hasSuffix("：") else { return true }
            let label = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label.count <= 6 else { return true }
            let isSpeakerLabel = label.unicodeScalars.allSatisfy { scalar in
                CharacterSet.letters.contains(scalar) || LanguageUtils.isCJKScalar(scalar)
            }
            return !isSpeakerLabel
        }
    }

    func libraryNativeTitleAliasForTesting(resultTitle: String, inputTitle: String) -> String? {
        libraryNativeTitleAlias(resultTitle: resultTitle, inputTitle: inputTitle)
    }

    private func discoverLibraryNativeTitleAlias(
        title: String,
        artist: String,
        duration: TimeInterval
    ) async -> String? {
        let headers = [
            "Accept": "application/json",
            "User-Agent": "nanoPod/1.0 (https://github.com/yinanli1917-cloud/AM-MiniPlayer)"
        ]
        guard let url = HTTPClient.buildURL(base: "https://lrclib.net/api/search", queryItems: [
            "track_name": title,
            "artist_name": artist
        ]) else { return nil }

        guard let (data, _) = try? await HTTPClient.getData(url: url, headers: headers, timeout: 1.5, retry: false),
              let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for result in results.prefix(8) {
            guard let resultTitle = result["trackName"] as? String,
                  let resultArtist = result["artistName"] as? String,
                  MatchingUtils.isArtistMatch(target: artist, actual: resultArtist),
                  let resultDuration = Self.jsonDouble(result["duration"]),
                  abs(resultDuration - duration) < 1.5,
                  let alias = libraryNativeTitleAlias(resultTitle: resultTitle, inputTitle: title) else {
                continue
            }
            return alias
        }
        return nil
    }

    private func libraryNativeTitleAlias(resultTitle: String, inputTitle: String) -> String? {
        guard LanguageUtils.containsCJK(resultTitle),
              latinEvidenceKey(resultTitle).contains(latinEvidenceKey(inputTitle)) else {
            return nil
        }
        let separators = CharacterSet(charactersIn: "-–—|｜/／()（）[]【】")
        let disallowedMarkers = [
            "live", "remix", "instrumental", "karaoke", "cover", "dj",
            "现场", "現場", "伴奏", "翻唱", "纯音乐", "純音樂"
        ]
        return resultTitle
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { segment in
                let normalized = LanguageUtils.normalizeTrackName(segment)
                let cjkCount = normalized.unicodeScalars.filter { LanguageUtils.isCJKScalar($0) }.count
                let lower = normalized.lowercased()
                return cjkCount >= 2
                    && cjkCount <= 16
                    && !disallowedMarkers.contains(where: { lower.contains($0) })
            }
            .map { LanguageUtils.toSimplifiedChinese(LanguageUtils.normalizeTrackName($0)) }
    }

    private static func jsonDouble(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    // MARK: - lyrics.ovh

    func fetchFromLyricsOVH(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        let normalizedTitle = LanguageUtils.normalizeTrackName(title)
        let normalizedArtist = LanguageUtils.normalizeArtistName(artist)

        guard let encodedArtist = normalizedArtist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = normalizedTitle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)") else { return nil }

        do {
            // 🔑 lyrics.ovh 是纯文本备选源（最低优先级），缩短超时避免拖慢整体
            let json = try await HTTPClient.getJSON(url: url, timeout: 2.0, retry: false)
            guard let lyricsText = json["lyrics"] as? String, !lyricsText.isEmpty else { return nil }

            let lyrics = parser.createUnsyncedLyrics(lyricsText, duration: duration)
            let score = scorer.calculateScore(lyrics, source: .lyricsOvh, duration: duration, translationEnabled: translationEnabled, kind: .unsynced)
            return LyricsFetchResult(lyrics: lyrics, source: .lyricsOvh, score: score, kind: .unsynced)
        } catch {
            return nil
        }
    }

    // MARK: - Genius（纯文本备选源，覆盖面最广）

    func fetchFromGenius(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        guard let searchURL = HTTPClient.buildURL(
            base: "https://genius.com/api/search/song",
            queryItems: ["q": "\(title) \(artist)", "per_page": "5"]
        ) else { return nil }
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]

        do {
            // 1. 搜索 → 验证标题/艺术家 → 歌词页路径
            let searchJSON = try await HTTPClient.getJSON(url: searchURL, headers: headers, timeout: 2.0, retry: false)
            guard let response = searchJSON["response"] as? [String: Any],
                  let sections = response["sections"] as? [[String: Any]],
                  let hits = sections.first?["hits"] as? [[String: Any]] else { return nil }
            let simplifiedTitle = LanguageUtils.toSimplifiedChinese(title)
            let simplifiedArtist = LanguageUtils.toSimplifiedChinese(artist)
            var matchedPath: String?
            for hit in hits {
                guard let r = hit["result"] as? [String: Any],
                      let hitTitle = r["title"] as? String, let p = r["path"] as? String else { continue }
                let hitArtist = r["artist_names"] as? String ?? ""
                let titleOK = isTitleMatch(input: title, result: hitTitle, simplifiedInput: simplifiedTitle)
                let artistOK = isArtistMatch(input: artist, result: hitArtist, simplifiedInput: simplifiedArtist)
                let aliasArtistOK = titleOK && hasDistinctiveArtistTokenOverlap(artist, hitArtist)
                if titleOK && (artistOK || aliasArtistOK) { matchedPath = p; break }
            }
            guard let path = matchedPath, let pageURL = URL(string: "https://genius.com\(path)") else { return nil }

            // 2. 抓取 HTML → 提取歌词
            let (data, _) = try await HTTPClient.getData(url: pageURL, headers: headers, timeout: 2.0, retry: false)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            let lyricsText = Self.extractGeniusLyrics(from: html)
            guard !lyricsText.isEmpty else { return nil }

            let lyrics = parser.createUnsyncedLyrics(lyricsText, duration: duration)
            let score = scorer.calculateScore(lyrics, source: .genius, duration: duration, translationEnabled: translationEnabled, kind: .unsynced)
            return LyricsFetchResult(lyrics: lyrics, source: .genius, score: score, kind: .unsynced)
        } catch { return nil }
    }

    /// 从 Genius HTML 提取 data-lyrics-container 中的歌词纯文本
    static func extractGeniusLyrics(from html: String) -> String {
        let pattern = #"data-lyrics-container="true"[^>]*>(.*?)</div>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return "" }
        let entityMap = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'"]
        var lines: [String] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            var fragment = String(html[range])
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            for (entity, char) in entityMap { fragment = fragment.replacingOccurrences(of: entity, with: char) }
            let geniusMeta = #"^\d+\s+Contributor"#
            lines.append(contentsOf: fragment.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.range(of: geniusMeta, options: .regularExpression) == nil })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Apple Music Catalog (MusicKit / MusicDataRequest)

    func appleMusicCatalogIdentityMatches(
        inputTitle: String,
        inputArtist: String,
        inputAlbum: String,
        inputDuration: TimeInterval,
        catalogTitle: String,
        catalogArtist: String,
        catalogAlbum: String,
        catalogDuration: TimeInterval
    ) -> Bool {
        guard abs(catalogDuration - inputDuration) < 3.0 else { return false }
        let inputTitleNorm = LanguageUtils.normalizeTrackName(inputTitle).lowercased()
        let inputArtistNorm = LanguageUtils.normalizeArtistName(inputArtist).lowercased()
        let inputAlbumNorm = LanguageUtils.normalizeTrackName(inputAlbum).lowercased()
        let catalogTitleNorm = LanguageUtils.normalizeTrackName(catalogTitle).lowercased()
        let catalogArtistNorm = LanguageUtils.normalizeArtistName(catalogArtist).lowercased()
        let catalogAlbumNorm = LanguageUtils.normalizeTrackName(catalogAlbum).lowercased()
        let titleOK = catalogTitleNorm == inputTitleNorm
            || catalogTitleNorm.contains(inputTitleNorm)
            || inputTitleNorm.contains(catalogTitleNorm)
        let artistOK = catalogArtistNorm == inputArtistNorm
            || catalogArtistNorm.contains(inputArtistNorm)
            || inputArtistNorm.contains(catalogArtistNorm)
        let albumOK = !inputAlbumNorm.isEmpty
            && !catalogAlbumNorm.isEmpty
            && (catalogAlbumNorm == inputAlbumNorm
                || catalogAlbumNorm.contains(inputAlbumNorm)
                || inputAlbumNorm.contains(catalogAlbumNorm))
        let crossScriptCatalogOK = titleOK
            && abs(catalogDuration - inputDuration) < 1.0
            && LanguageUtils.isPureASCII(inputArtist)
            && LanguageUtils.containsCJK(catalogArtist)
        return titleOK && (artistOK || albumOK || crossScriptCatalogOK)
    }

    func fetchFromAppleMusic(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        do {
            // Step 1: locate the song in Apple's catalog
            var request = MusicCatalogSearchRequest(term: "\(title) \(artist)", types: [Song.self])
            request.limit = 8
            let response = try await request.response()
            guard !response.songs.isEmpty else {
                DebugLogger.log("AppleMusic", "❌ catalog search empty for '\(title)' by '\(artist)'")
                return nil
            }

            // Step 2: pick the song whose title + artist + duration align
            let matched: Song? = response.songs.first { s in
                appleMusicCatalogIdentityMatches(
                    inputTitle: title,
                    inputArtist: artist,
                    inputAlbum: album,
                    inputDuration: duration,
                    catalogTitle: s.title,
                    catalogArtist: s.artistName,
                    catalogAlbum: s.albumTitle ?? "",
                    catalogDuration: s.duration ?? 0
                )
            }
            guard let song = matched else {
                DebugLogger.log("AppleMusic", "❌ no catalog match for '\(title)' by '\(artist)'")
                return nil
            }
            guard song.hasLyrics else {
                DebugLogger.log("AppleMusic", "❌ song.hasLyrics=false for '\(song.title)' by '\(song.artistName)'")
                return nil
            }

            // Step 3: fetch the lyrics endpoint via MusicDataRequest
            let storefront = try await MusicDataRequest.currentCountryCode
            guard let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/songs/\(song.id.rawValue)/lyrics") else { return nil }
            let dataRequest = MusicDataRequest(urlRequest: URLRequest(url: url))
            let dataResponse = try await dataRequest.response()
            guard let json = try JSONSerialization.jsonObject(with: dataResponse.data) as? [String: Any],
                  let dataArr = json["data"] as? [[String: Any]],
                  let first = dataArr.first,
                  let attrs = first["attributes"] as? [String: Any],
                  let ttml = attrs["ttml"] as? String,
                  !ttml.isEmpty else {
                DebugLogger.log("AppleMusic", "❌ lyrics response had no TTML")
                return nil
            }

            guard let parsed = parser.parseTTML(ttml), !parsed.isEmpty else {
                DebugLogger.log("AppleMusic", "❌ parseTTML returned 0 lines")
                return nil
            }
            let kind: LyricsKind = .synced
            let score = scorer.calculateScore(parsed, source: .appleMusic, duration: duration, translationEnabled: translationEnabled, kind: kind)
            DebugLogger.log("AppleMusic", "✅ '\(title)' by '\(artist)' — \(parsed.count) lines (TTML)")
            return LyricsFetchResult(lyrics: parsed, source: .appleMusic, score: score, kind: kind)
        } catch {
            DebugLogger.log("AppleMusic", "❌ MusicDataRequest error: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - AMLL 索引条目

struct AMLLIndexEntry {
    let id: String
    let musicName: String
    let artists: [String]
    let album: String
    let rawLyricFile: String
    let platform: String
}
