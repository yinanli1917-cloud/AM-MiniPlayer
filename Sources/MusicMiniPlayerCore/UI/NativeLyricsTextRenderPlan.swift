import CoreGraphics
import Foundation

struct NativeLyricsTextRenderPlan: Equatable {
    struct Configuration: Equatable {
        let line: LyricLine
        let currentTime: TimeInterval
        let isActive: Bool
        let staticOpacity: CGFloat
        let showTranslation: Bool

        init(
            line: LyricLine,
            currentTime: TimeInterval,
            isActive: Bool,
            staticOpacity: CGFloat = 0.35,
            showTranslation: Bool = true
        ) {
            self.line = line
            self.currentTime = currentTime
            self.isActive = isActive
            self.staticOpacity = staticOpacity
            self.showTranslation = showTranslation
        }
    }

    let displayText: String
    let wordRuns: [NativeLyricsWordRunPlan]
    let mainSweepProgress: CGFloat
    let mainPostLineFade: CGFloat
    let translation: NativeLyricsTranslationRenderPlan?
    let constants: NativeLyricsTextConstants

    static func make(configuration: Configuration) -> NativeLyricsTextRenderPlan {
        let constants = NativeLyricsTextConstants()
        let line = configuration.line
        let displayText = cleanedDisplayText(for: line)
        let tokens = LyricDisplaySegmenter.displayTokens(forWords: line.words)
        let lineEndTime = line.words.last?.endTime ?? line.endTime
        let mainSweepProgress = configuration.isActive
            ? wordCountProgress(
                words: line.words,
                currentTime: configuration.currentTime,
                lineStartTime: line.startTime,
                lineEndTime: lineEndTime
            )
            : 1
        let mainPostLineFade = postLineFadeOut(currentTime: configuration.currentTime, lineEndTime: lineEndTime)
        let runs = tokens.enumerated().map { index, token in
            NativeLyricsWordRunPlan.make(
                token: token,
                tokenIndex: index,
                tokenCount: tokens.count,
                lineEndTime: lineEndTime,
                currentTime: configuration.currentTime,
                isActiveLine: configuration.isActive,
                staticOpacity: configuration.staticOpacity,
                constants: constants
            )
        }
        let translation = makeTranslationPlan(
            line: line,
            currentTime: configuration.currentTime,
            isActiveLine: configuration.isActive,
            staticOpacity: configuration.staticOpacity,
            showTranslation: configuration.showTranslation,
            constants: constants
        )
        return NativeLyricsTextRenderPlan(
            displayText: displayText,
            wordRuns: runs,
            mainSweepProgress: mainSweepProgress,
            mainPostLineFade: mainPostLineFade,
            translation: translation,
            constants: constants
        )
    }

    private static func cleanedDisplayText(for line: LyricLine) -> String {
        let pattern = "\\[\\d{2}:\\d{2}[:.]*\\d{0,3}\\]"
        var text = line.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if line.hasSyllableSync && !line.words.isEmpty {
            let totalCharacters = line.words.reduce(0) { $0 + $1.word.count }
            let averageLength = Double(totalCharacters) / Double(line.words.count)
            if averageLength <= 2 {
                text = line.words.map(\.word).joined()
            }
        }
        return text
    }

    private static func makeTranslationPlan(
        line: LyricLine,
        currentTime: TimeInterval,
        isActiveLine: Bool,
        staticOpacity: CGFloat,
        showTranslation: Bool,
        constants: NativeLyricsTextConstants
    ) -> NativeLyricsTranslationRenderPlan? {
        guard showTranslation,
              let translation = line.translation,
              !translation.isEmpty else { return nil }
        let progress = line.hasSyllableSync
            ? wordCountProgress(words: line.words, currentTime: currentTime, lineStartTime: line.startTime, lineEndTime: line.endTime)
            : linearProgress(currentTime: currentTime, startTime: line.startTime, endTime: line.endTime)
        let postLineFade = postLineFadeOut(currentTime: currentTime, lineEndTime: line.endTime)
        let opacity = isActiveLine
            ? constants.translationBrightAlpha
            : staticOpacity * constants.currentTranslationOpacityFactor
        return NativeLyricsTranslationRenderPlan(
            text: translation,
            progress: isActiveLine ? progress : 1,
            opacity: opacity,
            dimAlpha: constants.translationDimAlpha,
            brightAlpha: constants.translationBrightAlpha,
            fadeHalfPoint: constants.translationFadeHalfPoint,
            postLineFade: postLineFade
        )
    }

