/**
 * [INPUT]: Song metadata (title, artist, duration) + SearchParams from candidate selection
 * [OUTPUT]: LyricsFetchResult from each source (AMLL, NetEase, QQ, LRCLIB, lyrics.ovh, Genius, Apple Music)
 * [POS]: Source fetcher sub-module of LyricsFetcher — HTTP calls + parsing for all 7 lyric sources
 * [PROTOCOL]: Changes here → update this header, then check Services/Lyrics/CLAUDE.md
 */

import Foundation
import MusicKit

// ============================================================
// MARK: - Source Fetchers (extension of LyricsFetcher)
// ============================================================

extension LyricsFetcher {

    // MARK: - AMLL-TTML-DB

    func fetchFromAMLL(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
        // 尝试通过 Apple Music Track ID 直接获取
        if let trackId = await getAppleMusicTrackId(title: title, artist: artist, duration: duration),
           let lyrics = await fetchAMLLTTML(platform: "am-lyrics", filename: "\(trackId).ttml") {
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score, kind: .synced)
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
            // ("If", "Deep", etc.) because the global index has many exact
            // title collisions. Require artist evidence unless the title is
            // distinctive CJK/non-ASCII text.
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
            let score = scorer.calculateScore(lyrics, source: "AMLL", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(lyrics: lyrics, source: "AMLL", score: score, kind: .synced)
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
        let expectedTitleLower = expectedTitle.lowercased()
        let expectedArtistLower = expectedArtist.lowercased()
        for line in lines {
            let text = line.replacingOccurrences(of: "\\[\\d{2}:\\d{2}\\.\\d{2,3}\\]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard text.contains(" - ") else { continue }
            if text.contains(":") || text.contains("：") { continue }
            let parts = text.components(separatedBy: " - ")
            guard parts.count == 2 else { continue }
            let lineArtist = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let lineTitle = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if !lineArtist.isEmpty && !lineTitle.isEmpty
                && !lineArtist.contains(expectedArtistLower) && !expectedArtistLower.contains(lineArtist)
                && !lineTitle.contains(expectedTitleLower) && !expectedTitleLower.contains(lineTitle) {
                DebugLogger.log("NetEase", "⚠️ Content mismatch: lyrics say '\(lineArtist) - \(lineTitle)' but expected '\(expectedTitle)' by '\(expectedArtist)'")
                return false
            }
        }
        return true
    }

    func fetchFromNetEase(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        DebugLogger.log("NetEase", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s) album='\(album)'")
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration, album: album, disableCjkEscapeInP3: false)
        let headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                       "Referer": "https://music.163.com"]

        let match: SelectedSearchCandidate<Int>? = await searchAndSelectCandidate(
            params: params, source: "NetEase",
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
                if let artists = song["artists"] as? [[String: Any]],
                   let first = artists.first, let n = first["name"] as? String { artist = n }
                let dur = (song["duration"] as? Double ?? 0) / 1000.0
                var albumName = ""
                if let album = song["album"] as? [String: Any], let n = album["name"] as? String { albumName = n }
                return (id, name, artist, dur, albumName)
            }
        )

