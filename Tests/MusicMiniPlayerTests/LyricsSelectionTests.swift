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

    func testUnsyncedConsensusIsNotUsedForSyncedLyricsUI() {
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

        XCTAssertNil(selected)
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

    func testUnsyncedConsensusDoesNotReplaceMissingSyncedResult() {
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

        XCTAssertNil(selected)
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

    func testUnsyncedConsensusDoesNotReplaceWrongSyncedOutlier() {
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

        XCTAssertNil(selected)
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

    func testSevereTailGapRejectsMistimedSyncedWhenPlainConsensusExists() {
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

        XCTAssertNil(selected)
    }
}

private extension LyricsFetcher.LyricsFetchResult {
    var firstLineText: String? {
        lyrics.first?.text
    }
}
