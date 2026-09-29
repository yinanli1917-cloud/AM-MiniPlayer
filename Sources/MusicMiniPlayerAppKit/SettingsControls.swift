/**
 * [INPUT]: Depends on SettingsPalette/SettingsMetrics, SettingsHoverIntent
 *          (row tracker + model), SettingsDemo (row → demo identity).
 * [OUTPUT]: Exports SettingsCard, SettingsDivider, SettingsSectionHeader,
 *           SettingsSectionFooter, SettingsRow, SettingsSwitchStyle,
 *           SettingsPushButtonStyle, SettingsSegmentedControl.
 * [POS]: Settings window's building blocks, drawn to the mockup's `.card` /
 *        `.crow` / `.tg` / `.pbtn` / `.segc` rules. Custom-drawn (not
 *        NSSwitch / NSSegmentedControl) on purpose: system controls grey out
 *        in an inactive window and their divider drawing is not ours to fix,
 *        and the draft specifies an accent-filled selected segment and a
 *        36×16 switch. They stay real SwiftUI Toggle / Button semantics.
 */

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - Card, dividers, section chrome
// ──────────────────────────────────────────────

/// Grouped card: radius 10, `--m-card` fill, rows clipped to the corner.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardCorner, style: .continuous))
    }
}

/// `.crow + .crow { border-top: 1px --m-cardsep }`, full card width.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(SettingsPalette.cardSeparator).frame(height: 1)
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

/// `.crow`: min height 40, padding 8/10, title 13pt, detail 11pt secondary.
/// Lights up (`.hov`) while the pointer is on it; reports position to the
/// hover-intent model through a tracking-area background.
struct SettingsRow<Trailing: View>: View {
    let demo: SettingsDemo
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @EnvironmentObject private var hover: SettingsHoverIntentModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .background(hover.highlightedRow == demo ? SettingsPalette.rowHover : Color.clear)
        .background(SettingsRowHoverTracker(demo: demo, model: hover))
        .accessibilityElement(children: .contain)
    }
}

// ──────────────────────────────────────────────
// MARK: - Switch (.tg: 36×16, knob 14, 1pt inset)
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
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 0.75, y: 0.5)
                    .padding(1)
            }
            .frame(width: 36, height: 16)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
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

// ──────────────────────────────────────────────
// MARK: - Segmented control (.segc: 440×24, track radius 7, pad 2, seg radius 5)
// ──────────────────────────────────────────────

struct SettingsSegmentedControl: View {
    let tabs: [SettingsTab]
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? SettingsPalette.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(width: SettingsMetrics.contentWidth, height: SettingsMetrics.segmentedHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsPalette.segmentTrack)
        )
        .accessibilityElement(children: .contain)
    }
}
