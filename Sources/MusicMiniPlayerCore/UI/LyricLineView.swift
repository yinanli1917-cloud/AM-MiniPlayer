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

        // AMLL-style per-word gradient fill for syllable-synced, line-level sweep otherwise
        VStack(alignment: .leading, spacing: 4) {
            // Main lyrics line
            HStack(spacing: 0) {
                if line.hasSyllableSync && isCurrent, let mc = musicController {
                    // Per-word fill: each word has its own gradient sweep (60fps via TimelineView)
                    TimelineView(.animation) { _ in
                        WordByWordText(
                            words: line.words,
                            lineText: cleanedText,
                            currentTime: mc.wordFillTime
                        )
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

/// Renders each word as a separate view with its own gradient mask sweep.
/// AMLL technique: each word gets `mask-image` with `mask-position` driven by word timing.
private struct WordByWordText: View {
    let words: [LyricWord]
    let lineText: String
    let currentTime: TimeInterval

    /// Whether words need inter-word spaces.
    /// CJK TTML: each character is a word (avg ≤ 2 chars) → no spaces (font provides width).
    /// Latin TTML: words are multi-char (avg > 2) → need spaces between words.
    private var needsSpaces: Bool {
        guard !words.isEmpty else { return false }
        let avgLen = Double(words.reduce(0) { $0 + $1.word.count }) / Double(words.count)
        return avgLen > 2
    }

    var body: some View {
        WordFlowLayout {
            ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                let suffix = (index < words.count - 1 && needsSpaces) ? " " : ""
                let du = word.endTime - word.startTime
                WordFillSpan(
                    text: word.word + suffix,
                    progress: CGFloat(word.progress(at: currentTime)),
                    emphasisProgress: Self.emphasisProgress(for: word, at: currentTime),
                    wordDuration: du,
                    isActive: currentTime >= word.startTime && currentTime < word.endTime,
                    hasPlayed: currentTime >= word.endTime
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// AMLL: `animateDu = max(du * 1.2, 2000ms)`. Returns 0→1 over the extended duration.
    static func emphasisProgress(for word: LyricWord, at time: TimeInterval) -> CGFloat {
        let du = word.endTime - word.startTime
        let emphDuration = max(du * 1.2, 2.0)
        guard emphDuration > 0 else { return 0 }
        let t = (time - word.startTime) / emphDuration
        return CGFloat(min(max(t, 0), 1))
    }
}

// ── WordFillSpan ─────────────────────────────────────────────────────────────
// AMLL's three animation systems per word, translated to SwiftUI:
//
// 1. Mask sweep: gradient slides left→right based on word.progress(at:)
// 2. Float: rises -1.2pt with ease-out over max(1s, wordDuration),
//    STAYS elevated after word ends (AMLL `fill: "both"`),
//    settles back when line deactivates (view switches to plain Text)
// 3. Glow: text-shadow with AMLL's exact formula:
//    glowLevel = max(0, x < 0.4 ? y/2 : y - 0.5) * blur
//    Duration = max(wordDuration * 1.2, 2s), so glow outlasts the word

private struct WordFillSpan: View {
    let text: String
    let progress: CGFloat
    let emphasisProgress: CGFloat
    let wordDuration: TimeInterval
    let isActive: Bool    // currently being sung
    let hasPlayed: Bool   // finished singing

    private let font: Font = .system(size: 24, weight: .semibold)

    // AMLL emphasis easing: smoothstep approximation of bezIn(0→0.4) + 1-bezOut(0.4→1)
    private var empEasing: CGFloat {
        let x = emphasisProgress
        guard x > 0 && x < 1 else { return 0 }
        let mid: CGFloat = 0.4
        if x < mid {
            let t = x / mid
            return t * t * (3 - 2 * t)
        } else {
            let t = (x - mid) / (1 - mid)
            return 1 - t * t * (3 - 2 * t)
        }
    }

    // AMLL glow: max(0, x < 0.4 ? y/2 : y - 0.5) * blur
    private var glowLevel: CGFloat {
        let x = emphasisProgress, y = empEasing
        guard x > 0 && x < 1 else { return 0 }
        let blur: CGFloat = wordDuration >= 3.0 ? 0.8 : (wordDuration >= 2.0 ? 0.6 : 0.5)
        return max(0, x < 0.4 ? y / 2 : y - 0.5) * blur
    }

    /// Single Text + foregroundStyle(LinearGradient) — no overlay, no GeometryReader.
    /// Eliminates layout passes and view diffs that cause jerkiness and layout shifts.
    private var sweepGradient: LinearGradient {
        let dim = Color.white.opacity(0.4)
        guard progress > 0 && progress < 1 else {
            let c = progress >= 1 ? Color.white : dim
            return LinearGradient(colors: [c], startPoint: .leading, endPoint: .trailing)
        }
        // AMLL fade edge: ~4% of line width
        let fade: CGFloat = 0.04
        return LinearGradient(
            stops: [
                .init(color: .white, location: max(0, progress - fade)),
                .init(color: dim, location: min(1, progress + fade))
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(sweepGradient)
            // AMLL float: max(1s, wordDuration) ease-out, persists after word ends
            .offset(y: (isActive || hasPlayed) ? -1.2 : 0)
            .animation(.easeOut(duration: max(1.0, wordDuration)), value: isActive || hasPlayed)
            // AMLL glow: rgba(255,255,255,glowLevel) 0 0 10px
            .shadow(color: .white.opacity(Double(glowLevel)), radius: 10)
    }
}

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
    @ObservedObject var musicController: MusicController

    var body: some View {
        InterludeDotsView(
            startTime: startTime,
            endTime: endTime,
            currentTime: musicController.currentTime,
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
