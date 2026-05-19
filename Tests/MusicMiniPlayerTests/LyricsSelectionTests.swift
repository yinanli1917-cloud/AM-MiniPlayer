import XCTest
@testable import MusicMiniPlayerCore

final class LyricsSelectionTests: XCTestCase {

    private func makeLines(_ seed: [String], wordLevel: Bool = false) -> [LyricLine] {
        seed.enumerated().map { index, text in
            let start = Double(index) * 4.0
            let end = start + 3.5
            let words: [LyricWord] = wordLevel
                ? text.split(separator: " ").enumerated().map { wordIndex, word in
                    let wordStart = start + Double(wordIndex) * 0.25
                    return LyricWord(word: String(word), startTime: wordStart, endTime: wordStart + 0.2)
                }
                : []
            return LyricLine(text: text, startTime: start, endTime: end, words: words)
        }
    }

    private func makeLines(_ seed: [String], startingAt firstStart: Double, gap: Double = 4.0) -> [LyricLine] {
        seed.enumerated().map { index, text in
            let start = firstStart + Double(index) * gap
            return LyricLine(text: text, startTime: start, endTime: start + gap - 0.5)
        }
    }

    func testArtistAliasRequiresProviderConfirmation() {
        XCTAssertTrue(
            LyricsFetcher.isConfirmedArtistAlias(
                asciiArtist: "Tanya Chua",
                providerAliases: ["Tanya Chua"]
            )
        )

        XCTAssertFalse(
            LyricsFetcher.isConfirmedArtistAlias(
                asciiArtist: "Tanya Chua",
                providerAliases: ["JJ Lin", "Sun Yanzi"]
            )
        )
    }