    private static func wordCountProgress(
        words: [LyricWord],
        currentTime: TimeInterval,
        lineStartTime: TimeInterval,
        lineEndTime: TimeInterval
    ) -> CGFloat {
        guard !words.isEmpty else {
            return linearProgress(currentTime: currentTime, startTime: lineStartTime, endTime: lineEndTime)
        }
        let count = CGFloat(words.count)
        for (index, word) in words.enumerated() {
            if currentTime < word.startTime { return CGFloat(index) / count }
            if currentTime < word.endTime {
                return (CGFloat(index) + CGFloat(word.progress(at: currentTime))) / count
            }
        }
        return 1
    }

    private static func linearProgress(
        currentTime: TimeInterval,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) -> CGFloat {
        guard endTime > startTime else { return currentTime >= startTime ? 1 : 0 }
        if currentTime <= startTime { return 0 }
        if currentTime >= endTime { return 1 }
        return CGFloat((currentTime - startTime) / (endTime - startTime))
    }

    static func postLineFadeOut(currentTime: TimeInterval, lineEndTime: TimeInterval) -> CGFloat {
        let fadeOutDuration: TimeInterval = 1.5
        let timeSinceLineEnd = currentTime - lineEndTime
        guard timeSinceLineEnd > 0 else { return 1 }
        if timeSinceLineEnd >= fadeOutDuration { return 0 }
        let t = timeSinceLineEnd / fadeOutDuration
        return CGFloat(1 - t * t)
    }
}

struct NativeLyricsTextConstants: Equatable {
    let mainFontSize: CGFloat = 24
    let translationFontSize: CGFloat = 24 * 0.67
    let brightAlpha: CGFloat = 0.85
    let dimAlpha: CGFloat = 0.25
    let fadeHalfPoint: CGFloat = 12
    let translationBrightAlpha: CGFloat = 0.75
    let translationDimAlpha: CGFloat = 0.20
    let translationFadeHalfPoint: CGFloat = 8
    let currentTranslationOpacityFactor: CGFloat = 0.85
    let baseFloatTargetY: CGFloat = -2
}

struct NativeLyricsWordRunPlan: Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let progress: CGFloat
    let isCJK: Bool
    let isEmphasis: Bool
    let baseFloatY: CGFloat
    let opacity: CGFloat
    let sweep: NativeLyricsSweepPlan
    let emphasis: NativeLyricsEmphasisPlan

    static func make(
        token: LyricTimedDisplayToken,
        tokenIndex: Int,
        tokenCount: Int,
        lineEndTime: TimeInterval,
        currentTime: TimeInterval,
        isActiveLine: Bool,
        staticOpacity: CGFloat,
        constants: NativeLyricsTextConstants
    ) -> NativeLyricsWordRunPlan {
        let word = token.word
        let duration = word.endTime - word.startTime
        let progress = CGFloat(word.progress(at: currentTime))
        let isCJK = LanguageUtils.containsCJK(word.word)
        let isEmphasis = !isCJK && shouldEmphasize(token.text, duration: duration)
        let postLineFade = NativeLyricsTextRenderPlan.postLineFadeOut(
            currentTime: currentTime,
            lineEndTime: lineEndTime
        )
        let opacity = isActiveLine ? constants.brightAlpha : staticOpacity
        let baseFloatY = isActiveLine
            ? baseFloat(
                currentTime: currentTime,
                startTime: word.startTime,
                endTime: word.endTime,
                targetY: constants.baseFloatTargetY
            )
            : 0
        let emphasis = NativeLyricsEmphasisPlan.make(
            text: token.text,
            duration: duration,
            isLastWordOfLine: tokenIndex == tokenCount - 1,
            isCJK: isCJK,
            currentTime: currentTime,
            wordStartTime: word.startTime
        )
        return NativeLyricsWordRunPlan(
            text: token.text,
            startTime: word.startTime,
            endTime: word.endTime,
            progress: isActiveLine ? progress : 1,
            isCJK: isCJK,
            isEmphasis: isEmphasis,
            baseFloatY: baseFloatY,
            opacity: opacity,
            sweep: NativeLyricsSweepPlan(
                progress: isActiveLine ? progress : 1,
                dimAlpha: constants.dimAlpha,
                brightAlpha: constants.brightAlpha,
                fadeHalfPoint: constants.fadeHalfPoint,
                postLineFade: postLineFade
            ),
            emphasis: isActiveLine ? emphasis : .inactive
        )
    }

    private static func shouldEmphasize(_ text: String, duration: TimeInterval) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return false
        }
        return duration >= 1.5 && trimmed.count > 1 && trimmed.count <= 7
    }

    private static func baseFloat(
        currentTime: TimeInterval,
        startTime: TimeInterval,
        endTime: TimeInterval,
        targetY: CGFloat
    ) -> CGFloat {
        guard currentTime >= startTime else { return 0 }
        let wordDuration = endTime - startTime
        let floatDuration = max(1.0, wordDuration)
        let elapsed = currentTime - startTime
        if elapsed >= floatDuration { return targetY }
        let t = CGFloat(elapsed / floatDuration)
        let eased = NativeLyricsEasing.cubicBezier(x1: 0, y1: 0, x2: 0.58, y2: 1, x: t)
        return targetY * eased
    }
}

