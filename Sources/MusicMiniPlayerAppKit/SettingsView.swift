/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 MusicController/LyricsService/OnboardingState/
 *          GlobalShortcutAction；依赖 LocalizedStrings 的 L10n/UserDefaultsBinding；
 *          依赖 SettingsDemoStage 的 DemoStage/SettingsDemo/SettingsRowHoverIntentHost；
 *          依赖 AboutPageView。
 * [OUTPUT]: 导出 SettingsWindowView、SettingsWindowState、SettingsTab、
 *           GettingToKnowNanoPodAction、TourButtonPolicy、LaunchAtLoginBridge、
 *           LaunchAtLoginProviding。
 * [POS]: MusicMiniPlayerApp 的设置界面集合（v3.2 重做：演示台 + 分段控件 + 分组行，
 *        无 sidebar 无工具栏 — docs/design/2026-09-25-menu-settings/proposal.md）
 */

import SwiftUI
import MusicMiniPlayerCore
import Translation
import UniformTypeIdentifiers
import KeyboardShortcuts
import ServiceManagement

// ──────────────────────────────────────────────
// MARK: - SettingsTab (v3.2: Player · General · Shortcuts · About)
// ──────────────────────────────────────────────

enum SettingsTab: String, Hashable, CaseIterable {
    case player
    case general
    case shortcuts
    case about
    #if DEBUG || LOCAL_DEVELOPER_BUILD
    case diagnostics
    #endif

    /// Same list as `allCases` — kept for call-site parity with the pre-redesign
    /// name (`SettingsTab.visibleCases`), since diagnostics is always compiled
    /// out (not merely hidden) outside DEBUG/LOCAL_DEVELOPER_BUILD.
    static var visibleCases: [SettingsTab] { allCases }

