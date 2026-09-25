import SwiftUI
import AppKit

// =============================================================================
// [INPUT]: FluidGradientBackground (fluid arm), AppKit NSGlassEffectView
//          (glass + clear arms, macOS 26), NSImage.dominantColor() for the tint
// [OUTPUT]: PanelBackdropStyle (defaults-driven switch), PanelBackdrop (the
//           single mount point for the panel's base background)
// [POS]: Backdrop-cost experiment. The glass arm revives the pre-b9b6657
//        translucent panel (LiquidBackgroundView, deprecated for overexposure)
//        on the native Tahoe glass API instead of stacked NSVisualEffectViews.
//        The clear arm is the founder-requested real Liquid Glass "Clear"
//        style — desktop shows through the panel with a single solid tint on
//        top, replacing the artwork-derived fluid gradient.
//        Switch at runtime via nanopod://debug/backdrop/<style>; default stays
//        fluid so the shipping look is unchanged until the user opts in.
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
}

/// Where the backdrop is mounted. The panel base always renders a material;
/// page overlays (playlist) render nothing in the glass arm so the base glass
/// shows through instead of stacking a second material on top of it.
public enum PanelBackdropRole {
    case base
    case pageOverlay
}

public struct PanelBackdrop: View {
    let artwork: NSImage?
    let role: PanelBackdropRole

    @AppStorage(PanelBackdropStyle.defaultsKey)
    private var rawStyle: String = PanelBackdropStyle.fluid.rawValue

    // C1 commit 2 (research/c1-edge-morph-design-2026-09-12.md §2): the
    // EdgePresentationModel is injected as an environment object next to
    // musicController in MusicMiniPlayerApp.swift, above PanelBackdrop in the
    // hierarchy — verified: MiniPlayerView.mainBody mounts PanelBackdrop
    // inside the same content tree that receives `.environmentObject(edgePresentationModel)`.
    @EnvironmentObject private var edgePresentation: EdgePresentationModel

    public init(artwork: NSImage?, role: PanelBackdropRole = .base) {
        self.artwork = artwork
        self.role = role
    }

    public var body: some View {
        if role == .base, EdgeMorphHost.baseBackdropHidden(presentation: edgePresentation.presentation, arm: MicroInteractionFeel.edgeMorph) {
            // Exactly one material at a time (design §2): while the pill
            // carries the glass, the base backdrop mirrors the existing
            // `.pageOverlay` Color.clear precedent below.
            Color.clear
        } else {
            switch PanelBackdropStyle.resolve(from: rawStyle) {
            case .fluid:
                FluidGradientBackground(artwork: artwork)
            case .glass:
                if #available(macOS 26.0, *) {
                    switch role {
                    case .base:
                        GlassBackdropView(artwork: artwork, glassStyle: .regular)
                    case .pageOverlay:
                        Color.clear
                    }
                } else {
                    FluidGradientBackground(artwork: artwork)
                }
            case .clear:
                if #available(macOS 26.0, *) {
                    switch role {
                    case .base:
                        GlassBackdropView(artwork: artwork, glassStyle: .clear)
                    case .pageOverlay:
                        Color.clear
                    }
                } else {
                    FluidGradientBackground(artwork: artwork)
                }
            }
        }
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
