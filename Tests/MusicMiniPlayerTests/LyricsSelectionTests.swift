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

    private func makeCompleteStaticLyrics(prefix: String) -> [LyricLine] {
        makeLines((1...20).map { "\(prefix) corroborated lyric line \($0) through the night" })
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

    func testOrphanExactTitleFallbackIsBoundedToDistinctiveCJKAndTightDuration() {
        let fetcher = LyricsFetcher.shared

        XCTAssertTrue(fetcher.isSafeNetEaseOrphanExactTitleCandidate(
            inputTitle: "忘记有时",
            originalTitle: "忘记有时",
            candidateTitle: "忘记有时",
            durationDiff: 0.11
        ))

        XCTAssertFalse(fetcher.isSafeNetEaseOrphanExactTitleCandidate(
            inputTitle: "初恋",
            originalTitle: "初恋",
            candidateTitle: "初恋",
            durationDiff: 0.11
        ))

        XCTAssertFalse(fetcher.isSafeNetEaseOrphanExactTitleCandidate(
            inputTitle: "忘记有时",
            originalTitle: "忘记有时",
            candidateTitle: "忘记有时",
            durationDiff: 2.0
        ))

        XCTAssertFalse(fetcher.isSafeNetEaseOrphanExactTitleCandidate(
            inputTitle: "忘记有时",
            originalTitle: "忘记有时",
            candidateTitle: "我们曾经白头到老",
            durationDiff: 0.11
        ))
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
            source: .netEase,
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
            source: .lrclib,
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
            source: .lyricsOvh,
            score: 13,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(
            from: [wrongWordLevel, correctSynced, correctUnsynced],
            songDuration: 120
        )

        XCTAssertEqual(selected?.source, .lrclib)
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
            source: .netEase,
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
            source: .lrclib,
            score: 42,
            kind: .synced
        )

        let selected = fetcher.selectBestResult(
            from: [wordLevel, alternate],
            songDuration: 120
        )

        XCTAssertEqual(selected?.source, .netEase)
    }

    func testSameIdentityWordLevelBeatsAlbumMatchedLineSync() {
        let fetcher = LyricsFetcher.shared
        let sharedText = [
            "浪漫節日燈飾太亮掩蓋了隱憂",
            "情人陪同來到多擠迫的關口",
            "沿路有千百人在一起倒數",
            "霓虹燈照著我一個人走",
            "寒風中記低未完成的夢",
            "誰還留在街角等候",
            "若然明日天色仍舊",
            "我都想再向前走"
        ]
        let albumLineSync = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines(sharedText),
            source: .lrclibSearch,
            score: 82,
            kind: .synced,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        let wordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines(sharedText, wordLevel: true),
            source: .netEase,
            score: 76,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(
            from: [albumLineSync, wordLevel],
            songDuration: 40
        )

        XCTAssertEqual(selected?.source, .netEase)
        XCTAssertTrue(selected?.lyrics.contains(where: { $0.hasSyllableSync }) == true)
    }

    func testNetEaseWordLevelSiblingOverridesAlbumMatchedCreditLineSync() {
        let fetcher = LyricsFetcher.shared
        let albumLineSync = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "後期；樸總監",
                "浪漫節日燈飾太亮",
                "情人陪同來到多擠迫的關口",
                "沿路有千百人在一起倒數",
                "霓虹燈照著我一個人走",
                "寒風中記低未完成的夢",
                "誰還留在街角等候",
                "若然明日天色仍舊"
            ], startingAt: 15.2, gap: 4.3),
            source: .netEase,
            score: 75,
            kind: .synced,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        let wordLevelSibling = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "浪漫 節日 燈飾 太亮 掩蓋 了 隱憂",
                "情人 陪同 來到 多 擠迫 的 關口",
                "沿路 有 千百人 在 一起 倒數",
                "霓虹燈 照著 我 一個人 走",
                "寒風 中 記低 未完成 的 夢",
                "誰 還 留在 街角 等候",
                "若然 明日 天色 仍舊",
                "我 都 想 再 向前 走"
            ], wordLevel: true),
            source: .netEase,
            score: 66,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        XCTAssertTrue(fetcher.shouldPreferNetEaseAuthoritativeSiblingForTesting(
            sibling: wordLevelSibling,
            primary: albumLineSync,
            duration: 256
        ))
    }

    func testNetEaseWordLevelSiblingCanReplaceOverSegmentedGenericSingleAlbumVersion() {
        let fetcher = LyricsFetcher.shared
        let overSegmentedAlbumMatch = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "浪漫 節日 燈飾 太亮",
                "掩蓋 了 隱憂",
                "情人 陪同 來到",
                "多 擠迫 的 關口",
                "沿路 有 千百人",
                "在 一起 倒數",
                "霓虹燈 照著 我",
                "一個人 走"
            ], wordLevel: true),
            source: .netEase,
            score: 100,
            kind: .synced,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 2.3
        )
        let canonicalSibling = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "浪漫 節日 燈飾 太亮 掩蓋 了 隱憂",
                "情人 陪同 來到 多 擠迫 的 關口",
                "沿路 有 千百人 在 一起 倒數",
                "霓虹燈 照著 我 一個人 走",
                "寒風 中 記低 未完成 的 夢",
                "誰 還 留在 街角 等候"
            ], wordLevel: true),
            source: .netEase,
            score: 100,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 1.8
        )

        XCTAssertTrue(fetcher.shouldPreferNetEaseAuthoritativeSiblingForTesting(
            sibling: canonicalSibling,
            primary: overSegmentedAlbumMatch,
            duration: 256
        ))
    }

    func testSparseCJKLineSyncWithoutAlbumDoesNotProbeWordLevelSibling() {
        let fetcher = LyricsFetcher.shared
        let sparseLineSync = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "我的宝贝　请听我说",
                "世界很大　你要慢慢走",
                "别怕风雨　别怕寂寞",
                "我会在这里为你守候",
                "有一天你会看见",
                "温柔一直在身边"
            ], startingAt: 25.7, gap: 18.0),
            source: .netEase,
            score: 47,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        XCTAssertFalse(fetcher.shouldProbeNetEaseAuthoritativeSiblingForTesting(
            primary: sparseLineSync,
            title: "我的寶貝",
            artist: "Lee Chih Ching",
            duration: 257
        ))
    }

    func testAlbumMatchedLineSyncCanBeatUnprovenWordLevelOutlier() {
        let fetcher = LyricsFetcher.shared
        let albumLineSync = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "maybe learning how to live without you",
                "maybe learning how to make it through",
                "all the quiet rooms are feeling wider",
                "every little memory points to you",
                "I keep waiting for the morning",
                "I keep looking for the truth",
                "the city keeps the lights on",
                "but none of them lead back to you"
            ]),
            source: .lrclibSearch,
            score: 82,
            kind: .synced,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        let unprovenWordLevel = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "standing by the doorway under neon light",
                "dancing with the shadow that keeps me awake",
                "another glass is empty on the table",
                "everybody sings but nobody stays",
                "summer in the city feels borrowed",
                "the chorus keeps turning away",
                "there is a train beyond the river",
                "calling a name I never knew"
            ], wordLevel: true),
            source: .netEase,
            score: 96,
            kind: .synced,
            titleMatched: false,
            matchedDurationDiff: nil
        )

        let selected = fetcher.selectBestResult(
            from: [unprovenWordLevel, albumLineSync],
            songDuration: 40
        )

        XCTAssertEqual(selected?.source, .lrclibSearch)
        XCTAssertFalse(selected?.lyrics.contains(where: { $0.hasSyllableSync }) == true)
    }

    func testLineSyncDiskCacheCannotShortCircuitAuthoritativeWordLevelSearch() {
        let fetcher = LyricsFetcher.shared
        let lineSyncLyrics = makeLines([
            "walking alone through winter lights",
            "every corner keeps a quiet sign"
        ])
        let wordLevelLyrics = makeLines([
            "walking alone through winter lights",
            "every corner keeps a quiet sign"
        ], wordLevel: true)

        XCTAssertFalse(fetcher.canUseImmediateCachedLyrics(
            lineSyncLyrics,
            source: .lrclibSearch,
            title: "Winter Solo Walk",
            artist: "Gordon Flanders"
        ))
        XCTAssertTrue(fetcher.canUseImmediateCachedLyrics(
            wordLevelLyrics,
            source: .netEase,
            title: "Winter Solo Walk",
            artist: "Gordon Flanders"
        ))
    }

    func testComparableHumanCuratedSyncedSourceBeatsLibraryFallback() {
        let fetcher = LyricsFetcher.shared
        let libraryFallback = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "I'm like some kind of Supernova",
                "Watch out",
                "Look at me go",
                "Have some fun",
                "We're going on",
                "New stars are born"
            ]),
            source: .lrclibSearch,
            score: 77,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        let humanCurated = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "I'm like some kind of Supernova",
                "Watch out",
                "Look at me go",
                "Have some fun",
                "We're going on",
                "New stars are born"
            ]),
            source: .netEase,
            score: 68,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(
            from: [libraryFallback, humanCurated],
            songDuration: 178
        )

        XCTAssertEqual(selected?.source, .netEase)
    }

    func testUnsyncedConsensusCanReturnStaticFallbackWhenNoSyncedSurvives() {
        let fetcher = LyricsFetcher.shared
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeCompleteStaticLyrics(prefix: "morning city"),
            source: .genius,
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: .lyricsOvh,
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, .genius)
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
            source: .genius,
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
            source: .genius,
            score: 21,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [plain], songDuration: 120)

        XCTAssertNil(selected)
    }

    func testExactLyricsOvhAloneIsNotTrustedAsStaticFallback() {
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
            source: .lyricsOvh,
            score: 25,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [plain], songDuration: 225)

        // Plain text has no recording/version/timing evidence. Even a long,
        // plausible payload from one endpoint is not enough to cross the
        // service's wrong-lyrics safety boundary.
        XCTAssertNil(selected)
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
            source: .lrclib,
            score: 35,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeCompleteStaticLyrics(prefix: "morning city"),
            source: .genius,
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: .lyricsOvh,
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [synced, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, .genius)
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
            source: .lrclib,
            score: 52,
            kind: .synced
        )
        let syncedB = LyricsFetcher.LyricsFetchResult(
            lyrics: syncedA.lyrics,
            source: .qq,
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
            source: .genius,
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: .lyricsOvh,
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [syncedA, syncedB, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.source, .lrclib)
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
            source: .netEase,
            score: 60,
            kind: .synced
        )
        let plainA = LyricsFetcher.LyricsFetchResult(
            lyrics: makeCompleteStaticLyrics(prefix: "real song"),
            source: .genius,
            score: 31,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: .lyricsOvh,
            score: 28,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [wrongSynced, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, .genius)
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
            source: .netEase,
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
            source: .lyricsOvh,
            score: 27,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: .genius,
            score: 6,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [strongSynced, plainA, plainB], songDuration: 120)

        XCTAssertEqual(selected?.source, .netEase)
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
            source: .netEase,
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
            source: .netEase,
            score: 80,
            kind: .synced,
            titleMatched: false
        )

        let selected = fetcher.selectBestResult(from: [looseEscape, directTitle], songDuration: 120)

        XCTAssertEqual(selected?.firstLineText, "原谅我最近在低潮期")
    }

    func testStrongNativeAliasBeatsLowerLibraryTitleEvidence() {
        let fetcher = LyricsFetcher.shared
        let nativeAlias = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "一樣在六點 泡一樣的咖啡",
                "一樣的街道 一樣的天氣",
                "一樣的心情 一樣的你",
                "怪天氣裡我還想著你",
                "雨停之前都不要醒",
                "城市在窗外慢慢安靜",
                "我聽見風聲又靠近",
                "如果明天還是陰雨",
                "就讓我再等一等你",
                "等到天晴"
            ], startingAt: 13, gap: 5),
            source: .netEase,
            score: 74,
            kind: .synced,
            titleMatched: false,
            matchedDurationDiff: 0.4,
            nativeAliasMatched: true
        )
        let libraryTitle = LyricsFetcher.LyricsFetchResult(
            lyrics: nativeAlias.lyrics,
            source: .lrclibSearch,
            score: 69,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(from: [nativeAlias, libraryTitle], songDuration: 70)

        XCTAssertEqual(selected?.source, .netEase)
    }

    func testMirroredLibrarySourcesDoNotValidateWeakSyncedHit() {
        let fetcher = LyricsFetcher.shared
        let weakLibraryLyrics = makeLines([
            "Burgundy",
            "Burgundy red",
            "Tell me where the story goes",
            "Underneath the evening glow",
            "Waiting for another ride",
            "Surfing through the passing time",
            "Maybe we could come around",
            "Maybe we could find it out",
            "Secrets in the summer sky",
            "Only we can own tonight",
            "Burgundy",
            "Burgundy red"
        ], startingAt: 37, gap: 8)

        let lrclib = LyricsFetcher.LyricsFetchResult(
            lyrics: weakLibraryLyrics,
            source: .lrclib,
            score: 14,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )
        let lrclibSearchMirror = LyricsFetcher.LyricsFetchResult(
            lyrics: weakLibraryLyrics,
            source: .lrclibSearch,
            score: 13,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(
            from: [lrclib, lrclibSearchMirror],
            songDuration: 378
        )

        XCTAssertNil(selected)
    }

    func testScriptMismatchSourceDoesNotBeatLowerScoredEnglishLibraryHit() {
        let fetcher = LyricsFetcher.shared
        let wrongCJKDominant = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "Long gone every time",
                "I close my eyes see you one more time",
                "움직일 수 없어 너의 모습앞에 너무도 달라진 표정",
                "차가운 말투와 날 피하는 눈빛 예전에 니가 아니야",
                "이유라도 대봐 내가 알 수 있게 왜 나를 떠나려는지",
                "마음 약한 내가 쓰러져 울것을 누구보다 알면서",
                "단한번만 나의 모습을 되돌아봐 줘",
                "멈춰버린 내 가슴은 또 어떻게 해"
            ]),
            source: .netEase,
            score: 87,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2,
            scriptMismatchSuspected: true
        )
        let lowerScoredEnglish = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines([
                "Long gone every time",
                "I close my eyes see you one more time",
                "So long say goodbye come on",
                "Dance around the fire",
                "Hold the night a little higher",
                "We keep moving through the smoke",
                "Every spark is getting brighter",
                "Take me where the embers glow"
            ], startingAt: 10, gap: 22),
            source: .lrclib,
            score: 29,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        let selected = fetcher.selectBestResult(
            from: [wrongCJKDominant, lowerScoredEnglish],
            songDuration: 200
        )

        XCTAssertEqual(selected?.source, .lrclib)
    }

    func testSevereTailGapFallsBackToStaticConsensusWhenSyncedIsMistimed() {
        let fetcher = LyricsFetcher.shared
        let mistimed = LyricsFetcher.LyricsFetchResult(
            lyrics: [
                LyricLine(text: "Every time you lie in my place", startTime: 10, endTime: 14),
                LyricLine(text: "I do want to say", startTime: 20, endTime: 24),
                LyricLine(text: "Only you can conquer time", startTime: 150, endTime: 154)
            ],
            source: .lrclib,
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
            source: .genius,
            score: 15,
            kind: .unsynced
        )
        let plainB = LyricsFetcher.LyricsFetchResult(
            lyrics: plainA.lyrics,
            source: .lyricsOvh,
            score: 13,
            kind: .unsynced
        )

        let selected = fetcher.selectBestResult(from: [mistimed, plainA, plainB], songDuration: 300)

        XCTAssertEqual(selected?.kind, .unsynced)
        XCTAssertEqual(selected?.source, .genius)
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
            source: .netEase,
            score: 42,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.5
        )

        let selected = fetcher.selectBestResult(from: [lateSynced], songDuration: 248)

        XCTAssertNil(selected)
    }

    func testExactCatalogLongIntroJapaneseLyricsSurviveTimelineGate() {
        let fetcher = LyricsFetcher.shared
        let lines = [
            (92.89, "悲しみに　出会うたび"),
            (101.20, "あの人を　思い出す"),
            (135.00, "悲しみに　出会うたび"),
            (142.65, "あの人を　思い出す"),
            (150.30, "こんな時　そばにいて"),
            (156.50, "肩を抱いてほしいと"),
            (165.63, "なぐさめも　涙もいらないさ"),
            (172.38, "ぬくもりが　ほしいだけ"),
            (180.93, "ひとはみな　一人では"),
            (187.10, "生きてゆけない　ものだから"),
            (211.82, "空しさに　悩む日は"),
            (219.44, "あの人を　誘いたい"),
            (227.08, "ひとことも　語らずに"),
            (233.34, "おなじ歌　歌おうと"),
            (242.50, "何気ない　心のふれあいが"),
            (249.04, "幸せを　連れてくる"),
            (257.75, "ひとはみな　一人では"),
            (263.82, "生きてゆけない　ものだから"),
            (288.67, "ひとはみな　一人では"),
            (294.90, "生きてゆけない　ものだから"),
            (302.67, "生きてゆけない　ものだから")
        ].map { start, text in
            LyricLine(text: text, startTime: start, endTime: start + 5.0)
        }
        let exactLongIntro = LyricsFetcher.LyricsFetchResult(
            lyrics: lines,
            source: .netEase,
            score: 48.6,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 0.1
        )

        let selected = fetcher.selectBestResult(from: [exactLongIntro], songDuration: 340.133)

        XCTAssertEqual(selected?.source, .netEase)
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

    func testArtistProbeVariantsSplitAndConvertCollaborations() {
        let probes = LyricsFetcher.shared.artistProbeVariants("Hung Liang Chang & Karen Mok")

        XCTAssertTrue(probes.contains("Hung Liang Chang"))
        XCTAssertTrue(probes.contains("Karen Mok"))
        XCTAssertTrue(probes.contains("hong liang zhang"))
        XCTAssertTrue(probes.contains("hongliangzhang"))
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

    func testCJKTitleWithASCIIArtistDoesNotPromoteWrongCJKArtistThroughAlbumMatch() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "冬天一個遊",
            artist: "Gordon Flanders",
            originalTitle: "冬天一個遊",
            originalArtist: "Gordon Flanders",
            duration: 255.957,
            album: "冬天一個遊 - Single"
        )
        let songs: [[String: Any]] = [
            [
                "id": 1,
                "name": "冬天一个游",
                "artist": "Gordon Flanders",
                "duration": 254.149,
                "album": "FLANDERS"
            ],
            [
                "id": 2,
                "name": "冬天一个游",
                "artist": "Hoho / 之之是林之之",
                "duration": 254.0,
                "album": "冬天一个游"
            ]
        ]

        let candidates: [LyricsFetcher.SearchCandidate<Int>] = fetcher.buildCandidates(
            songs: songs,
            params: params,
            searchDescriptor: "title only",
            extractSong: { song in
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let artist = song["artist"] as? String,
                      let duration = song["duration"] as? Double,
                      let album = song["album"] as? String else { return nil }
                return (id, name, artist, duration, album)
            }
        )

        XCTAssertEqual(candidates.first { $0.id == 1 }?.artistMatch, true)
        XCTAssertEqual(candidates.first { $0.id == 2 }?.artistMatch, false)

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "冬天一個遊",
            inputArtist: "Gordon Flanders",
            hasAlbumHint: true
        )

        XCTAssertEqual(selected?.id, 1)
    }

    /// P1b artist-only arms must carry cross-script title evidence. Without
    /// it, "Dinner" (Kay Huang, 259s) accepted the sibling 女朋友男朋友 at
    /// Δ1.4s from an alias-artist-only dump and served 99.9-point wrong
    /// lyrics — the candidate title never related to the input title at all.
    func testArtistOnlyAliasWithoutTitleEvidenceStaysRejected() {
        let fetcher = LyricsFetcher.shared
        // Live-state fixture: the CN alias wave had already resolved the
        // artist to 黄韵玲, so the dump candidate carries artistMatch=true.
        let params = LyricsFetcher.SearchParams(
            title: "Dinner",
            artist: "黄韵玲",
            originalTitle: "Dinner",
            originalArtist: "Kay Huang",
            duration: 259
        )
        let songs: [[String: Any]] = [[
            "id": 1,
            "name": "女朋友男朋友",
            "artist": "黄韵玲",
            "duration": 257.6,
            "album": "永恒承诺"
        ]]
        let candidates: [LyricsFetcher.SearchCandidate<Int>] = fetcher.buildCandidates(
            songs: songs,
            params: params,
            searchDescriptor: "alias artist only:黄韵玲",
            extractSong: { song in
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let artist = song["artist"] as? String,
                      let duration = song["duration"] as? Double,
                      let album = song["album"] as? String else { return nil }
                return (id, name, artist, duration, album)
            }
        )
        XCTAssertNil(fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Dinner",
            inputArtist: "Kay Huang",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        ))
    }

    /// The same arm keeps a genuine romanized alias: the candidate title
    /// romanizes to the input, so cross-script evidence exists.
    func testArtistOnlyAliasWithPhoneticEvidenceStillSelected() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "Hatsukoi",
            artist: "Kozo Murashita",
            originalTitle: "Hatsukoi",
            originalArtist: "Kozo Murashita",
            duration: 225
        )
        let songs: [[String: Any]] = [[
            "id": 1,
            "name": "初恋",
            "artist": "村下孝蔵",
            "duration": 224.6,
            "album": "初恋~浅き夢みし~"
        ]]
        let candidates: [LyricsFetcher.SearchCandidate<Int>] = fetcher.buildCandidates(
            songs: songs,
            params: params,
            searchDescriptor: "alias artist only:村下孝蔵",
            extractSong: { song in
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let artist = song["artist"] as? String,
                      let duration = song["duration"] as? Double,
                      let album = song["album"] as? String else { return nil }
                return (id, name, artist, duration, album)
            }
        )
        XCTAssertEqual(fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Hatsukoi",
            inputArtist: "Kozo Murashita",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )?.id, 1)
    }

    /// The NetEase artist-discography fallback may only claim a native-title
    /// alias when the candidate title actually corroborates the input
    /// (phonetically, via either title half). Input-only "looks like an
    /// alias" heuristics admitted 女朋友男朋友 for "Dinner" at Δ1.4s (99.9pts
    /// wrong lyrics). Translation aliases resolve upstream via the
    /// catalog-alias bridge and arrive as title matches, not guesses.
    func testDiscographyAliasRequiresCandidateTitleEvidence() {
        XCTAssertFalse(LyricsFetcher.discographyAliasTitleEvidence(
            rawTitle: "Dinner",
            rawOriginalTitle: "Dinner",
            candidateTitle: "女朋友男朋友"
        ))
        XCTAssertTrue(LyricsFetcher.discographyAliasTitleEvidence(
            rawTitle: "Hatsukoi",
            rawOriginalTitle: "Hatsukoi",
            candidateTitle: "初恋"
        ))
        // Dual-title: the resolved half corroborates even when the original
        // does not (resolved CJK title round-trips through its own script).
        XCTAssertTrue(LyricsFetcher.discographyAliasTitleEvidence(
            rawTitle: "三个人的晚餐",
            rawOriginalTitle: "Dinner",
            candidateTitle: "三个人的晚餐"
        ))
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
            source: .netEase,
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
            source: .netEase,
            inputTitle: "This Is My Love",
            inputArtist: "Michelle Chen",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected)
    }

    func testAlbumHintBlocksUnscopedEnglishAliasDurationCollision() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1898256676,
                name: "一定会",
                artist: "林俊杰",
                album: "一定会/After The Rain",
                durationDiff: 0.7,
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
            source: .netEase,
            inputTitle: "The Key",
            inputArtist: "JJ Lin",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected)
    }

    func testProviderTitleArtistNativeAliasUsesConfirmedCJKArtistEvidence() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 276_461,
                name: "告诉我",
                artist: "陈绮贞",
                album: "还是会寂寞",
                durationDiff: 0.7,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 0,
                searchDescriptor: "title+artist"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Tell Me",
            inputArtist: "Cheer Chen",
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 276_461)
        XCTAssertTrue(selected?.titleMatched == true)
        XCTAssertTrue(selected?.nativeAliasMatched == true)
    }

    func testTopExactNativeTitleOnlyCandidateUsesConfirmedCJKArtistEvidence() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 3_006_001,
                name: "鼻鼻",
                artist: "文兆杰",
                album: "其后",
                durationDiff: 0.8,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 2,
                resultIndex: 0,
                searchDescriptor: "title only"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .qq,
            inputTitle: "For my Doggie",
            inputArtist: "Wen Zhaojie",
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 3_006_001)
        XCTAssertTrue(selected?.titleMatched == true)
        XCTAssertTrue(selected?.nativeAliasMatched == true)
    }

    func testAlbumHintAllowsSemanticEnglishNativeTitleAlias() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 4001,
                name: "关键词",
                artist: "林俊杰",
                album: "和自己对话",
                durationDiff: 2.3,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 0,
                searchDescriptor: "alias+title:林俊杰"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "The Key",
            inputArtist: "JJ Lin",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 4001)
        XCTAssertEqual(selected?.nativeAliasMatched, true)
    }

    func testLongEnglishTitleRejectsSameArtistAlbumDurationCollision() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 4002,
                name: "他不爱我",
                artist: "莫文蔚",
                album: "回蔚",
                durationDiff: 0.1,
                titleMatch: false,
                artistMatch: true,
                albumMatch: true,
                normalizedNameLength: 5,
                resultIndex: 0,
                searchDescriptor: "album+artist"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "A Candlelight Dinner With Only Ice Cream",
            inputArtist: "Karen Mok",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected, "same artist, album, and duration cannot replace missing title evidence")
    }

    func testLongEnglishTitleRejectsProviderTopRankNativeCollision() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 4003,
                name: "他不爱我",
                artist: "Karen Mok",
                album: "回蔚",
                durationDiff: 0.1,
                titleMatch: false,
                artistMatch: true,
                albumMatch: true,
                normalizedNameLength: 5,
                resultIndex: 0,
                searchDescriptor: "title+artist:A Candlelight Dinner With Only Ice Cream Karen Mok"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "A Candlelight Dinner With Only Ice Cream",
            inputArtist: "Karen Mok",
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected, "provider rank is not semantic title evidence")
    }

    func testShortEnglishTitleRejectsAlbumMatchedNativeCollision() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 4004,
                name: "慢慢的流",
                artist: "Karen Mok",
                album: "回蔚",
                durationDiff: 0.1,
                titleMatch: false,
                artistMatch: true,
                albumMatch: true,
                normalizedNameLength: 5,
                resultIndex: 0,
                searchDescriptor: "title+artist"
            )
        ]

        XCTAssertNil(fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Hiroshima mon amour",
            inputArtist: "Karen Mok",
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        ), "album identity cannot replace missing cross-script title evidence")
    }

    func testEnglishTitleRejectsDurationOnlyAlbumScopedWitnessAlias() {
        XCTAssertFalse(LyricsFetcher.allowsDurationOnlyAlbumScopedNativeAlias(
            inputTitle: "Hiroshima mon amour",
            candidateTitle: "慢慢的流",
            albumScoped: true
        ))
        XCTAssertFalse(LyricsFetcher.allowsDurationOnlyAlbumScopedNativeAlias(
            inputTitle: "A Candlelight Dinner With Only Ice Cream",
            candidateTitle: "他不爱我",
            albumScoped: true
        ))
        XCTAssertTrue(LyricsFetcher.allowsDurationOnlyAlbumScopedNativeAlias(
            inputTitle: "Mayonaka No Shujinkou",
            candidateTitle: "真夜中の主人公",
            albumScoped: true
        ))
    }

    func testGenericEnglishTokenDoesNotCreateAliasTitleOverlap() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 2046796566,
                name: "The Show (with JJ Lin)",
                artist: "Steve Aoki / 林俊杰",
                album: "The Show",
                durationDiff: 0.4,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 8,
                resultIndex: 0,
                searchDescriptor: "alias+title:林俊杰"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "The Key",
            inputArtist: "JJ Lin",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected)
    }

    func testAlbumScopedCompilationArtistDoesNotBecomeSpecificArtistEvidence() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "This Is My Love",
            artist: "Michelle Chen",
            originalTitle: "This Is My Love",
            originalArtist: "Michelle Chen",
            duration: 312,
            album: "脫掉制服"
        )
        let songs: [[String: Any]] = [
            [
                "id": 543656445,
                "name": "This Is My Love",
                "artist": "群星",
                "duration": 312.1,
                "album": "脱掉制服"
            ]
        ]

        let candidates: [LyricsFetcher.SearchCandidate<Int>] = fetcher.buildCandidates(
            songs: songs,
            params: params,
            searchDescriptor: "album+artist",
            extractSong: { song in
                guard let id = song["id"] as? Int,
                      let name = song["name"] as? String,
                      let artist = song["artist"] as? String,
                      let duration = song["duration"] as? Double,
                      let album = song["album"] as? String else { return nil }
                return (id, name, artist, duration, album)
            }
        )

        XCTAssertEqual(candidates.first?.titleMatch, true)
        XCTAssertEqual(candidates.first?.albumMatch, true)
        XCTAssertEqual(candidates.first?.artistMatch, false)

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "This Is My Love",
            inputArtist: "Michelle Chen",
            hasAlbumHint: true
        )

        XCTAssertNil(selected)

        let fallbackSelected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "This Is My Love",
            inputArtist: "Michelle Chen",
            hasAlbumHint: true,
            allowCompilationAlbumFallback: true
        )

        XCTAssertEqual(fallbackSelected?.id, 543656445)
        XCTAssertEqual(fallbackSelected?.albumMatched, true)
        XCTAssertEqual(fallbackSelected?.titleMatched, true)
    }

    func testAlbumScopedCompilationFallbackAcceptsExactAlbumTitleDuration() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "This Is My Love",
            artist: "Michelle Chen",
            originalTitle: "This Is My Love",
            originalArtist: "Michelle Chen",
            duration: 312,
            album: "脫掉制服"
        )

        XCTAssertTrue(fetcher.isSafeCompilationAlbumFallbackCandidate(
            params: params,
            candidateTitle: "This Is My Love",
            candidateArtist: "群星",
            candidateAlbum: "脱掉制服",
            candidateDuration: 312.1,
            resultIndex: 1,
            searchDescriptor: "compilation album+artist"
        ))
        XCTAssertFalse(fetcher.isSafeCompilationAlbumFallbackCandidate(
            params: params,
            candidateTitle: "Oriental Love",
            candidateArtist: "群星",
            candidateAlbum: "脱掉制服",
            candidateDuration: 420.4,
            resultIndex: 0,
            searchDescriptor: "compilation album+artist"
        ))
        XCTAssertFalse(fetcher.isSafeCompilationAlbumFallbackCandidate(
            params: params,
            candidateTitle: "This Is My Love",
            candidateArtist: "群星",
            candidateAlbum: "Top Pop Europa Plus",
            candidateDuration: 312.1,
            resultIndex: 1,
            searchDescriptor: "compilation album+artist"
        ))
    }

    func testProviderNativeCompilationAlbumDiscoveryIsTightlyGuarded() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "This Is My Love",
            artist: "Michelle Chen",
            originalTitle: "This Is My Love",
            originalArtist: "Michelle Chen",
            duration: 312,
            album: "Young Stars"
        )

        XCTAssertTrue(fetcher.isSafeCompilationAlbumDiscoveryCandidate(
            params: params,
            candidateTitle: "This Is My Love",
            candidateArtist: "群星",
            candidateAlbum: "脱掉制服",
            candidateDuration: 312.052,
            resultIndex: 47
        ))
        XCTAssertFalse(fetcher.isSafeCompilationAlbumDiscoveryCandidate(
            params: params,
            candidateTitle: "Oriental Love",
            candidateArtist: "群星",
            candidateAlbum: "脱掉制服",
            candidateDuration: 420.397,
            resultIndex: 2
        ))
        XCTAssertFalse(fetcher.isSafeCompilationAlbumDiscoveryCandidate(
            params: params,
            candidateTitle: "This Is My Love",
            candidateArtist: "Walter Lanza",
            candidateAlbum: "This Is My Love",
            candidateDuration: 330.5,
            resultIndex: 0
        ))
        XCTAssertFalse(fetcher.isSafeCompilationAlbumDiscoveryCandidate(
            params: params,
            candidateTitle: "This Is My Love",
            candidateArtist: "群星",
            candidateAlbum: "Top Pop Europa Plus",
            candidateDuration: 312.052,
            resultIndex: 4
        ))
    }

    func testForegroundCatalogDiscoveryRequiresDistinctiveExactTitle() {
        let fetcher = LyricsFetcher.shared
        let distinctive = LyricsFetcher.SearchParams(
            title: "This Is My Love",
            artist: "Michelle Chen",
            originalTitle: "This Is My Love",
            originalArtist: "Michelle Chen",
            duration: 312,
            album: "Young Stars"
        )
        XCTAssertTrue(fetcher.shouldForegroundNetEaseCatalogExactTitleDiscovery(params: distinctive))

        let generic = LyricsFetcher.SearchParams(
            title: "Love",
            artist: "Michelle Chen",
            originalTitle: "Love",
            originalArtist: "Michelle Chen",
            duration: 312,
            album: "Young Stars"
        )
        XCTAssertFalse(fetcher.shouldForegroundNetEaseCatalogExactTitleDiscovery(params: generic))
        XCTAssertFalse(fetcher.isSafeCompilationAlbumDiscoveryCandidate(
            params: generic,
            candidateTitle: "Love",
            candidateArtist: "群星",
            candidateAlbum: "脱掉制服",
            candidateDuration: 312.052,
            resultIndex: 10
        ))
    }

    func testCatalogExactTitleDiscoveryQueriesCompilationArtistHints() {
        let fetcher = LyricsFetcher.shared
        let params = LyricsFetcher.SearchParams(
            title: "This Is My Love",
            artist: "Michelle Chen",
            originalTitle: "This Is My Love",
            originalArtist: "Michelle Chen",
            duration: 312,
            album: "Young Stars"
        )

        let queries = fetcher.netEaseCompilationAlbumDiscoveryQueriesForTesting(params: params)

        XCTAssertTrue(queries.contains("This Is My Love"))
        XCTAssertTrue(queries.contains("This Is My Love 华语群星"))
        XCTAssertTrue(queries.contains("This Is My Love 華語群星"))
    }

    func testCatalogExactTitleCandidateCanWinExistingSearchRoundWithoutDeepProbe() {
        let fetcher = LyricsFetcher.shared
        let candidate = LyricsFetcher.SearchCandidate(
            id: 543_656_445,
            name: "This Is My Love",
            artist: "群星",
            album: "脱掉制服",
            durationDiff: 0.052,
            titleMatch: true,
            artistMatch: false,
            albumMatch: false,
            normalizedNameLength: 12,
            resultIndex: 19,
            searchDescriptor: "title+artist"
        )

        let selected = fetcher.selectBestCandidate(
            [candidate],
            source: .netEase,
            inputTitle: "This Is My Love",
            inputArtist: "Michelle Chen",
            hasAlbumHint: true,
            allowCompilationAlbumFallback: true
        )
        XCTAssertEqual(selected?.id, 543_656_445)
        XCTAssertTrue(selected?.titleMatched == true)

        XCTAssertNil(fetcher.selectBestCandidate(
            [candidate],
            source: .netEase,
            inputTitle: "Love",
            inputArtist: "Michelle Chen",
            hasAlbumHint: true,
            allowCompilationAlbumFallback: true
        ))
    }

    func testForegroundArtistDiscographyAliasUsesGeneralTitleShape() {
        let fetcher = LyricsFetcher.shared
        XCTAssertTrue(fetcher.shouldForegroundNetEaseArtistDiscographyAliasFallback(
            title: "Ocean",
            artist: "Tanya Chua",
            originalTitle: "Ocean",
            originalArtist: "Tanya Chua",
            duration: 244,
            album: ""
        ))
        XCTAssertTrue(fetcher.shouldForegroundNetEaseArtistDiscographyAliasFallback(
            title: "Deep",
            artist: "Tanya Chua",
            originalTitle: "Deep",
            originalArtist: "Tanya Chua",
            duration: 244,
            album: ""
        ))
        XCTAssertFalse(fetcher.shouldForegroundNetEaseArtistDiscographyAliasFallback(
            title: "Ai",
            artist: "Tanya Chua",
            originalTitle: "Ai",
            originalArtist: "Tanya Chua",
            duration: 244,
            album: ""
        ))
        XCTAssertFalse(fetcher.shouldForegroundNetEaseArtistDiscographyAliasFallback(
            title: "All The Things You Never Knew",
            artist: "Wang Leehom",
            originalTitle: "All The Things You Never Knew",
            originalArtist: "Wang Leehom",
            duration: 279,
            album: ""
        ))
        XCTAssertFalse(fetcher.shouldForegroundNetEaseArtistDiscographyAliasFallback(
            title: "Ocean",
            artist: "Tanya Chua",
            originalTitle: "Ocean",
            originalArtist: "Tanya Chua",
            duration: 244,
            album: "Known Album"
        ))
    }

    func testLibraryCatalogTitleCanExposeNativeAliasForEnglishStorefrontTitle() {
        let fetcher = LyricsFetcher.shared
        let alias = fetcher.libraryNativeTitleAliasForTesting(
            resultTitle: "你不知道的事 - All The Things You Never Knew",
            inputTitle: "All The Things You Never Knew"
        )

        XCTAssertEqual(alias, "你不知道的事")
        XCTAssertNil(fetcher.libraryNativeTitleAliasForTesting(
            resultTitle: "All The Things You Are",
            inputTitle: "All The Things You Never Knew"
        ))
    }

    func testLibraryNativeTitleBridgeKeepsEmptyEnglishMissInsideForegroundBudget() {
        let fetcher = LyricsFetcher.shared

        let deadline = fetcher.foregroundEmptyResultDeadlineForTesting(
            title: "Love Is Free",
            artist: "Brenton Wood",
            duration: 153,
            album: ""
        )

        XCTAssertLessThanOrEqual(deadline, 2.25)
    }

    func testForegroundFetchHasSingleHardDeadlineUnderInteractionBudget() {
        XCTAssertLessThanOrEqual(
            LyricsFetcher.shared.foregroundHardDeadlineForTesting,
            2.70
        )
    }

    func testHardTimeoutReturnsWhileWorkerIgnoresCancellation() async {
        let started = Date()
        _ = await LyricsFetcher.shared.withHardSourceTimeout(seconds: 0.05) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.50) {
                    continuation.resume(returning: Optional<LyricsFetcher.LyricsFetchResult>.none)
                }
            }
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            0.25,
            "wall-clock timeout must resume without waiting for a blocking provider worker"
        )
    }

    func testAlbumTitleEchoDoesNotUseLibraryNativeTitleCachePreflight() {
        let fetcher = LyricsFetcher.shared

        XCTAssertFalse(fetcher.shouldUsePreflightLibraryNativeTitleCacheForTesting(
            title: "Love You More & More",
            artist: "Rene Liu",
            album: "Love You More & More"
        ))
        XCTAssertTrue(fetcher.shouldUsePreflightLibraryNativeTitleCacheForTesting(
            title: "All The Things You Never Knew",
            artist: "Wang Leehom",
            album: ""
        ))
    }

    func testDecoratedTitleCanUseNativeMetadataCachePreflight() {
        let fetcher = LyricsFetcher.shared

        XCTAssertTrue(fetcher.shouldUseDecoratedTitleMetadataCachePreflightForTesting(
            inputTitle: "None of Your Business (feat. Kumachan)",
            cachedTitle: "關你屁事啊 (feat. 熊仔)"
        ))
        XCTAssertFalse(fetcher.shouldUseDecoratedTitleMetadataCachePreflightForTesting(
            inputTitle: "Love Is Free",
            cachedTitle: "Love Is Free"
        ))
    }

    func testDirectProviderLocalizedTitleAliasRequiresExactArtistTopResultAndTightDuration() {
        let fetcher = LyricsFetcher.shared
        let matching = LyricsFetcher.SearchCandidate(
            id: 1_805_380_249,
            name: "多完美的一天",
            artist: "deca joins",
            album: "鸟鸟鸟 Bird and Reflections",
            durationDiff: 0.107,
            titleMatch: false,
            artistMatch: true,
            albumMatch: false,
            normalizedNameLength: 6,
            resultIndex: 0,
            searchDescriptor: "title+artist"
        )
        let selected = fetcher.selectBestCandidate(
            [matching],
            source: .netEase,
            inputTitle: "Such a Perfect Day",
            inputArtist: "deca joins",
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 1_805_380_249)
        XCTAssertTrue(selected?.titleMatched == true)
        XCTAssertTrue(selected?.nativeAliasMatched == true)

        let looseDuration = LyricsFetcher.SearchCandidate(
            id: 2,
            name: "多完美的一天",
            artist: "deca joins",
            album: "鸟鸟鸟 Bird and Reflections",
            durationDiff: 0.6,
            titleMatch: false,
            artistMatch: true,
            albumMatch: false,
            normalizedNameLength: 6,
            resultIndex: 0,
            searchDescriptor: "title+artist"
        )
        XCTAssertNil(fetcher.selectBestCandidate(
            [looseDuration],
            source: .netEase,
            inputTitle: "Such a Perfect Day",
            inputArtist: "deca joins",
            allowNativeTitleAlias: true
        ))

        let lowerRanked = LyricsFetcher.SearchCandidate(
            id: 3,
            name: "多完美的一天",
            artist: "deca joins",
            album: "鸟鸟鸟 Bird and Reflections",
            durationDiff: 0.107,
            titleMatch: false,
            artistMatch: true,
            albumMatch: false,
            normalizedNameLength: 6,
            resultIndex: 3,
            searchDescriptor: "title+artist"
        )
        XCTAssertNil(fetcher.selectBestCandidate(
            [lowerRanked],
            source: .netEase,
            inputTitle: "Such a Perfect Day",
            inputArtist: "deca joins",
            allowNativeTitleAlias: true
        ))
    }

    func testCollaborationEvidenceTitleQueryPreservesFeaturedArtistTokens() {
        XCTAssertEqual(
            LyricsFetcher.collaborationEvidenceTitleQuery(from: "Distance (feat. deca joins)"),
            "Distance deca joins"
        )
        XCTAssertEqual(
            LyricsFetcher.collaborationEvidenceTitleQuery(from: "Song ft. Artist A & Artist B"),
            "Song Artist A Artist B"
        )
    }

    func testCJKMediaDescriptorSearchTermsKeepQuotedWorkTitle() {
        XCTAssertEqual(
            LyricsFetcher.cjkMediaDescriptorSearchTerms(from: "叶子 (电视剧《蔷薇之恋》原声带版)"),
            "蔷薇之恋"
        )
    }

    func testFeaturedTitleNativeAliasBeatsWrongExactTitleWhenCollaboratorMatches() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1_920_623_031,
                name: "最好的距离",
                artist: "郑宜农/deca joins",
                album: "水逆",
                durationDiff: 0.5,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 5,
                resultIndex: 0,
                searchDescriptor: "title+artist-collaboration"
            ),
            LyricsFetcher.SearchCandidate(
                id: 812_124,
                name: "distance",
                artist: "ラムジ",
                album: "好きだから",
                durationDiff: 7.7,
                titleMatch: true,
                artistMatch: false,
                albumMatch: false,
                normalizedNameLength: 8,
                resultIndex: 2,
                searchDescriptor: "title+artist-collaboration"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Distance (feat. deca joins)",
            inputArtist: "Enno Cheng",
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 1_920_623_031)
        XCTAssertTrue(selected?.titleMatched == true)
        XCTAssertTrue(selected?.nativeAliasMatched == true)
    }

    /// CONTRACT CHANGE (evidence-first): an artist-only dump candidate with
    /// no title relation to the input is never selected, even at tight Δ.
    /// The old arm accepted "Deep"→无底洞 (right) by the same rule that
    /// accepted "Dinner"→女朋友男朋友 (99.9pts wrong lyrics) — a coin flip.
    /// Translated aliases resolve upstream via the catalog-alias bridge
    /// (title-scoped storefront query collapsing to one identity) and then
    /// match P1 by title. Known cost: catalog-ambiguous single-word aliases
    /// (Deep-class: Apple lists BOTH 無底洞 and "Deep" at the same duration)
    /// stay unresolved rather than guessed.
    func testSingleWordEnglishTitleWithoutEvidenceStaysUnresolved() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
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

        XCTAssertNil(fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Deep",
            inputArtist: "Tanya Chua",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        ))
    }

    /// Same contract for multi-word English inputs: "Strange Weather" no
    /// longer rides the bare artist-only probe. Its alias 怪天气 is a single
    /// collapsed identity on the TW/CN storefronts, so the catalog-alias
    /// bridge resolves the native title upstream and P1 matches it by title.
    func testMultiWordEnglishTitleWithoutEvidenceStaysUnresolved() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "怪天气",
                artist: "YELLOW黄宣 / 9m88",
                album: "怪天气",
                durationDiff: 0.4,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 0,
                searchDescriptor: "artist only"
            )
        ]

        XCTAssertNil(fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Strange Weather",
            inputArtist: "YELLOW & 9m88",
            allowNativeTitleAlias: true
        ))
    }

    func testAlbumHintBlocksLooseEnglishNativeArtistProbeCollision() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "未命名的悲伤",
                artist: "曾沛慈",
                album: "我是曾沛慈",
                durationDiff: 0.4,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 6,
                resultIndex: 0,
                searchDescriptor: "artist only"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .qq,
            inputTitle: "Thinking of Someone",
            inputArtist: "Pets Tseng",
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected)
    }

    func testJapaneseRomajiTitleEvidenceBeatsCloserArtistOnlyCollision() {
        let fetcher = LyricsFetcher.shared
        XCTAssertTrue(
            fetcher.isTitleMatch(
                input: "Hatsukoi",
                result: "初恋",
                simplifiedInput: "hatsukoi"
            )
        )

        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "少女",
                artist: "村下孝蔵",
                album: "七夕夜想曲",
                durationDiff: 0.7,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 2,
                resultIndex: 0,
                searchDescriptor: "alias artist only:村下孝蔵"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "初恋",
                artist: "村下孝蔵",
                album: "七夕夜想曲",
                durationDiff: 3.8,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 2,
                resultIndex: 1,
                searchDescriptor: "alias artist only:村下孝蔵"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Hatsukoi",
            inputArtist: "Kozo Murashita",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
    }

    func testPinyinTitleMatchesNativeChineseCandidateForResolvedArtistAlias() {
        let fetcher = LyricsFetcher.shared
        XCTAssertTrue(
            fetcher.isTitleMatch(
                input: "Yi Jian Zhong Qing",
                result: "一見鍾情",
                simplifiedInput: "yi jian zhong qing"
            )
        )

        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "Yi Jian Zhong Qing",
                artist: "藍心湄",
                album: "夏日撒糖情歌",
                durationDiff: 0.0,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 18,
                resultIndex: 0,
                searchDescriptor: "title+artist"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "一見鍾情",
                artist: "藍心湄",
                album: "一見鍾情",
                durationDiff: 0.0,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 4,
                resultIndex: 1,
                searchDescriptor: "alias artist only:藍心湄"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Yi Jian Zhong Qing",
            inputArtist: "Pauline Lan",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
    }

    func testRomanizedShortKanaTitleMatchesNativeJapaneseCandidate() {
        let fetcher = LyricsFetcher.shared
        XCTAssertTrue(
            fetcher.isTitleMatch(
                input: "Fureai",
                result: "ふれあい",
                simplifiedInput: "fureai"
            )
        )

        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 598367,
                name: "ふれあい",
                artist: "柏原芳恵",
                album: "アンコール",
                durationDiff: 0.1,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 4,
                resultIndex: 0,
                searchDescriptor: "title+artist"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Fureai",
            inputArtist: "Yoshie Kashiwabara",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 598367)
        XCTAssertTrue(selected?.titleMatched == true)
    }

    func testLongSparseExactCatalogLyricsSurviveLargeTailGap() {
        let fetcher = LyricsFetcher.shared
        let sparseSynced = LyricsFetcher.LyricsFetchResult(
            lyrics: makeLines(
                (0..<42).map { index in
                    index == 0 ? "Every time you lie in my place" : "Only you can conquer time"
                },
                startingAt: 0.2,
                gap: 4.5
            ),
            source: .qq,
            score: 35,
            kind: .synced,
            titleMatched: true,
            matchedDurationDiff: 1.0
        )

        let selected = fetcher.selectBestResult(from: [sparseSynced], songDuration: 401)

        XCTAssertEqual(selected?.source, .qq)
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
            source: .netEase,
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
            source: .netEase,
            score: -80,
            kind: .unavailable,
            titleMatched: true,
            matchedDurationDiff: 7.8
        )

        let selected = fetcher.selectUnavailableResult(from: [unavailable])

        XCTAssertEqual(selected?.source, .netEase)
    }

    func testWeakTerminalAvailabilityDoesNotBlockAlbumNativeAliasRescue() {
        let fetcher = LyricsFetcher.shared
        let instrumental = LyricsFetcher.LyricsFetchResult(
            lyrics: [LyricLine(text: "纯音乐，请欣赏", startTime: 0, endTime: 1)],
            source: .qq,
            score: -100,
            kind: .instrumental,
            albumMatched: false,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        XCTAssertTrue(fetcher.shouldSuppressWeakTerminalAvailabilityForNativeAliasMiss(
            album: "Shangri-La",
            results: [instrumental],
            albumScopedBranchFired: true,
            catalogExactTitleBranchFired: true
        ))
    }

    func testAlbumMatchedTerminalAvailabilityRemainsAuthoritative() {
        let fetcher = LyricsFetcher.shared
        let unavailable = LyricsFetcher.LyricsFetchResult(
            lyrics: [],
            source: .qq,
            score: -80,
            kind: .unavailable,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        XCTAssertFalse(fetcher.shouldSuppressWeakTerminalAvailabilityForNativeAliasMiss(
            album: "Known Album",
            results: [unavailable],
            albumScopedBranchFired: true,
            catalogExactTitleBranchFired: false
        ))
    }

    func testNoAlbumTerminalAvailabilityCacheDoesNotBypassAlbumScopedRetry() {
        let fetcher = LyricsFetcher.shared
        let cached = LyricsDiskCacheEntry(
            source: "QQ",
            syncedLyrics: "",
            lines: [CachedLyricLine(text: "Instrumental", startTime: 0, endTime: 180, words: [], translation: nil)],
            kind: .instrumental,
            ts: Date().timeIntervalSince1970,
            duration: 180,
            album: nil,
            matchedDurationDiff: 0.2
        )

        XCTAssertFalse(fetcher.shouldUseImmediateCachedAvailability(
            cached,
            requestedAlbum: "Known Album"
        ))
        XCTAssertTrue(fetcher.shouldUseImmediateCachedAvailability(
            cached,
            requestedAlbum: ""
        ))
    }

    func testAlbumMatchedTerminalAvailabilityCacheCanShortCircuit() {
        let fetcher = LyricsFetcher.shared
        let cached = LyricsDiskCacheEntry(
            source: "QQ",
            syncedLyrics: "",
            lines: [CachedLyricLine(text: "Instrumental", startTime: 0, endTime: 180, words: [], translation: nil)],
            kind: .instrumental,
            ts: Date().timeIntervalSince1970,
            duration: 180,
            album: "Known Album",
            matchedDurationDiff: 0.2
        )

        XCTAssertTrue(fetcher.shouldUseImmediateCachedAvailability(
            cached,
            requestedAlbum: "known album"
        ))
        XCTAssertFalse(fetcher.shouldUseImmediateCachedAvailability(
            cached,
            requestedAlbum: "Other Album"
        ))
    }

    func testForegroundCatalogProbePreventsAvailabilityCacheShortCircuit() {
        let fetcher = LyricsFetcher.shared
        let cached = LyricsDiskCacheEntry(
            source: "QQ",
            syncedLyrics: "",
            lines: [CachedLyricLine(text: "Instrumental", startTime: 0, endTime: 275, words: [], translation: nil)],
            kind: .instrumental,
            ts: Date().timeIntervalSince1970,
            duration: 275,
            album: "Lovers - Single",
            matchedDurationDiff: 0.1
        )

        XCTAssertTrue(fetcher.isAlbumTitleEchoNativeAliasProbeInput(
            title: "Lovers",
            album: "Lovers - Single"
        ))
        XCTAssertFalse(fetcher.shouldUseImmediateCachedAvailability(
            cached,
            requestedAlbum: "Lovers - Single",
            defersForegroundProviderProbe: true
        ))
        XCTAssertTrue(fetcher.shouldUseImmediateCachedAvailability(
            cached,
            requestedAlbum: "Lovers - Single"
        ))
    }

    func testProviderUnavailableNeverPersistsAsSongAvailability() {
        let fetcher = LyricsFetcher.shared
        let unavailable = LyricsFetcher.LyricsFetchResult(
            lyrics: [],
            source: .netEase,
            score: -80,
            kind: .unavailable,
            albumMatched: false,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        XCTAssertFalse(fetcher.shouldPersistAvailabilityResult(
            unavailable,
            requestedAlbum: "Known Album"
        ))
        XCTAssertFalse(fetcher.shouldPersistAvailabilityResult(
            unavailable,
            requestedAlbum: ""
        ))
    }

    func testAlbumMatchedTerminalAvailabilityCanPersistWithAlbumHint() {
        let fetcher = LyricsFetcher.shared
        let instrumental = LyricsFetcher.LyricsFetchResult(
            lyrics: [LyricLine(text: "Instrumental", startTime: 0, endTime: 180)],
            source: .qq,
            score: -100,
            kind: .instrumental,
            albumMatched: true,
            titleMatched: true,
            matchedDurationDiff: 0.2
        )

        XCTAssertTrue(fetcher.shouldPersistAvailabilityResult(
            instrumental,
            requestedAlbum: "Known Album"
        ))
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
            source: .netEase,
            inputTitle: "Second Love",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected?.matchRank, 2)
    }

    func testAlbumHintBlocksLooseAliasTitleCollisionForRomanizedJapaneseTitle() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "駅",
                artist: "中森明菜",
                album: "CRIMSON",
                durationDiff: 8.4,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 1,
                resultIndex: 0,
                searchDescriptor: "alias+title:中森明菜"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "雪の華",
                artist: "中森明菜",
                album: "歌姫4 -My Eggs Benedict-",
                durationDiff: 0.0,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 1,
                searchDescriptor: "artist only"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Yuki No Hana",
            inputArtist: "Akina Nakamori",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected?.title, "雪の華")
    }

    func testAlbumHintBlocksLooseAliasAlbumCollisionForRomanizedJapaneseTitle() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "接吻",
                artist: "中森明菜",
                album: "歌姫4 -My Eggs Benedict-",
                durationDiff: 0.2,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 2,
                resultIndex: 0,
                searchDescriptor: "alias album+artist:中森明菜"
            ),
            LyricsFetcher.SearchCandidate(
                id: 2,
                name: "雪の華",
                artist: "中森明菜",
                album: "歌姫4 -My Eggs Benedict-",
                durationDiff: 0.0,
                titleMatch: false,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 3,
                resultIndex: 1,
                searchDescriptor: "artist only"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .netEase,
            inputTitle: "Yuki No Hana",
            inputArtist: "Akina Nakamori",
            aliasConfirmedCJK: true,
            hasAlbumHint: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 2)
        XCTAssertEqual(selected?.title, "雪の華")
    }

    func testQQRejectsUnscopedNativeTitleOnlyForLongRomanizedJapaneseTitle() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "ドリーム・ボートが出る夜に",
                artist: "菊池桃子",
                album: "Eternal Best",
                durationDiff: 0.0,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 13,
                resultIndex: 0,
                searchDescriptor: "title only"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .qq,
            inputTitle: "Dream Boat ga Deru Yoru ni",
            inputArtist: "Momoko Kikuchi",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertNil(selected)
    }

    func testQQKeepsArtistScopedNativeTitleForLongRomanizedJapaneseTitle() {
        let fetcher = LyricsFetcher.shared
        let candidates = [
            LyricsFetcher.SearchCandidate(
                id: 1,
                name: "ドリーム・ボートが出る夜に",
                artist: "菊池桃子",
                album: "Miroir",
                durationDiff: 0.1,
                titleMatch: true,
                artistMatch: true,
                albumMatch: false,
                normalizedNameLength: 13,
                resultIndex: 0,
                searchDescriptor: "title+artist"
            )
        ]

        let selected = fetcher.selectBestCandidate(
            candidates,
            source: .qq,
            inputTitle: "Dream Boat ga Deru Yoru ni",
            inputArtist: "Momoko Kikuchi",
            aliasConfirmedCJK: true,
            allowNativeTitleAlias: true
        )

        XCTAssertEqual(selected?.id, 1)
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
            source: .netEase,
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
