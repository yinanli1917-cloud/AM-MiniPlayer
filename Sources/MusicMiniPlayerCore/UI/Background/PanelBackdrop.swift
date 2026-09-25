import SwiftUI
import AppKit

// =============================================================================
// [INPUT]: FluidGradientBackground (fluid arm + always the pageOverlay/base
//          layer under glass), AppKit NSGlassEffectView (glass + clear arms,
//          macOS 26), NSImage.dominantColor() for the tint,
//          PageSwitchClockScheduler.animations(...).material (crossfade clock)
// [OUTPUT]: PanelBackdropStyle (defaults-driven switch) + glassOpacity(style:
//           isAlbumPageNonFullscreen:) pure helper, PanelBackdrop (the single
//           mount point for the panel's base background)
// [POS]: Backdrop-cost experiment. The glass arm revives the pre-b9b6657
//        translucent panel (LiquidBackgroundView, deprecated for overexposure)
//        on the native Tahoe glass API instead of stacked NSVisualEffectViews.
//        The clear arm is the founder-requested real Liquid Glass "Clear"
//        style — desktop shows through the panel with a single solid tint on
//        top, replacing the artwork-derived fluid gradient.
//        Switch at runtime via nanopod://debug/backdrop/<style>; default stays
//        fluid so the shipping look is unchanged until the user opts in.
//        Founder 2026-09-25: the glass/clear surface is scoped to the
//        non-fullscreen ALBUM page only — lyrics and playlist keep the plain
//        fluid gradient at every style (the translucent glass would let that
//        fluid layer show through, so the two crossfade: fluid opacity =
//        1 − glassOpacity). MiniPlayerView passes the page condition in as a
//        Bool (`isAlbumPageNonFullscreen`); PanelBackdrop never reads page
//        state itself.
// =============================================================================

public enum PanelBackdropStyle: String, CaseIterable {
    case fluid
    case glass
    case clear

    public static let defaultsKey = "panelBackdropStyle"

    /// Absent or unknown values fall back to the shipping fluid backdrop.
    public static func resolve(from raw: String?) -> PanelBackdropStyle {
        guard let raw else { return .fluid }
        return PanelBackdropStyle(rawValue: raw.lowercased()) ?? .fluid
    }

    /// Pure opacity for the glass surface layered over the base fluid
    /// gradient (founder 2026-09-25: glass/clear apply to the non-fullscreen
    /// album page only). `.fluid` never shows glass. This only decides the
    /// `.base` role's glass layer — `.pageOverlay` (playlist) never mounts a
    /// glass layer at all, at any style, so its opacity question doesn't arise.
    public static func glassOpacity(style: PanelBackdropStyle, isAlbumPageNonFullscreen: Bool) -> Double {
        switch style {
        case .fluid:
            return 0
        case .glass, .clear:
            return isAlbumPageNonFullscreen ? 1 : 0
        }
    }
}

/// Where the backdrop is mounted. The panel base renders the current style
/// (fluid gradient, or fluid + glass crossfade on the non-fullscreen album
/// page); page overlays (playlist) always render the plain fluid gradient,
/// at every style — glass never applies there.
public enum PanelBackdropRole {
    case base
    case pageOverlay
}

public struct PanelBackdrop: View {
    let artwork: NSImage?
    let role: PanelBackdropRole
    /// True only while the panel shows the ALBUM page in non-fullscreen mode
    /// (founder 2026-09-25). Passed in from MiniPlayerView — PanelBackdrop
    /// never reads page/fullscreen state itself. Meaningless for
    /// `.pageOverlay`, which never mounts glass regardless of this value.
    let isAlbumPageNonFullscreen: Bool

    @AppStorage(PanelBackdropStyle.defaultsKey)
    private var rawStyle: String = PanelBackdropStyle.fluid.rawValue

    // C1 commit 2 (research/c1-edge-morph-design-2026-09-12.md §2): the
    // EdgePresentationModel is injected as an environment object next to
    // musicController in MusicMiniPlayerApp.swift, above PanelBackdrop in the
    // hierarchy — verified: MiniPlayerView.mainBody mounts PanelBackdrop
    // inside the same content tree that receives `.environmentObject(edgePresentationModel)`.
    @EnvironmentObject private var edgePresentation: EdgePresentationModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(artwork: NSImage?, role: PanelBackdropRole = .base, isAlbumPageNonFullscreen: Bool = false) {
        self.artwork = artwork
        self.role = role
        self.isAlbumPageNonFullscreen = isAlbumPageNonFullscreen
    }