    var title: String {
        switch self {
        case .player: return L10n.localized("player")
        case .general: return L10n.localized("general")
        case .shortcuts: return L10n.localized("shortcuts")
        case .about: return L10n.localized("about")
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case .diagnostics: return "Diagnostics"
        #endif
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - SettingsWindowState (persists the last-selected tab)
// ──────────────────────────────────────────────

final class SettingsWindowState: ObservableObject {
    static let selectedTabDefaultsKey = "nanoPodSettingsSelectedTab"

    @Published var selectedTab: SettingsTab {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: Self.selectedTabDefaultsKey) }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.selectedTabDefaultsKey),
           let restored = SettingsTab(rawValue: raw) {
            selectedTab = restored
        } else {
            selectedTab = .general
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Launch at Login (SMAppService, test-seamed)
// ──────────────────────────────────────────────

/// `SMAppService.mainApp`'s surface, narrowed to what this row needs — lets
/// tests inject a fake instead of registering a REAL login item on the
/// machine running the test suite.
public protocol LaunchAtLoginProviding: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginProviding {}

enum LaunchAtLoginBridge {
    #if DEBUG
    static var testingProvider: (any LaunchAtLoginProviding)?
    #endif

    static var provider: any LaunchAtLoginProviding {
        #if DEBUG
        if let testingProvider { return testingProvider }
        #endif
        return SMAppService.mainApp
    }

    static var status: SMAppService.Status { provider.status }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try provider.register()
            } else {
                try provider.unregister()
            }
        } catch {
            debugPrint("[LaunchAtLoginBridge] \(error)")
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - "Getting to know nanoPod" row (pure action + title policy)
// ──────────────────────────────────────────────

/// Pure title-key decision (proposal §4.3 / onboarding proposal §9.2 naming).
enum TourButtonPolicy {
    static func titleKey(hasCompletedOnboarding: Bool) -> String {
        hasCompletedOnboarding ? "tour.settings.again" : "tour.settings.keepGoing"
    }
}

/// Decoupled from the View so tests can call it directly without hosting a
/// SwiftUI hierarchy: not-yet-completed resumes from where the user left off
/// (no reset); completed starts over (reset first, then request the window).
@MainActor
enum GettingToKnowNanoPodAction {
    static func perform(onboardingState: OnboardingState, requestOnboarding: () -> Void) {
        if onboardingState.hasCompletedOnboarding {
            onboardingState.reset()
        }
        requestOnboarding()
    }
}

// ──────────────────────────────────────────────
// MARK: - SettingsWindowView
// ──────────────────────────────────────────────

struct SettingsWindowView: View {
    @EnvironmentObject var musicController: MusicController
    @ObservedObject var state: SettingsWindowState
    @StateObject private var lyricsService = LyricsService.shared
    @StateObject private var onboardingState = OnboardingState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Overridable for tests — the production default reaches through the
    /// app-layer singleton, which is nil in a plain unit-test process.
    var onRequestOnboarding: () -> Void = { AppMain.shared?.showOnboardingWindow() }

    @State private var activeDemo: SettingsDemo?
    @State private var playToken = 0
    @State private var loopTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if state.selectedTab == .about {
                    AboutPageView()
                } else if isDiagnosticsTab {
                    EmptyView()
                } else {
                    DemoStage(demo: activeDemo, context: demoContext, playToken: playToken, reduceMotion: reduceMotion, caption: activeDemo.map(captionText) ?? "")
                }
            }
            .frame(height: 120)
            .padding(.bottom, 14)

            Picker("", selection: $state.selectedTab) {
                ForEach(SettingsTab.visibleCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 440)
            .padding(.bottom, 14)

            Group {
                switch state.selectedTab {
                case .player: playerTab
                case .general: generalTab
                case .shortcuts: shortcutsTab
                case .about: EmptyView()
                #if DEBUG || LOCAL_DEVELOPER_BUILD
                case .diagnostics: DiagnosticsDebugPanel(musicController: musicController)
                #endif
                }
            }
            .frame(height: 350)
        }
        .padding(20)
        .frame(width: 480, height: 562)
        .onChange(of: activeDemo) { _, newValue in
            restartLoop(for: newValue)
        }
        .onDisappear {
            loopTask?.cancel()
        }
    }

    private var isDiagnosticsTab: Bool {
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        return state.selectedTab == .diagnostics
        #else
        return false
        #endif
    }

    // MARK: Demo loop (hover-driven; never runs under Reduce Motion — proposal §4.4)

    private func restartLoop(for demo: SettingsDemo?) {
        loopTask?.cancel()
        loopTask = nil
        guard let demo, !reduceMotion else { return }
        playToken += 1
        loopTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                guard !Task.isCancelled, activeDemo == demo else { return }
                playToken += 1
            }
        }
    }

    private var demoContext: SettingsDemoContext {
        SettingsDemoContext(
            fullscreenCoverOn: UserDefaults.standard.bool(forKey: "fullscreenAlbumCover"),
            edgeShowSongOn: UserDefaults.standard.object(forKey: LiquidEdgeController.autoPeekDefaultsKey) as? Bool ?? true,
            showTranslationOn: lyricsService.showTranslation,
            translationSampleText: translationSampleText,
            launchAtLoginOn: LaunchAtLoginBridge.status == .enabled,
            showInDockOn: AppMain.shared?.showInDock ?? true,
            automationStatus: onboardingState.automationStatus,
            appleMusicStatus: onboardingState.musicKitStatus,
            shortcutDescriptions: Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map {
                ($0, KeyboardShortcuts.getShortcut(for: $0.name)?.description ?? "")
            })
        )
    }

    private var translationSampleText: String {
        let currentLang = lyricsService.translationLanguage
        switch currentLang {
        case "zh": return "我们去看海吧"
        case "ja": return "海を見に行こう"
        case "ko": return "바다 보러 가자"
        case "fr": return "Allons voir la mer"
        case "de": return "Lass uns ans Meer fahren"
        case "es": return "Vamos a ver el mar"
        default: return "Let's go see the sea"
        }
    }

    private func captionText(for demo: SettingsDemo) -> String {
        switch demo {
        case .fullscreenCover: return L10n.localized("fullscreenCover")
        case .edgeShowSongOnTrackChange: return L10n.localized("edgeShowSongOnTrackChange")
        case .showTranslation: return L10n.localized("showTranslation")
        case .translateTo: return L10n.localized("translateTo")
        case .launchAtLogin: return L10n.localized("launchAtLogin")
        case .showInDock: return L10n.localized("showInDock")
        case .gettingToKnowNanoPod: return L10n.localized("tour.settings.title")
        case .musicAutomation: return L10n.localized("automation")
        case .appleMusicAccess: return L10n.localized("musicKit")
        case .playbackHistory: return L10n.localized("clearPlaybackHistory")
        case .playPauseShortcut: return GlobalShortcutAction.togglePlayPause.localizedTitle
        case .nextTrackShortcut: return GlobalShortcutAction.nextTrack.localizedTitle
        case .previousTrackShortcut: return GlobalShortcutAction.previousTrack.localizedTitle
        case .showHidePlayerShortcut: return GlobalShortcutAction.togglePanel.localizedTitle
        case .hideToEdgeShortcut: return GlobalShortcutAction.hideToEdge.localizedTitle
        }
    }

    // MARK: - Player Tab

    private var playerTab: some View {
        Form {
            Section {
                SettingsRow(demo: .fullscreenCover, activeDemo: $activeDemo) {
                    Toggle(isOn: UserDefaultsBinding.bool(forKey: "fullscreenAlbumCover")) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("fullscreenCover"))
                            Text(L10n.localized("fullscreenCoverDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            Section {
                SettingsRow(demo: .edgeShowSongOnTrackChange, activeDemo: $activeDemo) {
                    Toggle(isOn: edgeShowSongBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("edgeShowSongOnTrackChange"))
                            Text(L10n.localized("edgeShowSongOnTrackChangeDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            if #available(macOS 15.0, *) {
                Section {
                    SettingsRow(demo: .showTranslation, activeDemo: $activeDemo) {
                        Toggle(isOn: Binding(
                            get: { lyricsService.showTranslation },
                            set: { lyricsService.showTranslation = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.localized("showTranslation"))
                                Text(L10n.localized("showTranslationDesc"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                Section {
                    SettingsRow(demo: .translateTo, activeDemo: $activeDemo) {
                        Picker(selection: Binding(
                            get: {
                                let currentLang = lyricsService.translationLanguage
                                return currentLang == L10n.systemLanguageCode ? "system" : currentLang
                            },
                            set: { code in
                                lyricsService.translationLanguage = code == "system" ? L10n.systemLanguageCode : code
                            }
                        )) {
                            ForEach(L10n.translationLanguageOptions, id: \.code) { option in
                                Text(option.name).tag(option.code)
                            }
                        } label: {
                            Text(L10n.localized("translationLang"))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Default on (no public API tells whether the player already notifies).
    private var edgeShowSongBinding: Binding<Bool> {
        let key = LiquidEdgeController.autoPeekDefaultsKey
        return Binding(
            get: { UserDefaults.standard.object(forKey: key) as? Bool ?? true },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                SettingsRow(demo: .launchAtLogin, activeDemo: $activeDemo) {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: Binding(
                            get: { LaunchAtLoginBridge.status == .enabled },
                            set: { LaunchAtLoginBridge.setEnabled($0) }
                        )) {
                            Text(L10n.localized("launchAtLogin"))
                        }
                        .toggleStyle(.switch)

                        if LaunchAtLoginBridge.status == .requiresApproval {
                            HStack {
                                Text(L10n.localized("launchAtLoginApprovalNeeded"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button(L10n.localized("launchAtLoginOpenItems")) {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(.link)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section {
                SettingsRow(demo: .showInDock, activeDemo: $activeDemo) {
                    Toggle(isOn: Binding(
                        get: { AppMain.shared?.showInDock ?? true },
                        set: { AppMain.shared?.showInDock = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("showInDock"))
                            Text(L10n.localized("showInDockDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }

            Section {
                SettingsRow(demo: .gettingToKnowNanoPod, activeDemo: $activeDemo) {
                    HStack {
                        Text(L10n.localized("tour.settings.title"))
                        Spacer()
                        Button(L10n.localized(TourButtonPolicy.titleKey(hasCompletedOnboarding: onboardingState.hasCompletedOnboarding))) {
                            GettingToKnowNanoPodAction.perform(onboardingState: onboardingState, requestOnboarding: onRequestOnboarding)
                        }
                        .frame(minWidth: 210)
                        .fixedSize()
                    }
                }
            }

            Section {
                SettingsRow(demo: .musicAutomation, activeDemo: $activeDemo) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("automation"))
                        }
                        Spacer()
                        automationStatusControl
                    }
                }
            } footer: {
                Text(L10n.localized("automationFooter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsRow(demo: .appleMusicAccess, activeDemo: $activeDemo) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("musicKit"))
                            Text(L10n.localized("musicKitDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        musicKitStatusControl
                    }
                }
            }

            Section {
                SettingsRow(demo: .playbackHistory, activeDemo: $activeDemo) {
                    Button(role: .destructive) {
                        musicController.clearPlaybackHistory()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("clearPlaybackHistory"))
                            Text(L10n.localized("clearPlaybackHistoryDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var automationStatusControl: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(onboardingState.automationStatus == .authorized ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            switch onboardingState.automationStatus {
            case .authorized:
                Text(L10n.localized("onboarding.auth.authorized")).font(.caption).foregroundStyle(.secondary)
            case .denied:
                Button(L10n.localized("automationOpenSettings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .notDetermined:
                Button(L10n.localized("automationGrant")) {
                    onboardingState.requestAutomationAccess()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var musicKitStatusControl: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(musicController.musicKitAuthorized ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            Text(musicController.musicKitAuthStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !musicController.musicKitAuthorized {
                Button(L10n.localized("musicKitRequest")) {
                    Task { await musicController.requestMusicKitAccess() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button(L10n.localized("musicKitOpen")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section {
                ForEach(GlobalShortcutAction.allCases) { action in
                    SettingsRow(demo: demo(for: action), activeDemo: $activeDemo) {
                        KeyboardShortcuts.Recorder(action.localizedTitle, name: action.name)
                    }
                }
            } footer: {
                Text(L10n.localized("shortcutsFooter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func demo(for action: GlobalShortcutAction) -> SettingsDemo {
        switch action {
        case .togglePlayPause: return .playPauseShortcut
        case .nextTrack: return .nextTrackShortcut
        case .previousTrack: return .previousTrackShortcut
        case .togglePanel: return .showHidePlayerShortcut
        case .hideToEdge: return .hideToEdgeShortcut
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - SettingsRow (hover-intent wrapper — proposal §4.4)
// ──────────────────────────────────────────────

/// Wraps a Form row: on a genuine dwell (150ms, ≤4pt drift — the same numbers
/// as the progress bar's hover-intent gate), tells the parent to show this
/// row's demo. A fast pass-through never switches the stage.
struct SettingsRow<Content: View>: View {
    let demo: SettingsDemo
    @Binding var activeDemo: SettingsDemo?
    let content: Content
    @State private var host = SettingsRowHoverIntentHost()

    init(demo: SettingsDemo, activeDemo: Binding<SettingsDemo?>, @ViewBuilder content: () -> Content) {
        self.demo = demo
        self._activeDemo = activeDemo
        self.content = content()
    }

    var body: some View {
        content
            .contentShape(Rectangle())
            .onHover { hovering in
                host.onCommitChanged = { committed in
                    if committed {
                        activeDemo = demo
                    } else if activeDemo == demo {
                        activeDemo = nil
                    }
                }
                host.hoverChanged(hovering)
            }
    }
}

#if DEBUG || LOCAL_DEVELOPER_BUILD
// ──────────────────────────────────────────────
// MARK: - Owner Diagnostics Debug Panel
// ──────────────────────────────────────────────

struct DiagnosticsDebugPanel: View {
    @ObservedObject var musicController: MusicController
    @StateObject private var diagnostics = DiagnosticsService.shared

    @State private var selectedSymptom: DiagnosticUserSymptom = .wrongLyrics
    @State private var applyingInferredSymptom = false
    @State private var userOverrodeSymptom = false
    @State private var note: String = ""
    @State private var mediaAttachments: [URL] = []
    @State private var exportMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                Divider()

                reportControls

                Divider()

                recentInteractions

                Divider()

                recentIncidents
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { diagnostics.isEnabled },
                set: { diagnostics.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Owner diagnostics")
                        .font(.headline)
                    Text("Local debug mode for Codex reports. Not a release telemetry surface.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                diagnosticsMetric("Incidents", "\(diagnostics.incidentCount)")
                diagnosticsMetric("Events", "\(diagnostics.events.count)")
                diagnosticsMetric("Active", "\(diagnostics.activeInteractionCount)")
                diagnosticsMetric("Traces", "\(diagnostics.interactions.count)")
                diagnosticsMetric("Line Motion", "\(diagnostics.lyricLineMotionSampleCount)")
                diagnosticsMetric("Latest", diagnostics.latestIncident?.category.rawValue ?? diagnostics.latestInteraction?.type.rawValue ?? "none")
            }

            if let warning = diagnostics.lastWarning {
                Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(warning.severity == .critical ? .red : .orange)
            }

            HStack {
                Button("Export Current Bundle") {
                    exportCurrentBundle()
                }
                .disabled(!diagnostics.isEnabled)

                Button("Clear Diagnostics") {
                    diagnostics.clear(suppressImmediateStandaloneFrameStalls: true)
                    exportMessage = "Diagnostics cleared"
                }
                .disabled(!diagnostics.isEnabled)

                if let url = diagnostics.lastExportURL {
                    Button("Reveal Last Export") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                }
            }
            .controlSize(.small)

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var reportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual report")
                .font(.headline)

            Picker("Visible symptom", selection: $selectedSymptom) {
                ForEach(DiagnosticUserSymptom.allCases) { symptom in
                    Text(symptom.rawValue).tag(symptom)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedSymptom) { _, _ in
                if !applyingInferredSymptom {
                    userOverrodeSymptom = true
                }
            }

            TextField("Optional note", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .onChange(of: note) { _, newNote in
                    inferSymptomFromNote(newNote)
                }

            HStack {
                Button("Attach Media...") {
                    chooseMediaAttachments()
                }
                .disabled(!diagnostics.isEnabled)

                Text(mediaAttachments.isEmpty ? "No media attached" : "\(mediaAttachments.count) attachment(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Report Current Issue") {
                    reportCurrentIssue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!diagnostics.isEnabled)
            }
            .controlSize(.small)
        }
    }

    private var recentIncidents: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Captured incidents")
                .font(.headline)

            if diagnostics.incidents.isEmpty {
                Text(diagnostics.isEnabled ? "No incidents captured yet." : "Enable diagnostics to start collecting local incidents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(diagnostics.incidents.prefix(30)) { incident in
                            incidentRow(incident)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }
        }
    }

    private var recentInteractions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interaction traces")
                .font(.headline)

            if diagnostics.interactions.isEmpty {
                Text(diagnostics.activeInteractionCount > 0 ? "Collecting active interaction..." : "No completed interactions captured yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(diagnostics.interactions.prefix(12)) { interaction in
                            interactionRow(interaction)
                        }
                    }
                }
                .frame(minHeight: 84, maxHeight: 140)
            }
        }
    }

    private func diagnosticsMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func incidentRow(_ incident: DiagnosticIncident) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: incident.severity))
                    .frame(width: 7, height: 7)
                Text(incident.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(timeString(incident.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(incident.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(incident.category.rawValue)
                if let symptom = incident.userSymptom {
                    Text(symptom.rawValue)
                }
                if let track = incident.track, track.title != kNotPlayingSentinel {
                    Text("\(track.title) - \(track.artist)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func interactionRow(_ interaction: DiagnosticInteractionTrace) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon(for: interaction.status))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color(for: interaction.status))
                Text("\(interaction.type.rawValue) on \(interaction.page)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(timeString(interaction.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let duration = interaction.metrics["durationMs"].map { "\(Int($0.rounded()))ms" } ?? "open"
            let maxFrame = interaction.metrics["maxFrameDeltaMs"].map { "\(Int($0.rounded()))ms max frame" } ?? "no frame sample"
            Text("\(interaction.status.rawValue) - \(duration) - \(maxFrame)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func color(for severity: DiagnosticSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func color(for status: DiagnosticInteractionStatus) -> Color {
        switch status {
        case .active: return .blue
        case .completed: return .green
        case .interrupted: return .orange
        case .timedOut: return .red
        }
    }

    private func icon(for status: DiagnosticInteractionStatus) -> String {
        switch status {
        case .active: return "record.circle"
        case .completed: return "checkmark.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        case .timedOut: return "timer.circle.fill"
        }
    }

    private func reportCurrentIssue() {
        do {
            let url = try diagnostics.recordManualReport(
                symptom: selectedSymptom,
                note: note,
                track: musicController.diagnosticsTrackContext(),
                mediaAttachments: mediaAttachments
            )
            exportMessage = "Report exported: \(url.path)"
            note = ""
            mediaAttachments = []
            applyingInferredSymptom = false
            userOverrodeSymptom = false
            selectedSymptom = .wrongLyrics
        } catch {
            exportMessage = "Report failed: \(error.localizedDescription)"
        }
    }

    private func inferSymptomFromNote(_ note: String) {
        guard !userOverrodeSymptom || selectedSymptom == .other else { return }
        let inferred = DiagnosticUserSymptom.inferred(from: selectedSymptom, note: note)
        guard inferred != selectedSymptom else { return }

        applyingInferredSymptom = true
        selectedSymptom = inferred
        DispatchQueue.main.async {
            applyingInferredSymptom = false
        }
    }

    private func exportCurrentBundle() {
        do {
            let url = try diagnostics.exportReportBundle(
                userSymptom: nil,
                userNote: note,
                track: musicController.diagnosticsTrackContext(),
                mediaAttachments: mediaAttachments
            )
            exportMessage = "Bundle exported: \(url.path)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func chooseMediaAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .quickTimeMovie, .mpeg4Movie]
        if panel.runModal() == .OK {
            mediaAttachments = panel.urls
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
#endif
