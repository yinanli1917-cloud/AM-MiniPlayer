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
            // Main lyrics container
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
            } else if lyricsService.lyrics.isEmpty {
                emptyStateView
            } else {
                // Lyrics scroll view
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 20) {
                            // Top spacer for centering first lyrics
                            Spacer()
                                .frame(height: 160)

                            ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                                // Show loading dots as a lyric line when currentLineIndex is nil and we're before this line
                                let showLoadingDots = lyricsService.currentLineIndex == nil &&
                                   musicController.currentTime > 0 &&
                                   musicController.currentTime < line.startTime &&
                                   (index == 0 || (index > 0 && musicController.currentTime >= lyricsService.lyrics[index - 1].endTime))
                                
                                // Show loading dots as a normal lyric line (same spacing and style)
                                if showLoadingDots {
                                    LoadingDotsLyricView(
                                        currentTime: musicController.currentTime,
                                        nextLineStartTime: line.startTime,
                                        previousLineEndTime: index > 0 ? lyricsService.lyrics[index - 1].endTime : 0
                                    )
                                    .id("loading-dots-\(index)")
                                }

                                // First line should display normally, same as other future lines
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
                    }
                    .background(
                        // Use a transparent overlay to detect scroll without blocking
                        ScrollDetectorView(
                            onScrollDetected: {
                                // User is manually scrolling - update state without blocking
                                if !isManualScrolling {
                                    isManualScrolling = true
                                }
                                
                                // Hide controls immediately when scrolling
                                if showControls {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showControls = false
                                    }
                                }

                                // Cancel existing timer
                                autoScrollTimer?.invalidate()

                                // Set new timer to restore auto-scroll after 2 seconds of no scrolling
                                autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        isManualScrolling = false
                                        // Only show controls if hovering
                                        if isHovering {
                                            showControls = true
                                        }
                                    }
                                }
                            }
                        )
                        .allowsHitTesting(false) // Don't block touches
                    )
                    .onChange(of: lyricsService.currentLineIndex) { oldValue, newValue in
                        if !isManualScrolling, let currentIndex = newValue, currentIndex < lyricsService.lyrics.count {
                            withAnimation(.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.5)) {
                                proxy.scrollTo(lyricsService.lyrics[currentIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            
            // Bottom control bar
            controlBar
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.3)) {
                isHovering = hovering
                if hovering && !isManualScrolling {
                    showControls = true
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
            ZStack(alignment: .bottom) {
                // Gradient mask
                LinearGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.8)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                .allowsHitTesting(false)
                .opacity(isHovering && showControls ? 1 : 0)

                // Controls - fixed position at bottom
                if isHovering && showControls {
                    SharedBottomControls(
                        currentPage: $currentPage,
                        isHovering: $isHovering,
                        showControls: $showControls,
                        isProgressBarHovering: $isProgressBarHovering,
                        dragPosition: $dragPosition
                    )
                    .padding(.bottom, 0) // Ensure consistent bottom padding
                }
            }
        }
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
        let scale: CGFloat = {
            if isCurrent {
                // Current line: subtle scale up with smooth transition
                return 1.08
            } else if absDistance == 1 {
                // Adjacent lines: very slight scale
                return 1.02
            } else {
                return 1.0
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
        
        // Calculate progress within current line for subtle animations
        let lineProgress: Double = {
            guard isCurrent, currentTime >= line.startTime, line.endTime > line.startTime else {
                return 0
            }
            let duration = line.endTime - line.startTime
            let elapsed = currentTime - line.startTime
            return min(1.0, max(0.0, elapsed / duration))
        }()
        
        // Subtle pulse effect for current line
        let pulseScale: CGFloat = isCurrent ? (1.0 + sin(lineProgress * .pi * 2) * 0.02) : 1.0
        
        // Simple text without karaoke effect, allow multiple lines
        Text(line.text)
            .font(.system(size: 24, weight: isCurrent ? .bold : .medium, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(nil) // Allow unlimited lines for wrapping
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true) // Allow text to expand vertically
            .scaleEffect(scale * pulseScale, anchor: .leading)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(y: yOffset)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.75, blendDuration: 0.2),
                value: currentIndex
            )
            .animation(
                .easeInOut(duration: 0.3),
                value: isScrolling
            )
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

// MARK: - Loading Dots View (Legacy - no longer used)

struct LoadingDotsView: View {
    @State private var animationPhase: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .opacity(animationPhase == index ? 1.0 : 0.3)
                    .scaleEffect(animationPhase == index ? 1.2 : 1.0)
            }
        }
        .onAppear {
            // Animate dots sequentially
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    animationPhase = (animationPhase + 1) % 3
                }
            }
        }
    }
}

