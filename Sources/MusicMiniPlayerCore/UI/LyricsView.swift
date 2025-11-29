import SwiftUI
import AppKit

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    @State private var isHovering: Bool = false
    @State private var isProgressBarHovering: Bool = false
    @State private var dragPosition: CGFloat? = nil
    @State private var isManualScrolling: Bool = false
    @State private var autoScrollTimer: Timer? = nil
    @State private var showControls: Bool = true
    @State private var lastDragLocation: CGFloat = 0
    @State private var dragVelocity: CGFloat = 0
    @State private var showLoadingDots: Bool = false
    @Binding var currentPage: PlayerPage
    var openWindow: OpenWindowAction?

    public init(currentPage: Binding<PlayerPage>, openWindow: OpenWindowAction? = nil) {
        self._currentPage = currentPage
        self.openWindow = openWindow
    }

    public var body: some View {
        ZStack {
            // Background (Liquid Glass) - same as MiniPlayerView
            LiquidBackgroundView(artwork: musicController.currentArtwork)
            .ignoresSafeArea()

            // Main lyrics container
            VStack(spacing: 0) {
                if lyricsService.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundColor(.white)
                } else if let error = lyricsService.error {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundColor(.white.opacity(0.3))
                        Text(error)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))

                        // Retry button
                        Button(action: {
                            lyricsService.fetchLyrics(
                                for: musicController.currentTrackTitle,
                                artist: musicController.currentArtist,
                                duration: musicController.duration,
                                forceRefresh: true
                            )
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Retry")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.2))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .overlay(
                        Group {
                            if showControls {
                                controlBar
                            }
                        }
                    )
                } else if lyricsService.lyrics.isEmpty {
                    emptyStateView
                        .overlay(
                            Group {
                                if showControls {
                                    controlBar
                                }
                            }
                        )
                } else {
                    // Lyrics scroll view - controls must be OUTSIDE as overlay
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 20) {
                                // Top spacer for centering first lyrics
                                Spacer()
                                    .frame(height: 160)

                                ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                                    LyricLineView(
                                        line: line,
                                        index: index,
                                        currentIndex: lyricsService.currentLineIndex ?? 0,
                                        currentTime: musicController.currentTime,
                                        isScrolling: isManualScrolling
                                    )
                                    .id(line.id)
                                    .onTapGesture {
                                        musicController.seek(to: line.startTime)
                                    }
                                }

                                // Bottom spacer for centering last lyrics
                                Spacer()
                                    .frame(height: 80)  // 减小覆盖面积，只覆盖实际需要的控件空间
                            }
                            .drawingGroup()  // Performance optimization for smooth 60fps animations
                        }
                        .onChange(of: lyricsService.currentLineIndex) { oldValue, newValue in
                            if !isManualScrolling, let currentIndex = newValue, currentIndex < lyricsService.lyrics.count {
                                // 检查是否是第一句歌词（从nil或0切换到0）
                                let isFirstLine = (oldValue == nil || oldValue == 0) && newValue == 0

                                if isFirstLine {
                                    // 第一句使用更平滑的spring动画
                                    withAnimation(.spring(response: 0.8, dampingFraction: 0.75, blendDuration: 0.3)) {
                                        proxy.scrollTo(lyricsService.lyrics[currentIndex].id, anchor: .center)
                                    }
                                } else {
                                    // 其他行使用标准的缓动曲线
                                    withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.5)) {
                                        proxy.scrollTo(lyricsService.lyrics[currentIndex].id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                    .overlay(
                        // 🔑 关键：控件必须在ScrollView的overlay之上，而不是在同一个ZStack内
                        Group {
                            if showControls {
                                controlBar
                            }
                        }
                    )
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // Music按钮 - overlay不接收hover事件，不改变布局
            if showControls {
                MusicButtonView()
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Hide按钮 - overlay不接收hover事件，不改变布局
            if showControls {
                HideButtonView()
                    .padding(12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.3)) {
                isHovering = hovering
                if hovering && !isManualScrolling {
                    showControls = true
                } else if !hovering && !isManualScrolling {
                    showControls = false
                }
            }
        }
          .onAppear {
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
        }
          .onChange(of: musicController.currentTrackTitle) {
            lyricsService.fetchLyrics(for: musicController.currentTrackTitle,
                                      artist: musicController.currentArtist,
                                      duration: musicController.duration)
        }
        .onChange(of: musicController.currentTime) {
            lyricsService.updateCurrentTime(musicController.currentTime)
        }
    }
    
    // MARK: - Subviews
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))
            Text("No lyrics available")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    private var controlBar: some View {
        VStack {
            Spacer()

            // 渐变遮罩 + 控件区域（整体拦截点击，防止穿透）
            ZStack(alignment: .bottom) {
                // Gradient mask
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.5)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 80)

                SharedBottomControls(
                    currentPage: $currentPage,
                    isHovering: $isHovering,
                    showControls: $showControls,
                    isProgressBarHovering: $isProgressBarHovering,
                    dragPosition: $dragPosition
                )
                .padding(.bottom, 0)
            }
            .contentShape(Rectangle())  // 🔑 确保整个区域可点击
            .allowsHitTesting(true)     // 🔑 拦截所有点击，防止穿透到下层歌词
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    
    private var timeAndProgressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Text(formatTime(musicController.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 35, alignment: .leading)

                Spacer()

                if let quality = musicController.audioQuality {
                    qualityBadge(quality)
                }

                Spacer()

                Text("-" + formatTime(musicController.duration - musicController.currentTime))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 35, alignment: .trailing)
            }
            .padding(.horizontal, 28)

            progressBar
        }
    }
    
    private func qualityBadge(_ quality: String) -> some View {
        HStack(spacing: 2) {
            if quality == "Hi-Res Lossless" {
                Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 8))
            } else if quality == "Dolby Atmos" {
                Image(systemName: "spatial.audio.badge.checkmark").font(.system(size: 8))
            } else {
                Image(systemName: "waveform").font(.system(size: 8))
            }
            Text(quality).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.ultraThinMaterial)
        .cornerRadius(4)
        .foregroundColor(.white.opacity(0.9))
    }
    
    private var progressBar: some View {
        GeometryReader { geo in
            let currentProgress: CGFloat = musicController.duration > 0 ? (dragPosition ?? CGFloat(musicController.currentTime / musicController.duration)) : 0

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2)).frame(height: isProgressBarHovering ? 8 : 6)
                Capsule().fill(Color.white).frame(width: geo.size.width * currentProgress, height: isProgressBarHovering ? 8 : 6)
            }
            .scaleEffect(isProgressBarHovering ? 1.05 : 1.0)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isProgressBarHovering = hovering
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged({ value in
                        let percentage = min(max(0, value.location.x / geo.size.width), 1)
                        dragPosition = percentage
                    })
                    .onEnded({ value in
                        let percentage = min(max(0, value.location.x / geo.size.width), 1)
                        let time = percentage * musicController.duration
                        musicController.seek(to: time)
                        dragPosition = nil
                    })
            )
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 20)
        .padding(.horizontal, 20)
    }
    
    private var playbackControls: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 12)
            Button(action: { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { currentPage = .album } }) {
                Image(systemName: "quote.bubble.fill").font(.system(size: 16)).foregroundColor(.white).frame(width: 28, height: 28)
            }
            Spacer()
            Button(action: musicController.previousTrack) {
                Image(systemName: "backward.fill").font(.system(size: 20)).foregroundColor(.white).frame(width: 32, height: 32)
            }
            Spacer().frame(width: 10)
            Button(action: musicController.togglePlayPause) {
                ZStack {
                    Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 24)).foregroundColor(.white)
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer().frame(width: 10)
            Button(action: musicController.nextTrack) {
                Image(systemName: "forward.fill").font(.system(size: 20)).foregroundColor(.white).frame(width: 32, height: 32)
            }
            Spacer()
            Button(action: { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { currentPage = .playlist } }) {
                Image(systemName: "music.note.list").font(.system(size: 16)).foregroundColor(.white.opacity(0.7)).frame(width: 28, height: 28)
            }
            Spacer().frame(width: 12)
        }
        .buttonStyle(.plain)
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Lyric Line View

