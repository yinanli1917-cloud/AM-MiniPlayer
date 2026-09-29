/**
 * [INPUT]: Depends on AppKit dynamic NSColor (appearance-resolved) only.
 * [OUTPUT]: Exports SettingsPalette (colours) and SettingsMetrics (pt constants)
 *           for the settings window.
 * [POS]: Single source for the settings window's look, transcribed from the
 *        finished visual draft (docs/design/2026-09-25-menu-settings/mockup.html
 *        `.mock.light` / `.mock.dark` palettes and the `.v3` window rules).
 *        Text uses the system semantic colours (.primary/.secondary = the
 *        draft's --m-fg/--m-fg2); everything the draft hard-codes lives here.
 */

import SwiftUI
import AppKit

// ──────────────────────────────────────────────
// MARK: - Metrics (draft: .win.v3 / .stage / .segc / .card / .crow)
// ──────────────────────────────────────────────

enum SettingsMetrics {
    /// Window content size (proposal §4.2).
    static let windowSize = CGSize(width: 480, height: 562)
    static let outerPadding: CGFloat = 20
    static let contentWidth: CGFloat = 440
    static let stageHeight: CGFloat = 120
    static let stageTileGap: CGFloat = 10
    static let tileWidth: CGFloat = (contentWidth - stageTileGap) / 2
    static let tileCorner: CGFloat = 10
    static let segmentedHeight: CGFloat = 24
    static let stageToSegmented: CGFloat = 14
    static let segmentedToContent: CGFloat = 14
    static let cardCorner: CGFloat = 10
    static let rowMinHeight: CGFloat = 40
    static let rowVerticalPadding: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 10
    /// Scrolling page area: from under the segmented control to the window's
    /// bottom edge. The last 12pt are inside the scroll content (bottom
    /// inset), so a page that fits at rest never shows a clipped card.
    static let pageViewportHeight: CGFloat =
        windowSize.height - outerPadding - stageHeight - stageToSegmented
        - segmentedHeight - segmentedToContent
    static let pageBottomInset: CGFloat = 12
}

// ──────────────────────────────────────────────
// MARK: - Palette
// ──────────────────────────────────────────────

enum SettingsPalette {

    /// Brand accent (`AccentColor` asset: light #FA4058, dark #FB546C — proposal
    /// "强调色"). In the shipping app `NSAccentColorName` makes
    /// `NSColor.controlAccentColor` resolve to this (or to the user's own
    /// choice when their system accent is not Multicolor — HIG behaviour).
    /// A bare unit-test process has no such Info.plist, so the offscreen
    /// render tests install the brand values through `accentOverride`.
    static let brandAccent = dynamic(light: 0xFA4058, dark: 0xFB546C)

    #if DEBUG
    nonisolated(unsafe) static var accentOverride: NSColor?
    #endif

    static var accentNS: NSColor {
        #if DEBUG
        if let accentOverride { return accentOverride }
        #endif
        return .controlAccentColor
    }
    static var accent: Color { Color(nsColor: accentNS) }

    // Window body / grouped cards (--m-win, --m-card, --m-cardsep)
    static let windowBackground = Color(nsColor: dynamic(light: 0xFEFEFE, dark: 0x1F1F21))
    static let card = Color(nsColor: dynamic(light: 0xF4F4F5, dark: 0x2A2A2D))
    static let cardSeparator = Color(nsColor: dynamic(light: 0xE6E6E8, darkWhite: 1, darkAlpha: 0.09))
    /// `.crow.hov` — rgba(127,127,127,.08) in both appearances.
    static let rowHover = Color(nsColor: NSColor(white: 0.498, alpha: 0.08))

    // Segmented control (--m-segbg)
    static let segmentTrack = Color(nsColor: dynamic(light: 0xE9E9EB, dark: 0x3A3A3E))

    // Switch (--m-off) and push button (--m-btn / --m-hair / --m-btnshadow)
    static let switchOff = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.22, darkWhite: 1, darkAlpha: 0.26))
    static let buttonFill = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x5A5A5E))
    static let hairline = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.09, darkWhite: 1, darkAlpha: 0.10))
    static let hairlineStrong = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.20, darkWhite: 1, darkAlpha: 0.22))
    static let buttonShadow = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.18, darkWhite: 0, darkAlpha: 0.50))

    // Demo stage tiles (draft: .stage / .mscreen / .mpanel / .keycap)
    static let screenTile = Color(nsColor: dynamic(light: 0xDFE3EA, dark: 0x34363C))
    static let screenBar = Color(nsColor: dynamicWhite(lightWhite: 1, lightAlpha: 0.75, darkWhite: 1, darkAlpha: 0.14))
    static let screenDock = Color(nsColor: dynamicWhite(lightWhite: 1, lightAlpha: 0.70, darkWhite: 1, darkAlpha: 0.14))
    static let fg3 = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.28, darkWhite: 1, darkAlpha: 0.30))
    static let panel = Color(nsColor: dynamic(light: 0x2B2B30, dark: 0x151518))
    static let panelInk = Color.white.opacity(0.9)
    static let panelInk2 = Color(nsColor: dynamicWhite(lightWhite: 1, lightAlpha: 0.45, darkWhite: 1, darkAlpha: 0.40))
    static let cover = Color(nsColor: dynamic(light: 0x7AA2E8, dark: 0x5F86D4))
    static let coverEnd = Color(nsColor: NSColor(srgbRed: 0x3F / 255, green: 0x5F / 255, blue: 0xA8 / 255, alpha: 1))
    static let coverAlt = Color(nsColor: dynamic(light: 0xE8A06A, dark: 0xD18A58))
    static let coverAltEnd = Color(nsColor: NSColor(srgbRed: 0xA3 / 255, green: 0x55 / 255, blue: 0x2A / 255, alpha: 1))
    static let keycapFill = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x1A1A1C))

    // MARK: helpers

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { isDark($0) ? rgb(dark) : rgb(light) }
    }

    static func dynamic(light: UInt32, darkWhite: CGFloat, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { isDark($0) ? NSColor(white: darkWhite, alpha: darkAlpha) : rgb(light) }
    }

    static func dynamicWhite(lightWhite: CGFloat, lightAlpha: CGFloat, darkWhite: CGFloat, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) {
            isDark($0)
                ? NSColor(white: darkWhite, alpha: darkAlpha)
                : NSColor(white: lightWhite, alpha: lightAlpha)
        }
    }
}
