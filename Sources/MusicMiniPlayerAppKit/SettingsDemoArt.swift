/**
 * [INPUT]: Depends on SettingsPalette (mockup colours), SettingsDemo /
 *          SettingsDemoContext / DemoTileStyle (SettingsDemoStage),
 *          MusicMiniPlayerCore's GlobalShortcutAction and
 *          OnboardingAuthorizationStatus.
 * [OUTPUT]: Exports DemoArt (a left + right tile), SettingsDemo.art(context:),
 *           and the shared drawing primitives DemoMiniPanel, DemoScreenContent,
 *           DemoLyricSheet, DemoKeycap, DemoMusicIcon, DemoTourCard.
 * [POS]: The static stills on the settings demo stage — one clean illustration
 *        pair per settings row, transcribed from the mockup's `.mpanel` /
 *        `.mscreen` / `.lyr` / `.keycap` / `.musicicon` scenes (proposal §4.3
 *        "静帧"). Vector SwiftUI only: no bitmaps, no animation. Left tile =
 *        the object or the "off" side, right tile = the result or the "on"
 *        side.
 */

import SwiftUI
import MusicMiniPlayerCore

// ──────────────────────────────────────────────
// MARK: - Art model
// ──────────────────────────────────────────────

struct DemoArt {
    struct Side {
        let style: DemoTileStyle
        let content: AnyView
        init(_ style: DemoTileStyle = .neutral, @ViewBuilder _ content: () -> some View) {
            self.style = style
            self.content = AnyView(content())
        }
    }

    let left: Side
    let right: Side
    /// The left tile is a dark "screen off" picture: its caption is drawn light.
    var captionOnDark: Bool = false
}

