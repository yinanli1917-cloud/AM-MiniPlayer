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

    func testPartialSourceTranslationCreatesInspectableIncidentWhenTranslationShown() {
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

        let incident = DiagnosticsService.shared.incidents.first
        XCTAssertEqual(incident?.category, .lyricsPartialTranslation)
        XCTAssertEqual(incident?.title, "Source translation incomplete")
        XCTAssertEqual(incident?.metrics["translationLineCount"], 13)
        XCTAssertEqual(incident?.metrics["missingTranslationLineCount"], 7)
        XCTAssertEqual(incident?.metrics["translationCoverage"] ?? -1, 0.65, accuracy: 0.001)
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

    func testLiveLyricLineMotionCSVWritesSingleHeaderAcrossBatches() throws {
        func sample(lineID: String, lineIndex: Int) -> DiagnosticLyricLineMotionSample {
            DiagnosticLyricLineMotionSample(
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

    func testNoSourceLyricsMissIsInformational() {
        let track = DiagnosticTrackContext(
            title: "Missing Song",
            artist: "Missing Artist",
            album: "Missing Album",
            duration: 200
        )

        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 0)

        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.category, .lyricsFallbackChurn)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.severity, .info)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.title, "Lyrics unresolved")
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.evidence["result"], "unresolved")

        DiagnosticsService.shared.clear()
        DiagnosticsService.shared.recordLyricsFetchStarted(track: track, forceRefresh: false)
        DiagnosticsService.shared.recordLyricsFetchMiss(track: track, resultCount: 2)

        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.category, .lyricsFallbackChurn)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.severity, .warning)
        XCTAssertEqual(DiagnosticsService.shared.incidents.first?.evidence["result"], "miss")
    }

    func testDebugLogAttachmentIsSessionScoped() {
        XCTAssertFalse(DiagnosticsService.shared.shouldAttachDebugLog(modifiedAt: Date().addingTimeInterval(-10)))
        XCTAssertTrue(DiagnosticsService.shared.shouldAttachDebugLog(modifiedAt: Date()))
    }

    func testCurrentSessionDebugLogIsAttachedToReportBundle() throws {
        let debugLogURL = try XCTUnwrap(diagnosticsStorageRoot?.appendingPathComponent("nanopod_debug.log"))
        try "current diagnostics log\n".write(to: debugLogURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: debugLogURL.path)

        let url = try DiagnosticsService.shared.exportReportBundle(
            userSymptom: .visibleStutter,
            userNote: "current debug log",
            track: nil
        )

        let attachedLog = url.appendingPathComponent("nanopod_debug.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachedLog.path))
        XCTAssertEqual(try String(contentsOf: attachedLog, encoding: .utf8), "current diagnostics log\n")
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

        let snapshot = TestSnapshot(
            savedAt: base,
            sessionID: UUID(),
            sessionStartedAt: base.addingTimeInterval(-300),
            appBuildSignature: DiagnosticsService.shared.currentAppBuildSignatureForTesting(),
            incidents: [legacyHighCPU] + lineMotionIncidents + incidents,
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
            isUnsynced: false,
            hadSourceTranslation: false
        )

        let trace = DiagnosticsService.shared.interactions.first
        XCTAssertEqual(trace?.type, .lyricsRefresh)
        XCTAssertEqual(trace?.page, "lyrics")
        XCTAssertEqual(trace?.status, .completed)
        XCTAssertEqual(trace?.metrics["lineCount"], 28)
        XCTAssertEqual(trace?.evidence["source"], "NetEase")
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
}
