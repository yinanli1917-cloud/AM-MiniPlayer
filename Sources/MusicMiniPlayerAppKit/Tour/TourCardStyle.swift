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
    /// Beat-row hover wash: accent 12 % (dark 18 %), prototype C.5.2.
    var rowHover: Color

    static func resolve(dark: Bool) -> TourCardPalette {
        dark ? .dark : .light
    }

    /// `#FA4058` on light (§4.7).
    static let light = TourCardPalette(
        ink: Color(hex: 0x1A1A1F), muted: Color(hex: 0x55545F),
        track: Color.black.opacity(0.10),
        buttonFill: Color(hex: 0x1A1A1F), buttonInk: .white,
        accent: Color(hex: 0xFA4058), accentInk: Color(hex: 0xD42640), ringTrack: Color(hex: 0xFA4058).opacity(0.22),
        hairline: Color.black.opacity(0.08), rowHover: Color(hex: 0xFA4058).opacity(0.12)
    )

    /// `#FB546C` on dark (§4.7).
    static let dark = TourCardPalette(
        ink: Color(hex: 0xF3F2F6), muted: Color(hex: 0xB4B1BF),
        track: Color.white.opacity(0.14),
        buttonFill: Color(hex: 0xF3F2F6), buttonInk: Color(hex: 0x1A1A1F),
        accent: Color(hex: 0xFB546C), accentInk: Color(hex: 0xFF8497), ringTrack: Color(hex: 0xFB546C).opacity(0.28),
        hairline: Color.white.opacity(0.10), rowHover: Color(hex: 0xFB546C).opacity(0.18)
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

/// Prototype C.5.1's press feel, shared by the three styles: hover eases the
/// scale to 1.03, press drops it to 0.96 in 0.07 s, release springs back with
/// a small overshoot (Spring(duration: 0.26, bounce: 0.4)). Reduce Motion: no
/// scaling at all (hover only changes colour, press dims to 0.75).
enum TourPressFeel {
    static func scale(hovering: Bool, pressed: Bool, reduceMotion: Bool) -> CGFloat {
        if reduceMotion { return 1 }
        if pressed { return 0.96 }
        return hovering ? 1.03 : 1
    }

    static func animation(pressed: Bool, reduceMotion: Bool) -> Animation? {
        if reduceMotion { return nil }
        return pressed ? .easeOut(duration: 0.07) : .spring(duration: 0.26, bounce: 0.4)
    }
}

/// Tracks hover for a `ButtonStyle` (a style has no state of its own).
private struct TourHoverBody<Content: View>: View {
    var configuration: ButtonStyleConfiguration
    @ViewBuilder var content: (_ hovering: Bool, _ pressed: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering, configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// `.card .link`: 12pt, secondary ink, no chrome. Hover: ink + the underline
/// draws from the left in 0.18 s; pressed 0.55 opacity. `emphasized` (the step
/// has sat unfinished for 6 s) tints it with the accent ink, no motion.
struct TourLinkStyle: ButtonStyle {
    var palette: TourCardPalette
    var emphasized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        TourHoverBody(configuration: configuration) { hovering, pressed in
            let base: Color = emphasized ? palette.accentInk : palette.muted
            configuration.label
                .font(.system(size: TourCardMetrics.linkSize))
                .foregroundStyle(hovering || pressed ? (emphasized ? palette.accentInk : palette.ink) : base)
                .overlay(alignment: .bottomLeading) {
                    Rectangle()
                        .frame(height: 1)
                        .scaleEffect(x: hovering ? 1 : 0, anchor: .leading)
                        .offset(y: 1)
                        .foregroundStyle(emphasized ? palette.accentInk : palette.ink)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
                }
                .opacity(pressed ? (reduceMotion ? 0.75 : 0.55) : 1)
                .animation(.easeOut(duration: 0.14), value: hovering)
                .contentShape(Rectangle())
        }
    }
}

/// `.card .cbtn.pri`: solid ACCENT capsule, white 12pt semibold. (It was the ink
/// colour — a black button on the finale card, 2026-09-29.) Hover: brightness
/// +7 %, scale 1.03; press: brightness -7 %, scale 0.96.
struct TourPrimaryButtonStyle: ButtonStyle {
    var palette: TourCardPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        TourHoverBody(configuration: configuration) { hovering, pressed in
            configuration.label
                .font(.system(size: TourCardMetrics.buttonSize, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, TourCardMetrics.buttonPaddingH)
                .padding(.vertical, TourCardMetrics.buttonPaddingV)
                .background(Capsule().fill(palette.accent))
                .brightness(pressed ? -0.07 : (hovering ? 0.07 : 0))
                .opacity(pressed && reduceMotion ? 0.75 : 1)
                .scaleEffect(TourPressFeel.scale(hovering: hovering, pressed: pressed, reduceMotion: reduceMotion))
                .animation(TourPressFeel.animation(pressed: pressed, reduceMotion: reduceMotion), value: pressed)
                .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14), value: hovering)
        }
    }
}

/// `.card .mbtn.sec`: 10-14% contrast fill (16 -> 26 % on hover, 36 % pressed), ink text.
struct TourSecondaryButtonStyle: ButtonStyle {
    var palette: TourCardPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        TourHoverBody(configuration: configuration) { hovering, pressed in
            configuration.label
                .font(.system(size: TourCardMetrics.buttonSize, weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, TourCardMetrics.buttonPaddingH)
                .padding(.vertical, TourCardMetrics.buttonPaddingV)
                .background(Capsule().fill(palette.ink.opacity(pressed ? 0.36 : (hovering ? 0.26 : 0.16))))
                .opacity(pressed && reduceMotion ? 0.75 : 1)
                .scaleEffect(TourPressFeel.scale(hovering: hovering, pressed: pressed, reduceMotion: reduceMotion))
                .animation(TourPressFeel.animation(pressed: pressed, reduceMotion: reduceMotion), value: pressed)
                .animation(reduceMotion ? nil : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.14), value: hovering)
        }
    }
}
