/**
 * [INPUT]: EdgeCollapseAppModel (presentation + variant/tint/bounce/tempo/
 *          isPlaying/trackIndex/fakeProgress/reduceMotionFlashOpacity)
 * [OUTPUT]: RootContentView — the panel's whole SwiftUI tree, rewritten per
 *           AUDIT-2026-09-20.md's "correct approach" (§ Correct approach for
 *           macOS 26 public API) and top-level task instruction #1: ONE
 *           `GlassEffectContainer` inside ONE `@Namespace`, hosting the
 *           `body` (card/tucked/floating-info) and `control` (floating-only)
 *           shapes as stable `glassEffectID`s that persist across states —
 *           never a structurally different view type swapped in per state
 *           (that was v1's bug, audited §2/§4).
 * [POS]: Standalone spike root view.
 * [PROTOCOL]: `body`'s glass shape is a SINGLE persistently-mounted view
 *             across every `EdgePresentation` — its `RoundedRectangle`
 *             corner radius and `.frame` size are the only things that
 *             change (never its concrete `Shape` TYPE, never conditionally
 *             mounted/unmounted). See README "shape identity" for why: a
 *             capsule IS `RoundedRectangle(cornerRadius: height/2)` (Apple's
 *             own `DefaultGlassEffectShape` docs), so every shape this
 *             design needs (card/tucked/floating-H-bar/floating-V-drop) is
 *             expressible as one `RoundedRectangle` with an animated corner
 *             radius — sidestepping any uncertainty about whether the glass
 *             system morphs between two DIFFERENT concrete `Shape` types
 *             under one `glassEffectID` (undocumented; the mechanism this
 *             file relies on instead — one persistent view, animated frame/
 *             cornerRadius — is exactly what glass-morph-spike's scenario 2
 *             already measured MORPH=yes on, 23 continuous frame-steps, see
 *             research/spikes/glass-morph-spike/results/summary.md).
 */

import SwiftUI

struct RootContentView: View {
    @ObservedObject var model: EdgeCollapseAppModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassRootView(model: model)
        } else {
            LegacyFallbackView(model: model)
        }
    }
}

// MARK: - macOS 26 Liquid Glass tree

