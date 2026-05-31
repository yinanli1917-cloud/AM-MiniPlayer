import CryptoKit
import CoreGraphics
import Foundation

struct NativeLyricsRenderPlan: Equatable {
    struct Configuration: Equatable {
        let lyrics: [LyricLine]
        let firstRealLyricIndex: Int
        let currentDisplayIndex: Int
        let anchorY: CGFloat
        let measuredHeights: [Int: CGFloat]
        let rowSpacing: CGFloat
        let defaultRowHeight: CGFloat
        let mode: Mode

        init(
            lyrics: [LyricLine],
            firstRealLyricIndex: Int,
            currentDisplayIndex: Int,
            anchorY: CGFloat,
            measuredHeights: [Int: CGFloat] = [:],
            rowSpacing: CGFloat = 6,
            defaultRowHeight: CGFloat = 36,
            mode: Mode = .natural(waveTargets: [:])
        ) {
            self.lyrics = lyrics
            self.firstRealLyricIndex = firstRealLyricIndex
            self.currentDisplayIndex = currentDisplayIndex
            self.anchorY = anchorY
            self.measuredHeights = measuredHeights
            self.rowSpacing = rowSpacing
            self.defaultRowHeight = defaultRowHeight
            self.mode = mode
        }
    }

    enum Mode: Equatable {
        case natural(waveTargets: [Int: Int])
        case directSnap(targetDisplayIndex: Int, reason: DirectSnapReason)
        case manualScroll(frozenDisplayIndex: Int, manualOffset: CGFloat)
    }

    enum DirectSnapReason: Equatable {
        case initialLayout
        case seek
        case tapToLine
        case trackReset
        case reducedMotion
    }

    let rows: [NativeLyricsRenderRow]
    let renderedIndices: [Int]
    let activeDisplayIndex: Int
    let totalHeight: CGFloat
    let workload: NativeLyricsWorkloadIdentity

    static func make(configuration: Configuration) -> NativeLyricsRenderPlan {
        let renderedIndices = configuration.lyrics.indices.filter {
            $0 == 0 || $0 >= configuration.firstRealLyricIndex
        }
        let activeDisplayIndex = activeDisplayIndex(for: configuration)
        let accumulatedHeights = accumulatedHeights(
            renderedIndices: renderedIndices,
            measuredHeights: configuration.measuredHeights,
            defaultRowHeight: configuration.defaultRowHeight,
            rowSpacing: configuration.rowSpacing
        )
        let totalHeight = totalHeight(
            renderedIndices: renderedIndices,
            measuredHeights: configuration.measuredHeights,
            defaultRowHeight: configuration.defaultRowHeight,
            rowSpacing: configuration.rowSpacing
        )
        let rows = renderedIndices.compactMap { displayIndex -> NativeLyricsRenderRow? in
            guard configuration.lyrics.indices.contains(displayIndex) else { return nil }
            let line = configuration.lyrics[displayIndex]
            let targetDisplayIndex = targetDisplayIndex(
                for: displayIndex,
                activeDisplayIndex: activeDisplayIndex,
                configuration: configuration
            )
            let accumulatedY = accumulatedHeights[displayIndex] ?? 0
            let targetAccumulatedY = accumulatedHeights[targetDisplayIndex] ?? 0
            let height = configuration.measuredHeights[displayIndex] ?? configuration.defaultRowHeight
            let y = configuration.anchorY - targetAccumulatedY + accumulatedY + manualOffset(configuration.mode)
            let visual = NativeLyricsVisualState.make(
                displayIndex: displayIndex,
                activeDisplayIndex: activeDisplayIndex
            )
            return NativeLyricsRenderRow(
                id: "\(displayIndex)-\(line.startTime)-\(line.text)",
                displayIndex: displayIndex,
                sourceIndex: displayIndex,
                text: line.text,
                translation: line.translation,
                words: line.words,
                role: role(
                    displayIndex: displayIndex,
                    line: line,
                    lyrics: configuration.lyrics,
                    firstRealLyricIndex: configuration.firstRealLyricIndex
                ),
                frame: CGRect(x: 0, y: y, width: 0, height: height),
                targetDisplayIndex: targetDisplayIndex,
                visual: visual
            )
        }
        return NativeLyricsRenderPlan(
            rows: rows,
            renderedIndices: renderedIndices,
            activeDisplayIndex: activeDisplayIndex,
            totalHeight: totalHeight,
            workload: NativeLyricsWorkloadIdentity.make(
                lyrics: configuration.lyrics,
                firstRealLyricIndex: configuration.firstRealLyricIndex
            )
        )
    }

    func hitTest(displayPointY: CGFloat) -> NativeLyricsRenderRow? {
        rows.first { $0.frame.minY <= displayPointY && displayPointY <= $0.frame.maxY }
    }

    private static func activeDisplayIndex(for configuration: Configuration) -> Int {
        switch configuration.mode {
        case .manualScroll(let frozenDisplayIndex, _):
            return frozenDisplayIndex
        case .directSnap(let targetDisplayIndex, _):
            return targetDisplayIndex
        case .natural:
            return configuration.currentDisplayIndex
        }
    }