    func testContentConsensusBeatsWrongWordLevelOutlier() {
        let fetcher = LyricsFetcher.shared
        let wrongWordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "standing by the doorway under neon light",
                "dancing with the shadow that keeps me awake",
                "another glass is empty on the table",
                "everybody sings but nobody stays",
                "summer in the city feels borrowed",
                "the chorus keeps turning away"
            ], wordLevel: true),
            source: "NetEase",
            score: 96,
            kind: .synced
        )
        let correctSynced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "maybe learning how to live without you",
                "maybe learning how to make it through",
                "all the quiet rooms are feeling wider",
                "every little memory points to you",
                "I keep waiting for the morning",
                "I keep looking for the truth"
            ]),
            source: "LRCLIB",
            score: 52,
            kind: .synced
        )
        let correctUnsynced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "maybe learning how to live without you",
                "maybe learning how to make it through",
                "all the quiet rooms are feeling wider",
                "every little memory points to you",
                "I keep waiting for the morning",
                "I keep looking for the truth"
            ]),
            source: "lyrics.ovh",
            score: 13,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(
            from: [wrongWordLevel, correctSynced, correctUnsynced],
            songDuration: 120
        )

        XCTAssertEqual(selected?.source, "LRCLIB")
    }

    func testSingleDisagreeingSourceDoesNotOverrideWordLevelPriority() {
        let fetcher = LyricsFetcher.shared
        let wordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "standing by the doorway under neon light",
                "dancing with the shadow that keeps me awake",
                "another glass is empty on the table",
                "everybody sings but nobody stays",
                "summer in the city feels borrowed",
                "the chorus keeps turning away"
            ], wordLevel: true),
            source: "NetEase",
            score: 96,
            kind: .synced
        )
        let alternate = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "maybe learning how to live without you",
                "maybe learning how to make it through",
                "all the quiet rooms are feeling wider",
                "every little memory points to you",
                "I keep waiting for the morning",
                "I keep looking for the truth"
            ]),
            source: "LRCLIB",
            score: 42,
            kind: .synced
        )

        let selected = fetcher.selectBestResult(
            from: [wordLevel, alternate],
            songDuration: 120
        )

        XCTAssertEqual(selected?.source, "NetEase")
    }

    func testUnsyncedConsensusCanReturnStaticFallbackWhenNoSyncedSurvives() {
        let fetcher = LyricsFetcher.shared
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "when the morning comes I keep walking",
                "through the city lights and the rain",
                "every little road is calling",
                "take me back to you again",
                "I can hear the chorus rising",
                "I can feel it in my name"
            ]),
            source: "Genius",
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "when the morning comes I keep walking",
                "through the city lights and the rain",
                "every little road is calling",
                "take me back to you again",
                "I can hear the chorus rising",
                "I can feel it in my name"
            ]),
            source: "lyrics.ovh",
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, "Genius")
    }

    func testShortCJKGeniusSnippetIsNotUsedAsFallback() {
        let fetcher = LyricsFetcher.shared
        let snippet = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "曾經相逢時 回頭生疏至此",
                "如今失眠時 誰還很想要知",
                "誰在最後及時相知一輩子",
                "誰在記憶只剩名字",
                "情生不逢時",
                "誰姍姍來遲",
                "應該想起的 想一次",
                "不必掛心的 即管試一試",
                "啦啦啦"
            ]),
            source: "Genius",
            score: 20.5,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [snippet], songDuration: 120)

        XCTAssertNil(selected)
    }

    func testCompleteCJKGeniusLyricsIsNotUsedAsFallback() {
        let fetcher = LyricsFetcher.shared
        let plain = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "某些不可改變的改變",
                "與一些不要發現的發現",
                "讓我可跟你共處一室",
                "仍然能送你一束花",
                "餘生請你指教",
                "無條件為你",
                "不理會世事變改",
                "仍然能靠近你",
                "如若你喜歡怪人",
                "其實我很美"
            ]),
            source: "Genius",
            score: 21,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [plain], songDuration: 120)

        XCTAssertNil(selected)
    }

    func testExactLyricsOvhCanBeStaticFallbackWhenSyncedIsMissing() {
        let fetcher = LyricsFetcher.shared
        let plain = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "samidare wa midori iro",
                "kanashiku saseta yo",
                "koi wo shite sabishikute",
                "todokanu omoi wo atatamete ita",
                "suki da yo to iezu ni",
                "hatsukoi wa furiko zaiku no kokoro",
                "houkago no koutei wo hashiru kimi ga ita",
                "asai yume dakara mune wo hanarenai",
                "yuubae wa anzu iro",
                "kaerimichi hitori kuchibue fuite",
                "namae sae yobenakute",
                "torawareta kokoro mitsumete ita yo",
                "kaze ni matta hanabira ga",
                "minamo wo midasu you ni",
                "ima mo hanarenai",
                "mune wo hanarenai"
            ]),
            source: "lyrics.ovh",
            score: 25,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [plain], songDuration: 225)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, "lyrics.ovh")
    }

    func testUnsyncedConsensusReplacesMissingSyncedResultWithStaticFallback() {
        let fetcher = LyricsFetcher.shared
        let synced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "different timed line one",
                "different timed line two",
                "different timed line three",
                "different timed line four",
                "different timed line five",
                "different timed line six"
            ]),
            source: "LRCLIB",
            score: 35,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "when the morning comes I keep walking",
                "through the city lights and the rain",
                "every little road is calling",
                "take me back to you again",
                "I can hear the chorus rising",
                "I can feel it in my name"
            ]),
            source: "Genius",
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: "lyrics.ovh",
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [synced, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, "Genius")
    }

    func testSyncedConsensusBeatsUnsyncedConsensus() {
        let fetcher = LyricsFetcher.shared
        let syncedA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "different timed line one",
                "different timed line two",
                "different timed line three",
                "different timed line four",
                "different timed line five",
                "different timed line six"
            ]),
            source: "LRCLIB",
            score: 52,
            kind: .synced
        )
        let syncedB = LyricsFetcher.LyricsFetchResult(
            lyrics: syncedA.lyrics,
            source: "QQ",
            score: 33,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "when the morning comes I keep walking",
                "through the city lights and the rain",
                "every little road is calling",
                "take me back to you again",
                "I can hear the chorus rising",
                "I can feel it in my name"
            ]),
            source: "Genius",
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: "lyrics.ovh",
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [syncedA, syncedB, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.source, "LRCLIB")
        XCTAssertEqual(selected?.kind, .synced)
    }

    func testUnsyncedConsensusReplacesWrongSyncedOutlierWithStaticFallback() {
        let fetcher = LyricsFetcher.shared
        let wrongSynced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "another language line one",
                "another language line two",
                "another language line three",
                "another language line four",
                "another language line five",
                "another language line six"
            ]),
            source: "NetEase",
            score: 60,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "the real song starts in the morning",
                "the real song keeps moving on",
                "the real song has the same chorus",
                "the real song belongs here",
                "the real song is not the outlier",
                "the real song closes the night"
            ]),
            source: "Genius",
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: "lyrics.ovh",
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [wrongSynced, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, "Genius")
    }

    func testUnsyncedConsensusDoesNotVetoStrongWordLevelSynced() {
        let fetcher = LyricsFetcher.shared
        let strongSynced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "サングラスかけたまま",
                "時の流れを見つめてる",
                "Weekend",
                "真昼のネオンきらめく街",
                "ハンバーガーほおばって",
                "私たちStreet dancer"
            ], wordLevel: true),
            source: "NetEase",
            score: 99,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "サングラスかけたままSangurasu kaketa mama",
                "時の流れを見つめてるToki no nagare wo mitsume teru",
                "Weekend mahiru no neon",
                "私たちstreet dancer",
                "七色の虹よ",
                "心がある私たちstreet dancer"
            ]),
            source: "lyrics.ovh",
            score: 27,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: "Genius",
            score: 6,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [strongSynced, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.source, "NetEase")
        XCTAssertEqual(selected?.kind, .synced)
    }

    func testTitleEvidenceBeatsLooseSameDurationEscape() {
        let fetcher = LyricsFetcher.shared
        let directTitle = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "原谅我最近在低潮期",
                "有些话我讲得不好听",
                "可能因为实在太熟悉",
                "下意识对你像对我自己",
                "生活总是不太容易",
                "总有些压力"
            ]),
            source: "NetEase",
            score: 74,
            kind: .synced,
            titleMatched: true
        )
        let looseEscape = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "千金难买的 换不回来的",
                "取之不尽的 永无止境的",
                "篝火还没熄灭 海风吹来有点凉",
                "星星伴着沙滩 月光守着海浪",
                "车灯照向远方 什么都看不到",
                "仿佛宇宙只剩孤独的我们俩"
            ]),
            source: "NetEase",
            score: 80,
            kind: .synced,
            titleMatched: false
        )

        let selected = fetcher.selectBestResult(from: [looseEscape, directTitle], songDuration: 120)

        XCTAssertEqual(selected?.firstLineText, "原谅我最近在低潮期")
    }

    func testSevereTailGapFallsBackToStaticConsensusWhenSyncedIsMistimed() {
        let fetcher = LyricsFetcher.shared
        let mistimed = LyricsFetcher.LyricsFetchResult(
            lyrics: [
                LyricLine(text: "Every time you lie in my place", startTime: 10, endTime: 14),
                LyricLine(text: "I do want to say", startTime: 20, endTime: 24),
                LyricLine(text: "Only you can conquer time", startTime: 150, endTime: 154)
            ],
            source: "LRCLIB",
            score: 55,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "Every time you lie in my place",
                "I do want to say",
                "It's you, you my babe",
                "I won't be too late",
                "My Jinji don't you cry",
                "This world out of time",
                "Only you can conquer time",
                "Only you can conquer time",
                "Oh don't leave me behind",
                "Without you I would cry",
                "Cause only you my baby",
                "Only you can conquer time",
                "Oh sometimes I",
                "Without you I would cry",
                "Cause only you my baby",
                "Only you can conquer time",
                "Oh don't leave me behind",
                "Without you I will cry",
                "Cause only you my baby",
                "Only you can conquer time",
                "Only you can conquer time"
            ]),
            source: "Genius",
            score: 15,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: "lyrics.ovh",
            score: 13,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [mistimed, plainA, plainB], songDuration: 300)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, "Genius")
    }

    func testLateFirstVocalTimelineIsRejected() {
        let fetcher = LyricsFetcher.shared
        let lateSynced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "...",
                "you know I never found you",
                "walking through the city",
                "waiting for the evening",
                "nothing ever changes",
                "call me in the morning"
            ], startingAt: 183),
            source: "NetEase",
            score: 42,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.5
        )

        let selected = fetcher.selectBestResult(from: [lateSynced], songDuration: 248)

        XCTAssertNil(selected)
    }

    func testEnglishContractionVariantsCoverApostropheMissingTitles() {
        XCTAssertEqual(
            LyricsFetcher.englishContractionVariants("Its Just A Matter Of Time"),
            ["it's Just A Matter Of Time"]
        )
    }

    func testArtistProbeVariantsConvertWadeGilesNames() {
        let probes = LyricsFetcher.shared.artistProbeVariants("Lee Chih Ching")

        XCTAssertTrue(probes.contains("li zhi qin"))
        XCTAssertTrue(probes.contains("lizhiqin"))
    }

    func testCJKArtistDoesNotMatchFanSuffix() {
        let fetcher = LyricsFetcher.shared

        XCTAssertTrue(
            fetcher.isArtistMatch(
                input: "王力宏",
                result: "王力宏",
                simplifiedInput: "王力宏"
            )
        )
        XCTAssertFalse(
            fetcher.isArtistMatch(
                input: "王力宏",
                result: "王力宏的小迷妹",
                simplifiedInput: "王力宏"
            )
        )
    }

    func testCJKArtistMatchesWithinProviderArtistList() {
        let fetcher = LyricsFetcher.shared

        XCTAssertTrue(
            fetcher.isArtistMatch(
                input: "陈妍希",
                result: "陈晓 / 陈妍希",
                simplifiedInput: "陈妍希"
            )
        )
        XCTAssertFalse(
            fetcher.isArtistMatch(
                input: "陈妍希",
                result: "陈晓 / 杨丞琳",
                simplifiedInput: "陈妍希"
            )
        )
    }

    func testCompactRomanizedTitleMatchesProviderParticleSpacing() {
        let fetcher = LyricsFetcher.shared

        XCTAssertTrue(
            fetcher.isTitleMatch(
                input: "Namidanokatachino Earring",
                result: "Namidano katachino Earring",
                simplifiedInput: "namidanokatachino earring"
            )
        )
    }

    func testCompactRomanizedTitleDropsBackingTrackAndAllowsConfirmedSearchArtist() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "Namidanokatachino Earring",
            artist: "Akina Nakamori",
            originalTitle: "Namidanokatachino Earring",
            originalArtist: "Akina Nakamori",
            duration: 276
        )
        let songs: [[String: Any]] = [
            [
                "id": 1,
                "name": "Namida No Katachi No Earring (Instrumental) [2014 Remaster]",
                "artist": "Akina Nakamori",
                "duration": 267.9,
                "album": "北ウイング (+5) [2014 Remaster]"
            ],
            [
                "id": 2,
                "name": "Namidano katachino Earring",
                "artist": "中森明菜",
                "duration": 265.0,
                "album": "COMPLETE SINGLE COLLECTIONS ~FIRST TEN YEARS"
            ]
        ]

        let candidates: [LyricsFetcher.SearchCandidate<Int>] = fetcher.buildCandidates(
            songs: songs,
            params: params,
            searchDescriptor: "title+artist",
            extractSong: { song in
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let artist = song["artist"] as? String,
                      let duration = song["duration"] as? Double,
                      let album = song["album"] as? String else { return nil }
                return (id, name, artist, duration, album)
            }
        )

        XCTAssertFalse(candidates.contains { $0.id == 1 })
        let vocal = candidates.first { $0.id == 2 }
        XCTAssertEqual(vocal?.titleMatch, true)
        XCTAssertEqual(vocal?.artistMatch, true)
    }

    func testConfirmedCJKArtistAliasCanSelectNativeEnglishTitleTranslation() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "The Key",
                artist: "Craig Ruhnke",
                album: "Sweet Feelings",
                durationDiff: 5.3,
                titleMatch: true,
                artistMatch: false,
                albumMatch: false,
                normalizedNameLength: 7,
                resultIndex: 0,
                searchDescriptor: "alias+title:林俊杰"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "关键词",
                artist: "林俊杰",
                album: "和自己对话",
                durationDiff: 2.3,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 1,
                searchDescriptor: "alias+title:林俊杰"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: "NetEase",
            inputTitle: "The Key",
            inputArtist: "JJ Lin",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected?.nativeAliasMatched, true)
    }

    func testEnglishTitleDoesNotUseArtistOnlyNativeAlias() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 34324547,
                name: "爱如初见",
                artist: "陈晓 / 陈妍希",
                album: "热门华语280",
                durationDiff: 6.2,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 4,
                resultIndex: 4,
                searchDescriptor: "alias artist only:陈妍希"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: "NetEase",
            inputTitle: "This Is My Love",
            inputArtist: "Michelle Chen",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected)
    }

    func testSingleWordEnglishTitleUsesOnlyTightNativeArtistAlias() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "坠落",
                artist: "蔡健雅",
                album: "天使与魔鬼的对话",
                durationDiff: 6.1,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 2,
                resultIndex: 1,
                searchDescriptor: "alias+title:蔡健雅"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "无底洞",
                artist: "蔡健雅",
                album: "I Do Believe",
                durationDiff: 1.3,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 0,
                searchDescriptor: "alias artist only:蔡健雅"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: "NetEase",
            inputTitle: "Deep",
            inputArtist: "Tanya Chua",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
    }

    func testCompressedFastLineTimedVersionIsRejected() {
        let fetcher = LyricsFetcher.shared
        let fastVersion = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "******Music******",
                "愛神也有苦惱",
                "問他可知道",
                "看看我的心似是醉了櫻桃",
                "人如熟了櫻桃",
                "愛情常向窗邊低訴",
                "恨他不知道",
                "但願今夕在情人夢里",
                "寫下痴心記號",
                "甜蜜是這戀愛預告"
            ], startingAt: 0.8, gap: 18.0),
            source: "NetEase",
            score: 51.6,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(from: [fastVersion], songDuration: 218.839)

        XCTAssertNil(selected)
    }

    func testAppleCatalogAllowsLocalizedArtistForExactTitleDuration() {
        let fetcher = LyricsFetcher.shared

        XCTAssertTrue(
            fetcher.appleMusicCatalogIdentityMatches(
                inputTitle: "This Is My Love",
                inputArtist: "Michelle Chen",
                inputAlbum: "Young Stars",
                inputDuration: 312,
                catalogTitle: "This Is My Love",
                catalogArtist: "陳冠蒨",
                catalogAlbum: "脫掉制服",
                catalogDuration: 312
            )
        )
    }

    func testUnavailableCatalogIdentityAllowsLooseExactTitleDuration() {
        let fetcher = LyricsFetcher.shared
        let unavailable = LyricsFetcher.LyricsFetchResult(
            lyrics: [],
            source: "NetEase",
            score: -80,
            kind: .unavailable,
            titleMatched: true,
            matchedDurationDiff: 7.8
        )

        let selected = fetcher.selectUnavailableResult(from: [unavailable])

        XCTAssertEqual(selected?.source, "NetEase")
    }

    func testNativeAliasDoesNotBeatExplicitSameArtistTitleEvidence() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "駅",
                artist: "中森明菜",
                album: "CRIMSON",
                durationDiff: 16.6,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 1,
                resultIndex: 0,
                searchDescriptor: "alias+title:中森明菜"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "Second Love",
                artist: "中森明菜",
                album: "Akina Box",
                durationDiff: 17.2,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 11,
                resultIndex: 1,
                searchDescriptor: "title+artist"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: "NetEase",
            inputTitle: "Second Love",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected?.matchRank, 2)
    }

    func testCJKExactTitleArtistCanUseBoundedLooseDuration() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "江山（剧集《洪武三十二》主题曲）",
                artist: "馬德鍾",
                album: "江山（剧集《洪武三十二》主题曲）",
                durationDiff: 27,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 16,
                resultIndex: 0,
                searchDescriptor: ""
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: "NetEase",
            inputTitle: "江山"
        )

        XCTAssertEqual(selected?.id, 1)
        XCTAssertEqual(selected?.matchRank, 2)
    }
}

private extension LyricsFetcher.LyricsFetchResult {
    var firstLineText: String? {
        lyrics.first?.text
    }
}
