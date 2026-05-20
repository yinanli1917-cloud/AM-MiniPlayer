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
    case lyricsPartialTranslation
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

    fileprivate func matchesReportTrack(_ other: DiagnosticTrackContext) -> Bool {
        if let lhsID = persistentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           let rhsID = other.persistentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lhsID.isEmpty,
           !rhsID.isEmpty {
            return lhsID == rhsID
        }

        let lhsTitle = MetadataDiskCache.normalize(title)
        let rhsTitle = MetadataDiskCache.normalize(other.title)
        let lhsArtist = MetadataDiskCache.normalize(artist)
        let rhsArtist = MetadataDiskCache.normalize(other.artist)
        guard !lhsTitle.isEmpty, !rhsTitle.isEmpty, lhsTitle == rhsTitle else { return false }
        guard !lhsArtist.isEmpty, !rhsArtist.isEmpty, lhsArtist == rhsArtist else { return false }

        if duration > 0, other.duration > 0, abs(duration - other.duration) > 2.0 {
            return false
        }
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
    public private(set) var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample] = []
    @Published public private(set) var lyricLineMotionSampleCount: Int = 0
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
                if incidents.isEmpty, events.isEmpty, interactions.isEmpty, lyricLineMotionSamples.isEmpty {
                    restorePersistedSnapshotIfAvailable()
                }
                startSessionIfNeeded()
            } else {
                healthSampler?.invalidate()
                healthSampler = nil
                activeInteractions.values.forEach { $0.timeoutTask?.cancel() }
                activeInteractions.removeAll()
                activeInteractionCount = 0
                schedulePersistenceSave()
            }
        }
    }

    public let sessionID: UUID

    private var sessionStartedAt: Date
    private var lyricsFetchStarts: [String: Date] = [:]
    private var activeLyricsRefreshInteractions: [String: UUID] = [:]
    private var baselineStats: [String: RunningStat] = [:]
    private var activeInteractions: [UUID: ActiveDiagnosticInteraction] = [:]
    private var healthSampler: Timer?
    private let maxEvents = 300
    private let maxIncidents = 120
    private let maxInteractions = 120
    private let maxLyricLineMotionSamples = 2400
    private let standaloneFrameStallCoalesceWindow: TimeInterval = 60
    private let retention: TimeInterval = 24 * 60 * 60
    private var previousLyricLineMotionSamples: [String: (timestamp: Date, renderedMidY: Double)] = [:]
    private var lastLyricLineMotionActiveStateKey: String?
    private var lastLyricLineMotionActiveStateSince: Date?
    private var lastLyricLineMotionIncidentAt: Date?
    private var lastLyricLineMotionIncidentSignature: String?
    private var recentCPUSamples: [(timestamp: Date, cpu: Double)] = []
    private var lastHighCPUIncidentAt: Date?
    private var suppressStandaloneFrameStallsUntil: Date = .distantPast
    private var storageBaseDirectoryForTesting: URL?
    private var debugLogURLForTesting: URL?
    private var persistenceSaveTask: Task<Void, Never>?
    private var lastLyricLineMotionCountPublishAt: Date = .distantPast
    private let liveMotionWriteQueue = DispatchQueue(
        label: "com.nanopod.diagnostics.live-line-motion-writes",
        qos: .utility
    )

    private init() {
        self.isEnabled = Self.isOwnerDiagnosticsBuild && UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.sessionID = UUID()
        self.sessionStartedAt = Date()
        if isEnabled {
            restorePersistedSnapshotIfAvailable()
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

    public func clear(suppressImmediateStandaloneFrameStalls: Bool = false) {
        incidents.removeAll()
        events.removeAll()
        activeInteractions.values.forEach { $0.timeoutTask?.cancel() }
        activeInteractions.removeAll()
        interactions.removeAll()
        lyricLineMotionSamples.removeAll()
        lyricLineMotionSampleCount = 0
        previousLyricLineMotionSamples.removeAll()
        lastLyricLineMotionActiveStateKey = nil
        lastLyricLineMotionActiveStateSince = nil
        lastLyricLineMotionIncidentAt = nil
        lastLyricLineMotionIncidentSignature = nil
        recentCPUSamples.removeAll()
        lastHighCPUIncidentAt = nil
        suppressStandaloneFrameStallsUntil = suppressImmediateStandaloneFrameStalls
            ? Date().addingTimeInterval(1.5)
            : .distantPast
        activeInteractionCount = 0
        lyricsFetchStarts.removeAll()
        activeLyricsRefreshInteractions.removeAll()
        baselineStats.removeAll()
        lastExportURL = nil
        lastWarning = nil
        sessionStartedAt = Date()
        persistenceSaveTask?.cancel()
        persistenceSaveTask = nil
        removePersistedSnapshot()
        removeLiveLyricLineMotionSamples()
    }

    func setStorageBaseDirectoryForTesting(_ url: URL?) {
        storageBaseDirectoryForTesting = url
    }

    func setDebugLogURLForTesting(_ url: URL?) {
        debugLogURLForTesting = url
    }

    func flushPersistenceForTesting() {
        persistSnapshotSynchronously()
    }

    func simulateProcessRestartForTesting() {
        resetInMemoryBuffersForRestore()
        restorePersistedSnapshotIfAvailable()
    }

    func persistedSnapshotExistsForTesting() -> Bool {
        guard let url = try? diagnosticsStateSnapshotURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func currentAppBuildSignatureForTesting() -> String {
        Self.currentAppBuildSignature()
    }

    public func prepareForTermination() {
        guard isEnabled else { return }
        interruptActiveInteractionsForShutdown()
        trimBuffers()
        persistenceSaveTask?.cancel()
        persistenceSaveTask = nil
        persistSnapshotSynchronously()
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
        schedulePersistenceSave()
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
        schedulePersistenceSave()
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
        schedulePersistenceSave()
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
        if forceRefresh {
            activeLyricsRefreshInteractions[key] = beginInteraction(
                type: .lyricsRefresh,
                page: "lyrics",
                expectedDuration: 3.0,
                track: track,
                metrics: ["trackDuration": track.duration],
                evidence: ["trigger": "forceRefresh"]
            )
        }
    }

    public func recordLyricsFetchFinished(
        track: DiagnosticTrackContext,
        source: String?,
        score: Double?,
        lineCount: Int,
        isUnsynced: Bool,
        hadSourceTranslation: Bool,
        translationLineCount: Int = 0,
        translatableLineCount: Int = 0,
        missingTranslationLineCount: Int = 0,
        translationDisplayRequested: Bool = false
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
            "hasSourceTranslation": hadSourceTranslation ? 1 : 0,
            "translationLineCount": Double(translationLineCount),
            "translatableLineCount": Double(translatableLineCount),
            "missingTranslationLineCount": Double(missingTranslationLineCount),
            "translationCoverage": translatableLineCount > 0
                ? Double(translationLineCount) / Double(translatableLineCount)
                : 0
        ]
        if let score { metrics["score"] = score }

        recordEvent(
            "lyrics.fetch.finish",
            detail: source.map { "Selected \($0)" } ?? "Lyrics fetch finished",
            track: track,
            metrics: metrics
        )
        completeLyricsRefreshInteraction(
            key: key,
            track: track,
            detail: source.map { "Lyrics refresh selected \($0)." } ?? "Lyrics refresh finished.",
            metrics: metrics,
            evidence: ["source": source ?? "unknown"]
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

        if translationDisplayRequested && hadSourceTranslation && missingTranslationLineCount > 0 {
            recordIncident(
                category: .lyricsPartialTranslation,
                severity: .warning,
                title: "Source translation incomplete",
                detail: "The selected lyrics source translated \(translationLineCount)/\(max(translatableLineCount, 1)) visible lines.",
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
        let hasRejectedCandidates = resultCount > 0
        completeLyricsRefreshInteraction(
            key: key,
            track: track,
            detail: hasRejectedCandidates
                ? "Lyrics refresh ended without a trusted result."
                : "Lyrics refresh ended unresolved with no source candidates.",
            metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)],
            evidence: ["result": hasRejectedCandidates ? "miss" : "unresolved"]
        )
        recordIncident(
            category: .lyricsFallbackChurn,
            severity: hasRejectedCandidates ? .warning : .info,
            title: hasRejectedCandidates ? "Lyrics search returned no trusted result" : "Lyrics unresolved",
            detail: hasRejectedCandidates
                ? "No trusted lyrics were selected after \(formatSeconds(elapsed))."
                : "No trusted lyrics source was resolved after \(formatSeconds(elapsed)); this is not automatically treated as a regression.",
            track: track,
            metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)],
            evidence: ["result": hasRejectedCandidates ? "miss" : "unresolved"]
        )
    }

    private func completeLyricsRefreshInteraction(
        key: String,
        track: DiagnosticTrackContext,
        detail: String,
        metrics: [String: Double],
        evidence: [String: String]
    ) {
        guard let id = activeLyricsRefreshInteractions.removeValue(forKey: key) else { return }
        completeInteraction(
            id,
            detail: detail,
            metrics: metrics,
            evidence: evidence.merging(["pageAtFinish": "lyrics"]) { current, _ in current }
        )
    }

    public func recordFrameTick(delta: TimeInterval, page: String) {
        guard isEnabled else { return }
        updateBaseline("frame.delta.ms", value: delta * 1000)
        let hasActiveInteractions = !activeInteractions.isEmpty
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
        guard !hasActiveInteractions else { return }
        guard Date() >= suppressStandaloneFrameStallsUntil else { return }
        recordStandaloneFrameStall(page: page, delta: delta)
    }

    private func recordStandaloneFrameStall(page: String, delta: TimeInterval) {
        let pageName = page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : page
        let incoming = DiagnosticIncident(
            category: .uiFrameStall,
            severity: delta > 0.250 ? .critical : .warning,
            title: "UI frame stall",
            detail: "\(pageName) frame interval reached \(formatMilliseconds(delta)).",
            automaticallyDetected: true,
            metrics: ["deltaMs": delta * 1000],
            evidence: ["page": pageName]
        )

        guard let signature = standaloneFrameStallCoalesceSignature(for: incoming) else {
            recordIncident(
                category: incoming.category,
                severity: incoming.severity,
                title: incoming.title,
                detail: incoming.detail,
                metrics: incoming.metrics,
                evidence: incoming.evidence
            )
            return
        }

        if let index = incidents.firstIndex(where: { standaloneFrameStallCoalesceSignature(for: $0) == signature }) {
            let merged = mergeFrameStallIncident(incoming, into: incidents[index])
            incidents[index] = merged
            if merged.severity == .critical {
                lastWarning = merged
            } else if let severe = severeOrRepeatedIssue {
                lastWarning = severe
            }
            trimBuffers()
            schedulePersistenceSave()
            return
        }

        let normalized = normalizedFrameStallIncident(incoming, signature: signature)
        recordIncident(
            category: normalized.category,
            severity: normalized.severity,
            title: normalized.title,
            detail: normalized.detail,
            metrics: normalized.metrics,
            evidence: normalized.evidence
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
        updateLyricLineMotionSampleCount()

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
        scheduleHighFrequencyPersistenceSave()
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
        let reportGeneratedAt = Date()
        let reportIncidents = scopedIncidents(for: resolvedTrack.track)
        let reportEvents = scopedEvents(for: resolvedTrack.track)
        let reportInteractions = scopedInteractions(for: resolvedTrack.track)
        let reportLineMotionSamples = scopedLyricLineMotionSamples(for: resolvedTrack.track)
        let reportBaseline = scopedBaseline(
            for: resolvedTrack.track,
            lineMotionSamples: reportLineMotionSamples
        )
        let manifest = DiagnosticReportManifest(
            generatedAt: reportGeneratedAt,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            buildVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            sessionID: sessionID,
            userSymptom: userSymptom,
            userNote: userNote,
            track: resolvedTrack.track,
            incidents: reportIncidents,
            events: reportEvents,
            interactions: reportInteractions,
            lyricLineMotionSamples: reportLineMotionSamples,
            baseline: reportBaseline,
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
        try performanceCSV(events: reportEvents, interactions: reportInteractions).write(
            to: reportDir.appendingPathComponent("performance_samples.csv"),
            atomically: true,
            encoding: .utf8
        )
        try lyricLineMotionCSV(samples: reportLineMotionSamples.reversed()).write(
            to: reportDir.appendingPathComponent("lyrics_line_motion_samples.csv"),
            atomically: true,
            encoding: .utf8
        )
        try writeDebugLogAttachment(to: reportDir)

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
        repairLiveLyricLineMotionCSVIfNeeded()
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

    private func scopedIncidents(for track: DiagnosticTrackContext?) -> [DiagnosticIncident] {
        guard let track, track.hasCredibleIdentity else { return incidents }
        return incidents.filter { incident in
            if let incidentTrack = incident.track {
                return incidentTrack.matchesReportTrack(track)
            }
            if let evidenceTrack = incident.evidence["track"], evidenceTrack.contains(" / ") {
                return evidenceTrackContext(evidenceTrack)?.matchesReportTrack(track) == true
            }
            if incident.category == .lyricsLineMotion {
                return false
            }
            return true
        }
    }

    private func scopedEvents(for track: DiagnosticTrackContext?) -> [DiagnosticEvent] {
        guard let track, track.hasCredibleIdentity else { return events }
        return events.filter { event in
            guard let eventTrack = event.track else { return true }
            return eventTrack.matchesReportTrack(track)
        }
    }

    private func scopedInteractions(for track: DiagnosticTrackContext?) -> [DiagnosticInteractionTrace] {
        guard let track, track.hasCredibleIdentity else { return interactions }
        return interactions.filter { interaction in
            guard let interactionTrack = interaction.track else { return true }
            return interactionTrack.matchesReportTrack(track)
        }
    }

    private func scopedLyricLineMotionSamples(for track: DiagnosticTrackContext?) -> [DiagnosticLyricLineMotionSample] {
        guard let track, track.hasCredibleIdentity else { return lyricLineMotionSamples }
        return lyricLineMotionSamples.filter { sample in
            MetadataDiskCache.normalize(sample.trackTitle) == MetadataDiskCache.normalize(track.title)
                && MetadataDiskCache.normalize(sample.trackArtist) == MetadataDiskCache.normalize(track.artist)
        }
    }

    private func scopedBaseline(
        for track: DiagnosticTrackContext?,
        lineMotionSamples reportLineMotionSamples: [DiagnosticLyricLineMotionSample]
    ) -> [String: Double] {
        var values = baselineStats.mapValues(\.average)
        guard track?.hasCredibleIdentity == true else { return values }

        for key in Array(values.keys) where key.hasPrefix("lyrics.lineMotion.") {
            values.removeValue(forKey: key)
        }
        guard !reportLineMotionSamples.isEmpty else { return values }

        values["lyrics.lineMotion.targetError.pt"] = average(reportLineMotionSamples.map { abs($0.targetErrorY) })
        values["lyrics.lineMotion.interLineError.pt"] = average(reportLineMotionSamples.compactMap { $0.interLineDeltaErrorY.map(abs) })
        values["lyrics.lineMotion.velocity.ptPerSec"] = average(reportLineMotionSamples.map { abs($0.velocityY) })
        return values
    }

    private func evidenceTrackContext(_ value: String) -> DiagnosticTrackContext? {
        let parts = value.components(separatedBy: " / ")
        guard parts.count >= 2, let artist = parts.last else { return nil }
        let title = parts.dropLast().joined(separator: " / ")
        return DiagnosticTrackContext(title: title, artist: artist, album: "", duration: 0)
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
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
        schedulePersistenceSave()
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
        let hasCPUIssue = maxCPU > 120
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
        normalizeLegacyHighCPUIncidents()
        coalesceStandaloneFrameStallIncidents()
        coalesceLyricLineMotionIncidents()
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
        updateLyricLineMotionSampleCount(force: true)
        refreshLastWarningAfterIncidentNormalization()
    }

    private func coalesceStandaloneFrameStallIncidents() {
        guard incidents.count > 1 else { return }

        var compacted: [DiagnosticIncident] = []
        var bucketIndexBySignature: [String: Int] = [:]
        compacted.reserveCapacity(incidents.count)

        for incident in incidents {
            guard let signature = standaloneFrameStallCoalesceSignature(for: incident) else {
                compacted.append(incident)
                continue
            }

            if let index = bucketIndexBySignature[signature] {
                compacted[index] = mergeFrameStallIncident(incident, into: compacted[index])
            } else {
                bucketIndexBySignature[signature] = compacted.count
                compacted.append(normalizedFrameStallIncident(incident, signature: signature))
            }
        }

        incidents = compacted
    }

    private func coalesceLyricLineMotionIncidents() {
        guard incidents.count > 1 else { return }

        var compacted: [DiagnosticIncident] = []
        var bucketIndexBySignature: [String: Int] = [:]
        compacted.reserveCapacity(incidents.count)

        for incident in incidents {
            guard let signature = lyricLineMotionCoalesceSignature(for: incident) else {
                compacted.append(incident)
                continue
            }

            if let index = bucketIndexBySignature[signature] {
                compacted[index] = mergeLyricLineMotionIncident(incident, into: compacted[index])
            } else {
                bucketIndexBySignature[signature] = compacted.count
                compacted.append(normalizedLyricLineMotionIncident(incident, signature: signature))
            }
        }

        incidents = compacted
    }

    private func refreshLastWarningAfterIncidentNormalization() {
        guard let lastWarning else { return }
        if let current = incidents.first(where: { $0.id == lastWarning.id }) {
            self.lastWarning = current
        } else {
            self.lastWarning = severeOrRepeatedIssue
        }
    }

    private func standaloneFrameStallCoalesceSignature(for incident: DiagnosticIncident) -> String? {
        guard incident.category == .uiFrameStall,
              incident.automaticallyDetected,
              incident.track == nil,
              incident.evidence["interactionID"] == nil else {
            return nil
        }

        let page = normalizedFrameStallPage(for: incident)
        let bucket = floor(incident.timestamp.timeIntervalSince1970 / standaloneFrameStallCoalesceWindow)
        return "uiFrameStall|\(page)|\(Int(bucket))"
    }

    private func normalizedFrameStallPage(for incident: DiagnosticIncident) -> String {
        let rawPage = incident.evidence["page"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawPage, !rawPage.isEmpty {
            return rawPage
        }
        return "unknown"
    }

    private func lyricLineMotionCoalesceSignature(for incident: DiagnosticIncident) -> String? {
        guard incident.category == .lyricsLineMotion,
              incident.automaticallyDetected else {
            return nil
        }

        if let track = incident.track, track.hasCredibleIdentity {
            return [
                "lyricsLineMotion",
                MetadataDiskCache.normalize(track.title),
                MetadataDiskCache.normalize(track.artist)
            ].joined(separator: "|")
        }
        if let evidenceTrack = incident.evidence["track"],
           let track = evidenceTrackContext(evidenceTrack),
           track.hasCredibleIdentity {
            return [
                "lyricsLineMotion",
                MetadataDiskCache.normalize(track.title),
                MetadataDiskCache.normalize(track.artist)
            ].joined(separator: "|")
        }
        return "lyricsLineMotion|unknown"
    }

    private func normalizedFrameStallIncident(
        _ incident: DiagnosticIncident,
        signature: String
    ) -> DiagnosticIncident {
        var normalized = incident
        normalized.metrics["occurrenceCount"] = max(normalized.metrics["occurrenceCount"] ?? 1, 1)
        let delta = normalized.metrics["deltaMs"] ?? normalized.metrics["maxDeltaMs"] ?? 0
        normalized.metrics["maxDeltaMs"] = max(delta, normalized.metrics["maxDeltaMs"] ?? 0)
        normalized.metrics["firstTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.metrics["lastTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.evidence["signature"] = signature
        normalized.evidence["coalescedWindowSeconds"] = "\(Int(standaloneFrameStallCoalesceWindow))"
        return normalized
    }

    private func mergeFrameStallIncident(
        _ incoming: DiagnosticIncident,
        into representative: DiagnosticIncident
    ) -> DiagnosticIncident {
        var merged = representative
        let incomingDelta = incoming.metrics["deltaMs"] ?? incoming.metrics["maxDeltaMs"] ?? 0
        let existingMaxDelta = merged.metrics["maxDeltaMs"] ?? merged.metrics["deltaMs"] ?? 0
        let maxDelta = max(existingMaxDelta, incomingDelta)
        let count = (merged.metrics["occurrenceCount"] ?? 1) + (incoming.metrics["occurrenceCount"] ?? 1)
        let firstTimestamp = min(
            merged.metrics["firstTimestampEpoch"] ?? merged.timestamp.timeIntervalSince1970,
            incoming.timestamp.timeIntervalSince1970
        )
        let lastTimestamp = max(
            merged.metrics["lastTimestampEpoch"] ?? merged.timestamp.timeIntervalSince1970,
            incoming.timestamp.timeIntervalSince1970
        )

        merged.metrics["occurrenceCount"] = count
        merged.metrics["deltaMs"] = maxDelta
        merged.metrics["maxDeltaMs"] = maxDelta
        merged.metrics["firstTimestampEpoch"] = firstTimestamp
        merged.metrics["lastTimestampEpoch"] = lastTimestamp
        if incoming.severity == .critical {
            merged.severity = .critical
        }
        let page = normalizedFrameStallPage(for: merged)
        if merged.evidence["signature"] == nil,
           let signature = standaloneFrameStallCoalesceSignature(for: merged) {
            merged.evidence["signature"] = signature
        }
        merged.evidence["coalescedWindowSeconds"] = "\(Int(standaloneFrameStallCoalesceWindow))"
        merged.title = "UI frame stall burst"
        merged.detail = "\(page) had \(Int(count)) standalone frame stalls in \(Int(standaloneFrameStallCoalesceWindow))s; max interval \(String(format: "%.0f", maxDelta))ms."
        return merged
    }

    private func normalizedLyricLineMotionIncident(
        _ incident: DiagnosticIncident,
        signature: String
    ) -> DiagnosticIncident {
        var normalized = incident
        normalized.metrics["occurrenceCount"] = max(normalized.metrics["occurrenceCount"] ?? 1, 1)
        normalized.metrics["firstTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.metrics["lastTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.evidence["signature"] = signature
        return normalized
    }

    private func mergeLyricLineMotionIncident(
        _ incoming: DiagnosticIncident,
        into representative: DiagnosticIncident
    ) -> DiagnosticIncident {
        var merged = representative
        let count = (merged.metrics["occurrenceCount"] ?? 1) + (incoming.metrics["occurrenceCount"] ?? 1)
        let firstTimestamp = min(
            merged.metrics["firstTimestampEpoch"] ?? merged.timestamp.timeIntervalSince1970,
            incoming.timestamp.timeIntervalSince1970
        )
        let lastTimestamp = max(
            merged.metrics["lastTimestampEpoch"] ?? merged.timestamp.timeIntervalSince1970,
            incoming.timestamp.timeIntervalSince1970
        )

        merged.metrics["occurrenceCount"] = count
        merged.metrics["firstTimestampEpoch"] = firstTimestamp
        merged.metrics["lastTimestampEpoch"] = lastTimestamp
        for key in [
            "maxTargetErrorPt",
            "maxInterLineErrorPt",
            "laggedNearbyTargetCount",
            "activeLineElapsedMs",
            "activeTargetLagged"
        ] {
            if let incomingValue = incoming.metrics[key] {
                merged.metrics[key] = max(merged.metrics[key] ?? incomingValue, incomingValue)
            }
        }
        if incoming.severity == .critical {
            merged.severity = .critical
        }
        if merged.evidence["signature"] == nil,
           let signature = lyricLineMotionCoalesceSignature(for: merged) {
            merged.evidence["signature"] = signature
        }
        let maxTarget = merged.metrics["maxTargetErrorPt"] ?? 0
        let maxInterLine = merged.metrics["maxInterLineErrorPt"] ?? 0
        merged.title = "Lyrics line motion drift burst"
        merged.detail = "\(Int(count)) line-motion drift samples for this track; max target error \(String(format: "%.0f", maxTarget))pt, max spacing error \(String(format: "%.0f", maxInterLine))pt."
        return merged
    }

    private func normalizeLegacyHighCPUIncidents() {
        for index in incidents.indices where incidents[index].category == .highCPU {
            guard incidents[index].metrics["maxRecentCPUPercent"] == nil else { continue }
            let currentCPU = incidents[index].metrics["cpuPercent"]
            let reportedCPU = highCPUPercentFromDetail(incidents[index].detail)
            guard let maxCPU = [currentCPU, reportedCPU].compactMap({ $0 }).max(), maxCPU > 0 else {
                continue
            }

            incidents[index].metrics["currentCPUPercent"] = currentCPU ?? maxCPU
            incidents[index].metrics["maxRecentCPUPercent"] = maxCPU
            incidents[index].metrics["cpuPercent"] = maxCPU
            incidents[index].metrics["highCPUSampleCount"] = incidents[index].metrics["highCPUSampleCount"] ?? 1
            incidents[index].evidence["migratedLegacyHighCPUMetrics"] = "true"
        }
    }

    private func highCPUPercentFromDetail(_ detail: String) -> Double? {
        let prefix = "Process CPU reached "
        guard detail.hasPrefix(prefix),
              let percentIndex = detail[prefix.endIndex...].firstIndex(of: "%") else {
            return nil
        }
        return Double(detail[prefix.endIndex..<percentIndex])
    }

    private func schedulePersistenceSave() {
        guard isEnabled else { return }
        guard persistenceSaveTask == nil else { return }
        persistenceSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.performScheduledPersistenceSave()
        }
    }

    private func scheduleHighFrequencyPersistenceSave() {
        guard isEnabled else { return }
        guard persistenceSaveTask == nil else { return }
        persistenceSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.performScheduledPersistenceSave()
        }
    }

    private func performScheduledPersistenceSave() {
        persistenceSaveTask = nil
        persistSnapshotImmediately()
    }

    private func persistSnapshotImmediately() {
        guard isEnabled else { return }
        let snapshot = makePersistenceSnapshot()
        guard let url = try? diagnosticsStateSnapshotURL() else { return }
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: [.atomic])
            } catch {
                // Persistence is best-effort local diagnostics state; avoid
                // recursively recording diagnostics while writing diagnostics.
            }
        }
    }

    private func persistSnapshotSynchronously() {
        guard isEnabled else { return }
        let snapshot = makePersistenceSnapshot()
        guard let url = try? diagnosticsStateSnapshotURL() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort on shutdown; do not block app termination on local diagnostics.
        }
    }

    private func restorePersistedSnapshotIfAvailable() {
        guard isEnabled else { return }
        guard let url = try? diagnosticsStateSnapshotURL(),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(DiagnosticPersistenceSnapshot.self, from: data) else { return }
        let currentBuildSignature = Self.currentAppBuildSignature()
        guard snapshot.appBuildSignature == currentBuildSignature else {
            resetInMemoryBuffersForRestore()
            removePersistedSnapshot()
            recordEvent(
                "diagnostics.session.resetForBuild",
                detail: "Dropped stale rolling diagnostics from a previous app build.",
                metrics: ["hadPreviousBuildSignature": snapshot.appBuildSignature == nil ? 0 : 1]
            )
            return
        }

        incidents = snapshot.incidents
        events = snapshot.events
        interactions = snapshot.interactions.map { trace in
            guard trace.status == .active else { return trace }
            var interrupted = trace
            interrupted.status = .interrupted
            interrupted.completedAt = snapshot.savedAt
            interrupted.evidence["restoredAfterRestart"] = "true"
            return interrupted
        }
        lyricLineMotionSamples = snapshot.lyricLineMotionSamples
        updateLyricLineMotionSampleCount(force: true)
        baselineStats = snapshot.baselineStats
        lastWarning = snapshot.lastWarning ?? severeOrRepeatedIssue
        if let lastExportPath = snapshot.lastExportPath {
            lastExportURL = URL(fileURLWithPath: lastExportPath)
        }

        trimBuffers()
        activeInteractions.values.forEach { $0.timeoutTask?.cancel() }
        activeInteractions.removeAll()
        activeInteractionCount = 0
        previousLyricLineMotionSamples.removeAll()
        persistSnapshotImmediately()
    }

    private func makePersistenceSnapshot() -> DiagnosticPersistenceSnapshot {
        DiagnosticPersistenceSnapshot(
            savedAt: Date(),
            sessionID: sessionID,
            sessionStartedAt: sessionStartedAt,
            appBuildSignature: Self.currentAppBuildSignature(),
            incidents: incidents,
            events: events,
            interactions: interactions + activeInteractions.values.map(\.trace),
            lyricLineMotionSamples: lyricLineMotionSamples,
            baselineStats: baselineStats,
            lastWarning: lastWarning,
            lastExportPath: lastExportURL?.path
        )
    }

    private static func currentAppBuildSignature() -> String {
        if let buildInfoURL = Bundle.main.url(forResource: "BuildInfo", withExtension: "txt"),
           let buildInfo = try? String(contentsOf: buildInfoURL, encoding: .utf8) {
            let trimmed = buildInfo.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "unknown-bundle"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown-version"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown-build"
        return "\(bundleID)|\(version)|\(build)|ownerDiagnostics=\(isOwnerDiagnosticsBuild)"
    }

    private func interruptActiveInteractionsForShutdown() {
        guard !activeInteractions.isEmpty else { return }
        let interruptedCount = activeInteractions.count
        let now = Date()
        for id in Array(activeInteractions.keys) {
            guard var active = activeInteractions.removeValue(forKey: id) else { continue }
            active.timeoutTask?.cancel()
            active.trace.completedAt = now
            active.trace.status = .interrupted
            active.trace.metrics["durationMs"] = now.timeIntervalSince(active.trace.startedAt) * 1000
            active.trace.evidence["shutdownFlush"] = "true"
            interactions.insert(active.trace, at: 0)
        }
        activeInteractionCount = 0
        events.insert(
            DiagnosticEvent(
                name: "diagnostics.session.flush",
                detail: "Persisted diagnostics before app termination.",
                metrics: ["interruptedInteractionCount": Double(interruptedCount)]
            ),
            at: 0
        )
    }

    private func resetInMemoryBuffersForRestore() {
        incidents.removeAll()
        events.removeAll()
        interactions.removeAll()
        lyricLineMotionSamples.removeAll()
        lyricLineMotionSampleCount = 0
        previousLyricLineMotionSamples.removeAll()
        baselineStats.removeAll()
        activeInteractions.values.forEach { $0.timeoutTask?.cancel() }
        activeInteractions.removeAll()
        activeLyricsRefreshInteractions.removeAll()
        activeInteractionCount = 0
        lastExportURL = nil
        lastWarning = nil
    }

    private func removePersistedSnapshot() {
        guard let url = try? diagnosticsStateSnapshotURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeLiveLyricLineMotionSamples() {
        guard let url = try? liveLyricLineMotionSamplesURL() else { return }
        liveMotionWriteQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func updateLyricLineMotionSampleCount(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastLyricLineMotionCountPublishAt) >= 0.75 else { return }
        lastLyricLineMotionCountPublishAt = now
        lyricLineMotionSampleCount = lyricLineMotionSamples.count
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

        if let cpu {
            recordHighCPUIncidentIfNeeded(cpu: cpu, metrics: metrics)
        }
        if let rss {
            recordMemoryIncidentIfNeeded(rss: rss, metrics: metrics)
        }
    }

    private func recordHighCPUIncidentIfNeeded(cpu: Double, metrics: [String: Double]) {
        let now = Date()
        recentCPUSamples.append((timestamp: now, cpu: cpu))
        recentCPUSamples.removeAll { now.timeIntervalSince($0.timestamp) > 20 }

        let highSamples = recentCPUSamples.filter { $0.cpu > 70 }
        let maxRecentCPU = highSamples.map(\.cpu).max() ?? cpu
        let isSustainedHighCPU = (highSamples.count >= 2 && maxRecentCPU >= 90) || highSamples.count >= 3
        let isCriticalSpike = cpu > 150
        guard isCriticalSpike || isSustainedHighCPU else { return }
        if let lastHighCPUIncidentAt, now.timeIntervalSince(lastHighCPUIncidentAt) < 30 {
            return
        }
        lastHighCPUIncidentAt = now
        var incidentMetrics = metrics
        incidentMetrics["currentCPUPercent"] = cpu
        incidentMetrics["maxRecentCPUPercent"] = maxRecentCPU
        incidentMetrics["highCPUSampleCount"] = Double(highSamples.count)
        incidentMetrics["cpuPercent"] = maxRecentCPU

        recordIncident(
            category: .highCPU,
            severity: isCriticalSpike ? .critical : .warning,
            title: "High CPU detected",
            detail: "Process CPU reached \(String(format: "%.0f", maxRecentCPU))%.",
            metrics: incidentMetrics
        )
    }

    private func recordMemoryIncidentIfNeeded(rss: Double, metrics: [String: Double]) {
        if rss > 600 {
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
        let base = diagnosticsStorageBaseDirectory()
        let dir = base
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func diagnosticsStateSnapshotURL() throws -> URL {
        let base = diagnosticsStorageBaseDirectory()
        let dir = base
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rolling_state.json")
    }

    private func diagnosticsStorageBaseDirectory() -> URL {
        if let storageBaseDirectoryForTesting {
            return storageBaseDirectoryForTesting
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
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

    private func performanceCSV(
        events: [DiagnosticEvent],
        interactions: [DiagnosticInteractionTrace]
    ) -> String {
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

    private func lyricLineMotionCSV<S: Sequence>(
        samples: S,
        includeHeader: Bool = true
    ) -> String where S.Element == DiagnosticLyricLineMotionSample {
        var rows = includeHeader ? [
            "timestamp,page,trackTitle,trackArtist,lineIndex,lineID,lineStartTime,lineEndTime,playbackTime,activeIndex,displayIndex,targetIndex,renderedMinY,renderedMidY,renderedHeight,targetMinY,targetMidY,targetErrorY,velocityY,observedInterLineDeltaY,expectedInterLineDeltaY,interLineDeltaErrorY,waveOffsetY,manualScrollOffsetY,isManualScrolling,isInitialMotionSuppressed"
        ] : []
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
        let header = lyricLineMotionCSV(samples: [])
        let rows = lyricLineMotionCSV(samples: samples, includeHeader: false)
        guard let data = (rows + "\n").data(using: .utf8) else { return }

        do {
            let url = try liveLyricLineMotionSamplesURL()
            liveMotionWriteQueue.async {
                do {
                    let fileExists = FileManager.default.fileExists(atPath: url.path)
                    if !fileExists {
                        try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    handle.write(data)
                } catch {
                    Task { @MainActor in
                        DiagnosticsService.shared.recordEvent("diagnostics.liveMotionWriteFailed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            recordEvent("diagnostics.liveMotionWriteFailed", detail: error.localizedDescription)
        }
    }

    private func repairLiveLyricLineMotionCSVIfNeeded() {
        let header = lyricLineMotionCSV(samples: [])
        do {
            let url = try liveLyricLineMotionSamplesURL()
            liveMotionWriteQueue.async {
                do {
                    try Self.repairLiveLyricLineMotionCSV(at: url, header: header)
                } catch {
                    Task { @MainActor in
                        DiagnosticsService.shared.recordEvent("diagnostics.liveMotionRepairFailed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            recordEvent("diagnostics.liveMotionRepairFailed", detail: error.localizedDescription)
        }
    }

    nonisolated private static func repairLiveLyricLineMotionCSV(at url: URL, header: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let text = try String(contentsOf: url, encoding: .utf8)
        let repaired = repairedLiveLyricLineMotionCSV(text, header: header)
        guard repaired != text else { return }
        try repaired.write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func repairedLiveLyricLineMotionCSV(_ text: String, header: String) -> String {
        let hasTrailingNewline = text.hasSuffix("\n")
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var repairedRows = [header]
        for row in rows where !isLiveLyricLineMotionHeader(row, expectedHeader: header) {
            repairedRows.append(row)
        }
        return repairedRows.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
    }

    nonisolated private static func isLiveLyricLineMotionHeader(_ row: String, expectedHeader: String) -> Bool {
        row == expectedHeader || row.hasPrefix("timestamp,page,trackTitle,trackArtist,lineIndex,lineID")
    }

    private func recordLyricLineMotionIncidentIfNeeded(_ samples: [DiagnosticLyricLineMotionSample]) {
        let stableSamples = samples.filter { !$0.isManualScrolling && !$0.isInitialMotionSuppressed }
        guard !stableSamples.isEmpty else { return }

        let maxTargetError = stableSamples.map { abs($0.targetErrorY) }.max() ?? 0
        let maxInterLineError = stableSamples.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
        let activeSample = stableSamples.first { $0.lineIndex == $0.activeIndex }
        let activeLineElapsed = activeSample.map { $0.playbackTime - $0.lineStartTime } ?? 0
        let activeVisualElapsed = activeSample.map { visualElapsedForActiveState(sample: $0) } ?? 0
        let laggedNearbyTargets = stableSamples.filter {
            abs($0.lineIndex - $0.activeIndex) <= 4 && $0.targetIndex != $0.activeIndex
        }.count
        let activeTargetLagged = activeSample.map { $0.targetIndex != $0.activeIndex } ?? false

        if isCollapsedLyricLineMotionGeometry(
            stableSamples,
            maxTargetError: maxTargetError,
            laggedNearbyTargets: laggedNearbyTargets
        ) {
            recordEvent(
                "diagnostics.lyricsLineMotionGeometryDiscarded",
                detail: "Ignored collapsed line-motion geometry sample.",
                metrics: [
                    "sampleCount": Double(stableSamples.count),
                    "maxTargetErrorPt": maxTargetError,
                    "maxInterLineErrorPt": maxInterLineError
                ]
            )
            return
        }

        let hasGeometryDrift = maxInterLineError > 18 || maxTargetError > 32
        let hasLateWaveTargets = activeVisualElapsed > 0.55 && activeTargetLagged && laggedNearbyTargets >= 4
        guard hasGeometryDrift || hasLateWaveTargets else { return }

        let sample = activeSample ?? stableSamples[0]
        let signature = [
            sample.trackTitle,
            sample.trackArtist,
            String(sample.activeIndex),
            String(sample.displayIndex),
            String(sample.targetIndex),
            String(Int(maxTargetError / 10)),
            String(Int(maxInterLineError / 10))
        ].joined(separator: "|")
        let now = Date()
        let cooldown: TimeInterval = signature == lastLyricLineMotionIncidentSignature ? 30.0 : 3.0
        if let lastLyricLineMotionIncidentAt,
           now.timeIntervalSince(lastLyricLineMotionIncidentAt) < cooldown {
            return
        }

        lastLyricLineMotionIncidentAt = now
        lastLyricLineMotionIncidentSignature = signature
        let track = DiagnosticTrackContext(
            title: sample.trackTitle,
            artist: sample.trackArtist,
            album: "",
            duration: 0,
            playbackTime: sample.playbackTime
        )
        recordIncident(
            category: .lyricsLineMotion,
            severity: maxInterLineError > 28 || maxTargetError > 48 ? .critical : .warning,
            title: "Lyrics line motion drift",
            detail: "Rendered lyric lines diverged from their target motion during playback.",
            track: track,
            metrics: [
                "maxTargetErrorPt": maxTargetError,
                "maxInterLineErrorPt": maxInterLineError,
                "laggedNearbyTargetCount": Double(laggedNearbyTargets),
                "activeLineElapsedMs": activeLineElapsed * 1000,
                "activeVisualElapsedMs": activeVisualElapsed * 1000,
                "activeTargetLagged": activeTargetLagged ? 1 : 0
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

    private func visualElapsedForActiveState(sample: DiagnosticLyricLineMotionSample) -> TimeInterval {
        let key = [
            sample.trackTitle,
            sample.trackArtist,
            sample.lineID,
            String(sample.activeIndex),
            String(sample.displayIndex)
        ].joined(separator: "|")
        if key != lastLyricLineMotionActiveStateKey {
            lastLyricLineMotionActiveStateKey = key
            lastLyricLineMotionActiveStateSince = sample.timestamp
            return 0
        }
        let since = lastLyricLineMotionActiveStateSince ?? sample.timestamp
        return max(0, sample.timestamp.timeIntervalSince(since))
    }

    private func isCollapsedLyricLineMotionGeometry(
        _ samples: [DiagnosticLyricLineMotionSample],
        maxTargetError: Double,
        laggedNearbyTargets: Int
    ) -> Bool {
        guard samples.count >= 4, maxTargetError > 120, laggedNearbyTargets == 0 else { return false }
        guard let minRendered = samples.map(\.renderedMidY).min(),
              let maxRendered = samples.map(\.renderedMidY).max(),
              let minTarget = samples.map(\.targetMidY).min(),
              let maxTarget = samples.map(\.targetMidY).max() else {
            return false
        }

        let renderedSpan = maxRendered - minRendered
        let targetSpan = maxTarget - minTarget
        guard targetSpan > 120, renderedSpan < max(24, targetSpan * 0.20) else { return false }

        let renderedBuckets = Set(samples.map { Int(($0.renderedMidY / 4).rounded()) })
        return renderedBuckets.count <= max(3, samples.count / 3)
    }

    func shouldAttachDebugLog(modifiedAt: Date) -> Bool {
        modifiedAt >= sessionStartedAt.addingTimeInterval(-1)
    }

    private func writeDebugLogAttachment(to reportDir: URL) throws {
        if let debugLogURL = currentSessionDebugLogURL(),
           let logData = try? Data(contentsOf: debugLogURL) {
            let destination = reportDir.appendingPathComponent("nanopod_debug.log")
            try logData.write(to: destination)
            return
        }

        let status = [
            "No current-session nanoPod debug log was available for this report.",
            "Stale /tmp/nanopod_debug.log content is not attached."
        ].joined(separator: "\n") + "\n"
        try status.write(
            to: reportDir.appendingPathComponent("debug_log_status.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func currentSessionDebugLogURL() -> URL? {
        let url = debugLogURLForTesting ?? URL(fileURLWithPath: "/tmp/nanopod_debug.log")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              shouldAttachDebugLog(modifiedAt: modifiedAt) else {
            return nil
        }
        return url
    }

    private func liveLyricLineMotionSamplesURL() throws -> URL {
        let base = diagnosticsStorageBaseDirectory()
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

private struct DiagnosticPersistenceSnapshot: Codable, Sendable {
    var schemaVersion: Int = 1
    var savedAt: Date
    var sessionID: UUID
    var sessionStartedAt: Date
    var appBuildSignature: String?
    var incidents: [DiagnosticIncident]
    var events: [DiagnosticEvent]
    var interactions: [DiagnosticInteractionTrace]
    var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample]
    var baselineStats: [String: RunningStat]
    var lastWarning: DiagnosticIncident?
    var lastExportPath: String?
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
