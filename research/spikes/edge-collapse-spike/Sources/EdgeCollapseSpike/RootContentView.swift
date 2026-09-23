/**
 * [INPUT]: EdgeCollapsePoseStore.pose (sampled once per frame) + MusicController.shared.
 * [OUTPUT]: RootContentView v8.
 *   - Card: the real nanoPod MiniPlayerView (fullscreen-cover mode).
 *   - Tucked: the app's own edge footprint, a 6pt strip at full panel
 *     height; it shows playback progress as a fill from the bottom.
 *   - Hover: a vertical capsule buds out of the strip (two glass bodies in
 *     one container, separate at rest, blended while close) with cover,
 *     title, artist, pause/play inside a progress ring, and next.
 *   - Click the capsule or the strip: grows back into the real panel.
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

    /// One Glass value for both bodies (same material).
    private var glass: Glass {
        switch model.tint {
        case .black: return .clear.tint(Color.black.opacity(EdgeCollapseTokens.tintOpacity)).interactive()
        case .none, .gradient: return .clear.interactive()
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
        let raw = pose.body
        let w = max(raw.width, 0)
        let r = CGRect(x: min(raw.minX, container.width - w), y: raw.minY, width: w, height: raw.height)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: pose.bodyCornerInner, bottomLeadingRadius: pose.bodyCornerInner,
            bottomTrailingRadius: pose.bodyCornerEdge, topTrailingRadius: pose.bodyCornerEdge,
            style: .continuous)
        return ZStack(alignment: .bottom) {
            dimming.opacity(clamp01(pose.dim))
            // Progress: played part fills from the bottom.
            if pose.stripContentOpacity > 0.01 {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(height: r.height * progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(clamp01(pose.stripContentOpacity))
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

    // MARK: - Hover capsule

    private var capsuleView: some View {
        let r = pose.capsule
        let t = EdgeCollapseTokens.self
        let shape = RoundedRectangle(cornerRadius: pose.capsuleCorner, style: .continuous)
        return ZStack(alignment: .top) {
            dimming.opacity(clamp01(pose.dim))
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
                HStack(spacing: 14) { controlButtons(ink: .white) }
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

    /// Two buttons: pause/play inside a progress ring (Apple Watch Now
    /// Playing), and next. Both are nanoPod's own buttons.
    @ViewBuilder
    private func controlButtons(ink: Color) -> some View {
        ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress)
                .stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            PlayPauseControlButton(isPlaying: music.isPlaying, inkColor: ink, hoverFill: ink.opacity(0.18)) {
                music.togglePlayPause()
            }
            .frame(width: 28, height: 28)
        }
        .frame(width: 36, height: 36)
        SkipControlButton(action: { music.nextTrack() }, direction: 1, inkColor: ink, hoverFill: ink.opacity(0.18))
            .frame(width: 28, height: 28)
    }

    // MARK: - Cover that flies between panel, capsule and edge

    /// Always mounted (re-creating it at collapse start cost a 49ms frame on
    /// the first run); blur only while it is visible and non-zero.
    private var heroView: some View {
        let r = pose.hero
        let visible = clamp01(pose.heroOpacity) * (1 - clamp01(pose.panelOpacity))
        return Group {
            if let art = music.currentArtwork { Image(nsImage: art).resizable().scaledToFill() } else { Color.gray }
        }
        .frame(width: max(r.width, 0), height: max(r.height, 0))
        .clipShape(RoundedRectangle(cornerRadius: max(pose.heroCorner, 0), style: .continuous))
        .blur(radius: visible > 0.005 && pose.heroBlur > 0.1 ? pose.heroBlur : 0)
        .opacity(visible)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
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
