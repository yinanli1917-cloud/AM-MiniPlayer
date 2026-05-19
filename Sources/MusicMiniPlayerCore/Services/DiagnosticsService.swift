/**
 * [INPUT]: Runtime timing signals from MusicController/LyricsService and user report actions
 * [OUTPUT]: DiagnosticsService owner debug-mode incident buffer and report bundle export
 * [POS]: MusicMiniPlayerCore local-only diagnostics recorder for Codex/debug bug reports
 */

import Combine
import Darwin
import Foundation

public enum DiagnosticSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case critical
}

public enum DiagnosticIncidentCategory: String, Codable, CaseIterable, Sendable {
    case lyricsSlowFetch
    case lyricsFallbackChurn
    case lyricsManualReport
    case uiFrameStall
    case uiInteractionSlow
    case uiAnimationIncomplete
    case lyricsPagePerformance
    case lyricsLineMotion
    case scriptingBridgeLatency
    case scriptingBridgeTimeout
    case scriptingBridgeBacklog
    case artworkBlocking
    case highCPU
    case memorySpike
    case statusItemAnomaly
}

public enum DiagnosticInteractionType: String, Codable, CaseIterable, Sendable {
    case nextTrack
    case previousTrack
    case playPause
    case pageSwitch
    case lyricsRefresh

    var displayName: String {
        switch self {
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .playPause: return "Play/pause"
        case .pageSwitch: return "Page switch"
        case .lyricsRefresh: return "Lyrics refresh"
        }
    }
}

public enum DiagnosticInteractionStatus: String, Codable, CaseIterable, Sendable {
    case active
    case completed
    case interrupted
    case timedOut
}

public enum DiagnosticUserSymptom: String, Codable, CaseIterable, Identifiable, Sendable {
    case wrongLyrics = "wrong lyrics"
    case lyricsTimingOff = "lyrics timing off"
    case staleLyrics = "stale lyrics after switching"
    case translationWrong = "translation wrong"
    case lyricsLoadingTooSlow = "lyrics loading too slow"
    case visibleStutter = "visible stutter"
    case other = "other"

    public var id: String { rawValue }
}

public struct DiagnosticInteractionTrace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var type: DiagnosticInteractionType
    public var page: String
    public var startedAt: Date
    public var completedAt: Date?
    public var expectedDuration: TimeInterval
    public var status: DiagnosticInteractionStatus
    public var track: DiagnosticTrackContext?
    public var metrics: [String: Double]
    public var evidence: [String: String]

    public init(
        id: UUID = UUID(),
        type: DiagnosticInteractionType,
        page: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        expectedDuration: TimeInterval,
        status: DiagnosticInteractionStatus = .active,
        track: DiagnosticTrackContext? = nil,
        metrics: [String: Double] = [:],
        evidence: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.page = page
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.expectedDuration = expectedDuration
        self.status = status
        self.track = track
        self.metrics = metrics
        self.evidence = evidence
    }
}

public struct DiagnosticTrackContext: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var persistentID: String?
    public var playbackTime: TimeInterval?

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        persistentID: String? = nil,
        playbackTime: TimeInterval? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.persistentID = persistentID
        self.playbackTime = playbackTime
    }

    public var hasCredibleIdentity: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanArtist.isEmpty else { return false }
        guard cleanTitle != "Wrong Lyrics" || cleanArtist != "Reporter" || album != "Debug" else { return false }
        guard cleanTitle != kNotPlayingSentinel else { return false }
        return true
    }
}

public struct DiagnosticIncident: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var category: DiagnosticIncidentCategory
    public var severity: DiagnosticSeverity
    public var title: String
    public var detail: String
    public var automaticallyDetected: Bool
    public var userSymptom: DiagnosticUserSymptom?
    public var track: DiagnosticTrackContext?
    public var metrics: [String: Double]
    public var evidence: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticIncidentCategory,
        severity: DiagnosticSeverity,
        title: String,
        detail: String,
        automaticallyDetected: Bool,
        userSymptom: DiagnosticUserSymptom? = nil,
        track: DiagnosticTrackContext? = nil,
        metrics: [String: Double] = [:],
        evidence: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.automaticallyDetected = automaticallyDetected
        self.userSymptom = userSymptom
        self.track = track
        self.metrics = metrics
        self.evidence = evidence
    }
}

public struct DiagnosticEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var name: String
    public var detail: String
    public var track: DiagnosticTrackContext?
    public var metrics: [String: Double]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        name: String,
        detail: String,
        track: DiagnosticTrackContext? = nil,
        metrics: [String: Double] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.detail = detail
        self.track = track
        self.metrics = metrics
    }
}

