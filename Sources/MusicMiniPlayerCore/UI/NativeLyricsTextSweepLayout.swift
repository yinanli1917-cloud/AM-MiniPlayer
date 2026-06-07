import AppKit
import CoreGraphics
import Foundation

struct NativeLyricsTextSweepMaskLine: Equatable {
    let maskRect: CGRect
    let wavefrontX: CGFloat
}

struct NativeLyricsTranslationSweepMaskLine: Equatable {
    let maskRect: CGRect
    let wavefrontX: CGFloat
}

struct NativeLyricsTranslationSweepVisualLinePlan: Equatable {
    let rect: CGRect
    let width: CGFloat
}

struct NativeLyricsTextSweepVisualRun: Equatable {
    struct Glyph: Equatable {
        let index: Int
        let text: String
        let rect: CGRect
    }

    let order: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let isEmphasis: Bool
    let rect: CGRect
    let glyphs: [Glyph]
}

struct NativeLyricsTextSweepVisualLinePlan: Equatable {
    let maskRect: CGRect
    let runs: [NativeLyricsTextSweepVisualRun]
}

private struct NativeLyricsTextLineFragment {
    let rect: CGRect
    let glyphRange: NSRange
}

private struct NativeLyricsTokenGlyphPlan {
    let glyph: NativeLyricsTextSweepVisualRun.Glyph
    let glyphRange: NSRange
}

enum NativeLyricsTextSweepLayout {
    static func make(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat,
        fadeHalfPoint: CGFloat,
        currentTime: TimeInterval
    ) -> [NativeLyricsTextSweepMaskLine] {
        maskLines(
            from: makePlan(
                displayText: displayText,
                wordRuns: wordRuns,
                width: width,
                fontSize: fontSize,
                fadeHalfPoint: fadeHalfPoint
            ),
            fadeHalfPoint: fadeHalfPoint,
            currentTime: currentTime
        )
    }

    static func makePlan(
        displayText: String,
        wordRuns: [NativeLyricsWordRunPlan],
        width: CGFloat,
        fontSize: CGFloat,
        fadeHalfPoint: CGFloat
    ) -> [NativeLyricsTextSweepVisualLinePlan] {
        guard !displayText.isEmpty, !wordRuns.isEmpty, width > 1 else { return [] }

        let attributed = NSAttributedString(
            string: displayText,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            ]
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var fragments: [NativeLyricsTextLineFragment] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            fragments.append(NativeLyricsTextLineFragment(rect: usedRect, glyphRange: lineGlyphRange))
        }
        guard !fragments.isEmpty else { return [] }

        var visualRunsByLine: [Int: [NativeLyricsTextSweepVisualRun]] = [:]
        let nsText = displayText as NSString
        var characterLocation = 0
        for (order, run) in wordRuns.enumerated() {
            let tokenLength = (run.text as NSString).length
            defer { characterLocation += tokenLength }
            guard tokenLength > 0, characterLocation < nsText.length else { continue }
            let clampedLength = min(tokenLength, nsText.length - characterLocation)
            let characterRange = NSRange(location: characterLocation, length: clampedLength)
            var actualCharacterRange = NSRange(location: NSNotFound, length: 0)
            let tokenGlyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: &actualCharacterRange
            )
            guard tokenGlyphRange.location != NSNotFound, tokenGlyphRange.length > 0 else { continue }
            let tokenRect = layoutManager.boundingRect(forGlyphRange: tokenGlyphRange, in: textContainer)
            guard tokenRect.width > 0, tokenRect.height > 0 else { continue }
            let glyphPlans = glyphPlans(
                for: run.text,
                characterRange: characterRange,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            var matchedFragment = false
            for (lineIndex, fragment) in fragments.enumerated() {
                let fragmentGlyphRange = NSIntersectionRange(fragment.glyphRange, tokenGlyphRange)
                guard fragmentGlyphRange.length > 0 else { continue }
                let fragmentGlyphs = glyphPlans
                    .filter { NSIntersectionRange($0.glyphRange, fragmentGlyphRange).length > 0 }
                    .map(\.glyph)
                let fragmentRect = glyphBoundingRect(
                    for: fragmentGlyphRange,
                    fallback: tokenRect,
                    glyphs: fragmentGlyphs,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
                guard fragmentRect.width > 0, fragmentRect.height > 0 else { continue }
                matchedFragment = true
                visualRunsByLine[lineIndex, default: []].append(NativeLyricsTextSweepVisualRun(
                    order: order,
                    startTime: run.startTime,
                    endTime: run.endTime,
                    text: run.text,
                    isEmphasis: run.isEmphasis || run.emphasis != .inactive,
                    rect: fragmentRect,
                    glyphs: fragmentGlyphs
                ))
            }

            if matchedFragment {
                continue
            }

            let lineIndex = nearestFragmentIndex(to: tokenRect, in: fragments)
            visualRunsByLine[lineIndex, default: []].append(NativeLyricsTextSweepVisualRun(
                order: order,
                startTime: run.startTime,
                endTime: run.endTime,
                text: run.text,
                isEmphasis: run.isEmphasis || run.emphasis != .inactive,
                rect: tokenRect,
                glyphs: glyphPlans.map(\.glyph)
            ))
        }

        return visualRunsByLine.keys.sorted().compactMap { lineIndex in
            guard var visualRuns = visualRunsByLine[lineIndex], !visualRuns.isEmpty else { return nil }
            visualRuns.sort {
                if $0.order == $1.order {
                    return $0.rect.minX < $1.rect.minX
                }
                return $0.order < $1.order
            }

            var maskRect = fragments[lineIndex].rect
            for visualRun in visualRuns {
                maskRect = maskRect.union(visualRun.rect)
            }
            maskRect = maskRect.insetBy(dx: -20, dy: -4)
            return NativeLyricsTextSweepVisualLinePlan(maskRect: maskRect, runs: visualRuns)
        }
    }

