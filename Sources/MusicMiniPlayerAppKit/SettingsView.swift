/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 MusicController/LyricsService/TourPersistence/
 *          GlobalShortcutAction；依赖 LocalizedStrings 的 L10n/UserDefaultsBinding；
 *          依赖 SettingsControls（卡片/行/开关/分段）、SettingsHoverIntent（悬停意图）、
 *          SettingsDemoStage（演示台）、SettingsPalette、AboutPageView。
 * [OUTPUT]: 导出 SettingsWindowView、SettingsWindowState、SettingsTab、
 *           GettingToKnowNanoPodAction、TourButtonPolicy、LaunchAtLoginBridge、
 *           LaunchAtLoginProviding。
 * [POS]: MusicMiniPlayerApp 的设置界面（v3.2：演示台 + 分段控件 + 分组卡片，
 *        无 sidebar 无工具栏；视觉以 mockup.html 为准 —
 *        docs/design/2026-09-25-menu-settings/proposal.md §4）
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

extension SettingsDemo {
    /// The page this row lives on.
    var tab: SettingsTab {
        switch self {
        case .fullscreenCover, .edgeShowSongOnTrackChange, .showTranslation, .translateTo: return .player
        case .launchAtLogin, .showInDock, .gettingToKnowNanoPod, .musicAutomation,
             .appleMusicAccess, .playbackHistory: return .general
        case .playPauseShortcut, .nextTrackShortcut, .previousTrackShortcut,
             .showHidePlayerShortcut, .hideToEdgeShortcut: return .shortcuts
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - SettingsWindowState (persists the last-selected tab)
// ──────────────────────────────────────────────

final class SettingsWindowState: ObservableObject {
    static let selectedTabDefaultsKey = "nanoPodSettingsSelectedTab"

    private let defaults: UserDefaults

    @Published var selectedTab: SettingsTab {
        didSet { defaults.set(selectedTab.rawValue, forKey: Self.selectedTabDefaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.selectedTabDefaultsKey),
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

/// Pure title-key decision (onboarding proposal §9.2 naming): not-yet-
/// finished (never started, in progress, or explicitly stopped with steps
/// still pending) reads "接着认识 nanoPod"; only a fully completed run reads
/// "重新认识 nanoPod".
enum TourButtonPolicy {
    static func titleKey(status: TourRunStatus) -> String {
        status == .completed ? "tour.settings.again" : "tour.settings.keepGoing"
    }
}

/// Decoupled from the View so tests can call it directly without hosting a
/// SwiftUI hierarchy: not-yet-completed resumes from where the user left off
/// (`fromStart: false` — `TourEvent.resume`); completed starts over
/// (`fromStart: true` — persistence is reset, then `TourEvent.start`).
@MainActor
enum GettingToKnowNanoPodAction {
    static func perform(status: TourRunStatus, requestTour: (_ fromStart: Bool) -> Void) {
        requestTour(status == .completed)
    }
}

// ──────────────────────────────────────────────
// MARK: - SettingsWindowView
// ──────────────────────────────────────────────

struct SettingsWindowView: View {
    @EnvironmentObject var musicController: MusicController
    @ObservedObject var state: SettingsWindowState
    @StateObject private var lyricsService = LyricsService.shared
    /// Kept for its Automation/MusicKit authorization queries and the Automation
    /// grant request; its old onboarding bookkeeping is superseded by
    /// `TourPersistence` and no longer read here.
    @StateObject private var onboardingState = OnboardingState.shared
    @StateObject private var hover = SettingsHoverIntentModel()
    @StateObject private var stage = DemoStageModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingClearHistory = false
    /// Bumped after a permission request so the status rows re-query.
    @State private var permissionRefresh = 0

    /// Read fresh on every body evaluation — the tour isn't expected to be
    /// running while its own "keep going / again" button is on screen.
    private var tourStatus: TourRunStatus { TourPersistence.load().status }

    /// Overridable for tests — the production default reaches through the
    /// app-layer singleton, which is nil in a plain unit-test process.
    /// `fromStart`: true restarts the tour from step 1 (persistence reset
    /// first); false resumes from wherever it left off.
    var onRequestTour: (_ fromStart: Bool) -> Void = { AppMain.shared?.showTour(fromStart: $0) }
    /// Test seams: deterministic permission state for renders.
    var automationStatusProvider: () -> OnboardingAuthorizationStatus = { OnboardingState.shared.automationStatus }
    var appleMusicStatusProvider: () -> OnboardingAuthorizationStatus = { OnboardingState.shared.musicKitStatus }

    init(state: SettingsWindowState) {
        self.state = state
    }

    var body: some View {
        VStack(spacing: 0) {
            stageArea
                .frame(width: SettingsMetrics.contentWidth, height: SettingsMetrics.stageHeight)
                .padding(.bottom, SettingsMetrics.stageToSegmented)

            SettingsSegmentedControl(tabs: SettingsTab.visibleCases, selection: $state.selectedTab)
                .padding(.bottom, SettingsMetrics.segmentedToContent)

            pageArea
                .frame(width: SettingsMetrics.contentWidth, height: SettingsMetrics.pageViewportHeight, alignment: .top)
        }
        .padding(.top, SettingsMetrics.topPadding)
        .padding(.horizontal, SettingsMetrics.outerPadding)
        .frame(width: SettingsMetrics.windowSize.width, height: SettingsMetrics.windowSize.height, alignment: .top)
        .background(SettingsPalette.windowBackground)
        .background(DemoWindowVisibilityObserver { stage.settle() })
        .environmentObject(hover)
        .onAppear {
            stage.reduceMotion = reduceMotion
            if let demo = state.selectedTab.defaultDemo { stage.show(demo) }
        }
        .onChange(of: reduceMotion) { _, value in
            stage.reduceMotion = value
            if value { stage.settle() }
        }
        .onChange(of: state.selectedTab) { _, tab in
            hover.resetStage()
            if let demo = tab.defaultDemo { stage.show(demo) }
        }
        // The pointer rested on a row (dwell gate passed): that row's scene starts.
        .onChange(of: hover.commitCount) { _, _ in
            if let demo = hover.stageDemo, demo.tab == state.selectedTab {
                stage.begin(demo, isOn: demoContext.isOn(demo))
            }
        }
        // The pointer left the committed row: its loop plays out to the rest frame.
        .onChange(of: hover.highlightedRow) { _, row in stage.pointerMoved(to: row) }
        .confirmationDialog(
            L10n.localized("clearHistoryConfirmTitle"),
            isPresented: $confirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button(L10n.localized("clearPlaybackHistory"), role: .destructive) {
                musicController.clearPlaybackHistory()
            }
            Button(L10n.localized("cancel"), role: .cancel) {}
        } message: {
            Text(L10n.localized("clearHistoryConfirmMessage"))
        }
    }

    // MARK: Stage + page

    @ViewBuilder
    private var stageArea: some View {
        switch state.selectedTab {
        case .about:
            AboutHeaderView()
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case .diagnostics:
            Color.clear
        #endif
        default:
            DemoStage(model: stage, context: demoContext)
        }
    }

    @ViewBuilder
    private var pageArea: some View {
        switch state.selectedTab {
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case .diagnostics:
            DiagnosticsDebugPanel(musicController: musicController)
        #endif
        default:
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    switch state.selectedTab {
                    case .player: playerPage
                    case .general: generalPage
                    case .shortcuts: shortcutsPage
                    case .about: AboutLinksView()
                    #if DEBUG || LOCAL_DEVELOPER_BUILD
                    case .diagnostics: EmptyView()
                    #endif
                    }
                }
                .frame(width: SettingsMetrics.contentWidth, alignment: .leading)
                .padding(.bottom, SettingsMetrics.pageBottomInset)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Stage context

    private var demoContext: SettingsDemoContext {
        var context = SettingsDemoContext(
            translationSampleText: translationSampleText,
            shortcutDescriptions: Dictionary(uniqueKeysWithValues: GlobalShortcutAction.allCases.map {
                ($0, KeyboardShortcuts.getShortcut(for: $0.name)?.description ?? "")
            })
        )
        context.switchStates = [
            .fullscreenCover: UserDefaults.standard.bool(forKey: "fullscreenAlbumCover"),
            .edgeShowSongOnTrackChange: edgeShowSongBinding.wrappedValue,
            .showTranslation: lyricsService.showTranslation,
            .launchAtLogin: LaunchAtLoginBridge.status == .enabled,
            .showInDock: AppMain.shared?.showInDock ?? true,
        ]
        for demo in SettingsDemo.allCases {
            context.captions[demo] = captionText(for: demo)
            context.chips[demo] = chipText(for: demo, context: context)
        }
        return context
    }

    /// The pill's state text: On / Off for switches, the language for "Translate To",
    /// the recorded combination for shortcuts.
    private func chipText(for demo: SettingsDemo, context: SettingsDemoContext) -> String? {
        switch demo {
        case .fullscreenCover, .edgeShowSongOnTrackChange, .showTranslation, .launchAtLogin, .showInDock:
            return L10n.localized(context.isOn(demo) ? "stateOn" : "stateOff")
        case .translateTo:
            let current = lyricsService.translationLanguage
            let code = current == L10n.systemLanguageCode ? "system" : current
            return L10n.translationLanguageOptions.first { $0.code == code }?.name
        case .gettingToKnowNanoPod, .musicAutomation, .appleMusicAccess, .playbackHistory:
            return nil
        case .playPauseShortcut, .nextTrackShortcut, .previousTrackShortcut, .showHidePlayerShortcut, .hideToEdgeShortcut:
            let text = demo.shortcutAction.map(context.shortcutLabel(for:)) ?? ""
            return text.isEmpty ? nil : text
        }
    }

    private var translationSampleText: String {
        switch lyricsService.translationLanguage {
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
        case .appleMusicAccess: return L10n.localized("appleMusic")
        case .playbackHistory: return L10n.localized("playbackHistory")
        case .playPauseShortcut: return GlobalShortcutAction.togglePlayPause.localizedTitle
        case .nextTrackShortcut: return GlobalShortcutAction.nextTrack.localizedTitle
        case .previousTrackShortcut: return GlobalShortcutAction.previousTrack.localizedTitle
        case .showHidePlayerShortcut: return GlobalShortcutAction.togglePanel.localizedTitle
        case .hideToEdgeShortcut: return GlobalShortcutAction.hideToEdge.localizedTitle
        }
    }

    // MARK: - Row helpers

    /// A switch row. Flipping the switch replays the change once on the stage (spec A.2).
    private func toggleRow(_ demo: SettingsDemo, title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        let replaying = Binding(
            get: { isOn.wrappedValue },
            set: { isOn.wrappedValue = $0; stage.replay(demo, isOn: $0) })
        return SettingsRow(demo: demo, title: title, detail: detail) {
            Toggle(isOn: replaying) { Text(title) }
                .toggleStyle(SettingsSwitchStyle())
                .accessibilityLabel(title)
        }
    }

    // MARK: - Player page

    @ViewBuilder
    private var playerPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                toggleRow(.fullscreenCover,
                          title: L10n.localized("fullscreenCover"),
                          detail: L10n.localized("fullscreenCoverDesc"),
                          isOn: UserDefaultsBinding.bool(forKey: "fullscreenAlbumCover"))
                SettingsDivider()
                toggleRow(.edgeShowSongOnTrackChange,
                          title: L10n.localized("edgeShowSongOnTrackChange"),
                          detail: L10n.localized("edgeShowSongOnTrackChangeDesc"),
                          isOn: edgeShowSongBinding)
                if #available(macOS 15.0, *) {
                    SettingsDivider()
                    toggleRow(.showTranslation,
                              title: L10n.localized("showTranslation"),
                              detail: L10n.localized("showTranslationDesc"),
                              isOn: Binding(
                                get: { lyricsService.showTranslation },
                                set: { lyricsService.showTranslation = $0 }))
                    SettingsDivider()
                    SettingsRow(demo: .translateTo, title: L10n.localized("translateTo")) {
                        Picker(L10n.localized("translateTo"), selection: Binding(
                            get: {
                                let currentLang = lyricsService.translationLanguage
                                return currentLang == L10n.systemLanguageCode ? "system" : currentLang
                            },
                            set: { code in
                                lyricsService.translationLanguage = code == "system" ? L10n.systemLanguageCode : code
                                // The chosen language shows on the stage at once (spec A.6.3).
                                stage.replay(.translateTo, isOn: true)
                            }
                        )) {
                            ForEach(L10n.translationLanguageOptions, id: \.code) { option in
                                Text(option.name).tag(option.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            if #available(macOS 15.0, *) {
                SettingsSectionFooter(text: L10n.localized("playerFooter"))
            }
        }
    }

    /// Default on (no public API tells whether the player already notifies).
    private var edgeShowSongBinding: Binding<Bool> {
        let key = LiquidEdgeController.autoPeekDefaultsKey
        return Binding(
            get: { UserDefaults.standard.object(forKey: key) as? Bool ?? true },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    // MARK: - General page

    @ViewBuilder
    private var generalPage: some View {
        let loginStatus = LaunchAtLoginBridge.status
        SettingsCard {
            SettingsRow(
                demo: .launchAtLogin,
                title: L10n.localized("launchAtLogin"),
                detail: loginStatus == .requiresApproval ? L10n.localized("launchAtLoginApprovalNeeded") : nil
            ) {
                HStack(spacing: 10) {
                    if loginStatus == .requiresApproval {
                        Button(L10n.localized("launchAtLoginOpenItems")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SettingsPushButtonStyle())
                    }
                    Toggle(isOn: Binding(
                        get: { LaunchAtLoginBridge.status == .enabled },
                        set: { LaunchAtLoginBridge.setEnabled($0); permissionRefresh += 1; stage.replay(.launchAtLogin, isOn: $0) }
                    )) { Text(L10n.localized("launchAtLogin")) }
                        .toggleStyle(SettingsSwitchStyle())
                        .accessibilityLabel(L10n.localized("launchAtLogin"))
                }
            }
            SettingsDivider()
            toggleRow(.showInDock,
                      title: L10n.localized("showInDock"),
                      isOn: Binding(
                        get: { AppMain.shared?.showInDock ?? true },
                        set: { AppMain.shared?.showInDock = $0 }))
            SettingsDivider()
            SettingsRow(demo: .gettingToKnowNanoPod, title: L10n.localized("tour.settings.title")) {
                tourButton
            }
            SettingsDivider()
            SettingsRow(demo: .musicAutomation, title: L10n.localized("automation"), detail: L10n.localized("automationDesc")) {
                permissionControl(
                    status: automationStatusProvider(),
                    grant: {
                        onboardingState.requestAutomationAccess()
                        permissionRefresh += 1
                    },
                    openSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
            }
            SettingsDivider()
            SettingsRow(demo: .appleMusicAccess, title: L10n.localized("appleMusic")) {
                permissionControl(
                    status: appleMusicStatusProvider(),
                    grant: {
                        Task {
                            await musicController.requestMusicKitAccess()
                            permissionRefresh += 1
                        }
                    },
                    openSettings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
            }
            SettingsDivider()
            SettingsRow(
                demo: .playbackHistory,
                title: L10n.localized("playbackHistory"),
                detail: L10n.localized("clearPlaybackHistoryDesc")
            ) {
                Button(L10n.localized("clearButton")) { confirmingClearHistory = true }
                    .buttonStyle(SettingsPushButtonStyle())
            }
        }
    }

    /// Both titles are laid out (one hidden) so the button keeps the width of
    /// the longer one and never changes the row when the text swaps.
    private var tourButton: some View {
        let status = tourStatus
        return Button {
            GettingToKnowNanoPodAction.perform(status: status, requestTour: onRequestTour)
        } label: {
            ZStack {
                Text(L10n.localized("tour.settings.keepGoing")).hidden()
                Text(L10n.localized("tour.settings.again")).hidden()
                Text(L10n.localized(TourButtonPolicy.titleKey(status: status)))
            }
        }
        .buttonStyle(SettingsPushButtonStyle())
    }

    @ViewBuilder
    private func permissionControl(status: OnboardingAuthorizationStatus, grant: @escaping () -> Void, openSettings: String) -> some View {
        HStack(spacing: 10) {
            Text(permissionLabel(status))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            switch status {
            case .authorized:
                EmptyView()
            case .notDetermined:
                Button(L10n.localized("automationGrant"), action: grant)
                    .buttonStyle(SettingsPushButtonStyle())
            case .denied:
                Button(L10n.localized("automationOpenSettings")) {
                    if let url = URL(string: openSettings) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(SettingsPushButtonStyle())
            }
        }
        .id(permissionRefresh)
    }

    private func permissionLabel(_ status: OnboardingAuthorizationStatus) -> String {
        switch status {
        case .authorized: return L10n.localized("onboarding.auth.authorized")
        case .denied: return L10n.localized("authDenied")
        case .notDetermined: return L10n.localized("authNotDetermined")
        }
    }

    // MARK: - Shortcuts page

    @ViewBuilder
    private var shortcutsPage: some View {
        SettingsCard {
            ForEach(Array(GlobalShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                if index > 0 { SettingsDivider() }
                SettingsRow(demo: demo(for: action), title: action.localizedTitle) {
                    KeyboardShortcuts.Recorder(for: action.name)
                }
            }
        }
        SettingsSectionFooter(text: L10n.localized("shortcutsFooter"))
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
