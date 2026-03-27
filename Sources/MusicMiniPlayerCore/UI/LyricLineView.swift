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

    // 🔑 清理歌词文本
    private var cleanedText: String {
        let pattern = "\\[\\d{2}:\\d{2}[:.]*\\d{0,3}\\]"
        return line.text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
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
                    // Per-word fill: each word has its own gradient mask (60fps via TimelineView)
                    TimelineView(.animation) { _ in
                        WordByWordText(
                            words: line.words,
                            lineText: cleanedText,
                            currentTime: mc.wordFillTime
                        )
                    }
                } else if isCurrent, let mc = musicController {
                    // Line-level sweep for lines without word timestamps
                    TimelineView(.animation) { _ in
                        Text(cleanedText)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(lineSweepGradient(at: mc.wordFillTime))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
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

    // ── Line-Level Sweep (fallback for non-syllable-synced lines) ───────────

    /// Line-level gradient sweep from startTime to endTime.
    private func lineSweepGradient(at time: TimeInterval) -> LinearGradient {
        let start = line.startTime, end = line.endTime
        let progress: CGFloat = {
            guard end > start else { return time >= start ? 1 : 0 }
            if time <= start { return 0 }
            if time >= end { return 1 }
            return CGFloat((time - start) / (end - start))
        }()
        let dim = Color.white.opacity(0.4)
        if progress <= 0 { return LinearGradient(colors: [dim], startPoint: .leading, endPoint: .trailing) }
        if progress >= 1 { return LinearGradient(colors: [.white], startPoint: .leading, endPoint: .trailing) }
        let fade: CGFloat = 0.04
        return LinearGradient(
            stops: [
                .init(color: .white, location: max(0, progress - fade)),
                .init(color: dim, location: min(1, progress + fade))
            ],
            startPoint: .leading, endPoint: .trailing
        )
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

    /// Whether words need inter-word spaces (TTML=yes, YRC/CJK=no).
    /// Compare concatenated words against original line text to detect spacing.
    private var needsSpaces: Bool {
        guard lineText.contains(" ") else { return false }
        let joined = words.map(\.word).joined()
        let stripped = lineText.replacingOccurrences(of: " ", with: "")
        // If joining without spaces matches the stripped text, original had spaces
        return joined == stripped
    }

    var body: some View {
        WordFlowLayout {
            ForEach(Array(words.enumerated()), id: \.element.id) { index, word in
                let suffix = (index < words.count - 1 && needsSpaces) ? " " : ""
                WordFillSpan(
                    text: word.word + suffix,
                    progress: CGFloat(word.progress(at: currentTime))
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Single word with AMLL-style gradient mask fill.
/// Two layers: dimmed base + bright overlay masked by a sweeping gradient.
/// Fade width = height/2 (matches AMLL's `word.height / 2`).
private struct WordFillSpan: View {
    let text: String
    let progress: CGFloat

    private let font: Font = .system(size: 24, weight: .semibold)
    private let dimOpacity: CGFloat = 0.4    // AMLL: rgba(0,0,0,0.25) → 25% visibility
    private let brightOpacity: CGFloat = 1.0 // AMLL: rgba(0,0,0,0.85) → 85% visibility

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(Color.white.opacity(dimOpacity))
            .overlay {
                Text(text)
                    .font(font)
                    .foregroundStyle(Color.white.opacity(brightOpacity))
                    .mask { sweepMask }
            }
            // AMLL float: word lifts 0.05em (~1.2pt at 24pt) during play
            .offset(y: progress > 0 && progress < 1 ? -1.2 : 0)
            .animation(.easeOut(duration: 0.3), value: progress > 0 && progress < 1)
    }

    @ViewBuilder
    private var sweepMask: some View {
        if progress <= 0 {
            Color.clear
        } else if progress >= 1 {
            Color.white
        } else {
            GeometryReader { geo in
                // AMLL: fade width = word height / 2
                let fadeW = geo.size.height * 0.5
                let w = geo.size.width
                let frontX = w * progress
                // Gradient: bright from left → fades to clear at the sweep front
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: max(0, (frontX - fadeW) / w)),
                        .init(color: .clear, location: min(1, frontX / w))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
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
