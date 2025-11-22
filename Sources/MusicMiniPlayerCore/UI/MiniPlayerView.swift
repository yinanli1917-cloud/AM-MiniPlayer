import SwiftUI

public struct MiniPlayerView: View {
    @EnvironmentObject var musicController: MusicController
    @State private var isFlipped: Bool = false
    
    public init() {}
    
    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background (Liquid Glass)
                LiquidBackgroundView(artwork: musicController.currentArtwork)
                
                // Content
                VStack(spacing: 0) {
                    if !isFlipped {
                        Spacer() // Equal spacing top

                        // Album Art with Progressive Blur and Text
                        if let artwork = musicController.currentArtwork {
                            let artSize = geometry.size.width * 0.60 // Reduced to 60% for better padding balance
                            
                            ZStack(alignment: .bottom) {
                                // 1. Original Artwork
                                Image(nsImage: artwork)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: artSize, height: artSize)
                                    .clipped()
                                
                                // 2. Progressive Blur Overlay
                                Image(nsImage: artwork)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: artSize, height: artSize)
                                    .blur(radius: 50)
                                    .mask(
                                        LinearGradient(
                                            gradient: Gradient(stops: [
                                                .init(color: .clear, location: 0.0),
                                                .init(color: .black, location: 0.3),
                                                .init(color: .black, location: 1.0)
                                            ]),
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .clipped()
                                
                                // 3. Dark Gradient for Text Readability
                                LinearGradient(
                                    gradient: Gradient(colors: [.clear, .black.opacity(0.6)]),
                                    startPoint: .center,
                                    endPoint: .bottom
                                )
                                .frame(width: artSize, height: artSize)
                                .allowsHitTesting(false)
                                
                                // 4. Text Info
                                VStack(spacing: 4) {
                                    Text(musicController.currentTrackTitle)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                        .shadow(radius: 2)
                                    
                                    Text(musicController.currentArtist)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                        .lineLimit(1)
                                        .shadow(radius: 2)
                                }
                                .padding(.bottom, 16)
                                .padding(.horizontal, 12)
                                .frame(width: artSize)
                            }
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.5), radius: 25, x: 0, y: 12)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                    isFlipped.toggle()
                                }
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: geometry.size.width * 0.60, height: geometry.size.width * 0.60)
                                .overlay(Text("No Art").foregroundColor(.white))
                        }

                        Spacer() // Equal spacing bottom

                        // Bottom Controls Container
                        VStack(spacing: 12) {

                            // 1. Time - Lossless Badge - Duration
                            HStack {
                                Text("0:07")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(width: 30, alignment: .leading)

                                Spacer()

                                // Lossless Badge
                                HStack(spacing: 2) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 8))
                                    Text("Lossless")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial)
                                .cornerRadius(4)
                                .foregroundColor(.white.opacity(0.9))

                                Spacer()

                                Text("-4:11")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(width: 30, alignment: .trailing)
                            }
                            .padding(.horizontal, 8)

                            // 2. Progress Bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(height: 4)

                                    Capsule()
                                        .fill(Color.white)
                                        .frame(width: geo.size.width * 0.3, height: 4)
                                }
                            }
                            .frame(height: 4)

                            // 3. Main Controls Row (Absolute Centering)
                            ZStack {
                                // Left: Volume
                                HStack {
                                    Button(action: {}) {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                    .frame(width: 40)
                                    Spacer()
                                }
                                
                                // Center: Playback Controls
                                HStack(spacing: 24) { // Increased spacing for better touch targets
                                    Button(action: musicController.previousTrack) {
                                        Image(systemName: "backward.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Button(action: musicController.togglePlayPause) {
                                        Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 32))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Button(action: musicController.nextTrack) {
                                        Image(systemName: "forward.fill")
                                            .font(.system(size: 18))
                                            .foregroundColor(.white)
                                    }
                                }
                                
                                // Right: Lyrics & List
                                HStack {
                                    Spacer()
                                    HStack(spacing: 16) {
                                        Button(action: { withAnimation { isFlipped.toggle() } }) {
                                            Image(systemName: "quote.bubble")
                                                .font(.system(size: 14))
                                                .foregroundColor(isFlipped ? .white : .white.opacity(0.7))
                                        }
                                        
                                        Button(action: {}) {
                                            Image(systemName: "list.bullet")
                                                .font(.system(size: 14))
                                                .foregroundColor(.white.opacity(0.7))
                                        }
                                    }
                                    .frame(width: 60, alignment: .trailing)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    } else {
                        // Lyrics View
                        LyricsView()
                            .onTapGesture {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                    isFlipped.toggle()
                                }
                            }
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(width: 300, height: 340) // Compact MiniPlayer size
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ZStack {
        // Simulate Desktop Wallpaper (Purple)
        if let wallpaperURL = Bundle.module.url(forResource: "wallpaper", withExtension: "jpg"),
           let wallpaper = NSImage(contentsOf: wallpaperURL) {
            Image(nsImage: wallpaper)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
        } else {
            Color.purple
                .ignoresSafeArea()
        }

        // The Player Window
        MiniPlayerView()
            .environmentObject({
                let controller = MusicController.shared
                controller.currentTrackTitle = "Cariño"
                controller.currentArtist = "The Marías"
                if let artURL = Bundle.module.url(forResource: "album_cover", withExtension: "jpg"),
                   let art = NSImage(contentsOf: artURL) {
                    controller.currentArtwork = art
                }
                return controller
            }())
            .frame(width: 300, height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
    }
}
