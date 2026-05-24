/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 MusicController/LyricsService
 *          依赖 LocalizedStrings 的 L10n/UserDefaultsBinding
 * [OUTPUT]: 导出 SettingsWindowView、SettingsWindowState
 * [POS]: MusicMiniPlayerApp 的设置界面集合
 */

import SwiftUI
import MusicMiniPlayerCore
import Translation
import UniformTypeIdentifiers

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

            Text("\(L10n.localized("version")) \(displayVersion)")
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

    private var displayVersion: String {
        Bundle.main.infoDictionary?["NPDisplayVersion"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "?"
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
