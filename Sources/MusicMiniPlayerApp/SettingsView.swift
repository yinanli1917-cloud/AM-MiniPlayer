/**
 * [INPUT]: 依赖 MusicMiniPlayerCore 的 MusicController/LyricsService
 *          依赖 LocalizedStrings 的 L10n/UserDefaultsBinding
 * [OUTPUT]: 导出 MenuBarSettingsView、SettingsWindowView、SettingsRow、SettingsToggleRow、SettingsPickerRow
 * [POS]: MusicMiniPlayerApp 的设置界面集合
 */

import SwiftUI
import MusicMiniPlayerCore
import Translation

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

struct SettingsWindowView: View {
    @EnvironmentObject var musicController: MusicController
    @StateObject private var lyricsService = LyricsService.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L10n.localized("general"), systemImage: "gear") }
            appearanceTab
                .tabItem { Label(L10n.localized("appearance"), systemImage: "paintbrush") }
            aboutTab
                .tabItem { Label(L10n.localized("about"), systemImage: "info.circle") }
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
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Circle()
                            .fill(musicController.musicKitAuthorized ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)

                        Text(musicController.musicKitAuthStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)

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
                            .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
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
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Music Mini Player")
                .font(.title)
                .fontWeight(.semibold)

            Text("\(L10n.localized("version")) 1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 20) {
                Link(destination: URL(string: "https://github.com/YinanLi/MusicMiniPlayer")!) {
                    Label("GitHub", systemImage: "link")
                }
                .buttonStyle(.link)
            }

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
                    .foregroundColor(isDestructive ? .red : .secondary)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(isDestructive ? .red : .primary)

                Spacer()

                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
                .foregroundColor(.secondary)
                .frame(width: 16, height: 16)

            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.primary)

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
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)

                Spacer()

                Text(currentValue)
                    .font(.system(size: 12))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
                                    .foregroundColor(.accentColor)
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
