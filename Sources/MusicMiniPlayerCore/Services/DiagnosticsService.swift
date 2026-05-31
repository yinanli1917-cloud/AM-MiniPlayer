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
    case lyricsMissing
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
    case missingLyrics = "missing lyrics"
    case lyricsResolverProblem = "lyrics resolver problem"
    case lyricsTimingOff = "lyrics timing off"
    case staleLyrics = "stale lyrics after switching"
    case missingTranslation = "missing translation"
    case translationWrong = "translation wrong"
    case lyricsLoadingTooSlow = "lyrics loading too slow"
    case artworkMissing = "missing artwork"
    case artworkLateOrWrong = "artwork late or wrong"
    case artworkStaleAfterSwitch = "artwork stale after switching"
    case switchingBlackout = "blackout during switching"
    case switchingAnimationInterrupted = "switching animation interrupted"
    case playbackContextWrong = "playback context wrong"
    case scriptingBridgeDelay = "ScriptingBridge delay"
    case controlsSlow = "controls slow or stuck"
    case highCPU = "high CPU"
    case visibleStutter = "visible stutter"
    case other = "other"

    public var id: String { rawValue }

    public static func inferred(from selected: DiagnosticUserSymptom, note: String) -> DiagnosticUserSymptom {
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return selected }
        if normalized.contains("missing artwork") || normalized.contains("no artwork") || normalized.contains("cover missing") || normalized.contains("封面") {
            return .artworkMissing
        }
        if normalized.contains("blackout")
            || normalized.contains("black screen")
            || normalized.contains("blank screen")
            || normalized.contains("goes black")
            || normalized.contains("turned black")
            || normalized.contains("黑屏")
            || normalized.contains("黑掉")
            || normalized.contains("变黑")
            || normalized.contains("變黑") {
            return .switchingBlackout
        }
        if normalized.contains("artwork") || normalized.contains("cover") {
            if normalized.contains("late") || normalized.contains("slow") || normalized.contains("stale") || normalized.contains("wrong") || normalized.contains("慢") || normalized.contains("旧") || normalized.contains("晚") || normalized.contains("慢一步") {
                return .artworkStaleAfterSwitch
            }
            return .artworkLateOrWrong
        }
        if normalized.contains("resolver") || normalized.contains("mismatch") || normalized.contains("wrong match") || normalized.contains("错配") || normalized.contains("匹配错") || normalized.contains("找错") {
            return .lyricsResolverProblem
        }
        if normalized.contains("missing translation") || normalized.contains("no translation") || normalized.contains("doesn't translate") || normalized.contains("does not translate") || normalized.contains("not translate") || normalized.contains("target language") || normalized.contains("缺翻译") || normalized.contains("缺少翻译") || normalized.contains("没翻译") || normalized.contains("沒有翻譯") || normalized.contains("不翻译") || normalized.contains("不翻譯") {
            return .missingTranslation
        }
        if normalized.contains("missing lyrics") || normalized.contains("no lyrics") || normalized.contains("unresolved") || normalized.contains("找不到歌词") || normalized.contains("缺歌词") {
            return .missingLyrics
        }
        if normalized.contains("animation") || normalized.contains("switching line") || normalized.contains("line switch") || normalized.contains("切换动画") || normalized.contains("切歌动画") || normalized.contains("打断") || normalized.contains("不完整") {
            return .switchingAnimationInterrupted
        }
        if normalized.contains("context") || normalized.contains("radio") || normalized.contains("playlist") || normalized.contains("search") || normalized.contains("上下文") || normalized.contains("电台") || normalized.contains("播放列表") || normalized.contains("搜索") {
            return .playbackContextWrong
        }
        if normalized.contains("scripting bridge") || normalized.contains("script bridge") || normalized.contains("sb delay") || normalized.contains("apple event") {
            return .scriptingBridgeDelay
        }
        if normalized.contains("cpu") {
            return .highCPU
        }
        if normalized.contains("control") || normalized.contains("下一首") || normalized.contains("卡住") {
            return .controlsSlow
        }
        return selected
    }
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
    public var trackClass: String?
    public var playlistName: String?
    public var playbackContext: String?
    public var playerPage: String?

    public init(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        persistentID: String? = nil,
        playbackTime: TimeInterval? = nil,
        trackClass: String? = nil,
        playlistName: String? = nil,
        playbackContext: String? = nil,
        playerPage: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.persistentID = persistentID
        self.playbackTime = playbackTime
        self.trackClass = trackClass
        self.playlistName = playlistName
        self.playbackContext = playbackContext
        self.playerPage = playerPage
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

    fileprivate func matchesReportTrackByTitleArtist(_ other: DiagnosticTrackContext) -> Bool {
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
    public var visibleTopY: Double
    public var visibleBottomY: Double
    public var lineTopClipY: Double
    public var lineBottomClipY: Double
    public var activeTopClipY: Double
    public var activeBottomClipY: Double
    public var controlsVisible: Bool

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
        isInitialMotionSuppressed: Bool,
        visibleTopY: Double = 0,
        visibleBottomY: Double = 0,
        lineTopClipY: Double = 0,
        lineBottomClipY: Double = 0,
        activeTopClipY: Double = 0,
        activeBottomClipY: Double = 0,
        controlsVisible: Bool = false
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
        self.visibleTopY = visibleTopY
        self.visibleBottomY = visibleBottomY
        self.lineTopClipY = lineTopClipY
        self.lineBottomClipY = lineBottomClipY
        self.activeTopClipY = activeTopClipY
        self.activeBottomClipY = activeBottomClipY
        self.controlsVisible = controlsVisible
    }
}

public struct DiagnosticLiveMotionSnapshot: Equatable, Sendable {
    public var timestamp: Date
    public var trackTitle: String
    public var trackArtist: String
    public var playbackTime: TimeInterval
    public var activeIndex: Int
    public var displayIndex: Int
    public var targetIndex: Int
    public var sampleCount: Int
    public var capturedFirstLineIndex: Int
    public var capturedLastLineIndex: Int
    public var maxTargetErrorY: Double
    public var maxInterLineErrorY: Double
    public var maxVelocityY: Double
    public var staleStaticLineCount: Int
    public var fieldTargetMismatchCount: Int
    public var maxFieldTargetDistance: Int
    public var wavePropagationLineCount: Int
    public var activeTargetLagged: Bool
    public var activeVisualElapsedMs: Double
    public var lateActiveTarget: Bool
    public var lingeringWaveBacklog: Bool
    public var latestFrameDeltaMs: Double
    public var recentFrameStallCount: Int
    public var captureMissCount: Int
    public var latestCaptureMissAt: Date?
    public var captureMissDisplayLineCount: Int
    public var captureMissMonitoringEnabled: Bool
}

