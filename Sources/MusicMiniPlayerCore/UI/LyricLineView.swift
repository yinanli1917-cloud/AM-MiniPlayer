/**
 * [INPUT]: LyricLine (歌词数据模型), MusicController (播放时间)
 * [OUTPUT]: LyricLineView, InterludeDotsView, PreludeDotsView, TranslationLoadingDotsView, SystemTranslationModifier
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
    var currentTime: TimeInterval = 0  // 保留用于将来逐字高亮
    var onTap: (() -> Void)? = nil  // 🔑 点击回调
    var showTranslation: Bool = false  // 🔑 是否显示翻译
    var isTranslating: Bool = false  // 🔑 是否正在翻译中

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

        // 🔑 行级高亮：当前行全白，其他行半透明（用 foregroundColor 控制，不用外层 opacity）
        let textOpacity: CGFloat = {
            if isScrolling { return 0.6 }  // 滚动时所有行统一透明度
            if isCurrent { return 1.0 }    // 当前行全白
            return 0.35                     // 其他行固定 35% 透明度
        }()

        // 🔑 稳定版本：简单的行级高亮（等待正确的逐字高亮实现）
        // 参考 AMLL/LyricFever 样式：翻译显示在原文下方
        VStack(alignment: .leading, spacing: 4) {
            // 🔑 主歌词行
            HStack(spacing: 0) {
                Text(cleanedText)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(textOpacity))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            // 🔑 翻译行 - 使用 internalShowTranslation 控制，实现开启时的平滑动画
            if internalShowTranslation, let translation = translationText {
                HStack(spacing: 0) {
                    Text(translation)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(textOpacity * 0.6))
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
// MARK: - InterludeDotsView
// ═══════════════════════════════════════════════════════════════════════════════
/// 间奏加载点视图 - 基于播放时间精确控制动画

struct InterludeDotsView: View {
    let startTime: TimeInterval  // 间奏开始时间（前一句歌词结束时间）
    let endTime: TimeInterval    // 间奏结束时间（下一句歌词开始时间）
    let currentTime: TimeInterval  // 🔑 改为直接接收 currentTime

    // 🔑 淡出动画时长（算入总时长）
    private let fadeOutDuration: TimeInterval = 0.7

    // 🔑 是否在间奏时间范围内
    private var isInInterlude: Bool {
        currentTime >= startTime && currentTime < endTime
    }

    var body: some View {
        // 🔑 总时长，三个点只占用 (总时长 - 淡出时长)
        let totalDuration = endTime - startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        // 计算每个点的精细进度
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = startTime + segmentDuration * Double(index)
            let dotEndTime = startTime + segmentDuration * Double(index + 1)

            if currentTime <= dotStartTime {
                return 0.0
            } else if currentTime >= dotEndTime {
                return 1.0
            } else {
                let progress = (currentTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(sin(progress * .pi / 2))
            }
        }

        // 🔑 计算整体淡出透明度和模糊
        let fadeOutProgress: CGFloat = {
            let fadeStartTime = startTime + dotsActiveDuration
            if currentTime < fadeStartTime {
                return 0.0
            } else if currentTime >= endTime {
                return 1.0
            } else {
                let progress = (currentTime - fadeStartTime) / fadeOutDuration
                return CGFloat(progress)
            }
        }()

        let overallOpacity = isInInterlude ? (1.0 - fadeOutProgress) : 0.0
        let overallBlur = fadeOutProgress * 8

        // 🔑 呼吸动画：使用缓动函数让脉搏更柔和丝滑
        let rawPhase = sin(currentTime * .pi * 0.8)
        // 使用 ease-in-out 曲线：让加速和减速都更柔和
        let breathingPhase = rawPhase * abs(rawPhase)  // x * |x| 产生平方缓动效果

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
            Spacer(minLength: 0)  // 🔑 左对齐
        }
        .padding(.vertical, 8)
        .opacity(overallOpacity)
        .blur(radius: overallBlur)
        .animation(.easeOut(duration: 0.2), value: isInInterlude)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - TranslationLoadingDotsView
// ═══════════════════════════════════════════════════════════════════════════════
/// 翻译加载动画 - 三个渐变闪烁的点

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
        // 创建波浪式闪烁效果
        let baseOpacity = 0.3
        let highlightOpacity = 0.7
        let phase = Double(animationPhase)

        // 每个点有不同的相位偏移
        let offset = Double(index) * 0.3
        let value = sin((phase + offset) * .pi)

        return baseOpacity + (highlightOpacity - baseOpacity) * max(0, value)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - PreludeDotsView
// ═══════════════════════════════════════════════════════════════════════════════
/// 前奏加载点视图 - 替换 "..." 省略号歌词

struct PreludeDotsView: View {
    let startTime: TimeInterval  // 前奏/间奏开始时间
    let endTime: TimeInterval    // 前奏/间奏结束时间（下一句歌词开始时间）
    @ObservedObject var musicController: MusicController

    // 🔑 淡出动画时长（算入总时长）
    private let fadeOutDuration: TimeInterval = 0.7

    private var currentTime: TimeInterval {
        musicController.currentTime
    }

    var body: some View {
        // 🔑 总时长 = 原时长，但三个点只占用 (总时长 - 淡出时长)
        let totalDuration = endTime - startTime
        let dotsActiveDuration = max(0.1, totalDuration - fadeOutDuration)
        let segmentDuration = dotsActiveDuration / 3.0

        // 计算每个点的精细进度
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = startTime + segmentDuration * Double(index)
            let dotEndTime = startTime + segmentDuration * Double(index + 1)

            if currentTime <= dotStartTime {
                return 0.0
            } else if currentTime >= dotEndTime {
                return 1.0
            } else {
                let progress = (currentTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(sin(progress * .pi / 2))
            }
        }

        // 🔑 计算整体淡出透明度和模糊
        let fadeOutProgress: CGFloat = {
            let fadeStartTime = startTime + dotsActiveDuration
            if currentTime < fadeStartTime {
                return 0.0
            } else if currentTime >= endTime {
                return 1.0
            } else {
                let progress = (currentTime - fadeStartTime) / fadeOutDuration
                return CGFloat(progress)
            }
        }()

        let overallOpacity = 1.0 - fadeOutProgress
        let overallBlur = fadeOutProgress * 8

        // 🔑 呼吸动画：使用缓动函数让脉搏更柔和丝滑
        let rawPhase = sin(currentTime * .pi * 0.8)
        // 使用 ease-in-out 曲线：让加速和减速都更柔和
        let breathingPhase = rawPhase * abs(rawPhase)  // x * |x| 产生平方缓动效果

        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = dotProgresses[index]
                    // 🔑 只有正在点亮过程中的点（0 < progress < 1）才有呼吸动画
                    let isLightingUp = progress > 0.0 && progress < 1.0
                    let breathingScale: CGFloat = isLightingUp ? (1.0 + CGFloat(breathingPhase) * 0.12) : 1.0

                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .opacity(0.25 + progress * 0.75)
                        .scaleEffect((0.85 + progress * 0.15) * breathingScale)
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
            }
            Spacer(minLength: 0)
        }
        // 🔑 移除 padding，因为外层 VStack 已经有 padding 了
        .padding(.vertical, 8)
        .opacity(overallOpacity)
        .blur(radius: overallBlur)
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
