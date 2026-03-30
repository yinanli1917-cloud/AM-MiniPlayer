/**
 * [INPUT]: LyricLine (歌词数据模型), MusicController (播放时间)
 * [OUTPUT]: LyricLineView, InterludeDotsView (+ PreludeDotsView alias), TranslationLoadingDotsView, SystemTranslationModifier
 * [POS]: UI/ 的歌词行子视图，从 LyricsView 拆分出的独立渲染组件
 */

import SwiftUI
import Translation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - LyricLineView
// ═══════════════════════════════════════════════════════════════════════════════

struct LyricLineView: View {
    let line: LyricLine
    let index: Int
    let currentIndex: Int
    let isScrolling: Bool
    var musicController: MusicController? = nil  // For word-by-word fill animation
    var onTap: (() -> Void)? = nil
    var showTranslation: Bool = false
    var isTranslating: Bool = false
    var translationFailed: Bool = false

    @State private var isHovering: Bool = false
    // 🔑 内部翻译显示状态，用于实现开启时的平滑动画
    @State private var internalShowTranslation: Bool = false

    private var distance: Int { index - currentIndex }
    private var isCurrent: Bool { distance == 0 }
    private var isPast: Bool { distance < 0 }
    private var absDistance: Int { abs(distance) }

    // 🔑 清理歌词文本 — strip timestamp tags + TTML-artifact CJK spaces
    private var cleanedText: String {
        let pattern = "\\[\\d{2}:\\d{2}[:.]*\\d{0,3}\\]"
        var text = line.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // TTML parser adds " " between each span. For CJK (avg word ≤ 2 chars),
        // these spaces are artifacts — strip them so characters pack naturally.
        if line.hasSyllableSync && !line.words.isEmpty {
            let avgLen = Double(line.words.reduce(0) { $0 + $1.word.count }) / Double(line.words.count)
            if avgLen <= 2 {
                text = line.words.map(\.word).joined()
            }
        }
        return text
    }

    // 🔑 翻译文本（如果有）
    private var translationText: String? {
        guard let translation = line.translation, !translation.isEmpty else { return nil }
        return translation
    }

