/**
 * [INPUT]: SwiftUI, AppKit (NSVisualEffectView), this folder's TourBubbleShape /
 *          TourCardStyle.
 * [OUTPUT]: Exports TourCardMaterialArm (liquid | glass | clear | vibrancy | simulated),
 *           TourGlassFinish (rim/sheen numbers per appearance),
 *           TourCardMaterialModifier (`View.tourCardMaterial`),
 *           TourVibrancyBackground.
 * [POS]: MusicMiniPlayerAppKit/Tour. The card's surface (proposal §4.6):
 *        macOS 26 = real Liquid Glass (`glassEffect`) in ONE bubble shape
 *        (body + beak), macOS 14/15 = `.popover` `NSVisualEffectView` masked
 *        to the same shape. `liquid` (default, 2026-10-04) is `glass` plus what
 *        makes system glass read as glass: a thin specular rim around the whole
 *        outline (brightest along the top), a soft top sheen, and glass buttons
 *        (see TourCardStyle) inside ONE `GlassEffectContainer`; nothing opaque
 *        sits between the glass and the wallpaper. `glass` is the plain
 *        previous look (`defaults write … NanoPodTourCardMaterial glass`). `simulated` exists ONLY for offscreen renders
 *        (ImageRenderer cannot draw glass or NSViewRepresentable material):
 *        it paints the storyboard's translucent fill so the card's CONTENT
 *        can be reviewed on light/dark desktops. It is never selected in the
 *        shipping app. `vibrancy` is also the live A/B fallback if glass looks
 *        wrong on a given Mac: `defaults write com.yinanli.nanoPod
 *        NanoPodTourCardMaterial vibrancy` (or nanopod://debug/tour/material/
 *        <arm>).
 */

import SwiftUI
import AppKit

enum TourCardMaterialArm: String, CaseIterable {
    case liquid, glass, clear, vibrancy, simulated

    static let defaultsKey = "NanoPodTourCardMaterial"

    /// Absent/unknown -> liquid. `simulated` can never come from defaults.
    static func current(_ defaults: UserDefaults = .standard) -> TourCardMaterialArm {
        guard let raw = defaults.string(forKey: defaultsKey),
              let arm = TourCardMaterialArm(rawValue: raw.lowercased()), arm != .simulated else { return .liquid }
        return arm
    }

    /// Glass arms need macOS 26; older systems always use vibrancy.
    var resolved: TourCardMaterialArm {
        if #available(macOS 26.0, *) { return self }
        return self == .simulated ? .simulated : .vibrancy
    }

    /// Non-glass arms need the window's own shadow (glass draws its own).
    var needsWindowShadow: Bool { resolved == .vibrancy }

    /// Buttons are glass capsules (and the card's glass shapes share one container).
    var usesGlassButtons: Bool { resolved == .liquid }
}

/// The `liquid` arm's finish, per appearance: a ~1pt specular rim (a vertical
/// gradient, brightest at the top edge, fading down the sides, faint at the
/// bottom) and a white sheen that is gone by `sheenReach` of the height.
/// Numbers tuned against composited window shots (TourCardGlassShotTests),
/// pinned in the tests so a tweak is a deliberate edit.
struct TourGlassFinish: Equatable {
    /// Rim opacity at the top edge, at 30 % and 65 % of the height, and at the bottom.
    var rimTop: Double
    var rimUpper: Double
    var rimLower: Double
    var rimBottom: Double
    var sheenOpacity: Double
    var sheenReach: Double

    /// Opacity of the accent wash over the primary button's glass (both appearances).
    static let accentWash: Double = 0.9

    static func resolve(dark: Bool) -> TourGlassFinish { dark ? .dark : .light }

    static let light = TourGlassFinish(rimTop: 0.95, rimUpper: 0.55, rimLower: 0.35, rimBottom: 0.30, sheenOpacity: 0.32, sheenReach: 0.40)
    static let dark = TourGlassFinish(rimTop: 0.80, rimUpper: 0.40, rimLower: 0.18, rimBottom: 0.14, sheenOpacity: 0.10, sheenReach: 0.40)

