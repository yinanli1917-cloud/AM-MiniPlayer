import SwiftUI
import AppKit

// =============================================================================
// [INPUT]: FluidGradientBackground (fluid arm), AppKit NSGlassEffectView
//          (glass arm, macOS 26), NSImage.dominantColor() for the tint
// [OUTPUT]: PanelBackdropStyle (defaults-driven switch), PanelBackdrop (the
//           single mount point for the panel's base background)
// [POS]: Backdrop-cost experiment. The glass arm revives the pre-b9b6657
//        translucent panel (LiquidBackgroundView, deprecated for overexposure)
//        on the native Tahoe glass API instead of stacked NSVisualEffectViews.
//        Switch at runtime via nanopod://debug/backdrop/<style>; default stays
//        fluid so the shipping look is unchanged until the user opts in.
// =============================================================================

public enum PanelBackdropStyle: String, CaseIterable {
    case fluid
    case glass

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

    public init(artwork: NSImage?, role: PanelBackdropRole = .base) {
        self.artwork = artwork
        self.role = role
    }

    public var body: some View {
        switch PanelBackdropStyle.resolve(from: rawStyle) {
        case .fluid:
            FluidGradientBackground(artwork: artwork)
        case .glass:
            if #available(macOS 26.0, *) {
                switch role {
                case .base:
                    GlassBackdropView(artwork: artwork)
                case .pageOverlay:
                    Color.clear
                }
            } else {
                FluidGradientBackground(artwork: artwork)
            }
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Native glass arm (macOS 26)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@available(macOS 26.0, *)
private struct GlassBackdropView: View {
    let artwork: NSImage?
    @State private var tint: NSColor?
    @State private var tintedArtworkHash: Int = 0

    var body: some View {
        NativeGlassSurface(tint: tint)
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
                tint = dominant?.withAlphaComponent(0.35)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct NativeGlassSurface: NSViewRepresentable {
    var tint: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = 16
        view.tintColor = tint
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        view.tintColor = tint
    }
}
