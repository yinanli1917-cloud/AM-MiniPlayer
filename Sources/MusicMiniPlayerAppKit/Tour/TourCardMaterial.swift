/**
 * [INPUT]: SwiftUI, AppKit (NSVisualEffectView), this folder's TourBubbleShape /
 *          TourCardStyle.
 * [OUTPUT]: Exports TourCardMaterialArm (liquid | glass | clear | vibrancy | simulated),
 *           TourCardMaterialModifier (`View.tourCardMaterial`),
 *           TourVibrancyBackground.
 * [POS]: MusicMiniPlayerAppKit/Tour. The card's surface (proposal §4.6):
 *        macOS 26 = real Liquid Glass (`glassEffect`) in ONE bubble shape
 *        (body + beak), macOS 14/15 = `.popover` `NSVisualEffectView` masked
 *        to the same shape. `liquid` (default, 2026-10-05) is plain native
 *        Liquid Glass (`.glassEffect(.regular)`) with nothing drawn on it, and the
 *        card's controls are system styles (see TourCardView); the founder rejected
 *        the hand-drawn rim/sheen of the first liquid version. A non-key window draws
 *        glass without the key window's specular rim and desaturates glass tints;
 *        that is the system's look for a window that never takes focus
 *        (TourCardGlassShotTests records it). `glass` is the same glass with the
 *        old custom buttons and a hairline (`defaults write … NanoPodTourCardMaterial
 *        glass`). `simulated` exists ONLY for offscreen renders (ImageRenderer cannot
 *        draw glass or NSViewRepresentable material):
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

    /// Controls and text are system styles (the other arms keep the card's own palette and button styles).
    var usesSystemControls: Bool { resolved == .liquid }
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
                // One container: the body's glass and the system glass buttons share one sampling region.
                GlassEffectContainer { content.glassEffect(.regular, in: shape) }
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
    /// The dark 0.5pt hairline flattens a glass edge, so the native `liquid` arm leaves it off.
    @ViewBuilder
    func tourCardHairline(_ arm: TourCardMaterialArm, shape: TourBubbleShape, color: Color) -> some View {
        if arm.usesSystemControls { self } else { overlay(shape.stroke(color, lineWidth: 0.5)) }
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
