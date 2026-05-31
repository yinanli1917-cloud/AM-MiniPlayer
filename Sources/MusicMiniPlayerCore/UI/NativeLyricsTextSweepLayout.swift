import AppKit
import CoreGraphics
import Foundation

struct NativeLyricsTextSweepMaskLine: Equatable {
    let maskRect: CGRect
    let wavefrontX: CGFloat
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
            let glyphs = glyphPlans(
                for: run.text,
                characterRange: characterRange,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            let lineIndex = fragments.firstIndex { fragment in
                NSIntersectionRange(fragment.glyphRange, tokenGlyphRange).length > 0
            } ?? nearestFragmentIndex(to: tokenRect, in: fragments)
            visualRunsByLine[lineIndex, default: []].append(NativeLyricsTextSweepVisualRun(
                order: order,
                startTime: run.startTime,
                endTime: run.endTime,
                text: run.text,
                isEmphasis: run.isEmphasis || run.emphasis != .inactive,
                rect: tokenRect,
                glyphs: glyphs
            ))
        }

        return visualRunsByLine.keys.sorted().compactMap { lineIndex in
            guard var visualRuns = visualRunsByLine[lineIndex], !visualRuns.isEmpty else { return nil }
            visualRuns.sort { $0.order < $1.order }

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

    private static func glyphPlans(
        for token: String,
        characterRange: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [NativeLyricsTextSweepVisualRun.Glyph] {
        let nsToken = token as NSString
        guard nsToken.length > 0 else { return [] }
        var glyphs: [NativeLyricsTextSweepVisualRun.Glyph] = []
        glyphs.reserveCapacity(nsToken.length)

        for tokenOffset in 0..<nsToken.length {
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
            glyphs.append(NativeLyricsTextSweepVisualRun.Glyph(
                index: glyphs.count,
                text: nsToken.substring(with: NSRange(location: tokenOffset, length: 1)),
                rect: rect
            ))
        }
        return glyphs
    }
}