struct NativeLyricsSweepPlan: Equatable {
    let progress: CGFloat
    let dimAlpha: CGFloat
    let brightAlpha: CGFloat
    let fadeHalfPoint: CGFloat
    let postLineFade: CGFloat
}

struct NativeLyricsTranslationRenderPlan: Equatable {
    let text: String
    let progress: CGFloat
    let opacity: CGFloat
    let dimAlpha: CGFloat
    let brightAlpha: CGFloat
    let fadeHalfPoint: CGFloat
    let postLineFade: CGFloat
}

struct NativeLyricsEmphasisPlan: Equatable {
    static let inactive = NativeLyricsEmphasisPlan(
        amount: 0,
        blurLevel: 0,
        scale: 1,
        liftY: 0,
        floatY: 0,
        glowOpacity: 0,
        glowRadius: 0
    )

    let amount: CGFloat
    let blurLevel: CGFloat
    let scale: CGFloat
    let liftY: CGFloat
    let floatY: CGFloat
    let glowOpacity: CGFloat
    let glowRadius: CGFloat

    static func make(
        text: String,
        duration: TimeInterval,
        isLastWordOfLine: Bool,
        isCJK: Bool,
        currentTime: TimeInterval,
        wordStartTime: TimeInterval
    ) -> NativeLyricsEmphasisPlan {
        guard !isCJK,
              duration >= 1.5,
              text.trimmingCharacters(in: .whitespaces).count > 1 else {
            return .inactive
        }
        let amount = emphasisAmount(duration: duration, isLast: isLastWordOfLine)
        let blurLevel = emphasisBlurLevel(duration: duration, isLast: isLastWordOfLine)
        let du = max(1.0, duration) * (isLastWordOfLine ? 1.2 : 1.0)
        let progress = CGFloat(min(1, max(0, (currentTime - wordStartTime) / du)))
        let easing = NativeLyricsEasing.emphasis(progress)
        let scale = 1 + easing * 0.1 * amount
        let liftY = -easing * 0.6 * amount
        let floatDuration = du * 1.4
        let floatProgress = CGFloat(min(1, max(0, (currentTime - wordStartTime + 0.4) / floatDuration)))
        let floatY = (floatProgress > 0 && floatProgress < 1) ? -sin(floatProgress * .pi) * 1.5 : 0
        return NativeLyricsEmphasisPlan(
            amount: amount,
            blurLevel: blurLevel,
            scale: scale,
            liftY: liftY,
            floatY: floatY,
            glowOpacity: easing * blurLevel * 1.5,
            glowRadius: 12
        )
    }

    private static func emphasisAmount(duration: TimeInterval, isLast: Bool) -> CGFloat {
        var amount = duration / 2.0
        amount = amount > 1 ? sqrt(amount) : amount * amount * amount
        amount *= 0.6
        if isLast { amount *= 1.6 }
        return min(1.2, amount)
    }

    private static func emphasisBlurLevel(duration: TimeInterval, isLast: Bool) -> CGFloat {
        var blur = duration / 3.0
        blur = blur > 1 ? sqrt(blur) : blur * blur * blur
        blur *= 0.5
        if isLast { blur *= 1.5 }
        return min(0.8, blur)
    }
}

enum NativeLyricsEasing {
    static func emphasis(_ x: CGFloat, mid: CGFloat = 0.5) -> CGFloat {
        guard x > 0 && x < 1 else { return 0 }
        if x < mid {
            return cubicBezier(x1: 0.2, y1: 0.4, x2: 0.58, y2: 1.0, x: min(1, max(0, x / mid)))
        } else {
            return 1 - cubicBezier(x1: 0.3, y1: 0.0, x2: 0.58, y2: 1.0, x: min(1, max(0, (x - mid) / (1 - mid))))
        }
    }

    static func cubicBezier(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, x: CGFloat) -> CGFloat {
        guard x > 0 && x < 1 else { return x <= 0 ? 0 : 1 }
        var t = x
        for _ in 0..<8 {
            let bx = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t - x
            let dx = 3 * (1 - t) * (1 - t) * x1 + 6 * (1 - t) * t * (x2 - x1) + 3 * t * t * (1 - x2)
            guard abs(dx) > 1e-6 else { break }
            t -= bx / dx
            t = min(1, max(0, t))
        }
        return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
    }
}