    private static func targetDisplayIndex(
        for displayIndex: Int,
        activeDisplayIndex: Int,
        configuration: Configuration
    ) -> Int {
        switch configuration.mode {
        case .manualScroll(let frozenDisplayIndex, _):
            return frozenDisplayIndex
        case .directSnap(let targetDisplayIndex, _):
            return targetDisplayIndex
        case .natural(let waveTargets):
            return waveTargets[displayIndex] ?? activeDisplayIndex
        }
    }

    private static func manualOffset(_ mode: Mode) -> CGFloat {
        if case .manualScroll(_, let manualOffset) = mode { return manualOffset }
        return 0
    }

    private static func accumulatedHeights(
        renderedIndices: [Int],
        measuredHeights: [Int: CGFloat],
        defaultRowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> [Int: CGFloat] {
        var accumulated: CGFloat = 0
        var result: [Int: CGFloat] = [:]
        for (position, displayIndex) in renderedIndices.enumerated() {
            result[displayIndex] = accumulated
            accumulated += measuredHeights[displayIndex] ?? defaultRowHeight
            if position < renderedIndices.count - 1 {
                accumulated += rowSpacing
            }
        }
        return result
    }

    private static func totalHeight(
        renderedIndices: [Int],
        measuredHeights: [Int: CGFloat],
        defaultRowHeight: CGFloat,
        rowSpacing: CGFloat
    ) -> CGFloat {
        renderedIndices.enumerated().reduce(CGFloat.zero) { partial, item in
            let spacing = item.offset < renderedIndices.count - 1 ? rowSpacing : 0
            return partial + (measuredHeights[item.element] ?? defaultRowHeight) + spacing
        }
    }

    private static func role(
        displayIndex: Int,
        line: LyricLine,
        lyrics: [LyricLine],
        firstRealLyricIndex: Int
    ) -> NativeLyricsRenderRow.Role {
        if line.text.trimmingCharacters(in: .whitespacesAndNewlines) == "⋯" {
            return .preludeDots(endTime: nextRealStartTime(
                after: displayIndex,
                lyrics: lyrics,
                firstRealLyricIndex: firstRealLyricIndex
            ) ?? line.endTime)
        }
        if let next = lyrics.dropFirst(displayIndex + 1).first,
           next.startTime - line.endTime >= 5 {
            return .lyricWithTrailingInterludeDots(startTime: line.endTime, endTime: next.startTime)
        }
        return .lyric
    }

    private static func nextRealStartTime(
        after displayIndex: Int,
        lyrics: [LyricLine],
        firstRealLyricIndex: Int
    ) -> TimeInterval? {
        let start = max(displayIndex + 1, firstRealLyricIndex)
        guard start < lyrics.count else { return nil }
        for index in start..<lyrics.count {
            let text = lyrics[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && text != "⋯" {
                return lyrics[index].startTime
            }
        }
        return nil
    }
}

struct NativeLyricsRenderRow: Equatable, Identifiable {
    enum Role: Equatable {
        case preludeDots(endTime: TimeInterval)
        case lyric
        case lyricWithTrailingInterludeDots(startTime: TimeInterval, endTime: TimeInterval)
    }

    let id: String
    let displayIndex: Int
    let sourceIndex: Int
    let text: String
    let translation: String?
    let words: [LyricWord]
    let role: Role
    let frame: CGRect
    let targetDisplayIndex: Int
    let visual: NativeLyricsVisualState

    var hasSyllableSync: Bool { !words.isEmpty }
}

struct NativeLyricsVisualState: Equatable {
    let opacity: CGFloat
    let scale: CGFloat
    let blurRadius: CGFloat
    let isActive: Bool

    static func make(displayIndex: Int, activeDisplayIndex: Int) -> NativeLyricsVisualState {
        let distance = abs(displayIndex - activeDisplayIndex)
        if distance == 0 {
            return NativeLyricsVisualState(opacity: 1, scale: 1, blurRadius: 0, isActive: true)
        }
        return NativeLyricsVisualState(
            opacity: 0.35,
            scale: 0.95,
            blurRadius: CGFloat(distance) * 1.5,
            isActive: false
        )
    }
}

struct NativeLyricsWorkloadIdentity: Equatable {
    let lineCount: Int
    let hasSyllableSync: Bool
    let firstRealLineSHA256: String?

    static func make(lyrics: [LyricLine], firstRealLyricIndex: Int) -> NativeLyricsWorkloadIdentity {
        let firstRealLine = lyrics.dropFirst(firstRealLyricIndex).first {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text != "⋯"
        }
        return NativeLyricsWorkloadIdentity(
            lineCount: lyrics.count,
            hasSyllableSync: lyrics.contains { $0.hasSyllableSync },
            firstRealLineSHA256: firstRealLine.map { sha256($0.text) }
        )
    }

    private static func sha256(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
