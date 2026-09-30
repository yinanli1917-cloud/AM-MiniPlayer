/**
 * [INPUT]: SwiftUI (Canvas), AppKit (NSColor for text-colour mixing);
 *          TourFeedbackChoreographer's Frame / FX snapshot value types;
 *          TourCompletionFeedback (the ObservableObject the views observe);
 *          TourCardStyle's palette / metrics.
 * [OUTPUT]: Exports TourFeedbackRing, TourFeedbackBeatDot, TourFeedbackBeatRow,
 *           the `tourFeedbackBlock(_:_:)` content-fade modifier, TourFXCanvas
 *           (pure particle drawing), TourFXHost (live wrapper) and the
 *           palette additions the animation needs.
 * [POS]: MusicMiniPlayerAppKit/Tour. Everything that DRAWS a feedback frame.
 *        The ring and the beat dot are drawn in a Canvas with the same
 *        operations, in the same order, as the prototype's SVG (track, disc,
 *        arc, comet, seal flash, check), so a stroke of the prototype and a
 *        stroke here have the same geometry. All transforms are applied
 *        inside the Canvas (a scaled Canvas view would be a scaled bitmap).
 */

import SwiftUI
import AppKit
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Palette additions (prototype `--accent-soft/--gold/--violet/--dot-track`)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension TourCardPalette {
    var isDark: Bool { self == .dark }
    /// Unchecked beat outline: `#3C3C43` 30 % (light) / `#EBEBF5` 30 % (dark).
    var dotTrack: Color { isDark ? Color(hex: 0xEBEBF5, opacity: 0.30) : Color(hex: 0x3C3C43, opacity: 0.30) }
    var accentSoft: Color { Color(hex: 0xFF8FA0) }
    var gold: Color { isDark ? Color(hex: 0xFFC65A) : Color(hex: 0xFFB93F) }
    var violet: Color { isDark ? Color(hex: 0x8F82FF) : Color(hex: 0x7A6BFF) }
    var mint: Color { Color(hex: 0x7FD6C2) }

    func color(_ c: TourFXColor) -> Color {
        switch c {
        case .accent: return accent
        case .soft: return accentSoft
        case .gold: return gold
        case .violet: return violet
        case .mint: return mint
        case .white: return .white
        }
    }
}

