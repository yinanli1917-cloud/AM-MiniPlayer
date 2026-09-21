/**
 * [INPUT]: EdgeCollapseAppModel.pose + MusicController.shared.
 * [OUTPUT]: RootContentView v7 (vertical only: docked pill with cover + pause ring + next; hover widens and drips the controls off).
 *   - Panel state IS the real nanoPod MiniPlayerView (fullscreen-cover mode),
 *     untouched. Underneath it, at the same rect, sits the glass body.
 *   - Collapse: MiniPlayerView fades out over the first 100ms revealing the
 *     glass at the same rect (ref1 material swap), the body morphs into an
 *     island grown out of the screen edge, the cover (one overlay Image
 *     crossfaded in place over the real cover) detaches late and lands last
 *     (ref2).
 *   - Material: `.clear` glass (HIG: components floating over media) + a
 *     full-width dimming gradient, black at the edge fading inward (HIG
 *     dimming layer; Siri panel look). Same Glass value on both bodies.
 *   - Floating: 72pt info bar (52pt cover, title, artist, progress) + a
 *     control body carrying nanoPod's own PlayPause/Skip buttons, always
 *     mounted, parked inside the bar and dripping off on a delayed spring
 *     (ref4); text blurs in as the shapes settle (ref4).
 * [POS]: Standalone spike root view.
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
    @StateObject private var edgePresentation = EdgePresentationModel()
    @Namespace private var ns

    private var pose: EdgeCollapsePose { model.pose }
    private var isPanel: Bool { model.presentation == .card }

    /// One Glass value for both bodies. Clear over the wallpaper; the black
    /// comes from the dimming layer, not from the material.
    private var glass: Glass {
        switch model.tint {
        case .none: return .clear.interactive()
        case .black: return .clear.tint(Color.black.opacity(EdgeCollapseTokens.tintOpacity)).interactive()
        case .gradient: return .clear.interactive()
        }
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
                    bodyView.glassEffectID("body", in: ns)
                    // Drawn above the body so its buttons stay clickable while parked inside the docked pill.
                    controlView.glassEffectID("control", in: ns)
                }
            }

            panelView
            heroView
        }
        .frame(width: EdgeCollapseTokens.containerSize.width, height: EdgeCollapseTokens.containerSize.height)
        .overlay(Color.black.opacity(model.reduceMotionFlashOpacity * 0.6).allowsHitTesting(false))
    }

    // MARK: - The real nanoPod panel (fullscreen-cover mode)

    private var panelView: some View {
        let r = EdgeCollapsePoses.pose(for: .card, variant: model.variant, titleWidth: 0).bodyRect
        return MiniPlayerView()
            .environmentObject(music)
            .environmentObject(edgePresentation)
            .frame(width: r.width, height: r.height)
            .clipShape(RoundedRectangle(cornerRadius: EdgeCollapseTokens.cardCornerRadius, style: .continuous))
            .opacity(pose.cardContentOpacity)
            .allowsHitTesting(pose.cardContentOpacity > 0.9)
            .position(x: r.midX, y: r.midY)
    }

    // MARK: - Glass body: panel rect → island → floating bar

    private var bodyView: some View {
        let r = pose.bodyRect
        let dim = 1 - pose.artworkTint
        return ZStack {
            // Full-width dimming layer: black at the screen edge, lighter inward.
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(EdgeCollapseTokens.edgeDimInnerOpacity), location: 0),
                    .init(color: Color.black.opacity(EdgeCollapseTokens.edgeDimMidOpacity), location: 0.5),
                    .init(color: Color.black.opacity(EdgeCollapseTokens.edgeDimOpacity), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing)
            .opacity(model.tint == .gradient ? dim : 0)

            // Hover pill: title + artist under the cover.
            VStack(spacing: 2) {
                Spacer(minLength: 0)
                Text(model.trackTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(music.currentArtist).font(.system(size: 10)).opacity(0.72).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            .blur(radius: pose.contentBlur)
            .opacity(pose.barTextOpacity)
        }
        .allowsHitTesting(false)
        .frame(width: r.width, height: r.height)
        .clipShape(bodyShape)
        .glassEffect(glass, in: bodyShape)
        .contentShape(bodyShape)
        .onTapGesture { if !isPanel { model.requestExpand() } }
        .position(x: r.midX, y: r.midY)
    }

    // MARK: - Control body: nanoPod's own buttons, always mounted

    private var controlView: some View {
        let r = pose.controlRect
        let shape = RoundedRectangle(cornerRadius: EdgeCollapseTokens.floatingControlCornerRadius, style: .continuous)
        let ink = Color.white
        let vertical = r.height > r.width
        return Group {
            if vertical { VStack(spacing: 10) { controlButtons(ink: ink) } } else { HStack(spacing: 18) { controlButtons(ink: ink) } }
        }
        .blur(radius: pose.contentBlur)
        .opacity(pose.controlContentOpacity)
        .frame(width: r.width, height: r.height)
        .glassEffect(glass, in: shape)
        .contentShape(shape)
        .allowsHitTesting(pose.controlContentOpacity > 0.9)
        .position(x: r.midX, y: r.midY)
    }

    /// Two buttons only: pause/play with a progress ring (Apple Watch Now
    /// Playing), and next. Both are nanoPod's own buttons.
    @ViewBuilder
    private func controlButtons(ink: Color) -> some View {
        ZStack {
            Circle().stroke(ink.opacity(0.25), lineWidth: 2.5)
            Circle().trim(from: 0, to: progress).stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            PlayPauseControlButton(isPlaying: music.isPlaying, inkColor: ink, hoverFill: ink.opacity(0.18)) {
                music.togglePlayPause()
            }
            .frame(width: 30, height: 30)
        }
        .frame(width: 40, height: 40)
        SkipControlButton(action: { music.nextTrack() }, direction: 1, inkColor: ink, hoverFill: ink.opacity(0.18))
            .frame(width: 30, height: 30)
    }

    // MARK: - Hero cover: crossfades in place over the real cover, then flies

    private var heroView: some View {
        let r = pose.heroRect
        return Group {
            if let art = music.currentArtwork { Image(nsImage: art).resizable().scaledToFill() } else { Color.gray }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: pose.heroCorner, style: .continuous))
        .opacity(1 - pose.cardContentOpacity)
        .position(x: r.midX, y: r.midY)
        .allowsHitTesting(false)
    }

    private var progress: CGFloat {
        guard music.duration > 0 else { return 0 }
        return CGFloat(min(max(music.currentTime / music.duration, 0), 1))
    }
}

/// Spike-local single-colour extraction (kept for the control window readout).
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
