/**
 * [INPUT]: Depends on MusicMiniPlayerCore's GlobalShortcutAction and
 *          OnboardingAuthorizationStatus; SettingsPalette/SettingsMetrics;
 *          SettingsDemoArt (the stills themselves).
 * [OUTPUT]: Exports SettingsDemo (one case per settings row), SettingsDemoContext
 *           (current setting values the stills reflect), DemoStage (the 440×120
 *           frame: two tiles + caption, cross-fading between rows).
 * [POS]: Settings window's demo stage FRAME. Laid out like System Settings ›
 *        Trackpad (docs/design/2026-09-25-menu-settings/ref-system-settings-
 *        trackpad.webp): two rounded tiles side by side, the left holds the
 *        object / before, the right the result / in context. This round every
 *        row shows a clean STATIC still (SettingsDemoArt); the animated
 *        prototypes replace the stills later, so nothing here animates except
 *        the 0.22s cross-fade between two stills (skipped under Reduce Motion).
 */

import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - SettingsDemo (one case per row that has a demo)
// ──────────────────────────────────────────────

/// One case per settings row (proposal §4.3). `SettingsWindowStructureTests`
/// pins `Set(SettingsDemo.allCases)` against the `demo:` values the rows in
/// `SettingsView.swift` declare — exact 1:1.
///
/// The proposal's prose count ("13 个 case") undercounts against the row tables
/// it lists (Player 4 + General 6 + Shortcuts 5 = 15); every row gets its own
/// case for a verifiable 1:1 mapping.
enum SettingsDemo: String, CaseIterable {
    // Player
    case fullscreenCover
    case edgeShowSongOnTrackChange
    case showTranslation
    case translateTo
    // General
    case launchAtLogin
    case showInDock
    case gettingToKnowNanoPod
    case musicAutomation
    case appleMusicAccess
    case playbackHistory
    // Shortcuts
    case playPauseShortcut
    case nextTrackShortcut
    case previousTrackShortcut
    case showHidePlayerShortcut
    case hideToEdgeShortcut
}

extension SettingsTab {
    /// The still the stage shows before any row has been rested on.
    var defaultDemo: SettingsDemo? {
        switch self {
        case .player: return .fullscreenCover
        case .general: return .launchAtLogin
        case .shortcuts: return .playPauseShortcut
        case .about: return nil
        #if DEBUG || LOCAL_DEVELOPER_BUILD
        case .diagnostics: return nil
        #endif
        }
    }
}

/// What the stills need to know from the running app — plain data, no
/// UserDefaults/service reads inside the art itself. (The stills show both
/// ends of a setting, so on/off values are not needed until the animated
/// prototypes land.)
struct SettingsDemoContext {
    /// A sample line in the chosen translation language.
    var translationSampleText: String
    /// The user's recorded shortcuts (empty string = none recorded).
    var shortcutDescriptions: [GlobalShortcutAction: String]

    func shortcutLabel(for action: GlobalShortcutAction) -> String {
        shortcutDescriptions[action] ?? ""
    }
}

// ──────────────────────────────────────────────
// MARK: - DemoStage
// ──────────────────────────────────────────────

/// The 440×120 stage above the segmented control. `demo` changes → the old
/// pair of tiles and the new pair cross-fade. `reduceMotion` is an explicit
/// parameter (not read from the environment) so tests and renders can pin it.
struct DemoStage: View {
    let demo: SettingsDemo
    let context: SettingsDemoContext
    let reduceMotion: Bool
    let caption: String

    /// The only animation on the stage. `nil` under Reduce Motion: the still
    /// swaps instantly.
    static func crossFade(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    var body: some View {
        ZStack {
            DemoTilePair(demo: demo, context: context, caption: caption)
                .id(demo)
                .transition(.opacity)
        }
        .frame(width: SettingsMetrics.contentWidth, height: SettingsMetrics.stageHeight)
        .animation(Self.crossFade(reduceMotion: reduceMotion), value: demo)
        .accessibilityHidden(true)
    }
}

/// Two tiles + the row-name caption in the left tile's bottom-left corner
/// (draft: `.stage .capt`, 11pt secondary, 10 / 8).
struct DemoTilePair: View {
    let demo: SettingsDemo
    let context: SettingsDemoContext
    let caption: String

    var body: some View {
        let art = demo.art(context: context)
        HStack(spacing: SettingsMetrics.stageTileGap) {
            DemoTile(style: art.left.style) { art.left.content }
                .overlay(alignment: .bottomLeading) {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(art.captionOnDark ? AnyShapeStyle(Color.white.opacity(0.6)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 0))
                }
            DemoTile(style: art.right.style) { art.right.content }
        }
    }
}

enum DemoTileStyle {
    /// Card-coloured tile (the trackpad page's grey "device" tile).
    case neutral
    /// Tinted "desktop" tile (the trackpad page's blue screen tile).
    case screen
}

struct DemoTile<Content: View>: View {
    let style: DemoTileStyle
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Rectangle().fill(style == .screen ? SettingsPalette.screenTile : SettingsPalette.card)
            // Objects sit a little high so the row-name caption never touches them.
            content.offset(y: style == .neutral ? -4 : 0)
        }
        .frame(width: SettingsMetrics.tileWidth, height: SettingsMetrics.stageHeight)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.tileCorner, style: .continuous))
    }
}
