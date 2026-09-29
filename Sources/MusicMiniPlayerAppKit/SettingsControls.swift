/**
 * [INPUT]: Depends on SettingsPalette/SettingsMetrics, SettingsHoverIntent
 *          (row tracker + model), SettingsDemo (row → demo identity).
 * [OUTPUT]: Exports SettingsCard, SettingsDivider, SettingsSectionHeader,
 *           SettingsSectionFooter, SettingsRow, SettingsSwitchStyle,
 *           SettingsPushButtonStyle.
 * [POS]: Settings window's building blocks, drawn to the mockup's `.card` /
 *        `.crow` / `.tg` / `.pbtn` rules. Custom-drawn (not NSSwitch) on
 *        purpose: system controls grey out in an inactive window and their
 *        divider drawing is not ours to fix, and the draft specifies a 36×20
 *        switch. They stay real SwiftUI Toggle / Button semantics. (The page
 *        switcher is the native toolbar-tab strip, SettingsTabViewController.)
 */

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - Card, dividers, section chrome
// ──────────────────────────────────────────────

/// Grouped card: radius 12 (= the demo stage's), card fill, rows clipped to the corner.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous))
    }
}

/// The prototype's `.row + .row { border-top: 1px }`: the line sits INSIDE the lower row's
/// height, on top of its hover fill — so it takes no height of its own (rows stay exactly
/// 44 / 53pt and a whole card is the plain sum of its rows) and draws above the row below.
struct SettingsDivider: View {
    var body: some View {
        Color.clear
            .frame(height: 0)
            .overlay(alignment: .top) {
                Rectangle().fill(SettingsPalette.cardSeparator).frame(height: 1)
            }
            .zIndex(1)
    }
}

/// `.cgh` — 12pt semibold secondary, 2pt indent, 18pt above / 6pt below.
struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.cgf` — 11pt secondary, 10pt inset, 6pt above, wraps at 420.
struct SettingsSectionFooter: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ──────────────────────────────────────────────
// MARK: - Row
// ──────────────────────────────────────────────

/// `.row`: 44pt (title only) or 53pt (title + description) tall, 14pt side padding, title 13pt,
/// description 11pt secondary. The row under the pointer takes the hover grey at once; the row the
/// stage is showing keeps a half-strength grey. Reports position to the hover-intent model through
/// a tracking-area background.
struct SettingsRow<Trailing: View>: View {
    let demo: SettingsDemo
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @EnvironmentObject private var hover: SettingsHoverIntentModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var background: Color {
        if hover.highlightedRow == demo { return SettingsPalette.rowHover }
        if (hover.stageDemo ?? demo.tab.defaultDemo) == demo { return SettingsPalette.rowActive }
        return .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .frame(height: detail == nil ? SettingsMetrics.rowHeight : SettingsMetrics.rowHeightWithDetail)
        .background(background)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: background)
        .background(SettingsRowHoverTracker(demo: demo, model: hover))
        .accessibilityElement(children: .contain)
    }
}

// ──────────────────────────────────────────────
// MARK: - Switch (.sw: 36×20, knob 16, 2pt inset)
// ──────────────────────────────────────────────

struct SettingsSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? SettingsPalette.accent : SettingsPalette.switchOff)
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: 36, height: 20)
            .animation(reduceMotion ? nil : .timingCurve(0.3, 1.2, 0.5, 1, duration: 0.2), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? Text("1") : Text("0"))
        .accessibilityAddTraits(.isToggle)
    }
}

// ──────────────────────────────────────────────
// MARK: - Push button (.pbtn: h24, 12pt, radius 6, hairline + shadow)
// ──────────────────────────────────────────────

struct SettingsPushButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(SettingsPalette.buttonFill)
                    .shadow(color: SettingsPalette.buttonShadow, radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsPalette.hairline, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .fixedSize()
    }
}
