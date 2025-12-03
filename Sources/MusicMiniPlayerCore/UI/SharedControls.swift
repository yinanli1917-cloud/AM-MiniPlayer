import SwiftUI
import AppKit

// NSView wrapper that prevents window dragging
struct NonDraggableView: NSViewRepresentable {
    func makeNSView(context: Context) -> NonDraggableNSView {
        return NonDraggableNSView()
    }

    func updateNSView(_ nsView: NonDraggableNSView, context: Context) {}
}

class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Shared Bottom Controls
struct SharedBottomControls: View {
    @EnvironmentObject var musicController: MusicController
    @Binding var currentPage: PlayerPage
    @Binding var isHovering: Bool
    @Binding var showControls: Bool
    @Binding var isProgressBarHovering: Bool
    @Binding var dragPosition: CGFloat?
    @State private var isDraggingProgressBar: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // Time & Progress Bar - wrapped to prevent window dragging
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
            .background(NonDraggableView())

            // Playback Controls
            HStack(spacing: 12) {
                // Left navigation button
                leftNavigationButton
                    .frame(width: 28, height: 28)

                Spacer()

                // Previous Track
                HoverableControlButton(iconName: "backward.fill", size: 18) {
                    musicController.previousTrack()
                }
                .frame(width: 32, height: 32)

                // Play/Pause
                HoverableControlButton(iconName: musicController.isPlaying ? "pause.fill" : "play.fill", size: 22) {
                    musicController.togglePlayPause()
                }
                .frame(width: 32, height: 32)

                // Next Track
                HoverableControlButton(iconName: "forward.fill", size: 18) {
                    musicController.nextTrack()
                }
                .frame(width: 32, height: 32)

                Spacer()

                // Right navigation button
                playlistNavigationButton
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Computed Properties

    private var leftNavigationButton: some View {
        NavigationIconButton(
            iconName: currentPage == .lyrics ? "quote.bubble.fill" : "quote.bubble",
            isActive: currentPage == .lyrics
        ) {
            print("💬 Lyrics button clicked - current page: \(currentPage)")
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                let oldPage = currentPage
                if currentPage == .album {
                    currentPage = .lyrics
                } else if currentPage == .lyrics {
                    currentPage = .album
                } else if currentPage == .playlist {
                    currentPage = .lyrics
                }
                print("💬 Page changed from \(oldPage) to \(currentPage)")
            }
        }
    }

    private var playlistNavigationButton: some View {
        NavigationIconButton(
            iconName: currentPage == .playlist ? "play.square.stack.fill" : "play.square.stack",
            isActive: currentPage == .playlist
        ) {
            print("🎵 Playlist button clicked - current page: \(currentPage)")
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                let oldPage = currentPage
                if currentPage == .album {
                    currentPage = .playlist
                } else if currentPage == .playlist {
                    currentPage = .album
                } else {
                    currentPage = .playlist
                }
                print("🎵 Page changed from \(oldPage) to \(currentPage)")
            }
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
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged({ value in
                        isDraggingProgressBar = true
                        let percentage = min(max(0, value.location.x / geo.size.width), 1)
                        dragPosition = percentage
                    })
                    .onEnded({ value in
                        let percentage = min(max(0, value.location.x / geo.size.width), 1)
                        let time = percentage * musicController.duration
                        musicController.seek(to: time)
                        dragPosition = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isDraggingProgressBar = false
                        }
                    })
            )
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

// MARK: - Hoverable Button Components

struct HoverableControlButton: View {
    let iconName: String
    let size: CGFloat
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: size))
                .foregroundColor(isHovering ? .white : .white.opacity(0.8))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.15 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

struct NavigationIconButton: View {
    let iconName: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundColor(isActive ? .white : (isHovering ? .white.opacity(0.9) : .white.opacity(0.7)))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.white.opacity((isActive || isHovering) ? 0.15 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}