    var body: some View {
        let scale: CGFloat = {
            if isScrolling { return 0.95 }
            if isCurrent { return 1.0 }
            return 0.95
        }()

        let blur: CGFloat = {
            if isScrolling { return 0 }
            if isCurrent { return 0 }
            return CGFloat(absDistance) * 1.5
        }()

        let textOpacity: CGFloat = {
            if isScrolling { return 0.6 }
            if isCurrent { return 1.0 }
            return 0.35
        }()

        // Syllable-synced lines ALWAYS use WordByWordText (same FlowLayout in all states)
        // to prevent layout jumps when transitioning between current/non-current.
        VStack(alignment: .leading, spacing: 4) {
            // Main lyrics line
            HStack(spacing: 0) {
                if line.hasSyllableSync {
                    if #available(macOS 15.0, *) {
                        if isCurrent, let mc = musicController {
                            TimelineView(.animation) { _ in
                                SyllableSyncedLine(
                                    words: line.words,
                                    currentTime: mc.wordFillTime,
                                    isAnimated: true,
                                    staticOpacity: 0
                                )
                            }
                        } else {
                            SyllableSyncedLine(
                                words: line.words,
                                currentTime: 0,
                                isAnimated: false,
                                staticOpacity: textOpacity
                            )
                        }
                    } else {
                        // macOS 14 fallback: per-word WordFillSpan
                        if isCurrent, let mc = musicController {
                            TimelineView(.animation) { _ in
                                WordByWordText(
                                    words: line.words,
                                    lineText: cleanedText,
                                    currentTime: mc.wordFillTime,
                                    staticOpacity: nil
                                )
                            }
                        } else {
                            WordByWordText(
                                words: line.words,
                                lineText: cleanedText,
                                currentTime: 0,
                                staticOpacity: textOpacity
                            )
                        }
                    }
                } else {
                    Text(cleanedText)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(textOpacity))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            // 🔑 翻译行 - 使用 internalShowTranslation 控制，实现开启时的平滑动画
            if internalShowTranslation, let translation = translationText {
                HStack(spacing: 0) {
                    Text(translation)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(textOpacity * 0.75))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(4)

                    Spacer(minLength: 0)
                }
            } else if showTranslation && isTranslating {
                // 🔑 翻译加载中动画
                HStack(spacing: 4) {
                    TranslationLoadingDotsView()
                    Spacer(minLength: 0)
                }
            } else if showTranslation && translationFailed && isCurrent {
                // 🔑 翻译失败提示（仅当前行显示）
                HStack(spacing: 4) {
                    Text("Translation unavailable")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                    Spacer(minLength: 0)
                }
            }
        }
        // 🔑 监听 showTranslation 变化，触发内部状态更新
        .onChange(of: showTranslation) { _, newValue in
            // 🔑 开启时延迟一帧，让布局系统先完成初始计算，然后动画到新高度
            if newValue {
                // 开启：延迟一帧添加翻译视图，这样 lineOffset 的变化会被动画捕获
                DispatchQueue.main.async {
                    internalShowTranslation = true
                }
            } else {
                // 关闭：立即移除
                internalShowTranslation = false
            }
        }
        .onAppear {
            // 🔑 初始化时同步状态
            internalShowTranslation = showTranslation
        }
        // 🔑 不设固定高度，让内容自然决定高度
        .padding(.vertical, 8)  // 🔑 每句歌词的内部 padding（hover 背景用）
        .padding(.horizontal, 8)
        .background(
            Group {
                if isScrolling && isHovering && line.text != "⋯" {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.08))
                }
            }
        )
        .padding(.horizontal, -8)  // 🔑 抵消内部 padding，保持文字对齐
        .blur(radius: blur)
        .scaleEffect(scale, anchor: .leading)
        .animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20), value: scale)
        .animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20), value: blur)
        .animation(.interpolatingSpring(mass: 1, stiffness: 100, damping: 20), value: textOpacity)
        // 🔑 翻译动画已移至容器级别，此处不再单独设置（性能优化）
        // 🔑 无障碍
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cleanedText + (translationText.map { "，\($0)" } ?? ""))
        .accessibilityValue(isCurrent ? "当前播放" : "")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        // 🔑 点击整个区域触发跳转
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .onHover { hovering in
            if isScrolling { isHovering = hovering }
        }
    }

}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Per-Word Fill (AMLL-style)
// ═══════════════════════════════════════════════════════════════════════════════

/// Renders each word with gradient sweep + word-level emphasis effects.
/// Used for ALL states of syllable-synced lines (current + past + future)
/// to prevent layout jumps when transitioning between states.
private struct WordByWordText: View {
    let words: [LyricWord]
    let lineText: String
    let currentTime: TimeInterval
    var staticOpacity: CGFloat? = nil

    private var needsSpaces: Bool {
        guard !words.isEmpty else { return false }
        let avgLen = Double(words.reduce(0) { $0 + $1.word.count }) / Double(words.count)
        return avgLen > 2
    }