public struct DiagnosticLyricLineMotionSample: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var page: String
    public var trackTitle: String
    public var trackArtist: String
    public var lineIndex: Int
    public var lineID: String
    public var lineStartTime: TimeInterval
    public var lineEndTime: TimeInterval
    public var playbackTime: TimeInterval
    public var activeIndex: Int
    public var displayIndex: Int
    public var targetIndex: Int
    public var renderedMinY: Double
    public var renderedMidY: Double
    public var renderedHeight: Double
    public var targetMinY: Double
    public var targetMidY: Double
    public var targetErrorY: Double
    public var velocityY: Double
    public var observedInterLineDeltaY: Double?
    public var expectedInterLineDeltaY: Double?
    public var interLineDeltaErrorY: Double?
    public var waveOffsetY: Double
    public var manualScrollOffsetY: Double
    public var isManualScrolling: Bool
    public var isInitialMotionSuppressed: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        page: String,
        trackTitle: String,
        trackArtist: String,
        lineIndex: Int,
        lineID: String,
        lineStartTime: TimeInterval,
        lineEndTime: TimeInterval,
        playbackTime: TimeInterval,
        activeIndex: Int,
        displayIndex: Int,
        targetIndex: Int,
        renderedMinY: Double,
        renderedMidY: Double,
        renderedHeight: Double,
        targetMinY: Double,
        targetMidY: Double,
        targetErrorY: Double,
        velocityY: Double = 0,
        observedInterLineDeltaY: Double? = nil,
        expectedInterLineDeltaY: Double? = nil,
        interLineDeltaErrorY: Double? = nil,
        waveOffsetY: Double,
        manualScrollOffsetY: Double,
        isManualScrolling: Bool,
        isInitialMotionSuppressed: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.page = page
        self.trackTitle = trackTitle
        self.trackArtist = trackArtist
        self.lineIndex = lineIndex
        self.lineID = lineID
        self.lineStartTime = lineStartTime
        self.lineEndTime = lineEndTime
        self.playbackTime = playbackTime
        self.activeIndex = activeIndex
        self.displayIndex = displayIndex
        self.targetIndex = targetIndex
        self.renderedMinY = renderedMinY
        self.renderedMidY = renderedMidY
        self.renderedHeight = renderedHeight
        self.targetMinY = targetMinY
        self.targetMidY = targetMidY
        self.targetErrorY = targetErrorY
        self.velocityY = velocityY
        self.observedInterLineDeltaY = observedInterLineDeltaY
        self.expectedInterLineDeltaY = expectedInterLineDeltaY
        self.interLineDeltaErrorY = interLineDeltaErrorY
        self.waveOffsetY = waveOffsetY
        self.manualScrollOffsetY = manualScrollOffsetY
        self.isManualScrolling = isManualScrolling
        self.isInitialMotionSuppressed = isInitialMotionSuppressed
    }
}

public struct DiagnosticReportManifest: Codable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var buildVersion: String
    public var osVersion: String
    public var sessionID: UUID
    public var userSymptom: DiagnosticUserSymptom?
    public var userNote: String
    public var track: DiagnosticTrackContext?
    public var incidents: [DiagnosticIncident]
    public var events: [DiagnosticEvent]
    public var interactions: [DiagnosticInteractionTrace]
    public var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample]
    public var baseline: [String: Double]
    public var mediaAttachmentNames: [String]
}

@MainActor
public final class DiagnosticsService: ObservableObject {
    public static let shared = DiagnosticsService()

    public static let enabledKey = "ownerDiagnosticsEnabled"
    public static var isOwnerDiagnosticsBuild: Bool {
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        return true
        #else
        return false
        #endif
    }

