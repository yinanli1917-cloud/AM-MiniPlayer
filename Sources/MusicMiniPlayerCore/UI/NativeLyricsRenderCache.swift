import CoreGraphics
import Foundation

struct NativeLyricsTextCacheKey: Hashable {
    struct WordKey: Hashable {
        let text: String
        let startTimeMilliseconds: Int
        let endTimeMilliseconds: Int

        init(_ word: LyricWord) {
            self.text = word.word
            self.startTimeMilliseconds = Int((word.startTime * 1000).rounded())
            self.endTimeMilliseconds = Int((word.endTime * 1000).rounded())
        }
    }

    let displayIndex: Int
    let text: String
    let translation: String?
    let words: [WordKey]
    let widthPixels: Int
    let showTranslation: Bool
    let mainFontSizeTenths: Int
    let translationFontSizeTenths: Int

    init(
        row: NativeLyricsRenderRow,
        width: CGFloat,
        showTranslation: Bool,
        constants: NativeLyricsTextConstants = NativeLyricsTextConstants()
    ) {
        self.displayIndex = row.displayIndex
        self.text = row.text
        self.translation = row.translation
        self.words = row.words.map(WordKey.init)
        self.widthPixels = Int(width.rounded(.toNearestOrAwayFromZero))
        self.showTranslation = showTranslation
        self.mainFontSizeTenths = Int((constants.mainFontSize * 10).rounded())
        self.translationFontSizeTenths = Int((constants.translationFontSize * 10).rounded())
    }
}

struct NativeLyricsRenderCacheDecision: Equatable {
    let reusedRowCount: Int
    let invalidatedRowCount: Int
    let mountedRowCount: Int
    let unmountedRowCount: Int

    var touchedRowCount: Int {
        invalidatedRowCount + mountedRowCount + unmountedRowCount
    }
}

struct NativeLyricsRenderCache {
    private var keysByDisplayIndex: [Int: NativeLyricsTextCacheKey] = [:]

    mutating func reconcile(
        rows: [NativeLyricsRenderRow],
        width: CGFloat,
        showTranslation: Bool
    ) -> NativeLyricsRenderCacheDecision {
        let nextKeys = Dictionary(uniqueKeysWithValues: rows.map { row in
            (
                row.displayIndex,
                NativeLyricsTextCacheKey(
                    row: row,
                    width: width,
                    showTranslation: showTranslation
                )
            )
        })
        let previousIndices = Set(keysByDisplayIndex.keys)
        let nextIndices = Set(nextKeys.keys)
        var reused = 0
        var invalidated = 0
        var mounted = 0

        for index in nextIndices {
            guard let nextKey = nextKeys[index] else { continue }
            if let previousKey = keysByDisplayIndex[index] {
                if previousKey == nextKey {
                    reused += 1
                } else {
                    invalidated += 1
                }
            } else {
                mounted += 1
            }
        }

        let unmounted = previousIndices.subtracting(nextIndices).count
        keysByDisplayIndex = nextKeys
        return NativeLyricsRenderCacheDecision(
            reusedRowCount: reused,
            invalidatedRowCount: invalidated,
            mountedRowCount: mounted,
            unmountedRowCount: unmounted
        )
    }
}