    public var body: some View {
        if role == .base, EdgeMorphHost.baseBackdropHidden(presentation: edgePresentation.presentation, arm: MicroInteractionFeel.edgeMorph) {
            // Exactly one material at a time (design §2): while the pill
            // carries the glass, the base backdrop mirrors the existing
            // `.pageOverlay` fluid-gradient precedent below (nothing extra
            // to hide — this branch already renders nothing).
            Color.clear
        } else if role == .pageOverlay {
            // Playlist/lyrics keep the plain fluid gradient at every style —
            // founder 2026-09-25 scoped glass/clear to the album page only.
            // This is unconditional (not gated by rawStyle) because it must
            // match the fluid arm's existing overlay-over-base-fluid stack
            // byte-for-byte when the style IS fluid, and simply never grows
            // a glass layer when it isn't.
            FluidGradientBackground(artwork: artwork)
        } else {
            switch PanelBackdropStyle.resolve(from: rawStyle) {
            case .fluid:
                FluidGradientBackground(artwork: artwork)
            case .glass, .clear:
                if #available(macOS 26.0, *) {
                    baseGlassCrossfade(style: PanelBackdropStyle.resolve(from: rawStyle))
                } else {
                    FluidGradientBackground(artwork: artwork)
                }
            }
        }
    }

    /// `.base` role, `.glass`/`.clear` style: the fluid gradient and the
    /// translucent glass surface stacked and crossfaded (fluid opacity
    /// = 1 − glassOpacity) so the fluid layer never shows through the glass
    /// on the album page, and the glass never floats over nothing when the
    /// page/fullscreen condition takes it away. Animated with the same clock
    /// MiniPlayerView uses for the page-switch material crossfade, so
    /// switching album↔lyrics/playlist crossfades instead of popping.
    @available(macOS 26.0, *)
    private func baseGlassCrossfade(style: PanelBackdropStyle) -> some View {
        let glassOpacity = PanelBackdropStyle.glassOpacity(style: style, isAlbumPageNonFullscreen: isAlbumPageNonFullscreen)
        let glassStyle: NSGlassEffectView.Style = style == .glass ? .regular : .clear
        let materialAnimation = PageSwitchClockScheduler.animations(
            arm: MicroInteractionFeel.pageSwitch,
            reduceMotion: reduceMotion
        ).material
        return ZStack {
            FluidGradientBackground(artwork: artwork)
                .opacity(1 - glassOpacity)
            GlassBackdropView(artwork: artwork, glassStyle: glassStyle)
                .opacity(glassOpacity)
        }
        .animation(materialAnimation, value: glassOpacity)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Native glass arm (macOS 26)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Tint alpha for the tuned glass arms (`.regular` and `.clear`). Same value
/// for both today; tune here if the two styles need to diverge.
private let panelGlassTintAlpha: CGFloat = 0.35

@available(macOS 26.0, *)
private struct GlassBackdropView: View {
    let artwork: NSImage?
    var glassStyle: NSGlassEffectView.Style
    @State private var tint: NSColor?
    @State private var tintedArtworkHash: Int = 0

    var body: some View {
        NativeGlassSurface(tint: tint, glassStyle: glassStyle)
            .onAppear { updateTint() }
            .onChange(of: artwork) { updateTint() }
    }

    private func updateTint() {
        guard let artwork else {
            tint = nil
            tintedArtworkHash = 0
            return
        }
        let hash = artwork.hashValue
        guard hash != tintedArtworkHash else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let dominant = artwork.dominantColor()
            DispatchQueue.main.async {
                tintedArtworkHash = hash
                tint = dominant?.withAlphaComponent(panelGlassTintAlpha)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct NativeGlassSurface: NSViewRepresentable {
    var tint: NSColor?
    var glassStyle: NSGlassEffectView.Style

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = 16
        view.style = glassStyle
        view.tintColor = tint
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.style = glassStyle
        view.tintColor = tint
    }
}