    var rimGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(rimTop), location: 0),
            .init(color: .white.opacity(rimUpper), location: 0.30),
            .init(color: .white.opacity(rimLower), location: 0.65),
            .init(color: .white.opacity(rimBottom), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    var sheenGradient: LinearGradient {
        LinearGradient(stops: [
            .init(color: .white.opacity(sheenOpacity), location: 0),
            .init(color: .white.opacity(0), location: sheenReach),
        ], startPoint: .top, endPoint: .bottom)
    }
}

struct TourCardMaterialModifier: ViewModifier {
    var arm: TourCardMaterialArm
    var shape: TourBubbleShape
    var dark: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch arm.resolved {
        case .liquid:
            if #available(macOS 26.0, *) {
                // Rim + sheen are the content's own background, so they land ABOVE the glass (which
                // `glassEffect` puts behind everything it wraps) and below the text. The container
                // gives the body glass and the buttons' glass one shared sampling region.
                let finish = TourGlassFinish.resolve(dark: dark)
                GlassEffectContainer {
                    content
                        .background {
                            ZStack {
                                shape.fill(finish.sheenGradient)
                                // 2pt stroke clipped to the shape = a 1pt rim hugging the inside of the outline.
                                shape.stroke(finish.rimGradient, lineWidth: 2).clipShape(shape)
                            }
                            .allowsHitTesting(false)
                        }
                        .glassEffect(.regular, in: shape)
                }
            } else {
                content.background(TourVibrancyBackground(shape: shape))
            }
        case .glass:
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(TourVibrancyBackground(shape: shape))
            }
        case .clear:
            if #available(macOS 26.0, *) {
                content.glassEffect(.clear, in: shape)
            } else {
                content.background(TourVibrancyBackground(shape: shape))
            }
        case .vibrancy:
            content.background(TourVibrancyBackground(shape: shape))
        case .simulated:
            // Storyboard `--mock-card-bg`: rgba(255,255,255,.66) / rgba(34,32,40,.58).
            content.background(shape.fill(dark ? Color(.sRGB, red: 34 / 255, green: 32 / 255, blue: 40 / 255, opacity: 0.58)
                                                : Color.white.opacity(0.66)))
        }
    }
}

extension View {
    /// The dark 0.5pt hairline flattens a glass edge, so the `liquid` arm (which has its own rim) leaves it off.
    @ViewBuilder
    func tourCardHairline(_ arm: TourCardMaterialArm, shape: TourBubbleShape, color: Color) -> some View {
        if arm.usesGlassButtons { self } else { overlay(shape.stroke(color, lineWidth: 0.5)) }
    }

    func tourCardMaterial(_ arm: TourCardMaterialArm, shape: TourBubbleShape, dark: Bool) -> some View {
        modifier(TourCardMaterialModifier(arm: arm, shape: shape, dark: dark))
    }
}

/// `.popover` material masked to the bubble. The mask is rebuilt in `layout()`
/// so it always matches the real size (the first version built it in
/// `updateNSView`, when bounds were still zero, leaving an unmasked slab).
struct TourVibrancyBackground: NSViewRepresentable {
    var shape: TourBubbleShape

    func makeNSView(context: Context) -> TourVibrancyView {
        let view = TourVibrancyView()
        view.shape = shape
        return view
    }

    func updateNSView(_ view: TourVibrancyView, context: Context) {
        if view.shape != shape { view.shape = shape }
    }
}

final class TourVibrancyView: NSVisualEffectView {
    var shape = TourBubbleShape(beakSide: .left, beakOffset: 40) {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let path = shape.path(in: CGRect(origin: .zero, size: size)).cgPath
        maskImage = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: path).fill()
            return true
        }
        // The window shadow is computed from the window's opaque pixels; after
        // a re-mask it must follow the (new) bubble, not the old silhouette.
        DispatchQueue.main.async { [weak self] in self?.window?.invalidateShadow() }
    }
}
