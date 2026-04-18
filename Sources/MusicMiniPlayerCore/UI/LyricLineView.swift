/**
 * [INPUT]: LyricLine (歌词数据模型), MusicController (播放时间)
 * [OUTPUT]: LyricLineView, InterludeDotsView (+ PreludeDotsView alias), TranslationLoadingDotsView, SystemTranslationModifier
 * [POS]: UI/ 的歌词行子视图，从 LyricsView 拆分出的独立渲染组件
 */

import SwiftUI
import Translation

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - LyricMetrics — single source of truth for layout dimensions
// ═══════════════════════════════════════════════════════════════════════════════
//
// Apple Music reference (measured from iPhone screenshot, normalized to main font):
//   • Translation font ratio:        ~0.59x main
//   • Intra-pair gap (lyric→trans):  ~0.35x main  (clear breathing, still paired)
//   • Inter-pair gap (trans→next):   ~0.88x main
//   • Translation opacity (current): ~0.85 (nearly as bright as main lyric)
//
// Our deviations (deliberate, for 250pt window legibility):
//   • Translation 0.67x not 0.59x — CJK characters need more pixels at small scale.
//
// 🔑 Responsive window prep:
//   When the window becomes resizable, replace `mainFontSize` with a function
//   `mainFontSize(for: windowWidth)` and ALL derived values scale automatically.
//   Renderer-internal tuning (LyricsTextRenderer.fadeHalfPt = 12pt = font/2,
//   glowRadius = 0.3 * font, etc.) must be updated together if mainFontSize changes.
//
fileprivate enum LyricMetrics {
    /// Main lyric font size — current production value tuned for 250pt window.
    static let mainFontSize: CGFloat = 24

    /// Translation font: 0.67x main → 16pt at 24pt main.
    /// Slightly larger than Apple Music's 0.59 for CJK legibility.
    static var translationFontSize: CGFloat { mainFontSize * 0.67 }

    /// Intra-pair gap (lyric → its translation): 0.33x main → 8pt at 24pt main.
    /// Matches Apple Music's ~0.35 ratio: clear breathing room, pair stays paired.
    static var intraPairSpacing: CGFloat { mainFontSize * 0.33 }

    /// Outer vertical padding per LyricLineView — provides draw overflow for
    /// emphasis float/lift/glow. NOT the inter-pair gap (that comes from
    /// LyricsView.calculateAccumulatedHeight + line spacing 6pt).
    static var outerVerticalPadding: CGFloat { 8 }

    /// Translation line spacing within wrapped multi-line translations.
    /// Apple Music uses tight wrapping for translations — 2pt is barely visible.
    static var translationLineSpacing: CGFloat { 2 }

    /// Translation opacity multiplier on the current line (matches main brightness).
    /// Apple Music renders translation nearly as bright as the main lyric — ~0.85.
    static let currentTranslationOpacityFactor: CGFloat = 0.85

    /// "Translation unavailable" hint font.
    static var hintFontSize: CGFloat { 14 }
}

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
        VStack(alignment: .leading, spacing: LyricMetrics.intraPairSpacing) {
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
                        .font(.system(size: LyricMetrics.mainFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(textOpacity))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            // Translation line — same view identity in all states (like SyllableSyncedLine)
            // to prevent lag when switching between current/non-current.
            if internalShowTranslation, let translation = translationText {
                if line.hasSyllableSync {
                    if isCurrent, let mc = musicController {
                        TimelineView(.animation) { _ in
                            TranslationSweepText(
                                text: translation,
                                words: line.words,
                                lineStartTime: line.startTime,
                                lineEndTime: line.endTime,
                                currentTime: mc.wordFillTime,
                                staticOpacity: nil
                            )
                        }
                    } else {
                        TranslationSweepText(
                            text: translation,
                            words: line.words,
                            lineStartTime: line.startTime,
                            lineEndTime: line.endTime,
                            currentTime: 0,
                            staticOpacity: textOpacity * LyricMetrics.currentTranslationOpacityFactor
                        )
                    }
                } else {
                    HStack(spacing: 0) {
                        Text(translation)
                            .font(.system(size: LyricMetrics.translationFontSize, weight: .semibold))
                            .foregroundColor(.white.opacity(textOpacity * LyricMetrics.currentTranslationOpacityFactor))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(LyricMetrics.translationLineSpacing)

                        Spacer(minLength: 0)
                    }
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
                        .font(.system(size: LyricMetrics.hintFontSize, weight: .medium))
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
        .padding(.vertical, LyricMetrics.outerVerticalPadding)  // hover 背景 + 渲染溢出
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
        .modifier(InterludeFadeModifier(
            isCurrent: isCurrent,
            lineEndTime: line.endTime,
            musicController: musicController
        ))
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
// MARK: - Translation Sweep (per-line gradient reveal)
// ═══════════════════════════════════════════════════════════════════════════════

/// Translation sweep view — uses the same TextRenderer approach as the original lyrics.
/// The TextRenderer gets per-visual-line runs, so the gradient naturally handles wrapping.
private struct TranslationSweepText: View {
    let text: String
    let words: [LyricWord]
    let lineStartTime: TimeInterval
    let lineEndTime: TimeInterval
    let currentTime: TimeInterval
    var staticOpacity: CGFloat? = nil  // non-nil → static rendering (non-current)

    /// Progress 0→1 matching the original lyrics' visual fill.
    private var lineProgress: CGFloat {
        guard !words.isEmpty else {
            let duration = lineEndTime - lineStartTime
            guard duration > 0 else { return currentTime >= lineStartTime ? 1 : 0 }
            if currentTime <= lineStartTime { return 0 }
            if currentTime >= lineEndTime { return 1 }
            return CGFloat((currentTime - lineStartTime) / duration)
        }
        let count = CGFloat(words.count)
        for (i, word) in words.enumerated() {
            if currentTime < word.startTime { return CGFloat(i) / count }
            if currentTime < word.endTime {
                return (CGFloat(i) + CGFloat(word.progress(at: currentTime))) / count
            }
        }
        return 1.0
    }

    var body: some View {
        HStack(spacing: 0) {
            if #available(macOS 15.0, *) {
                Text(text)
                    .font(.system(size: LyricMetrics.translationFontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .textRenderer(TranslationSweepRenderer(
                        progress: staticOpacity != nil ? 1.0 : lineProgress,
                        currentTime: currentTime,
                        lineEndTime: lineEndTime,
                        staticOpacity: staticOpacity
                    ))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(LyricMetrics.translationLineSpacing)
            } else {
                Text(text)
                    .font(.system(size: LyricMetrics.translationFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(staticOpacity ?? LyricMetrics.currentTranslationOpacityFactor))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(LyricMetrics.translationLineSpacing)
            }
            Spacer(minLength: 0)
        }
    }
}

/// TextRenderer for translation — same dim-base + bright-sweep technique as LyricsTextRenderer.
/// Each visual line is a separate run, so the gradient mask is per-line (no cross-line bleeding).
/// Progress is distributed across actual rendered line widths sequentially.
@available(macOS 15.0, *)
private struct TranslationSweepRenderer: TextRenderer {
    let progress: CGFloat
    let currentTime: TimeInterval
    let lineEndTime: TimeInterval
    var staticOpacity: CGFloat? = nil  // non-nil → render at flat opacity (non-current)
    private let brightAlpha: CGFloat = 0.75
    private let dimAlpha: CGFloat = 0.20
    private let fadeHalfPt: CGFloat = 8

    var displayPadding: EdgeInsets {
        // 🔑 MUST stay zero vertical. Same reason as LyricsTextRenderer:
        // displayPadding inflates per visual line, multiplying the gap on
        // wrapped translations. Translation text has no transforms or glow,
        // so zero is also semantically correct.
        EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Static mode: flat opacity, no sweep (matching original lyrics' static path)
        if let opacity = staticOpacity {
            for run in layout.flattenedRuns {
                var ctx = context
                ctx.opacity = Double(opacity)
                ctx.draw(run, options: .disablesSubpixelQuantization)
            }
            return
        }

        let runs = Array(layout.flattenedRuns)
        let totalWidth = runs.reduce(CGFloat(0)) { $0 + $1.typographicBounds.rect.width }
        guard totalWidth > 0 else { return }
        let filledWidth = progress * totalWidth

        // Pass 1: Dim base — all text visible at dim opacity
        for run in runs {
            var ctx = context
            ctx.opacity = Double(dimAlpha)
            ctx.draw(run, options: .disablesSubpixelQuantization)
        }

        // Pass 2: Bright overlay with per-run gradient mask (same as LyricsTextRenderer)
        // Apply postLineFadeOut so translation dims in sync with original lyrics.
        // AMLL: translation_opacity = main_opacity × 0.3 — always proportional.
        let fade = postLineFadeOut()
        guard fade > 0 else { return }
        let brightBoost = (brightAlpha - dimAlpha) * fade
        var cumWidth: CGFloat = 0
        for run in runs {
            let runRect = run.typographicBounds.rect
            let localFilled = filledWidth - cumWidth

            if localFilled > 0 {
                let localProgress = min(1.0, localFilled / max(1, runRect.width))
                let sweepX = runRect.minX + runRect.width * localProgress

                context.drawLayer { layerCtx in
                    var textCtx = layerCtx
                    textCtx.opacity = Double(brightBoost)
                    textCtx.draw(run, options: .disablesSubpixelQuantization)

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

            cumWidth += runRect.width
        }
    }

    /// Fade bright overlay after line ends — syncs with LyricsTextRenderer.postLineFadeOut.
    private func postLineFadeOut() -> CGFloat {
        let fadeOutDuration: TimeInterval = 1.5
        let timeSinceLineEnd = currentTime - lineEndTime
        guard timeSinceLineEnd > 0 else { return 1.0 }
        if timeSinceLineEnd >= fadeOutDuration { return 0 }
        let t = timeSinceLineEnd / fadeOutDuration
        return CGFloat(1.0 - t * t)
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
                let cleaned = word.word.trimmingCharacters(in: .whitespaces)
                let suffix = (index < words.count - 1 && needsSpaces) ? " " : ""
                let text = cleaned + suffix
                let isLast = (index == words.count - 1)
                if let opacity = staticOpacity {
                    Text(text)
                        .font(.system(size: LyricMetrics.mainFontSize, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(opacity))
                } else {
                    WordFillSpan(
                        text: text,
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
    // ── CJK uniform-fill flag ──
    // YRC/TTML parsers emit one LyricWord per CJK character. A horizontal sweep
    // across a single glyph looks fragmented (the shine traverses ~24pt in one
    // word's duration, essentially invisible). AMLL handles this by filling the
    // entire character uniformly — alpha lerps dim→bright over the word window.
    // English words keep the sweep because letters form a meaningful horizontal run.
    let isCJK: Bool
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
            .font(.system(size: LyricMetrics.mainFontSize, weight: .semibold))
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
            // Trim any internal whitespace artifact from the word source so
            // the " " joiner is the sole source of inter-word spacing. A
            // trailing space on `word.word` would add to the suffix space
            // and widen the line vs the line-level Text(...) rendering.
            let cleaned = word.word.trimmingCharacters(in: .whitespaces)
            let suffix = (index < words.count - 1 && needsSpaces) ? " " : ""
            let text = cleaned + suffix
            let duration = word.endTime - word.startTime
            let isLast = (index == words.count - 1)
            let isCJK = LanguageUtils.containsCJK(word.word)
            // CJK: suppress per-glyph emphasis scale/lift/glow even for long-held
            // characters. A single 1.5s+ character ballooning up while its
            // neighbors stay put reads as jarring, not expressive — breaks the
            // line's visual unity. Uniform color fill alone carries the rhythm.
            let emphasize = !isCJK && shouldEmphasize(text, duration: duration)
            result = result + Text(text)
                .customAttribute(WordTimingAttribute(
                    startTime: word.startTime,
                    endTime: word.endTime,
                    isEmphasis: emphasize,
                    amount: emphasisAmount(duration: duration, isLast: isLast),
                    blurLevel: emphasisBlurLevel(duration: duration, isLast: isLast),
                    du: max(1.0, duration) * (isLast ? 1.2 : 1.0),
                    lineEndTime: lineEnd,
                    isCJK: isCJK
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
    // AMLL-exact fade band. wordFadeWidth=0.5 in base.ts → fadeWidth = 0.5 ×
    // word.height = 12pt at 24pt font. The fade tail extends exactly
    // `fadeHalfPt` past the wavefront, so this value directly controls how
    // far the mask reads as "ahead of the sung character." With the line-
    // level wavefrontX + overlapping clamp ranges (sweepStart = minX −
    // fadeHalfPt unconditionally), even a 12pt halfwidth gives cross-char
    // visibility because adjacent runs' ranges still overlap by 24pt.
    private let fadeHalfPt: CGFloat = 12

    var displayPadding: EdgeInsets {
        // 🔑 MUST stay zero. SwiftUI applies displayPadding per visual line of
        // wrapped text, not per frame. Any non-zero value inflates the measured
        // height of multi-line wrapped lyrics, creating a phantom gap between
        // the lyric text and its translation that scales with line count.
        // The emphasis float/lift/glow extend beyond text bounds visually but
        // are NOT clipped here because the parent .padding(.vertical, 8) on
        // LyricLineView provides the necessary draw overflow.
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
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

        // ── Pass 1: Dim base layer (non-emphasis words only) ──
        // Emphasis words are fully handled by drawEmphasisBright (single layer
        // with gradient mask for both bright and dim regions). Drawing them here
        // would create a ghost at the untransformed position — visible 割裂感.
        for run in layout.flattenedRuns {
            if let attr = run[WordTimingAttribute.self], attr.isEmphasis { continue }
            var ctx = context
            ctx.opacity = Double(dimAlpha)
            if let attr = run[WordTimingAttribute.self] {
                ctx.translateBy(x: 0, y: baseFloat(for: attr))
            }
            ctx.draw(run, options: .disablesSubpixelQuantization)
        }

        // Compute line bounding rect + per-visual-line wavefrontX.
        //
        // For the fade band to be visibly spanning multiple characters, all
        // runs on a visual line must sample the SAME wavefrontX, with their
        // own mask clamped to their own [sweepStart, sweepEnd]. With tight-
        // packed CJK runs, adjacent sweep ranges overlap by 2·fadeHalfPt =
        // 48pt — so when the shared wavefront is inside one word, the
        // previous word's mask ALSO draws with that same wavefront inside
        // its own clamp range, rendering the band's tail across the prior
        // glyph. Two adjacent chars simultaneously display the gradient.
        //
        // Per-word clipping + wider band (previous attempt) gave zero
        // multi-char visibility because each word's mask was confined to
        // its own run pixels via destinationIn — adjacent chars were
        // already-bright or not-yet-reached at their own sweepX. Shared
        // wavefront breaks that isolation.
        //
        // Visual-line reset (rect.minX < prevMaxX − 1) handles wrapped
        // lyric lines without backward motion.
        var lineRect = CGRect.null
        for run in layout.flattenedRuns {
            lineRect = lineRect.union(run.typographicBounds.rect)
        }

        var runMeta: [(sweepStart: CGFloat, sweepEnd: CGFloat, lineIdx: Int)] = []
        runMeta.reserveCapacity(8)
        var lineWavefronts: [CGFloat] = []
        do {
            var prevSweepEnd: CGFloat = -.infinity
            var prevMaxX: CGFloat = -.infinity
            var lineIdx = -1
            var currentLineWavefront: CGFloat = -.infinity
            for run in layout.flattenedRuns {
                guard let attr = run[WordTimingAttribute.self] else { continue }
                let rect = run.typographicBounds.rect
                let isNewVisualLine = (prevMaxX == -.infinity) || (rect.minX < prevMaxX - 1)

                // Per-run clamp range — NOT constrained to prevSweepEnd.
                // For tight CJK text, adjacent runs overlap by 2·fadeHalfPt
                // (48pt), which is how multiple chars simultaneously render
                // the fade band when the shared wavefrontX sits near their
                // boundary.
                let sweepStart = rect.minX - fadeHalfPt
                let sweepEnd = rect.maxX + fadeHalfPt

                if isNewVisualLine {
                    if lineIdx >= 0 { lineWavefronts.append(currentLineWavefront) }
                    lineIdx += 1
                    currentLineWavefront = sweepStart
                }

                // Wavefront advancement: during this run's active time the
                // shared wavefront moves from (prev run's sweepEnd) to
                // (this run's sweepEnd). That's one word-width of travel
                // per word duration for tight text — continuous across
                // word boundaries, no reset.
                let advanceFrom: CGFloat = isNewVisualLine ? sweepStart : prevSweepEnd

                if currentTime >= attr.endTime {
                    currentLineWavefront = sweepEnd
                } else if currentTime > attr.startTime {
                    let dur = attr.endTime - attr.startTime
                    let p = dur > 0 ? CGFloat((currentTime - attr.startTime) / dur) : 0
                    currentLineWavefront = advanceFrom + (sweepEnd - advanceFrom) * p
                }

                runMeta.append((sweepStart, sweepEnd, lineIdx))
                prevSweepEnd = sweepEnd
                prevMaxX = rect.maxX
            }
            if lineIdx >= 0 { lineWavefronts.append(currentLineWavefront) }
        }

        // ── Pass 2: Bright overlay with gradient mask ──
        var metaIdx = 0
        for run in layout.flattenedRuns {
            guard let attr = run[WordTimingAttribute.self] else { continue }
            defer { metaIdx += 1 }
            let meta = runMeta[metaIdx]
            let lineWave = meta.lineIdx < lineWavefronts.count
                ? lineWavefronts[meta.lineIdx]
                : meta.sweepStart

            // Skip runs the wavefront hasn't reached.
            let fullyAhead = lineWave <= meta.sweepStart
            guard !fullyAhead || attr.isEmphasis else { continue }

            let duration = attr.endTime - attr.startTime
            let progress = wordProgress(attr, duration)
            let postLineFade = postLineFadeOut(attr)
            if postLineFade <= 0 && !attr.isEmphasis { continue }

            let floatY = baseFloat(for: attr)
            let sweepX = max(meta.sweepStart, min(lineWave, meta.sweepEnd))

            if attr.isEmphasis {
                drawEmphasisBright(run: run, attr: attr, progress: progress, floatY: floatY,
                                   fade: postLineFade, lineRect: lineRect, sweepX: sweepX, in: context)
            } else {
                drawSweepBright(run: run, attr: attr, progress: progress, floatY: floatY,
                                fade: postLineFade, lineRect: lineRect, sweepX: sweepX, in: context)
            }
        }
    }

    /// AMLL base float: duration = max(1s, wordDuration), CSS ease-out, fill:both.
    /// AMLL uses the Web Animations `easing: "ease-out"` which CSS defines
    /// as cubic-bezier(0, 0, 0.58, 1). Previously we used the cubic curve
    /// `1 − (1−t)³` which rises ~8% faster at mid-window, making the float
    /// feel shorter than AMLL's despite the identical 1s duration.
    private func baseFloat(for attr: WordTimingAttribute) -> CGFloat {
        let target: CGFloat = -2.0
        guard currentTime >= attr.startTime else { return 0 }
        let wordDuration = attr.endTime - attr.startTime
        let floatDuration = max(1.0, wordDuration)
        let elapsed = currentTime - attr.startTime
        if elapsed >= floatDuration { return target }  // fill: both
        let t = CGFloat(elapsed / floatDuration)
        let eased = cubicBezier(x1: 0, y1: 0, x2: 0.58, y2: 1, x: t)
        return target * eased
    }

    // ── Gradient-masked bright overlay ──
    // sweepX is SHARED across all runs on the same visual line (computed
    // in draw as per-visual-line wavefrontX, then clamped to each run's
    // [sweepStart, sweepEnd]). With fadeHalfPt=24 the 48pt band spans two
    // CJK glyphs; when the wavefront is inside one word, the previous
    // word's mask also renders the band's tail using the same sweepX,
    // producing cross-character visible gradient.
    private func drawSweepBright(
        run: Text.Layout.Run, attr: WordTimingAttribute, progress: CGFloat, floatY: CGFloat,
        fade: CGFloat, lineRect: CGRect, sweepX: CGFloat, in context: GraphicsContext
    ) {
        let brightBoost = brightAlpha - dimAlpha

        context.drawLayer { layerCtx in
            // Draw bright text into sublayer
            var textCtx = layerCtx
            textCtx.opacity = Double(brightBoost * fade)
            textCtx.translateBy(x: 0, y: floatY)
            textCtx.draw(run, options: .disablesSubpixelQuantization)

            // Apply gradient mask via destinationIn — sub-pixel smooth sweep
            // Use line-level rect so the gradient is uniform across all words (unibody wipe)
            let padded = lineRect.insetBy(dx: -20, dy: -20)
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

    // ── Emphasis: single-layer with bright→dim gradient mask ──
    // AMLL: single element per character, CSS mask transitions bright→dim directly.
    // No separate dim base layer — eliminates ghost at untransformed position.
    // Glyphs drawn at full opacity, gradient mask controls bright/dim regions.
    private func drawEmphasisBright(
        run: Text.Layout.Run, attr: WordTimingAttribute, progress: CGFloat,
        floatY: CGFloat, fade: CGFloat, lineRect: CGRect, sweepX: CGFloat,
        in context: GraphicsContext
    ) {
        let glyphCount = max(1, run.count)
        // Bright floor = dimAlpha: when fade→0, bright converges to dim → uniform dimAlpha.
        // No Pass 1 ghost needed — single layer handles the full lifecycle.
        let effectiveBright = max(brightAlpha * fade, dimAlpha)
        let bright = Color.white.opacity(Double(effectiveBright))
        let dim = Color.white.opacity(Double(dimAlpha))

        context.drawLayer { layerCtx in
            // Draw emphasis glyphs at full opacity with per-glyph transforms
            for (i, glyph) in run.enumerated() {
                var ctx = layerCtx
                // Full white — the gradient mask below will set final alpha

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

                // Emphasis float: staggered sin(x*PI), AMLL: -0.05em, du*1.4, starts 400ms early
                let floatDu = attr.du * 1.4
                let floatDelay = max(0, charDelay - 0.4)
                let t2 = CGFloat(min(1, max(0, (currentTime - attr.startTime - floatDelay) / floatDu)))
                let charFloat: CGFloat = (t2 > 0 && t2 < 1) ? -sin(t2 * .pi) * 1.2 : 0
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

            let padded = lineRect.insetBy(dx: -40, dy: -40)

            var maskCtx = layerCtx
            maskCtx.blendMode = .destinationIn

            // Gradient mask: bright→dim continuous across all chars. Same
            // code path for CJK and non-CJK — the extended sweepX makes
            // single-char runs traverse bright→dim cleanly and the line-
            // level gradient keeps adjacent chars on a shared fade band.
            let leftEdge = (sweepX - fadeHalfPt - padded.minX) / padded.width
            let rightEdge = (sweepX + fadeHalfPt - padded.minX) / padded.width
            maskCtx.fill(
                Path(padded),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: bright, location: 0),
                        .init(color: bright, location: max(0, leftEdge)),
                        .init(color: dim, location: min(1, rightEdge)),
                        .init(color: dim, location: 1),
                    ]),
                    startPoint: CGPoint(x: padded.minX, y: 0),
                    endPoint: CGPoint(x: padded.maxX, y: 0)
                )
            )
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
    // AMLL empEasing curve for timing, but ALL active words get a minimum scale/glow.
    // CJK: suppress emphasis entirely — per-glyph scale/lift on a single character
    // while its neighbors sit still breaks line unity. Uniform color fill handles it.
    private var isEmphasis: Bool {
        !LanguageUtils.containsCJK(text) && shouldEmphasize(text, duration: wordDuration)
    }
    private var du: TimeInterval {
        var d = max(1.0, wordDuration)
        if isLastWordOfLine { d *= 1.2 }
        return d
    }
    // amount: emphasis words use AMLL formula; non-emphasis get base=0.3 for subtle life.
    // CJK: zero — any per-glyph scaling breaks the line's visual unity.
    private var amount: CGFloat {
        if LanguageUtils.containsCJK(text) { return 0 }
        if isEmphasis {
            return emphasisAmount(duration: wordDuration, isLast: isLastWordOfLine)
        }
        return 0.3  // All active words get subtle scale/glow
    }
    // blurLevel: emphasis words use AMLL formula; non-emphasis get base=0.3
    private var blurLevel: CGFloat {
        if LanguageUtils.containsCJK(text) { return 0 }
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

    // CJK characters: each LyricWord is one glyph. A horizontal sweep across a
    // single character looks fragmented (~24pt of travel in one word window).
    // Use uniform fill instead — alpha lerps dim→bright as progress advances.
    private var isCJK: Bool { LanguageUtils.containsCJK(text) }

    // ── System 2: Sweep gradient (unified) ──
    // Wider fade band (half-width 0.5 of run in normalized coords → full
    // band spans from outside the run). Matches the TextRenderer path's
    // multi-char wave approach for all scripts.
    private var sweepGradient: LinearGradient {
        let dim = Color.white.opacity(dimOpacity)
        let bright = Color.white.opacity(brightOpacity)
        let fade: CGFloat = 0.5
        let mid = -fade + progress * (1 + 2 * fade)
        return LinearGradient(
            stops: [
                .init(color: bright, location: 0),
                .init(color: bright, location: max(0, mid - fade)),
                .init(color: dim, location: min(1, mid + fade)),
                .init(color: dim, location: 1),
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
// MARK: - InterludeFadeModifier
// ═══════════════════════════════════════════════════════════════════════════════
/// Fades out the just-finished current line during an inter-line gap
/// (interlude) — opacity only, NO blur. The blur stays off because the line
/// is still `isCurrent`; past lines (`distance < 0`) pick up blur+dim as
/// usual once `currentLineIndex` advances.
///
/// Uses a periodic TimelineView (10Hz) only while active; inactive lines
/// pass the content through unchanged.
private struct InterludeFadeModifier: ViewModifier {
    let isCurrent: Bool
    let lineEndTime: TimeInterval
    let musicController: MusicController?

    // Fade params: starts at line.endTime, eases from 1.0 down to 0.3 over 2s.
    private let fadeDuration: TimeInterval = 2.0
    private let fadeFloor: Double = 0.3

    func body(content: Content) -> some View {
        if isCurrent, let mc = musicController {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                content.opacity(opacity(for: mc.wordFillTime))
            }
        } else {
            content
        }
    }

    private func opacity(for currentTime: TimeInterval) -> Double {
        let elapsed = currentTime - lineEndTime
        guard elapsed > 0 else { return 1.0 }
        if elapsed >= fadeDuration { return fadeFloor }
        let p = elapsed / fadeDuration
        let eased = 1 - pow(1 - p, 2)  // ease-out quadratic
        return 1.0 - (1.0 - fadeFloor) * eased
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
        .padding(.vertical, visible ? 8 : 0)
        .frame(height: visible ? nil : 0)
        .clipped()
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
    var gateByTimeRange: Bool = false

    var body: some View {
        InterludeDotsView(
            startTime: startTime,
            endTime: endTime,
            currentTime: timePublisher.currentTime,
            gateByTimeRange: gateByTimeRange
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
