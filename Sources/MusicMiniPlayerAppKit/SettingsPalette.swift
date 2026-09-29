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
    /// Side and bottom padding; the top is 24 (motion prototype spec §A.1).
    static let outerPadding: CGFloat = 20
    static let topPadding: CGFloat = 24
    static let contentWidth: CGFloat = 440
    /// The demo stage: a centred 16:9 rounded rectangle (creator's decision 2026-09-29).
    static let stageWidth: CGFloat = 300
    static let stageHeight: CGFloat = 169
    static let stageCorner: CGFloat = 12
    static let segmentedHeight: CGFloat = 24
    static let stageToSegmented: CGFloat = 18
    static let segmentedToContent: CGFloat = 18
    /// Same radius as the stage: two cards, one corner.
    static let cardCorner: CGFloat = 12
    /// A row with only a title is 44pt tall; one with a description line is 53pt.
    static let rowHeight: CGFloat = 44
    static let rowHeightWithDetail: CGFloat = 53
    static let rowHorizontalPadding: CGFloat = 14
    /// Scrolling page area: from under the segmented control to the window's
    /// bottom edge. The last 20pt are inside the scroll content (bottom
    /// inset), so a page that fits at rest never shows a clipped card.
    static let pageViewportHeight: CGFloat =
        windowSize.height - topPadding - stageHeight - stageToSegmented
        - segmentedHeight - segmentedToContent
    static let pageBottomInset: CGFloat = 20
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
    // (motion prototype tokens: --win / --card / --row-line / --card-hover / --seg-bg)
    static let windowBackground = Color(nsColor: dynamic(light: 0xFBFBFC, dark: 0x262628))
    static let card = Color(nsColor: dynamic(light: 0xF3F3F5, dark: 0x303033))
    static let cardSeparator = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.08, darkWhite: 1, darkAlpha: 0.08))
    /// Row under the pointer: the trackpad page's hover grey.
    static let rowHover = Color(nsColor: dynamic(light: 0xE8E8EC, dark: 0x3B3B3F))
    /// The row whose scene the stage is showing, while the pointer is elsewhere (hover grey at 55%).
    static let rowActive = rowHover.opacity(0.55)

    // Segmented control (--seg-bg)
    static let segmentTrack = Color(nsColor: dynamic(light: 0xE7E7EA, dark: 0x3A3A3D))

    // Switch (--sw-off) and push button (--m-btn / --m-hair / --m-btnshadow)
    static let switchOff = Color(nsColor: NSColor(name: nil) { isDark($0) ? NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.4) : NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.25) })
    static let buttonFill = Color(nsColor: dynamic(light: 0xFFFFFF, dark: 0x5A5A5E))
    static let hairline = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.09, darkWhite: 1, darkAlpha: 0.10))
    static let hairlineStrong = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.20, darkWhite: 1, darkAlpha: 0.22))
    static let buttonShadow = Color(nsColor: dynamicWhite(lightWhite: 0, lightAlpha: 0.18, darkWhite: 0, darkAlpha: 0.50))

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
