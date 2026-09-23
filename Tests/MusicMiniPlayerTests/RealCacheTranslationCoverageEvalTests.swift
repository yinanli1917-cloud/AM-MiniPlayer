import XCTest
@testable import MusicMiniPlayerCore

/// Offline eval over a READ-ONLY snapshot of the founder's real lyrics/
/// translation disk caches (coordinator-provided, 2026-09-23,
/// `.eval-local/lyrics_cache.json` + `.eval-local/translation_cache.json`).
///
/// This class is OPTIONAL by design: `.eval-local/` is git-ignored and only
/// present when a coordinator/founder drops a snapshot in manually. Every
/// test here skips (via `XCTSkip`) when the folder is absent, so it never
/// runs in CI and never touches `~/Library/Application Support/nanoPod/` --
/// it only ever reads the snapshot files already copied into the worktree.
/// Never writes to `.eval-local/` (read-only per the coordinator's
/// instruction; also .gitignore'd so it can never be committed).
///
/// Decodes entries with the project's own public `LyricsDiskCacheEntry` /
/// `CachedLyricLine` / `TranslationCacheEntry` types (only the private
/// top-level `{version, entries}` envelope struct is re-declared locally,
/// since those wrapper types are `private` to their own files -- their
/// SHAPE is not private, it's documented in each file's own header comment
/// and verified against the actual snapshot JSON before writing this).
final class RealCacheTranslationCoverageEvalTests: XCTestCase {

    // ------------------------------------------------------------------
    // MARK: - Envelope mirrors (see LyricsDiskCache.swift / TranslationDiskCache.swift headers)
    // ------------------------------------------------------------------

    private struct LyricsCacheFileEnvelope: Decodable {
        let version: Int
        let entries: [String: LyricsDiskCacheEntry]
    }

    private struct TranslationCacheFileEnvelope: Decodable {
        let version: Int
        let entries: [String: TranslationCacheEntry]
    }

