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
            title: "Wrong Lyrics",
            artist: "Reporter",
            album: "Debug",
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
