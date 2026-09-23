/**
 * [INPUT]: EdgeCollapsePoseStore.pose (sampled once per frame) + MusicController.shared.
 * [OUTPUT]: RootContentView v11 — ONE liquid outline (LiquidShape): pure black
 *   at the edge (plain fill, no glass), glass fades in only as it becomes the
 *   capsule or the card. v9/v10 below kept for history:
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

    private var pose: EdgeCollapsePose { store.pose }
    private var container: CGSize { EdgeCollapseTokens.containerSize }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            liquidView
            panelView
            heroView
            capsuleContentView
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

    // MARK: - The one liquid object

    /// Edge body + capsule as one outline. A body flush with the screen edge
    /// is extended past it, so it has no right-hand corners or rim: at the
    /// edge it is continuous with the black bezel.
    private var parts: [LiquidPart] {
        var b = pose.body
        if b.width > 0.5, b.maxX >= container.width - 0.5 {
            b.size.width += pose.bodyCornerInner + 4
        }
        return [LiquidPart(rect: b, radius: pose.bodyCornerInner),
                LiquidPart(rect: pose.capsule, radius: pose.capsuleCorner)]
    }

    private var shape: LiquidShape { LiquidShape(parts: parts, neck: EdgeCollapseTokens.liquidNeck) }

    /// Black while it is at the edge (a plain fill: no glass, no rim, no
    /// highlight); glass fades in underneath only as it becomes the capsule
    /// or the card, and the black thins into the edge-side gradient
    /// (Siri panel look). One outline carries both, so they never separate.
    private var liquidView: some View {
        let g = clamp01(pose.glass)
        let s = shape
        let box = parts.filter { $0.rect.width >= 1 && $0.rect.height >= 1 }.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        let x0 = box.isNull ? 0 : box.minX / container.width
        let x1 = box.isNull ? 1 : min(box.maxX, container.width) / container.width
        return ZStack {
            if g > 0.01 {
                Color.clear
                    .glassEffect(.clear, in: s)
                    .opacity(g)
            }
            s.fill(LinearGradient(stops: fillStops(g),
                                  startPoint: UnitPoint(x: x0, y: 0.5), endPoint: UnitPoint(x: x1, y: 0.5)))
        }
        .frame(width: container.width, height: container.height)
        .contentShape(s)
        .onTapGesture {
            if model.presentation == .tucked || model.presentation == .floating { model.requestExpand() }
        }
    }

    private func fillStops(_ g: Double) -> [Gradient.Stop] {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * g }
        let t = EdgeCollapseTokens.self
        let (inner, mid, edge): (Double, Double, Double)
        switch model.tint {
        case .gradient: (inner, mid, edge) = (lerp(1, t.edgeDimInnerOpacity), lerp(1, t.edgeDimMidOpacity), lerp(1, t.edgeDimOpacity))
        case .black: (inner, mid, edge) = (lerp(1, 0.55), lerp(1, 0.55), lerp(1, 0.55))
        case .none: (inner, mid, edge) = (lerp(1, 0), lerp(1, 0), lerp(1, 0))
        }
        return [.init(color: .black.opacity(inner), location: 0),
                .init(color: .black.opacity(mid), location: 0.5),
                .init(color: .black.opacity(edge), location: 1)]
    }

    // MARK: - Capsule content (title, artist, two buttons)

    private var capsuleContentView: some View {
        let r = pose.capsule
        let t = EdgeCollapseTokens.self
        return ZStack(alignment: .top) {
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
        .clipShape(RoundedRectangle(cornerRadius: max(pose.capsuleCorner, 0), style: .continuous))
        .allowsHitTesting(pose.capsuleContentOpacity > 0.5)
        .position(x: r.midX, y: r.midY)
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
        let b = CGRect(x: pose.body.maxX - max(pose.body.width, 0), y: pose.body.minY, width: max(pose.body.width, 0), height: pose.body.height)
        let c = pose.capsule
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