    @Published public private(set) var incidents: [DiagnosticIncident] = []
    @Published public private(set) var events: [DiagnosticEvent] = []
    @Published public private(set) var interactions: [DiagnosticInteractionTrace] = []
    @Published public private(set) var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample] = []
    @Published public private(set) var activeInteractionCount: Int = 0
    @Published public private(set) var lastExportURL: URL?
    @Published public private(set) var lastWarning: DiagnosticIncident?
    @Published public var isEnabled: Bool {
        didSet {
            if isEnabled && !Self.isOwnerDiagnosticsBuild {
                isEnabled = false
                return
            }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startSessionIfNeeded()
            } else {
                healthSampler?.invalidate()
                healthSampler = nil
                activeInteractions.values.forEach { $0.timeoutTask?.cancel() }
                activeInteractions.removeAll()
                activeInteractionCount = 0
            }
        }
    }

    public let sessionID: UUID

    private var sessionStartedAt: Date
    private var lyricsFetchStarts: [String: Date] = [:]
    private var baselineStats: [String: RunningStat] = [:]
    private var activeInteractions: [UUID: ActiveDiagnosticInteraction] = [:]
    private var healthSampler: Timer?
    private let maxEvents = 300
    private let maxIncidents = 120
    private let maxInteractions = 120
    private let maxLyricLineMotionSamples = 2400
    private let retention: TimeInterval = 24 * 60 * 60
    private var previousLyricLineMotionSamples: [String: (timestamp: Date, renderedMidY: Double)] = [:]
    private var lastLyricLineMotionIncidentAt: Date?

    private init() {
        self.isEnabled = Self.isOwnerDiagnosticsBuild && UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.sessionID = UUID()
        self.sessionStartedAt = Date()
        if isEnabled {
            startSessionIfNeeded()
        }
    }

    public var incidentCount: Int { incidents.count }
    public var latestIncident: DiagnosticIncident? { incidents.first }
    public var latestInteraction: DiagnosticInteractionTrace? { interactions.first }

    public var severeOrRepeatedIssue: DiagnosticIncident? {
        if let latest = incidents.first, latest.severity == .critical {
            return latest
        }
        let recent = incidents.prefix(8)
        let bridgeCount = recent.filter { $0.category == .scriptingBridgeLatency || $0.category == .scriptingBridgeTimeout }.count
        if bridgeCount >= 3 {
            return recent.first { $0.category == .scriptingBridgeLatency || $0.category == .scriptingBridgeTimeout }
        }
        return nil
    }

    public func clear() {
        incidents.removeAll()
        events.removeAll()
        activeInteractions.values.forEach { $0.timeoutTask?.cancel() }
        activeInteractions.removeAll()
        interactions.removeAll()
        lyricLineMotionSamples.removeAll()
        previousLyricLineMotionSamples.removeAll()
        lastLyricLineMotionIncidentAt = nil
        activeInteractionCount = 0
        lyricsFetchStarts.removeAll()
        baselineStats.removeAll()
        lastExportURL = nil
        lastWarning = nil
        sessionStartedAt = Date()
    }

    public func recordEvent(
        _ name: String,
        detail: String,
        track: DiagnosticTrackContext? = nil,
        metrics: [String: Double] = [:]
    ) {
        guard isEnabled else { return }
        events.insert(DiagnosticEvent(name: name, detail: detail, track: track, metrics: metrics), at: 0)
        trimBuffers()
    }

    @discardableResult
    public func beginInteraction(
        type: DiagnosticInteractionType,
        page: String,
        expectedDuration: TimeInterval,
        track: DiagnosticTrackContext? = nil,
        metrics: [String: Double] = [:],
        evidence: [String: String] = [:]
    ) -> UUID? {
        guard isEnabled else { return nil }

        interruptOverlappingInteractions(type: type, page: page)

        var traceMetrics = metrics
        traceMetrics["expectedDurationMs"] = expectedDuration * 1000
        let trace = DiagnosticInteractionTrace(
            type: type,
            page: page,
            expectedDuration: expectedDuration,
            track: track,
            metrics: traceMetrics,
            evidence: evidence
        )

        let timeout = expectedDuration + 0.40
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.completeInteraction(
                trace.id,
                status: .timedOut,
                detail: "\(type.displayName) did not finish inside the expected animation window."
            )
        }

        activeInteractions[trace.id] = ActiveDiagnosticInteraction(trace: trace, timeoutTask: timeoutTask)
        activeInteractionCount = activeInteractions.count
        recordEvent(
            "interaction.start",
            detail: "\(type.displayName) started on \(page)",
            track: track,
            metrics: traceMetrics
        )
        return trace.id
    }

    public func completeInteraction(
        _ id: UUID?,
        status: DiagnosticInteractionStatus = .completed,
        detail: String? = nil,
        metrics: [String: Double] = [:],
        evidence: [String: String] = [:]
    ) {
        guard isEnabled, let id, var active = activeInteractions.removeValue(forKey: id) else { return }
        active.timeoutTask?.cancel()

        let completedAt = Date()
        active.trace.completedAt = completedAt
        active.trace.status = status
        active.trace.metrics["durationMs"] = completedAt.timeIntervalSince(active.trace.startedAt) * 1000
        merge(metrics, into: &active.trace.metrics)
        merge(evidence, into: &active.trace.evidence)

        interactions.insert(active.trace, at: 0)
        activeInteractionCount = activeInteractions.count
        recordEvent(
            "interaction.\(status.rawValue)",
            detail: detail ?? "\(active.trace.type.displayName) \(status.rawValue)",
            track: active.trace.track,
            metrics: active.trace.metrics
        )
        recordInteractionIncidentIfNeeded(active.trace, detail: detail)
        trimBuffers()
    }

    public func recordLyricsFetchStarted(track: DiagnosticTrackContext, forceRefresh: Bool) {
        guard isEnabled else { return }
        let key = lyricsKey(for: track)
        lyricsFetchStarts[key] = Date()
        recordEvent(
            "lyrics.fetch.start",
            detail: forceRefresh ? "Manual/forced lyrics fetch started" : "Lyrics fetch started",
            track: track,
            metrics: ["duration": track.duration]
        )
    }

    public func recordLyricsFetchFinished(
        track: DiagnosticTrackContext,
        source: String?,
        score: Double?,
        lineCount: Int,
        isUnsynced: Bool,
        hadSourceTranslation: Bool
    ) {
        guard isEnabled else { return }
        let key = lyricsKey(for: track)
        let elapsed = Date().timeIntervalSince(lyricsFetchStarts[key] ?? Date())
        lyricsFetchStarts.removeValue(forKey: key)
        updateBaseline("lyrics.fetch.seconds", value: elapsed)

        var metrics: [String: Double] = [
            "fetchSeconds": elapsed,
            "lineCount": Double(lineCount),
            "isUnsynced": isUnsynced ? 1 : 0,
            "hasSourceTranslation": hadSourceTranslation ? 1 : 0
        ]
        if let score { metrics["score"] = score }

        recordEvent(
            "lyrics.fetch.finish",
            detail: source.map { "Selected \($0)" } ?? "Lyrics fetch finished",
            track: track,
            metrics: metrics
        )

        if elapsed > 3.0 {
            recordIncident(
                category: .lyricsSlowFetch,
                severity: elapsed > 6.0 ? .critical : .warning,
                title: "Slow lyrics fetch",
                detail: "Lyrics took \(formatSeconds(elapsed)) to load.",
                track: track,
                metrics: metrics,
                evidence: ["source": source ?? "unknown"]
            )
        }

        if isUnsynced || (score ?? 100) < 30 {
            recordIncident(
                category: .lyricsFallbackChurn,
                severity: .warning,
                title: "Low-confidence lyrics result",
                detail: "The selected lyrics result was unsynced or low confidence.",
                track: track,
                metrics: metrics,
                evidence: ["source": source ?? "unknown"]
            )
        }
    }

    public func recordLyricsFetchMiss(track: DiagnosticTrackContext, resultCount: Int) {
        guard isEnabled else { return }
        let key = lyricsKey(for: track)
        let elapsed = Date().timeIntervalSince(lyricsFetchStarts[key] ?? Date())
        lyricsFetchStarts.removeValue(forKey: key)
        recordIncident(
            category: .lyricsFallbackChurn,
            severity: .warning,
            title: "Lyrics search returned no trusted result",
            detail: "No trusted lyrics were selected after \(formatSeconds(elapsed)).",
            track: track,
            metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)]
        )
    }

    public func recordFrameTick(delta: TimeInterval, page: String) {
        guard isEnabled else { return }
        updateBaseline("frame.delta.ms", value: delta * 1000)
        updateActiveInteractions { trace in
            incrementMetric("frameSampleCount", in: &trace.metrics)
            maximizeMetric("maxFrameDeltaMs", value: delta * 1000, in: &trace.metrics)
            trace.evidence["latestFramePage"] = page
            if page == "lyrics" {
                incrementMetric("lyricsFrameSampleCount", in: &trace.metrics)
            }
            if delta > 0.125 {
                incrementMetric("frameStallCount", in: &trace.metrics)
                trace.evidence["latestFrameStallPage"] = page
            }
        }
        guard delta > 0.125 else { return }
        recordIncident(
            category: .uiFrameStall,
            severity: delta > 0.250 ? .critical : .warning,
            title: "UI frame stall",
            detail: "\(page) frame interval reached \(formatMilliseconds(delta)).",
            metrics: ["deltaMs": delta * 1000],
            evidence: ["page": page]
        )
    }

    public func recordLyricsLineMotionSamples(_ samples: [DiagnosticLyricLineMotionSample]) {
        guard isEnabled, !samples.isEmpty else { return }

        var enriched: [DiagnosticLyricLineMotionSample] = []
        enriched.reserveCapacity(samples.count)
        for sample in samples {
            var next = sample
            let key = lyricLineMotionKey(for: next)
            if let previous = previousLyricLineMotionSamples[key] {
                let dt = next.timestamp.timeIntervalSince(previous.timestamp)
                if dt > 0.001 {
                    next.velocityY = (next.renderedMidY - previous.renderedMidY) / dt
                }
            }
            previousLyricLineMotionSamples[key] = (next.timestamp, next.renderedMidY)
            enriched.append(next)
        }

        lyricLineMotionSamples.insert(contentsOf: enriched.reversed(), at: 0)
        if lyricLineMotionSamples.count > maxLyricLineMotionSamples {
            lyricLineMotionSamples.removeLast(lyricLineMotionSamples.count - maxLyricLineMotionSamples)
        }

        let maxTargetError = enriched.map { abs($0.targetErrorY) }.max() ?? 0
        let maxInterLineError = enriched.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
        let maxVelocity = enriched.map { abs($0.velocityY) }.max() ?? 0
        updateBaseline("lyrics.lineMotion.targetError.pt", value: maxTargetError)
        updateBaseline("lyrics.lineMotion.interLineError.pt", value: maxInterLineError)
        updateBaseline("lyrics.lineMotion.velocity.ptPerSec", value: maxVelocity)

        updateActiveInteractions { trace in
            incrementMetric("lyricsLineMotionSampleCount", by: Double(enriched.count), in: &trace.metrics)
            maximizeMetric("maxLyricLineMotionTargetErrorPt", value: maxTargetError, in: &trace.metrics)
            maximizeMetric("maxLyricLineMotionInterLineErrorPt", value: maxInterLineError, in: &trace.metrics)
            maximizeMetric("maxLyricLineMotionVelocityPtPerSec", value: maxVelocity, in: &trace.metrics)
        }

        writeLiveLyricLineMotionSamples(enriched)
        recordLyricLineMotionIncidentIfNeeded(enriched)
        trimBuffers()
    }

    public func recordScriptingBridgeTiming(
        operation: String,
        queueWait: TimeInterval,
        readTime: TimeInterval,
        timedOut: Bool
    ) {
        guard isEnabled else { return }
        updateBaseline("scriptingBridge.queueWait.ms", value: queueWait * 1000)
        updateBaseline("scriptingBridge.read.ms", value: readTime * 1000)
        updateActiveInteractions { trace in
            incrementMetric("scriptingBridgeSampleCount", in: &trace.metrics)
            maximizeMetric("maxScriptingBridgeQueueWaitMs", value: queueWait * 1000, in: &trace.metrics)
            maximizeMetric("maxScriptingBridgeReadMs", value: readTime * 1000, in: &trace.metrics)
            trace.evidence["latestScriptingBridgeOperation"] = operation
            if timedOut {
                incrementMetric("scriptingBridgeTimeoutCount", in: &trace.metrics)
            }
        }

        if timedOut {
            recordIncident(
                category: .scriptingBridgeTimeout,
                severity: .critical,
                title: "ScriptingBridge timeout",
                detail: "\(operation) timed out while reading Music.app.",
                metrics: ["queueWaitMs": queueWait * 1000, "readMs": readTime * 1000],
                evidence: ["operation": operation]
            )
            return
        }

        guard queueWait > 0.25 || readTime > 0.10 else { return }
        recordIncident(
            category: queueWait > 0.25 ? .scriptingBridgeBacklog : .scriptingBridgeLatency,
            severity: queueWait > 1.0 || readTime > 0.5 ? .critical : .warning,
            title: queueWait > 0.25 ? "ScriptingBridge queue backlog" : "ScriptingBridge slow response",
            detail: "\(operation) waited \(formatMilliseconds(queueWait)) and read in \(formatMilliseconds(readTime)).",
            metrics: ["queueWaitMs": queueWait * 1000, "readMs": readTime * 1000],
            evidence: ["operation": operation]
        )
    }

    @discardableResult
    public func recordManualReport(
        symptom: DiagnosticUserSymptom,
        note: String,
        track: DiagnosticTrackContext,
        mediaAttachments: [URL] = []
    ) throws -> URL {
        let resolvedTrack = bestAvailableTrackContext(preferred: track)
        recordIncident(
            category: .lyricsManualReport,
            severity: .warning,
            title: "Manual report: \(symptom.rawValue)",
            detail: note.isEmpty ? "User reported \(symptom.rawValue)." : note,
            automaticallyDetected: false,
            userSymptom: symptom,
            track: resolvedTrack.track,
            evidence: resolvedTrack.evidence
        )
        return try exportReportBundle(userSymptom: symptom, userNote: note, track: resolvedTrack.track, mediaAttachments: mediaAttachments)
    }

    @discardableResult
    public func exportReportBundle(
        userSymptom: DiagnosticUserSymptom?,
        userNote: String,
        track: DiagnosticTrackContext?,
        mediaAttachments: [URL] = []
    ) throws -> URL {
        guard isEnabled else {
            throw DiagnosticsError.disabled
        }

        let root = try diagnosticsReportsDirectory()
        let stamp = Self.reportDateFormatter.string(from: Date())
        let reportDir = root.appendingPathComponent("nanopod-diagnostics-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDir, withIntermediateDirectories: true)

        let copiedMedia = try copyMediaAttachments(mediaAttachments, to: reportDir)
        let resolvedTrack = bestAvailableTrackContext(preferred: track)
        let manifest = DiagnosticReportManifest(
            generatedAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            sessionID: sessionID,
            userSymptom: userSymptom,
            userNote: userNote,
            track: resolvedTrack.track,
            incidents: incidents,
            events: events,
            interactions: interactions,
            lyricLineMotionSamples: lyricLineMotionSamples,
            baseline: baselineStats.mapValues(\.average),
            mediaAttachmentNames: copiedMedia
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: reportDir.appendingPathComponent("report.json"))

        try summaryMarkdown(for: manifest).write(
            to: reportDir.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
        try performanceCSV().write(
            to: reportDir.appendingPathComponent("performance_samples.csv"),
            atomically: true,
            encoding: .utf8
        )
        try lyricLineMotionCSV(samples: lyricLineMotionSamples.reversed()).write(
            to: reportDir.appendingPathComponent("lyrics_line_motion_samples.csv"),
            atomically: true,
            encoding: .utf8
        )
        if let logData = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/nanopod_debug.log")) {
            try logData.write(to: reportDir.appendingPathComponent("nanopod_debug.log"))
        }

        lastExportURL = reportDir
        return reportDir
    }

    private func startSessionIfNeeded() {
        if healthSampler == nil {
            healthSampler = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.sampleProcessHealth()
                }
            }
        }
        recordEvent("diagnostics.session.start", detail: "Owner diagnostics enabled")
    }

    private func bestAvailableTrackContext(
        preferred: DiagnosticTrackContext?
    ) -> (track: DiagnosticTrackContext?, evidence: [String: String]) {
        if let preferred, preferred.hasCredibleIdentity {
            return (preferred, ["trackContextSource": "provided"])
        }

        if let recentEventTrack = events.lazy.compactMap(\.track).first(where: { $0.hasCredibleIdentity }) {
            var evidence = ["trackContextSource": "recentEvent"]
            if let preferred {
                evidence["discardedTrackContext"] = "\(preferred.title) / \(preferred.artist) / \(preferred.album)"
            }
            return (recentEventTrack, evidence)
        }

        if let recentIncidentTrack = incidents.lazy.compactMap(\.track).first(where: { $0.hasCredibleIdentity }) {
            var evidence = ["trackContextSource": "recentIncident"]
            if let preferred {
                evidence["discardedTrackContext"] = "\(preferred.title) / \(preferred.artist) / \(preferred.album)"
            }
            return (recentIncidentTrack, evidence)
        }

        if let recentInteractionTrack = interactions.lazy.compactMap(\.track).first(where: { $0.hasCredibleIdentity }) {
            var evidence = ["trackContextSource": "recentInteraction"]
            if let preferred {
                evidence["discardedTrackContext"] = "\(preferred.title) / \(preferred.artist) / \(preferred.album)"
            }
            return (recentInteractionTrack, evidence)
        }

        return (preferred, ["trackContextSource": preferred == nil ? "missing" : "providedUnverified"])
    }

    private func recordIncident(
        category: DiagnosticIncidentCategory,
        severity: DiagnosticSeverity,
        title: String,
        detail: String,
        automaticallyDetected: Bool = true,
        userSymptom: DiagnosticUserSymptom? = nil,
        track: DiagnosticTrackContext? = nil,
        metrics: [String: Double] = [:],
        evidence: [String: String] = [:]
    ) {
        guard isEnabled else { return }
        let incident = DiagnosticIncident(
            category: category,
            severity: severity,
            title: title,
            detail: detail,
            automaticallyDetected: automaticallyDetected,
            userSymptom: userSymptom,
            track: track,
            metrics: metrics,
            evidence: evidence
        )
        incidents.insert(incident, at: 0)
        if let severe = severeOrRepeatedIssue {
            lastWarning = severe
        }
        trimBuffers()
    }

    private func interruptOverlappingInteractions(type: DiagnosticInteractionType, page: String) {
        let overlapping = activeInteractions.values
            .map(\.trace)
            .filter { isOverlappingInteraction($0, nextType: type, nextPage: page) }
            .map(\.id)
        for id in overlapping {
            completeInteraction(
                id,
                status: .interrupted,
                detail: "Interaction was replaced before its animation window completed.",
                evidence: ["replacementType": type.rawValue, "replacementPage": page]
            )
        }
    }

    private func isOverlappingInteraction(
        _ trace: DiagnosticInteractionTrace,
        nextType: DiagnosticInteractionType,
        nextPage: String
    ) -> Bool {
        switch (trace.type, nextType) {
        case (.nextTrack, .nextTrack),
             (.nextTrack, .previousTrack),
             (.previousTrack, .nextTrack),
             (.previousTrack, .previousTrack),
             (.pageSwitch, .pageSwitch):
            return true
        default:
            return trace.page == nextPage && Date().timeIntervalSince(trace.startedAt) < max(trace.expectedDuration, 0.3)
        }
    }

    private func updateActiveInteractions(_ update: (inout DiagnosticInteractionTrace) -> Void) {
        guard !activeInteractions.isEmpty else { return }
        for id in Array(activeInteractions.keys) {
            guard var active = activeInteractions[id] else { continue }
            update(&active.trace)
            activeInteractions[id] = active
        }
    }

    private func recordInteractionIncidentIfNeeded(_ trace: DiagnosticInteractionTrace, detail: String?) {
        let durationMs = trace.metrics["durationMs"] ?? 0
        let expectedMs = trace.metrics["expectedDurationMs"] ?? trace.expectedDuration * 1000
        let frameStalls = trace.metrics["frameStallCount"] ?? 0
        let maxFrameDelta = trace.metrics["maxFrameDeltaMs"] ?? 0
        let bridgeTimeouts = trace.metrics["scriptingBridgeTimeoutCount"] ?? 0
        let bridgeQueueWait = trace.metrics["maxScriptingBridgeQueueWaitMs"] ?? 0
        let bridgeRead = trace.metrics["maxScriptingBridgeReadMs"] ?? 0
        let maxCPU = trace.metrics["maxCPUPercent"] ?? 0
        let isLyricsPage = trace.page == "lyrics" || trace.evidence["toPage"] == "lyrics"

        if trace.status == .interrupted || trace.status == .timedOut {
            recordIncident(
                category: .uiAnimationIncomplete,
                severity: trace.status == .timedOut ? .critical : .warning,
                title: "\(trace.type.displayName) animation did not complete",
                detail: detail ?? "The interaction ended with status \(trace.status.rawValue).",
                track: trace.track,
                metrics: trace.metrics,
                evidence: trace.evidence.merging([
                    "interactionID": trace.id.uuidString,
                    "interactionType": trace.type.rawValue,
                    "page": trace.page
                ]) { current, _ in current }
            )
            return
        }

        let isSlow = durationMs > expectedMs + 250
        let hasFrameIssue = frameStalls > 0 || maxFrameDelta > 125
        let hasBridgeIssue = bridgeTimeouts > 0 || bridgeQueueWait > 250 || bridgeRead > 100
        let hasCPUIssue = maxCPU > 70
        guard isSlow || hasFrameIssue || hasBridgeIssue || hasCPUIssue else { return }

        let severity: DiagnosticSeverity = (durationMs > expectedMs + 600 || maxFrameDelta > 250 || bridgeTimeouts > 0 || maxCPU > 120)
            ? .critical
            : .warning
        var reasons: [String] = []
        if isSlow { reasons.append("animation window was late") }
        if hasFrameIssue { reasons.append("frame pacing was uneven") }
        if hasBridgeIssue { reasons.append("ScriptingBridge work overlapped") }
        if hasCPUIssue { reasons.append("CPU was high") }

        recordIncident(
            category: isLyricsPage ? .lyricsPagePerformance : .uiInteractionSlow,
            severity: severity,
            title: "\(trace.type.displayName) interaction was not smooth",
            detail: reasons.joined(separator: ", "),
            track: trace.track,
            metrics: trace.metrics,
            evidence: trace.evidence.merging([
                "interactionID": trace.id.uuidString,
                "interactionType": trace.type.rawValue,
                "page": trace.page
            ]) { current, _ in current }
        )
    }

    private func merge(_ source: [String: Double], into destination: inout [String: Double]) {
        for (key, value) in source {
            destination[key] = value
        }
    }

    private func merge(_ source: [String: String], into destination: inout [String: String]) {
        for (key, value) in source {
            destination[key] = value
        }
    }

    private func incrementMetric(_ key: String, by amount: Double = 1, in metrics: inout [String: Double]) {
        metrics[key, default: 0] += amount
    }

    private func maximizeMetric(_ key: String, value: Double, in metrics: inout [String: Double]) {
        metrics[key] = max(metrics[key] ?? value, value)
    }

    private func trimBuffers() {
        let cutoff = Date().addingTimeInterval(-retention)
        events.removeAll { $0.timestamp < cutoff }
        incidents.removeAll { $0.timestamp < cutoff }
        interactions.removeAll { $0.startedAt < cutoff }
        lyricLineMotionSamples.removeAll { $0.timestamp < cutoff }
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        if incidents.count > maxIncidents {
            incidents.removeLast(incidents.count - maxIncidents)
        }
        if interactions.count > maxInteractions {
            interactions.removeLast(interactions.count - maxInteractions)
        }
        if lyricLineMotionSamples.count > maxLyricLineMotionSamples {
            lyricLineMotionSamples.removeLast(lyricLineMotionSamples.count - maxLyricLineMotionSamples)
        }
    }

    private func updateBaseline(_ key: String, value: Double) {
        var stat = baselineStats[key] ?? RunningStat()
        stat.add(value)
        baselineStats[key] = stat
    }

    private func sampleProcessHealth() {
        guard isEnabled else { return }

        let cpu = currentProcessCPUPercent()
        let rss = currentResidentMemoryMB()
        var metrics: [String: Double] = [:]

        if let cpu {
            metrics["cpuPercent"] = cpu
            updateBaseline("process.cpu.percent", value: cpu)
        }
        if let rss {
            metrics["rssMB"] = rss
            updateBaseline("process.rss.mb", value: rss)
        }
        updateActiveInteractions { trace in
            if let cpu {
                maximizeMetric("maxCPUPercent", value: cpu, in: &trace.metrics)
            }
            if let rss {
                maximizeMetric("maxRSSMB", value: rss, in: &trace.metrics)
            }
        }

        guard !metrics.isEmpty else { return }
        recordEvent("process.health.sample", detail: "CPU/RSS sample", metrics: metrics)

        if let cpu, cpu > 70 {
            recordIncident(
                category: .highCPU,
                severity: cpu > 120 ? .critical : .warning,
                title: "High CPU detected",
                detail: "Process CPU reached \(String(format: "%.0f", cpu))%.",
                metrics: metrics
            )
        }
        if let rss, rss > 600 {
            recordIncident(
                category: .memorySpike,
                severity: rss > 900 ? .critical : .warning,
                title: "Memory spike detected",
                detail: "Resident memory reached \(String(format: "%.0f", rss)) MB.",
                metrics: metrics
            )
        }
    }

    private func currentResidentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    private func currentProcessCPUPercent() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else {
            return nil
        }
        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    private func diagnosticsReportsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func copyMediaAttachments(_ urls: [URL], to reportDir: URL) throws -> [String] {
        guard !urls.isEmpty else { return [] }
        let mediaDir = reportDir.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        var names: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let destination = mediaDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            names.append("media/\(name)")
        }
        return names
    }

    private func summaryMarkdown(for report: DiagnosticReportManifest) -> String {
        var lines: [String] = [
            "# nanoPod Diagnostics Report",
            "",
            "- Generated: \(Self.displayDateFormatter.string(from: report.generatedAt))",
            "- App: \(report.appVersion) (\(report.buildVersion))",
            "- OS: \(report.osVersion)",
            "- Session: \(report.sessionID.uuidString)",
            "- User symptom: \(report.userSymptom?.rawValue ?? "none")",
            "- Note: \(report.userNote.isEmpty ? "none" : report.userNote)",
            ""
        ]
        if let track = report.track {
            lines.append("## Track")
            lines.append("")
            lines.append("- Title: \(track.title)")
            lines.append("- Artist: \(track.artist)")
            lines.append("- Album: \(track.album)")
            lines.append("- Duration: \(String(format: "%.1f", track.duration))s")
            lines.append("- Playback time: \(track.playbackTime.map { String(format: "%.1f", $0) + "s" } ?? "unknown")")
            lines.append("")
        }
        lines.append("## Recent Incidents")
        lines.append("")
        if report.incidents.isEmpty {
            lines.append("No incidents captured.")
        } else {
            for incident in report.incidents.prefix(20) {
                lines.append("- [\(incident.severity.rawValue)] \(incident.category.rawValue): \(incident.title) - \(incident.detail)")
            }
        }
        lines.append("")
        lines.append("## Recent Interactions")
        lines.append("")
        if report.interactions.isEmpty {
            lines.append("No interaction traces captured.")
        } else {
            for interaction in report.interactions.prefix(20) {
                let duration = interaction.metrics["durationMs"].map { "\(String(format: "%.0f", $0))ms" } ?? "open"
                let maxFrame = interaction.metrics["maxFrameDeltaMs"].map { ", max frame \(String(format: "%.0f", $0))ms" } ?? ""
                lines.append("- [\(interaction.status.rawValue)] \(interaction.type.rawValue) on \(interaction.page): \(duration)\(maxFrame)")
            }
        }
        lines.append("")
        lines.append("## Lyric Line Motion")
        lines.append("")
        if report.lyricLineMotionSamples.isEmpty {
            lines.append("No per-line motion samples captured.")
        } else {
            let maxTargetError = report.lyricLineMotionSamples.map { abs($0.targetErrorY) }.max() ?? 0
            let maxInterLineError = report.lyricLineMotionSamples.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
            let maxVelocity = report.lyricLineMotionSamples.map { abs($0.velocityY) }.max() ?? 0
            lines.append("- Samples: \(report.lyricLineMotionSamples.count)")
            lines.append("- Max target error: \(String(format: "%.1f", maxTargetError))pt")
            lines.append("- Max inter-line spacing error: \(String(format: "%.1f", maxInterLineError))pt")
            lines.append("- Max observed line velocity: \(String(format: "%.1f", maxVelocity))pt/s")
        }
        lines.append("")
        lines.append("## Baseline")
        lines.append("")
        if report.baseline.isEmpty {
            lines.append("No baseline samples captured.")
        } else {
            for (key, value) in report.baseline.sorted(by: { $0.key < $1.key }) {
                lines.append("- \(key): \(String(format: "%.2f", value))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func performanceCSV() -> String {
        var rows = ["timestamp,name,detail,metrics"]
        for event in events.reversed() {
            let metrics = event.metrics
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
                .joined(separator: ";")
            rows.append("\(Self.csvDateFormatter.string(from: event.timestamp)),\(csv(event.name)),\(csv(event.detail)),\(csv(metrics))")
        }
        for interaction in interactions.reversed() {
            let metrics = interaction.metrics
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key)=\(String(format: "%.3f", $0.value))" }
                .joined(separator: ";")
            rows.append("\(Self.csvDateFormatter.string(from: interaction.startedAt)),\(csv("interaction.\(interaction.type.rawValue)")),\(csv("\(interaction.status.rawValue) on \(interaction.page)")),\(csv(metrics))")
        }
        return rows.joined(separator: "\n")
    }

    private func lyricLineMotionCSV<S: Sequence>(samples: S) -> String where S.Element == DiagnosticLyricLineMotionSample {
        var rows = [
            "timestamp,page,trackTitle,trackArtist,lineIndex,lineID,lineStartTime,lineEndTime,playbackTime,activeIndex,displayIndex,targetIndex,renderedMinY,renderedMidY,renderedHeight,targetMinY,targetMidY,targetErrorY,velocityY,observedInterLineDeltaY,expectedInterLineDeltaY,interLineDeltaErrorY,waveOffsetY,manualScrollOffsetY,isManualScrolling,isInitialMotionSuppressed"
        ]
        for sample in samples {
            rows.append([
                Self.csvDateFormatter.string(from: sample.timestamp),
                csv(sample.page),
                csv(sample.trackTitle),
                csv(sample.trackArtist),
                "\(sample.lineIndex)",
                csv(sample.lineID),
                csvNumber(sample.lineStartTime),
                csvNumber(sample.lineEndTime),
                csvNumber(sample.playbackTime),
                "\(sample.activeIndex)",
                "\(sample.displayIndex)",
                "\(sample.targetIndex)",
                csvNumber(sample.renderedMinY),
                csvNumber(sample.renderedMidY),
                csvNumber(sample.renderedHeight),
                csvNumber(sample.targetMinY),
                csvNumber(sample.targetMidY),
                csvNumber(sample.targetErrorY),
                csvNumber(sample.velocityY),
                csvNumber(sample.observedInterLineDeltaY),
                csvNumber(sample.expectedInterLineDeltaY),
                csvNumber(sample.interLineDeltaErrorY),
                csvNumber(sample.waveOffsetY),
                csvNumber(sample.manualScrollOffsetY),
                sample.isManualScrolling ? "1" : "0",
                sample.isInitialMotionSuppressed ? "1" : "0"
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func writeLiveLyricLineMotionSamples(_ samples: [DiagnosticLyricLineMotionSample]) {
        guard !samples.isEmpty else { return }
        do {
            let url = try liveLyricLineMotionSamplesURL()
            let fileExists = FileManager.default.fileExists(atPath: url.path)
            if !fileExists {
                try lyricLineMotionCSV(samples: []).write(to: url, atomically: true, encoding: .utf8)
            }
            let rows = samples.map { sample in
                [
                    Self.csvDateFormatter.string(from: sample.timestamp),
                    csv(sample.page),
                    csv(sample.trackTitle),
                    csv(sample.trackArtist),
                    "\(sample.lineIndex)",
                    csv(sample.lineID),
                    csvNumber(sample.lineStartTime),
                    csvNumber(sample.lineEndTime),
                    csvNumber(sample.playbackTime),
                    "\(sample.activeIndex)",
                    "\(sample.displayIndex)",
                    "\(sample.targetIndex)",
                    csvNumber(sample.renderedMinY),
                    csvNumber(sample.renderedMidY),
                    csvNumber(sample.renderedHeight),
                    csvNumber(sample.targetMinY),
                    csvNumber(sample.targetMidY),
                    csvNumber(sample.targetErrorY),
                    csvNumber(sample.velocityY),
                    csvNumber(sample.observedInterLineDeltaY),
                    csvNumber(sample.expectedInterLineDeltaY),
                    csvNumber(sample.interLineDeltaErrorY),
                    csvNumber(sample.waveOffsetY),
                    csvNumber(sample.manualScrollOffsetY),
                    sample.isManualScrolling ? "1" : "0",
                    sample.isInitialMotionSuppressed ? "1" : "0"
                ].joined(separator: ",")
            }.joined(separator: "\n") + "\n"
            if let data = rows.data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            }
        } catch {
            recordEvent("diagnostics.liveMotionWriteFailed", detail: error.localizedDescription)
        }
    }

    private func recordLyricLineMotionIncidentIfNeeded(_ samples: [DiagnosticLyricLineMotionSample]) {
        let stableSamples = samples.filter { !$0.isManualScrolling && !$0.isInitialMotionSuppressed }
        guard !stableSamples.isEmpty else { return }

        let now = Date()
        if let lastLyricLineMotionIncidentAt,
           now.timeIntervalSince(lastLyricLineMotionIncidentAt) < 3.0 {
            return
        }

        let maxTargetError = stableSamples.map { abs($0.targetErrorY) }.max() ?? 0
        let maxInterLineError = stableSamples.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
        let activeSample = stableSamples.first { $0.lineIndex == $0.activeIndex }
        let activeElapsed = activeSample.map { $0.playbackTime - $0.lineStartTime } ?? 0
        let laggedNearbyTargets = stableSamples.filter {
            abs($0.lineIndex - $0.activeIndex) <= 4 && $0.targetIndex != $0.activeIndex
        }.count

        let hasGeometryDrift = maxInterLineError > 18 || maxTargetError > 32
        let hasLateWaveTargets = activeElapsed > 0.35 && laggedNearbyTargets >= 4
        guard hasGeometryDrift || hasLateWaveTargets else { return }

        lastLyricLineMotionIncidentAt = now
        let sample = activeSample ?? stableSamples[0]
        recordIncident(
            category: .lyricsLineMotion,
            severity: maxInterLineError > 28 || maxTargetError > 48 ? .critical : .warning,
            title: "Lyrics line motion drift",
            detail: "Rendered lyric lines diverged from their target motion during playback.",
            metrics: [
                "maxTargetErrorPt": maxTargetError,
                "maxInterLineErrorPt": maxInterLineError,
                "laggedNearbyTargetCount": Double(laggedNearbyTargets),
                "activeLineElapsedMs": activeElapsed * 1000
            ],
            evidence: [
                "track": "\(sample.trackTitle) / \(sample.trackArtist)",
                "activeIndex": "\(sample.activeIndex)",
                "displayIndex": "\(sample.displayIndex)",
                "targetIndex": "\(sample.targetIndex)",
                "page": sample.page
            ]
        )
    }

    private func liveLyricLineMotionSamplesURL() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lyrics_line_motion_samples.csv")
    }

    private func lyricLineMotionKey(for sample: DiagnosticLyricLineMotionSample) -> String {
        "\(sample.trackTitle)|\(sample.trackArtist)|\(sample.lineIndex)|\(sample.lineID)"
    }

    private func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func csvNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.4f", value)
    }

    private func lyricsKey(for track: DiagnosticTrackContext) -> String {
        "\(track.title.lowercased())|\(track.artist.lowercased())|\(Int(track.duration.rounded()))"
    }

    private func formatMilliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        "\(String(format: "%.1f", seconds))s"
    }

    private static let reportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let csvDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public enum DiagnosticsError: LocalizedError {
    case disabled

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Owner diagnostics are disabled."
        }
    }
}

private struct ActiveDiagnosticInteraction {
    var trace: DiagnosticInteractionTrace
    var timeoutTask: Task<Void, Never>?
}

private struct RunningStat: Codable, Equatable, Sendable {
    private(set) var count: Int = 0
    private(set) var total: Double = 0
    private(set) var max: Double = 0

    var average: Double {
        count > 0 ? total / Double(count) : 0
    }

    mutating func add(_ value: Double) {
        count += 1
        total += value
        max = Swift.max(max, value)
    }
}
