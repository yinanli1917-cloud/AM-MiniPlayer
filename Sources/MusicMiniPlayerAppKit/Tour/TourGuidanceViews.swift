/**
 * [INPUT]: SwiftUI (Canvas); TourGuidanceMotion's TourCardVisual /
 *          TourOverlayVisual / TourRingGeometry; TourCardStyle's palette.
 * [OUTPUT]: Exports TourGuidanceStore and its three observable objects (TourCardVisualStore, TourGlyphClock,
 *           TourOverlayStore — separate, so a frame that changes only the ring redraws only the ring, one that
 *           changes only the demo's clock re-renders only the demo, one that only moves the card redraws nothing),
 *           TourOverlayRegion (the smallest screen rect the overlay needs), TourGuidanceDrawing (pure drawing
 *           of one frame), TourGuidanceOverlayView (the overlay window's root).
 * [POS]: MusicMiniPlayerAppKit/Tour. Draws the highlight ring, the ghost
 *        cursor and the panel-edge glow (prototype C.4) in ONE click-through
 *        overlay window. The window is only as big as what is drawn in it (it used to span the
 *        whole 2560x1440 screen: a 59 MB transparent backing store re-rendered every frame) and
 *        is parked while nothing is drawn; inside it the ring is a Canvas drawing in
 *        screen-derived coordinates, so the ring itself never moves a window.
 */

import SwiftUI
import AppKit
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Store
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// What the card's SwiftUI content draws (height, beak, scale, block fades, the demo band). Its OWN observable object:
/// SwiftUI re-evaluates a view whenever ANY `@Published` of an observed object changes, so a card that observed the ring's
/// breathing (or the panel's frame, which changes on every scroll event of a drag) was rebuilt for nothing.
@MainActor
final class TourCardVisualStore: ObservableObject {
    @Published var visual: TourCardVisual = .hidden
    /// The card is driven by the guidance motion (springs) rather than by
    /// static placement: tests that render a bare card leave this false.
    @Published var driven = false
}

/// The trackpad demo's clock (seconds into its cycle, nil = at rest) — its own observable object too, so the ~7 s the demo
/// plays re-render the demo alone, not the card around it (title, body, beats, buttons).
@MainActor
final class TourGlyphClock: ObservableObject {
    @Published var elapsed: Double?
}

/// What the overlay window draws (ring, ghost cursor, panel glow) and where: its frame and the panel's frame, screen space (y up).
@MainActor
final class TourOverlayStore: ObservableObject {
    @Published var visual: TourOverlayVisual = .hidden
    @Published var frame: CGRect = .zero
    @Published var panelFrame: CGRect = .zero
}

/// The three observable pieces of the guidance, and the plain accessors the shell and the controller write through.
@MainActor
final class TourGuidanceStore {
    let cardStore = TourCardVisualStore()
    let glyphClock = TourGlyphClock()
    let overlayStore = TourOverlayStore()
    let marksStore = TourMarksStore()
    let ghostStore = TourGhostStore()