@available(macOS 26.0, *)
private struct GlassRootView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    @Namespace private var ns

    private enum HeroLocation { case page, floatingBody, none }

    private var visualLayout: EdgeCollapseLayout.VisualLayout {
        EdgeCollapseLayout.visualLayout(for: model.presentation)
    }

    private var titleWidth: CGFloat {
        EdgeCollapseLayout.estimatedTitleWidth(model.trackTitle)
    }

    private var frames: EdgeCollapseLayout.Frames {
        EdgeCollapseLayout.rects(for: model.presentation, variant: model.variant, titleWidth: titleWidth)
    }

    private var bodyCornerRadius: CGFloat {
        switch visualLayout {
        case .card:
            return EdgeCollapseTokens.cardCornerRadius
        case .tucked:
            // Capsule == RoundedRectangle(cornerRadius: height/2) — see file header.
            return frames.body.height / 2
        case .floating:
            switch model.variant {
            case .h: return frames.body.height / 2 // capsule bar
            case .v: return EdgeCollapseTokens.floatingDropCornerRadiusV
            }
        }
    }

    private var heroLocation: HeroLocation {
        switch visualLayout {
        case .card: return .page
        case .tucked: return .none
        case .floating: return .floatingBody
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            GlassEffectContainer(spacing: EdgeCollapseTokens.containerSpacing) {
                ZStack(alignment: .topLeading) {
                    bodyShape
                        .glassEffectID("body", in: ns)
                        .glassEffectTransition(.matchedGeometry)

                    if visualLayout == .floating {
                        controlShape
                            .glassEffectID("control", in: ns)
                            .glassEffectTransition(.matchedGeometry)
                    }
                }
            }

            // Hero lives OUTSIDE the container/clip stack so a floating<->card
            // flight is never cut by either host's own clipShape mid-transit
            // — see file header + top-level task instruction #1's hero bullet.
            heroOverlay
        }
        .frame(width: EdgeCollapseTokens.containerSize.width, height: EdgeCollapseTokens.containerSize.height)
        .overlay(reduceMotionFlash)
    }

    // MARK: - Body (glassEffectID "body")

    private var bodyShape: some View {
        let rect = frames.body
        return RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous)
            .fill(.clear)
            .frame(width: rect.width, height: rect.height)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous))
            .overlay(bodyContent(rect: rect))
            .overlay(tintOverlay(cornerRadius: bodyCornerRadius, size: rect.size))
            .position(x: rect.midX, y: rect.midY)
            .contentShape(RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous))
            .onTapGesture {
                guard visualLayout != .card else { return }
                model.requestExpand()
            }
    }

    /// All three states' content layers stay MOUNTED simultaneously and
    /// cross-fade via opacity (never a conditional `if`/`switch` swap) so
    /// the card's fluid gradient genuinely "fades out during collapse"
    /// (top-level task instruction #1) instead of popping away the instant
    /// the state enum changes.
    @ViewBuilder
    private func bodyContent(rect: CGRect) -> some View {
        ZStack {
            cardFluidContent
                .opacity(visualLayout == .card ? 1 : 0)
            tuckedProgressContent
                .opacity(visualLayout == .tucked ? 1 : 0)
            if model.variant == .h {
                floatingInfoContent
                    .opacity(visualLayout == .floating ? 1 : 0)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }

    private var cardFluidContent: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.10, blue: 0.28),
                    Color(red: 0.45, green: 0.18, blue: 0.22),
                    Color(red: 0.62, green: 0.36, blue: 0.20),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 16) {
                Spacer(minLength: 132) // clears the 200pt hero overlay above
                Text(model.trackTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 214)

                HStack(spacing: 30) {
                    Button(action: { model.toggleIsPlaying() }) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Button(action: { model.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(.white)

                Spacer(minLength: 12)
            }
        }
    }

    private var tuckedProgressContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Rectangle()
                .fill(Color.white.opacity(0.32))
                .frame(height: EdgeCollapseTokens.tuckedSize.height * model.fakeProgress)
        }
    }

    private var floatingInfoContent: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 34) // room for the hero overlay's artwork dot
            Text(model.trackTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
    }

    // MARK: - Control (glassEffectID "control", floating-only)

    @ViewBuilder
    private var controlShape: some View {
        if let rect = frames.control {
            RoundedRectangle(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, style: .continuous)
                .fill(.clear)
                .frame(width: rect.width, height: rect.height)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, style: .continuous))
                .overlay(controlContent)
                .overlay(tintOverlay(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, size: rect.size))
                .position(x: rect.midX, y: rect.midY)
                .contentShape(RoundedRectangle(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, style: .continuous))
                .onTapGesture { model.toggleIsPlaying() }
                .transition(.opacity)
        }
    }

    private var controlContent: some View {
        Group {
            if model.variant == .h {
                HStack(spacing: 14) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "forward.fill").font(.system(size: 12, weight: .semibold))
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "forward.fill").font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    // MARK: - Hero (matchedGeometryEffect, top-level task instruction #1)

    @ViewBuilder
    private var heroOverlay: some View {
        switch heroLocation {
        case .page:
            HeroArtworkView(size: 200, cornerRadius: 28)
                .matchedGeometryEffect(id: "hero", in: ns)
                .position(x: frames.body.midX, y: frames.body.minY + 24 + 100)
                .transition(.opacity)
        case .floatingBody:
            let size: CGFloat = model.variant == .h ? 24 : 26
            HeroArtworkView(size: size, cornerRadius: size / 2)
                .clipShape(Circle())
                .matchedGeometryEffect(id: "hero", in: ns)
                .position(heroFloatingCenter(size: size))
                .transition(.opacity)
        case .none:
            EmptyView()
        }
    }

    private func heroFloatingCenter(size: CGFloat) -> CGPoint {
        let rect = frames.body
        switch model.variant {
        case .h:
            return CGPoint(x: rect.minX + 10 + size / 2, y: rect.midY)
        case .v:
            return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    // MARK: - Tint overlay (top-level task instruction #1)

    @ViewBuilder
    private func tintOverlay(cornerRadius: CGFloat, size: CGSize) -> some View {
        let inset = EdgeCollapseTokens.tintInset
        Group {
            switch model.tint {
            case .gradient:
                LinearGradient(
                    colors: [Color.black.opacity(EdgeCollapseTokens.tintOpacity), Color.black.opacity(0)],
                    startPoint: .trailing,
                    endPoint: .leading
                )
            case .black:
                Color.black.opacity(EdgeCollapseTokens.tintOpacity)
            case .none:
                Color.clear
            }
        }
        .frame(width: max(0, size.width - inset * 2), height: max(0, size.height - inset * 2))
        .clipShape(RoundedRectangle(cornerRadius: max(0, cornerRadius - inset), style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: - Reduce Motion crossfade flash (top-level task instruction #5)

    private var reduceMotionFlash: some View {
        Color.black
            .opacity(model.reduceMotionFlashOpacity * 0.6)
            .allowsHitTesting(false)
    }
}

// MARK: - Pre-macOS 26 fallback — solid dark, no private API stand-in for glass.

private struct LegacyFallbackView: View {
    @ObservedObject var model: EdgeCollapseAppModel

    var body: some View {
        let layout = EdgeCollapseLayout.visualLayout(for: model.presentation)
        let frames = EdgeCollapseLayout.rects(
            for: model.presentation,
            variant: model.variant,
            titleWidth: EdgeCollapseLayout.estimatedTitleWidth(model.trackTitle)
        )
        let cornerRadius = layout == .card ? EdgeCollapseTokens.cardCornerRadius : frames.body.height / 2

        return ZStack(alignment: .topLeading) {
            Color.clear
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.85))
                .frame(width: frames.body.width, height: frames.body.height)
                .position(x: frames.body.midX, y: frames.body.midY)
            if let control = frames.control {
                RoundedRectangle(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                    .frame(width: control.width, height: control.height)
                    .position(x: control.midX, y: control.midY)
            }
        }
        .frame(width: EdgeCollapseTokens.containerSize.width, height: EdgeCollapseTokens.containerSize.height)
    }
}
