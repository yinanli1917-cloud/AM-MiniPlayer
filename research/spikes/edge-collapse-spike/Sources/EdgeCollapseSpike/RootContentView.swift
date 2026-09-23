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
            edgeLight
            liquidView
            panelView
            heroView
            capsuleContentView
        }
        .frame(width: container.width, height: container.height)
        .overlay(Color.black.opacity(model.reduceMotionFlashOpacity * 0.6).allowsHitTesting(false))
    }

    // MARK: - The real nanoPod panel

    /// The real panel never moves or scales: it sits at the card rect and is
    /// seen through the liquid — clipped to the liquid's visible part, so the
    /// liquid growing IS the panel appearing (founder 2026-09-22). A plain
    /// rounded-rect clip (cheap), not a mask of the outline.
    private var panelView: some View {
        let card = EdgeCollapsePoses.cardRect
        let clip = liquidClip
        let atRest = model.presentation == .card && abs(clip.rect.width - card.width) < 0.5
        return PanelLayer(edgePresentation: edgePresentation)
            .equatable()
            .offset(x: card.minX - clip.rect.minX, y: card.minY - clip.rect.minY)
            .frame(width: max(clip.rect.width, 0), height: max(clip.rect.height, 0), alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: max(clip.corner, 0), style: .continuous))
            .shadow(color: .black.opacity(atRest ? 0.35 : 0), radius: 18, y: 8)
            .opacity(clamp01(pose.panelOpacity))
            .allowsHitTesting(atRest && pose.panelOpacity > 0.9)
            .position(x: clip.rect.midX, y: clip.rect.midY)
    }

    /// The larger visible part of the liquid and its corner radius.
    private var liquidClip: (rect: CGRect, corner: CGFloat) {
        let b = CGRect(x: pose.body.maxX - max(pose.body.width, 0), y: pose.body.minY,
                       width: max(pose.body.width, 0), height: pose.body.height)
        let c = pose.capsule
        let bodyArea = b.width * b.height, capArea = max(c.width, 0) * max(c.height, 0)
        if capArea > bodyArea {
            return (c, min(pose.capsuleCorner, min(c.width, c.height) / 2))
        }
        return (b, min(pose.bodyCornerInner, min(b.width, b.height) / 2))
    }

    // MARK: - The one liquid object

    private var parts: [LiquidPart] { EdgeCollapsePoses.liquidParts(pose) }

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
                // Materialize: the glass arrives out of a blur, not just a fade.
                Color.clear
                    .glassEffect(.clear, in: s)
                    .blur(radius: g < 0.98 ? (1 - g) * 8 : 0)
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

    // MARK: - Edge light (tucked)

    /// A soft light along the screen edge in the artwork's colour. The lit
    /// length from the bottom is the playback progress; the rest is a faint
    /// track. Paused = dimmer. Touching it brightens it at once.
    private var edgeLight: some View {
        let t = EdgeCollapseTokens.self
        let len = CGFloat(max(pose.glowLength, 0))
        let boost = store.hoverBoost
        let level = clamp01(pose.glow) * (music.isPlaying ? 1 : 0.55)
        let color = store.glowColor
        let rim = EdgeRimPath(width: t.handleSize.width, height: len, edge: container.width, midY: container.height / 2)
        return ZStack {
            // Soft light: layered strokes of falling opacity (no blur filter).
            rim.stroke(color.opacity(0.10 + 0.10 * boost), style: StrokeStyle(lineWidth: 8 + 4 * boost, lineCap: .round, lineJoin: .round))
            rim.stroke(color.opacity(0.22 + 0.15 * boost), style: StrokeStyle(lineWidth: 4 + 2 * boost, lineCap: .round, lineJoin: .round))
            // Track, then the lit part = playback progress, starting at the
            // bottom where the sliver meets the bezel.
            rim.stroke(color.opacity(0.30), style: StrokeStyle(lineWidth: t.glowCore, lineCap: .round, lineJoin: .round))
            rim.trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: t.glowCore, lineCap: .round, lineJoin: .round))
        }
        .frame(width: container.width, height: container.height)
        .opacity(level)
        .allowsHitTesting(false)
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

    /// Pause/play inside a progress ring; next without a ring. The two glyphs
    /// are scaled to read the same size (founder 2026-09-22).
    @ViewBuilder
    private func controlButtons(ink: Color) -> some View {
        // Ring + pause reads the same size as the next glyph (founder 2026-09-22).
        let ring: CGFloat = 26, stroke: CGFloat = 2
        ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: stroke)
            Circle().trim(from: 0, to: progress)
                .stroke(ink, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            PlayPauseControlButton(isPlaying: music.isPlaying, inkColor: ink, hoverFill: ink.opacity(0.18)) {
                music.togglePlayPause()
            }
            .scaleEffect(0.52)
        }
        .frame(width: ring, height: ring)
        // Next: no ring (founder 2026-09-22); glyph scaled down to read the
        // same size as the pause glyph inside its progress ring.
        SkipControlButton(action: { music.nextTrack() }, direction: 1, inkColor: ink, hoverFill: ink.opacity(0.18))
            .scaleEffect(1.05)
            .frame(width: 32, height: ring)
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

/// The three inner sides of the black sliver at the screen edge (top, inner
/// side, bottom), drawn from where its bottom meets the bezel, so a trim
/// from 0 is progress. The bezel side has no line.
struct EdgeRimPath: Shape {
    var width: CGFloat
    var height: CGFloat
    var edge: CGFloat
    var midY: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard height > 0.5 else { return p }
        let r = min(width, height / 2)
        let top = midY - height / 2, bottom = midY + height / 2, inner = edge - width
        p.move(to: CGPoint(x: edge, y: bottom))
        p.addLine(to: CGPoint(x: inner + r, y: bottom))
        p.addArc(center: CGPoint(x: inner + r, y: bottom - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: inner, y: top + r))
        p.addArc(center: CGPoint(x: inner + r, y: top + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: edge, y: top))
        return p
    }
}
