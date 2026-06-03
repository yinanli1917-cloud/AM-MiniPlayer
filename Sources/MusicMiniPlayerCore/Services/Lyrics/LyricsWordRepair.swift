import Foundation

enum LyricsWordRepair {
    private static let contractionSuffixes = [
        "IT'S",
        "I'M",
        "I'LL",
        "I'D",
        "DON'T",
        "CAN'T",
        "WON'T",
        "YOU'RE",
        "YOU'VE",
        "YOU'LL",
        "WE'RE",
        "WE'VE",
        "WE'LL",
        "HE'S",
        "HE'D",
        "HE'LL",
        "SHE'S",
        "SHE'D",
        "SHE'LL",
        "THEY'RE",
        "THEY'VE",
        "THEY'LL",
        "THAT'S",
        "THERE'S",
    ]

    static func repair(lines: [LyricLine]) -> [LyricLine] {
        lines.map(repair(line:))
    }

    static func repair(line: LyricLine) -> LyricLine {
        guard !line.words.isEmpty else { return line }
        let repairedWords = repair(words: line.words)
        guard repairedWords != line.words else { return line }
        let repairedText = repairedWords
            .map(\.word)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LyricLine(
            text: repairedText.isEmpty ? line.text : repairedText,
            startTime: line.startTime,
            endTime: line.endTime,
            words: repairedWords,
            translation: line.translation
        )
    }

    private static func repair(words: [LyricWord]) -> [LyricWord] {
        var repaired: [LyricWord] = []
        repaired.reserveCapacity(words.count)
        for word in words {
            if let split = splitMergedLatinContraction(word) {
                repaired.append(contentsOf: split)
            } else {
                repaired.append(word)
            }
        }
        return repaired
    }

    private static func splitMergedLatinContraction(_ word: LyricWord) -> [LyricWord]? {
        let raw = word.word
        let trailingWhitespace = raw.reversed().prefix { $0.isWhitespace }.reversed()
        let core = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard core.count >= 8, !core.contains(where: \.isWhitespace) else { return nil }
        guard isASCIIUppercaseContractionCore(core) else { return nil }

        for suffix in contractionSuffixes {
            guard core.count > suffix.count + 3, core.hasSuffix(suffix) else { continue }
            let splitOffset = core.count - suffix.count
            let prefixEnd = core.index(core.startIndex, offsetBy: splitOffset)
            let prefix = String(core[..<prefixEnd])
            let suffixText = String(core[prefixEnd...])
            guard isASCIIUppercaseWord(prefix), isASCIIUppercaseContractionCore(suffixText) else { continue }

            let duration = max(0, word.endTime - word.startTime)
            guard duration > 0 else { return nil }
            let totalWeight = Double(prefix.count + suffixText.count)
            let prefixWeight = Double(prefix.count) / max(1, totalWeight)
            let splitTime = word.startTime + duration * prefixWeight

            return [
                LyricWord(
                    word: prefix + " ",
                    startTime: word.startTime,
                    endTime: splitTime
                ),
                LyricWord(
                    word: suffixText + String(trailingWhitespace),
                    startTime: splitTime,
                    endTime: word.endTime
                )
            ]
        }

        return nil
    }

    private static func isASCIIUppercaseWord(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && CharacterSet.uppercaseLetters.contains(scalar)
        }
    }

    private static func isASCIIUppercaseContractionCore(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            if scalar == "'" || scalar == "\u{2019}" {
                return true
            }
            return scalar.isASCII && CharacterSet.uppercaseLetters.contains(scalar)
        }
    }
}
