import SwiftUI

public struct LyricsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    
    public init() {}
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if lyricsService.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = lyricsService.error {
                        Text(error)
                            .foregroundColor(.red)
                    } else {
                        ForEach(Array(lyricsService.lyrics.enumerated()), id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.system(size: index == lyricsService.currentLineIndex ? 24 : 18,
                                              weight: index == lyricsService.currentLineIndex ? .bold : .regular,
                                              design: .rounded))
                                .foregroundColor(index == lyricsService.currentLineIndex ? .white : .white.opacity(0.5))
                                .blur(radius: index == lyricsService.currentLineIndex ? 0 : 0.5)
                                .scaleEffect(index == lyricsService.currentLineIndex ? 1.05 : 1.0)
                                .animation(.spring(), value: lyricsService.currentLineIndex)
                                .id(index)
                                .onTapGesture {
                                    // Seek to this line? (Optional feature)
                                }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .onChange(of: lyricsService.currentLineIndex) {
                if let index = lyricsService.currentLineIndex {
                    withAnimation {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
        .onAppear {
            // Trigger fetch when view appears
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
}

#Preview {
    LyricsView()
        .environmentObject(MusicController.shared)
        .frame(width: 300, height: 300)
        .background(Color.black)
}