// MARK: - Loading Dots Lyric View (in scroll list)

struct LoadingDotsLyricView: View {
    let currentTime: TimeInterval
    let nextLineStartTime: TimeInterval
    let previousLineEndTime: TimeInterval

    var body: some View {
        // Calculate the wait duration (gap between lyrics)
        let waitDuration = nextLineStartTime - previousLineEndTime

        // Calculate time elapsed in this gap
        let elapsedTime = currentTime - previousLineEndTime

        // Divide the wait duration into 3 equal segments for the dots
        let segmentDuration = waitDuration / 3.0

        // Determine which dots should be lit (once lit, they stay lit)
        let litDots: Int = {
            if elapsedTime < segmentDuration {
                return 0
            } else if elapsedTime < segmentDuration * 2 {
                return 1
            } else if elapsedTime < segmentDuration * 3 {
                return 2
            } else {
                return 3 // All dots lit
            }
        }()
        
        // Calculate fade out progress (last 15% of wait duration for smooth transition)
        let fadeOutStart = waitDuration * 0.85
        let fadeOutProgress = max(0, min(1, (elapsedTime - fadeOutStart) / (waitDuration - fadeOutStart)))
        let dotsOpacity = 1.0 - fadeOutProgress

        // Display dots as a normal lyric line with same spacing (20) and style
        HStack(spacing: 8) {
            ForEach(0..<3) { index in
                let isLit = index < litDots
                
                // Opacity: lit dots stay bright, unlit dots are dim
                let dotOpacity: Double = {
                    if isLit {
                        return 1.0 * dotsOpacity
                    } else {
                        return 0.3 * dotsOpacity
                    }
                }()
                
                // Scale: lit dots are slightly larger
                let dotScale: CGFloat = isLit ? 1.2 : 1.0
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .opacity(dotOpacity)
                    .scaleEffect(dotScale)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: litDots)
                    .animation(.easeInOut(duration: 0.4), value: dotsOpacity)
            }
        }
        .font(.system(size: 24, weight: .medium, design: .rounded))
        .foregroundColor(.white)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Scroll Detector View (non-blocking)

struct ScrollDetectorView: NSViewRepresentable {
    let onScrollDetected: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = ScrollDetectorNSView()
        view.onScrollDetected = onScrollDetected
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let detectorView = nsView as? ScrollDetectorNSView {
            detectorView.onScrollDetected = onScrollDetected
        }
    }
}

class ScrollDetectorNSView: NSView {
    var onScrollDetected: (() -> Void)?
    private var lastScrollTime: Date = Date()
    private var scrollTimer: Timer?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Monitor scroll events via NSScrollView if available
        if let scrollView = findScrollView(in: self) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidScroll),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
    }
    
    override func scrollWheel(with event: NSEvent) {
        // Don't block - just notify and pass through immediately
        lastScrollTime = Date()
        onScrollDetected?()
        
        // Cancel and restart timer
        scrollTimer?.invalidate()
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            // If no scroll for 2 seconds, reset
            if Date().timeIntervalSince(self.lastScrollTime) > 2.0 {
                timer.invalidate()
            }
        }
        
        // Always pass event to super immediately - don't block
        super.scrollWheel(with: event)
    }
    
    @objc private func scrollViewDidScroll() {
        lastScrollTime = Date()
        onScrollDetected?()
    }
    
    private func findScrollView(in view: NSView) -> NSScrollView? {
        var current: NSView? = view.superview
        while current != nil {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            current = current?.superview
        }
        return nil
    }
    
    deinit {
        scrollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

#Preview {
    @Previewable @State var currentPage: PlayerPage = .lyrics
    LyricsView(currentPage: $currentPage)
        .environmentObject(MusicController(preview: true))
        .frame(width: 300, height: 400)
        .background(Color.black)
}