private func mixColors(_ a: Color, _ b: Color, _ t: Double) -> Color {
    let ca = NSColor(a).usingColorSpace(.sRGB) ?? .black
    let cb = NSColor(b).usingColorSpace(.sRGB) ?? .black
    func lerp(_ x: CGFloat, _ y: CGFloat) -> Double { Double(x + (y - x) * CGFloat(t)) }
    return Color(.sRGB, red: lerp(ca.redComponent, cb.redComponent), green: lerp(ca.greenComponent, cb.greenComponent),
                 blue: lerp(ca.blueComponent, cb.blueComponent), opacity: lerp(ca.alphaComponent, cb.alphaComponent))
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Ring drawing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TourRingParams: Equatable {
    var progressSteps: Double
    var total: Double
    var lineWidth = 5.5
    var scale = 1.0
    var velocity = 0.0
    var disc = 0.0
    var seal = 0.0
    var checkDraw = 0.0
    var checkScale = 1.0
}

enum TourRingDrawing {
    static let radius = TourFeedbackChoreographer.ringPathRadius
    static let circumference = 2 * Double.pi * radius

    /// 12 o'clock start, clockwise: a full-circle path rotated -90 degrees.
    static func circlePath() -> Path {
        Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            .applying(CGAffineTransform(rotationAngle: -.pi / 2))
    }

    /// Prototype `paint()` for the ring, in the order the SVG paints it.
    static func draw(_ ctx: GraphicsContext, center: CGPoint, params p: TourRingParams, palette: TourCardPalette) {
        var g = ctx
        g.translateBy(x: center.x, y: center.y)
        g.scaleBy(x: p.scale, y: p.scale)

        let circle = circlePath()
        let frac = min(max(p.progressSteps / p.total, 0), 1)
        let full = frac >= 0.9995

        // track
        g.stroke(circle, with: .color(palette.ringTrack), style: StrokeStyle(lineWidth: 5.5))
        // solid disc (closing)
        if p.disc > 0.0005 {
            let r = radius * min(max(p.disc, 0), 1.05)
            g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(palette.accent))
        }
        // arc
        if frac > 0.003 {
            let path = full ? circle : circle.trimmedPath(from: 0, to: frac)
            g.stroke(path, with: .color(palette.accent), style: StrokeStyle(lineWidth: p.lineWidth, lineCap: .round))
        }
        // comet: a short white highlight trailing the arc head, sized by speed
        if !full {
            let speed = abs(p.velocity)
            let alpha = min(max(speed * 0.32, 0), 0.55)
            let lenFrac = (0.55 / p.total) * min(max(speed / 2.4, 0), 1)
            let minFrac = 0.01 / circumference
            let len = max(minFrac, lenFrac)
            if alpha > 0.001, frac > 0.003 {
                var c = g
                c.opacity = alpha
                let start = max(0, frac - len)
                c.stroke(circle.trimmedPath(from: start, to: max(frac, start + 0.0001)), with: .color(.white),
                         style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        // seal flash (closing)
        if p.seal > 0.001 {
            var s = g
            s.opacity = min(max(p.seal, 0), 1)
            s.stroke(circle, with: .color(.white), style: StrokeStyle(lineWidth: p.lineWidth))
        }
        // check: M8.6 14.3 L12.2 17.7 L19.2 10 in the 28x28 box, drawn by trim
        if p.checkDraw > 0.001 {
            var c = g
            c.scaleBy(x: p.checkScale, y: p.checkScale)
            var path = Path()
            path.move(to: CGPoint(x: 8.6 - 14, y: 14.3 - 14))
            path.addLine(to: CGPoint(x: 12.2 - 14, y: 17.7 - 14))
            path.addLine(to: CGPoint(x: 19.2 - 14, y: 10 - 14))
            let ink: Color = p.disc > 0.35 ? .white : palette.accent
            c.stroke(path.trimmedPath(from: 0, to: min(max(p.checkDraw, 0), 1)), with: .color(ink),
                     style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Ring view
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// The continuous progress ring (§4.7): outer diameter 28, line 5.5, round
/// cap, 12 o'clock clockwise, centerline radius (28 - 5.5) / 2 = 11.25.
struct TourFeedbackRing: View {
    var completed: Int
    var total: Int = 7
    /// A finished ring (the finale): solid disc with a white check.
    var closed: Bool = false
    var stepLabel: String = ""
    var palette: TourCardPalette
    @ObservedObject var feedback: TourCompletionFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var diameter: CGFloat { TourMotionPolicy.Tokens.ringOuterDiameter }
    /// Room for the swollen stroke, the 1.08 seal scale and the halo.
    private let canvasSide: CGFloat = 52

    var body: some View {
        let f = feedback.frame
        let engaged = f.ringProgress != nil
        let totalD = Double(max(total, 1))
        let params: TourRingParams
        if engaged {
            params = TourRingParams(progressSteps: f.ringProgress ?? 0, total: totalD, lineWidth: f.ringLineWidth, scale: f.ringScale,
                                    velocity: f.ringVelocity, disc: f.disc, seal: f.seal, checkDraw: f.checkDraw, checkScale: f.checkScale)
        } else {
            params = TourRingParams(progressSteps: closed ? totalD : Double(completed), total: totalD,
                                    disc: closed ? 1 : 0, checkDraw: closed ? 1 : 0, checkScale: 1)
        }
        let numberOpacity = engaged ? f.numberOpacity : (closed ? 0 : 1)
        return ZStack {
            Canvas { ctx, size in
                TourRingDrawing.draw(ctx, center: CGPoint(x: size.width / 2, y: size.height / 2), params: params, palette: palette)
            }
            .frame(width: canvasSide, height: canvasSide)
            Text(stepLabel)
                .font(.system(size: 9.5, weight: .bold))
                .monospacedDigit()
                .tracking(-0.2)
                .foregroundStyle(palette.ink)
                // A quiet step change (skip, "Begin") rolls the number up (C.3, 0.22 s); during a
                // completion the feedback drives the number itself.
                .contentTransition(.numericText())
                .animation(engaged || reduceMotion ? nil : .easeOut(duration: 0.22), value: stepLabel)
                .opacity(numberOpacity)
                .scaleEffect(engaged ? f.numberScale : 1)
                .offset(y: engaged ? f.numberOffsetY : 0)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(closed ? "已完成" : "第 \(stepLabel) 步，共 \(total) 步")
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Beat dot + row
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourBeatDotDrawing {
    /// 14 x 14 dot, drawn around `center`: outline r 6.25 / 1.5pt, solid disc
    /// r 6.9 * fill, white check `M4 7.3 L6.3 9.5 L10.2 4.8` (1.9pt), scale.
    static func draw(_ ctx: GraphicsContext, center: CGPoint, fill: Double, draw: Double, scale: Double, palette: TourCardPalette,
                     hover: Bool = false, skipped: Bool = false, pending: Double = 0) {
        var g = ctx
        g.translateBy(x: center.x, y: center.y)
        g.scaleBy(x: scale, y: scale)
        let outline = Path(ellipseIn: CGRect(x: -6.25, y: -6.25, width: 12.5, height: 12.5))
        if pending > 0.003 {
            // "Ready for you" glow (C.5.3): a soft accent halo breathing around the dot.
            var glow = g
            glow.addFilter(.blur(radius: 2))
            glow.stroke(outline, with: .color(palette.accent.opacity(0.75 * pending)), style: StrokeStyle(lineWidth: 1.5 + 3 * pending))
        }
        if skipped {
            // "Not this time" (C.5.4): dashed and dimmed to 55 %.
            var dim = g
            dim.opacity = 0.55
            dim.stroke(outline, with: .color(palette.dotTrack), style: StrokeStyle(lineWidth: 1.5, dash: [2.2, 2.2]))
        } else {
            g.stroke(outline, with: .color(hover || pending > 0.003 ? palette.accent : palette.dotTrack), style: StrokeStyle(lineWidth: 1.5))
        }
        let r = 6.9 * min(max(fill, 0), 1)
        if r > 0.005 {
            g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(palette.accent))
        }
        if draw > 0.001 {
            var path = Path()
            path.move(to: CGPoint(x: 4 - 7, y: 7.3 - 7))
            path.addLine(to: CGPoint(x: 6.3 - 7, y: 9.5 - 7))
            path.addLine(to: CGPoint(x: 10.2 - 7, y: 4.8 - 7))
            g.stroke(path.trimmedPath(from: 0, to: min(max(draw, 0), 1)), with: .color(.white),
                     style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
        }
    }
}

/// The 14pt beat circle: outline -> solid accent with a white check.
struct TourFeedbackBeatDot: View {
    var index: Int
    var checked: Bool
    var palette: TourCardPalette
    @ObservedObject var feedback: TourCompletionFeedback
    var hover = false
    var skipped = false
    /// The beat is ready for the user's last move (C.5.3): a glow that breathes 3 times.
    var pending = false

    @State private var pendingPhase = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let beat = feedback.frame.beats[index]
        let fill = beat?.fill ?? (checked ? 1 : 0)
        let draw = beat?.draw ?? (checked ? 1 : 0)
        let scale = beat?.scale ?? 1
        let size = TourCardMetrics.beatDot
        let glow = pending && !checked ? (reduceMotion ? 0.001 : pendingPhase) : 0
        return Canvas { ctx, canvas in
            TourBeatDotDrawing.draw(ctx, center: CGPoint(x: canvas.width / 2, y: canvas.height / 2), fill: fill, draw: draw, scale: scale,
                                    palette: palette, hover: hover, skipped: skipped && !checked, pending: glow)
        }
        .frame(width: 26, height: 26)
        .frame(width: size, height: size)
        .onChange(of: pending) { _, isPending in
            guard isPending, !reduceMotion else { pendingPhase = 0; return }
            // drop-shadow 0 -> 4pt, period 1.4 s, 3 cycles, then rest (spec C.5.3).
            pendingPhase = 0
            withAnimation(.easeInOut(duration: 0.7).repeatCount(6, autoreverses: true)) { pendingPhase = 1 }
        }
    }
}

/// A beat row: dot + text. The text turns from ink to muted over 0.2s from
/// the moment the dot is pressed (prototype `li.done`).
struct TourFeedbackBeatRow: View {
    var beat: TourBeatModel
    var palette: TourCardPalette
    var size: CGFloat
    @ObservedObject var feedback: TourCompletionFeedback
    /// The pointer moved onto / off this row: the ring peeks at the row's control (C.4.1).
    var onHover: ((Int, Bool) -> Void)?

    @State private var hovering = false

    var body: some View {
        let mix = feedback.frame.beats[beat.id]?.textMix ?? (beat.checked ? 1 : 0)
        return HStack(spacing: 8) {
            TourFeedbackBeatDot(index: beat.id, checked: beat.checked, palette: palette, feedback: feedback,
                                hover: hovering, skipped: beat.skipped, pending: beat.pending)
            Text(beat.text)
                .font(.system(size: size))
                .foregroundStyle(mixColors(palette.ink, palette.muted, beat.skipped ? 1 : mix))
                .fixedSize(horizontal: false, vertical: true)
        }
        // A row is a status, not a button: the wash says "this is the one I mean",
        // it does not invite a click. Sized 8pt out to each side WITHOUT taking layout room.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.rowHover)
                .padding(.horizontal, -8)
                .padding(.vertical, -3)
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover?(beat.id, inside)
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Handoff content fade
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Block 0 = title, 1 = body, 2 = beats and everything below (spec §B.2).
private struct TourFeedbackBlock: ViewModifier {
    var index: Int
    @ObservedObject var feedback: TourCompletionFeedback
    /// The card guidance's own per-block fade (appear stagger, step-to-step
    /// swap): multiplies the completion feedback's, nil = not driven.
    var guide: TourGuidanceFrame?

    func body(content: Content) -> some View {
        let f = feedback.frame
        var opacity = f.contentOpacity.indices.contains(index) ? f.contentOpacity[index] : 1
        var dy = f.contentOffsetY.indices.contains(index) ? f.contentOffsetY[index] : 0
        if let guide {
            opacity *= guide.contentOpacity.indices.contains(index) ? guide.contentOpacity[index] : 1
            dy += guide.contentOffsetY.indices.contains(index) ? guide.contentOffsetY[index] : 0
        }
        return content.opacity(opacity).offset(y: dy)
    }
}

extension View {
    func tourFeedbackBlock(_ index: Int, _ feedback: TourCompletionFeedback, guide: TourGuidanceFrame? = nil) -> some View {
        modifier(TourFeedbackBlock(index: index, feedback: feedback, guide: guide))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Particles (sparks, halos, confetti)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Pure drawing of one FX snapshot in window-local, y-down coordinates.
struct TourFXCanvas: View {
    var snapshot: TourFXSnapshot
    var palette: TourCardPalette

    var body: some View {
        Canvas { ctx, _ in
            #if DEBUG
            TourPerfProbe.bump(.fxRender)
            #endif
            for p in snapshot.particles {
                var g = ctx
                switch p.kind {
                case .spark:
                    let u = p.age / p.life
                    g.opacity = 1 - TourFeedbackEase.in.value(u)
                    let r = p.r * (1 - u * 0.5)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(palette.color(p.color)))
                case .confetti:
                    let left = p.life - p.age
                    g.opacity = left < 0.5 ? left / 0.5 : 1
                    g.translateBy(x: p.x, y: p.y)
                    g.rotate(by: .radians(p.rot))
                    let color = palette.color(p.color)
                    switch p.shape {
                    case 0: g.fill(Path(CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h)), with: .color(color))
                    case 1:
                        let r = p.w * 0.45
                        g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .color(color))
                    default: g.fill(Path(CGRect(x: -p.w * 0.18, y: -p.h * 0.7, width: p.w * 0.36, height: p.h * 1.4)), with: .color(color))
                    }
                }
            }
            for h in snapshot.halos where h.age >= 0 {
                let u = h.age / h.life
                let e = TourFeedbackEase.out.value(u)
                var g = ctx
                g.opacity = 0.5 * (1 - u)
                let r = (14 + e * 16) * h.z
                g.stroke(Path(ellipseIn: CGRect(x: h.x - r, y: h.y - r, width: r * 2, height: r * 2)), with: .color(palette.accent),
                         style: StrokeStyle(lineWidth: 1.5 * h.z))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The FX window's root: draws whatever the feedback currently holds.
struct TourFXHost: View {
    @ObservedObject var feedback: TourCompletionFeedback
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TourFXCanvas(snapshot: feedback.fx, palette: .resolve(dark: colorScheme == .dark))
    }
}