    static func maskLines(
        from plan: [NativeLyricsTextSweepVisualLinePlan],
        fadeHalfPoint: CGFloat,
        currentTime: TimeInterval
    ) -> [NativeLyricsTextSweepMaskLine] {
        plan.compactMap { line in
            guard !line.runs.isEmpty else { return nil }
            let wavefront = wavefrontX(
                for: line,
                fadeHalfPoint: fadeHalfPoint,
                currentTime: currentTime
            )
            return NativeLyricsTextSweepMaskLine(maskRect: line.maskRect, wavefrontX: wavefront)
        }
    }

    static func wavefrontX(
        for line: NativeLyricsTextSweepVisualLinePlan,
        fadeHalfPoint: CGFloat,
        currentTime: TimeInterval
    ) -> CGFloat {
        guard !line.runs.isEmpty else { return 0 }
        var wavefront = line.runs[0].rect.minX - fadeHalfPoint
        var previousSweepEnd = wavefront
        for visualRun in line.runs {
            let sweepStart = visualRun.rect.minX - fadeHalfPoint
            let sweepEnd = visualRun.rect.maxX + fadeHalfPoint
            let advanceFrom = previousSweepEnd
            if currentTime >= visualRun.endTime {
                wavefront = sweepEnd
            } else if currentTime > visualRun.startTime {
                let duration = visualRun.endTime - visualRun.startTime
                let progress = duration > 0
                    ? CGFloat((currentTime - visualRun.startTime) / duration)
                    : 1
                wavefront = advanceFrom + (sweepEnd - advanceFrom) * min(1, max(0, progress))
                break
            } else {
                wavefront = min(wavefront, sweepStart)
                break
            }
            previousSweepEnd = sweepEnd
        }
        return wavefront
    }

    private static func nearestFragmentIndex(
        to rect: CGRect,
        in fragments: [NativeLyricsTextLineFragment]
    ) -> Int {
        guard !fragments.isEmpty else { return 0 }
        return fragments.indices.min { lhs, rhs in
            abs(fragments[lhs].rect.midY - rect.midY) < abs(fragments[rhs].rect.midY - rect.midY)
        } ?? 0
    }

