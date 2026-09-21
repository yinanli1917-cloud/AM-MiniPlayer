/**
 * [INPUT]: EdgeCollapseAppModel.pose (all animatable channels) +
 *          MusicController.shared (real artwork / title / artist / playback).
 * [OUTPUT]: RootContentView v5 — one material for every state: a regular
 *           Liquid Glass body tinted with ONE colour extracted from the
 *           artwork in the panel state, blending to black at the edge; the
 *           tucked state is an island grown out of the screen edge (flat
 *           edge side, round inner side); the control body is always
 *           mounted and drips off the body on a delayed spring; the artwork
 *           is one view that flies. Nothing is ever swapped or inserted.
 * [POS]: Standalone spike root view.
 * [PROTOCOL]: This view only reads `model.pose`; all motion comes from the
 *             model animating pose channels with per-channel springs.
 */

import SwiftUI
import AppKit
import MusicMiniPlayerCore

struct RootContentView: View {
    @ObservedObject var model: EdgeCollapseAppModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassRootView(model: model)
        } else {
            Text("macOS 26 required").frame(width: 320, height: 360)
        }
    }
}

@available(macOS 26.0, *)
private struct GlassRootView: View {
    @ObservedObject var model: EdgeCollapseAppModel
    @ObservedObject var music = MusicController.shared
    @Namespace private var ns

    private var pose: EdgeCollapsePose { model.pose }

    /// One colour from the artwork; the whole panel glass is tinted with it.
    private var artworkColor: Color {
        model.artworkColor.map { Color(nsColor: $0) } ?? Color(white: 0.3)
    }

    /// Same Glass value for both bodies so they read as one material.
    private var glass: Glass {
        let base: Color
        switch model.tint {
        case .none: base = .clear
        case .black, .gradient: base = Color.black.opacity(EdgeCollapseTokens.tintOpacity)
        }
        let tint = blend(artworkColor.opacity(EdgeCollapseTokens.cardTintOpacity), base, t: pose.artworkTint)
        return .regular.tint(tint).interactive()
    }

    private var bodyShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: pose.cornerInner, bottomLeadingRadius: pose.cornerInner,
            bottomTrailingRadius: pose.cornerEdge, topTrailingRadius: pose.cornerEdge,
            style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            GlassEffectContainer(spacing: EdgeCollapseTokens.containerSpacing) {
                ZStack(alignment: .topLeading) {
                    controlView.glassEffectID("control", in: ns)
                    bodyView.glassEffectID("body", in: ns)
                }
            }

