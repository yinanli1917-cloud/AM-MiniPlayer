/**
 * [INPUT]: No external dependencies.
 * [OUTPUT]: Development-only native lyrics fixtures.
 * [POS]: Stable in-app lyrics samples for no-mouse visual verification.
 */

import Foundation

#if DEBUG || LOCAL_DEVELOPER_BUILD
public struct NativeLyricsDebugFixtureData {
    public let name: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: TimeInterval
    public let startTime: TimeInterval
    public let firstRealLyricIndex: Int
    public let lyrics: [LyricLine]
    public let showTranslation: Bool
}

public enum NativeLyricsDebugFixture {
    public static func fixture(named rawName: String) -> NativeLyricsDebugFixtureData? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "", "translated-word", "line-breakup-truth", "native":
            return translatedWordFixture(name: name.isEmpty ? "translated-word" : name)
        default:
            return nil
        }
    }

    private static func translatedWordFixture(name: String) -> NativeLyricsDebugFixtureData {
        let lyrics: [LyricLine] = [
            LyricLine(text: "⋯", startTime: 0.0, endTime: 1.8),
            wordLine(
                start: 1.8,
                parts: [
                    ("You ", 0.34), ("keep ", 0.32), ("arriving ", 0.58),
                    ("before ", 0.44), ("the ", 0.18), ("light", 0.54)
                ],
                translation: "你总是在光出现之前抵达"
            ),
            wordLine(
                start: 5.0,
                parts: [
                    ("This ", 0.20), ("line ", 0.26), ("is ", 0.18),
                    ("intentionally ", 0.70), ("long ", 0.26), ("enough ", 0.42),
                    ("to ", 0.16), ("wrap ", 0.30), ("inside ", 0.36),
                    ("the ", 0.16), ("small ", 0.34), ("window", 0.50)
                ],
                translation: "这一行故意写得更长，用来验证小窗口里的换行不会被裁掉"
            ),
            wordLine(
                start: 9.2,
                parts: [
                    ("风", 0.20), ("吹", 0.20), ("过", 0.24),
                    ("玻", 0.18), ("璃", 0.20), ("，", 0.12),
                    ("字", 0.22), ("还", 0.18), ("在", 0.18), ("发", 0.20), ("亮", 0.34)
                ],
                translation: "The letters keep glowing after the wind passes."
            ),
            wordLine(
                start: 12.9,
                parts: [
                    ("何", 0.22), ("度", 0.22), ("で", 0.20), ("も", 0.20),
                    (" ", 0.02), ("名前", 0.38), ("を", 0.18),
                    ("呼", 0.22), ("び", 0.20), ("直", 0.22), ("す", 0.28)
                ],
                translation: "No matter how many times, I call the name again."
            ),
            wordLine(
                start: 16.6,
                parts: [
                    ("hold ", 0.58), ("on ", 0.42), ("to ", 0.20),
                    ("the ", 0.18), ("held ", 0.62), ("word", 0.72)
                ],
                translation: "抓住那个被延长的词"
            ),
            LyricLine(text: "⋯", startTime: 20.2, endTime: 24.3),
            wordLine(
                start: 24.3,
                parts: [
                    ("The ", 0.20), ("next ", 0.26), ("line ", 0.30),
                    ("should ", 0.32), ("return ", 0.42), ("with ", 0.24),
                    ("a ", 0.12), ("spring", 0.58)
                ],
                translation: "下一行应该带着弹簧感回来"
            )
        ]

        return NativeLyricsDebugFixtureData(
            name: name,
            title: "Native Lyrics Visual Fixture",
            artist: "nanoPod Debug",
            album: "No-Mouse Verification",
            duration: 31.0,
            startTime: 0.0,
            firstRealLyricIndex: 1,
            lyrics: lyrics,
            showTranslation: true
        )
    }

    private static func wordLine(
        start: TimeInterval,
        parts: [(String, TimeInterval)],
        translation: String
    ) -> LyricLine {
        var cursor = start
        let words = parts.map { part, duration in
            let word = LyricWord(word: part, startTime: cursor, endTime: cursor + duration)
            cursor += duration
            return word
        }
        let text = parts.map(\.0).joined()
        return LyricLine(text: text, startTime: start, endTime: cursor, words: words, translation: translation)
    }
}
#endif