    var card: TourCardVisual {
        get { cardStore.visual }
        set { cardStore.visual = newValue }
    }
    var overlay: TourOverlayVisual {
        get { overlayStore.visual }
        set { overlayStore.visual = newValue }
    }
    var overlayFrame: CGRect {
        get { overlayStore.frame }
        set { overlayStore.frame = newValue }
    }
    var panelFrame: CGRect {
        get { overlayStore.panelFrame }
        set { overlayStore.panelFrame = newValue }
    }
    var driven: Bool {
        get { cardStore.driven }
        set { cardStore.driven = newValue }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Overlay region
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The screen rect (AppKit, y up) the overlay window has to cover for one frame: the panel-edge glow's halo,
/// the ring with its pulse, sonar ripples and soft glow, the ghost cursor with its ripple. nil = nothing is drawn.
enum TourOverlayRegion {
    /// Room past a shape for the blurred glows (a 12+12g pt CSS glow reaches ~3 sigma out).
    static let glowMargin: CGFloat = 56
    /// The ring's largest scale: appear pulse 1.14 x breath 1.035 x sonar 1.35.
    static let maxRingScale: CGFloat = 1.14 * 1.035 * 1.35
    static let ghostReach: CGFloat = 64
    /// Room past a snap-target mark for its pulse swell and soft outline.
    static let markReach: CGFloat = 10

    static func needed(for f: TourOverlayVisual, panel: CGRect) -> CGRect? {
        var region: CGRect?
        func add(_ r: CGRect) { region = region.map { $0.union(r) } ?? r }
        if f.panelGlow > 0.003, !panel.isEmpty {
            let reach = 6 + 22 * CGFloat(f.panelGlow) + glowMargin
            add(panel.insetBy(dx: -reach, dy: -reach))
        }
        if f.ringVisible, f.ringOpacity > 0.003 {
            let grow = (CGFloat(max(f.ring.w, f.ring.h)) * (maxRingScale - 1)) / 2 + glowMargin
            add(f.ring.rect.insetBy(dx: -grow, dy: -grow))
        }
        if f.ghostVisible, f.ghostOpacity > 0.003 {
            add(CGRect(x: f.ghost.x - ghostReach, y: f.ghost.y - ghostReach, width: ghostReach * 2, height: ghostReach * 2))
        }
        return region
    }

    /// The window frame to use given the one it has: keep it while it still contains `needed` and is not
    /// wastefully large (resizing a window is the expensive part, not drawing in it); otherwise grow to cover
    /// `needed` plus the panel's neighbourhood (rings hop between controls inside it), clamped to the screen.
    static func windowFrame(current: CGRect, needed: CGRect, panel: CGRect, screen: CGRect) -> CGRect {
        let wanted = needed.intersection(screen)
        if current.contains(wanted), current.width * current.height <= 4 * max(wanted.width * wanted.height, 160_000) { return current }
        var target = needed
        let neighbourhood = panel.insetBy(dx: -120, dy: -120)
        if !panel.isEmpty, neighbourhood.intersects(needed) { target = target.union(neighbourhood) }
        return target.intersection(screen).integral
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Drawing (prototype `paintC` halo / gcur / rim)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourGuidanceDrawing {
    /// Screen point (y up) -> overlay-local point (y down).
    static func local(_ p: CGPoint, in overlay: CGRect) -> CGPoint {
        CGPoint(x: p.x - overlay.minX, y: overlay.maxY - p.y)
    }

    static func ringPath(_ g: TourRingGeometry, in overlay: CGRect, scale: Double = 1) -> Path {
        let c = local(CGPoint(x: g.cx, y: g.cy), in: overlay)
        let w = g.w * scale, h = g.h * scale
        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        return Path(roundedRect: rect, cornerRadius: min(g.corner * scale, min(w, h) / 2), style: .continuous)
    }

    static func draw(_ ctx: GraphicsContext, frame f: TourOverlayVisual, overlay: CGRect, panel: CGRect, palette: TourCardPalette) {
        if f.panelGlow > 0.003 { drawPanelGlow(ctx, g: f.panelGlow, overlay: overlay, panel: panel, palette: palette) }
        if f.ringVisible, f.ringOpacity > 0.003 { drawRing(ctx, f: f, overlay: overlay, palette: palette) }
        if f.ghostVisible, f.ghostOpacity > 0.003 { drawGhost(ctx, f: f, overlay: overlay, palette: palette) }
    }

    /// Snap-target marks (prototype C.4.5): a soft rounded outline the size of the panel at each landing spot, very low
    /// opacity (stroke ~0.18, a light fill). The corner the panel sits in is "here" (a touch firmer, with a dot); a corner
    /// the user has landed in carries a small check; the one that just received the panel pulses (fill + check).
    static func drawSnapMarks(_ ctx: GraphicsContext, marks: TourSnapMarksVisual, overlay: CGRect, palette: TourCardPalette, only: Int? = nil) {
        for (i, screenRect) in marks.rects.enumerated() where only == nil || only == i {
            let c0 = local(CGPoint(x: screenRect.minX, y: screenRect.maxY), in: overlay)
            let pulse = marks.pulses.indices.contains(i) ? marks.pulses[i] : 0
            // pulse: fill swells fast, eases out; a hair of scale rides with it.
            let hit = pulse > 0 && pulse < 1 ? TourFeedbackEase.out.value(min(pulse / 0.2, 1)) * (1 - TourFeedbackEase.out.value(max((pulse - 0.2) / 0.8, 0))) : 0
            let grow = 1 + 0.025 * hit + 0.012 * marks.breath
            let w = screenRect.width * grow, h = screenRect.height * grow
            let rect = CGRect(x: c0.x - (w - screenRect.width) / 2, y: c0.y - (h - screenRect.height) / 2, width: w, height: h)
            let shape = Path(roundedRect: rect, cornerRadius: 16 * grow, style: .continuous)
            let isHere = marks.here == i
            let isTarget = marks.target == i && !isHere
            let landed = marks.landed.indices.contains(i) && marks.landed[i]
            var layer = ctx
            layer.opacity = marks.opacity
            let breathLift = 0.06 * marks.breath
            let fillAlpha = (isHere ? 0.10 : isTarget ? 0.12 : 0.07) + breathLift * 0.5 + 0.20 * hit
            let strokeAlpha = (isHere ? 0.30 : isTarget ? 0.34 : 0.18) + breathLift + 0.30 * hit
            layer.fill(shape, with: .color(palette.accent.opacity(fillAlpha)))
            layer.stroke(shape, with: .color(palette.accent.opacity(strokeAlpha)), style: StrokeStyle(lineWidth: isTarget ? 2 : 1.5))
            let mid = CGPoint(x: rect.midX, y: rect.midY)
            if landed || hit > 0 {
                // The tick: drawn in with the pulse, then a quiet resting check on a corner already used.
                let rest = landed ? 0.5 : 0
                var tick = layer
                tick.opacity = marks.opacity * max(rest, min(1, 0.5 + hit))
                var p = Path()
                p.move(to: CGPoint(x: mid.x - 9, y: mid.y + 0.5))
                p.addLine(to: CGPoint(x: mid.x - 3, y: mid.y + 7))
                p.addLine(to: CGPoint(x: mid.x + 10, y: mid.y - 7))
                let drawn = pulse > 0 && pulse < 1 ? min(pulse / 0.3, 1) : 1
                tick.stroke(p.trimmedPath(from: 0, to: drawn), with: .color(palette.accent),
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            } else if isHere {
                layer.fill(Path(ellipseIn: CGRect(x: mid.x - 3.5, y: mid.y - 3.5, width: 7, height: 7)), with: .color(palette.accent.opacity(0.55)))
            }
        }
    }

    /// `inset 0 0 0 1.5px rgba(accent, .55 g), 0 0 (6 + 22 g)px rgba(accent, .35 g)`
    static func drawPanelGlow(_ ctx: GraphicsContext, g: Double, overlay: CGRect, panel: CGRect, palette: TourCardPalette) {
        let c0 = local(CGPoint(x: panel.minX, y: panel.maxY), in: overlay)
        let rect = CGRect(x: c0.x, y: c0.y, width: panel.width, height: panel.height)
        let shape = Path(roundedRect: rect, cornerRadius: 16, style: .continuous)
        // The outer glow paints OUTSIDE the panel only (a CSS box-shadow does): inside it would
        // read as a dark red vignette over the cover.
        var outer = ctx
        outer.clip(to: shape, options: .inverse)
        outer.addFilter(.blur(radius: (6 + 22 * g) / 2))
        outer.stroke(shape, with: .color(palette.accent.opacity(0.35 * g)), style: StrokeStyle(lineWidth: 6 + 22 * g))
        var inner = ctx
        inner.clip(to: shape)
        inner.stroke(shape, with: .color(palette.accent.opacity(0.55 * g)), style: StrokeStyle(lineWidth: 3))
    }

    /// `1.5px accent border; 0 0 0 (3+4g)px ring-track, 0 0 (12+12g)px accent(.32+.22g)`,
    /// dashed while it is only a hint, plus the sonar ripples.
    static func drawRing(_ ctx: GraphicsContext, f: TourOverlayVisual, overlay: CGRect, palette: TourCardPalette) {
        let g = f.breath
        let scale = f.ringScale * f.ringPulse * (1 + 0.035 * g)
        var layer = ctx
        layer.opacity = min(max(f.ringOpacity * (1 - 0.18 * g), 0), 1)
        let shape = ringPath(f.ring, in: overlay, scale: scale)

        // CSS box-shadows paint OUTSIDE the border box only: the control inside
        // the ring must stay untinted, so both are clipped to the outside.
        var outside = layer
        outside.clip(to: shape, options: .inverse)
        // Outer track halo (the "spread").
        let spread = 3 + 4 * g
        outside.stroke(shape, with: .color(palette.ringTrack), style: StrokeStyle(lineWidth: 1.5 + spread * 2))
        // Soft accent glow.
        var glow = outside
        glow.addFilter(.blur(radius: (12 + 12 * g) / 2))
        glow.stroke(shape, with: .color(palette.accent.opacity(0.32 + 0.22 * g)), style: StrokeStyle(lineWidth: 3 + 4 * g))
        // The crisp ring itself.
        let style = f.ringDashed
            ? StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3.2])
            : StrokeStyle(lineWidth: 1.5)
        layer.stroke(shape, with: .color(palette.accent), style: style)

        // Sonar ripples: expand 1.0 -> 1.35 and fade .5 -> 0 (ease-out).
        for u in f.ripples {
            let e = TourFeedbackEase.out.value(u)
            var r = ctx
            r.opacity = TourGuidanceTokens.rippleAlpha * (1 - e) * min(max(f.ringOpacity, 0), 1)
            let rp = ringPath(f.ring, in: overlay, scale: scale * (1 + TourGuidanceTokens.rippleScale * e))
            r.stroke(rp, with: .color(palette.accent), style: StrokeStyle(lineWidth: 1.5))
        }
    }

    /// The prototype's arrow (`M2 1.5v17l4.4-4 3 7 3.2-1.4-3-6.8H16z`) with the
    /// hotspot at (2, 1.5), a drop shadow, and the "parked here" ripple.
    static func drawGhost(_ ctx: GraphicsContext, f: TourOverlayVisual, overlay: CGRect, palette: TourCardPalette) {
        let tip = local(f.ghost, in: overlay)
        var g = ctx
        g.opacity = f.ghostOpacity
        if let rp = f.ghostRipple {
            var r = g
            r.opacity = 0.55 * (1 - rp)
            let radius = 13 * (0.6 + rp * 1.8)
            r.stroke(Path(ellipseIn: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(palette.accent), style: StrokeStyle(lineWidth: 2))
        }
        var arrow = Path()
        arrow.move(to: CGPoint(x: 2, y: 1.5))
        arrow.addLine(to: CGPoint(x: 2, y: 18.5))
        arrow.addLine(to: CGPoint(x: 6.4, y: 14.5))
        arrow.addLine(to: CGPoint(x: 9.4, y: 21.5))
        arrow.addLine(to: CGPoint(x: 12.6, y: 20.1))
        arrow.addLine(to: CGPoint(x: 9.6, y: 13.3))
        arrow.addLine(to: CGPoint(x: 16, y: 13.3))
        arrow.closeSubpath()
        let placed = arrow.applying(CGAffineTransform(translationX: tip.x - 2, y: tip.y - 1.5))
        var shadowed = g
        shadowed.addFilter(.shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 2))
        shadowed.fill(placed, with: .color(.white))
        g.stroke(placed, with: .color(Color(hex: 0x111111)), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Snap-target marks (one small window each)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The four marks sit at the far corners of the screen: ONE overlay window spanning them would be the 2560x1440 transparent
/// backing store the ring overlay was cut down from. Each mark gets its own window, exactly its size plus room for the pulse.
@MainActor
final class TourMarksStore: ObservableObject {
    @Published var visual: TourSnapMarksVisual = .hidden
}

enum TourMarkWindowRegion {
    /// Room past a mark for its pulse swell and its soft outline.
    static let reach: CGFloat = TourOverlayRegion.markReach
    static func frame(for markRect: CGRect) -> CGRect { markRect.insetBy(dx: -reach, dy: -reach) }
}

struct TourSnapMarkView: View {
    @ObservedObject var store: TourMarksStore
    var index: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = TourCardPalette.resolve(dark: colorScheme == .dark)
        let marks = store.visual
        return Canvas { ctx, _ in
            guard marks.rects.indices.contains(index) else { return }
            TourGuidanceDrawing.drawSnapMarks(ctx, marks: marks, overlay: TourMarkWindowRegion.frame(for: marks.rects[index]), palette: palette, only: index)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Overlay root
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TourGuidanceOverlayView: View {
    @ObservedObject var store: TourOverlayStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = TourCardPalette.resolve(dark: colorScheme == .dark)
        let f = store.visual
        let overlay = store.frame
        let panel = store.panelFrame
        return Canvas { ctx, _ in
            #if DEBUG
            TourPerfProbe.bump(.overlayRender)
            #endif
            TourGuidanceDrawing.draw(ctx, frame: f, overlay: overlay, panel: panel, palette: palette)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
