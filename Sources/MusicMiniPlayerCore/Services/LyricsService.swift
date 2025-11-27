import Foundation
import Combine
import os

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
    private let logger = Logger(subsystem: "com.yinanli.MusicMiniPlayer", category: "LyricsService")

    private init() {}

    func fetchLyrics(for title: String, artist: String, duration: TimeInterval, forceRefresh: Bool = false) {
        // Avoid re-fetching if same song (unless force refresh)
        let songID = "\(title)-\(artist)"
        guard songID != currentSongID || forceRefresh else { return }

        currentSongID = songID
        isLoading = true
        error = nil
        // Don't clear lyrics immediately - keep showing old lyrics until new ones load
        currentLineIndex = nil

        logger.info("🎤 Fetching lyrics for: \(title) - \(artist) (duration: \(Int(duration))s)")

        Task {
            var fetchedLyrics: [LyricLine]? = nil

            // Try multiple sources in parallel for faster response
            do {
                logger.info("🔍 Starting parallel search from multiple sources...")

                async let source1 = try? await fetchFromAMLLTTMLDB(title: title, artist: artist, duration: duration)
                async let source2 = try? await fetchFromLRCLIB(title: title, artist: artist, duration: duration)
                async let source3 = try? await fetchFromLyricsOVH(title: title, artist: artist, duration: duration)

                // Return the first successful result
                let results = await [source1, source2, source3]
                fetchedLyrics = results.first { $0 != nil } ?? nil

                logger.info("🎤 Parallel search completed")

                if let lyrics = fetchedLyrics {
                    await MainActor.run {
                        self.lyrics = lyrics
                        self.isLoading = false
                        self.error = nil
                        self.logger.info("✅ Successfully fetched \(lyrics.count) lyric lines")
                    }
                } else {
                    throw NSError(domain: "LyricsService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Lyrics not found in any source"])
                }
            } catch {
                await MainActor.run {
                    self.lyrics = []
                    self.isLoading = false
                    self.error = "No lyrics available"
                    self.logger.error("❌ Failed to fetch lyrics from all sources")
                }
            }
        }
    }

    func updateCurrentTime(_ time: TimeInterval) {
        // IMPORTANT: 3.5 second tolerance for smooth animation
        // This was determined through extensive testing to account for:
        // 1. Animation lead time for scroll-to-center effect
        // 2. User perception delay
        // 3. Network/processing latency
        // DO NOT REMOVE THIS TOLERANCE without discussing with user
        let tolerance: TimeInterval = 3.5

        var bestMatch: Int? = nil

        for (index, line) in lyrics.enumerated() {
            // Check if current time is within this line's range (with tolerance)
            if time >= (line.startTime - tolerance) && time < line.endTime {
                bestMatch = index
                break
            }
        }

        // Update if we found a match and it's different
        if let newIndex = bestMatch {
            if currentLineIndex != newIndex {
                currentLineIndex = newIndex
            }
        } else {
            // No line matches - set to nil (will trigger loading dots)
            currentLineIndex = nil
        }
    }

    // MARK: - amll-ttml-db API (TTML format with word-level timing)
    
    private func fetchFromAMLLTTMLDB(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        logger.info("🌐 Fetching from amll-ttml-db: \(title) by \(artist)")
        
        // Note: This is a placeholder API endpoint - update with actual amll-ttml-db API when available
        // Common pattern: https://api.amll-ttml-db.com/search?title=...&artist=...
        // For now, we'll use a reasonable endpoint structure that can be updated
        
        // Build URL with parameters
        var components = URLComponents(string: "https://api.amll-ttml-db.com/api/search")!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]
        
        guard let url = components.url else {
            logger.error("Invalid amll-ttml-db URL")
            return nil
        }
        
        logger.info("📡 Request URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10.0
        
        let session = URLSession.shared
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type from amll-ttml-db")
                return nil
            }
            
            logger.info("📦 Response status: \(httpResponse.statusCode)")
            
            // Check for 404 - no lyrics found
            if httpResponse.statusCode == 404 {
                logger.warning("No lyrics found in amll-ttml-db")
                return nil
            }
            
            // Check for other errors
            guard (200...299).contains(httpResponse.statusCode) else {
                logger.error("HTTP error from amll-ttml-db: \(httpResponse.statusCode)")
                return nil
            }
            
            // Try to parse as JSON first (API might return JSON with TTML content)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Check if response contains TTML data
                if let ttmlContent = json["ttml"] as? String, !ttmlContent.isEmpty {
                    logger.info("✅ Found TTML content in JSON response")
                    return parseTTML(ttmlContent)
                } else if let ttmlUrl = json["ttml_url"] as? String, let ttmlUrlObj = URL(string: ttmlUrl) {
                    // If API returns a URL to TTML file, fetch it
                    logger.info("📥 Fetching TTML from URL: \(ttmlUrl)")
                    let (ttmlData, _) = try await session.data(from: ttmlUrlObj)
                    if let ttmlString = String(data: ttmlData, encoding: .utf8) {
                        return parseTTML(ttmlString)
                    }
                }
            }
            
            // Try parsing as direct TTML XML
            if let ttmlString = String(data: data, encoding: .utf8), !ttmlString.isEmpty {
                logger.info("✅ Received TTML content directly")
                return parseTTML(ttmlString)
            }
            
            logger.warning("No TTML content found in amll-ttml-db response")
            return nil
        } catch {
            logger.error("❌ Error fetching from amll-ttml-db: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - TTML Parser
    
    private func parseTTML(_ ttmlString: String) -> [LyricLine]? {
        logger.info("📝 Parsing TTML content (\(ttmlString.count) chars)")
        
        // TTML format: <tt><body><div><p begin="HH:MM:SS.mmm" end="HH:MM:SS.mmm">Text</p></div></body></tt>
        // We'll use a simple parser to extract <p> elements with timing
        
        var lines: [LyricLine] = []
        
        // Pattern to match <p> tags with begin and end attributes
        // Matches: <p begin="00:00:10.500" end="00:00:15.200">Text here</p>
        let pattern = "<p[^>]*begin=\"([^\"]+)\"[^>]*end=\"([^\"]+)\"[^>]*>(.*?)</p>"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            logger.error("Failed to create TTML regex")
            return nil
        }
        
        let matches = regex.matches(in: ttmlString, range: NSRange(ttmlString.startIndex..., in: ttmlString))
        
        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            
            // Extract begin time
            guard let beginRange = Range(match.range(at: 1), in: ttmlString) else { continue }
            let beginString = String(ttmlString[beginRange])
            
            // Extract end time
            guard let endRange = Range(match.range(at: 2), in: ttmlString) else { continue }
            let endString = String(ttmlString[endRange])
            
            // Extract text content
            guard let textRange = Range(match.range(at: 3), in: ttmlString) else { continue }
            var text = String(ttmlString[textRange])
            
            // Remove any nested tags and decode HTML entities
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "&lt;", with: "<")
            text = text.replacingOccurrences(of: "&gt;", with: ">")
            text = text.replacingOccurrences(of: "&amp;", with: "&")
            text = text.replacingOccurrences(of: "&quot;", with: "\"")
            text = text.replacingOccurrences(of: "&apos;", with: "'")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !text.isEmpty else { continue }
            
            // Parse time format: HH:MM:SS.mmm or HH:MM:SS,mmm
            if let startTime = parseTTMLTime(beginString),
               let endTime = parseTTMLTime(endString) {
                lines.append(LyricLine(text: text, startTime: startTime, endTime: endTime))
            }
        }
        
        // Sort by start time to ensure correct order
        lines.sort { $0.startTime < $1.startTime }
        
        logger.info("✅ Parsed \(lines.count) lyric lines from TTML")
        return lines.isEmpty ? nil : lines
    }
    
    private func parseTTMLTime(_ timeString: String) -> TimeInterval? {
        // TTML time format: HH:MM:SS.mmm or HH:MM:SS,mmm or HH:MM:SS.mm
        // Also supports: H:MM:SS.mmm (single digit hour)
        let components = timeString.components(separatedBy: CharacterSet(charactersIn: ":,."))
        
        guard components.count >= 3 else { return nil }
        
        let hour = Int(components[0]) ?? 0
        let minute = Int(components[1]) ?? 0
        let second = Int(components[2]) ?? 0
        let millisecond = components.count > 3 ? (Int(components[3]) ?? 0) : 0
        
        let totalSeconds = Double(hour * 3600) + Double(minute * 60) + Double(second) + Double(millisecond) / 1000.0
        return totalSeconds
    }

    // MARK: - LRCLIB API (Free, Open-Source Lyrics Database)

    private func fetchFromLRCLIB(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        logger.info("🌐 Fetching from LRCLIB: \(title) by \(artist)")

        // Build URL with parameters
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ]

        guard let url = components.url else {
            logger.error("Invalid LRCLIB URL")
            return nil
        }

        logger.info("📡 Request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0 (https://github.com/yourusername/MusicMiniPlayer)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type")
            return nil
        }

        logger.info("📦 Response status: \(httpResponse.statusCode)")

        // Check for 404 - no lyrics found
        if httpResponse.statusCode == 404 {
            logger.warning("No lyrics found in LRCLIB database")
            return nil
        }

        // Check for other errors
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error: \(httpResponse.statusCode)")
            return nil
        }

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.error("Failed to parse JSON response")
            return nil
        }

        logger.info("✅ Received response with keys: \(json.keys.joined(separator: ", "))")

        // LRCLIB returns synced lyrics in "syncedLyrics" field as LRC format string
        if let syncedLyrics = json["syncedLyrics"] as? String, !syncedLyrics.isEmpty {
            logger.info("✅ Found synced lyrics (\(syncedLyrics.count) chars)")
            return parseLRC(syncedLyrics)
        }

        // Fallback to plain lyrics if synced not available
        if let plainLyrics = json["plainLyrics"] as? String, !plainLyrics.isEmpty {
            logger.info("⚠️ Only plain lyrics available, creating basic timing")
            return createUnsyncedLyrics(plainLyrics, duration: duration)
        }

        logger.warning("No lyrics content in response")
        return nil
    }

    // MARK: - LRC Parser

    private func parseLRC(_ lrcText: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        // LRC format: [mm:ss.xx]Lyric text
        // Pattern: [minutes:seconds.centiseconds]text
        let pattern = "\\[(\\d{2}):(\\d{2})[:.](\\d{2,3})\\](.+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            logger.error("Failed to create LRC regex")
            return []
        }

        let lrcLines = lrcText.components(separatedBy: .newlines)

        for line in lrcLines {
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))

            for match in matches {
                guard match.numberOfRanges == 5,
                      let minuteRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let centisecondRange = Range(match.range(at: 3), in: line),
                      let textRange = Range(match.range(at: 4), in: line) else {
                    continue
                }

                let minute = Int(line[minuteRange]) ?? 0
                let second = Int(line[secondRange]) ?? 0
                let centisecond = Int(line[centisecondRange]) ?? 0

                let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                let startTime = Double(minute * 60) + Double(second) + Double(centisecond) / 100.0

                lines.append(LyricLine(text: text, startTime: startTime, endTime: startTime + 5.0))
            }
        }

        // Calculate proper end times based on next line's start time
        for i in 0..<lines.count {
            if i < lines.count - 1 {
                let nextStartTime = lines[i + 1].startTime
                lines[i] = LyricLine(text: lines[i].text, startTime: lines[i].startTime, endTime: nextStartTime)
            }
        }

        logger.info("Parsed \(lines.count) lyric lines from LRC")
        return lines
    }

    // MARK: - lyrics.ovh API (Free, Simple Alternative)

    private func fetchFromLyricsOVH(title: String, artist: String, duration: TimeInterval) async throws -> [LyricLine]? {
        logger.info("🌐 Fetching from lyrics.ovh: \(title) by \(artist)")

        // URL encode artist and title
        guard let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            logger.error("Failed to encode artist/title for lyrics.ovh")
            return nil
        }

        let urlString = "https://api.lyrics.ovh/v1/\(encodedArtist)/\(encodedTitle)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid lyrics.ovh URL")
            return nil
        }

        logger.info("📡 Request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("MusicMiniPlayer/1.0", forHTTPHeaderField: "User-Agent")

        let session = URLSession.shared
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from lyrics.ovh")
            return nil
        }

        logger.info("📦 Response status: \(httpResponse.statusCode)")

        // Check for 404 - no lyrics found
        if httpResponse.statusCode == 404 {
            logger.warning("No lyrics found in lyrics.ovh")
            return nil
        }

        // Check for other errors
        guard (200...299).contains(httpResponse.statusCode) else {
            logger.error("HTTP error from lyrics.ovh: \(httpResponse.statusCode)")
            return nil
        }

        // Parse JSON response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyricsText = json["lyrics"] as? String, !lyricsText.isEmpty else {
            logger.warning("No lyrics content in lyrics.ovh response")
            return nil
        }

        logger.info("✅ Found lyrics from lyrics.ovh (\(lyricsText.count) chars)")

        // lyrics.ovh returns plain text, create unsynced lyrics
        return createUnsyncedLyrics(lyricsText, duration: duration)
    }

    // MARK: - Unsynced Lyrics Fallback

    private func createUnsyncedLyrics(_ plainText: String, duration: TimeInterval) -> [LyricLine] {
        let textLines = plainText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !textLines.isEmpty else { return [] }

        // Distribute lines evenly across song duration
        let timePerLine = duration / Double(textLines.count)

        var lines: [LyricLine] = []
        for (index, text) in textLines.enumerated() {
            let startTime = Double(index) * timePerLine
            let endTime = Double(index + 1) * timePerLine
            lines.append(LyricLine(text: text, startTime: startTime, endTime: endTime))
        }

        logger.info("Created \(lines.count) unsynced lyric lines")
        return lines
    }
}