    var body: some View {
        WordFlowLayout {
            ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                let suffix = (index < words.count - 1 && needsSpaces) ? " " : ""
                let isLast = (index == words.count - 1)
                if let opacity = staticOpacity {
                    Text(word.word + suffix)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(opacity))
                } else {
                    WordFillSpan(
                        text: word.word + suffix,
                        progress: CGFloat(word.progress(at: currentTime)),
                        wordDuration: word.endTime - word.startTime,
                        wordStartTime: word.startTime,
                        currentTime: currentTime,
                        isActive: currentTime >= word.startTime && currentTime < word.endTime,
                        hasPlayed: currentTime >= word.endTime,
                        isLastWordOfLine: isLast
                    )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Cubic Bezier Easing (AMLL-faithful)
// ═══════════════════════════════════════════════════════════════════════════════

/// Evaluates a cubic bezier curve y(t) for a given x, using Newton-Raphson.
/// Control points: (x1,y1), (x2,y2), with implicit (0,0) and (1,1).
private func cubicBezier(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, x: CGFloat) -> CGFloat {
    guard x > 0 && x < 1 else { return x <= 0 ? 0 : 1 }
    // Newton-Raphson: solve bezierX(t) = x for t, then return bezierY(t)
    var t = x  // initial guess
    for _ in 0..<8 {
        let bx = 3*(1-t)*(1-t)*t*x1 + 3*(1-t)*t*t*x2 + t*t*t - x
        let dx = 3*(1-t)*(1-t)*x1 + 6*(1-t)*t*(x2-x1) + 3*t*t*(1-x2)
        guard abs(dx) > 1e-6 else { break }
        t -= bx / dx
        t = min(1, max(0, t))
    }
    return 3*(1-t)*(1-t)*t*y1 + 3*(1-t)*t*t*y2 + t*t*t
}

// AMLL exact beziers
private let bezIn = { (x: CGFloat) in cubicBezier(x1: 0.2, y1: 0.4, x2: 0.58, y2: 1.0, x: x) }
private let bezOut = { (x: CGFloat) in cubicBezier(x1: 0.3, y1: 0.0, x2: 0.58, y2: 1.0, x: x) }

/// AMLL empEasing: rises via bezIn to mid, falls via bezOut from mid.
private func empEasing(_ x: CGFloat, mid: CGFloat = 0.5) -> CGFloat {
    guard x > 0 && x < 1 else { return 0 }
    if x < mid {
        return bezIn(min(1, max(0, x / mid)))
    } else {
        return 1 - bezOut(min(1, max(0, (x - mid) / (1 - mid))))
    }
}

/// shouldEmphasize: AMLL uses 1s threshold, but at 24pt/250px mini-player scale
/// the subtle effects become too frequent. Raised to 1.5s for CJK, 1.5s for non-CJK
/// to reserve emphasis for truly held notes.
private func shouldEmphasize(_ text: String, duration: TimeInterval) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
        return duration >= 1.5
    }
    return duration >= 1.5 && trimmed.count > 1 && trimmed.count <= 7
}

/// AMLL amount: (du/2000)^3 if <1, sqrt if >1, *0.6, clamped 1.2
private func emphasisAmount(duration: TimeInterval, isLast: Bool) -> CGFloat {
    var a = duration / 2.0
    a = a > 1 ? sqrt(a) : a * a * a
    a *= 0.6
    if isLast { a *= 1.6 }  // AMLL: last word of line boost
    return min(1.2, a)
}

/// AMLL blur: (du/3000)^3 if <1, sqrt if >1, *0.5, clamped 0.8
private func emphasisBlurLevel(duration: TimeInterval, isLast: Bool) -> CGFloat {
    var b = duration / 3.0
    b = b > 1 ? sqrt(b) : b * b * b
    b *= 0.5
    if isLast { b *= 1.5 }  // AMLL: last word of line boost
    return min(0.8, b)
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - TextRenderer Lyrics (macOS 15+ per-glyph rendering)
// ═══════════════════════════════════════════════════════════════════════════════
// Uses TextRenderer for CSS-equivalent per-glyph transforms while preserving
// kerning and text layout. This is what Apple Music likely uses natively.

@available(macOS 15.0, *)
private struct WordTimingAttribute: TextAttribute {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isEmphasis: Bool
    let amount: CGFloat
    let blurLevel: CGFloat
    let du: TimeInterval       // emphasis duration (max(1s, wordDuration) * lastBoost)
    let lineEndTime: TimeInterval  // last word's endTime — for post-line fade-out
}

@available(macOS 15.0, *)
extension Text.Layout {
    var flattenedRuns: some RandomAccessCollection<Text.Layout.Run> {
        flatMap { line in line }
    }
}

/// Builds a single concatenated Text with per-word timing attributes.
@available(macOS 15.0, *)
private struct SyllableSyncedLine: View {
    let words: [LyricWord]
    let currentTime: TimeInterval
    let isAnimated: Bool           // true for current line, false for past/future
    let staticOpacity: CGFloat     // used when !isAnimated

    private var needsSpaces: Bool {
        guard !words.isEmpty else { return false }
        let avgLen = Double(words.reduce(0) { $0 + $1.word.count }) / Double(words.count)
        return avgLen > 2
    }

    var body: some View {
        buildText()
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(.white)
            .textRenderer(LyricsTextRenderer(
                currentTime: currentTime,
                isAnimated: isAnimated,
                staticOpacity: staticOpacity
            ))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buildText() -> Text {
        let lineEnd = words.last?.endTime ?? 0
        var result = Text("")
        for (index, word) in words.enumerated() {
            let suffix = (index < words.count - 1 && needsSpaces) ? " " : ""
            let text = word.word + suffix
            let duration = word.endTime - word.startTime
            let isLast = (index == words.count - 1)
            result = result + Text(text)
                .customAttribute(WordTimingAttribute(
                    startTime: word.startTime,
                    endTime: word.endTime,
                    isEmphasis: shouldEmphasize(text, duration: duration),
                    amount: emphasisAmount(duration: duration, isLast: isLast),
                    blurLevel: emphasisBlurLevel(duration: duration, isLast: isLast),
                    du: max(1.0, duration) * (isLast ? 1.2 : 1.0),
                    lineEndTime: lineEnd
                ))
        }
        return result
    }
}

@available(macOS 15.0, *)
private struct LyricsTextRenderer: TextRenderer {
    let currentTime: TimeInterval
    let isAnimated: Bool
    let staticOpacity: CGFloat
    // AMLL values (from updateMaskAlphaTargets at scale=1.0)
    private let brightAlpha: CGFloat = 0.85
    private let dimAlpha: CGFloat = 0.25
    // AMLL fade width: word.height / 2 = 12pt for 24pt font
    private let fadeHalfPt: CGFloat = 12

    var displayPadding: EdgeInsets {
        EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // ── Static lines: single pass at staticOpacity ──
        guard isAnimated else {
            for run in layout.flattenedRuns {
                var ctx = context
                ctx.opacity = Double(staticOpacity)
                ctx.draw(run, options: .disablesSubpixelQuantization)
            }
            return
        }

        // ── Pass 1: Dim base layer (all text at dim opacity) ──
        for run in layout.flattenedRuns {
            var ctx = context
            ctx.opacity = Double(dimAlpha)
            if let attr = run[WordTimingAttribute.self] {
                ctx.translateBy(x: 0, y: baseFloat(for: attr))
            }
            ctx.draw(run, options: .disablesSubpixelQuantization)
        }

        // ── Pass 2: Bright overlay with gradient mask (sub-pixel sweep) ──
        // AMLL uses CSS mask-image: linear-gradient sliding across each word.
        // SwiftUI equivalent: drawLayer + destinationIn blend with gradient fill.
        for run in layout.flattenedRuns {
            guard let attr = run[WordTimingAttribute.self] else { continue }
            let duration = attr.endTime - attr.startTime
            let progress = wordProgress(attr, duration)
            guard progress > 0 else { continue }

            let postLineFade = postLineFadeOut(attr)
            guard postLineFade > 0 else { continue }

            let floatY = baseFloat(for: attr)

            if attr.isEmphasis {
                drawEmphasisBright(run: run, attr: attr, progress: progress,
                                   floatY: floatY, fade: postLineFade, in: context)
            } else {
                drawSweepBright(run: run, progress: progress, floatY: floatY,
                                fade: postLineFade, in: context)
            }
        }
    }

    // ── Normal words: gradient-masked bright overlay (sub-pixel smooth) ──
    private func drawSweepBright(
        run: Text.Layout.Run, progress: CGFloat, floatY: CGFloat,
        fade: CGFloat, in context: GraphicsContext
    ) {
        let runRect = run.typographicBounds.rect
        let brightBoost = brightAlpha - dimAlpha
        let sweepX = runRect.minX + runRect.width * progress

        context.drawLayer { layerCtx in
            // Draw bright text into sublayer
            var textCtx = layerCtx
            textCtx.opacity = Double(brightBoost * fade)
            textCtx.translateBy(x: 0, y: floatY)
            textCtx.draw(run, options: .disablesSubpixelQuantization)

            // Apply gradient mask via destinationIn — sub-pixel smooth sweep
            // The gradient ramps from opaque (left, already sung) to clear (right, upcoming)
            let padded = runRect.insetBy(dx: -20, dy: -20)
            let leftEdge = (sweepX - fadeHalfPt - padded.minX) / padded.width
            let rightEdge = (sweepX + fadeHalfPt - padded.minX) / padded.width

            var maskCtx = layerCtx
            maskCtx.blendMode = .destinationIn
            maskCtx.fill(
                Path(padded),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: max(0, leftEdge)),
                        .init(color: .clear, location: min(1, rightEdge)),
                        .init(color: .clear, location: 1),
                    ]),
                    startPoint: CGPoint(x: padded.minX, y: 0),
                    endPoint: CGPoint(x: padded.maxX, y: 0)
                )
            )
        }
    }

    // ── Emphasis: per-glyph bright rendering with stagger/scale/spread/glow ──
    // Emphasis words need per-glyph transforms (scale, spread, float) so we can't
    // use a single gradient mask. The emphasis effects dominate visually, so the
    // slight per-glyph step in sweep opacity is imperceptible.
    private func drawEmphasisBright(
        run: Text.Layout.Run, attr: WordTimingAttribute, progress: CGFloat,
        floatY: CGFloat, fade: CGFloat, in context: GraphicsContext
    ) {
        let glyphCount = max(1, run.count)
        let runWidth = run.typographicBounds.width
        let fadeRatio = runWidth > 0 ? fadeHalfPt / runWidth : 0.06

        var accWidth: CGFloat = 0
        for (i, glyph) in run.enumerated() {
            let glyphWidth = glyph.typographicBounds.width
            let glyphFraction = runWidth > 0 ? (accWidth + glyphWidth / 2) / runWidth : 0
            accWidth += glyphWidth

            // Soft sweep opacity (per-glyph interpolation)
            let softStep = min(1.0, max(0, (progress - glyphFraction + fadeRatio) / (fadeRatio * 2)))
            let brightBoost = (brightAlpha - dimAlpha) * fade
            guard softStep > 0 else { continue }

            var ctx = context
            ctx.opacity = Double(brightBoost * softStep)

            // Per-glyph stagger delay
            let charDelay = (attr.du / 2.5 / Double(glyphCount)) * Double(i)
            let t1 = CGFloat(min(1, max(0, (currentTime - attr.startTime - charDelay) / attr.du)))
            let charEasing = empEasing(t1)

            // Scale centered on glyph
            let scale = 1.0 + charEasing * 0.1 * attr.amount
            let gc = glyph.typographicBounds.rect
            ctx.translateBy(x: gc.midX, y: gc.midY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -gc.midX, y: -gc.midY)

            // Spread: push outward from center
            let spreadX = -charEasing * 0.03 * attr.amount * CGFloat(glyphCount / 2 - i) * 24

            // Emphasis float: staggered sin(x*PI)
            let floatDu = attr.du * 1.4
            let floatDelay = max(0, charDelay - 0.4)
            let t2 = CGFloat(min(1, max(0, (currentTime - attr.startTime - floatDelay) / floatDu)))
            let charFloat: CGFloat = (t2 > 0 && t2 < 1) ? -sin(t2 * .pi) * 1.5 : 0
            let emphLift = -charEasing * 0.6 * attr.amount

            ctx.translateBy(x: spreadX, y: floatY + charFloat + emphLift)

            // Per-glyph glow — AMLL: alpha=empEasing*blur, radius=min(0.3em, blur*0.3em)
            if charEasing > 0 && attr.blurLevel > 0 {
                let glowAlpha = Double(charEasing * attr.blurLevel)
                let glowRadius = min(0.3 * 24, attr.blurLevel * 0.3 * 24)
                ctx.addFilter(.shadow(color: .white.opacity(glowAlpha), radius: glowRadius))
            }

            ctx.draw(glyph, options: .disablesSubpixelQuantization)
        }
    }

    // ── Helpers ──

    private func postLineFadeOut(_ attr: WordTimingAttribute) -> CGFloat {
        let fadeOutDuration: TimeInterval = 1.5
        let timeSinceLineEnd = currentTime - attr.lineEndTime
        guard timeSinceLineEnd > 0 else { return 1.0 }
        if timeSinceLineEnd >= fadeOutDuration { return 0 }
        let t = timeSinceLineEnd / fadeOutDuration
        return CGFloat(1.0 - t * t)  // ease-in: slow start, fast finish
    }

    private func wordProgress(_ attr: WordTimingAttribute, _ duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return currentTime >= attr.startTime ? 1 : 0 }
        if currentTime <= attr.startTime { return 0 }
        if currentTime >= attr.endTime { return 1 }
        return CGFloat((currentTime - attr.startTime) / duration)
    }

    /// AMLL base float: duration = max(1s, wordDuration), ease-out, fill:both.
    /// The float is ALWAYS at least 1s long — short words still float slowly,
    /// creating a gentle wave-like cascade across words in the line.
    private func baseFloat(for attr: WordTimingAttribute) -> CGFloat {
        let target: CGFloat = -2.0
        guard currentTime >= attr.startTime else { return 0 }
        // Float duration: at least 1s, matching AMLL's max(1000, wordDuration)
        let wordDuration = attr.endTime - attr.startTime
        let floatDuration = max(1.0, wordDuration)
        let elapsed = currentTime - attr.startTime
        if elapsed >= floatDuration { return target }  // fill: both — stays forever
        // ease-out: fast start, slow finish (cubic ease-out)
        let t = elapsed / floatDuration
        let eased = 1.0 - pow(1.0 - t, 3)
        return target * eased
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - WordFillSpan (fallback for macOS 14)
// ═══════════════════════════════════════════════════════════════════════════════
// AMLL easing curves for timing accuracy, amplified magnitudes for 250px mini player.
// AMLL is designed for full-screen (48-72pt); our 24pt/250px viewport needs ~2x amplification.
//
// Three animation systems:
//   System 1: Base float — ALL words, ease-out, permanent
//   System 2: Sweep gradient — ALL words, LinearGradient bright→dim
//   System 3: Emphasis — scale + glow + lift + float, empEasing curve

private struct WordFillSpan: View {
    let text: String
    let progress: CGFloat
    let wordDuration: TimeInterval
    let wordStartTime: TimeInterval
    let currentTime: TimeInterval
    let isActive: Bool
    let hasPlayed: Bool
    let isLastWordOfLine: Bool

    private let font: Font = .system(size: 24, weight: .semibold)
    // AMLL active line: bright=1.0, dark=0.4 (from updateMaskAlphaTargets at scale=1.0)
    private let brightOpacity: CGFloat = 1.0
    private let dimOpacity: CGFloat = 0.4

    // ── Emphasis parameters ──
    // AMLL empEasing curve for timing, but ALL active words get a minimum scale/glow
    private var isEmphasis: Bool { shouldEmphasize(text, duration: wordDuration) }
    private var du: TimeInterval {
        var d = max(1.0, wordDuration)
        if isLastWordOfLine { d *= 1.2 }
        return d
    }
    // amount: emphasis words use AMLL formula; non-emphasis get base=0.3 for subtle life
    private var amount: CGFloat {
        if isEmphasis {
            return emphasisAmount(duration: wordDuration, isLast: isLastWordOfLine)
        }
        return 0.3  // All active words get subtle scale/glow
    }
    // blurLevel: emphasis words use AMLL formula; non-emphasis get base=0.3
    private var blurLevel: CGFloat {
        if isEmphasis {
            return emphasisBlurLevel(duration: wordDuration, isLast: isLastWordOfLine)
        }
        return 0.3
    }

    // ── System 1: Base float (ALL words) ──
    // AMLL: -0.05em, amplified to 2pt for mini-player visibility
    private var baseFloatY: CGFloat {
        let target: CGFloat = -2.0
        if hasPlayed { return target }
        if isActive {
            let eased = 1.0 - pow(1.0 - Double(progress), 3)
            return target * eased
        }
        return 0
    }

    // ── System 2: Sweep gradient (ALL words) ──
    private var sweepGradient: LinearGradient {
        let dim = Color.white.opacity(dimOpacity)
        let bright = Color.white.opacity(brightOpacity)
        guard progress > 0 && progress < 1 else {
            return LinearGradient(
                colors: [progress >= 1 ? bright : dim],
                startPoint: .leading, endPoint: .trailing
            )
        }
        let fade: CGFloat = 0.06
        return LinearGradient(
            stops: [
                .init(color: bright, location: max(0, progress - fade)),
                .init(color: dim, location: min(1, progress + fade))
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    // ── System 3: Emphasis scale/glow/lift/float ──
    // Uses empEasing curve (AMLL cubic bezier) for correct timing
    private var emphasisProgress: CGFloat {
        guard du > 0 else { return 0 }
        let t = (currentTime - wordStartTime) / du
        return CGFloat(min(1, max(0, t)))
    }
    private var easing: CGFloat {
        guard isActive || (hasPlayed && emphasisProgress < 1) else { return 0 }
        return empEasing(emphasisProgress)
    }

    // Scale: 1 + empEasing * 0.1 * amount (all active words, emphasis words scale more)
    private var totalScale: CGFloat {
        guard easing > 0 else { return 1.0 }
        return 1.0 + easing * 0.1 * amount
    }

    // Emphasis lift (Y): subtle upward shift tied to emphasis peak
    private var emphasisLiftY: CGFloat {
        guard easing > 0, isEmphasis else { return 0 }
        return -easing * 0.6 * amount  // amplified from AMLL's 0.025em
    }

    // Glow: fixed 12pt radius for visibility, AMLL empEasing for opacity timing
    private var glowOpacity: Double {
        guard easing > 0 else { return 0 }
        return Double(easing * blurLevel) * 1.5  // 1.5x boost for mini-player
    }
    private let glowRadius: CGFloat = 12  // fixed for visibility at small scale

    // Emphasis float: sin(x*PI) breathing, du*1.4 duration, starts 400ms early
    private var emphasisFloatY: CGFloat {
        guard isEmphasis else { return 0 }
        let floatDu = du * 1.4
        guard floatDu > 0 else { return 0 }
        let t = (currentTime - wordStartTime + 0.4) / floatDu
        let clamped = CGFloat(min(1, max(0, t)))
        guard clamped > 0 && clamped < 1 else { return 0 }
        return -sin(clamped * .pi) * 1.5  // amplified from AMLL's 0.05em
    }

    // ── Combined offset Y ──
    private var totalOffsetY: CGFloat {
        baseFloatY + emphasisLiftY + emphasisFloatY
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(sweepGradient)
            .scaleEffect(totalScale)
            .offset(y: totalOffsetY)
            .shadow(color: .white.opacity(glowOpacity), radius: glowRadius)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - WordFlowLayout
// ═══════════════════════════════════════════════════════════════════════════════

/// Flow layout that wraps words like natural text.
private struct WordFlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, pos) in arrange(proposal: proposal, subviews: subviews).positions.enumerated() {
            subviews[i].place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxW = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 {
                x = 0; y += rowH; rowH = 0
            }
            positions.append(CGPoint(x: x, y: y))
            x += size.width
            rowH = max(rowH, size.height)
            maxX = max(maxX, x)
        }
        return (CGSize(width: maxX, height: y + rowH), positions)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - InterludeDotsView（前奏/间奏统一动画）
// ═══════════════════════════════════════════════════════════════════════════════
/// 基于播放时间的三点动画 — 前奏（PreludeDotsView）和间奏共用

struct InterludeDotsView: View {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let currentTime: TimeInterval
    /// 是否需要时间范围检查（间奏需要，前奏始终可见）
    var gateByTimeRange: Bool = true

    private let fadeOutDuration: TimeInterval = 0.7

    private var isInRange: Bool {
        currentTime >= startTime && currentTime < endTime
    }

    var body: some View {
        let totalDuration = endTime - startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStart = startTime + segmentDuration * Double(index)
            let dotEnd = startTime + segmentDuration * Double(index + 1)
            if currentTime <= dotStart { return 0.0 }
            if currentTime >= dotEnd { return 1.0 }
            return CGFloat(sin((currentTime - dotStart) / (dotEnd - dotStart) * .pi / 2))
        }

        let fadeOutProgress: CGFloat = {
            let fadeStart = startTime + dotsActiveDuration
            if currentTime < fadeStart { return 0.0 }
            if currentTime >= endTime { return 1.0 }
            return CGFloat((currentTime - fadeStart) / fadeOutDuration)
        }()

        let visible = gateByTimeRange ? isInRange : true
        let overallOpacity = visible ? (1.0 - fadeOutProgress) : 0.0

        // 呼吸动画：x * |x| 产生平方缓动效果
        let rawPhase = sin(currentTime * .pi * 0.8)
        let breathingPhase = rawPhase * abs(rawPhase)

        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { dotIndex in
                let progress = dotProgresses[dotIndex]
                let isLightingUp = progress > 0.0 && progress < 1.0
                let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.12) : 1.0

                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(0.25 + progress * 0.75)
                    .scaleEffect((0.85 + progress * 0.15) * breathingScale)
                    .animation(.easeOut(duration: 0.3), value: progress)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .opacity(overallOpacity)
        .blur(radius: fadeOutProgress * 8)
        .animation(.easeOut(duration: 0.2), value: visible)
    }
}

/// 前奏点视图（InterludeDotsView 的便捷别名，不做时间范围门控）
struct PreludeDotsView: View {
    let startTime: TimeInterval
    let endTime: TimeInterval
    @ObservedObject var timePublisher: TimePublisher

    var body: some View {
        InterludeDotsView(
            startTime: startTime,
            endTime: endTime,
            currentTime: timePublisher.currentTime,
            gateByTimeRange: false
        )
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - TranslationLoadingDotsView
// ═══════════════════════════════════════════════════════════════════════════════

struct TranslationLoadingDotsView: View {
    @State private var animationPhase: Int = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(dotOpacity(for: index)))
                    .frame(width: 4, height: 4)
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                animationPhase = 1
            }
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        let baseOpacity = 0.3
        let highlightOpacity = 0.7
        let phase = Double(animationPhase)
        let offset = Double(index) * 0.3
        let value = sin((phase + offset) * .pi)
        return baseOpacity + (highlightOpacity - baseOpacity) * max(0, value)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - SystemTranslationModifier (macOS 15.0+)
// ═══════════════════════════════════════════════════════════════════════════════
/// 系统翻译修饰器 - 仅在 macOS 15.0+ 可用时使用

struct SystemTranslationModifier: ViewModifier {
    var translationSessionConfigAny: Any?
    let lyricsService: LyricsService
    let translationTrigger: Int

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            if let config = translationSessionConfigAny as? TranslationSession.Configuration {
                // 🔑 使用 translationTrigger 作为视图 ID
                // .translationTask 只在 config 变化时触发，但切歌时 config 可能相同（相同语言对）
                // 通过 .id() 强制重建视图，从而重新触发 .translationTask
                content
                    .translationTask(config, action: { session in
                        // 🔑 所有防重复逻辑都在 performSystemTranslation 内部处理
                        guard lyricsService.showTranslation,
                              !lyricsService.lyrics.isEmpty else { return }
                        await lyricsService.performSystemTranslation(session: session)
                    })
                    .id(translationTrigger)  // 🔑 强制在 trigger 变化时重建视图
            } else {
                content
            }
        } else {
            content
        }
    }
}