    private func evalLocalDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/MusicMiniPlayerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(".eval-local")
    }

    // ------------------------------------------------------------------
    // MARK: - Eval
    // ------------------------------------------------------------------

    func test_realCacheSourceDetectionAndCoverageEval() throws {
        let dir = evalLocalDir()
        let lyricsURL = dir.appendingPathComponent("lyrics_cache.json")
        guard FileManager.default.fileExists(atPath: lyricsURL.path) else {
            throw XCTSkip(".eval-local/lyrics_cache.json not present -- this eval only runs when a coordinator/founder drops a real-cache snapshot into the worktree; skipping (never runs in CI, never touches real paths)")
        }

        let lyricsData = try Data(contentsOf: lyricsURL)
        let lyricsFile = try JSONDecoder().decode(LyricsCacheFileEnvelope.self, from: lyricsData)

        let translationURL = dir.appendingPathComponent("translation_cache.json")
        var translationEntries: [String: TranslationCacheEntry] = [:]
        if FileManager.default.fileExists(atPath: translationURL.path) {
            let translationData = try Data(contentsOf: translationURL)
            translationEntries = try JSONDecoder().decode(TranslationCacheFileEnvelope.self, from: translationData).entries
        }

        // Dedup: LyricsDiskCache.cacheKeys() emits several hashed keys per
        // song (title-normalization variants), so the same song's lines
        // appear under multiple dictionary keys. Group by a signature of the
        // line texts so each song is evaluated exactly once.
        struct UniqueSong {
            let entry: LyricsDiskCacheEntry
            var duplicateKeyCount: Int
        }
        var uniqueSongs: [String: UniqueSong] = [:]
        for entry in lyricsFile.entries.values {
            let lines = entry.lines ?? []
            guard !lines.isEmpty else { continue }
            let signature = lines.map(\.text).joined(separator: "\u{1}")
            if var existing = uniqueSongs[signature] {
                existing.duplicateKeyCount += 1
                uniqueSongs[signature] = existing
            } else {
                uniqueSongs[signature] = UniqueSong(entry: entry, duplicateKeyCount: 1)
            }
        }
        XCTAssertFalse(uniqueSongs.isEmpty, "The lyrics snapshot decoded but produced zero usable (non-empty-lines) unique songs -- dataset or decoding is broken")

        var tableRows: [String] = []
        var coverageDropRows: [String] = []
        var disagreementRows: [String] = []
        var totalOldCoverage = 0
        var totalNewCoverage = 0
        var songsWithBigDrop = 0
        var totalFingerprintMatches = 0

        for (songIndex, signature) in uniqueSongs.keys.sorted().enumerated() {
            let unique = uniqueSongs[signature]!
            let entry = unique.entry
            let lyricLines = LyricsDiskCache.lyricLines(from: entry.lines ?? [])
            guard !lyricLines.isEmpty else { continue }

            let eligibleIndices = LyricsService.translationEligibleLineIndices(in: lyricLines, onlyMissingTranslations: false)
            let eligibleTexts = eligibleIndices.map { lyricLines[$0].text }

            let diag = LyricsTranslationSourceDetection.diagnostics(eligibleLineTexts: eligibleTexts)

            // OLD logic (pre-2026-09-22): every eligible line was sent for
            // translation, no song-level source gate and no per-line
            // consistency gate at all.
            let oldCoverage = eligibleIndices.count

            var newCoverage = 0
            var gatedOutSamples: [String] = []
            if let source = diag.language {
                for idx in eligibleIndices {
                    if LyricsTranslationSourceDetection.lineIsConsistent(lyricLines[idx].text, withSongSource: source) {
                        newCoverage += 1
                    } else {
                        gatedOutSamples.append(lyricLines[idx].text)
                    }
                }
            } else {
                // Song source undetermined -> the new gate sends nothing.
                gatedOutSamples = eligibleTexts
            }
            totalOldCoverage += oldCoverage
            totalNewCoverage += newCoverage

            let confidenceStr = diag.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
            let languageStr = diag.language?.minimalIdentifier ?? "SKIP"
            let sampleGated = gatedOutSamples.prefix(3).joined(separator: " / ")
            let songLabel = "song#\(songIndex + 1) [\(entry.source), album=\(entry.album ?? "?"), dur=\(Int(entry.duration))s, \(unique.duplicateKeyCount)x dup cache keys]"
            tableRows.append(
                "\(songLabel): method=\(diag.method) lang=\(languageStr) confidence=\(confidenceStr) " +
                "totalLines=\(lyricLines.count) eligible=\(oldCoverage) gatedOut=\(gatedOutSamples.count) " +
                "sample_gated=[\(sampleGated)]"
            )

            if oldCoverage > 0 {
                let dropRatio = Double(oldCoverage - newCoverage) / Double(oldCoverage)
                if dropRatio > 0.10 {
                    songsWithBigDrop += 1
                    coverageDropRows.append(
                        "\(songLabel): OLD=\(oldCoverage) NEW=\(newCoverage) drop=\(String(format: "%.0f%%", dropRatio * 100))\n" +
                        "  ALL DROPPED LINES: \(gatedOutSamples)"
                    )
                }
            }

            // Cross-check against the translation snapshot via CONTENT
            // fingerprint (firstRealLineSHA256|lineCount) -- the same join
            // key TranslationDiskCache itself uses to trust a row, robust to
            // the lyrics-cache key and translation-cache key using different
            // hash schemes.
            guard !translationEntries.isEmpty else { continue }
            let firstRealIndex = lyricLines.firstIndex(where: { LyricsParser.shared.isRealLyricLine($0.text) }) ?? 0
            let fingerprint = LyricsService.translationFingerprint(lyrics: lyricLines, firstRealLyricIndex: firstRealIndex)
            for (key, translationEntry) in translationEntries where translationEntry.fingerprint == fingerprint {
                totalFingerprintMatches += 1
                let targetLanguageTag = key.split(separator: "|").last.map(String.init) ?? "?"
                let targetPrimary = String(targetLanguageTag.prefix(2))
                guard let detectedSource = diag.language else { continue }
                // Disagreement signal: the cached translation's target
                // language shares the same primary subtag as the NEWLY
                // detected source -- i.e. "translating zh into zh", which
                // only makes sense for the from-lyrics-source
                // partial-fill case, not a from-scratch system translation.
                // Flag it as a signal worth a human look, not an assertion
                // failure (this snapshot predates the per-line gate and may
                // legitimately contain that case).
                if detectedSource.languageCode?.identifier == targetPrimary {
                    let sampleTranslated = Array(translationEntry.lines.values.prefix(2))
                    disagreementRows.append(
                        "\(songLabel): translation snapshot targets '\(targetLanguageTag)' but newly-detected source is ALSO '\(detectedSource.minimalIdentifier)' " +
                        "-- sample cached translated lines: \(sampleTranslated)"
                    )
                }
            }
        }

        print("\n=== Real-cache song-level source detection + coverage (\(uniqueSongs.count) unique songs, \(lyricsFile.entries.count) raw cache-key entries, \(translationEntries.count) translation-cache rows) ===")
        tableRows.forEach { print($0) }
        print("\nTotal eligible-line coverage: OLD=\(totalOldCoverage) NEW=\(totalNewCoverage) (\(totalOldCoverage > 0 ? String(format: "%.1f%%", Double(totalNewCoverage) / Double(totalOldCoverage) * 100) : "n/a") retained)")
        print("\n=== Songs with coverage drop > 10% (\(songsWithBigDrop)) ===")
        if coverageDropRows.isEmpty { print("(none)") }
        coverageDropRows.forEach { print($0) }
        print("\nFingerprint join: \(totalFingerprintMatches) translation-cache rows matched one of the \(uniqueSongs.count) unique songs by content fingerprint (out of \(translationEntries.count) translation-cache rows total -- a low/zero count here means the translation snapshot mostly covers OTHER songs not present in this lyrics snapshot, not that the disagreement check found nothing to check)")
        print("\n=== Source vs. cached-translation-target disagreements (\(disagreementRows.count)) ===")
        if disagreementRows.isEmpty { print("(none)") }
        disagreementRows.forEach { print($0) }
        print("=====================================================================\n")
    }
}

private extension Locale.Language {
    var minimalIdentifier: String {
        guard let code = languageCode?.identifier else { return "unknown" }
        if code == "zh", let script = script?.identifier {
            return "zh-\(script)"
        }
        return code
    }
}