struct LyricLineView: View {
    let line: LyricLine
    let index: Int
    let currentIndex: Int
    let currentTime: TimeInterval
    let isScrolling: Bool // Add parameter to know if user is scrolling

    var body: some View {
        let distance = index - currentIndex
        let isCurrent = distance == 0
        let isPast = distance < 0
        let absDistance = abs(distance)

        // Enhanced Visual State Calculations with smoother transitions
        // 使用scaleEffect而不是动态字体，保持文本排版一致性
        let scale: CGFloat = {
            if isCurrent {
                return 1.08
            } else if absDistance == 1 {
                return 0.96
            } else {
                return 0.92
            }
        }()

        let blur: CGFloat = {
            // No blur when scrolling to show all lyrics clearly
            if isScrolling { return 0 }

            // Progressive blur based on distance when not scrolling
            if isCurrent { return 0 }

            if isPast {
                // Past lines: gentle blur that increases with distance
                let blurAmount = min(CGFloat(absDistance) * 0.4, 2.5)
                return blurAmount
            } else {
                // Future lines: stronger blur for depth effect
                let blurAmount = min(CGFloat(absDistance) * 0.7, 5.0)
                return blurAmount
            }
        }()
        
        let opacity: CGFloat = {
            if isCurrent {
                return 1.0
            }

            if isPast {
                // Past lines: fade gracefully but remain readable
                let fadeAmount = max(0.4, 1.0 - Double(absDistance) * 0.15)
                return fadeAmount
            } else {
                // Future lines: progressive fade with smoother curve
                let fadeAmount = max(0.25, 0.95 - Double(absDistance) * 0.10)
                return fadeAmount
            }
        }()
        
        // Enhanced yOffset with smoother transitions
        let yOffset: CGFloat = {
            if isCurrent {
                return -3 // Slightly more lift for emphasis
            } else if absDistance == 1 {
                return -1 // Subtle lift for adjacent lines
            } else {
                return 0
            }
        }()
        
        // 🔑 关键修复：所有歌词使用完全一致的字体（24pt + semibold）
        // 字体大小、粗细、行间距完全相同，确保所有歌词的文本排版100%一致
        // 只通过scaleEffect改变视觉大小，不触发任何布局重新计算
        Group {
            if line.text == "⋯" {
                // 特殊处理：加载占位符显示基于时间的三等分点亮动画
                TimeBasedLoadingDotsView(
                    currentTime: currentTime,
                    endTime: line.endTime
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(line.text)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .blur(radius: blur)
        .opacity(opacity)
        .offset(y: yOffset)
        .animation(
            .timingCurve(0.2, 0.0, 0.0, 1.0, duration: 1.2),
            value: currentIndex
        )
        .animation(
            .easeInOut(duration: 0.3),
            value: isScrolling
        )
        .padding(.horizontal, 32)  // 左右各32px padding，保证居中
        .contentShape(Rectangle())
    }
}

// MARK: - Time-Based Loading Dots View (三等分前奏时间点亮动画)

struct TimeBasedLoadingDotsView: View {
    let currentTime: TimeInterval
    let endTime: TimeInterval

    var body: some View {
        let duration = endTime // 前奏总时长
        let segmentDuration = duration / 3.0 // 每个点占1/3时间

        // 计算每个点的进度（0.0-1.0）
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = segmentDuration * Double(index)
            let dotEndTime = segmentDuration * Double(index + 1)

            if currentTime <= dotStartTime {
                return 0.0
            } else if currentTime >= dotEndTime {
                return 1.0
            } else {
                // 平滑渐变函数
                let progress = (currentTime - dotStartTime) / (dotEndTime - dotStartTime)
                return CGFloat(progress * progress * (3.0 - 2.0 * progress)) // Smoothstep
            }
        }

        // 🔑 计算整体淡出透明度：与第一句歌词滚动同步（3.5s tolerance）
        let overallOpacity: CGFloat = {
            let fadeOutDuration: TimeInterval = 3.5 // 与LyricsService的tolerance同步

            if currentTime >= endTime {
                // 已经超过结束时间，完全透明
                return 0.0
            } else if currentTime >= endTime - fadeOutDuration {
                // 进入淡出阶段，与第一句歌词滚动进入同步
                let fadeProgress = (endTime - currentTime) / fadeOutDuration
                return CGFloat(fadeProgress) // 从1.0淡到0.0
            } else {
                // 正常显示
                return 1.0
            }
        }()

        HStack(spacing: 10) {
            ForEach(0..<3) { index in
                let progress = dotProgresses[index]
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .opacity(0.35 + progress * 0.65) // 从0.35渐变到1.0
                    .scaleEffect(1.0 + progress * 0.3) // 从1.0渐变到1.3
            }
        }
        .scaleEffect(0.8) // 整体缩小到0.8x
        .frame(height: 24) // Match lyric text height
        .opacity(overallOpacity) // 🔑 应用整体淡出效果
    }
}

// MARK: - Loading Dots Lyric View (in scroll list)

struct LoadingDotsLyricView: View {
    let currentTime: TimeInterval
    let nextLineStartTime: TimeInterval
    let previousLineEndTime: TimeInterval

    var body: some View {
        // Calculate the gap duration (time between lyrics)
        let gapDuration = nextLineStartTime - previousLineEndTime

        // Only show dots if there's a meaningful gap
        guard gapDuration > 0.3 else {
            return AnyView(EmptyView())
        }

        // Calculate elapsed time in this gap
        let elapsedTime = max(0, currentTime - previousLineEndTime)

        // Only show dots if we're still in the gap (before the next line starts exactly)
        // This prevents overlap with the first lyric line
        guard elapsedTime < gapDuration else {
            return AnyView(EmptyView())
        }

        // Use 3 equal segments for the dots animation - true thirds
        let segmentDuration = gapDuration / 3.0

        // Calculate smooth progress for each dot
        let dotProgresses: [CGFloat] = (0..<3).map { index in
            let dotStartTime = segmentDuration * CGFloat(index)
            let dotEndTime = segmentDuration * CGFloat(index + 1)

            if elapsedTime <= dotStartTime {
                return 0.0
            } else if elapsedTime >= dotEndTime {
                return 1.0
            } else {
                // Smooth easing function for natural animation
                let progress = (elapsedTime - dotStartTime) / (dotEndTime - dotStartTime)
                return progress * progress * (3.0 - 2.0 * progress) // Smooth step function
            }
        }

        // Display dots as proper lyric line with Apple Music style - much larger
        return AnyView(
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    let progress = dotProgresses[index]

                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10) // Much larger dots
                        .scaleEffect(0.7 + progress * 0.3) // Scale from 0.7 to 1.0
                        .opacity(0.4 + progress * 0.6) // Fade from 0.4 to 1.0
                        .animation(.timingCurve(0.2, 0.0, 0.0, 1.0, duration: 0.4), value: progress)
                        // Add breathing effect for completed dots
                        .overlay(
                            Circle()
                                .fill(Color.white)
                                .scaleEffect(progress > 0.5 ? 1.2 + sin(Date().timeIntervalSince1970 * 3) * 0.1 : 1.0)
                                .opacity(progress > 0.5 ? 0.3 : 0.0)
                                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: progress > 0.5)
                        )
                }
            }
            .font(.system(size: 23, weight: .medium, design: .rounded)) // Same size as lyric lines
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(0.7) // Slightly transparent like upcoming lyrics
        )
    }
}



#Preview {
    @Previewable @State var currentPage: PlayerPage = .lyrics
    LyricsView(currentPage: $currentPage)
        .environmentObject(MusicController(preview: true))
        .frame(width: 300, height: 400)
        .background(Color.black)
}
