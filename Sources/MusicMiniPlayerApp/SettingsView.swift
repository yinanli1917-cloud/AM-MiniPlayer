/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 MusicController/LyricsService
 *          依赖 LocalizedStrings 的 L10n/UserDefaultsBinding
 * [OUTPUT]: 导出 MenuBarSettingsView、SettingsWindowView、SettingsRow、SettingsToggleRow、SettingsPickerRow
 * [POS]: MusicMiniPlayerApp 的设置界面集合
 */

import SwiftUI
import MusicMiniPlayerCore
import Translation
import UniformTypeIdentifiers

// ──────────────────────────────────────────────
// MARK: - 菜单栏弹出设置（参照 CleanShot X）
// ──────────────────────────────────────────────

struct MenuBarSettingsView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared
    var onExpand: (() -> Void)?
    var onQuit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // 窗口
            SettingsRow(title: L10n.localized("showWindow"), icon: "macwindow", action: { onExpand?() })

            Divider().padding(.horizontal, 12)

            // 播放控制
            SettingsRow(title: L10n.localized("playPause"), icon: "playpause.circle", shortcut: "Space", action: { musicController.togglePlayPause() })
            SettingsRow(title: L10n.localized("previous"), icon: "backward.circle", action: { musicController.previousTrack() })
            SettingsRow(title: L10n.localized("next"), icon: "forward.circle", action: { musicController.nextTrack() })

            Divider().padding(.horizontal, 12)

            // 歌词翻译 (macOS 15+)
            if #available(macOS 15.0, *) {
                SettingsPickerRow(
                    title: L10n.localized("mb.translationLang"),
                    icon: "character.bubble",
                    currentValue: translationLanguageDisplayName,
                    options: menuBarTranslationOptions,
                    onSelect: { code in
                        let targetCode = code == "system" ? L10n.systemLanguageCode : code
                        lyricsService.translationLanguage = targetCode
                    }
                )

                Divider().padding(.horizontal, 12)
            }

            // 设置
            SettingsToggleRow(
                title: L10n.localized("mb.fullscreenCover"),
                icon: "rectangle.fill",
                isOn: UserDefaultsBinding.bool(forKey: "fullscreenAlbumCover")
            )

            SettingsToggleRow(
                title: L10n.localized("showInDock"),
                icon: "dock.rectangle",
                isOn: Binding(
                    get: { AppMain.shared?.showInDock ?? true },
                    set: { AppMain.shared?.showInDock = $0 }
                )
            )

            Divider().padding(.horizontal, 12)

            // 其他
            SettingsRow(title: L10n.localized("openMusic"), icon: "music.note", action: {
                let url = URL(fileURLWithPath: "/System/Applications/Music.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            })

            SettingsRow(title: L10n.localized("settings"), icon: "gear", shortcut: "⌘,", action: {
                AppMain.shared?.showSettingsWindow()
            })

            Divider().padding(.horizontal, 12)

            SettingsRow(title: L10n.localized("quit"), icon: "power", shortcut: "⌘Q", isDestructive: true, action: { onQuit?() })
        }
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private var translationLanguageDisplayName: String {
        let currentLang = lyricsService.translationLanguage
        if currentLang == L10n.systemLanguageCode {
            return L10n.localized("mb.followSystem")
        }
        return menuBarTranslationOptions.first { $0.code == currentLang }?.name ?? currentLang
    }

    /// 菜单栏用短标签 "System"
    private var menuBarTranslationOptions: [(name: String, code: String)] {
        var opts = L10n.translationLanguageOptions
        // 第一项替换为菜单栏短标签
        if !opts.isEmpty {
            opts[0] = (L10n.localized("mb.followSystem"), "system")
        }
        return opts
    }
}

// ──────────────────────────────────────────────
// MARK: - 设置窗口（独立 NSWindow）
// ──────────────────────────────────────────────

enum SettingsTab: Hashable {
    case general
    case appearance
    case diagnostics
    case about
}

final class SettingsWindowState: ObservableObject {
    @Published var selectedTab: SettingsTab = .general
}

struct SettingsWindowView: View {
    @EnvironmentObject var musicController: MusicController
    @ObservedObject var state: SettingsWindowState
    @StateObject private var lyricsService = LyricsService.shared

    var body: some View {
        TabView(selection: $state.selectedTab) {
            generalTab
                .tabItem { Label(L10n.localized("general"), systemImage: "gear") }
                .tag(SettingsTab.general)
            appearanceTab
                .tabItem { Label(L10n.localized("appearance"), systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            #if DEBUG || LOCAL_DEVELOPER_BUILD
            DiagnosticsDebugPanel(musicController: musicController)
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                .tag(SettingsTab.diagnostics)
            #endif
            aboutTab
                .tabItem { Label(L10n.localized("about"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        .frame(minWidth: 450, minHeight: 350)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            // MusicKit 授权
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.localized("musicKit"))
                        Text(L10n.localized("musicKitDesc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

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
            }

            Section {
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
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Appearance Tab

    private var appearanceTab: some View {
        Form {
            Section {
                Toggle(isOn: UserDefaultsBinding.bool(forKey: "fullscreenAlbumCover")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.localized("fullscreenCover"))
                        Text(L10n.localized("fullscreenCoverDesc"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if #available(macOS 15.0, *) {
                Section {
                    Picker(selection: Binding(
                        get: {
                            let currentLang = lyricsService.translationLanguage
                            return currentLang == L10n.systemLanguageCode ? "system" : currentLang
                        },
                        set: { code in
                            let targetCode = code == "system" ? L10n.systemLanguageCode : code
                            lyricsService.translationLanguage = targetCode
                        }
                    )) {
                        ForEach(L10n.translationLanguageOptions, id: \.code) { option in
                            Text(option.name).tag(option.code)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.localized("translationLang"))
                            Text(L10n.localized("translationLangDesc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.linearGradient(
                    colors: [.accentColor, .accentColor.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .symbolEffect(.pulse, options: .repeating.speed(0.3))

            Text("nanoPod")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            Text("\(L10n.localized("version")) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer()

            Link(destination: URL(string: "https://github.com/yinanli1917-cloud/AM-MiniPlayer")!) {
                Label("GitHub", systemImage: "link")
                    .font(.system(size: 13))
            }
            .buttonStyle(.link)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ──────────────────────────────────────────────
// MARK: - 通用设置行组件
// ──────────────────────────────────────────────

struct SettingsRow: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isDestructive ? .red : .secondary)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isDestructive ? .red : .primary)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.bouncy(duration: 0.25)) {
                isHovering = hovering
            }
        }
        .padding(.horizontal, 6)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
    }
}

struct SettingsPickerRow: View {
    let title: String
    let icon: String
    let currentValue: String
    let options: [(name: String, code: String)]
    let onSelect: (String) -> Void

    @State private var isHovering = false
    @State private var showPicker = false

    var body: some View {
        Button(action: { showPicker.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                Spacer()

                Text(currentValue)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.bouncy(duration: 0.25)) {
                isHovering = hovering
            }
        }
        .padding(.horizontal, 6)
        .popover(isPresented: $showPicker, arrowEdge: .trailing) {
            VStack(spacing: 2) {
                ForEach(options, id: \.code) { option in
                    Button(action: {
                        onSelect(option.code)
                        showPicker = false
                    }) {
                        HStack {
                            Text(option.name)
                                .font(.system(size: 12))
                            Spacer()
                            if currentValue == option.name {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .frame(width: 140)
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