            heroView
            cardContent
        }
        .frame(width: EdgeCollapseTokens.containerSize.width, height: EdgeCollapseTokens.containerSize.height)
        .overlay(Color.black.opacity(model.reduceMotionFlashOpacity * 0.6).allowsHitTesting(false))
    }

    // MARK: - Body

    private var bodyView: some View {
        let r = pose.bodyRect
        return ZStack {
            // Edge-side dimming layer (HIG dimming layer), only when not the panel.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(EdgeCollapseTokens.edgeDimOpacity)],
                    startPoint: .leading, endPoint: .trailing)
                .frame(width: r.width * EdgeCollapseTokens.edgeDimFraction)
            }
            .opacity(model.tint == .gradient ? 1 - pose.artworkTint : 0)

            // Island progress line (bottom).
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Capsule().fill(Color.white.opacity(0.85))
                    .frame(width: max(0, r.width - 16), height: 3)
                    .padding(.bottom, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.35)).frame(width: max(0, r.width - 16), height: 3).padding(.bottom, 10)
                    }
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, (r.width - 16) * progress)) }
            }
            .opacity(pose.progressOpacity)

            // Floating bar text (H).
            HStack(spacing: 10) {
                Spacer(minLength: EdgeCollapseTokens.floatingBarArtwork + 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.trackTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(music.currentArtist).font(.system(size: 11)).opacity(0.75).lineLimit(1)
                }
                .foregroundStyle(.white)
                Spacer(minLength: 12)
            }
            .opacity(pose.barTextOpacity)
        }
        .allowsHitTesting(false)
        .frame(width: r.width, height: r.height)
        .clipShape(bodyShape)
        .glassEffect(glass, in: bodyShape)
        .contentShape(bodyShape)
        .onTapGesture { if model.presentation != .card { model.requestExpand() } }
        .position(x: r.midX, y: r.midY)
    }

    // MARK: - Control (always mounted; parked inside body when hidden)

    private var controlView: some View {
        let r = pose.controlRect
        let shape = RoundedRectangle(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, style: .continuous)
        return Group {
            if model.variant == .h { HStack(spacing: 16) { controlGlyphs } } else { VStack(spacing: 14) { controlGlyphs } }
        }
        .foregroundStyle(.white)
        .opacity(pose.controlContentOpacity)
        .frame(width: r.width, height: r.height)
        .glassEffect(glass, in: shape)
        .contentShape(shape)
        .allowsHitTesting(pose.controlContentOpacity > 0.5)
        .position(x: r.midX, y: r.midY)
    }

    private var controlGlyphs: some View {
        Group {
            Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold)).frame(width: 24, height: 24)
                .contentShape(Rectangle()).onTapGesture { model.toggleIsPlaying() }
            Image(systemName: "forward.fill")
                .font(.system(size: 14, weight: .semibold)).frame(width: 24, height: 24)
                .contentShape(Rectangle()).onTapGesture { model.nextTrack() }
        }
    }

    // MARK: - Hero artwork: one view, every state

    private var heroView: some View {
        let r = pose.heroRect
        return Group {
            if let art = music.currentArtwork { Image(nsImage: art).resizable().scaledToFill() } else { Color.gray }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: pose.heroCorner, style: .continuous))
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
    }

    // MARK: - Panel content below the cover (fullscreen-cover layout)

    private var cardContent: some View {
        let b = pose.bodyRect
        let top = b.minY + b.width
        let h = max(0, b.maxY - top)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.trackTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(music.currentArtist).font(.system(size: 11)).opacity(0.75).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                Image(systemName: "backward.fill")
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold)).frame(width: 28, height: 28)
                    .contentShape(Rectangle()).onTapGesture { model.toggleIsPlaying() }
                Image(systemName: "forward.fill").frame(width: 24, height: 24)
                    .contentShape(Rectangle()).onTapGesture { model.nextTrack() }
            }
            .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(width: b.width, height: h)
        .position(x: b.midX, y: top + h / 2)
        .opacity(pose.cardContentOpacity)
        .allowsHitTesting(pose.cardContentOpacity > 0.5)
    }

    private var progress: CGFloat {
        guard music.duration > 0 else { return 0 }
        return CGFloat(min(max(music.currentTime / music.duration, 0), 1))
    }
}

private func blend(_ a: Color, _ b: Color, t: Double) -> Color {
    let ca = NSColor(a).usingColorSpace(.sRGB) ?? .black
    let cb = NSColor(b).usingColorSpace(.sRGB) ?? .black
    let k = CGFloat(min(max(t, 0), 1))
    return Color(nsColor: NSColor(
        red: cb.redComponent + (ca.redComponent - cb.redComponent) * k,
        green: cb.greenComponent + (ca.greenComponent - cb.greenComponent) * k,
        blue: cb.blueComponent + (ca.blueComponent - cb.blueComponent) * k,
        alpha: cb.alphaComponent + (ca.alphaComponent - cb.alphaComponent) * k))
}

/// Spike-local single-colour extraction (mean of a coarse sample grid).
func edgeCollapseArtworkColor(_ image: NSImage) -> NSColor? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return nil }
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    let step = max(1, min(w, h) / 24)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
            }
            x += step
        }
        y += step
    }
    guard n > 0 else { return nil }
    return NSColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
}