extension SettingsDemo {
    /// The still for this row. `context` supplies the recorded shortcut label
    /// and the translation sample.
    func art(context c: SettingsDemoContext) -> DemoArt {
        switch self {

        case .fullscreenCover:
            return DemoArt(
                left: .init { DemoMiniPanel(cover: .fit, u: 1.1) },
                right: .init { DemoMiniPanel(cover: .full, u: 1.1) })

        case .edgeShowSongOnTrackChange:
            return DemoArt(
                left: .init { DemoMiniPanel(cover: .fit, u: 1.1) },
                right: .init(.screen) { DemoScreenContent(edge: .stripWithCapsule) })

        case .showTranslation:
            return DemoArt(
                left: .init { DemoLyricSheet(translation: nil) },
                right: .init { DemoLyricSheet(translation: c.translationSampleText) })

        case .translateTo:
            return DemoArt(
                left: .init {
                    Image(systemName: "translate")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(SettingsPalette.accent)
                },
                right: .init { DemoLyricSheet(translation: c.translationSampleText) })

        case .launchAtLogin:
            return DemoArt(
                left: .init(.screen) { DemoScreenContent(dim: 0.62, menuBarNote: false) },
                right: .init(.screen) { DemoScreenContent(menuBarNote: true) },
                captionOnDark: true)

        case .showInDock:
            return DemoArt(
                left: .init(.screen) { DemoScreenContent(dock: .plain) },
                right: .init(.screen) { DemoScreenContent(dock: .withApp) })

        case .gettingToKnowNanoPod:
            return DemoArt(
                left: .init { DemoMiniPanel(cover: .fit, u: 1.1) },
                right: .init { DemoTourCard() })

        case .musicAutomation:
            return DemoArt(
                left: .init { DemoPermissionFlow(granted: false) },
                right: .init { DemoPermissionFlow(granted: true) })

        case .appleMusicAccess:
            return DemoArt(
                left: .init { DemoMiniPanel(cover: .placeholder, u: 1.1) },
                right: .init { DemoMiniPanel(cover: .fit, u: 1.1) })

        case .playbackHistory:
            return DemoArt(
                left: .init { DemoMiniPanel(cover: .history(rows: 3), u: 1.1) },
                right: .init { DemoMiniPanel(cover: .history(rows: 0), u: 1.1) })

        case .playPauseShortcut:
            return DemoArt(
                left: .init { DemoKeycap(label: c.shortcutLabel(for: .togglePlayPause)) },
                right: .init { DemoMiniPanel(cover: .fit, glyph: "pause.fill", u: 1.1) })

        case .nextTrackShortcut:
            return DemoArt(
                left: .init { DemoKeycap(label: c.shortcutLabel(for: .nextTrack)) },
                right: .init { DemoMiniPanel(cover: .fit, alt: true, u: 1.1) })

        case .previousTrackShortcut:
            return DemoArt(
                left: .init { DemoKeycap(label: c.shortcutLabel(for: .previousTrack)) },
                right: .init { DemoMiniPanel(cover: .fit, alt: true, u: 1.1) })

        case .showHidePlayerShortcut:
            return DemoArt(
                left: .init { DemoKeycap(label: c.shortcutLabel(for: .togglePanel)) },
                right: .init(.screen) { DemoScreenContent(panel: .faded) })

        case .hideToEdgeShortcut:
            return DemoArt(
                left: .init { DemoKeycap(label: c.shortcutLabel(for: .hideToEdge)) },
                right: .init(.screen) { DemoScreenContent(edge: .strip) })
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Mini panel (.mpanel: 62.5 × 71 = the real 250 × 284 panel ÷ 4)
// ──────────────────────────────────────────────

struct DemoMiniPanel: View {
    enum Cover: Equatable {
        case fit                  // cover at 68% width, centred (real artSize = 0.68 × width)
        case full                 // cover fills the panel, text sits on a bottom gradient
        case placeholder          // grey cover: no artwork access
        case history(rows: Int)   // playlist page rows
    }

    var cover: Cover = .fit
    var alt: Bool = false
    var glyph: String? = nil
    /// Scale over the draft's 62.5-wide panel.
    var u: CGFloat = 1

    private var width: CGFloat { 62.5 * u }
    private var height: CGFloat { 71 * u }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SettingsPalette.panel
            switch cover {
            case .fit, .placeholder:
                coverSquare(size: 42.5 * u, corner: 2 * u)
                    .offset(x: 10 * u, y: 8 * u)
                if let glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 7.5 * u, weight: .bold))
                        .foregroundStyle(SettingsPalette.panelInk)
                        .frame(width: width)
                        .offset(y: 55.5 * u)
                } else {
                    textBars(x1: 14, y1: 54, w1: 34, x2: 20, y2: 60, w2: 22)
                }
            case .full:
                coverSquare(size: width, corner: 0)
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .bottom, endPoint: .top)
                    .frame(height: 26 * u)
                    .offset(y: height - 26 * u)
                textBars(x1: 6, y1: 56, w1: 34, x2: 6, y2: 62, w2: 22)
            case .history(let rows):
                ForEach(0..<rows, id: \.self) { i in
                    historyRow(index: i).offset(y: (9 + CGFloat(i) * 18) * u)
                }
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 4 * u, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 3 * u, y: 1 * u)
    }

    private func coverSquare(size: CGFloat, corner: CGFloat) -> some View {
        let colors = cover == .placeholder
            ? [SettingsPalette.fg3, SettingsPalette.fg3]
            : (alt ? [SettingsPalette.coverAlt, SettingsPalette.coverAltEnd] : [SettingsPalette.cover, SettingsPalette.coverEnd])
        return RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
    }

    private func textBars(x1: CGFloat, y1: CGFloat, w1: CGFloat, x2: CGFloat, y2: CGFloat, w2: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2 * u).fill(SettingsPalette.panelInk)
                .frame(width: w1 * u, height: 3 * u).offset(x: x1 * u, y: y1 * u)
            RoundedRectangle(cornerRadius: 2 * u).fill(SettingsPalette.panelInk2)
                .frame(width: w2 * u, height: 3 * u).offset(x: x2 * u, y: y2 * u)
        }
    }

    private func historyRow(index: Int) -> some View {
        HStack(spacing: 4 * u) {
            RoundedRectangle(cornerRadius: 1.5 * u)
                .fill(LinearGradient(
                    colors: index % 2 == 0
                        ? [SettingsPalette.cover, SettingsPalette.coverEnd]
                        : [SettingsPalette.coverAlt, SettingsPalette.coverAltEnd],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 12 * u, height: 12 * u)
            VStack(alignment: .leading, spacing: 2 * u) {
                RoundedRectangle(cornerRadius: 1 * u).fill(SettingsPalette.panelInk)
                    .frame(width: (28 - CGFloat(index) * 4) * u, height: 2.5 * u)
                RoundedRectangle(cornerRadius: 1 * u).fill(SettingsPalette.panelInk2)
                    .frame(width: 18 * u, height: 2.5 * u)
            }
        }
        .padding(.leading, 6 * u)
    }
}

// ──────────────────────────────────────────────
// MARK: - Screen (.mscreen: the tile IS the screen)
// ──────────────────────────────────────────────

struct DemoScreenContent: View {
    enum Dock { case none, plain, withApp }
    enum Edge { case none, strip, stripWithCapsule }
    enum Panel { case none, visible, faded }

    var dim: Double = 0
    var menuBarNote: Bool = true
    var dock: Dock = .none
    var edge: Edge = .none
    var panel: Panel = .none

    private let w = SettingsMetrics.tileWidth
    private let h = SettingsMetrics.stageHeight

