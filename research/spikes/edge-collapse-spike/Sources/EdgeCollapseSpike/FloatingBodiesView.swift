/**
 * [INPUT]: EdgeCollapseAppModel (variant, tint, floatingSeparation/Offset/
 *          Overshoot, artworkDotOpacity, floatingControlsOpacity, heroLocation)
 * [OUTPUT]: FloatingBodiesView — the settled `.floating` state: two Liquid
 *           Glass bodies (info + control) in ONE GlassEffectContainer, design
 *           §6 + top-level task instruction #6.
 * [POS]: Standalone spike content view for design §2/§3 `floating`.
 * [PROTOCOL]: No glass-on-glass (content inside each body never itself calls
 *             `.glassEffect`); every glass shape explicit (Capsule/
 *             RoundedRectangle) with aspect ≥3:1 or corner ≤ half short side —
 *             design §3.
 */

import SwiftUI

struct FloatingBodiesView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    var heroNS: Namespace.ID
    @Namespace private var glassNS

    var body: some View {
        ZStack(alignment: .trailing) {
            // Transparent hit-region fill — the window
            // (EdgeCollapseTokens.floatingWindowSizeH/V) is already larger
            // than the bodies, giving the "union expanded by 12pt" hover-exit
            // target design §6 asks for.
            Color.clear

            bodies
                .offset(x: -model.floatingBodyOffset)
                .scaleEffect(model.floatingOvershootScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !hovering, model.presentation == .floating else { return }
            model.requestHoverExit()
        }
    }

    @ViewBuilder private var bodies: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: EdgeCollapseTokens.floatingBodyEdgeGap) {
                if model.variant == .h {
                    horizontalBodies
                } else {
                    verticalBodies
                }
            }
        } else {
            // Pre-macOS 26: GlassEffectContainer/.glassEffect are unavailable.
            // Solid dark fallback — never a private API stand-in for glass.
            if model.variant == .h {
                horizontalBodiesFallback
            } else {
                verticalBodiesFallback
            }
        }
    }

    // MARK: - Variant H (design §6): info bar above, control body below, edge-aligned

    @available(macOS 26.0, *)
    @ViewBuilder private var horizontalBodies: some View {
        VStack(alignment: .trailing, spacing: model.floatingSeparation) {
            infoBarContentH
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .glassEffectID("info", in: glassNS)
                .overlay(edgeTint(in: Capsule(style: .continuous)))
                .contentShape(Capsule(style: .continuous))
                .onTapGesture { model.requestExpand() }

            controlContentH
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .glassEffectID("control", in: glassNS)
                .overlay(edgeTint(in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { model.toggleIsPlaying() }
        }
    }

    @ViewBuilder private var horizontalBodiesFallback: some View {
        VStack(alignment: .trailing, spacing: model.floatingSeparation) {
            infoBarContentH
                .background(Color.black.opacity(0.6), in: Capsule(style: .continuous))
                .overlay(edgeTint(in: Capsule(style: .continuous)))
                .contentShape(Capsule(style: .continuous))
                .onTapGesture { model.requestExpand() }

            controlContentH
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(edgeTint(in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { model.toggleIsPlaying() }
        }
    }

    @ViewBuilder private var infoBarContentH: some View {
        HStack(spacing: 8) {
            ZStack {
                if model.heroLocation == .floatingBody {
                    HeroArtworkView(size: 24, cornerRadius: 12)
                        .clipShape(Circle())
                        .matchedGeometryEffect(id: "hero", in: heroNS)
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
            }

            Text(model.trackTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .opacity(model.artworkDotOpacity)
        .padding(.horizontal, 10)
        .frame(height: 32)
        // minWidth keeps the capsule at or above the 3:1 aspect-ratio floor
        // (design §3) even when the track title is short (e.g. a 4-character
        // CJK title) — never let content size alone decide the shape's aspect.
        .frame(minWidth: 100, maxWidth: 180, alignment: .trailing)
    }

    @ViewBuilder private var controlContentH: some View {
        HStack(spacing: 14) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "forward.fill")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(width: 64, height: 28)
        .opacity(model.floatingControlsOpacity)
    }

    // MARK: - Variant V (design §6): artwork drop above, control body below, both hugging the edge, no title

    @available(macOS 26.0, *)
    @ViewBuilder private var verticalBodies: some View {
        VStack(spacing: model.floatingSeparation) {
            // §3's "aspect ≥3:1 OR explicit RoundedRectangle" rule targets
            // accidental near-square Capsules; a genuine 1:1 round drop is
            // drawn with `Circle()` instead, whose corner radius is BY
            // DEFINITION exactly half the short side — the rule's other
            // clause, satisfied exactly rather than by accident.
            infoDropContentV
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("info", in: glassNS)
                .overlay(edgeTint(in: Circle()))
                .contentShape(Circle())
                .onTapGesture { model.requestExpand() }

            controlContentV
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .glassEffectID("control", in: glassNS)
                .overlay(edgeTint(in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { model.toggleIsPlaying() }
        }
    }

    @ViewBuilder private var verticalBodiesFallback: some View {
        VStack(spacing: model.floatingSeparation) {
            infoDropContentV
                .background(Color.black.opacity(0.6), in: Circle())
                .overlay(edgeTint(in: Circle()))
                .contentShape(Circle())
                .onTapGesture { model.requestExpand() }

            controlContentV
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(edgeTint(in: RoundedRectangle(cornerRadius: 14, style: .continuous)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { model.toggleIsPlaying() }
        }
    }

    @ViewBuilder private var infoDropContentV: some View {
        ZStack {
            if model.heroLocation == .floatingBody {
                HeroArtworkView(size: 32, cornerRadius: 16)
                    .clipShape(Circle())
                    .matchedGeometryEffect(id: "hero", in: heroNS)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
        .opacity(model.artworkDotOpacity)
        .frame(width: 32, height: 32)
    }

    @ViewBuilder private var controlContentV: some View {
        VStack(spacing: 10) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "forward.fill")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .frame(width: 28, height: 64)
        .opacity(model.floatingControlsOpacity)
    }

    // MARK: - Tint overlay (design §6: black→clear gradient, edge side black; or flat black)

    @ViewBuilder
    private func edgeTint<S: Shape>(in shape: S) -> some View {
        Group {
            switch model.tint {
            case .gradient:
                LinearGradient(
                    colors: [Color.black.opacity(0.82), Color.black.opacity(0)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            case .black:
                Color.black.opacity(0.55)
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}
