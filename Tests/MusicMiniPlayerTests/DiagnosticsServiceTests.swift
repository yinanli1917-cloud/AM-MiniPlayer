import XCTest
@testable import MusicMiniPlayerCore

@MainActor
final class DiagnosticsServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagnosticsService.shared.isEnabled = true
        DiagnosticsService.shared.clear()
    }

    override func tearDown() {
        DiagnosticsService.shared.clear()
        DiagnosticsService.shared.isEnabled = false
        super.tearDown()
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

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("summary.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("performance_samples.csv").path))
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.userSymptom, .wrongLyrics)
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

    func testFrameStallCreatesHiddenCauseIncident() {
        DiagnosticsService.shared.recordFrameTick(delta: 0.180, page: "lyrics")

        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .uiFrameStall)
        XCTAssertEqual(incident?.automaticallyDetected, true)
        XCTAssertEqual(incident?.evidence["page"], "lyrics")
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
}