public struct DiagnosticLyricWaveTimelineSample: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var page: String
    public var trackTitle: String
    public var trackArtist: String
    public var waveID: Int
    public var phase: String
    public var lineIndex: Int
    public var oldIndex: Int
    public var newIndex: Int
    public var displayIndex: Int
    public var scheduledDelay: TimeInterval
    public var actualDelay: TimeInterval
    public var lineInterval: TimeInterval?
    public var targetRadius: Int
    public var scheduleCount: Int
    public var renderedCount: Int
    public var isActiveLine: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        page: String,
        trackTitle: String,
        trackArtist: String,
        waveID: Int,
        phase: String,
        lineIndex: Int,
        oldIndex: Int,
        newIndex: Int,
        displayIndex: Int,
        scheduledDelay: TimeInterval,
        actualDelay: TimeInterval,
        lineInterval: TimeInterval?,
        targetRadius: Int,
        scheduleCount: Int,
        renderedCount: Int,
        isActiveLine: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.page = page
        self.trackTitle = trackTitle
        self.trackArtist = trackArtist
        self.waveID = waveID
        self.phase = phase
        self.lineIndex = lineIndex
        self.oldIndex = oldIndex
        self.newIndex = newIndex
        self.displayIndex = displayIndex
        self.scheduledDelay = scheduledDelay
        self.actualDelay = actualDelay
        self.lineInterval = lineInterval
        self.targetRadius = targetRadius
        self.scheduleCount = scheduleCount
        self.renderedCount = renderedCount
        self.isActiveLine = isActiveLine
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
    public static let lineMotionGeometryEnabledKey = "ownerLineMotionGeometryEnabled"
    public static let lyricWaveTimelineEnabledKey = "ownerLyricWaveTimelineEnabled"
    public static var isOwnerDiagnosticsBuild: Bool {
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        return true
        #else
        return false
        #endif
    }

    @Published public private(set) var incidents: [DiagnosticIncident] = []
    // Event rows can be emitted once per frame-summary interval; keep them off
    // ObservableObject publishing so diagnostics do not invalidate active pages.
    public private(set) var events: [DiagnosticEvent] = []
    @Published public private(set) var interactions: [DiagnosticInteractionTrace] = []
    public private(set) var lyricLineMotionSamples: [DiagnosticLyricLineMotionSample] = []
    public private(set) var lyricWaveTimelineSamples: [DiagnosticLyricWaveTimelineSample] = []
    @Published public private(set) var lyricLineMotionSampleCount: Int = 0
    public private(set) var liveMotionSnapshot: DiagnosticLiveMotionSnapshot?
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
                DebugLogger.setDiagnosticsFileLoggingEnabled(false)
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
    private var lyricsBackfillStarts: [String: Date] = [:]
    private var lyricsBackfillForegroundSeconds: [String: TimeInterval] = [:]
    private var artworkFetchStarts: [Int: Date] = [:]
    private var activeLyricsRefreshInteractions: [String: UUID] = [:]
    private var baselineStats: [String: RunningStat] = [:]
    private var activeInteractions: [UUID: ActiveDiagnosticInteraction] = [:]
    private var healthSampler: Timer?
    private let maxEvents = 300
    private let maxIncidents = 120
    private let maxInteractions = 120
    private let maxLyricLineMotionSamples = 2400
    private let maxLyricWaveTimelineSamples = 4000
    private let standaloneFrameStallThreshold: TimeInterval = 0.125
    private let criticalStandaloneFrameStallThreshold: TimeInterval = 0.250
    private let severeStandaloneFrameStallThreshold: TimeInterval = 0.500
    private let standaloneFrameStallCoalesceWindow: TimeInterval = 60
    private let standaloneWarningFrameStallIncidentThreshold = 6
    private let standaloneCriticalFrameStallIncidentThreshold = 3
    private let scriptingBridgeCoalesceWindow: TimeInterval = 120
    private let memoryCoalesceWindow: TimeInterval = 10 * 60
    private let memorySampleWindow: TimeInterval = 90
    private let memoryWarningRSSMB: Double = 800
    private let memoryCriticalRSSMB: Double = 1200
    private let memoryGrowthWarningMB: Double = 300
    private let memoryGrowthCriticalMB: Double = 600
    private let correlatedScriptingBridgeReadIncidentThreshold: TimeInterval = 0.50
    private let severeStandaloneScriptingBridgeReadIncidentThreshold: TimeInterval = 1.0
    private let startupStandaloneFrameStallSuppressionDuration: TimeInterval = 5.0
    private let retention: TimeInterval = 24 * 60 * 60
    private var previousLyricLineMotionSamples: [String: (timestamp: Date, renderedMidY: Double)] = [:]
    private var latestFrameDeltaMs: Double = 0
    private var recentFrameStallTicks: [Date] = []
    private var lyricLineMotionCaptureMissCount = 0
    private var latestLyricLineMotionCaptureMissAt: Date?
    private var lastLyricLineMotionCaptureDisplayLineCount = 0
    private var lastLyricLineMotionCaptureMonitoringEnabled = false
    private var lastLyricLineMotionActiveStateKey: String?
    private var lastLyricLineMotionActiveStateSince: Date?
    private var lastLyricLineMotionIncidentAt: Date?
    private var lastLyricLineMotionIncidentSignature: String?
    private var recentCPUSamples: [(timestamp: Date, cpu: Double)] = []
    private var recentMemorySamples: [(timestamp: Date, rss: Double)] = []
    private var lastHighCPUIncidentAt: Date?
    private var suppressStandaloneFrameStallsUntil: Date = .distantPast
    private var pendingStandaloneFrameStalls: [String: DiagnosticIncident] = [:]
    private var storageBaseDirectoryForTesting: URL?
    private var debugLogURLForTesting: URL?
    private var persistenceSaveTask: Task<Void, Never>?
    private var lastLyricLineMotionCountPublishAt: Date = .distantPast
    private let liveMotionWriteQueue = DispatchQueue(
        label: "com.nanopod.diagnostics.live-line-motion-writes",
        qos: .utility
    )
    private let liveWaveTimelineWriteQueue = DispatchQueue(
        label: "com.nanopod.diagnostics.live-wave-timeline-writes",
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
    public var isLyricWaveTimelineEnabled: Bool {
        isEnabled && UserDefaults.standard.bool(forKey: Self.lyricWaveTimelineEnabledKey)
    }
    public var isLineMotionGeometryEnabled: Bool {
        isEnabled && UserDefaults.standard.bool(forKey: Self.lineMotionGeometryEnabledKey)
    }

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
        lyricWaveTimelineSamples.removeAll()
        lyricLineMotionSampleCount = 0
        previousLyricLineMotionSamples.removeAll()
        liveMotionSnapshot = nil
        latestFrameDeltaMs = 0
        recentFrameStallTicks.removeAll()
        lyricLineMotionCaptureMissCount = 0
        latestLyricLineMotionCaptureMissAt = nil
        lastLyricLineMotionCaptureDisplayLineCount = 0
        lastLyricLineMotionCaptureMonitoringEnabled = false
        lastLyricLineMotionActiveStateKey = nil
        lastLyricLineMotionActiveStateSince = nil
        lastLyricLineMotionIncidentAt = nil
        lastLyricLineMotionIncidentSignature = nil
        recentCPUSamples.removeAll()
        recentMemorySamples.removeAll()
        lastHighCPUIncidentAt = nil
        pendingStandaloneFrameStalls.removeAll()
        suppressStandaloneFrameStallsUntil = suppressImmediateStandaloneFrameStalls
            ? Date().addingTimeInterval(1.5)
            : .distantPast
        activeInteractionCount = 0
        lyricsFetchStarts.removeAll()
        lyricsBackfillStarts.removeAll()
        lyricsBackfillForegroundSeconds.removeAll()
        artworkFetchStarts.removeAll()
        activeLyricsRefreshInteractions.removeAll()
        baselineStats.removeAll()
        lastExportURL = nil
        lastWarning = nil
        sessionStartedAt = Date()
        persistenceSaveTask?.cancel()
        persistenceSaveTask = nil
        removePersistedSnapshot()
        removeLiveLyricLineMotionSamples()
        removeLiveLyricWaveTimelineSamples()
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

    func recordProcessHealthSampleForTesting(cpu: Double?, rss: Double?, physicalFootprint: Double? = nil) {
        recordProcessHealthSample(cpu: cpu, rss: rss, physicalFootprint: physicalFootprint ?? rss)
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
        if isHighFrequencyEvent(name) {
            scheduleHighFrequencyPersistenceSave()
        } else {
            schedulePersistenceSave()
        }
    }

    private func isHighFrequencyEvent(_ name: String) -> Bool {
        name == "lyrics.presentationFrame.summary"
            || name == "lyrics.nativeRenderer.summary"
    }

    public func enrichTrackContext(_ context: DiagnosticTrackContext) {
        guard isEnabled, context.hasCredibleIdentity else { return }
        var changed = false

        for index in incidents.indices {
            changed = enrichTrackContext(&incidents[index].track, with: context) || changed
        }
        for index in events.indices {
            changed = enrichTrackContext(&events[index].track, with: context) || changed
        }
        for index in interactions.indices {
            changed = enrichTrackContext(&interactions[index].track, with: context) || changed
        }
        for id in Array(activeInteractions.keys) {
            guard var active = activeInteractions[id] else { continue }
            if enrichTrackContext(&active.trace.track, with: context) {
                activeInteractions[id] = active
                changed = true
            }
        }

        if changed {
            schedulePersistenceSave()
        }
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
        hasSyllableSync: Bool = false,
        firstRealLineSHA256: String? = nil,
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
            "hasSyllableSync": hasSyllableSync ? 1 : 0,
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
        let workloadEvidence = [
            "source": source ?? "unknown",
            "hasSyllableSync": hasSyllableSync ? "true" : "false",
            "firstRealLineSHA256": firstRealLineSHA256 ?? "unknown"
        ]

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
            evidence: workloadEvidence
        )

        let isLowConfidence = shouldRecordLowConfidenceLyricsResult(
            source: source,
            score: score,
            lineCount: lineCount,
            isUnsynced: isUnsynced,
            hadSourceTranslation: hadSourceTranslation,
            translationLineCount: translationLineCount,
            translatableLineCount: translatableLineCount
        )
        if !isLowConfidence && lineCount > 0 {
            clearLyricsFallbackIncidentAfterResolvedFetch(track: track, metrics: metrics)
        }

        if elapsed > 3.0 {
            recordIncident(
                category: .lyricsSlowFetch,
                severity: elapsed > 6.0 ? .critical : .warning,
                title: "Slow lyrics fetch",
                detail: "Lyrics took \(formatSeconds(elapsed)) to load.",
                track: track,
                metrics: metrics,
                evidence: workloadEvidence
            )
        }

        if isLowConfidence {
            if hasExistingLyricsFallbackIncident(for: track) {
                recordEvent(
                    "lyrics.fetch.lowConfidenceAfterMiss",
                    detail: "Low-confidence selected result is attached to the existing lyrics miss.",
                    track: track,
                    metrics: metrics
                )
                return
            }
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
            recordEvent(
                "lyrics.translation.partialSource",
                detail: "The selected lyrics source translated \(translationLineCount)/\(max(translatableLineCount, 1)) visible lines before system fill.",
                track: track,
                metrics: metrics
            )
        }
    }

    public func recordLyricsBackfillStarted(
        track: DiagnosticTrackContext,
        foregroundFetchSeconds: TimeInterval,
        foregroundResultCount: Int
    ) {
        guard isEnabled else { return }
        let key = lyricsKey(for: track)
        lyricsBackfillStarts[key] = Date()
        lyricsBackfillForegroundSeconds[key] = foregroundFetchSeconds
        recordEvent(
            "lyrics.backfill.start",
            detail: "Authoritative lyrics backfill started after foreground resolver did not return a trusted result.",
            track: track,
            metrics: [
                "foregroundFetchSeconds": foregroundFetchSeconds,
                "foregroundResultCount": Double(foregroundResultCount)
            ]
        )
        schedulePersistenceSave()
    }

    public func recordLyricsBackfillFinished(
        track: DiagnosticTrackContext,
        result: String,
        source: String?,
        score: Double?,
        lineCount: Int
    ) {
        guard isEnabled else { return }
        let key = lyricsKey(for: track)
        let elapsed = Date().timeIntervalSince(lyricsBackfillStarts[key] ?? Date())
        let foregroundElapsed = lyricsBackfillForegroundSeconds[key] ?? 0
        lyricsBackfillStarts.removeValue(forKey: key)
        lyricsBackfillForegroundSeconds.removeValue(forKey: key)
        let totalElapsed = foregroundElapsed + elapsed

        var metrics: [String: Double] = [
            "backfillSeconds": elapsed,
            "foregroundFetchSeconds": foregroundElapsed,
            "totalResolverSeconds": totalElapsed,
            "lineCount": Double(lineCount)
        ]
        if let score { metrics["score"] = score }

        recordEvent(
            "lyrics.backfill.finish",
            detail: "Authoritative lyrics backfill finished with \(result) from \(source ?? "unknown") after \(formatSeconds(elapsed)).",
            track: track,
            metrics: metrics
        )

        if elapsed > 4.0 || totalElapsed > 6.0 {
            recordIncident(
                category: .lyricsSlowFetch,
                severity: totalElapsed > 8.0 ? .critical : .warning,
                title: "Slow lyrics authoritative backfill",
                detail: "Authoritative lyrics backfill took \(formatSeconds(elapsed)); total resolver time was \(formatSeconds(totalElapsed)).",
                track: track,
                metrics: metrics,
                evidence: [
                    "phase": "authoritativeBackfill",
                    "result": result,
                    "source": source ?? "unknown"
                ]
            )
        }
    }

    public func recordLyricsPartialTranslationFilled(
        track: DiagnosticTrackContext,
        filledLineCount: Int,
        translationLineCount: Int,
        translatableLineCount: Int,
        translationLanguage: String
    ) {
        guard isEnabled else { return }
        let before = incidents.count
        incidents.removeAll { incident in
            guard incident.category == .lyricsPartialTranslation,
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }
        let cleared = before - incidents.count
        let metrics: [String: Double] = [
            "filledLineCount": Double(filledLineCount),
            "translationLineCount": Double(translationLineCount),
            "translatableLineCount": Double(translatableLineCount),
            "missingTranslationLineCount": Double(max(translatableLineCount - translationLineCount, 0)),
            "clearedPartialTranslationIncidentCount": Double(cleared)
        ]
        recordEvent(
            "lyrics.translation.filledPartialSource",
            detail: "System translation (\(translationLanguage)) filled \(filledLineCount) missing source-translation line(s).",
            track: track,
            metrics: metrics
        )
    }

    public func recordLyricsSystemTranslationGap(
        track: DiagnosticTrackContext,
        reason: String,
        translationLanguage: String,
        translationLineCount: Int,
        translatableLineCount: Int
    ) {
        guard isEnabled else { return }
        let missingLineCount = max(translatableLineCount - translationLineCount, 0)
        guard translatableLineCount > 0, missingLineCount > 0 else { return }

        let metrics: [String: Double] = [
            "translationLineCount": Double(translationLineCount),
            "translatableLineCount": Double(translatableLineCount),
            "missingTranslationLineCount": Double(missingLineCount),
            "translationCoverage": Double(translationLineCount) / Double(translatableLineCount)
        ]
        let evidence = [
            "translationLanguage": translationLanguage,
            "reason": reason,
            "source": "system"
        ]

        if let existingIndex = incidents.firstIndex(where: { incident in
            guard incident.category == .lyricsPartialTranslation,
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }) {
            incidents[existingIndex].timestamp = Date()
            incidents[existingIndex].title = "System translation unavailable"
            incidents[existingIndex].detail = "System translation did not fill \(missingLineCount)/\(translatableLineCount) visible line(s): \(reason)."
            merge(metrics, into: &incidents[existingIndex].metrics)
            merge(evidence, into: &incidents[existingIndex].evidence)
            trimBuffers()
            schedulePersistenceSave()
            return
        }

        recordIncident(
            category: .lyricsPartialTranslation,
            severity: .warning,
            title: "System translation unavailable",
            detail: "System translation did not fill \(missingLineCount)/\(translatableLineCount) visible line(s): \(reason).",
            track: track,
            metrics: metrics,
            evidence: evidence
        )
    }

    public func recordLyricsVisibleTranslationGap(
        track: DiagnosticTrackContext,
        lineIndex: Int,
        sourceLineIndex: Int? = nil,
        segmentIndex: Int? = nil,
        segmentCount: Int? = nil,
        displayIndex: Int,
        activeIndex: Int,
        playbackTime: TimeInterval,
        lineStartTime: TimeInterval,
        lineEndTime: TimeInterval,
        totalLineCount: Int,
        visibleLineCount: Int,
        visibleTranslatedLineCount: Int,
        visibleMissingTranslationLineCount: Int,
        sourceLineHasTranslation: Bool = false,
        lineIsTranslationEligible: Bool,
        lineIsVocable: Bool,
        showTranslation: Bool,
        canTranslate: Bool,
        translationFailed: Bool
    ) {
        guard isEnabled, showTranslation else { return }
        guard totalLineCount > 0, visibleLineCount > 0 else { return }
        guard visibleMissingTranslationLineCount > 0,
              visibleTranslatedLineCount > 0 || sourceLineHasTranslation else {
            return
        }

        let reason: String = {
            if sourceLineHasTranslation, (segmentCount ?? 1) > 1 {
                return "generated display chunk lost source translation"
            }
            if lineIsTranslationEligible { return "visible eligible line missing translation" }
            if lineIsVocable { return "visible vocable line excluded from aggregate translation coverage" }
            return "visible line excluded from aggregate translation coverage"
        }()
        var metrics: [String: Double] = [
            "lineIndex": Double(lineIndex),
            "displayIndex": Double(displayIndex),
            "activeIndex": Double(activeIndex),
            "playbackTime": playbackTime,
            "lineStartTime": lineStartTime,
            "lineEndTime": lineEndTime,
            "lineDuration": max(lineEndTime - lineStartTime, 0),
            "totalLineCount": Double(totalLineCount),
            "visibleLineCount": Double(visibleLineCount),
            "visibleTranslatedLineCount": Double(visibleTranslatedLineCount),
            "visibleMissingTranslationLineCount": Double(visibleMissingTranslationLineCount),
            "sourceLineHasTranslation": sourceLineHasTranslation ? 1 : 0,
            "lineIsTranslationEligible": lineIsTranslationEligible ? 1 : 0,
            "lineIsVocable": lineIsVocable ? 1 : 0,
            "canTranslate": canTranslate ? 1 : 0,
            "translationFailed": translationFailed ? 1 : 0
        ]
        if let sourceLineIndex {
            metrics["sourceLineIndex"] = Double(sourceLineIndex)
        }
        if let segmentIndex {
            metrics["segmentIndex"] = Double(segmentIndex)
        }
        if let segmentCount {
            metrics["segmentCount"] = Double(segmentCount)
        }

        var evidence = [
            "source": "visibleLine",
            "reason": reason,
            "lineIndex": String(lineIndex),
            "displayIndex": String(displayIndex),
            "activeIndex": String(activeIndex)
        ]
        if let sourceLineIndex {
            evidence["sourceLineIndex"] = String(sourceLineIndex)
        }
        if let segmentIndex {
            evidence["segmentIndex"] = String(segmentIndex)
        }
        if let segmentCount {
            evidence["segmentCount"] = String(segmentCount)
        }

        if let existingIndex = incidents.firstIndex(where: { incident in
            guard incident.category == .lyricsPartialTranslation,
                  incident.evidence["source"] == "visibleLine",
                  incident.evidence["lineIndex"] == String(lineIndex),
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }) {
            incidents[existingIndex].timestamp = Date()
            incidents[existingIndex].title = "Visible lyric line missing translation"
            incidents[existingIndex].detail = "The highlighted lyric line has no translation while nearby visible lines do."
            merge(metrics, into: &incidents[existingIndex].metrics)
            merge(evidence, into: &incidents[existingIndex].evidence)
            incrementMetric("occurrenceCount", in: &incidents[existingIndex].metrics)
            trimBuffers()
            schedulePersistenceSave()
            return
        }

        var newMetrics = metrics
        newMetrics["occurrenceCount"] = 1
        recordIncident(
            category: .lyricsPartialTranslation,
            severity: .warning,
            title: "Visible lyric line missing translation",
            detail: "The highlighted lyric line has no translation while nearby visible lines do.",
            userSymptom: .missingTranslation,
            track: track,
            metrics: newMetrics,
            evidence: evidence
        )
    }

    public func recordLyricsSystemTranslationFilled(
        track: DiagnosticTrackContext,
        filledLineCount: Int,
        translationLineCount: Int,
        translatableLineCount: Int,
        translationLanguage: String
    ) {
        guard isEnabled else { return }
        let before = incidents.count
        incidents.removeAll { incident in
            guard incident.category == .lyricsPartialTranslation,
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }
        let cleared = before - incidents.count
        let metrics: [String: Double] = [
            "filledLineCount": Double(filledLineCount),
            "translationLineCount": Double(translationLineCount),
            "translatableLineCount": Double(translatableLineCount),
            "missingTranslationLineCount": Double(max(translatableLineCount - translationLineCount, 0)),
            "clearedPartialTranslationIncidentCount": Double(cleared)
        ]
        recordEvent(
            "lyrics.translation.filledSystem",
            detail: "System translation (\(translationLanguage)) filled \(filledLineCount) line(s).",
            track: track,
            metrics: metrics
        )
    }

    private func clearLyricsFallbackIncidentAfterResolvedFetch(track: DiagnosticTrackContext, metrics: [String: Double]) {
        let before = incidents.count
        incidents.removeAll { incident in
            guard (incident.category == .lyricsFallbackChurn || incident.category == .lyricsMissing),
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }
        let cleared = before - incidents.count
        guard cleared > 0 else { return }
        var eventMetrics = metrics
        eventMetrics["clearedFallbackIncidentCount"] = Double(cleared)
        recordEvent(
            "lyrics.fetch.resolvedAfterMiss",
            detail: "Trusted lyrics result cleared an earlier unresolved/fallback incident for the same track.",
            track: track,
            metrics: eventMetrics
        )
    }

    private func shouldRecordLowConfidenceLyricsResult(
        source: String?,
        score: Double?,
        lineCount: Int,
        isUnsynced: Bool,
        hadSourceTranslation: Bool,
        translationLineCount: Int,
        translatableLineCount: Int
    ) -> Bool {
        if isUnsynced { return true }
        guard let score else { return false }
        let normalizedSource = source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if isTrustedTranslatedSyncedResult(
            source: normalizedSource,
            score: score,
            lineCount: lineCount,
            hadSourceTranslation: hadSourceTranslation,
            translationLineCount: translationLineCount,
            translatableLineCount: translatableLineCount
        ) {
            return false
        }
        switch normalizedSource {
        case "lrclib":
            return !(score >= 20 && lineCount >= 10)
        case "lrclib-search":
            return !(score >= 28 && lineCount >= 10)
        default:
            return score < 30
        }
    }

    private func isTrustedTranslatedSyncedResult(
        source: String,
        score: Double,
        lineCount: Int,
        hadSourceTranslation: Bool,
        translationLineCount: Int,
        translatableLineCount: Int
    ) -> Bool {
        guard hadSourceTranslation,
              ["netease", "qq"].contains(source),
              score >= 25,
              lineCount >= 12,
              translatableLineCount > 0 else {
            return false
        }
        let coverage = Double(translationLineCount) / Double(translatableLineCount)
        return coverage >= 0.8
    }

    private func hasExistingLyricsFallbackIncident(for track: DiagnosticTrackContext) -> Bool {
        incidents.contains { incident in
            guard (incident.category == .lyricsFallbackChurn || incident.category == .lyricsMissing),
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }
    }

    public func recordLyricsFetchMiss(
        track: DiagnosticTrackContext,
        resultCount: Int,
        terminalCandidateOnly: Bool = false
    ) {
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
        if !hasRejectedCandidates {
            recordEvent(
                "lyrics.fetch.unresolved",
                detail: "Lyrics search found no trusted source candidates after \(formatSeconds(elapsed)).",
                track: track,
                metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)]
            )
            return
        }
        if terminalCandidateOnly {
            recordEvent(
                "lyrics.fetch.terminalMissPendingBackfill",
                detail: "Terminal-only lyrics miss is waiting for authoritative availability classification.",
                track: track,
                metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)]
            )
            return
        }
        recordLyricsMissingIncidentIfNeeded(
            track: track,
            elapsed: elapsed,
            resultCount: resultCount,
            result: "miss"
        )
    }

    private func recordLyricsMissingIncidentIfNeeded(
        track: DiagnosticTrackContext,
        elapsed: TimeInterval,
        resultCount: Int,
        result: String
    ) {
        guard track.hasCredibleIdentity else { return }
        if incidents.contains(where: { incident in
            guard (incident.category == .lyricsMissing || incident.category == .lyricsFallbackChurn),
                  let incidentTrack = incident.track else {
                return false
            }
            return incidentTrack.matchesReportTrack(track)
        }) {
            recordEvent(
                "lyrics.fetch.missingRepeated",
                detail: "Repeated missing-lyrics result was coalesced with the existing incident.",
                track: track,
                metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)]
            )
            return
        }
        recordIncident(
            category: .lyricsMissing,
            severity: .warning,
            title: result == "miss" ? "Lyrics search returned no trusted result" : "Lyrics missing",
            detail: result == "miss"
                ? "No trusted lyrics were selected after \(formatSeconds(elapsed))."
                : "No trusted lyrics source was resolved after \(formatSeconds(elapsed)).",
            track: track,
            metrics: ["fetchSeconds": elapsed, "resultCount": Double(resultCount)],
            evidence: ["result": result]
        )
    }

    public func recordLyricsFetchUnavailable(track: DiagnosticTrackContext, classification: String) {
        guard isEnabled else { return }
        let removedCount = incidents.count
        incidents.removeAll { incident in
            guard (incident.category == .lyricsFallbackChurn || incident.category == .lyricsMissing),
                  let incidentTrack = incident.track,
                  incidentTrack.matchesReportTrack(track) else {
                return false
            }
            if classification == "instrumental" { return true }
            return incident.evidence["result"] == "unresolved"
        }
        recordEvent(
            "lyrics.fetch.unavailable",
            detail: "Authoritative lyrics backfill classified this track as \(classification).",
            track: track,
            metrics: [
                "clearedFallbackIncidentCount": Double(removedCount - incidents.count),
                "clearedUnresolvedIncidentCount": Double(removedCount - incidents.count)
            ]
        )
    }

    public func recordArtworkFetchStarted(
        track: DiagnosticTrackContext,
        generation: Int,
        persistentIDPresent: Bool,
        metadataCacheEligible: Bool,
        heldPreviousArtwork: Bool
    ) {
        guard isEnabled else { return }
        artworkFetchStarts[generation] = Date()
        recordEvent(
            "artwork.fetch.start",
            detail: heldPreviousArtwork
                ? "Artwork fetch started while retaining the previous artwork until a replacement is ready."
                : "Artwork fetch started with no previous artwork on screen.",
            track: track,
            metrics: [
                "generation": Double(generation),
                "persistentIDPresent": persistentIDPresent ? 1 : 0,
                "metadataCacheEligible": metadataCacheEligible ? 1 : 0,
                "heldPreviousArtwork": heldPreviousArtwork ? 1 : 0
            ]
        )
    }

    public func recordArtworkCacheMiss(
        track: DiagnosticTrackContext,
        generation: Int,
        heldPreviousArtwork: Bool
    ) {
        guard isEnabled else { return }
        recordEvent(
            "artwork.cache.miss",
            detail: heldPreviousArtwork
                ? "Artwork cache missed; previous artwork stayed visible during fetch."
                : "Artwork cache missed with no previous artwork to retain.",
            track: track,
            metrics: [
                "generation": Double(generation),
                "heldPreviousArtwork": heldPreviousArtwork ? 1 : 0
            ]
        )
    }

    public func recordArtworkApplied(
        track: DiagnosticTrackContext,
        generation: Int,
        source: String,
        applyMilliseconds: Double
    ) {
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince(artworkFetchStarts[generation] ?? Date())
        artworkFetchStarts.removeValue(forKey: generation)
        updateBaseline("artwork.fetch.seconds", value: elapsed)
        updateBaseline("artwork.apply.ms", value: applyMilliseconds)

        let metrics: [String: Double] = [
            "generation": Double(generation),
            "fetchSeconds": elapsed,
            "applyMilliseconds": applyMilliseconds
        ]
        recordEvent(
            "artwork.apply",
            detail: "Artwork from \(source) applied after \(formatSeconds(elapsed)).",
            track: track,
            metrics: metrics
        )

        if elapsed > 1.0 || applyMilliseconds > 50 {
            recordIncident(
                category: .artworkBlocking,
                severity: elapsed > 2.0 || applyMilliseconds > 100 ? .critical : .warning,
                title: "Artwork update slow",
                detail: "Artwork from \(source) applied after \(formatSeconds(elapsed)); apply work took \(Int(applyMilliseconds.rounded()))ms.",
                track: track,
                metrics: metrics,
                evidence: ["source": source]
            )
        }
    }

    public func recordArtworkPlaceholderShown(
        track: DiagnosticTrackContext,
        generation: Int,
        reason: String,
        applyMilliseconds: Double
    ) {
        guard isEnabled else { return }
        updateBaseline("artwork.placeholder.apply.ms", value: applyMilliseconds)
        recordEvent(
            "artwork.placeholder",
            detail: "Current-track artwork placeholder shown because \(reason).",
            track: track,
            metrics: [
                "generation": Double(generation),
                "applyMilliseconds": applyMilliseconds
            ]
        )

        if reason != "initial" {
            recordIncident(
                category: .artworkBlocking,
                severity: reason == "fetchFailed" ? .critical : .warning,
                title: "Artwork missing for current track",
                detail: "Current-track artwork did not arrive before the fallback placeholder was shown.",
                track: track,
                metrics: [
                    "generation": Double(generation),
                    "applyMilliseconds": applyMilliseconds
                ],
                evidence: ["reason": reason]
            )
        }
    }

    public func recordArtworkDropped(
        track: DiagnosticTrackContext,
        generation: Int,
        source: String,
        reason: String
    ) {
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince(artworkFetchStarts[generation] ?? Date())
        recordEvent(
            "artwork.drop",
            detail: "Artwork result from \(source) was dropped: \(reason).",
            track: track,
            metrics: [
                "generation": Double(generation),
                "fetchSeconds": elapsed
            ]
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
        latestFrameDeltaMs = delta * 1000
        let now = Date()
        recentFrameStallTicks.removeAll { now.timeIntervalSince($0) > 5.0 }
        updateBaseline("frame.delta.ms", value: delta * 1000)
        let hasActiveInteractions = !activeInteractions.isEmpty
        updateActiveInteractions { trace in
            incrementMetric("frameSampleCount", in: &trace.metrics)
            maximizeMetric("maxFrameDeltaMs", value: delta * 1000, in: &trace.metrics)
            trace.evidence["latestFramePage"] = page
            if page == "lyrics" {
                incrementMetric("lyricsFrameSampleCount", in: &trace.metrics)
            }
            if delta > standaloneFrameStallThreshold {
                incrementMetric("frameStallCount", in: &trace.metrics)
                trace.evidence["latestFrameStallPage"] = page
            }
        }
        guard delta > standaloneFrameStallThreshold else { return }
        recentFrameStallTicks.append(now)
        guard !hasActiveInteractions else { return }
        guard Date() >= suppressStandaloneFrameStallsUntil else { return }
        recordStandaloneFrameStall(page: page, delta: delta)
    }

    private func recordStandaloneFrameStall(page: String, delta: TimeInterval) {
        let pageName = page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : page
        let incoming = DiagnosticIncident(
            category: .uiFrameStall,
            severity: delta > criticalStandaloneFrameStallThreshold ? .critical : .warning,
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

        let normalized: DiagnosticIncident
        if let pending = pendingStandaloneFrameStalls.removeValue(forKey: signature) {
            normalized = mergeFrameStallIncident(
                incoming,
                into: normalizedFrameStallIncident(pending, signature: signature)
            )
        } else {
            normalized = normalizedFrameStallIncident(incoming, signature: signature)
        }
        if shouldRecordStandaloneFrameStallIncident(normalized) {
            recordIncident(
                category: normalized.category,
                severity: normalized.severity,
                title: normalized.title,
                detail: normalized.detail,
                metrics: normalized.metrics,
                evidence: normalized.evidence
            )
        } else {
            pendingStandaloneFrameStalls[signature] = normalized
        }
    }

    public func recordLyricsLineMotionSamples(_ samples: [DiagnosticLyricLineMotionSample]) {
        guard isEnabled, !samples.isEmpty else { return }

        let previousSampleCount = lyricLineMotionSamples.count
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
        updateLyricLineMotionSampleCount(force: lyricLineMotionSamples.count != previousSampleCount)

        let maxTargetError = enriched.map { abs($0.targetErrorY) }.max() ?? 0
        let maxInterLineError = enriched.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
        let maxVelocity = enriched.map { abs($0.velocityY) }.max() ?? 0
        let maxActiveTopClip = enriched.map(\.activeTopClipY).max() ?? 0
        let maxActiveBottomClip = enriched.map(\.activeBottomClipY).max() ?? 0
        let maxLineTopClip = enriched.map(\.lineTopClipY).max() ?? 0
        let maxLineBottomClip = enriched.map(\.lineBottomClipY).max() ?? 0
        updateBaseline("lyrics.lineMotion.targetError.pt", value: maxTargetError)
        updateBaseline("lyrics.lineMotion.interLineError.pt", value: maxInterLineError)
        updateBaseline("lyrics.lineMotion.velocity.ptPerSec", value: maxVelocity)
        updateBaseline("lyrics.layout.activeTopClip.pt", value: maxActiveTopClip)
        updateBaseline("lyrics.layout.activeBottomClip.pt", value: maxActiveBottomClip)
        updateBaseline("lyrics.layout.lineTopClip.pt", value: maxLineTopClip)
        updateBaseline("lyrics.layout.lineBottomClip.pt", value: maxLineBottomClip)
        updateLiveMotionSnapshot(with: enriched)

        updateActiveInteractions { trace in
            incrementMetric("lyricsLineMotionSampleCount", by: Double(enriched.count), in: &trace.metrics)
            maximizeMetric("maxLyricLineMotionTargetErrorPt", value: maxTargetError, in: &trace.metrics)
            maximizeMetric("maxLyricLineMotionInterLineErrorPt", value: maxInterLineError, in: &trace.metrics)
            maximizeMetric("maxLyricLineMotionVelocityPtPerSec", value: maxVelocity, in: &trace.metrics)
            maximizeMetric("maxLyricActiveTopClipPt", value: maxActiveTopClip, in: &trace.metrics)
            maximizeMetric("maxLyricActiveBottomClipPt", value: maxActiveBottomClip, in: &trace.metrics)
            maximizeMetric("maxLyricLineTopClipPt", value: maxLineTopClip, in: &trace.metrics)
            maximizeMetric("maxLyricLineBottomClipPt", value: maxLineBottomClip, in: &trace.metrics)
        }

        writeLiveLyricLineMotionSamples(enriched)
        recordLyricLineMotionIncidentIfNeeded(enriched)
        trimBuffers()
        scheduleHighFrequencyPersistenceSave()
    }

    public func recordLyricsWaveTimelineSamples(_ samples: [DiagnosticLyricWaveTimelineSample]) {
        guard isLyricWaveTimelineEnabled, !samples.isEmpty else { return }

        lyricWaveTimelineSamples.insert(contentsOf: samples.reversed(), at: 0)
        if lyricWaveTimelineSamples.count > maxLyricWaveTimelineSamples {
            lyricWaveTimelineSamples.removeLast(lyricWaveTimelineSamples.count - maxLyricWaveTimelineSamples)
        }

        let scheduledCount = samples.filter { $0.phase == "scheduled" }.count
        let firedCount = samples.filter { $0.phase == "fired" }.count
        let maxDelayOverrun = samples
            .map { max(0, $0.actualDelay - $0.scheduledDelay) }
            .max() ?? 0
        updateBaseline("lyrics.waveTimeline.sampleCount", value: Double(samples.count))
        updateBaseline("lyrics.waveTimeline.delayOverrun.ms", value: maxDelayOverrun * 1000)

        updateActiveInteractions { trace in
            incrementMetric("lyricsWaveTimelineSampleCount", by: Double(samples.count), in: &trace.metrics)
            incrementMetric("lyricsWaveScheduledRowCount", by: Double(scheduledCount), in: &trace.metrics)
            incrementMetric("lyricsWaveFiredRowCount", by: Double(firedCount), in: &trace.metrics)
            maximizeMetric("maxLyricsWaveDelayOverrunMs", value: maxDelayOverrun * 1000, in: &trace.metrics)
        }

        writeLiveLyricWaveTimelineSamples(samples)
        trimBuffers()
    }

    public func recordLyricsLineMotionCaptureMiss(
        track: DiagnosticTrackContext,
        playbackTime: TimeInterval,
        lyricLineCount: Int,
        displayLineCount: Int,
        displayIndex: Int,
        monitoringEnabled: Bool
    ) {
        guard isEnabled else { return }
        lyricLineMotionCaptureMissCount += 1
        latestLyricLineMotionCaptureMissAt = Date()
        lastLyricLineMotionCaptureDisplayLineCount = displayLineCount
        lastLyricLineMotionCaptureMonitoringEnabled = monitoringEnabled

        var snapshot = liveMotionSnapshot ?? DiagnosticLiveMotionSnapshot(
            timestamp: Date(),
            trackTitle: track.title,
            trackArtist: track.artist,
            playbackTime: playbackTime,
            activeIndex: -1,
            displayIndex: displayIndex,
            targetIndex: -1,
            sampleCount: 0,
            capturedFirstLineIndex: -1,
            capturedLastLineIndex: -1,
            maxTargetErrorY: 0,
            maxInterLineErrorY: 0,
            maxVelocityY: 0,
            staleStaticLineCount: 0,
            fieldTargetMismatchCount: 0,
            maxFieldTargetDistance: 0,
            wavePropagationLineCount: 0,
            activeTargetLagged: false,
            activeVisualElapsedMs: 0,
            lateActiveTarget: false,
            lingeringWaveBacklog: false,
            latestFrameDeltaMs: latestFrameDeltaMs,
            recentFrameStallCount: recentFrameStallTicks.count,
            captureMissCount: lyricLineMotionCaptureMissCount,
            latestCaptureMissAt: latestLyricLineMotionCaptureMissAt,
            captureMissDisplayLineCount: displayLineCount,
            captureMissMonitoringEnabled: monitoringEnabled
        )
        snapshot.timestamp = Date()
        snapshot.trackTitle = track.title
        snapshot.trackArtist = track.artist
        snapshot.playbackTime = playbackTime
        snapshot.displayIndex = displayIndex
        snapshot.latestFrameDeltaMs = latestFrameDeltaMs
        snapshot.recentFrameStallCount = recentFrameStallTicks.count
        snapshot.captureMissCount = lyricLineMotionCaptureMissCount
        snapshot.latestCaptureMissAt = latestLyricLineMotionCaptureMissAt
        snapshot.captureMissDisplayLineCount = displayLineCount
        snapshot.captureMissMonitoringEnabled = monitoringEnabled
        liveMotionSnapshot = snapshot

        recordEvent(
            "diagnostics.lyricsLineMotionCaptureMissed",
            detail: "Line-motion diagnostics requested a frame sample but no lyric line geometry arrived before timeout.",
            track: track,
            metrics: [
                "playbackTime": playbackTime,
                "lyricLineCount": Double(lyricLineCount),
                "displayLineCount": Double(displayLineCount),
                "displayIndex": Double(displayIndex),
                "monitoringEnabled": monitoringEnabled ? 1 : 0
            ]
        )
    }

    private func updateLiveMotionSnapshot(with samples: [DiagnosticLyricLineMotionSample]) {
        let stableSamples = samples.filter { !$0.isManualScrolling && !$0.isInitialMotionSuppressed }
        let visibleSamples = stableSamples.isEmpty ? samples : stableSamples
        guard let sample = visibleSamples.first else { return }

        let maxTargetError = visibleSamples.map { abs($0.targetErrorY) }.max() ?? 0
        let maxInterLineError = visibleSamples.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
        let maxVelocity = visibleSamples.map { abs($0.velocityY) }.max() ?? 0
        let staleStaticCount = visibleSamples.filter(isStaleStaticLyricLineMotionSample).count
        let capturedFirstLineIndex = visibleSamples.map(\.lineIndex).min() ?? -1
        let capturedLastLineIndex = visibleSamples.map(\.lineIndex).max() ?? -1
        let fieldTargetMismatches = visibleSamples.filter { $0.targetIndex != $0.activeIndex }.count
        let maxFieldTargetDistance = visibleSamples.map { abs($0.targetIndex - $0.activeIndex) }.max() ?? 0
        let wavePropagationLines = visibleSamples.filter {
            abs($0.lineIndex - $0.activeIndex) <= 4 && $0.targetIndex != $0.activeIndex
        }.count
        let activeSample = visibleSamples.first { $0.lineIndex == $0.activeIndex }
        let activeVisualElapsed = activeSample.map { visualElapsedForActiveState(sample: $0) } ?? 0
        let activeTargetLagged = activeSample.map { $0.targetIndex != $0.activeIndex } ?? false
        let lateActiveTarget = activeVisualElapsed > 0.55 && activeTargetLagged && wavePropagationLines >= 4
        let lingeringWaveBacklog = activeVisualElapsed > 0.90 && wavePropagationLines >= 4

        liveMotionSnapshot = DiagnosticLiveMotionSnapshot(
            timestamp: sample.timestamp,
            trackTitle: sample.trackTitle,
            trackArtist: sample.trackArtist,
            playbackTime: sample.playbackTime,
            activeIndex: sample.activeIndex,
            displayIndex: sample.displayIndex,
            targetIndex: activeSample?.targetIndex ?? sample.targetIndex,
            sampleCount: samples.count,
            capturedFirstLineIndex: capturedFirstLineIndex,
            capturedLastLineIndex: capturedLastLineIndex,
            maxTargetErrorY: maxTargetError,
            maxInterLineErrorY: maxInterLineError,
            maxVelocityY: maxVelocity,
            staleStaticLineCount: staleStaticCount,
            fieldTargetMismatchCount: fieldTargetMismatches,
            maxFieldTargetDistance: maxFieldTargetDistance,
            wavePropagationLineCount: wavePropagationLines,
            activeTargetLagged: activeTargetLagged,
            activeVisualElapsedMs: activeVisualElapsed * 1000,
            lateActiveTarget: lateActiveTarget,
            lingeringWaveBacklog: lingeringWaveBacklog,
            latestFrameDeltaMs: latestFrameDeltaMs,
            recentFrameStallCount: recentFrameStallTicks.count,
            captureMissCount: lyricLineMotionCaptureMissCount,
            latestCaptureMissAt: latestLyricLineMotionCaptureMissAt,
            captureMissDisplayLineCount: lastLyricLineMotionCaptureDisplayLineCount,
            captureMissMonitoringEnabled: lastLyricLineMotionCaptureMonitoringEnabled
        )
    }

    public func recordScriptingBridgeTiming(
        operation: String,
        queueWait: TimeInterval,
        readTime: TimeInterval,
        timedOut: Bool
    ) {
        guard isEnabled else { return }
        let overlapsActiveInteraction = !activeInteractions.isEmpty
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

        let hasQueueBacklog = queueWait > 0.25
        let hasCorrelatedReadStall = overlapsActiveInteraction && readTime >= correlatedScriptingBridgeReadIncidentThreshold
        let hasSevereStandaloneReadStall = !overlapsActiveInteraction
            && readTime >= severeStandaloneScriptingBridgeReadIncidentThreshold
        let hasBaselineStandaloneSlowRead = isBaselineStandaloneSlowRead(
            operation: operation,
            queueWait: queueWait,
            readTime: readTime,
            overlapsActiveInteraction: overlapsActiveInteraction
        )
        guard hasQueueBacklog || hasCorrelatedReadStall || hasSevereStandaloneReadStall || hasBaselineStandaloneSlowRead else { return }
        if hasBaselineStandaloneSlowRead {
            recordEvent(
                operation == "pollPositionViaSB"
                    ? "scriptingBridge.positionPoll.slowReadBaseline"
                    : "scriptingBridge.standaloneSlowReadBaseline",
                detail: "\(operation) had an isolated slow read without queue backlog or active interaction overlap.",
                metrics: [
                    "queueWaitMs": queueWait * 1000,
                    "readMs": readTime * 1000
                ]
            )
            return
        }
        recordIncident(
            category: hasQueueBacklog ? .scriptingBridgeBacklog : .scriptingBridgeLatency,
            severity: queueWait > 1.0 || readTime > 0.5 ? .critical : .warning,
            title: hasQueueBacklog ? "ScriptingBridge queue backlog" : "ScriptingBridge slow response",
            detail: "\(operation) waited \(formatMilliseconds(queueWait)) and read in \(formatMilliseconds(readTime)).",
            metrics: ["queueWaitMs": queueWait * 1000, "readMs": readTime * 1000],
            evidence: ["operation": operation]
        )
    }

    private func isBaselineStandaloneSlowRead(
        operation: String,
        queueWait: TimeInterval,
        readTime: TimeInterval,
        overlapsActiveInteraction: Bool
    ) -> Bool {
        guard !overlapsActiveInteraction else { return false }
        guard queueWait <= 0.25 else { return false }
        return readTime >= correlatedScriptingBridgeReadIncidentThreshold
            && readTime < severeStandaloneScriptingBridgeReadIncidentThreshold
    }

    @discardableResult
    public func recordManualReport(
        symptom: DiagnosticUserSymptom,
        note: String,
        track: DiagnosticTrackContext,
        mediaAttachments: [URL] = []
    ) throws -> URL {
        let resolvedSymptom = DiagnosticUserSymptom.inferred(from: symptom, note: note)
        let resolvedTrack = bestAvailableTrackContext(preferred: track)
        recordIncident(
            category: .lyricsManualReport,
            severity: .warning,
            title: "Manual report: \(resolvedSymptom.rawValue)",
            detail: note.isEmpty ? "User reported \(resolvedSymptom.rawValue)." : note,
            automaticallyDetected: false,
            userSymptom: resolvedSymptom,
            track: resolvedTrack.track,
            evidence: resolvedTrack.evidence
        )
        return try exportReportBundle(userSymptom: resolvedSymptom, userNote: note, track: resolvedTrack.track, mediaAttachments: mediaAttachments)
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
        let reportIncidents = scopedIncidents(
            for: resolvedTrack.track,
            userSymptom: userSymptom,
            userNote: userNote,
            generatedAt: reportGeneratedAt
        )
        let reportInteractions = scopedInteractions(for: resolvedTrack.track)
        let reportLineMotionSamples = scopedLyricLineMotionSamples(
            for: resolvedTrack.track,
            userSymptom: userSymptom,
            userNote: userNote,
            generatedAt: reportGeneratedAt
        )
        let reportEvents = scopedEvents(
            for: resolvedTrack.track,
            lineMotionSamples: reportLineMotionSamples,
            userSymptom: userSymptom,
            userNote: userNote,
            generatedAt: reportGeneratedAt
        )
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
        configureDebugLoggerForCurrentSession()
        if healthSampler == nil {
            healthSampler = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.sampleProcessHealth()
                }
            }
        }
        suppressStandaloneFrameStallsUntil = max(
            suppressStandaloneFrameStallsUntil,
            Date().addingTimeInterval(startupStandaloneFrameStallSuppressionDuration)
        )
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

    @discardableResult
    private func enrichTrackContext(
        _ existing: inout DiagnosticTrackContext?,
        with context: DiagnosticTrackContext
    ) -> Bool {
        guard var current = existing,
              current.hasCredibleIdentity,
              (current.matchesReportTrack(context) || current.matchesReportTrackByTitleArtist(context)) else {
            return false
        }

        let original = current
        let sameTitleArtist = current.matchesReportTrackByTitleArtist(context)
        let incomingPID = context.persistentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let currentPID = current.persistentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !incomingPID.isEmpty && (currentPID.isEmpty || sameTitleArtist) {
            current.persistentID = incomingPID
        }
        if current.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !context.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.album = context.album
        }
        if current.duration <= 0, context.duration > 0 {
            current.duration = context.duration
        }
        if (current.trackClass ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let trackClass = context.trackClass,
           !trackClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.trackClass = trackClass
        }
        if (current.playlistName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let playlistName = context.playlistName,
           !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.playlistName = playlistName
        }
        let currentPlaybackContext = (current.playbackContext ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if currentPlaybackContext.isEmpty || currentPlaybackContext == "unknown",
           let playbackContext = context.playbackContext,
           !playbackContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.playbackContext = playbackContext
        }
        if (current.playerPage ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let playerPage = context.playerPage,
           !playerPage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.playerPage = playerPage
        }

        guard current != original else { return false }
        existing = current
        return true
    }

    private func scopedIncidents(
        for track: DiagnosticTrackContext?,
        userSymptom: DiagnosticUserSymptom?,
        userNote: String,
        generatedAt: Date
    ) -> [DiagnosticIncident] {
        guard let track, track.hasCredibleIdentity else { return incidents }
        var scoped = incidents.filter { incident in
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
        if shouldUseTimeScopedArtworkFallback(userSymptom: userSymptom, userNote: userNote),
           !scoped.contains(where: { $0.category == .artworkBlocking }) {
            let existingIDs = Set(scoped.map(\.id))
            let recentArtworkIncidents = incidents.filter { incident in
                incident.category == .artworkBlocking
                    && !existingIDs.contains(incident.id)
                    && abs(generatedAt.timeIntervalSince(incident.timestamp)) <= artworkReportFallbackLookback
            }
            scoped.append(contentsOf: recentArtworkIncidents)
        }
        return scoped
    }

    private func scopedEvents(
        for track: DiagnosticTrackContext?,
        lineMotionSamples reportLineMotionSamples: [DiagnosticLyricLineMotionSample],
        userSymptom: DiagnosticUserSymptom?,
        userNote: String,
        generatedAt: Date
    ) -> [DiagnosticEvent] {
        var scoped: [DiagnosticEvent]
        guard let track, track.hasCredibleIdentity else { return events }
        scoped = events.filter { event in
            guard let eventTrack = event.track else { return true }
            return eventTrack.matchesReportTrack(track)
        }
        if shouldUseTimeScopedLineMotionFallback(userSymptom: userSymptom, userNote: userNote),
           !reportLineMotionSamples.isEmpty,
           !reportLineMotionSamples.allSatisfy({ lineMotionSample($0, matches: track) }) {
            scoped.insert(
                DiagnosticEvent(
                    timestamp: generatedAt,
                    name: "diagnostics.lyricsLineMotionTimeScopedFallback",
                    detail: "Included recent lyrics-page motion samples by report time because no exact current-track motion rows were available.",
                    track: track,
                    metrics: [
                        "sampleCount": Double(reportLineMotionSamples.count),
                        "lookbackSeconds": lineMotionReportFallbackLookback
                    ]
                ),
                at: 0
            )
        }
        if shouldUseTimeScopedArtworkFallback(userSymptom: userSymptom, userNote: userNote),
           !scoped.contains(where: { $0.name.hasPrefix("artwork.") }) {
            let existingIDs = Set(scoped.map(\.id))
            let recentArtworkEvents = events.filter { event in
                event.name.hasPrefix("artwork.")
                    && !existingIDs.contains(event.id)
                    && abs(generatedAt.timeIntervalSince(event.timestamp)) <= artworkReportFallbackLookback
            }
            if !recentArtworkEvents.isEmpty {
                scoped.insert(
                    DiagnosticEvent(
                        timestamp: generatedAt,
                        name: "diagnostics.artworkTimeScopedFallback",
                        detail: "Included recent artwork events by report time because no exact current-track artwork rows were available.",
                        track: track,
                        metrics: [
                            "eventCount": Double(recentArtworkEvents.count),
                            "lookbackSeconds": artworkReportFallbackLookback
                        ]
                    ),
                    at: 0
                )
                scoped.append(contentsOf: recentArtworkEvents)
            }
        }
        return scoped
    }

    private func scopedInteractions(for track: DiagnosticTrackContext?) -> [DiagnosticInteractionTrace] {
        guard let track, track.hasCredibleIdentity else { return interactions }
        return interactions.filter { interaction in
            guard let interactionTrack = interaction.track else { return true }
            return interactionTrack.matchesReportTrack(track)
        }
    }

    private func scopedLyricLineMotionSamples(
        for track: DiagnosticTrackContext?,
        userSymptom: DiagnosticUserSymptom?,
        userNote: String,
        generatedAt: Date
    ) -> [DiagnosticLyricLineMotionSample] {
        guard let track, track.hasCredibleIdentity else { return lyricLineMotionSamples }
        let exact = lyricLineMotionSamples.filter { lineMotionSample($0, matches: track) }
        guard exact.isEmpty,
              shouldUseTimeScopedLineMotionFallback(userSymptom: userSymptom, userNote: userNote)
        else {
            return exact
        }

        return lyricLineMotionSamples.filter { sample in
            sample.page == "lyrics"
                && abs(generatedAt.timeIntervalSince(sample.timestamp)) <= lineMotionReportFallbackLookback
        }
    }

    private let lineMotionReportFallbackLookback: TimeInterval = 90
    private let artworkReportFallbackLookback: TimeInterval = 150

    private func shouldUseTimeScopedLineMotionFallback(
        userSymptom: DiagnosticUserSymptom?,
        userNote: String
    ) -> Bool {
        if userSymptom == .visibleStutter
            || userSymptom == .lyricsTimingOff
            || userSymptom == .switchingAnimationInterrupted
            || userSymptom == .switchingBlackout {
            return true
        }

        let normalizedNote = userNote.lowercased()
        let motionKeywords = [
            "animation", "animate", "motion", "stutter", "stuck", "lag", "glitch",
            "switch", "next", "previous", "frame", "jank",
            "动画", "动效", "卡顿", "卡住", "卡", "切换", "下一首", "上一首", "掉帧", "不丝滑"
        ]
        return motionKeywords.contains { normalizedNote.contains($0) }
    }

    private func shouldUseTimeScopedArtworkFallback(
        userSymptom: DiagnosticUserSymptom?,
        userNote: String
    ) -> Bool {
        if userSymptom == .artworkMissing
            || userSymptom == .artworkLateOrWrong
            || userSymptom == .artworkStaleAfterSwitch
            || userSymptom == .switchingBlackout {
            return true
        }

        let normalizedNote = userNote.lowercased()
        let artworkKeywords = [
            "artwork", "cover", "album art", "stale cover", "late cover",
            "封面", "专辑图", "專輯圖", "慢一步", "黑掉", "变黑", "變黑"
        ]
        return artworkKeywords.contains { normalizedNote.contains($0) }
    }

    private func lineMotionSample(
        _ sample: DiagnosticLyricLineMotionSample,
        matches track: DiagnosticTrackContext
    ) -> Bool {
        MetadataDiskCache.normalize(sample.trackTitle) == MetadataDiskCache.normalize(track.title)
            && MetadataDiskCache.normalize(sample.trackArtist) == MetadataDiskCache.normalize(track.artist)
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

        let isEmptyLyricsLoadingSwitch = trace.type == .pageSwitch
            && isLyricsPage
            && (trace.metrics["isLoadingLyrics"] ?? 0) > 0
            && (trace.metrics["lyricLineCount"] ?? 0) == 0
            && (trace.metrics["currentLineIndex"] ?? -1) < 0
        if isEmptyLyricsLoadingSwitch && !hasBridgeIssue && !hasCPUIssue {
            recordEvent(
                "interaction.loadingLyricsPageSwitchBaseline",
                detail: "Lyrics page switch completed while the page was still an empty loading state.",
                track: trace.track,
                metrics: trace.metrics
            )
            return
        }

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
        let previousMotionSampleCount = lyricLineMotionSamples.count
        events.removeAll { $0.timestamp < cutoff }
        let freshIncidents = incidents.filter { $0.timestamp >= cutoff }
        if freshIncidents.count != incidents.count {
            incidents = freshIncidents
        }
        let freshInteractions = interactions.filter { $0.startedAt >= cutoff }
        if freshInteractions.count != interactions.count {
            interactions = freshInteractions
        }
        lyricLineMotionSamples.removeAll { $0.timestamp < cutoff }
        normalizeLegacyHighCPUIncidents()
        coalesceStandaloneFrameStallIncidents()
        coalesceLyricLineMotionIncidents()
        coalesceScriptingBridgeIncidents()
        coalesceMemoryIncidents()
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        if incidents.count > maxIncidents {
            incidents = Array(incidents.prefix(maxIncidents))
        }
        if interactions.count > maxInteractions {
            interactions = Array(interactions.prefix(maxInteractions))
        }
        if lyricLineMotionSamples.count > maxLyricLineMotionSamples {
            lyricLineMotionSamples.removeLast(lyricLineMotionSamples.count - maxLyricLineMotionSamples)
        }
        updateLyricLineMotionSampleCount(force: lyricLineMotionSamples.count != previousMotionSampleCount)
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

        replaceIncidentsIfChanged(compacted.filter { shouldRecordStandaloneFrameStallIncident($0) })
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

        replaceIncidentsIfChanged(compacted)
    }

    private func coalesceScriptingBridgeIncidents() {
        guard incidents.count > 1 else { return }

        var compacted: [DiagnosticIncident] = []
        var bucketIndexBySignature: [String: Int] = [:]
        compacted.reserveCapacity(incidents.count)

        for incident in incidents {
            guard let signature = scriptingBridgeCoalesceSignature(for: incident) else {
                compacted.append(incident)
                continue
            }

            if let index = bucketIndexBySignature[signature] {
                compacted[index] = mergeScriptingBridgeIncident(incident, into: compacted[index])
            } else {
                bucketIndexBySignature[signature] = compacted.count
                compacted.append(normalizedScriptingBridgeIncident(incident, signature: signature))
            }
        }

        replaceIncidentsIfChanged(compacted)
    }

    private func coalesceMemoryIncidents() {
        guard incidents.count > 1 else { return }

        var compacted: [DiagnosticIncident] = []
        var bucketIndexBySignature: [String: Int] = [:]
        compacted.reserveCapacity(incidents.count)

        for incident in incidents {
            guard let signature = memoryCoalesceSignature(for: incident) else {
                compacted.append(incident)
                continue
            }

            if let index = bucketIndexBySignature[signature] {
                compacted[index] = mergeMemoryIncident(incident, into: compacted[index])
            } else {
                bucketIndexBySignature[signature] = compacted.count
                compacted.append(normalizedMemoryIncident(incident, signature: signature))
            }
        }

        replaceIncidentsIfChanged(compacted)
    }

    private func refreshLastWarningAfterIncidentNormalization() {
        guard let lastWarning else { return }
        let nextWarning = incidents.first(where: { $0.id == lastWarning.id }) ?? severeOrRepeatedIssue
        if self.lastWarning != nextWarning {
            self.lastWarning = nextWarning
        }
    }

    private func replaceIncidentsIfChanged(_ nextIncidents: [DiagnosticIncident]) {
        guard incidents != nextIncidents else { return }
        incidents = nextIncidents
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

    private func scriptingBridgeCoalesceSignature(for incident: DiagnosticIncident) -> String? {
        guard incident.automaticallyDetected,
              incident.category == .scriptingBridgeLatency
                || incident.category == .scriptingBridgeTimeout
                || incident.category == .scriptingBridgeBacklog else {
            return nil
        }
        let operation = incident.evidence["operation"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOperation = operation?.isEmpty == false ? operation! : "unknown"
        let bucket = floor(incident.timestamp.timeIntervalSince1970 / scriptingBridgeCoalesceWindow)
        return "scriptingBridge|\(incident.category.rawValue)|\(normalizedOperation)|\(Int(bucket))"
    }

    private func memoryCoalesceSignature(for incident: DiagnosticIncident) -> String? {
        guard incident.category == .memorySpike,
              incident.automaticallyDetected else {
            return nil
        }
        let bucket = floor(incident.timestamp.timeIntervalSince1970 / memoryCoalesceWindow)
        return "memorySpike|\(Int(bucket))"
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

    private func shouldRecordStandaloneFrameStallIncident(_ incident: DiagnosticIncident) -> Bool {
        guard standaloneFrameStallCoalesceSignature(for: incident) != nil else { return true }
        let maxDelta = incident.metrics["maxDeltaMs"] ?? incident.metrics["deltaMs"] ?? 0
        if maxDelta >= severeStandaloneFrameStallThreshold * 1000 { return true }
        let occurrenceCount = Int(incident.metrics["occurrenceCount"] ?? 1)
        if maxDelta >= criticalStandaloneFrameStallThreshold * 1000 {
            return occurrenceCount >= standaloneCriticalFrameStallIncidentThreshold
        }
        return occurrenceCount >= standaloneWarningFrameStallIncidentThreshold
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
            "maxActiveTopClipPt",
            "maxActiveBottomClipPt",
            "maxLineTopClipPt",
            "maxLineBottomClipPt",
            "laggedNearbyTargetCount",
            "activeLineElapsedMs",
            "activeTargetLagged",
            "lingeringWaveBacklog",
            "activeViewportClip",
            "lineViewportClip"
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
        let presentation = lyricLineMotionBurstPresentation(for: merged, count: Int(count))
        merged.title = presentation.title
        merged.detail = presentation.detail(maxTarget, maxInterLine)
        return merged
    }

    private func lyricLineMotionBurstPresentation(
        for incident: DiagnosticIncident,
        count: Int
    ) -> (title: String, detail: (Double, Double) -> String) {
        let hasViewportClip = (incident.metrics["activeViewportClip"] ?? 0) > 0
            || (incident.metrics["lineViewportClip"] ?? 0) > 0
            || (incident.metrics["maxActiveTopClipPt"] ?? 0) > 8
            || (incident.metrics["maxActiveBottomClipPt"] ?? 0) > 8
            || (incident.metrics["maxLineTopClipPt"] ?? 0) > 8
            || (incident.metrics["maxLineBottomClipPt"] ?? 0) > 8
        let hasMotionDrift = (incident.metrics["maxTargetErrorPt"] ?? 0) > 32
            || (incident.metrics["maxInterLineErrorPt"] ?? 0) > 18
            || (incident.metrics["activeTargetLagged"] ?? 0) > 0
            || (incident.metrics["lingeringWaveBacklog"] ?? 0) > 0

        if hasViewportClip && !hasMotionDrift {
            return (
                "Lyrics line clipped burst",
                { _, _ in
                    let maxTop = max(
                        incident.metrics["maxActiveTopClipPt"] ?? 0,
                        incident.metrics["maxLineTopClipPt"] ?? 0
                    )
                    let maxBottom = max(
                        incident.metrics["maxActiveBottomClipPt"] ?? 0,
                        incident.metrics["maxLineBottomClipPt"] ?? 0
                    )
                    return "\(count) viewport-clip samples for this track; max top clip \(String(format: "%.0f", maxTop))pt, max bottom clip \(String(format: "%.0f", maxBottom))pt."
                }
            )
        }

        return (
            "Lyrics line motion drift burst",
            { maxTarget, maxInterLine in
                "\(count) line-motion drift samples for this track; max target error \(String(format: "%.0f", maxTarget))pt, max spacing error \(String(format: "%.0f", maxInterLine))pt."
            }
        )
    }

    private func normalizedScriptingBridgeIncident(
        _ incident: DiagnosticIncident,
        signature: String
    ) -> DiagnosticIncident {
        var normalized = incident
        normalized.metrics["occurrenceCount"] = max(normalized.metrics["occurrenceCount"] ?? 1, 1)
        normalized.metrics["maxReadMs"] = max(
            normalized.metrics["maxReadMs"] ?? 0,
            normalized.metrics["readMs"] ?? 0
        )
        normalized.metrics["maxQueueWaitMs"] = max(
            normalized.metrics["maxQueueWaitMs"] ?? 0,
            normalized.metrics["queueWaitMs"] ?? 0
        )
        normalized.metrics["firstTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.metrics["lastTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.evidence["signature"] = signature
        normalized.evidence["coalescedWindowSeconds"] = "\(Int(scriptingBridgeCoalesceWindow))"
        return normalized
    }

    private func mergeScriptingBridgeIncident(
        _ incoming: DiagnosticIncident,
        into representative: DiagnosticIncident
    ) -> DiagnosticIncident {
        var merged = representative
        let count = (merged.metrics["occurrenceCount"] ?? 1) + (incoming.metrics["occurrenceCount"] ?? 1)
        let incomingRead = incoming.metrics["readMs"] ?? incoming.metrics["maxReadMs"] ?? 0
        let incomingQueueWait = incoming.metrics["queueWaitMs"] ?? incoming.metrics["maxQueueWaitMs"] ?? 0
        let maxRead = max(merged.metrics["maxReadMs"] ?? merged.metrics["readMs"] ?? 0, incomingRead)
        let maxQueueWait = max(merged.metrics["maxQueueWaitMs"] ?? merged.metrics["queueWaitMs"] ?? 0, incomingQueueWait)
        let firstTimestamp = min(
            merged.metrics["firstTimestampEpoch"] ?? merged.timestamp.timeIntervalSince1970,
            incoming.timestamp.timeIntervalSince1970
        )
        let lastTimestamp = max(
            merged.metrics["lastTimestampEpoch"] ?? merged.timestamp.timeIntervalSince1970,
            incoming.timestamp.timeIntervalSince1970
        )

        merged.metrics["occurrenceCount"] = count
        merged.metrics["readMs"] = maxRead
        merged.metrics["maxReadMs"] = maxRead
        merged.metrics["queueWaitMs"] = maxQueueWait
        merged.metrics["maxQueueWaitMs"] = maxQueueWait
        merged.metrics["firstTimestampEpoch"] = firstTimestamp
        merged.metrics["lastTimestampEpoch"] = lastTimestamp
        if incoming.severity == .critical {
            merged.severity = .critical
        }
        if merged.evidence["signature"] == nil,
           let signature = scriptingBridgeCoalesceSignature(for: merged) {
            merged.evidence["signature"] = signature
        }
        merged.evidence["coalescedWindowSeconds"] = "\(Int(scriptingBridgeCoalesceWindow))"
        let operation = merged.evidence["operation"] ?? "ScriptingBridge"
        let maxReadText = String(format: "%.0f", maxRead)
        if merged.category == .scriptingBridgeTimeout {
            merged.title = "ScriptingBridge timeout burst"
            merged.detail = "\(operation) timed out \(Int(count)) times in \(Int(scriptingBridgeCoalesceWindow))s; max read \(maxReadText)ms."
        } else if merged.category == .scriptingBridgeBacklog {
            merged.title = "ScriptingBridge queue backlog burst"
            merged.detail = "\(operation) had \(Int(count)) backlog samples in \(Int(scriptingBridgeCoalesceWindow))s; max queue wait \(String(format: "%.0f", maxQueueWait))ms."
        } else {
            merged.title = "ScriptingBridge slow response burst"
            merged.detail = "\(operation) had \(Int(count)) slow reads in \(Int(scriptingBridgeCoalesceWindow))s; max read \(maxReadText)ms."
        }
        return merged
    }

    private func normalizedMemoryIncident(
        _ incident: DiagnosticIncident,
        signature: String
    ) -> DiagnosticIncident {
        var normalized = incident
        let rss = normalized.metrics["rssMB"] ?? normalized.metrics["maxRSSMB"] ?? 0
        normalized.metrics["occurrenceCount"] = max(normalized.metrics["occurrenceCount"] ?? 1, 1)
        normalized.metrics["maxRSSMB"] = max(normalized.metrics["maxRSSMB"] ?? rss, rss)
        normalized.metrics["minRSSMB"] = min(
            normalized.metrics["minRSSMB"] ?? normalized.metrics["minRecentRSSMB"] ?? rss,
            normalized.metrics["minRecentRSSMB"] ?? rss
        )
        normalized.metrics["maxMemoryGrowthMB"] = max(
            normalized.metrics["maxMemoryGrowthMB"] ?? 0,
            normalized.metrics["memoryGrowthMB"] ?? 0
        )
        normalized.metrics["maxCPUPercent"] = max(
            normalized.metrics["maxCPUPercent"] ?? 0,
            normalized.metrics["cpuPercent"] ?? 0
        )
        normalized.metrics["firstTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.metrics["lastTimestampEpoch"] = normalized.timestamp.timeIntervalSince1970
        normalized.evidence["signature"] = signature
        normalized.evidence["coalescedWindowSeconds"] = "\(Int(memoryCoalesceWindow))"
        normalized.title = "Memory pressure burst"
        normalized.detail = memoryBurstDetail(for: normalized)
        return normalized
    }

    private func mergeMemoryIncident(
        _ incoming: DiagnosticIncident,
        into representative: DiagnosticIncident
    ) -> DiagnosticIncident {
        var merged = representative
        let incomingRSS = incoming.metrics["rssMB"] ?? incoming.metrics["maxRSSMB"] ?? 0
        let incomingMinRSS = incoming.metrics["minRSSMB"] ?? incoming.metrics["minRecentRSSMB"] ?? incomingRSS
        let incomingGrowth = incoming.metrics["memoryGrowthMB"] ?? incoming.metrics["maxMemoryGrowthMB"] ?? 0
        let incomingCPU = incoming.metrics["cpuPercent"] ?? incoming.metrics["maxCPUPercent"] ?? 0
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
        merged.metrics["rssMB"] = max(merged.metrics["rssMB"] ?? merged.metrics["maxRSSMB"] ?? 0, incomingRSS)
        merged.metrics["maxRSSMB"] = max(merged.metrics["maxRSSMB"] ?? 0, incomingRSS)
        merged.metrics["minRSSMB"] = min(merged.metrics["minRSSMB"] ?? incomingMinRSS, incomingMinRSS)
        merged.metrics["maxMemoryGrowthMB"] = max(merged.metrics["maxMemoryGrowthMB"] ?? 0, incomingGrowth)
        merged.metrics["maxCPUPercent"] = max(merged.metrics["maxCPUPercent"] ?? 0, incomingCPU)
        merged.metrics["firstTimestampEpoch"] = firstTimestamp
        merged.metrics["lastTimestampEpoch"] = lastTimestamp
        if incoming.severity == .critical {
            merged.severity = .critical
        }
        if merged.evidence["signature"] == nil,
           let signature = memoryCoalesceSignature(for: merged) {
            merged.evidence["signature"] = signature
        }
        merged.evidence["coalescedWindowSeconds"] = "\(Int(memoryCoalesceWindow))"
        merged.title = "Memory pressure burst"
        merged.detail = memoryBurstDetail(for: merged)
        return merged
    }

    private func memoryBurstDetail(for incident: DiagnosticIncident) -> String {
        let count = Int(incident.metrics["occurrenceCount"] ?? 1)
        let maxRSS = incident.metrics["maxRSSMB"] ?? incident.metrics["rssMB"] ?? 0
        let growth = incident.metrics["maxMemoryGrowthMB"] ?? incident.metrics["memoryGrowthMB"] ?? 0
        if growth >= memoryGrowthWarningMB {
            return "\(count) elevated memory samples in \(Int(memoryCoalesceWindow / 60))m; max resident memory \(String(format: "%.0f", maxRSS)) MB, max short-window growth \(String(format: "%.0f", growth)) MB."
        }
        return "\(count) elevated memory samples in \(Int(memoryCoalesceWindow / 60))m; max resident memory \(String(format: "%.0f", maxRSS)) MB."
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
            try? await Task.sleep(nanoseconds: 8_000_000_000)
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
            removeLiveLyricLineMotionSamples()
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
        pendingStandaloneFrameStalls.removeAll()
        recentMemorySamples.removeAll()
        baselineStats.removeAll()
        artworkFetchStarts.removeAll()
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
        liveMotionWriteQueue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func removeLiveLyricWaveTimelineSamples() {
        guard let url = try? liveLyricWaveTimelineSamplesURL() else { return }
        liveWaveTimelineWriteQueue.sync {
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
        let physicalFootprint = currentPhysicalFootprintMB()
        recordProcessHealthSample(cpu: cpu, rss: rss, physicalFootprint: physicalFootprint)
    }

    private func recordProcessHealthSample(cpu: Double?, rss: Double?, physicalFootprint: Double?) {
        var metrics: [String: Double] = [:]

        if let cpu {
            metrics["cpuPercent"] = cpu
            updateBaseline("process.cpu.percent", value: cpu)
        }
        if let rss {
            metrics["rssMB"] = rss
            updateBaseline("process.rss.mb", value: rss)
        }
        if let physicalFootprint {
            metrics["physicalFootprintMB"] = physicalFootprint
            updateBaseline("process.physical_footprint.mb", value: physicalFootprint)
        }
        updateActiveInteractions { trace in
            if let cpu {
                maximizeMetric("maxCPUPercent", value: cpu, in: &trace.metrics)
            }
            if let rss {
                maximizeMetric("maxRSSMB", value: rss, in: &trace.metrics)
            }
            if let physicalFootprint {
                maximizeMetric("maxPhysicalFootprintMB", value: physicalFootprint, in: &trace.metrics)
            }
        }

        guard !metrics.isEmpty else { return }
        recordEvent("process.health.sample", detail: "CPU/memory sample", metrics: metrics)

        if let cpu {
            recordHighCPUIncidentIfNeeded(cpu: cpu, metrics: metrics)
        }
        if let memory = physicalFootprint ?? rss {
            recordMemoryIncidentIfNeeded(memory: memory, metrics: metrics)
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

    private func recordMemoryIncidentIfNeeded(memory: Double, metrics: [String: Double]) {
        let now = Date()
        recentMemorySamples.append((timestamp: now, rss: memory))
        recentMemorySamples.removeAll { now.timeIntervalSince($0.timestamp) > memorySampleWindow }

        let minRecentMemory = recentMemorySamples.map(\.rss).min() ?? memory
        let growth = max(0, memory - minRecentMemory)
        let hasAbsolutePressure = memory >= memoryWarningRSSMB
        let hasSharpGrowth = memory >= memoryWarningRSSMB * 0.85 && growth >= memoryGrowthWarningMB
        guard hasAbsolutePressure || hasSharpGrowth else { return }

        let isCritical = memory >= memoryCriticalRSSMB || growth >= memoryGrowthCriticalMB
        var incidentMetrics = metrics
        incidentMetrics["memoryPressureMB"] = memory
        incidentMetrics["minRecentMemoryPressureMB"] = minRecentMemory
        incidentMetrics["memoryGrowthMB"] = growth
        incidentMetrics["memorySampleWindowSeconds"] = memorySampleWindow
        incidentMetrics["memoryWarningRSSMB"] = memoryWarningRSSMB

        let detail: String
        if hasSharpGrowth {
            detail = "Physical memory footprint reached \(String(format: "%.0f", memory)) MB after rising \(String(format: "%.0f", growth)) MB in \(Int(memorySampleWindow))s."
        } else {
            detail = "Physical memory footprint reached \(String(format: "%.0f", memory)) MB."
        }

        recordIncident(
            category: .memorySpike,
            severity: isCritical ? .critical : .warning,
            title: "Memory pressure detected",
            detail: detail,
            metrics: incidentMetrics
        )
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

    private func currentPhysicalFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
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
            if let trackClass = track.trackClass, !trackClass.isEmpty {
                lines.append("- Music track class: \(trackClass)")
            }
            if let playbackContext = track.playbackContext, !playbackContext.isEmpty {
                lines.append("- Playback context: \(playbackContext)")
            }
            if let playlistName = track.playlistName, !playlistName.isEmpty {
                lines.append("- Current playlist: \(playlistName)")
            }
            if let playerPage = track.playerPage, !playerPage.isEmpty {
                lines.append("- nanoPod page: \(playerPage)")
            }
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
            let maxTopClip = report.lyricLineMotionSamples.map(\.activeTopClipY).max() ?? 0
            let maxBottomClip = report.lyricLineMotionSamples.map(\.activeBottomClipY).max() ?? 0
            let maxLineTopClip = report.lyricLineMotionSamples.map(\.lineTopClipY).max() ?? 0
            let maxLineBottomClip = report.lyricLineMotionSamples.map(\.lineBottomClipY).max() ?? 0
            lines.append("- Samples: \(report.lyricLineMotionSamples.count)")
            lines.append("- Max target error: \(String(format: "%.1f", maxTargetError))pt")
            lines.append("- Max inter-line spacing error: \(String(format: "%.1f", maxInterLineError))pt")
            lines.append("- Max observed line velocity: \(String(format: "%.1f", maxVelocity))pt/s")
            lines.append("- Max active line viewport clip: top \(String(format: "%.1f", maxTopClip))pt, bottom \(String(format: "%.1f", maxBottomClip))pt")
            lines.append("- Max sampled line viewport clip: top \(String(format: "%.1f", maxLineTopClip))pt, bottom \(String(format: "%.1f", maxLineBottomClip))pt")
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
            "timestamp,page,trackTitle,trackArtist,lineIndex,lineID,lineStartTime,lineEndTime,playbackTime,activeIndex,displayIndex,targetIndex,renderedMinY,renderedMidY,renderedHeight,targetMinY,targetMidY,targetErrorY,velocityY,observedInterLineDeltaY,expectedInterLineDeltaY,interLineDeltaErrorY,waveOffsetY,manualScrollOffsetY,isManualScrolling,isInitialMotionSuppressed,visibleTopY,visibleBottomY,lineTopClipY,lineBottomClipY,activeTopClipY,activeBottomClipY,controlsVisible"
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
                sample.isInitialMotionSuppressed ? "1" : "0",
                csvNumber(sample.visibleTopY),
                csvNumber(sample.visibleBottomY),
                csvNumber(sample.lineTopClipY),
                csvNumber(sample.lineBottomClipY),
                csvNumber(sample.activeTopClipY),
                csvNumber(sample.activeBottomClipY),
                sample.controlsVisible ? "1" : "0"
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private func lyricWaveTimelineCSV<S: Sequence>(
        samples: S,
        includeHeader: Bool = true
    ) -> String where S.Element == DiagnosticLyricWaveTimelineSample {
        var rows = includeHeader ? [
            "timestamp,page,trackTitle,trackArtist,waveID,phase,lineIndex,oldIndex,newIndex,displayIndex,scheduledDelay,actualDelay,lineInterval,targetRadius,scheduleCount,renderedCount,isActiveLine"
        ] : []
        for sample in samples {
            rows.append([
                Self.csvDateFormatter.string(from: sample.timestamp),
                csv(sample.page),
                csv(sample.trackTitle),
                csv(sample.trackArtist),
                "\(sample.waveID)",
                csv(sample.phase),
                "\(sample.lineIndex)",
                "\(sample.oldIndex)",
                "\(sample.newIndex)",
                "\(sample.displayIndex)",
                csvNumber(sample.scheduledDelay),
                csvNumber(sample.actualDelay),
                csvNumber(sample.lineInterval),
                "\(sample.targetRadius)",
                "\(sample.scheduleCount)",
                "\(sample.renderedCount)",
                sample.isActiveLine ? "1" : "0"
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

    private func writeLiveLyricWaveTimelineSamples(_ samples: [DiagnosticLyricWaveTimelineSample]) {
        guard !samples.isEmpty else { return }
        let header = lyricWaveTimelineCSV(samples: [])
        let rows = lyricWaveTimelineCSV(samples: samples, includeHeader: false)
        guard let data = (rows + "\n").data(using: .utf8) else { return }

        do {
            let url = try liveLyricWaveTimelineSamplesURL()
            liveWaveTimelineWriteQueue.async {
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
                        DiagnosticsService.shared.recordEvent("diagnostics.liveWaveTimelineWriteFailed", detail: error.localizedDescription)
                    }
                }
            }
        } catch {
            recordEvent("diagnostics.liveWaveTimelineWriteFailed", detail: error.localizedDescription)
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
        let abnormalMotionSamples = stableSamples.filter(isAbnormalLyricLineMotionSample)
        let maxAbnormalTargetError = abnormalMotionSamples.map { abs($0.targetErrorY) }.max() ?? 0
        let maxAbnormalInterLineError = abnormalMotionSamples.compactMap { $0.interLineDeltaErrorY.map(abs) }.max() ?? 0
        let staleStaticSamples = stableSamples.filter(isStaleStaticLyricLineMotionSample)
        let maxStaleStaticTargetError = staleStaticSamples.map { abs($0.targetErrorY) }.max() ?? 0
        let maxActiveTopClip = stableSamples.map(\.activeTopClipY).max() ?? 0
        let maxActiveBottomClip = stableSamples.map(\.activeBottomClipY).max() ?? 0
        let viewportRelevantSamples = stableSamples.filter(isViewportRelevantLineMotionSample)
        let maxLineTopClip = viewportRelevantSamples.map(\.lineTopClipY).max() ?? 0
        let maxLineBottomClip = viewportRelevantSamples.map(\.lineBottomClipY).max() ?? 0
        let activeSample = stableSamples.first { $0.lineIndex == $0.activeIndex }
        let activeLineElapsed = activeSample.map { $0.playbackTime - $0.lineStartTime } ?? 0
        let activeVisualElapsed = activeSample.map { visualElapsedForActiveState(sample: $0) } ?? 0
        let laggedNearbyTargets = stableSamples.filter {
            abs($0.lineIndex - $0.activeIndex) <= 4 && $0.targetIndex != $0.activeIndex
        }.count
        let fieldTargetMismatches = stableSamples.filter { $0.targetIndex != $0.activeIndex }.count
        let maxFieldTargetDistance = stableSamples.map { abs($0.targetIndex - $0.activeIndex) }.max() ?? 0
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

        let hasGeometryDrift = maxAbnormalInterLineError > 18 || maxAbnormalTargetError > 32
        let hasLateActiveTarget = activeVisualElapsed > 0.55 && activeTargetLagged && laggedNearbyTargets >= 4
        let hasLingeringWaveBacklog = activeVisualElapsed > 0.90 && laggedNearbyTargets >= 4
        let hasUnevenLineSpacing = maxAbnormalInterLineError > 18
        let hasStaleStaticMotion = activeVisualElapsed > 0.20 && staleStaticSamples.count >= 3
        let hasActiveViewportClip = maxActiveTopClip > 8 || maxActiveBottomClip > 8
        let hasLineViewportClip = maxLineTopClip > 40 || maxLineBottomClip > 40
        guard hasGeometryDrift || hasLateActiveTarget || hasLingeringWaveBacklog || hasStaleStaticMotion || hasActiveViewportClip || hasLineViewportClip else { return }

        let sample = activeSample ?? stableSamples[0]
        let signature = [
            sample.trackTitle,
            sample.trackArtist,
            String(sample.activeIndex),
            String(sample.displayIndex),
            String(sample.targetIndex),
            String(Int(maxAbnormalTargetError / 10)),
            String(Int(maxAbnormalInterLineError / 10)),
            String(Int(maxStaleStaticTargetError / 10)),
            String(Int(max(max(maxActiveTopClip, maxActiveBottomClip), max(maxLineTopClip, maxLineBottomClip)) / 8))
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
            severity: maxAbnormalInterLineError > 28 || maxAbnormalTargetError > 48 || max(max(maxActiveTopClip, maxActiveBottomClip), max(maxLineTopClip, maxLineBottomClip)) > 28 ? .critical : .warning,
            title: (hasActiveViewportClip || hasLineViewportClip) && !hasGeometryDrift ? "Lyrics line clipped" : "Lyrics line motion drift",
            detail: hasActiveViewportClip || hasLineViewportClip
                ? "A rendered lyric line crossed the usable viewport while controls or panel bounds were present."
                : "Rendered lyric lines diverged from their target motion during playback.",
            track: track,
            metrics: [
                "maxTargetErrorPt": maxTargetError,
                "maxInterLineErrorPt": maxInterLineError,
                "maxAbnormalTargetErrorPt": maxAbnormalTargetError,
                "maxAbnormalInterLineErrorPt": maxAbnormalInterLineError,
                "staleStaticLineCount": Double(staleStaticSamples.count),
                "maxStaleStaticTargetErrorPt": maxStaleStaticTargetError,
                "maxActiveTopClipPt": maxActiveTopClip,
                "maxActiveBottomClipPt": maxActiveBottomClip,
                "maxLineTopClipPt": maxLineTopClip,
                "maxLineBottomClipPt": maxLineBottomClip,
                "laggedNearbyTargetCount": Double(laggedNearbyTargets),
                "fieldTargetMismatchCount": Double(fieldTargetMismatches),
                "maxFieldTargetDistance": Double(maxFieldTargetDistance),
                "activeLineElapsedMs": activeLineElapsed * 1000,
                "activeVisualElapsedMs": activeVisualElapsed * 1000,
                "activeTargetLagged": activeTargetLagged ? 1 : 0,
                "lingeringWaveBacklog": hasLingeringWaveBacklog ? 1 : 0,
                "unevenLineSpacing": hasUnevenLineSpacing ? 1 : 0,
                "staleStaticMotion": hasStaleStaticMotion ? 1 : 0,
                "activeViewportClip": hasActiveViewportClip ? 1 : 0,
                "lineViewportClip": hasLineViewportClip ? 1 : 0,
                "controlsVisible": sample.controlsVisible ? 1 : 0
            ],
            evidence: [
                "track": "\(sample.trackTitle) / \(sample.trackArtist)",
                "activeIndex": "\(sample.activeIndex)",
                "displayIndex": "\(sample.displayIndex)",
                "targetIndex": "\(sample.targetIndex)",
                "page": sample.page,
                "spacingMetric": "interLineDeltaErrorY",
                "visibleRangeY": "\(String(format: "%.1f", sample.visibleTopY))...\(String(format: "%.1f", sample.visibleBottomY))"
            ]
        )
    }

    private func isAbnormalLyricLineMotionSample(_ sample: DiagnosticLyricLineMotionSample) -> Bool {
        let targetDistance = abs(sample.targetIndex - sample.activeIndex)
        let intendedWaveOffset = abs(sample.waveOffsetY)
        let explainedTargetError = abs(abs(sample.targetErrorY) - intendedWaveOffset)
        let singleStepWaveAllowance = max(72, sample.renderedHeight * 1.4)

        return targetDistance > 1
            || intendedWaveOffset > singleStepWaveAllowance
            || explainedTargetError > 18
    }

    private func isStaleStaticLyricLineMotionSample(_ sample: DiagnosticLyricLineMotionSample) -> Bool {
        guard !sample.isManualScrolling, !sample.isInitialMotionSuppressed else { return false }
        guard sample.targetIndex != sample.activeIndex else { return false }
        guard abs(sample.lineIndex - sample.activeIndex) <= 4 else { return false }

        let staleOffsetThreshold = max(32, sample.renderedHeight * 0.70)
        let isOffsetFromTarget = abs(sample.targetErrorY) >= staleOffsetThreshold
        let isNotMoving = abs(sample.velocityY) < 2
        return isOffsetFromTarget && isNotMoving
    }

    private func isViewportRelevantLineMotionSample(_ sample: DiagnosticLyricLineMotionSample) -> Bool {
        if sample.lineIndex == sample.activeIndex { return true }
        guard abs(sample.lineIndex - sample.activeIndex) <= 1 else { return false }
        let padding = 8.0
        let renderedMaxY = sample.renderedMinY + sample.renderedHeight
        let targetMaxY = sample.targetMinY + sample.renderedHeight
        let visibleTopY = sample.visibleTopY - padding
        let visibleBottomY = sample.visibleBottomY + padding
        let renderedCanAffectViewport = renderedMaxY >= visibleTopY && sample.renderedMinY <= visibleBottomY
        let targetCanAffectViewport = targetMaxY >= visibleTopY && sample.targetMinY <= visibleBottomY
        return renderedCanAffectViewport || targetCanAffectViewport
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
            "Stale or unrelated debug log content is not attached."
        ].joined(separator: "\n") + "\n"
        try status.write(
            to: reportDir.appendingPathComponent("debug_log_status.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func currentSessionDebugLogURL() -> URL? {
        guard let url = debugLogURLForTesting ?? (try? liveDebugLogURL()) else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              shouldAttachDebugLog(modifiedAt: modifiedAt) else {
            return nil
        }
        return url
    }

    private func configureDebugLoggerForCurrentSession() {
        guard let url = debugLogURLForTesting ?? (try? liveDebugLogURL()) else { return }
        DebugLogger.setLogURL(url)
        DebugLogger.setDiagnosticsFileLoggingEnabled(true)
    }

    private func liveDebugLogURL() throws -> URL {
        let dir = try diagnosticsLiveDirectory()
        return dir.appendingPathComponent("nanopod_debug.log")
    }

    private func diagnosticsLiveDirectory() throws -> URL {
        let base = diagnosticsStorageBaseDirectory()
        let dir = base
            .appendingPathComponent("nanoPod", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Live", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func liveLyricLineMotionSamplesURL() throws -> URL {
        let dir = try diagnosticsLiveDirectory()
        return dir.appendingPathComponent("lyrics_line_motion_samples.csv")
    }

    private func liveLyricWaveTimelineSamplesURL() throws -> URL {
        let dir = try diagnosticsLiveDirectory()
        return dir.appendingPathComponent("lyrics_wave_timeline.csv")
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