    private static func glyphBoundingRect(
        for glyphRange: NSRange,
        fallback: CGRect,
        glyphs: [NativeLyricsTextSweepVisualRun.Glyph],
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> CGRect {
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        if rect.width > 0, rect.height > 0 {
            return rect
        }
        if let first = glyphs.first {
            rect = first.rect
            for glyph in glyphs.dropFirst() {
                rect = rect.union(glyph.rect)
            }
            return rect
        }
        return fallback
    }

    private static func glyphPlans(
        for token: String,
        characterRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [NativeLyricsTokenGlyphPlan] {
        let nsToken = token as NSString
        guard nsToken.length > 0 else { return [] }
        var glyphs: [NativeLyricsTokenGlyphPlan] = []
        glyphs.reserveCapacity(nsToken.length)

        for tokenOffset in 0..<nsToken.length {
            let tokenCharacter = nsToken.substring(with: NSRange(location: tokenOffset, length: 1))
            guard !tokenCharacter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let location = characterRange.location + tokenOffset
            guard location < characterRange.location + characterRange.length else { continue }
            let charRange = NSRange(location: location, length: 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: charRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { continue }
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard rect.width > 0, rect.height > 0 else { continue }
            glyphs.append(NativeLyricsTokenGlyphPlan(
                glyph: NativeLyricsTextSweepVisualRun.Glyph(
                    index: glyphs.count,
                    text: tokenCharacter,
                    rect: rect
                ),
                glyphRange: glyphRange
            ))
        }
        return glyphs
    }
}

enum NativeLyricsTranslationSweepLayout {
    static func makePlan(
        text: String,
        width: CGFloat,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> [NativeLyricsTranslationSweepVisualLinePlan] {
        guard !text.isEmpty, width > 1 else { return [] }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .paragraphStyle: paragraph
            ]
        )
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lines: [NativeLyricsTranslationSweepVisualLinePlan] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
            guard usedRect.width > 0, usedRect.height > 0 else { return }
            lines.append(NativeLyricsTranslationSweepVisualLinePlan(
                rect: usedRect,
                width: usedRect.width
            ))
        }
        return lines
    }

    static func maskLines(
        from plan: [NativeLyricsTranslationSweepVisualLinePlan],
        progress: CGFloat,
        fadeHalfPoint: CGFloat
    ) -> [NativeLyricsTranslationSweepMaskLine] {
        guard !plan.isEmpty else { return [] }
        let totalWidth = plan.reduce(CGFloat.zero) { $0 + $1.width }
        guard totalWidth > 0 else { return [] }
        let filledWidth = min(1, max(0, progress)) * totalWidth
        var accumulated: CGFloat = 0
        var lines: [NativeLyricsTranslationSweepMaskLine] = []
        for line in plan {
            let localFilled = filledWidth - accumulated
            defer { accumulated += line.width }
            let maskRect = line.rect.insetBy(dx: -20, dy: -20)
            let wavefront: CGFloat
            if localFilled <= 0 {
                wavefront = maskRect.minX - fadeHalfPoint
            } else {
                let localProgress = min(1, max(0, localFilled / max(1, line.width)))
                wavefront = line.rect.minX + line.rect.width * localProgress
            }
            lines.append(NativeLyricsTranslationSweepMaskLine(
                maskRect: maskRect,
                wavefrontX: wavefront
            ))
        }
        return lines
    }

    static func maskLinesSequential(
        from plan: [NativeLyricsTranslationSweepVisualLinePlan],
        currentTime: TimeInterval,
        lineStartTime: TimeInterval,
        lineEndTime: TimeInterval,
        fadeHalfPoint: CGFloat
    ) -> [NativeLyricsTranslationSweepMaskLine] {
        guard !plan.isEmpty else { return [] }
        let n = plan.count
        let totalDuration = lineEndTime - lineStartTime
        guard totalDuration > 0 else {
            return maskLines(from: plan, progress: 1, fadeHalfPoint: fadeHalfPoint)
        }
        var lines: [NativeLyricsTranslationSweepMaskLine] = []
        for (index, line) in plan.enumerated() {
            let segmentStart = lineStartTime + totalDuration * Double(index) / Double(n)
            let segmentEnd = lineStartTime + totalDuration * Double(index + 1) / Double(n)
            let segmentDuration = segmentEnd - segmentStart
            let localProgress: CGFloat
            if currentTime >= segmentEnd {
                localProgress = 1
            } else if currentTime <= segmentStart || segmentDuration <= 0 {
                localProgress = 0
            } else {
                localProgress = CGFloat((currentTime - segmentStart) / segmentDuration)
            }
            let maskRect = line.rect.insetBy(dx: -20, dy: -20)
            let wavefront: CGFloat
            if localProgress <= 0 {
                wavefront = maskRect.minX - fadeHalfPoint
            } else {
                wavefront = line.rect.minX + line.rect.width * min(1, localProgress)
            }
            lines.append(NativeLyricsTranslationSweepMaskLine(
                maskRect: maskRect,
                wavefrontX: wavefront
            ))
        }
        return lines
    }
}
