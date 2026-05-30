import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class DiagnosticsServiceTests: XCTestCase {
    private var diagnosticsStorageRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let diagnosticsStorageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanoPod-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticsStorageRoot, withIntermediateDirectories: true)
        self.diagnosticsStorageRoot = diagnosticsStorageRoot
        DiagnosticsService.shared.setStorageBaseDirectoryForTesting(diagnosticsStorageRoot)
        DiagnosticsService.shared.setDebugLogURLForTesting(diagnosticsStorageRoot.appendingPathComponent("nanopod_debug.log"))
        DiagnosticsService.shared.isEnabled = true
        DiagnosticsService.shared.clear()
    }

    override func tearDownWithError() throws {
        DiagnosticsService.shared.clear()
        DiagnosticsService.shared.isEnabled = false
        DiagnosticsService.shared.setStorageBaseDirectoryForTesting(nil)
        DiagnosticsService.shared.setDebugLogURLForTesting(nil)
        DebugLogger.resetLogURL()
        if let diagnosticsStorageRoot {
            try? FileManager.default.removeItem(at: diagnosticsStorageRoot)
        }
        diagnosticsStorageRoot = nil
        try super.tearDownWithError()
    }

    func testSlowLyricsFetchCreatesIncident() {
        let track = DiagnosticTrackContext(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 240
        )

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "NetEase",
            score: 80,
            lineCount: 20,
            isUnsynced: false,
            hadSourceTranslation: true
        )

        // A finish without a matching start uses a zero-duration fallback and should not flag.
        XCTAssertTrue(DiagnosticsService.shared.incidents.isEmpty)

        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "pollPositionViaSB",
            queueWait: 0.4,
            readTime: 0.02,
            timedOut: false
        )

        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.category, .scriptingBridgeBacklog)
    }

    func testSlowAuthoritativeBackfillCreatesResolverIncident() {
        let track = DiagnosticTrackContext(
            title: "The Key",
            artist: "JJ Lin",
            album: "From M.E. To Myself",
            duration: 207
        )

        DiagnosticsService.shared.recordLyricsBackfillStarted(
            track: track,
            foregroundFetchSeconds: 6.2,
            foregroundResultCount: 0
        )
        DiagnosticsService.shared.recordLyricsBackfillFinished(
            track: track,
            result: "lyrics",
            source: "NetEase",
            score: 84,
            lineCount: 36
        )

        let event = DiagnosticsService.shared.events.first { $0.name == "lyrics.backfill.finish" }
        XCTAssertTrue(event?.detail.contains("NetEase") ?? false)
        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .lyricsSlowFetch)
        XCTAssertEqual(incident?.title, "Slow lyrics authoritative backfill")
        XCTAssertEqual(incident?.evidence["source"], "NetEase")
        XCTAssertGreaterThanOrEqual(incident?.metrics["totalResolverSeconds"] ?? 0, 6.2)
    }

    func testTrackContextEnrichmentBackfillsPlaylistAndClass() {
        let earlyTrack = DiagnosticTrackContext(
            title: "Distance (feat. deca joins)",
            artist: "Enno Cheng",
            album: "Mercury Retrograde",
            duration: 246.546,
            persistentID: "STALE_PREVIOUS_ID",
            playbackContext: "unknown",
            playerPage: "lyrics"
        )
        DiagnosticsService.shared.recordEvent(
            "artwork.fetch.start",
            detail: "Artwork fetch started before bridge context arrived.",
            track: earlyTrack
        )
        DiagnosticsService.shared.recordLyricsFetchMiss(track: earlyTrack, resultCount: 1)

        let enriched = DiagnosticTrackContext(
            title: "Distance (feat. deca joins)",
            artist: "Enno Cheng",
            album: "Mercury Retrograde",
            duration: 246.546,
            persistentID: "CURRENT_ID",
            trackClass: "shared track",
            playlistName: "Music",
            playbackContext: "playlist-or-library",
            playerPage: "lyrics"
        )
        DiagnosticsService.shared.enrichTrackContext(enriched)

        XCTAssertEqual(DiagnosticsService.shared.events.first { $0.name == "artwork.fetch.start" }?.track?.persistentID, "CURRENT_ID")
        XCTAssertEqual(DiagnosticsService.shared.events.first { $0.name == "artwork.fetch.start" }?.track?.trackClass, "shared track")
        XCTAssertEqual(DiagnosticsService.shared.events.first { $0.name == "artwork.fetch.start" }?.track?.playlistName, "Music")
        XCTAssertEqual(DiagnosticsService.shared.events.first { $0.name == "artwork.fetch.start" }?.track?.playbackContext, "playlist-or-library")
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.track?.persistentID, "CURRENT_ID")
    }

    func testStandaloneMinorScriptingBridgeReadStaysInBaselineOnly() {
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "pollPositionViaSB",
            queueWait: 0.001,
            readTime: 0.265,
            timedOut: false
        )

        XCTAssertTrue(DiagnosticsService.shared.incidents.isEmpty)
    }

    func testStandalonePositionPollSlowReadStaysInBaselineOnly() {
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "pollPositionViaSB",
            queueWait: 0.001,
            readTime: 0.650,
            timedOut: false
        )

        XCTAssertTrue(DiagnosticsService.shared.incidents.isEmpty)
        let event = DiagnosticsService.shared.events.first { $0.name == "scriptingBridge.positionPoll.slowReadBaseline" }
        XCTAssertEqual(event?.metrics["readMs"] ?? -1, 650, accuracy: 0.001)
    }

    func testStandaloneFullStateSlowReadStaysInBaselineOnly() {
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "updatePlayerState",
            queueWait: 0.001,
            readTime: 0.650,
            timedOut: false
        )

        XCTAssertTrue(DiagnosticsService.shared.incidents.isEmpty)
        let event = DiagnosticsService.shared.events.first { $0.name == "scriptingBridge.standaloneSlowReadBaseline" }
        XCTAssertEqual(event?.metrics["readMs"] ?? -1, 650, accuracy: 0.001)
    }

    func testCorrelatedScriptingBridgeReadCreatesIncident() {
        let id = DiagnosticsService.shared.beginInteraction(
            type: .pageSwitch,
            page: "lyrics",
            expectedDuration: 0.35
        )

        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "updatePlayerState",
            queueWait: 0.001,
            readTime: 0.650,
            timedOut: false
        )

        DiagnosticsService.shared.completeInteraction(id)

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .scriptingBridgeLatency }
        XCTAssertEqual(incident?.severity, .critical)
        XCTAssertEqual(incident?.metrics["readMs"] ?? 0, 650, accuracy: 0.001)
    }

    func testSevereStandalonePositionPollReadCreatesIncident() {
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "pollPositionViaSB",
            queueWait: 0.001,
            readTime: 1.150,
            timedOut: false
        )

        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .scriptingBridgeLatency)
        XCTAssertEqual(incident?.evidence["operation"], "pollPositionViaSB")
        XCTAssertEqual(incident?.metrics["readMs"] ?? 0, 1150, accuracy: 0.001)
    }

    func testRepeatedScriptingBridgeTimeoutsCoalesceByOperation() {
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "updatePlayerState",
            queueWait: 0,
            readTime: 2.0,
            timedOut: true
        )
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "updatePlayerState",
            queueWait: 0.01,
            readTime: 2.3,
            timedOut: true
        )

        XCTAssertEqual(DiagnosticsService.shared.incidents.count, 1)
        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .scriptingBridgeTimeout)
        XCTAssertEqual(incident?.title, "ScriptingBridge timeout burst")
        XCTAssertEqual(incident?.metrics["occurrenceCount"] ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(incident?.metrics["maxReadMs"] ?? 0, 2300, accuracy: 0.001)
        XCTAssertEqual(incident?.evidence["operation"], "updatePlayerState")
    }

    func testPartialSourceTranslationCreatesEventUntilSystemFillFails() {
        let track = DiagnosticTrackContext(
            title: "Anohini Kaeritai",
            artist: "Miki Imai",
            album: "Dialogue",
            duration: 249
        )

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "NetEase",
            score: 93.5,
            lineCount: 21,
            isUnsynced: false,
            hadSourceTranslation: true,
            translationLineCount: 13,
            translatableLineCount: 20,
            missingTranslationLineCount: 7,
            translationDisplayRequested: true
        )

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsPartialTranslation })
        let event = DiagnosticsService.shared.events.first { $0.name == "lyrics.translation.partialSource" }
        XCTAssertEqual(event?.metrics["translationLineCount"], 13)
        XCTAssertEqual(event?.metrics["missingTranslationLineCount"], 7)
        XCTAssertEqual(event?.metrics["translationCoverage"] ?? -1, 0.65, accuracy: 0.001)
    }

    func testSystemFillClearsPartialSourceTranslationGapIncident() {
        let track = DiagnosticTrackContext(
            title: "The Way We Were",
            artist: "Teresa Teng",
            album: "愛之世界",
            duration: 207.773
        )

        DiagnosticsService.shared.recordLyricsSystemTranslationGap(
            track: track,
            reason: "translation task failed",
            translationLanguage: "zh-Hant",
            translationLineCount: 15,
            translatableLineCount: 16
        )

        XCTAssertEqual(
            DiagnosticsService.shared.incidents.filter { $0.category == .lyricsPartialTranslation }.count,
            1
        )

        DiagnosticsService.shared.recordLyricsPartialTranslationFilled(
            track: track,
            filledLineCount: 1,
            translationLineCount: 16,
            translatableLineCount: 16,
            translationLanguage: "zh-Hant"
        )

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsPartialTranslation })
        let event = DiagnosticsService.shared.events.first {
            $0.name == "lyrics.translation.filledPartialSource"
        }
        XCTAssertEqual(event?.track, track)
        XCTAssertEqual(event?.metrics["filledLineCount"], 1)
        XCTAssertEqual(event?.metrics["clearedPartialTranslationIncidentCount"], 1)
    }

    func testSystemTranslationGapIsInspectableAndClearedBySystemFill() {
        let track = DiagnosticTrackContext(
            title: "Voyage",
            artist: "MUNYA",
            album: "Voyage to Mars",
            duration: 186.5
        )

        DiagnosticsService.shared.recordLyricsSystemTranslationGap(
            track: track,
            reason: "language pair supported but not installed",
            translationLanguage: "zh-Hans",
            translationLineCount: 0,
            translatableLineCount: 36
        )

        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .lyricsPartialTranslation)
        XCTAssertEqual(incident?.title, "System translation unavailable")
        XCTAssertEqual(incident?.metrics["missingTranslationLineCount"], 36)
        XCTAssertEqual(incident?.evidence["translationLanguage"], "zh-Hans")

        DiagnosticsService.shared.recordLyricsSystemTranslationFilled(
            track: track,
            filledLineCount: 36,
            translationLineCount: 36,
            translatableLineCount: 36,
            translationLanguage: "zh-Hans"
        )

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsPartialTranslation })
        let event = DiagnosticsService.shared.events.first { $0.name == "lyrics.translation.filledSystem" }
        XCTAssertEqual(event?.metrics["filledLineCount"], 36)
        XCTAssertEqual(event?.metrics["clearedPartialTranslationIncidentCount"], 1)
    }

    func testVisibleLineTranslationGapCreatesInspectableIncidentWhenAggregateCoverageLooksComplete() {
        let track = DiagnosticTrackContext(
            title: "Visible Gap",
            artist: "Diagnostics",
            album: "Fixture",
            duration: 180,
            playbackTime: 42,
            playerPage: "lyrics"
        )

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "NetEase",
            score: 97,
            lineCount: 3,
            isUnsynced: false,
            hadSourceTranslation: true,
            translationLineCount: 2,
            translatableLineCount: 2,
            missingTranslationLineCount: 0,
            translationDisplayRequested: true
        )
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsPartialTranslation })

        DiagnosticsService.shared.recordLyricsVisibleTranslationGap(
            track: track,
            lineIndex: 1,
            displayIndex: 1,
            activeIndex: 1,
            playbackTime: 42.2,
            lineStartTime: 42,
            lineEndTime: 44,
            totalLineCount: 3,
            visibleLineCount: 3,
            visibleTranslatedLineCount: 2,
            visibleMissingTranslationLineCount: 1,
            lineIsTranslationEligible: false,
            lineIsVocable: true,
            showTranslation: true,
            canTranslate: true,
            translationFailed: false
        )
        DiagnosticsService.shared.recordLyricsVisibleTranslationGap(
            track: track,
            lineIndex: 1,
            displayIndex: 1,
            activeIndex: 1,
            playbackTime: 42.4,
            lineStartTime: 42,
            lineEndTime: 44,
            totalLineCount: 3,
            visibleLineCount: 3,
            visibleTranslatedLineCount: 2,
            visibleMissingTranslationLineCount: 1,
            lineIsTranslationEligible: false,
            lineIsVocable: true,
            showTranslation: true,
            canTranslate: true,
            translationFailed: false
        )

        let incidents = DiagnosticsService.shared.incidents.filter { $0.category == .lyricsPartialTranslation }
        XCTAssertEqual(incidents.count, 1)
        let incident = incidents.first
        XCTAssertEqual(incident?.title, "Visible lyric line missing translation")
        XCTAssertEqual(incident?.userSymptom, .missingTranslation)
        XCTAssertEqual(incident?.metrics["lineIndex"], 1)
        XCTAssertEqual(incident?.metrics["visibleTranslatedLineCount"], 2)
        XCTAssertEqual(incident?.metrics["visibleMissingTranslationLineCount"], 1)
        XCTAssertEqual(incident?.metrics["lineIsVocable"], 1)
        XCTAssertEqual(incident?.metrics["occurrenceCount"], 2)
        XCTAssertEqual(incident?.evidence["source"], "visibleLine")
        XCTAssertEqual(
            incident?.evidence["reason"],
            "visible vocable line excluded from aggregate translation coverage"
        )
    }

    func testGeneratedLyricChunkMissingSourceTranslationCreatesInspectableIncident() {
        let track = DiagnosticTrackContext(
            title: "Segmented Translation Gap",
            artist: "Diagnostics",
            album: "Fixture",
            duration: 180,
            playbackTime: 120,
            playerPage: "lyrics"
        )

        DiagnosticsService.shared.recordLyricsVisibleTranslationGap(
            track: track,
            lineIndex: 12,
            sourceLineIndex: 7,
            segmentIndex: 1,
            segmentCount: 2,
            displayIndex: 12,
            activeIndex: 12,
            playbackTime: 120.2,
            lineStartTime: 119,
            lineEndTime: 121,
            totalLineCount: 30,
            visibleLineCount: 4,
            visibleTranslatedLineCount: 0,
            visibleMissingTranslationLineCount: 1,
            sourceLineHasTranslation: true,
            lineIsTranslationEligible: true,
            lineIsVocable: false,
            showTranslation: true,
            canTranslate: true,
            translationFailed: false
        )

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .lyricsPartialTranslation }
        XCTAssertEqual(incident?.title, "Visible lyric line missing translation")
        XCTAssertEqual(incident?.userSymptom, .missingTranslation)
        XCTAssertEqual(incident?.metrics["sourceLineHasTranslation"], 1)
        XCTAssertEqual(incident?.metrics["sourceLineIndex"], 7)
        XCTAssertEqual(incident?.metrics["segmentIndex"], 1)
        XCTAssertEqual(incident?.metrics["segmentCount"], 2)
        XCTAssertEqual(incident?.evidence["reason"], "generated display chunk lost source translation")
    }

    func testTrustedExactLRCLIBSyncedResultDoesNotCreateFallbackChurnNoise() {
        let track = DiagnosticTrackContext(
            title: "Round Midnight",
            artist: "Julie London",
            album: "Around Midnight",
            duration: 173.93
        )

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "LRCLIB",
            score: 26.9,
            lineCount: 17,
            isUnsynced: false,
            hadSourceTranslation: false,
            translationLineCount: 0,
            translatableLineCount: 16,
            missingTranslationLineCount: 16,
            translationDisplayRequested: true
        )

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
    }

    func testWeakLRCLIBSyncedResultStillCreatesFallbackChurnIncident() {
        let track = DiagnosticTrackContext(
            title: "Weak LRCLIB",
            artist: "Diagnostics",
            album: "Fixture",
            duration: 180
        )

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "LRCLIB",
            score: 18,
            lineCount: 8,
            isUnsynced: false,
            hadSourceTranslation: false
        )

        XCTAssertTrue(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
    }

    func testTranslatedSyncedProviderResultNearThresholdDoesNotCreateFallbackNoise() {
        let track = DiagnosticTrackContext(
            title: "Moon (feat. Bon Iver)",
            artist: "Daniel Caesar",
            album: "Son Of Spergy",
            duration: 317.043
        )

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "NetEase",
            score: 28.1,
            lineCount: 19,
            isUnsynced: false,
            hadSourceTranslation: true,
            translationLineCount: 18,
            translatableLineCount: 18,
            missingTranslationLineCount: 0,
            translationDisplayRequested: true
        )

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
    }

    func testManualReportExportsInspectableBundle() throws {
        let track = DiagnosticTrackContext(
            title: "Reported Song",
            artist: "Reported Artist",
            album: "Reported Album",
            duration: 180,
            persistentID: "123",
            playbackTime: 42
        )

        let url = try DiagnosticsService.shared.recordManualReport(
            symptom: .wrongLyrics,
            note: "Selected source appears to be a different song.",
            track: track
        )

        let requiredArtifacts = [
            "report.json",
            "summary.md",
            "performance_samples.csv",
            "lyrics_line_motion_samples.csv",
            "debug_log_status.txt"
        ]
        for artifact in requiredArtifacts {
            let artifactURL = url.appendingPathComponent(artifact)
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path), artifact)
            XCTAssertFalse(try Data(contentsOf: artifactURL).isEmpty, artifact)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("nanopod_debug.log").path))
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.userSymptom, .wrongLyrics)
    }

    func testManualReportInfersMissingLyricsArtworkAndContext() throws {
        let lyricsTrack = DiagnosticTrackContext(
            title: "I Don't Belong Anywhere",
            artist: "Zitan Qi",
            album: "I Don't Belong Anywhere",
            duration: 333,
            persistentID: "65C30E3EB6270257",
            playbackTime: 12,
            trackClass: "URL track",
            playlistName: "Discovery Station",
            playbackContext: "radio-or-stream",
            playerPage: "lyrics"
        )

        let lyricsURL = try DiagnosticsService.shared.recordManualReport(
            symptom: .wrongLyrics,
            note: "missing lyrics",
            track: lyricsTrack
        )
        let lyricsReportData = try Data(contentsOf: lyricsURL.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lyricsReport = try decoder.decode(DiagnosticReportManifest.self, from: lyricsReportData)
        XCTAssertEqual(lyricsReport.userSymptom, .missingLyrics)
        XCTAssertEqual(lyricsReport.track?.trackClass, "URL track")
        XCTAssertEqual(lyricsReport.track?.playlistName, "Discovery Station")
        XCTAssertEqual(lyricsReport.track?.playbackContext, "radio-or-stream")
        XCTAssertEqual(lyricsReport.track?.playerPage, "lyrics")

        let summary = try String(contentsOf: lyricsURL.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertTrue(summary.contains("Music track class: URL track"))
        XCTAssertTrue(summary.contains("Playback context: radio-or-stream"))
        XCTAssertTrue(summary.contains("Current playlist: Discovery Station"))
        XCTAssertTrue(summary.contains("nanoPod page: lyrics"))

        DiagnosticsService.shared.clear()
        let artworkURL = try DiagnosticsService.shared.recordManualReport(
            symptom: .other,
            note: "missing artwork",
            track: lyricsTrack
        )
        let artworkReportData = try Data(contentsOf: artworkURL.appendingPathComponent("report.json"))
        let artworkReport = try decoder.decode(DiagnosticReportManifest.self, from: artworkReportData)
        XCTAssertEqual(artworkReport.userSymptom, .artworkMissing)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.title, "Manual report: missing artwork")

        XCTAssertEqual(
            DiagnosticUserSymptom.inferred(from: .other, note: "resolver mismatch, 找错歌词"),
            .lyricsResolverProblem
        )
        XCTAssertEqual(
            DiagnosticUserSymptom.inferred(from: .wrongLyrics, note: "切歌动画被打断，不完整"),
            .switchingAnimationInterrupted
        )
        XCTAssertEqual(
            DiagnosticUserSymptom.inferred(from: .other, note: "next track goes black / 黑屏"),
            .switchingBlackout
        )
        XCTAssertEqual(
            DiagnosticUserSymptom.inferred(from: .other, note: "radio playlist context 看不到"),
            .playbackContextWrong
        )
        XCTAssertEqual(
            DiagnosticUserSymptom.inferred(from: .other, note: "Script Bridge delay makes next track slow"),
            .scriptingBridgeDelay
        )
        XCTAssertEqual(
            DiagnosticUserSymptom.inferred(from: .other, note: "system translation doesn't translate to the target language Chinese"),
            .missingTranslation
        )
    }

    func testLyricLineMotionSamplesExportWithReportBundle() throws {
        let sample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Motion Song",
            trackArtist: "Motion Artist",
            lineIndex: 3,
            lineID: "line-3",
            lineStartTime: 12.0,
            lineEndTime: 15.0,
            playbackTime: 12.4,
            activeIndex: 3,
            displayIndex: 3,
            targetIndex: 3,
            renderedMinY: 120,
            renderedMidY: 138,
            renderedHeight: 36,
            targetMinY: 121,
            targetMidY: 139,
            targetErrorY: -1,
            observedInterLineDeltaY: 42,
            expectedInterLineDeltaY: 42,
            interLineDeltaErrorY: 0,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false
        )

        DiagnosticsService.shared.recordLyricsLineMotionSamples([sample])
        XCTAssertEqual(DiagnosticsService.shared.lyricLineMotionSampleCount, 1)
        let track = DiagnosticTrackContext(
            title: "Motion Song",
            artist: "Motion Artist",
            album: "Motion Album",
            duration: 180
        )
        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .lyricsTimingOff,
            userNote: "motion sample",
            track: track
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("lyrics_line_motion_samples.csv").path))
        let data = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: data)
        XCTAssertEqual(report.lyricLineMotionSamples.count, 1)
        XCTAssertEqual(report.lyricLineMotionSamples.first?.lineID, "line-3")
    }

    func testLiveMotionSnapshotUpdatesFromLineMotionSamplesAndFrameTicks() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.042, page: "lyrics")
        func sample(index: Int) -> DiagnosticLyricLineMotionSample {
            let isLaggedLine = index == 1
            let isFarFieldLag = index == 8
            return DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Motion Song",
                trackArtist: "Motion Artist",
                lineIndex: index,
                lineID: "line-\(index)",
                lineStartTime: Double(index),
                lineEndTime: Double(index + 1),
                playbackTime: 2.4,
                activeIndex: 2,
                displayIndex: 2,
                targetIndex: isLaggedLine || isFarFieldLag ? 1 : 2,
                renderedMinY: Double(index * 50),
                renderedMidY: Double(index * 50 + 18),
                renderedHeight: 36,
                targetMinY: Double(index * 50),
                targetMidY: Double(index * 50 + 18),
                targetErrorY: isLaggedLine ? 34 : 0,
                observedInterLineDeltaY: isLaggedLine ? nil : 50,
                expectedInterLineDeltaY: isLaggedLine ? nil : 50,
                interLineDeltaErrorY: isLaggedLine ? nil : 0,
                waveOffsetY: isLaggedLine ? 34 : 0,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        }
        let samples = [sample(index: 1), sample(index: 2), sample(index: 3), sample(index: 8)]

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples)

        let snapshot = DiagnosticsService.shared.liveMotionSnapshot
        XCTAssertEqual(snapshot?.trackTitle, "Motion Song")
        XCTAssertEqual(snapshot?.activeIndex, 2)
        XCTAssertEqual(snapshot?.displayIndex, 2)
        XCTAssertEqual(snapshot?.targetIndex, 2)
        XCTAssertEqual(snapshot?.sampleCount, 4)
        XCTAssertEqual(snapshot?.capturedFirstLineIndex, 1)
        XCTAssertEqual(snapshot?.capturedLastLineIndex, 8)
        XCTAssertEqual(snapshot?.maxTargetErrorY ?? -1, 34, accuracy: 0.001)
        XCTAssertEqual(snapshot?.latestFrameDeltaMs ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(snapshot?.fieldTargetMismatchCount, 2)
        XCTAssertEqual(snapshot?.maxFieldTargetDistance, 1)
        XCTAssertEqual(snapshot?.wavePropagationLineCount, 1)
    }

    func testLiveMotionSnapshotRecordsCaptureMisses() {
        let track = DiagnosticTrackContext(
            title: "Motion Song",
            artist: "Motion Artist",
            album: "Motion Album",
            duration: 180
        )

        DiagnosticsService.shared.recordLyricsLineMotionCaptureMiss(
            track: track,
            playbackTime: 42.5,
            lyricLineCount: 18,
            displayLineCount: 22,
            displayIndex: 7,
            monitoringEnabled: true
        )

        let snapshot = DiagnosticsService.shared.liveMotionSnapshot
        XCTAssertEqual(snapshot?.captureMissCount, 1)
        XCTAssertEqual(snapshot?.captureMissDisplayLineCount, 22)
        XCTAssertEqual(snapshot?.captureMissMonitoringEnabled, true)
        XCTAssertEqual(snapshot?.displayIndex, 7)
        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "diagnostics.lyricsLineMotionCaptureMissed" })
    }

    func testLiveLyricLineMotionCSVWritesSingleHeaderAcrossBatches() throws {
        func sample(lineID: String, lineIndex: Int) -> DiagnosticLyricLineMotionSample {
            return DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Live Motion Song",
                trackArtist: "Live Motion Artist",
                lineIndex: lineIndex,
                lineID: lineID,
                lineStartTime: Double(lineIndex),
                lineEndTime: Double(lineIndex + 1),
                playbackTime: Double(lineIndex),
                activeIndex: lineIndex,
                displayIndex: lineIndex,
                targetIndex: lineIndex,
                renderedMinY: Double(lineIndex * 50),
                renderedMidY: Double(lineIndex * 50 + 22),
                renderedHeight: 44,
                targetMinY: Double(lineIndex * 50),
                targetMidY: Double(lineIndex * 50 + 22),
                targetErrorY: 0,
                observedInterLineDeltaY: nil,
                expectedInterLineDeltaY: nil,
                interLineDeltaErrorY: nil,
                waveOffsetY: 0,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples([sample(lineID: "line-a", lineIndex: 1)])
        DiagnosticsService.shared.recordLyricsLineMotionSamples([sample(lineID: "line-b", lineIndex: 2)])

        let liveURL = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
            .appendingPathComponent("lyrics_line_motion_samples.csv")
        let deadline = Date().addingTimeInterval(2)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: liveURL, encoding: .utf8)) ?? ""
            if text.contains("line-a"), text.contains("line-b") {
                break
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(text.contains("line-a"))
        XCTAssertTrue(text.contains("line-b"))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("timestamp,page") }.count, 1)
    }

    func testLiveLyricWaveTimelineCSVWritesAllRowScheduleAndFireEvents() throws {
        UserDefaults.standard.set(true, forKey: DiagnosticsService.lyricWaveTimelineEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: DiagnosticsService.lyricWaveTimelineEnabledKey) }

        let scheduled = DiagnosticLyricWaveTimelineSample(
            page: "lyrics",
            trackTitle: "Wave Song",
            trackArtist: "Wave Artist",
            waveID: 42,
            phase: "scheduled",
            lineIndex: 7,
            oldIndex: 6,
            newIndex: 8,
            displayIndex: 8,
            scheduledDelay: 0.08,
            actualDelay: 0,
            lineInterval: 1.2,
            targetRadius: 14,
            scheduleCount: 25,
            renderedCount: 25,
            isActiveLine: false
        )
        let fired = DiagnosticLyricWaveTimelineSample(
            page: "lyrics",
            trackTitle: "Wave Song",
            trackArtist: "Wave Artist",
            waveID: 42,
            phase: "fired",
            lineIndex: 8,
            oldIndex: 6,
            newIndex: 8,
            displayIndex: 8,
            scheduledDelay: 0.16,
            actualDelay: 0.19,
            lineInterval: 1.2,
            targetRadius: 14,
            scheduleCount: 25,
            renderedCount: 25,
            isActiveLine: true
        )

        DiagnosticsService.shared.recordLyricsWaveTimelineSamples([scheduled, fired])

        let liveURL = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
            .appendingPathComponent("lyrics_wave_timeline.csv")
        let deadline = Date().addingTimeInterval(2)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: liveURL, encoding: .utf8)) ?? ""
            if text.contains("scheduled"), text.contains("fired") {
                break
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(text.contains("Wave Song"))
        XCTAssertTrue(text.contains("scheduled"))
        XCTAssertTrue(text.contains("fired"))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("timestamp,page") }.count, 1)
    }

    func testLiveLyricLineMotionCSVRepairsExistingDuplicateHeadersOnSessionStart() throws {
        let liveURL = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
            .appendingPathComponent("lyrics_line_motion_samples.csv")
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "timestamp,page,trackTitle,trackArtist,lineIndex,lineID,lineStartTime,lineEndTime,playbackTime,activeIndex,displayIndex,targetIndex,renderedMinY,renderedMidY,renderedHeight,targetMinY,targetMidY,targetErrorY,velocityY,observedInterLineDeltaY,expectedInterLineDeltaY,interLineDeltaErrorY,waveOffsetY,manualScrollOffsetY,isManualScrolling,isInitialMotionSuppressed"
        let rowA = "2026-05-20T03:00:00Z,\"lyrics\",\"Old Song\",\"Old Artist\",1,\"old-a\",1.0000,2.0000,1.5000,1,1,1,10.0000,20.0000,20.0000,10.0000,20.0000,0.0000,,40.0000,40.0000,0.0000,0.0000,0.0000,0,0"
        let rowB = "2026-05-20T03:00:01Z,\"lyrics\",\"Old Song\",\"Old Artist\",2,\"old-b\",2.0000,3.0000,2.5000,2,2,2,50.0000,60.0000,20.0000,50.0000,60.0000,0.0000,,40.0000,40.0000,0.0000,0.0000,0.0000,0,0"
        try [header, rowA, header, rowB, header].joined(separator: "\n").write(
            to: liveURL,
            atomically: true,
            encoding: .utf8
        )

        DiagnosticsService.shared.isEnabled = false
        DiagnosticsService.shared.isEnabled = true

        let deadline = Date().addingTimeInterval(2)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: liveURL, encoding: .utf8)) ?? ""
            if text.components(separatedBy: "\n").filter({ $0.hasPrefix("timestamp,page") }).count == 1 {
                break
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(text.contains("old-a"))
        XCTAssertTrue(text.contains("old-b"))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("timestamp,page") }.count, 1)
    }

    func testReportBundleScopesTrackSpecificMotionEvidence() throws {
        let staleSample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Old Song",
            trackArtist: "Old Artist",
            lineIndex: 4,
            lineID: "old-line",
            lineStartTime: 10.0,
            lineEndTime: 12.0,
            playbackTime: 10.8,
            activeIndex: 4,
            displayIndex: 4,
            targetIndex: 4,
            renderedMinY: 220,
            renderedMidY: 238,
            renderedHeight: 36,
            targetMinY: 140,
            targetMidY: 158,
            targetErrorY: 80,
            observedInterLineDeltaY: 90,
            expectedInterLineDeltaY: 42,
            interLineDeltaErrorY: 48,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false
        )
        let currentSample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Current Song",
            trackArtist: "Current Artist",
            lineIndex: 1,
            lineID: "current-line",
            lineStartTime: 2.0,
            lineEndTime: 5.0,
            playbackTime: 2.5,
            activeIndex: 1,
            displayIndex: 1,
            targetIndex: 1,
            renderedMinY: 120,
            renderedMidY: 138,
            renderedHeight: 36,
            targetMinY: 120,
            targetMidY: 138,
            targetErrorY: 0,
            observedInterLineDeltaY: nil,
            expectedInterLineDeltaY: nil,
            interLineDeltaErrorY: nil,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false
        )

        DiagnosticsService.shared.recordLyricsLineMotionSamples([staleSample])
        DiagnosticsService.shared.recordLyricsLineMotionSamples([currentSample])

        let track = DiagnosticTrackContext(
            title: "Current Song",
            artist: "Current Artist",
            album: "Current Album",
            duration: 180
        )
        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .staleLyrics,
            userNote: "scope report",
            track: track
        )

        let data = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: data)

        XCTAssertEqual(report.lyricLineMotionSamples.map(\.trackTitle), ["Current Song"])
        XCTAssertEqual(report.baseline["lyrics.lineMotion.targetError.pt"] ?? -1, 0, accuracy: 0.001)
        XCTAssertFalse(report.incidents.contains { $0.evidence["track"] == "Old Song / Old Artist" })
        XCTAssertFalse(report.incidents.contains { $0.track?.title == "Old Song" })
    }

    func testMotionReportFallsBackToRecentLyricsLineMotionWhenTrackSwitched() throws {
        let previousTrackSample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Previous Song",
            trackArtist: "Previous Artist",
            lineIndex: 8,
            lineID: "previous-line",
            lineStartTime: 30.0,
            lineEndTime: 33.0,
            playbackTime: 31.2,
            activeIndex: 8,
            displayIndex: 8,
            targetIndex: 7,
            renderedMinY: 260,
            renderedMidY: 278,
            renderedHeight: 36,
            targetMinY: 190,
            targetMidY: 208,
            targetErrorY: 70,
            observedInterLineDeltaY: 88,
            expectedInterLineDeltaY: 42,
            interLineDeltaErrorY: 46,
            waveOffsetY: 18,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false
        )
        DiagnosticsService.shared.recordLyricsLineMotionSamples([previousTrackSample])

        let currentTrack = DiagnosticTrackContext(
            title: "Current Song",
            artist: "Current Artist",
            album: "Current Album",
            duration: 180
        )
        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "next track animation stuck while switching lyrics",
            track: currentTrack
        )

        let data = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: data)

        XCTAssertEqual(report.lyricLineMotionSamples.map(\.lineID), ["previous-line"])
        XCTAssertTrue(report.events.contains { $0.name == "diagnostics.lyricsLineMotionTimeScopedFallback" })
        XCTAssertEqual(report.baseline["lyrics.lineMotion.targetError.pt"] ?? -1, 70, accuracy: 0.001)
    }

    func testNonMotionReportDoesNotFallbackToOtherTrackLineMotion() throws {
        let previousTrackSample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Previous Song",
            trackArtist: "Previous Artist",
            lineIndex: 8,
            lineID: "previous-line",
            lineStartTime: 30.0,
            lineEndTime: 33.0,
            playbackTime: 31.2,
            activeIndex: 8,
            displayIndex: 8,
            targetIndex: 7,
            renderedMinY: 260,
            renderedMidY: 278,
            renderedHeight: 36,
            targetMinY: 190,
            targetMidY: 208,
            targetErrorY: 70,
            observedInterLineDeltaY: 88,
            expectedInterLineDeltaY: 42,
            interLineDeltaErrorY: 46,
            waveOffsetY: 18,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false
        )
        DiagnosticsService.shared.recordLyricsLineMotionSamples([previousTrackSample])

        let currentTrack = DiagnosticTrackContext(
            title: "Current Song",
            artist: "Current Artist",
            album: "Current Album",
            duration: 180
        )
        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .wrongLyrics,
            userNote: "wrong lyric content",
            track: currentTrack
        )

        let data = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: data)

        XCTAssertTrue(report.lyricLineMotionSamples.isEmpty)
        XCTAssertFalse(report.events.contains { $0.name == "diagnostics.lyricsLineMotionTimeScopedFallback" })
    }

    func testNoSourceLyricsMissStaysEventUntilAuthoritativeClassification() {
        let track = DiagnosticTrackContext(
            title: "Missing Song",
            artist: "Missing Artist",
            album: "Missing Album",
            duration: 200
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 0)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })
        let unresolvedEvent = DiagnosticsService.shared.events.first { $0.name == "lyrics.fetch.unresolved" }
        XCTAssertEqual(unresolvedEvent?.track, track)
        XCTAssertEqual(unresolvedEvent?.metrics["resultCount"] ?? -1, 0, accuracy: 0.001)

        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 0)
        XCTAssertEqual(DiagnosticsService.shared.incidents.filter { $0.category == .lyricsMissing }.count, 0)
        XCTAssertEqual(DiagnosticsService.shared.events.filter { $0.name == "lyrics.fetch.unresolved" }.count, 2)

        DiagnosticsService.shared.clear()
        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 2)

        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.category, .lyricsMissing)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.severity, .warning)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.evidence["result"], "miss")
    }

    func testLowConfidenceResultAfterRejectedCandidateMissDoesNotDuplicateFallbackIncident() {
        let track = DiagnosticTrackContext(
            title: "Nan Chun",
            artist: "SE SO NEON",
            album: "Nan Chun - Single",
            duration: 229.493
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 2)
        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "LRCLIB-Search",
            score: 22.6,
            lineCount: 21,
            isUnsynced: false,
            hadSourceTranslation: false
        )

        let missingIncidents = DiagnosticsService.shared.incidents.filter { $0.category == .lyricsMissing }
        XCTAssertEqual(missingIncidents.count, 1)
        XCTAssertEqual(missingIncidents.first?.evidence["result"], "miss")
        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "lyrics.fetch.lowConfidenceAfterMiss" })
    }

    func testTrustedLyricsResultClearsEarlierRejectedCandidateMiss() {
        let track = DiagnosticTrackContext(
            title: "Lovers",
            artist: "Naiwen Yang",
            album: "Centrifugal Force",
            duration: 326.007
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 1)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.category, .lyricsMissing)

        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "NetEase",
            score: 84.4,
            lineCount: 31,
            isUnsynced: false,
            hadSourceTranslation: false
        )

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })
        let resolvedEvent = DiagnosticsService.shared.events.first { $0.name == "lyrics.fetch.resolvedAfterMiss" }
        XCTAssertEqual(resolvedEvent?.track, track)
        XCTAssertEqual(resolvedEvent?.metrics["clearedFallbackIncidentCount"] ?? -1, 1, accuracy: 0.001)
    }

    func testAuthoritativeUnavailableRecordsEventForNoSourceLyrics() {
        let track = DiagnosticTrackContext(
            title: "By the Time I Get to Phoenix",
            artist: "Dorothy Ashby",
            album: "Dorothy's Harp",
            duration: 210.186
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 0)
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })

        DiagnosticsService.shared.recordLyricsFetchUnavailable(track: track, classification: "unavailable")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })
        let event = DiagnosticsService.shared.events.first { $0.name == "lyrics.fetch.unavailable" }
        XCTAssertEqual(event?.track, track)
        XCTAssertEqual(event?.metrics["clearedUnresolvedIncidentCount"] ?? -1, 0, accuracy: 0.001)
    }

    func testFastSingleCandidateLyricsMissStaysPendingForAuthoritativeClassification() {
        let track = DiagnosticTrackContext(
            title: "Long Ago and Far Away",
            artist: "Earl Klugh",
            album: "Finger Paintings",
            duration: 337.399
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 1, terminalCandidateOnly: true)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })
        let pendingEvent = DiagnosticsService.shared.events.first { $0.name == "lyrics.fetch.terminalMissPendingBackfill" }
        XCTAssertEqual(pendingEvent?.track, track)

        DiagnosticsService.shared.recordLyricsFetchUnavailable(track: track, classification: "unavailable")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })
        XCTAssertNotNil(DiagnosticsService.shared.events.first { $0.name == "lyrics.fetch.unavailable" })
    }

    func testAuthoritativeUnavailableDoesNotClearRejectedCandidateMiss() {
        let track = DiagnosticTrackContext(
            title: "Rejected Candidate Song",
            artist: "Diagnostics",
            album: "Fixture",
            duration: 200
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 2)
        DiagnosticsService.shared.recordLyricsFetchUnavailable(track: track, classification: "unavailable")

        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.category, .lyricsMissing)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.evidence["result"], "miss")
    }

    func testAuthoritativeInstrumentalClearsRejectedCandidateMiss() {
        let track = DiagnosticTrackContext(
            title: "Memento",
            artist: "Resavoir & Matt Gold",
            album: "Horizon",
            duration: 227.714
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 1)
        DiagnosticsService.shared.recordLyricsFetchUnavailable(track: track, classification: "instrumental")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsFallbackChurn })
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsMissing })
        let event = DiagnosticsService.shared.events.first { $0.name == "lyrics.fetch.unavailable" }
        XCTAssertEqual(event?.metrics["clearedUnresolvedIncidentCount"] ?? -1, 1, accuracy: 0.001)
    }

    func testDebugLogAttachmentIsSessionScoped() {
        XCTAssertFalse(DiagnosticsService.shared.shouldAttachDebugLog(modifiedAt: Date().addingTimeInterval(-10)))
        XCTAssertTrue(DiagnosticsService.shared.shouldAttachDebugLog(modifiedAt: Date()))
    }

    func testCurrentSessionDebugLogIsAttachedToReportBundle() throws {
        DebugLogger.log("diagnostics attachment test")

        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "current debug log",
            track: nil
        )

        let attachedLog = url.appendingPathComponent("nanopod_debug.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachedLog.path))
        XCTAssertTrue(try String(contentsOf: attachedLog, encoding: .utf8).contains("diagnostics attachment test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("debug_log_status.txt").path))
    }

    func testStaleDebugLogIsNotAttachedToReportBundle() throws {
        let debugLogURL = try XCTUnwrap(diagnosticsStorageRoot?.appendingPathComponent("nanopod_debug.log"))
        try "stale diagnostics log\n".write(to: debugLogURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: debugLogURL.path
        )

        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "stale debug log",
            track: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("nanopod_debug.log").path))
        let status = try String(contentsOf: url.appendingPathComponent("debug_log_status.txt"), encoding: .utf8)
        XCTAssertTrue(status.contains("No current-session nanoPod debug log"))
        XCTAssertFalse(status.contains("stale diagnostics log"))
    }

    func testDefaultDebugLogAttachmentIgnoresUnscopedCurrentLog() throws {
        DiagnosticsService.shared.setDebugLogURLForTesting(nil)
        let root = try XCTUnwrap(diagnosticsStorageRoot)
        let unscopedLogURL = root.appendingPathComponent("nanopod_debug.log")
        try "cli verifier contamination\n".write(to: unscopedLogURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: unscopedLogURL.path)

        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "unscoped debug log",
            track: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("nanopod_debug.log").path))
        let status = try String(contentsOf: url.appendingPathComponent("debug_log_status.txt"), encoding: .utf8)
        XCTAssertTrue(status.contains("No current-session nanoPod debug log"))
        XCTAssertFalse(status.contains("cli verifier contamination"))
    }

    func testDefaultDebugLogAttachmentUsesScopedLiveLog() throws {
        DiagnosticsService.shared.setDebugLogURLForTesting(nil)
        let root = try XCTUnwrap(diagnosticsStorageRoot)
        let liveDir = root
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let liveLogURL = liveDir.appendingPathComponent("nanopod_debug.log")
        try "current scoped diagnostics log\n".write(to: liveLogURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: liveLogURL.path)

        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "scoped debug log",
            track: nil
        )

        let attachedLog = url.appendingPathComponent("nanopod_debug.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachedLog.path))
        XCTAssertEqual(try String(contentsOf: attachedLog, encoding: .utf8), "current scoped diagnostics log\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("debug_log_status.txt").path))
    }

    func testRollingDiagnosticsSnapshotRestoresAfterSimulatedRestart() throws {
        let track = DiagnosticTrackContext(
            title: "Persistent Song",
            artist: "Persistent Artist",
            album: "Persistent Album",
            duration: 180
        )

        DiagnosticsService.shared.recordEvent(
            "test.marker",
            detail: "persist me",
            track: track,
            metrics: ["marker": 1]
        )
        let interaction = DiagnosticsService.shared.beginInteraction(
            type: .pageSwitch,
            page: "lyrics",
            expectedDuration: 0.35,
            track: track
        )
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.completeInteraction(interaction)
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.flushPersistenceForTesting()

        XCTAssertTrue(DiagnosticsService.shared.persistedSnapshotExistsForTesting())

        DiagnosticsService.shared.simulateProcessRestartForTesting()

        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "test.marker" })
        XCTAssertTrue(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
        XCTAssertTrue(DiagnosticsService.shared.interactions.contains {
            $0.type == .pageSwitch && $0.track?.title == "Persistent Song"
        })

        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "after restart",
            track: track
        )
        let data = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: data)

        XCTAssertEqual(report.track?.title, "Persistent Song")
        XCTAssertTrue(report.events.contains { $0.name == "test.marker" })
        XCTAssertTrue((report.baseline["frame.delta.ms"] ?? 0) > 0)
    }

    func testRestoredStandaloneFrameStallSpamIsCoalesced() throws {
        struct EmptyRunningStat: Encodable {}
        struct TestSnapshot: Encodable {
            var schemaVersion = 1
            let savedAt: Date
            let sessionID: UUID
            let sessionStartedAt: Date
            let appBuildSignature: String?
            let incidents: [DiagnosticIncident]
            var events: [DiagnosticEvent] = []
            var interactions: [DiagnosticInteractionTrace] = []
            var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample] = []
            var baselineStats: [String: EmptyRunningStat] = [:]
            var lastWarning: DiagnosticIncident? = nil
            var lastExportPath: String? = nil
        }
        struct RestoredSnapshot: Decodable {
            let incidents: [DiagnosticIncident]
        }

        let base = Date(timeIntervalSince1970: 1_800_000_050)
        let incidents = (0..<10).map { index in
            DiagnosticIncident(
                timestamp: base.addingTimeInterval(-Double(index)),
                category: .uiFrameStall,
                severity: index == 4 ? .critical : .warning,
                title: "UI frame stall",
                detail: "lyrics frame interval reached 180ms.",
                automaticallyDetected: true,
                metrics: ["deltaMs": index == 4 ? 340 : 180],
                evidence: ["page": "lyrics"]
            )
        }
        let legacyHighCPU = DiagnosticIncident(
            timestamp: base.addingTimeInterval(-30),
            category: .highCPU,
            severity: .warning,
            title: "High CPU detected",
            detail: "Process CPU reached 119%.",
            automaticallyDetected: true,
            metrics: ["cpuPercent": 3.6, "rssMB": 365],
            evidence: [:]
        )
        let motionTrack = DiagnosticTrackContext(
            title: "Motion Spam Song",
            artist: "Motion Spam Artist",
            album: "",
            duration: 180
        )
        var lineMotionIncidents: [DiagnosticIncident] = []
        for index in 0..<5 {
            let metrics: [String: Double] = [
                "maxTargetErrorPt": Double(40 + index),
                "maxInterLineErrorPt": Double(12 + index),
                "laggedNearbyTargetCount": Double(index)
            ]
            lineMotionIncidents.append(DiagnosticIncident(
                timestamp: base.addingTimeInterval(-Double(40 + index)),
                category: .lyricsLineMotion,
                severity: index == 2 ? .critical : .warning,
                title: "Lyrics line motion drift",
                detail: "Rendered lyric lines diverged from their target motion during playback.",
                automaticallyDetected: true,
                track: motionTrack,
                metrics: metrics,
                evidence: ["track": "Motion Spam Song / Motion Spam Artist"]
            ))
        }
        let memoryIncidents = (0..<6).map { index in
            DiagnosticIncident(
                timestamp: base.addingTimeInterval(-Double(70 + index * 5)),
                category: .memorySpike,
                severity: .warning,
                title: "Memory spike detected",
                detail: "Resident memory reached \(650 + index) MB.",
                automaticallyDetected: true,
                metrics: ["rssMB": Double(650 + index), "cpuPercent": Double(10 + index)],
                evidence: [:]
            )
        }

        let snapshot = TestSnapshot(
            savedAt: base,
            sessionID: UUID(),
            sessionStartedAt: base.addingTimeInterval(-300),
            appBuildSignature: DiagnosticsService.shared.currentAppBuildSignatureForTesting(),
            incidents: [legacyHighCPU] + memoryIncidents + lineMotionIncidents + incidents,
            lastWarning: incidents[0]
        )
        let snapshotURL = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("State", isDirectory: true)
            .appendingPathComponent("rolling_state.json")
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotURL)

        DiagnosticsService.shared.simulateProcessRestartForTesting()

        let frameStalls = DiagnosticsService.shared.incidents.filter { $0.category == .uiFrameStall }
        XCTAssertEqual(frameStalls.count, 1)
        XCTAssertEqual(frameStalls.first?.title, "UI frame stall burst")
        XCTAssertEqual(frameStalls.first?.severity, .critical)
        XCTAssertEqual(frameStalls.first?.metrics["occurrenceCount"], 10)
        XCTAssertEqual(frameStalls.first?.metrics["maxDeltaMs"] ?? -1, 340, accuracy: 0.001)
        XCTAssertEqual(frameStalls.first?.evidence["signature"], "uiFrameStall|lyrics|30000000")

        let highCPU = try XCTUnwrap(DiagnosticsService.shared.incidents.first { $0.category == .highCPU })
        XCTAssertEqual(highCPU.metrics["cpuPercent"] ?? -1, 119, accuracy: 0.001)
        XCTAssertEqual(highCPU.metrics["maxRecentCPUPercent"] ?? -1, 119, accuracy: 0.001)
        XCTAssertEqual(highCPU.metrics["currentCPUPercent"] ?? -1, 3.6, accuracy: 0.001)

        let lineMotion = DiagnosticsService.shared.incidents.filter { $0.category == .lyricsLineMotion }
        XCTAssertEqual(lineMotion.count, 1)
        XCTAssertEqual(lineMotion.first?.title, "Lyrics line motion drift burst")
        XCTAssertEqual(lineMotion.first?.severity, .critical)
        XCTAssertEqual(lineMotion.first?.metrics["occurrenceCount"], 5)
        XCTAssertEqual(lineMotion.first?.metrics["maxTargetErrorPt"] ?? -1, 44, accuracy: 0.001)
        XCTAssertEqual(lineMotion.first?.metrics["maxInterLineErrorPt"] ?? -1, 16, accuracy: 0.001)

        let memory = DiagnosticsService.shared.incidents.filter { $0.category == .memorySpike }
        XCTAssertEqual(memory.count, 1)
        XCTAssertEqual(memory.first?.title, "Memory pressure burst")
        XCTAssertEqual(memory.first?.metrics["occurrenceCount"], 6)
        XCTAssertEqual(memory.first?.metrics["maxRSSMB"] ?? -1, 655, accuracy: 0.001)

        let warning = try XCTUnwrap(DiagnosticsService.shared.lastWarning)
        XCTAssertEqual(warning.id, frameStalls.first?.id)
        XCTAssertEqual(warning.title, "UI frame stall burst")
        XCTAssertEqual(warning.metrics["occurrenceCount"], 10)

        DiagnosticsService.shared.flushPersistenceForTesting()
        let restoredData = try Data(contentsOf: snapshotURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restoredSnapshot = try decoder.decode(RestoredSnapshot.self, from: restoredData)
        XCTAssertEqual(restoredSnapshot.incidents.filter { $0.category == .lyricsLineMotion }.count, 1)
        XCTAssertEqual(restoredSnapshot.incidents.filter { $0.category == .uiFrameStall }.count, 1)
        XCTAssertEqual(restoredSnapshot.incidents.filter { $0.category == .memorySpike }.count, 1)
    }

    func testRoutineDebugRSSDoesNotCreateMemorySpikeIncident() {
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 20, rss: 650)
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 22, rss: 660)
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 18, rss: 670)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .memorySpike })
    }

    func testHighRSSWithModestPhysicalFootprintDoesNotCreateMemorySpikeIncident() {
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 20, rss: 920, physicalFootprint: 320)
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 22, rss: 940, physicalFootprint: 335)
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 18, rss: 950, physicalFootprint: 340)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .memorySpike })
        let samples = DiagnosticsService.shared.events.filter { $0.name == "process.health.sample" }
        XCTAssertEqual(samples.first?.metrics["rssMB"], 950)
        XCTAssertEqual(samples.first?.metrics["physicalFootprintMB"], 340)
    }

    func testElevatedMemorySamplesCoalesceIntoBurst() throws {
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 12, rss: 340)
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 18, rss: 690)
        DiagnosticsService.shared.recordProcessHealthSampleForTesting(cpu: 21, rss: 705)

        let memory = DiagnosticsService.shared.incidents.filter { $0.category == .memorySpike }
        XCTAssertEqual(memory.count, 1)
        let burst = try XCTUnwrap(memory.first)
        XCTAssertEqual(burst.title, "Memory pressure burst")
        XCTAssertEqual(burst.metrics["occurrenceCount"], 2)
        XCTAssertEqual(burst.metrics["maxRSSMB"] ?? -1, 705, accuracy: 0.001)
        XCTAssertEqual(burst.metrics["maxMemoryGrowthMB"] ?? -1, 365, accuracy: 0.001)
    }

    func testClearRemovesPersistedDiagnosticsSnapshotAndLiveMotionCSV() throws {
        DiagnosticsService.shared.recordEvent("test.marker", detail: "persist me")
        DiagnosticsService.shared.recordLyricsLineMotionSamples([
            DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Clear Song",
                trackArtist: "Clear Artist",
                lineIndex: 1,
                lineID: "clear-line",
                lineStartTime: 1,
                lineEndTime: 2,
                playbackTime: 1.5,
                activeIndex: 1,
                displayIndex: 1,
                targetIndex: 1,
                renderedMinY: 10,
                renderedMidY: 20,
                renderedHeight: 20,
                targetMinY: 10,
                targetMidY: 20,
                targetErrorY: 0,
                observedInterLineDeltaY: nil,
                expectedInterLineDeltaY: nil,
                interLineDeltaErrorY: nil,
                waveOffsetY: 0,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        ])
        DiagnosticsService.shared.flushPersistenceForTesting()
        XCTAssertTrue(DiagnosticsService.shared.persistedSnapshotExistsForTesting())

        let liveURL = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
            .appendingPathComponent("lyrics_line_motion_samples.csv")
        let writeDeadline = Date().addingTimeInterval(2)
        while Date() < writeDeadline {
            let text = (try? String(contentsOf: liveURL, encoding: .utf8)) ?? ""
            if text.contains("clear-line") { break }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveURL.path))

        DiagnosticsService.shared.clear()

        let clearDeadline = Date().addingTimeInterval(2)
        while Date() < clearDeadline,
              FileManager.default.fileExists(atPath: liveURL.path) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(DiagnosticsService.shared.persistedSnapshotExistsForTesting())
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveURL.path))
        DiagnosticsService.shared.simulateProcessRestartForTesting()
        XCTAssertTrue(DiagnosticsService.shared.events.isEmpty)
        XCTAssertTrue(DiagnosticsService.shared.incidents.isEmpty)
    }

    func testClearCanSuppressImmediateStandaloneFrameStallNoise() {
        DiagnosticsService.shared.clear(suppressImmediateStandaloneFrameStalls: true)

        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "album")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
    }

    func testSessionStartSuppressesStartupStandaloneFrameStallNoise() {
        DiagnosticsService.shared.clear()
        DiagnosticsService.shared.isEnabled = false
        DiagnosticsService.shared.isEnabled = true

        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "album")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "diagnostics.session.start" })
    }

    func testBuildSignatureMismatchRemovesStaleLiveMotionCSV() throws {
        struct EmptyRunningStat: Encodable {
            var count = 0
            var total = 0.0
            var max = 0.0
        }
        struct TestSnapshot: Encodable {
            var schemaVersion = 1
            let savedAt: Date
            let sessionID: UUID
            let sessionStartedAt: Date
            let appBuildSignature: String?
            var incidents: [DiagnosticIncident] = []
            var events: [DiagnosticEvent] = []
            var interactions: [DiagnosticInteractionTrace] = []
            var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample] = []
            var baselineStats: [String: EmptyRunningStat] = [:]
            var lastWarning: DiagnosticIncident? = nil
            var lastExportPath: String? = nil
        }

        let root = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        let stateURL = root
            .appendingPathComponent("State", isDirectory: true)
            .appendingPathComponent("rolling_state.json")
        let liveURL = root
            .appendingPathComponent("Live", isDirectory: true)
            .appendingPathComponent("lyrics_line_motion_samples.csv")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let snapshot = TestSnapshot(
            savedAt: Date(),
            sessionID: UUID(),
            sessionStartedAt: Date().addingTimeInterval(-60),
            appBuildSignature: "old-build"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: stateURL)
        try "timestamp,page,trackTitle\n2026-05-20T00:00:00Z,lyrics,Old\n".write(
            to: liveURL,
            atomically: true,
            encoding: .utf8
        )

        DiagnosticsService.shared.simulateProcessRestartForTesting()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              FileManager.default.fileExists(atPath: liveURL.path) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveURL.path))
        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "diagnostics.session.resetForBuild" })
    }

    func testTerminationFlushPersistsActiveInteractionAsInterrupted() {
        let track = DiagnosticTrackContext(
            title: "Shutdown Song",
            artist: "Shutdown Artist",
            album: "Shutdown Album",
            duration: 180
        )
        _ = DiagnosticsService.shared.beginInteraction(
            type: .pageSwitch,
            page: "lyrics",
            expectedDuration: 0.35,
            track: track
        )

        DiagnosticsService.shared.prepareForTermination()
        DiagnosticsService.shared.simulateProcessRestartForTesting()

        let trace = DiagnosticsService.shared.interactions.first
        XCTAssertEqual(trace?.type, .pageSwitch)
        XCTAssertEqual(trace?.status, .interrupted)
        XCTAssertEqual(trace?.evidence["shutdownFlush"], "true")
        XCTAssertEqual(trace?.track?.title, "Shutdown Song")
    }

    func testLyricLineMotionDriftCreatesIncident() {
        let sample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Motion Song",
            trackArtist: "Motion Artist",
            lineIndex: 4,
            lineID: "line-4",
            lineStartTime: 10.0,
            lineEndTime: 12.0,
            playbackTime: 10.8,
            activeIndex: 4,
            displayIndex: 4,
            targetIndex: 4,
            renderedMinY: 190,
            renderedMidY: 208,
            renderedHeight: 36,
            targetMinY: 140,
            targetMidY: 158,
            targetErrorY: 50,
            observedInterLineDeltaY: 88,
            expectedInterLineDeltaY: 42,
            interLineDeltaErrorY: 46,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false
        )

        DiagnosticsService.shared.recordLyricsLineMotionSamples([sample])

        XCTAssertTrue(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })
    }

    func testUnevenLyricLineSpacingCreatesMotionIncidentMetric() {
        func sample(index: Int) -> DiagnosticLyricLineMotionSample {
            let baseY = Double(index) * 64
            let shifted = index >= 2
            let shift = shifted ? 120.0 : 0.0
            let observedDelta: Double? = index == 0 ? nil : (index == 2 ? 184.0 : 64.0)
            let spacingError: Double? = index == 0 ? nil : (index == 2 ? 120.0 : 0.0)
            return DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Dense Motion Song",
                trackArtist: "Motion Artist",
                lineIndex: index,
                lineID: "dense-\(index)",
                lineStartTime: Double(index) * 0.85,
                lineEndTime: Double(index) * 0.85 + 0.7,
                playbackTime: 1.8,
                activeIndex: 2,
                displayIndex: 2,
                targetIndex: index == 2 ? 2 : 8,
                renderedMinY: baseY + shift,
                renderedMidY: baseY + 22 + shift,
                renderedHeight: 44,
                targetMinY: baseY,
                targetMidY: baseY + 22,
                targetErrorY: shift,
                observedInterLineDeltaY: observedDelta,
                expectedInterLineDeltaY: index == 0 ? nil : 64,
                interLineDeltaErrorY: spacingError,
                waveOffsetY: shift,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        }
        let samples = (0..<5).map(sample)

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples)

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .lyricsLineMotion }
        XCTAssertEqual(incident?.metrics["unevenLineSpacing"], 1)
        XCTAssertEqual(incident?.metrics["maxInterLineErrorPt"] ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(incident?.metrics["maxAbnormalInterLineErrorPt"] ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(incident?.evidence["spacingMetric"], "interLineDeltaErrorY")
    }

    func testSingleStepWaveSpacingDoesNotCreateMotionIncident() {
        func sample(index: Int) -> DiagnosticLyricLineMotionSample {
            let baseY = Double(index) * 50
            let isTrailingWaveLine = index == 3
            let waveOffset = isTrailingWaveLine ? 50.0 : 0.0
            return DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Dense Motion Song",
                trackArtist: "Motion Artist",
                lineIndex: index,
                lineID: "normal-wave-\(index)",
                lineStartTime: Double(index) * 0.85,
                lineEndTime: Double(index) * 0.85 + 0.7,
                playbackTime: 1.8,
                activeIndex: 2,
                displayIndex: 2,
                targetIndex: isTrailingWaveLine ? 1 : 2,
                renderedMinY: baseY + waveOffset,
                renderedMidY: baseY + 22 + waveOffset,
                renderedHeight: 44,
                targetMinY: baseY,
                targetMidY: baseY + 22,
                targetErrorY: waveOffset,
                observedInterLineDeltaY: index == 0 ? nil : (isTrailingWaveLine ? 100 : 50),
                expectedInterLineDeltaY: index == 0 ? nil : 50,
                interLineDeltaErrorY: index == 0 ? nil : (isTrailingWaveLine ? 50 : 0),
                waveOffsetY: waveOffset,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples((0..<5).map(sample))

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })
    }

    func testStaleStaticOffsetLinesCreateMotionIncident() {
        let base = Date()
        func samples(at timestamp: Date) -> [DiagnosticLyricLineMotionSample] {
            (7...13).map { index in
                let baseY = Double(index - 10) * 50
                let staleOffset = [8, 9, 11].contains(index) ? 50.0 : 0.0
                return DiagnosticLyricLineMotionSample(
                    timestamp: timestamp,
                    page: "lyrics",
                    trackTitle: "Line Level Song",
                    trackArtist: "Motion Artist",
                    lineIndex: index,
                    lineID: "stale-static-\(index)",
                    lineStartTime: Double(index) * 0.85,
                    lineEndTime: Double(index) * 0.85 + 0.7,
                    playbackTime: 8.8,
                    activeIndex: 10,
                    displayIndex: 10,
                    targetIndex: staleOffset > 0 ? 9 : 10,
                    renderedMinY: baseY + staleOffset,
                    renderedMidY: baseY + 22 + staleOffset,
                    renderedHeight: 44,
                    targetMinY: baseY,
                    targetMidY: baseY + 22,
                    targetErrorY: staleOffset,
                    observedInterLineDeltaY: index == 7 ? nil : 50,
                    expectedInterLineDeltaY: index == 7 ? nil : 50,
                    interLineDeltaErrorY: index == 7 ? nil : 0,
                    waveOffsetY: staleOffset,
                    manualScrollOffsetY: 0,
                    isManualScrolling: false,
                    isInitialMotionSuppressed: false
                )
            }
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples(at: base))
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples(at: base.addingTimeInterval(0.30)))

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .lyricsLineMotion }
        XCTAssertEqual(incident?.metrics["staleStaticMotion"], 1)
        XCTAssertEqual(incident?.metrics["staleStaticLineCount"] ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(incident?.metrics["maxStaleStaticTargetErrorPt"] ?? -1, 50, accuracy: 0.001)
    }

    func testLyricViewportClipCreatesIncident() {
        let sample = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Clipped Song",
            trackArtist: "Layout Artist",
            lineIndex: 7,
            lineID: "line-7",
            lineStartTime: 30.0,
            lineEndTime: 33.0,
            playbackTime: 31.0,
            activeIndex: 6,
            displayIndex: 6,
            targetIndex: 6,
            renderedMinY: 260,
            renderedMidY: 285,
            renderedHeight: 50,
            targetMinY: 260,
            targetMidY: 285,
            targetErrorY: 0,
            observedInterLineDeltaY: 54,
            expectedInterLineDeltaY: 54,
            interLineDeltaErrorY: 0,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false,
            visibleTopY: 42,
            visibleBottomY: 292,
            lineTopClipY: 0,
            lineBottomClipY: 48,
            activeTopClipY: 0,
            activeBottomClipY: 0,
            controlsVisible: true
        )

        DiagnosticsService.shared.recordLyricsLineMotionSamples([sample])

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .lyricsLineMotion }
        XCTAssertEqual(incident?.title, "Lyrics line clipped")
        XCTAssertEqual(incident?.metrics["lineViewportClip"], 1)
        XCTAssertEqual(incident?.metrics["maxLineBottomClipPt"], 48)
    }

    func testOffscreenSampledLyricLinesDoNotCreateViewportClipIncident() {
        let active = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Viewport Song",
            trackArtist: "Layout Artist",
            lineIndex: 4,
            lineID: "line-4",
            lineStartTime: 30.0,
            lineEndTime: 33.0,
            playbackTime: 31.0,
            activeIndex: 4,
            displayIndex: 4,
            targetIndex: 4,
            renderedMinY: 140,
            renderedMidY: 160,
            renderedHeight: 40,
            targetMinY: 140,
            targetMidY: 160,
            targetErrorY: 0,
            observedInterLineDeltaY: nil,
            expectedInterLineDeltaY: nil,
            interLineDeltaErrorY: nil,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false,
            visibleTopY: 42,
            visibleBottomY: 264,
            lineTopClipY: 0,
            lineBottomClipY: 0,
            activeTopClipY: 0,
            activeBottomClipY: 0,
            controlsVisible: false
        )
        let offscreen = DiagnosticLyricLineMotionSample(
            page: "lyrics",
            trackTitle: "Viewport Song",
            trackArtist: "Layout Artist",
            lineIndex: 16,
            lineID: "line-16",
            lineStartTime: 90.0,
            lineEndTime: 93.0,
            playbackTime: 31.0,
            activeIndex: 4,
            displayIndex: 4,
            targetIndex: 4,
            renderedMinY: 900,
            renderedMidY: 920,
            renderedHeight: 40,
            targetMinY: 900,
            targetMidY: 920,
            targetErrorY: 0,
            observedInterLineDeltaY: 760,
            expectedInterLineDeltaY: 760,
            interLineDeltaErrorY: 0,
            waveOffsetY: 0,
            manualScrollOffsetY: 0,
            isManualScrolling: false,
            isInitialMotionSuppressed: false,
            visibleTopY: 42,
            visibleBottomY: 264,
            lineTopClipY: 0,
            lineBottomClipY: 676,
            activeTopClipY: 0,
            activeBottomClipY: 0,
            controlsVisible: false
        )

        DiagnosticsService.shared.recordLyricsLineMotionSamples([active, offscreen])

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })
    }

    func testRestoredLineClipSpamKeepsClippedBurstLabel() throws {
        struct EmptyRunningStat: Encodable {}
        struct TestSnapshot: Encodable {
            var schemaVersion = 1
            let savedAt: Date
            let sessionID: UUID
            let sessionStartedAt: Date
            let appBuildSignature: String?
            let incidents: [DiagnosticIncident]
            var events: [DiagnosticEvent] = []
            var interactions: [DiagnosticInteractionTrace] = []
            var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample] = []
            var baselineStats: [String: EmptyRunningStat] = [:]
            var lastWarning: DiagnosticIncident? = nil
            var lastExportPath: String? = nil
        }

        let base = Date(timeIntervalSince1970: 1_800_001_000)
        let track = DiagnosticTrackContext(
            title: "Clipped Burst Song",
            artist: "Layout Artist",
            album: "",
            duration: 180
        )
        let incidents = (0..<3).map { index in
            DiagnosticIncident(
                timestamp: base.addingTimeInterval(-Double(index)),
                category: .lyricsLineMotion,
                severity: .warning,
                title: "Lyrics line clipped",
                detail: "A rendered lyric line crossed the usable viewport while controls or panel bounds were present.",
                automaticallyDetected: true,
                track: track,
                metrics: [
                    "maxTargetErrorPt": 0,
                    "maxInterLineErrorPt": 0,
                    "lineViewportClip": 1,
                    "maxLineBottomClipPt": Double(18 + index)
                ],
                evidence: ["track": "Clipped Burst Song / Layout Artist"]
            )
        }
        let snapshot = TestSnapshot(
            savedAt: base,
            sessionID: UUID(),
            sessionStartedAt: base.addingTimeInterval(-60),
            appBuildSignature: DiagnosticsService.shared.currentAppBuildSignatureForTesting(),
            incidents: incidents
        )
        let snapshotURL = try XCTUnwrap(diagnosticsStorageRoot)
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("State", isDirectory: true)
            .appendingPathComponent("rolling_state.json")
        try FileManager.default.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotURL)

        DiagnosticsService.shared.simulateProcessRestartForTesting()

        let lineMotion = DiagnosticsService.shared.incidents.filter { $0.category == .lyricsLineMotion }
        XCTAssertEqual(lineMotion.count, 1)
        XCTAssertEqual(lineMotion.first?.title, "Lyrics line clipped burst")
        XCTAssertEqual(lineMotion.first?.metrics["occurrenceCount"], 3)
        XCTAssertEqual(lineMotion.first?.metrics["maxLineBottomClipPt"] ?? -1, 20, accuracy: 0.001)
    }

    func testCollapsedLyricLineMotionGeometryDoesNotCreateIncident() {
        let samples = (0..<6).map { index in
            let targetMinY = 40.0 + Double(index * 72)
            return DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Motion Song",
                trackArtist: "Motion Artist",
                lineIndex: index,
                lineID: "line-\(index)",
                lineStartTime: Double(index * 3),
                lineEndTime: Double(index * 3 + 2),
                playbackTime: 1.0,
                activeIndex: 0,
                displayIndex: 0,
                targetIndex: 0,
                renderedMinY: 0,
                renderedMidY: 22,
                renderedHeight: 44,
                targetMinY: targetMinY,
                targetMidY: targetMinY + 22,
                targetErrorY: -targetMinY,
                observedInterLineDeltaY: index == 0 ? nil : 0,
                expectedInterLineDeltaY: index == 0 ? nil : 72,
                interLineDeltaErrorY: index == 0 ? nil : -72,
                waveOffsetY: 0,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })
        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "diagnostics.lyricsLineMotionGeometryDiscarded" })
    }

    func testNearbyWaveStaggerWithAlignedActiveLineDoesNotCreateMotionIncident() {
        let samples = (6...14).map { index in
            let targetMinY = Double(index - 10) * 78.0
            return DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: "Wave Song",
                trackArtist: "Wave Artist",
                lineIndex: index,
                lineID: "line-\(index)",
                lineStartTime: Double(index * 3),
                lineEndTime: Double(index * 3 + 2),
                playbackTime: 31.0,
                activeIndex: 10,
                displayIndex: 10,
                targetIndex: index == 10 ? 10 : 9,
                renderedMinY: targetMinY,
                renderedMidY: targetMinY + 22,
                renderedHeight: 44,
                targetMinY: targetMinY,
                targetMidY: targetMinY + 22,
                targetErrorY: 0,
                observedInterLineDeltaY: index == 6 ? nil : 78,
                expectedInterLineDeltaY: index == 6 ? nil : 78,
                interLineDeltaErrorY: index == 6 ? nil : 0,
                waveOffsetY: 0,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })
    }

    func testLateActiveWaveTargetCreatesMotionIncidentEvenWithAlignedGeometry() {
        let base = Date()
        func samples(at timestamp: Date) -> [DiagnosticLyricLineMotionSample] {
            (6...14).map { index in
            let targetMinY = Double(index - 10) * 78.0
            return DiagnosticLyricLineMotionSample(
                timestamp: timestamp,
                page: "lyrics",
                trackTitle: "Wave Song",
                trackArtist: "Wave Artist",
                lineIndex: index,
                lineID: "line-\(index)",
                lineStartTime: Double(index * 3),
                lineEndTime: Double(index * 3 + 2),
                playbackTime: 31.0,
                activeIndex: 10,
                displayIndex: 10,
                targetIndex: 9,
                renderedMinY: targetMinY,
                renderedMidY: targetMinY + 22,
                renderedHeight: 44,
                targetMinY: targetMinY,
                targetMidY: targetMinY + 22,
                targetErrorY: 0,
                observedInterLineDeltaY: index == 6 ? nil : 78,
                expectedInterLineDeltaY: index == 6 ? nil : 78,
                interLineDeltaErrorY: index == 6 ? nil : 0,
                waveOffsetY: 0,
                manualScrollOffsetY: 0,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
            }
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples(at: base))
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples(at: base.addingTimeInterval(0.70)))

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .lyricsLineMotion }
        XCTAssertEqual(incident?.metrics["activeTargetLagged"], 1)
        XCTAssertEqual(incident?.metrics["activeVisualElapsedMs"] ?? -1, 700, accuracy: 0.001)
    }

    func testLingeringNearbyWaveBacklogCreatesMotionIncidentEvenWhenActiveTargetAligned() {
        let base = Date()
        func samples(at timestamp: Date) -> [DiagnosticLyricLineMotionSample] {
            (6...14).map { index in
                let targetMinY = Double(index - 10) * 78.0
                return DiagnosticLyricLineMotionSample(
                    timestamp: timestamp,
                    page: "lyrics",
                    trackTitle: "Wave Song",
                    trackArtist: "Wave Artist",
                    lineIndex: index,
                    lineID: "line-\(index)",
                    lineStartTime: Double(index * 3),
                    lineEndTime: Double(index * 3 + 2),
                    playbackTime: 31.0,
                    activeIndex: 10,
                    displayIndex: 10,
                    targetIndex: index == 10 ? 10 : 9,
                    renderedMinY: targetMinY,
                    renderedMidY: targetMinY + 22,
                    renderedHeight: 44,
                    targetMinY: targetMinY,
                    targetMidY: targetMinY + 22,
                    targetErrorY: 0,
                    observedInterLineDeltaY: index == 6 ? nil : 78,
                    expectedInterLineDeltaY: index == 6 ? nil : 78,
                    interLineDeltaErrorY: index == 6 ? nil : 0,
                    waveOffsetY: 0,
                    manualScrollOffsetY: 0,
                    isManualScrolling: false,
                    isInitialMotionSuppressed: false
                )
            }
        }

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples(at: base))
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsLineMotion })

        DiagnosticsService.shared.recordLyricsLineMotionSamples(samples(at: base.addingTimeInterval(1.00)))

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .lyricsLineMotion }
        XCTAssertEqual(incident?.metrics["activeTargetLagged"], 0)
        XCTAssertEqual(incident?.metrics["lingeringWaveBacklog"], 1)
        XCTAssertEqual(incident?.metrics["activeVisualElapsedMs"] ?? -1, 1000, accuracy: 0.001)
    }

    func testManualReportReplacesDebugPlaceholderWithRecentTrackContext() throws {
        let realTrack = DiagnosticTrackContext(
            title: "戀愛預告",
            artist: "Sandy Lamb",
            album: "My Lovely Legend: Teresa Carpio & Sandy Lamb",
            duration: 218.839
        )
        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: realTrack,
            source: "NetEase",
            score: 51.6,
            lineCount: 26,
            isUnsynced: false,
            hadSourceTranslation: false
        )

        let placeholder = DiagnosticTrackContext(
            title: "Wrong Lyrics",
            artist: "Reporter",
            album: "Debug",
            duration: 180
        )

        let url = try DiagnosticsService.shared.recordManualReport(
            symptom: .wrongLyrics,
            note: "Selected source appears to be a different song.",
            track: placeholder
        )
        let data = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: data)

        XCTAssertEqual(report.track?.title, "戀愛預告")
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.track?.title, "戀愛預告")
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.evidence["trackContextSource"], "recentEvent")
    }

    func testSingleStandaloneWarningFrameStallDoesNotCreateNoiseIncident() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
    }

    func testTwoStandaloneWarningFrameStallsStayPendingAsIdleNoise() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "album")
        DiagnosticsService.shared.recordFrameTick(delta: 0.190, page: "album")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
    }

    func testFourStandaloneWarningFrameStallsStayPendingAsIdleNoise() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.170, page: "album")
        DiagnosticsService.shared.recordFrameTick(delta: 0.178, page: "album")
        DiagnosticsService.shared.recordFrameTick(delta: 0.165, page: "album")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "album")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
    }

    func testSingleStandaloneCriticalFrameStallStaysPendingAsIdleNoise() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.315, page: "album")

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .uiFrameStall })
    }

    func testSevereStandaloneFrameStallCreatesImmediateIncident() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.550, page: "album")

        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .uiFrameStall)
        XCTAssertEqual(incident?.severity, .critical)
        XCTAssertEqual(incident?.metrics["maxDeltaMs"] ?? -1, 550, accuracy: 0.001)
    }

    func testRepeatedStandaloneWarningFrameStallsCreateHiddenCauseIncident() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.190, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.200, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.190, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.200, page: "lyrics")

        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .uiFrameStall)
        XCTAssertEqual(incident?.automaticallyDetected, true)
        XCTAssertEqual(incident?.evidence["page"], "lyrics")
        XCTAssertEqual(incident?.metrics["occurrenceCount"], 6)
    }

    func testStandaloneFrameStallsCoalesceLiveBurst() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.340, page: "lyrics")
        DiagnosticsService.shared.recordFrameTick(delta: 0.220, page: "lyrics")

        let frameStalls = DiagnosticsService.shared.incidents.filter { $0.category == .uiFrameStall }
        XCTAssertEqual(frameStalls.count, 1)
        XCTAssertEqual(frameStalls.first?.title, "UI frame stall burst")
        XCTAssertEqual(frameStalls.first?.severity, .critical)
        XCTAssertEqual(frameStalls.first?.metrics["occurrenceCount"], 3)
        XCTAssertEqual(frameStalls.first?.metrics["maxDeltaMs"] ?? -1, 340, accuracy: 0.001)
        XCTAssertEqual(frameStalls.first?.evidence["page"], "lyrics")
        XCTAssertNotNil(frameStalls.first?.evidence["signature"])
    }

    func testInteractionTraceCorrelatesFrameAndBridgeSignals() {
        let track = DiagnosticTrackContext(
            title: "Animated Skip",
            artist: "Diagnostics",
            album: "Debug",
            duration: 210
        )

        let id = DiagnosticsService.shared.beginInteraction(
            type: .nextTrack,
            page: "lyrics",
            expectedDuration: 0.60,
            track: track,
            metrics: ["lyricLineCount": 32, "hasSyllableSyncLyrics": 1],
            evidence: ["animation": "SkipControlButton.replacementFlow"]
        )

        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")
        DiagnosticsService.shared.recordScriptingBridgeTiming(
            operation: "pollPositionViaSB",
            queueWait: 0.30,
            readTime: 0.03,
            timedOut: false
        )
        DiagnosticsService.shared.completeInteraction(id)

        let trace = DiagnosticsService.shared.interactions.first
        XCTAssertEqual(trace?.type, .nextTrack)
        XCTAssertEqual(trace?.status, .completed)
        XCTAssertEqual(trace?.metrics["frameStallCount"], 1)
        XCTAssertEqual(trace?.metrics["maxScriptingBridgeQueueWaitMs"] ?? -1, 300, accuracy: 0.1)
        XCTAssertTrue(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsPagePerformance })
    }

    func testEmptyLoadingLyricsPageSwitchStaysBaseline() {
        let track = DiagnosticTrackContext(
            title: "Long Ago and Far Away",
            artist: "Earl Klugh",
            album: "Finger Paintings",
            duration: 337.399
        )

        let id = DiagnosticsService.shared.beginInteraction(
            type: .pageSwitch,
            page: "lyrics",
            expectedDuration: 0.35,
            track: track,
            metrics: [
                "isLoadingLyrics": 1,
                "lyricLineCount": 0,
                "currentLineIndex": -1,
                "expectedDurationMs": 350
            ],
            evidence: ["fromPage": "album", "toPage": "lyrics"]
        )

        DiagnosticsService.shared.recordFrameTick(delta: 0.360, page: "lyrics")
        DiagnosticsService.shared.completeInteraction(id)

        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .lyricsPagePerformance })
        let baselineEvent = DiagnosticsService.shared.events.first { $0.name == "interaction.loadingLyricsPageSwitchBaseline" }
        XCTAssertEqual(baselineEvent?.track, track)
    }

    func testForcedLyricsRefreshCreatesInteractionTrace() {
        let track = DiagnosticTrackContext(
            title: "Refresh Song",
            artist: "Diagnostics",
            album: "Debug",
            duration: 200
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: true)
        XCTAssertEqual(DiagnosticsService.shared.activeInteractionCount, 1)

        DiagnosticsService.shared.recordFrameTick(delta: 0.040, page: "lyrics")
        DiagnosticsService.shared.recordLyricsFetchFinished(
            track: track,
            source: "NetEase",
            score: 72,
            lineCount: 28,
            hasSyllableSync: true,
            firstRealLineSHA256: "fixture-hash",
            isUnsynced: false,
            hadSourceTranslation: false
        )

        let trace = DiagnosticsService.shared.interactions.first
        XCTAssertEqual(trace?.type, .lyricsRefresh)
        XCTAssertEqual(trace?.page, "lyrics")
        XCTAssertEqual(trace?.status, .completed)
        XCTAssertEqual(trace?.metrics["lineCount"], 28)
        XCTAssertEqual(trace?.metrics["hasSyllableSync"], 1)
        XCTAssertEqual(trace?.evidence["source"], "NetEase")
        XCTAssertEqual(trace?.evidence["hasSyllableSync"], "true")
        XCTAssertEqual(trace?.evidence["firstRealLineSHA256"], "fixture-hash")
        XCTAssertEqual(DiagnosticsService.shared.activeInteractionCount, 0)
    }

    func testOverlappingSkipInteractionIsMarkedInterrupted() {
        let first = DiagnosticsService.shared.beginInteraction(
            type: .nextTrack,
            page: "album",
            expectedDuration: 0.60
        )
        XCTAssertNotNil(first)
        XCTAssertEqual(DiagnosticsService.shared.activeInteractionCount, 1)

        let second = DiagnosticsService.shared.beginInteraction(
            type: .previousTrack,
            page: "album",
            expectedDuration: 0.60
        )

        XCTAssertNotNil(second)
        XCTAssertEqual(DiagnosticsService.shared.interactions.first?.status, .interrupted)
        XCTAssertTrue(DiagnosticsService.shared.incidents.contains { $0.category == .uiAnimationIncomplete })

        DiagnosticsService.shared.completeInteraction(second)
        XCTAssertEqual(DiagnosticsService.shared.activeInteractionCount, 0)
    }

    func testSkipInteractionRecordsControlVisibilityMetrics() {
        let id = DiagnosticsService.shared.beginInteraction(
            type: .nextTrack,
            page: "lyrics",
            expectedDuration: 0.60,
            metrics: [
                "controlsVisibleAtStart": 1,
                "activeSkipAnimationCountAtStart": 0
            ],
            evidence: [
                "animation": "SkipControlButton.replacementFlow",
                "controlsVisibleAtStart": "true"
            ]
        )

        DiagnosticsService.shared.completeInteraction(
            id,
            status: .interrupted,
            detail: "Skip animation view disappeared before the replacement flow completed.",
            metrics: [
                "controlsVisibleAtFinish": 0,
                "activeSkipAnimationCountAtFinish": 1,
                "skipAnimationHiddenAtFinish": 1
            ],
            evidence: [
                "controlsVisibleAtFinish": "false"
            ]
        )

        let trace = DiagnosticsService.shared.interactions.first
        XCTAssertEqual(trace?.metrics["controlsVisibleAtStart"], 1)
        XCTAssertEqual(trace?.metrics["controlsVisibleAtFinish"], 0)
        XCTAssertEqual(trace?.metrics["skipAnimationHiddenAtFinish"], 1)
        XCTAssertEqual(trace?.evidence["controlsVisibleAtFinish"], "false")
        XCTAssertTrue(DiagnosticsService.shared.incidents.contains { $0.category == .uiAnimationIncomplete })
    }

    func testArtworkSlowApplyCreatesInspectableIncident() {
        let track = DiagnosticTrackContext(
            title: "Slow Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            duration: 188
        )

        DiagnosticsService.shared.recordArtworkFetchStarted(
            track: track,
            generation: 42,
            persistentIDPresent: false,
            metadataCacheEligible: true,
            heldPreviousArtwork: true
        )
        DiagnosticsService.shared.recordArtworkApplied(
            track: track,
            generation: 42,
            source: "apple",
            applyMilliseconds: 75
        )

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .artworkBlocking }
        XCTAssertEqual(incident?.title, "Artwork update slow")
        XCTAssertEqual(incident?.evidence["source"], "apple")
        XCTAssertEqual(incident?.metrics["applyMilliseconds"] ?? -1, 75, accuracy: 0.001)
        XCTAssertTrue(DiagnosticsService.shared.events.contains { $0.name == "artwork.apply" })
    }

    func testArtworkCacheMissRecordsRetainedPreviousArtwork() {
        let track = DiagnosticTrackContext(
            title: "Held Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            duration: 201
        )

        DiagnosticsService.shared.recordArtworkFetchStarted(
            track: track,
            generation: 7,
            persistentIDPresent: false,
            metadataCacheEligible: false,
            heldPreviousArtwork: true
        )
        DiagnosticsService.shared.recordArtworkCacheMiss(
            track: track,
            generation: 7,
            heldPreviousArtwork: true
        )

        let event = DiagnosticsService.shared.events.first { $0.name == "artwork.cache.miss" }
        XCTAssertEqual(event?.metrics["heldPreviousArtwork"], 1)
        XCTAssertFalse(DiagnosticsService.shared.incidents.contains { $0.category == .artworkBlocking })
    }

    func testArtworkPlaceholderIsInspectableWithoutCompletingFetch() {
        let track = DiagnosticTrackContext(
            title: "Fallback Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            duration: 201
        )

        DiagnosticsService.shared.recordArtworkFetchStarted(
            track: track,
            generation: 8,
            persistentIDPresent: false,
            metadataCacheEligible: true,
            heldPreviousArtwork: true
        )
        DiagnosticsService.shared.recordArtworkPlaceholderShown(
            track: track,
            generation: 8,
            reason: "retainedPreviousExpired",
            applyMilliseconds: 2
        )

        let event = DiagnosticsService.shared.events.first { $0.name == "artwork.placeholder" }
        XCTAssertTrue(event?.detail.contains("retainedPreviousExpired") == true)
        let incident = DiagnosticsService.shared.incidents.first { $0.category == .artworkBlocking }
        XCTAssertEqual(incident?.title, "Artwork missing for current track")
        XCTAssertEqual(incident?.evidence["reason"], "retainedPreviousExpired")
    }

    func testArtworkFetchFailedPlaceholderIsCriticalIncident() {
        let track = DiagnosticTrackContext(
            title: "Missing Cover",
            artist: "Diagnostics",
            album: "Debug Album",
            duration: 201
        )

        DiagnosticsService.shared.recordArtworkPlaceholderShown(
            track: track,
            generation: 9,
            reason: "fetchFailed",
            applyMilliseconds: 2
        )

        let incident = DiagnosticsService.shared.incidents.first { $0.category == .artworkBlocking }
        XCTAssertEqual(incident?.title, "Artwork missing for current track")
        XCTAssertEqual(incident?.severity, .critical)
        XCTAssertEqual(incident?.evidence["reason"], "fetchFailed")
    }

    func testArtworkReportFallsBackToRecentArtworkEventsWhenTrackSwitched() throws {
        let outgoingTrack = DiagnosticTrackContext(
            title: "Previous Cover",
            artist: "Diagnostics",
            album: "Old Album",
            duration: 181
        )
        let currentTrack = DiagnosticTrackContext(
            title: "Current Cover",
            artist: "Diagnostics",
            album: "New Album",
            duration: 202
        )

        DiagnosticsService.shared.recordArtworkFetchStarted(
            track: outgoingTrack,
            generation: 11,
            persistentIDPresent: false,
            metadataCacheEligible: true,
            heldPreviousArtwork: true
        )
        DiagnosticsService.shared.recordArtworkApplied(
            track: outgoingTrack,
            generation: 11,
            source: "web",
            applyMilliseconds: 75
        )

        let url = try DiagnosticsService.shared.recordManualReport(
            symptom: .artworkStaleAfterSwitch,
            note: "",
            track: currentTrack
        )
        let reportData = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: reportData)

        XCTAssertTrue(report.incidents.contains { $0.category == .artworkBlocking })
        XCTAssertTrue(report.events.contains { $0.name == "diagnostics.artworkTimeScopedFallback" })
        XCTAssertTrue(report.events.contains { $0.name == "artwork.apply" && $0.track?.title == "Previous Cover" })
    }

    func testBlackoutReportFallsBackToRecentMotionAndArtworkEvidence() throws {
        let previousTrack = DiagnosticTrackContext(
            title: "Blackout Previous",
            artist: "Diagnostics",
            album: "Old Album",
            duration: 181
        )
        let currentTrack = DiagnosticTrackContext(
            title: "Blackout Current",
            artist: "Diagnostics",
            album: "New Album",
            duration: 202
        )

        DiagnosticsService.shared.recordArtworkFetchStarted(
            track: previousTrack,
            generation: 18,
            persistentIDPresent: false,
            metadataCacheEligible: true,
            heldPreviousArtwork: true
        )
        DiagnosticsService.shared.recordLyricsLineMotionSamples([
            DiagnosticLyricLineMotionSample(
                page: "lyrics",
                trackTitle: previousTrack.title,
                trackArtist: previousTrack.artist,
                lineIndex: 2,
                lineID: "blackout-line-2",
                lineStartTime: 12,
                lineEndTime: 16,
                playbackTime: 13,
                activeIndex: 2,
                displayIndex: 1,
                targetIndex: 3,
                renderedMinY: 110,
                renderedMidY: 125,
                renderedHeight: 30,
                targetMinY: 82,
                targetMidY: 90,
                targetErrorY: 35,
                observedInterLineDeltaY: 36,
                expectedInterLineDeltaY: 36,
                interLineDeltaErrorY: 0,
                waveOffsetY: 4,
                manualScrollOffsetY: 14,
                isManualScrolling: false,
                isInitialMotionSuppressed: false
            )
        ])

        let url = try DiagnosticsService.shared.recordManualReport(
            symptom: .switchingBlackout,
            note: "",
            track: currentTrack
        )
        let reportData = try Data(contentsOf: url.appendingPathComponent("report.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticReportManifest.self, from: reportData)

        XCTAssertTrue(report.events.contains { $0.name == "diagnostics.artworkTimeScopedFallback" })
        XCTAssertTrue(report.events.contains { $0.name == "diagnostics.lyricsLineMotionTimeScopedFallback" })
        XCTAssertTrue(report.lyricLineMotionSamples.contains { $0.trackTitle == "Blackout Previous" })
    }
}
