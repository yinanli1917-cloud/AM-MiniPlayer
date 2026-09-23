/**
 * [INPUT]: EdgeCollapsePoseStore.pose (sampled once per frame) + MusicController.shared.
 * [OUTPUT]: RootContentView v9.
 *   - Card: the real nanoPod MiniPlayerView, real size, 16pt off the edge.
 *   - Tucked: a short edge handle (progress fill) or a cover tab.
 *   - Hover: a drop necks out of the handle, swells round, stretches into
 *     the capsule (cover, title, artist, pause in a progress ring, next);
 *     the handle goes back into the edge. Click: grows into the panel.
 *   - The cover is always clipped to the glass shapes, so it reads as
 *     content inside the liquid, never a separate card flying around.
 * [POS]: Standalone spike root view.
 * [PROTOCOL]: No animation modifiers here. Every value comes from `pose`.
 */

import SwiftUI
import AppKit
import MusicMiniPlayerCore

struct RootContentView: View {
    @ObservedObject var model: EdgeCollapseAppModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassRootView(model: model, store: model.poseStore)
        } else {
            Text("macOS 26 required").frame(width: 320, height: 360)
        }
    }
}

@available(macOS 26.0, *)
private struct GlassRootView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    @ObservedObject var store: EdgeCollapsePoseStore
    @ObservedObject var music = MusicController.shared
    @StateObject private var edgePresentation = EdgePresentationModel()
    @Namespace private var ns

    private var pose: EdgeCollapsePose { store.pose }
    private var container: CGSize { EdgeCollapseTokens.containerSize }

    /// One Glass value for both bodies (same material). The black is the
    /// glass tint itself, per frame, so every neck, drop and blend between
    /// the two bodies is the same black (v9 drew black as a layer on top of
    /// clear glass: the bridges and the drop showed clear glass).
    private var glass: Glass {
        switch model.tint {
        case .none: return .clear.interactive()
        case .black, .gradient: return .clear.tint(Color.black.opacity(clamp01(pose.tint))).interactive()
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            GlassEffectContainer(spacing: EdgeCollapseTokens.containerSpacing) {
                ZStack(alignment: .topLeading) {
                    bodyView.glassEffectID("body", in: ns)
                    capsuleView.glassEffectID("capsule", in: ns)
                }
            }

            panelView
            heroView
        }
        .frame(width: container.width, height: container.height)
        .overlay(Color.black.opacity(model.reduceMotionFlashOpacity * 0.6).allowsHitTesting(false))
    }

    // MARK: - The real nanoPod panel

    private var panelView: some View {
        let r = EdgeCollapsePoses.cardRect
        return PanelLayer(edgePresentation: edgePresentation)
            .equatable()
            .opacity(clamp01(pose.panelOpacity))
            .allowsHitTesting(pose.panelOpacity > 0.9)
            .position(x: r.midX, y: r.midY)
    }

    // MARK: - Edge body: card → 6pt strip

    private var bodyView: some View {
        // The collapse spring tucks the strip past the edge and back; keep
        // the right side on the edge and never draw a negative width.
        let r = bodyRect
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: pose.bodyCornerInner, bottomLeadingRadius: pose.bodyCornerInner,
            bottomTrailingRadius: pose.bodyCornerEdge, topTrailingRadius: pose.bodyCornerEdge,
            style: .continuous)
        return ZStack(alignment: .bottom) {
            // Tucked: pure black (founder 2026-09-22). Only at rest; while the
            // handle bulges and the drop necks out, the tinted glass carries it.
            if pose.stripContentOpacity > 0.01 {
                Color.black.opacity(clamp01(pose.stripContentOpacity))
            }
        }
        .allowsHitTesting(false)
        .frame(width: r.width, height: r.height)
        .clipShape(shape)
        .glassEffect(glass, in: shape)
        .contentShape(shape)
        .onTapGesture { if model.presentation == .tucked { model.requestExpand() } }
        .position(x: r.midX, y: r.midY)
    }

    /// Body rect as drawn. Width never negative; anything past the right
    /// edge is clipped by the window, which is the screen edge.
    private var bodyRect: CGRect {
        let raw = pose.body
        let w = max(raw.width, 0)
        return CGRect(x: raw.maxX - w, y: raw.minY, width: w, height: raw.height)
    }

    // MARK: - Hover capsule

    private var capsuleView: some View {
        let r = pose.capsule
        let t = EdgeCollapseTokens.self
        let shape = RoundedRectangle(cornerRadius: pose.capsuleCorner, style: .continuous)
        return ZStack(alignment: .top) {
            // Edge-side gradient black: part of the capsule's content, it
            // arrives with the text once the shape has settled.
            dimming.opacity(clamp01(pose.dim) * clamp01(pose.capsuleContentOpacity))
            if pose.capsuleContentOpacity > 0.01 {
            VStack(spacing: 0) {
                Color.clear.frame(height: t.capsulePadding + t.capsuleArtwork + 8)
                VStack(spacing: 2) {
                    Text(model.trackTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(music.currentArtist).font(.system(size: 10)).opacity(0.72).lineLimit(1)
                }
                .frame(height: t.capsuleTextHeight)
                .padding(.horizontal, 10)
                Color.clear.frame(height: 4)
                HStack(spacing: 16) { controlButtons(ink: .white) }
                    .frame(height: t.capsuleControlsHeight)
            }
            .foregroundStyle(.white)
            .frame(width: t.capsuleSize.width)
            .blur(radius: pose.capsuleContentBlur > 0.1 ? pose.capsuleContentBlur : 0)
            .opacity(clamp01(pose.capsuleContentOpacity))
            }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0), alignment: .top)
        .clipShape(shape)
        .glassEffect(glass, in: shape)
        .contentShape(shape)
        .onTapGesture { model.requestExpand() }
        .allowsHitTesting(pose.capsuleContentOpacity > 0.5)
        .position(x: r.midX, y: r.midY)
    }

    /// Black at the screen edge, lighter inward (Siri panel look).
    @ViewBuilder
    private var dimming: some View {
        if model.tint == .gradient {
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(EdgeCollapseTokens.edgeDimInnerOpacity), location: 0),
                    .init(color: Color.black.opacity(EdgeCollapseTokens.edgeDimMidOpacity), location: 0.5),
                    .init(color: Color.black.opacity(EdgeCollapseTokens.edgeDimOpacity), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing)
        } else {
            Color.clear
        }
    }

    /// Two buttons of the same visual size (founder 2026-09-22): each sits in
    /// a 36pt ring of the same stroke; pause/play's ring shows progress,
    /// next's ring is the plain track. Glyphs scaled to a matching height
    /// (nanoPod's play glyph is 21pt regular, the skip glyph 13.6pt semibold).
    @ViewBuilder
    private func controlButtons(ink: Color) -> some View {
        let ring: CGFloat = 36, stroke: CGFloat = 2.5
        ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: stroke)
            Circle().trim(from: 0, to: progress)
                .stroke(ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            PlayPauseControlButton(isPlaying: music.isPlaying, inkColor: ink, hoverFill: ink.opacity(0.18)) {
                music.togglePlayPause()
            }
            .scaleEffect(0.72)
        }
        .frame(width: ring, height: ring)
        ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: stroke)
            SkipControlButton(action: { music.nextTrack() }, direction: 1, inkColor: ink, hoverFill: ink.opacity(0.18))
                .scaleEffect(1.08)
        }
        .frame(width: ring, height: ring)
    }

    // MARK: - Cover that flies between panel, capsule and edge

    /// Always mounted (re-creating it at collapse start cost a 49ms frame on
    /// the first run); blur only while visible. Clipped to the box around the
    /// glass shapes with a plain rounded rect (a shape `.mask` forced an
    /// offscreen redraw every frame: 22-38ms frames, sampled). Hero rects are
    /// designed inside the glass; the clip only trims the lyrics-page fill.
    private var heroView: some View {
        let r = pose.hero
        let visible = clamp01(pose.heroOpacity) * (1 - clamp01(pose.panelOpacity))
        let b = bodyRect, c = pose.capsule
        let bodyArea = b.width * b.height, capArea = max(c.width, 0) * max(c.height, 0)
        let box = bodyArea < 1 ? c : capArea < 1 ? b : b.union(c)
        let corner = capArea > bodyArea ? pose.capsuleCorner : pose.bodyCornerInner
        return heroImage(r: CGRect(x: r.minX - box.minX, y: r.minY - box.minY, width: r.width, height: r.height), visible: visible)
            .frame(width: max(box.width, 0), height: max(box.height, 0), alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: max(min(corner, min(box.width, box.height) / 2), 0), style: .continuous))
            .position(x: box.midX, y: box.midY)
            .allowsHitTesting(false)
    }

    private func heroImage(r: CGRect, visible: Double) -> some View {
        Group {
            if let art = music.currentArtwork { Image(nsImage: art).resizable().scaledToFill() } else { Color.gray }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0))
        .clipShape(RoundedRectangle(cornerRadius: max(pose.heroCorner, 0), style: .continuous))
        .blur(radius: visible > 0.005 && pose.heroBlur > 0.1 ? pose.heroBlur : 0)
        .opacity(visible)
        .position(x: r.midX, y: r.midY)
    }

    private var progress: CGFloat {
        guard music.duration > 0 else { return 0 }
        return CGFloat(min(max(music.currentTime / music.duration, 0), 1))
    }

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// The real panel, isolated so per-frame pose changes never re-evaluate it.
@available(macOS 26.0, *)
private struct PanelLayer: View, Equatable {
    let edgePresentation: EdgePresentationModel
    nonisolated static func == (a: PanelLayer, b: PanelLayer) -> Bool { a.edgePresentation === b.edgePresentation }

    var body: some View {
        let r = EdgeCollapsePoses.cardRect
        MiniPlayerView()
            .environmentObject(MusicController.shared)
            .environmentObject(edgePresentation)
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: EdgeCollapseTokens.cardCornerRadius, style: .continuous))
    }
}