    var body: some View {
        ZStack(alignment: .topLeading) {
            // menu bar
            SettingsPalette.screenBar.frame(width: w, height: 10)
            ForEach([6, 16, 26], id: \.self) { x in
                RoundedRectangle(cornerRadius: 2).fill(SettingsPalette.fg3)
                    .frame(width: 6, height: 6).offset(x: CGFloat(x), y: 2)
            }
            if menuBarNote {
                Text("\u{266A}").font(.system(size: 8)).foregroundStyle(.primary)
                    .frame(width: 10, height: 10)
                    .offset(x: w - 18, y: 0)
            }

            if panel != .none {
                DemoMiniPanel(cover: .fit, u: 0.85)
                    .opacity(panel == .faded ? 0.35 : 1)
                    .offset(x: (w - 62.5 * 0.85) / 2, y: 22)
            }

            if edge != .none {
                stripView.offset(x: w - 6, y: 30)
                if edge == .stripWithCapsule { capsuleView.offset(x: w - 6 - 6 - 72, y: 47) }
            }

            if dock != .none { dockView }

            Color.black.opacity(dim).frame(width: w, height: h)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }

    private var stripView: some View {
        ZStack(alignment: .bottom) {
            SettingsPalette.panel
            SettingsPalette.accent.opacity(0.9).frame(height: 34)
        }
        .frame(width: 6, height: 56)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3))
    }

    private var capsuleView: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [SettingsPalette.coverAlt, SettingsPalette.coverAltEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 14, height: 14)
            RoundedRectangle(cornerRadius: 2).fill(SettingsPalette.panelInk).frame(width: 34, height: 3)
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .frame(height: 22)
        .background(Capsule().fill(SettingsPalette.panel))
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }

    private var dockView: some View {
        HStack(spacing: 3) {
            ForEach(0..<(dock == .withApp ? 5 : 4), id: \.self) { i in
                if dock == .withApp && i == 2 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.353, green: 0.784, blue: 0.980), Color(red: 0.039, green: 0.376, blue: 1), Color(red: 0.227, green: 0.173, blue: 0.541)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 12, height: 12)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(SettingsPalette.fg3).frame(width: 12, height: 12)
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(height: 16)
        .background(RoundedRectangle(cornerRadius: 5).fill(SettingsPalette.screenDock))
        .frame(width: w, height: h - 5, alignment: .bottom)
        // Nudged right of centre so the row-name caption (left tile) never touches it.
        .offset(x: 24)
    }
}

// ──────────────────────────────────────────────
// MARK: - Lyric sheet (.lyr)
// ──────────────────────────────────────────────

struct DemoLyricSheet: View {
    let translation: String?

    var body: some View {
        VStack(spacing: 9) {
            bar(width: 110, height: 6, fill: SettingsPalette.fg3)
            bar(width: 150, height: 7, fill: Color.primary.opacity(0.85))
            if let translation {
                Text(translation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, -3)
            }
            bar(width: 110, height: 6, fill: SettingsPalette.fg3)
        }
        .padding(.horizontal, 12)
    }

    private func bar(width: CGFloat, height: CGFloat, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(fill).frame(width: width, height: height)
    }
}

// ──────────────────────────────────────────────
// MARK: - Keycap (.keycap)
// ──────────────────────────────────────────────

/// Shows the user's recorded shortcut, one glyph per key; an unrecorded
/// shortcut is a dashed empty cap.
struct DemoKeycap: View {
    let label: String

    var body: some View {
        Group {
            if label.isEmpty {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 54, height: 22)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(label.enumerated()), id: \.offset) { _, ch in
                        Text(String(ch)).font(.system(size: 11))
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(SettingsPalette.keycapFill)
                        .shadow(color: SettingsPalette.hairlineStrong, radius: 0, y: 1.5)
                )
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsPalette.hairlineStrong, lineWidth: 1))
            }
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Music icon → panel (permissions)
// ──────────────────────────────────────────────

struct DemoMusicIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.984, green: 0.329, blue: 0.424), Color(red: 0.98, green: 0.169, blue: 0.263)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 26, height: 26)
            .overlay(Image(systemName: "music.note").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
    }
}

struct DemoPermissionFlow: View {
    /// granted: solid line + a panel with a song; not granted: dashed line + empty panel.
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            DemoMusicIcon()
            Group {
                if granted {
                    Rectangle().fill(Color.secondary).frame(width: 30, height: 1.5)
                } else {
                    Line().stroke(SettingsPalette.fg3, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 30, height: 1.5)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            DemoMiniPanel(cover: granted ? .fit : .placeholder, u: 0.9)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path(); p.move(to: CGPoint(x: 0, y: rect.midY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); return p
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Tour card
// ──────────────────────────────────────────────

/// A small onboarding card: progress ring outline over two text bars.
struct DemoTourCard: View {
    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().stroke(SettingsPalette.hairlineStrong, lineWidth: 3)
                Circle().trim(from: 0, to: 0.4)
                    .stroke(SettingsPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.75)).frame(width: 46, height: 3)
            RoundedRectangle(cornerRadius: 2).fill(SettingsPalette.fg3).frame(width: 32, height: 3)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsPalette.keycapFill))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SettingsPalette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}
