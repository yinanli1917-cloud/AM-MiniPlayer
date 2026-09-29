/**
 * [INPUT]: SwiftUI, AppKit (NSColor for the contrast math).
 * [OUTPUT]: Exports TourCardMetrics (sizes/spacings pinned to the storyboard's
 *           `.card` CSS), TourCardPalette (ink/muted/track/accent per
 *           appearance), TourContrast (WCAG ratio), TourLinkStyle,
 *           TourPrimaryButtonStyle, TourSecondaryButtonStyle.
 * [POS]: MusicMiniPlayerAppKit/Tour. The one place the card's numbers live so
 *        `TourCardView` reads like the storyboard and tests can pin the
 *        numbers. Buttons are custom, NOT system `.bordered*`/`.link` styles:
 *        the card window is never key, and system controls in a non-key
 *        window render their grey "inactive" look (founder 2026-09-29: grey
 *        buttons, blue links). These styles never depend on window state.
 */

import SwiftUI
import AppKit

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Metrics (storyboard.html `.card` CSS, proposal §4.7)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourCardMetrics {
    /// The card body. The window is this plus the beak on the beak side.
    static let bodyWidth: CGFloat = 260
    static let beakSize: CGFloat = 12
    static let cornerRadius: CGFloat = 14
    static let paddingTop: CGFloat = 14
    static let paddingSide: CGFloat = 14
    static let paddingBottom: CGFloat = 12

    // Sizes: the macOS standard readable tier (founder 2026-09-29: the
    // storyboard's 13/12/12/11/11 read small on a real Mac). Title 15
    // semibold, body and beats 13, footer links and buttons 12 — same
    // ratios as the system's own popovers (headline / body / callout).
    static let titleSize: CGFloat = 15
    static let bodySize: CGFloat = 13
    static let beatSize: CGFloat = 13
    static let linkSize: CGFloat = 12
    static let buttonSize: CGFloat = 12
    static let noteSize: CGFloat = 10.5
    static let confirmSize: CGFloat = 13

    /// CSS `line-height` minus the font's natural line height, as SwiftUI
    /// `lineSpacing` (extra space added between lines).
    static let titleLineSpacing: CGFloat = 1.5
    static let bodyLineSpacing: CGFloat = 3.0

    static let titleTopInset: CGFloat = 4     // `.title{padding-top:4px}`
    static let headGap: CGFloat = 12          // title <-> ring
    static let bodyTop: CGFloat = 8
    static let chipTop: CGFloat = 8
    static let beatsTop: CGFloat = 10
    static let beatGap: CGFloat = 6
    static let beatDot: CGFloat = 14
    static let gestureTop: CGFloat = 10
    static let noteTop: CGFloat = 8
    static let confirmTop: CGFloat = 8
    static let footTop: CGFloat = 12

    static let buttonPaddingV: CGFloat = 4
    static let buttonPaddingH: CGFloat = 10
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Palette (storyboard `--mock-*`, light + dark)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TourCardPalette: Equatable {
    var ink: Color
    var muted: Color
    /// Low-contrast fill: chip, secondary button, unchecked beat outline.
    var track: Color
    var buttonFill: Color
    var buttonInk: Color
    var accent: Color
    /// §4.7 "ink tier": the accent hue darkened/lightened to >= 4.5:1 for
    /// TEXT (the ring's step number); graphics keep `accent`.
    var accentInk: Color
    var ringTrack: Color
    var hairline: Color

    static func resolve(dark: Bool) -> TourCardPalette {
        dark ? .dark : .light
    }

    /// `#FA4058` on light (§4.7).
    static let light = TourCardPalette(
        ink: Color(hex: 0x1A1A1F), muted: Color(hex: 0x55545F),
        track: Color.black.opacity(0.10),
        buttonFill: Color(hex: 0x1A1A1F), buttonInk: .white,
        accent: Color(hex: 0xFA4058), accentInk: Color(hex: 0xD42640), ringTrack: Color(hex: 0xFA4058).opacity(0.22),
        hairline: Color.black.opacity(0.08)
    )

    /// `#FB546C` on dark (§4.7).
    static let dark = TourCardPalette(
        ink: Color(hex: 0xF3F2F6), muted: Color(hex: 0xB4B1BF),
        track: Color.white.opacity(0.14),
        buttonFill: Color(hex: 0xF3F2F6), buttonInk: Color(hex: 0x1A1A1F),
        accent: Color(hex: 0xFB546C), accentInk: Color(hex: 0xFF8497), ringTrack: Color(hex: 0xFB546C).opacity(0.28),
        hairline: Color.white.opacity(0.10)
    )
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// WCAG 2.x contrast ratio between two sRGB colors (alpha is composited over
/// `backdrop` first, so translucent text is measured as it is seen).
enum TourContrast {
    struct RGB: Equatable { var r: Double; var g: Double; var b: Double; var a: Double = 1 }

    static func rgb(_ color: Color) -> RGB {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }

    static func over(_ top: RGB, _ bottom: RGB) -> RGB {
        let a = top.a + bottom.a * (1 - top.a)
        guard a > 0 else { return RGB(r: 0, g: 0, b: 0, a: 0) }
        func mix(_ t: Double, _ b: Double) -> Double { (t * top.a + b * bottom.a * (1 - top.a)) / a }
        return RGB(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a: a)
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(text: RGB, on background: RGB) -> Double {
        let fg = over(text, background)
        let l1 = luminance(fg), l2 = luminance(background)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Button styles (window-state independent)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// `.card .link`: 12pt, secondary ink, no chrome. Pressed = ink.
struct TourLinkStyle: ButtonStyle {
    var palette: TourCardPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: TourCardMetrics.linkSize))
            .foregroundStyle(configuration.isPressed ? palette.ink : palette.muted)
            .contentShape(Rectangle())
    }
}

/// `.card .mbtn`: solid capsule, 12pt semibold, inverse ink.
struct TourPrimaryButtonStyle: ButtonStyle {
    var palette: TourCardPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: TourCardMetrics.buttonSize, weight: .semibold))
            .foregroundStyle(palette.buttonInk)
            .padding(.horizontal, TourCardMetrics.buttonPaddingH)
            .padding(.vertical, TourCardMetrics.buttonPaddingV)
            .background(Capsule().fill(palette.buttonFill))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// `.card .mbtn.sec`: 10-14% contrast fill, ink text.
struct TourSecondaryButtonStyle: ButtonStyle {
    var palette: TourCardPalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: TourCardMetrics.buttonSize, weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, TourCardMetrics.buttonPaddingH)
            .padding(.vertical, TourCardMetrics.buttonPaddingV)
            .background(Capsule().fill(palette.track))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