        var primaryResult: LyricsFetchResult?
        if let match {
            DebugLogger.log("NetEase", "✅ 找到 songId=\(match.id) albumMatch=\(match.albumMatched)")
            if let result = await fetchNetEaseLyrics(songId: match.id, duration: duration, expectedTitle: match.title, expectedArtist: match.artist) {
                let lyrics = result.lyrics
                let kind = result.kind
                let score = scorer.calculateScore(lyrics, source: "NetEase", duration: duration, translationEnabled: translationEnabled, kind: kind)
                let fetched = LyricsFetchResult(lyrics: lyrics, source: "NetEase", score: score, kind: kind, albumMatched: match.albumMatched, titleMatched: match.titleMatched, matchedDurationDiff: match.durationDiff)
                if score >= 35 || result.kind == .synced && result.lyrics.contains(where: { $0.hasSyllableSync }) {
                    return fetched
                }
                primaryResult = fetched
                DebugLogger.log("NetEase", "⚠️ Primary lyrics low quality (score=\(String(format: "%.1f", score))) — probing sibling catalog rows")
            }
        } else {
            DebugLogger.log("NetEase", "❌ 未找到歌曲 — trying artist-discography fallback")
        }
        DebugLogger.log("NetEase", "❌ 获取歌词失败/低质 — trying artist-discography fallback")
        // 🔑 Empty-lyrics fallback
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
        struct Cand { let id: Int; let name: String; let artist: String; let dur: Double; let delta: Double; let titleMatched: Bool; let sourceTitleAlias: Bool }
        let cands: [Cand] = songs.compactMap { s in
            guard let id = s["id"] as? Int,
                  let name = s["name"] as? String,
                  let dur = (s["duration"] as? Double).map({ $0 / 1000.0 }) else { return nil }
            if let primaryId = match?.id, id == primaryId { return nil }
            let artistName = ((s["artists"] as? [[String: Any]])?.first?["name"] as? String) ?? cjkArtistForFallback
            let delta = abs(dur - duration)
            guard delta < 20.0 else { return nil }
            let titleOK = isTitleMatch(input: params.rawTitle, result: name, simplifiedInput: simplifiedInputTitle)
                || isTitleMatch(input: params.rawOriginalTitle, result: name, simplifiedInput: params.simplifiedOriginalTitle)
            let inputTitleIsASCII = LanguageUtils.isPureASCII(params.rawTitle)
                || LanguageUtils.isPureASCII(params.rawOriginalTitle)
            let sameArtistIsCJK = LanguageUtils.containsCJK(cjkArtistForFallback)
            let resultTitleHasCJK = LanguageUtils.containsCJK(name)
            let lowerName = name.lowercased()
            let looksBackingTrack = lowerName.contains("karaoke")
                || lowerName.contains("instrumental")
                || lowerName.contains("伴奏")
                || lowerName.contains("オリジナル・カラオケ")
            let sourceTitleAlias = inputTitleIsASCII
                && sameArtistIsCJK
                && resultTitleHasCJK
                && !looksBackingTrack
                && delta < 20.0
            return Cand(id: id, name: name, artist: artistName, dur: dur, delta: delta, titleMatched: titleOK, sourceTitleAlias: sourceTitleAlias)
        }
        .filter { c in
            if c.titleMatched { return true }
            if c.sourceTitleAlias { return true }
            let inputLooksRomanized = LanguageUtils.isPureASCII(params.rawTitle)
                && (params.rawTitle.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count >= 4
                    || LanguageUtils.isLikelyRomanizedJapanese(params.rawTitle))
                && !LanguageUtils.isLikelyEnglishTitle(params.rawTitle)
            return inputLooksRomanized && LanguageUtils.containsCJK(c.name) && c.delta < 1.0
        }
        .sorted {
            if $0.sourceTitleAlias != $1.sourceTitleAlias { return $0.sourceTitleAlias && !$1.sourceTitleAlias }
            if $0.titleMatched != $1.titleMatched { return $0.titleMatched && !$1.titleMatched }
            return $0.delta < $1.delta
        }
        DebugLogger.log("NetEase", "🔁 artist-disco fallback: \(cands.count) candidates within ±15s (by title match)")
        var bestFallback: LyricsFetchResult?
        for c in cands.prefix(8) {
            if let r = await fetchNetEaseLyrics(songId: c.id, duration: duration, expectedTitle: c.name, expectedArtist: c.artist),
               !r.lyrics.isEmpty, r.lyrics.count >= 5 {
                let score = scorer.calculateScore(r.lyrics, source: "NetEase", duration: duration, translationEnabled: translationEnabled, kind: r.kind)
                let fetched = LyricsFetchResult(lyrics: r.lyrics, source: "NetEase", score: score, kind: r.kind, albumMatched: false, titleMatched: c.titleMatched, matchedDurationDiff: c.delta)
                DebugLogger.log("NetEase", "✅ fallback hit: id=\(c.id) '\(c.name)' Δ\(String(format: "%.1f", c.delta))s \(r.lyrics.count)L")
                if bestFallback == nil || score > bestFallback!.score {
                    bestFallback = fetched
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
        return primaryResult
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

            // 🔑 最后一道防线：剥离非中文歌曲中的中文翻译
            if !isYRC {
                lyrics = parser.stripChineseTranslations(lyrics)
            }

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
            var best: (artist: String, dur: Double)? = nil
            for song in songs.prefix(10) {
                guard let name = song["name"] as? String,
                      let singers = song["singer"] as? [[String: Any]],
                      let firstSinger = singers.first,
                      let singerName = firstSinger["name"] as? String,
                      let intervalInt = song["interval"] as? Int else { continue }
                let dur = Double(intervalInt)
                let titleOK = isTitleMatch(input: title, result: name, simplifiedInput: simplifiedInputTitle)
                let durOK = abs(dur - duration) < 3.0
                guard titleOK && durOK else { continue }
                guard LanguageUtils.containsCJK(singerName) else { continue }
                let thisDelta = abs(dur - duration)
                if let b = best, abs(b.dur - duration) <= thisDelta { continue }
                best = (singerName, dur)
            }
            return best?.artist
        } catch { }
        return nil
    }

    func fetchFromQQMusic(title: String, artist: String, originalTitle: String, originalArtist: String, duration: TimeInterval, translationEnabled: Bool, album: String = "") async -> LyricsFetchResult? {
        DebugLogger.log("QQMusic", "🔍 搜索: '\(title)' by '\(artist)' (\(Int(duration))s) album='\(album)'")
        let params = SearchParams(title: title, artist: artist, originalTitle: originalTitle, originalArtist: originalArtist, duration: duration, album: album, disableCjkEscapeInP3: false)
        guard let apiURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else { return nil }

        guard let qqMatch: SelectedSearchCandidate<String> = await searchAndSelectCandidate(
            params: params, source: "QQMusic",
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
                var artist = ""
                if let singers = song["singer"] as? [[String: Any]],
                   let first = singers.first, let n = first["name"] as? String { artist = n }
                let dur = Double(song["interval"] as? Int ?? 0)
                let albumName = (song["album"] as? [String: Any])?["name"] as? String ?? ""
                return (mid, name, artist, dur, albumName)
            }
        ) else {
            DebugLogger.log("QQMusic", "❌ 未找到歌曲")
            return nil
        }
        let songMid = qqMatch.id

        DebugLogger.log("QQMusic", "✅ 找到 songMid=\(songMid) albumMatch=\(qqMatch.albumMatched)")
        guard let result = await fetchQQMusicLyrics(songMid: songMid, duration: duration) else {
            DebugLogger.log("QQMusic", "❌ 获取歌词失败")
            return nil
        }
        let lyrics = result.lyrics
        let kind = result.kind
        let score = scorer.calculateScore(lyrics, source: "QQ", duration: duration, translationEnabled: translationEnabled, kind: kind)
        return LyricsFetchResult(lyrics: lyrics, source: "QQ", score: score, kind: kind, albumMatched: qqMatch.albumMatched, titleMatched: qqMatch.titleMatched, matchedDurationDiff: qqMatch.durationDiff)
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

        if let cached = lyricsDiskCache.get(title: title, artist: artist, duration: duration),
           cached.source == "LRCLIB",
           let cachedLines = cached.lines {
            let lyrics = LyricsDiskCache.lyricLines(from: cachedLines)
            if !lyrics.isEmpty {
                let score = scorer.calculateScore(lyrics, source: cached.source, duration: duration, translationEnabled: translationEnabled)
                return LyricsFetchResult(
                    lyrics: lyrics,
                    source: cached.source,
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
            let score = scorer.calculateScore(lyrics, source: "LRCLIB", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(
                lyrics: lyrics,
                source: "LRCLIB",
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
        if let cached = lyricsDiskCache.get(title: title, artist: artist, duration: duration),
           cached.source == "LRCLIB-Search",
           let cachedLines = cached.lines {
            let lyrics = LyricsDiskCache.lyricLines(from: cachedLines)
            if !lyrics.isEmpty {
                let score = scorer.calculateScore(lyrics, source: cached.source, duration: duration, translationEnabled: translationEnabled)
                return LyricsFetchResult(
                    lyrics: lyrics,
                    source: cached.source,
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
            let score = scorer.calculateScore(lyrics, source: "LRCLIB-Search", duration: duration, translationEnabled: translationEnabled)
            return LyricsFetchResult(
                lyrics: lyrics,
                source: "LRCLIB-Search",
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
            let score = scorer.calculateScore(lyrics, source: "lyrics.ovh", duration: duration, translationEnabled: translationEnabled, kind: .unsynced)
            return LyricsFetchResult(lyrics: lyrics, source: "lyrics.ovh", score: score, kind: .unsynced)
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
            let score = scorer.calculateScore(lyrics, source: "Genius", duration: duration, translationEnabled: translationEnabled, kind: .unsynced)
            return LyricsFetchResult(lyrics: lyrics, source: "Genius", score: score, kind: .unsynced)
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

    func fetchFromAppleMusic(title: String, artist: String, duration: TimeInterval, translationEnabled: Bool) async -> LyricsFetchResult? {
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
            let inputTitleNorm = LanguageUtils.normalizeTrackName(title).lowercased()
            let inputArtistNorm = LanguageUtils.normalizeArtistName(artist).lowercased()
            let matched: Song? = response.songs.first { s in
                let songDuration = s.duration ?? 0
                guard abs(songDuration - duration) < 3.0 else { return false }
                let sTitle = LanguageUtils.normalizeTrackName(s.title).lowercased()
                let sArtist = LanguageUtils.normalizeArtistName(s.artistName).lowercased()
                let titleOK = sTitle == inputTitleNorm
                    || sTitle.contains(inputTitleNorm) || inputTitleNorm.contains(sTitle)
                let artistOK = sArtist == inputArtistNorm
                    || sArtist.contains(inputArtistNorm) || inputArtistNorm.contains(sArtist)
                return titleOK && artistOK
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
            let score = scorer.calculateScore(parsed, source: "AppleMusic", duration: duration, translationEnabled: translationEnabled, kind: kind)
            DebugLogger.log("AppleMusic", "✅ '\(title)' by '\(artist)' — \(parsed.count) lines (TTML)")
            return LyricsFetchResult(lyrics: parsed, source: "AppleMusic", score: score, kind: kind)
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
