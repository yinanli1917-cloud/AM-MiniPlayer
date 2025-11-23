import SwiftUI

// MARK: - Shared Bottom Controls
struct SharedBottomControls: View {
    @EnvironmentObject var musicController: MusicController
    @Binding var currentPage: PlayerPage
    @Binding var isHovering: Bool
    @Binding var showControls: Bool
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?

    var body: some View {
        VStack(spacing: 8) {
            // Time & Progress Bar
            VStack(spacing: 4) {
                // Time labels
                HStack {
                    Text(formatTime(musicController.currentTime))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 35, alignment: .leading)

                    Spacer()

                    // Audio quality badge
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

                // Progress Bar
                progressBar
            }

            // Playback Controls
            HStack(spacing: 0) {
                Spacer().frame(width: 12)

                // Left navigation button
                leftNavigationButton

                Spacer()

                // Previous Track
                Button(action: musicController.previousTrack) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }

                Spacer().frame(width: 10)

                // Play/Pause
                Button(action: musicController.togglePlayPause) {
                    ZStack {
                        Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer().frame(width: 10)

                // Next Track
                Button(action: musicController.nextTrack) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }

                Spacer()

                // Right navigation button
                rightNavigationButton

                Spacer().frame(width: 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .background(Color.clear.contentShape(Rectangle()))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Computed Properties

    private var leftNavigationButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                if currentPage == .album {
                    currentPage = .lyrics
                } else if currentPage == .lyrics {
                    currentPage = .album
                } else if currentPage == .playlist {
                    // From playlist, go to lyrics
                    currentPage = .lyrics
                }
            }
        }) {
            Image(systemName: currentPage == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(currentPage == .lyrics ? 1.0 : 0.7))
                .frame(width: 28, height: 28)
        }
    }

    private var rightNavigationButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                if currentPage == .album {
                    currentPage = .playlist
                } else if currentPage == .playlist {
                    currentPage = .album
                } else {
                    currentPage = .playlist
                }
            }
        }) {
            Image(systemName: currentPage == .playlist ? "music.note.list.fill" : "music.note.list")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(currentPage == .playlist ? 1.0 : 0.7))
                .frame(width: 28, height: 28)
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let currentProgress: CGFloat = {
                if musicController.duration > 0 {
                    return dragPosition ?? CGFloat(musicController.currentTime / musicController.duration)
                }
                return 0
            }()

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: isProgressBarHovering ? 8 : 6)

                // Active Progress
                Capsule()
                    .fill(Color.white)
                    .frame(
                        width: geo.size.width * currentProgress,
                        height: isProgressBarHovering ? 8 : 6
                    )
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

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}