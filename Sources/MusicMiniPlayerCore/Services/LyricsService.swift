import Foundation
import Combine

// MARK: - Models

public struct LyricLine: Identifiable, Equatable {
    public let id = UUID()
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    
    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Service

public class LyricsService: ObservableObject {
    public static let shared = LyricsService()
    
    @Published public var lyrics: [LyricLine] = []
    @Published public var currentLineIndex: Int? = nil
    @Published var isLoading: Bool = false
    @Published var error: String? = nil
    
    private var currentSongID: String?
    
    private init() {}
    
    func fetchLyrics(for title: String, artist: String, duration: TimeInterval) {
        // Avoid re-fetching if same song (simplified check)
        let songID = "\(title)-\(artist)"
        guard songID != currentSongID else { return }
        
        currentSongID = songID
        isLoading = true
        error = nil
        lyrics = []
        
        // TODO: Implement actual Web Scraping / API call here
        // For now, we simulate a network delay and return mock synced lyrics
        // so the user can verify the UI and Animation.
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let mockLyrics = self?.generateMockLyrics(duration: duration) ?? []
            DispatchQueue.main.async {
                self?.lyrics = mockLyrics
                self?.isLoading = false
            }
        }
    }
    
    func updateCurrentTime(_ time: TimeInterval) {
        // Find the line that corresponds to the current time
        // This is a simple linear search; for large lyrics, binary search is better
        if let index = lyrics.firstIndex(where: { time >= $0.startTime && time < $0.endTime }) {
            if currentLineIndex != index {
                currentLineIndex = index
            }
        }
    }
    
    // MARK: - Mock Data Generator
    private func generateMockLyrics(duration: TimeInterval) -> [LyricLine] {
        var lines: [LyricLine] = []
        let lineCount = 20
        let lineDuration = duration / Double(lineCount)
        
        for i in 0..<lineCount {
            let start = Double(i) * lineDuration
            let end = start + lineDuration
            lines.append(LyricLine(
                text: "This is a simulated lyric line #\(i + 1)",
                startTime: start,
                endTime: end
            ))
        }
        return lines
    }
}
