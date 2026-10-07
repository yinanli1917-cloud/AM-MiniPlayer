/**
 * [INPUT]: SwiftUI (GraphicsContext, Path); TourCardStyle's TourCardPalette (accent).
 * [OUTPUT]: Exports TourCursorGlyph — the tour's ghost-cursor drawing (an arrow pointer with a music note at its tail), its
 *           geometry, and the arrival bob.
 * [POS]: MusicMiniPlayerAppKit/Tour. The one glyph of the "ghost cursor" in both of its places (the reveal step's invitation and the
 *        way back from the player app), drawn by TourGuidanceDrawing.drawGhost. Founder 2026-10-07: not white; black, a little
 *        playful and about music, still reading at once as a mouse pointer. So: the macOS arrow silhouette filled near-black
 *        with a thin white outline (reads on dark and light, like the real pointer), and an eighth note in the tour's accent
 *        riding at its tail like the badge on the system's copy cursor. Vector paths only (no emoji, no bundled image), so
 *        it is crisp at 1x and 2x. The hotspot is the arrow's tip: `draw` puts that point on `tip`.
 */

import SwiftUI

enum TourCursorGlyph {
    /// Near-black body of the arrow (the system pointer is pure black; this keeps a trace of the tour's ink).
    static let bodyColor = Color(hex: 0x16161A)
    /// Outline of the arrow and the halo under the note.
    static let outlineColor = Color.white
    /// Outline width of the arrow (pt), the system pointer's.
    static let outlineWidth: CGFloat = 1.3
    /// How far the note lifts on arrival (pt) and how far it tips (radians), at the middle of the bob.
    static let bobLift: CGFloat = 2.5
    static let bobTilt: CGFloat = 0.14

    /// Everything is in glyph space: y down, the hotspot (the arrow's tip) at the origin.
    struct Geometry {
        var arrow: Path
        var noteHead: Path
        var noteStem: Path
        var noteFlag: Path
        /// The point the note turns about while it bobs (the middle of its head).
        var notePivot: CGPoint
        var noteLineWidth: CGFloat
    }

    static let geometry: Geometry = {
        // The arrow: the standard pointer silhouette (a tall triangle with a notched tail), 14 x 22.
        var arrow = Path()
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 18.4), CGPoint(x: 4.5, y: 14.2), CGPoint(x: 7.6, y: 21.4),
            CGPoint(x: 10.9, y: 20.0), CGPoint(x: 7.8, y: 13.0), CGPoint(x: 14.2, y: 13.0)
        ]
        arrow.move(to: pts[0])
        pts.dropFirst().forEach { arrow.addLine(to: $0) }
        arrow.closeSubpath()

        // The eighth note, at the tail: head low and to the right of the arrow's foot, stem up from the head's right side,
        // one flag curling off the top.
        let pivot = CGPoint(x: 18.0, y: 25.4)
        let head = Path(ellipseIn: CGRect(x: -3.9, y: -2.9, width: 7.8, height: 5.8))
            .applying(CGAffineTransform(rotationAngle: -0.38))
            .applying(CGAffineTransform(translationX: pivot.x, y: pivot.y))
        let stemX = pivot.x + 3.3
        let stemTop = pivot.y - 14.2
        var stem = Path()
        stem.move(to: CGPoint(x: stemX, y: pivot.y - 0.8))
        stem.addLine(to: CGPoint(x: stemX, y: stemTop))
        var flag = Path()
        flag.move(to: CGPoint(x: stemX, y: stemTop))
        flag.addCurve(to: CGPoint(x: stemX + 6.2, y: stemTop + 8.6),
                      control1: CGPoint(x: stemX + 1.2, y: stemTop + 4.4),
                      control2: CGPoint(x: stemX + 6.8, y: stemTop + 4.6))
        return Geometry(arrow: arrow, noteHead: head, noteStem: stem, noteFlag: flag, notePivot: pivot, noteLineWidth: 2.0)
    }()

    /// The glyph's ink box in glyph space (arrow + note + outline), for sizing a window or a test render.
    static let inkBounds = CGRect(x: -2, y: -2, width: 34, height: 33)

    /// The note's bob for the arrival ripple's progress (0...1; nil = at rest): up and back once, never looping.
    static func bob(rippleProgress: Double?) -> (lift: CGFloat, tilt: CGFloat) {
        guard let p = rippleProgress, p > 0, p < 1 else { return (0, 0) }
        let s = CGFloat(sin(Double.pi * p))
        return (-bobLift * s, bobTilt * s)
    }

    /// Draws the glyph with its hotspot on `tip` (the overlay-local point, y down). `rippleProgress` is the arrival ripple's
    /// 0...1 (the note gives its one bob while it runs); the caller owns the glyph's overall opacity (set on `ctx`).
    static func draw(_ ctx: GraphicsContext, tip: CGPoint, palette: TourCardPalette, rippleProgress: Double? = nil, shadow: Bool = true) {
        let g = geometry
        let move = CGAffineTransform(translationX: tip.x, y: tip.y)
        let bob = bob(rippleProgress: rippleProgress)
        // The note turns about its head and lifts; the arrow does not move.
        let noteMove = CGAffineTransform(translationX: -g.notePivot.x, y: -g.notePivot.y)
            .concatenating(CGAffineTransform(rotationAngle: bob.tilt))
            .concatenating(CGAffineTransform(translationX: g.notePivot.x, y: g.notePivot.y + bob.lift))
            .concatenating(move)

        let arrow = g.arrow.applying(move)
        var body = ctx
        if shadow { body.addFilter(.shadow(color: .black.opacity(0.28), radius: 2, x: 0, y: 1.5)) }
        // Outline first (a stroke centred on the edge, round joins), then the body over its inner half.
        body.stroke(arrow, with: .color(outlineColor), style: StrokeStyle(lineWidth: outlineWidth * 2, lineJoin: .round))
        ctx.fill(arrow, with: .color(bodyColor))

        let head = g.noteHead.applying(noteMove), stem = g.noteStem.applying(noteMove), flag = g.noteFlag.applying(noteMove)
        let lw = g.noteLineWidth
        let round = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
        // A white halo keeps the red note apart from the arrow and from any wallpaper.
        var halo = ctx
        if shadow { halo.addFilter(.shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)) }
        halo.stroke(head, with: .color(outlineColor), style: round(1.8))
        halo.fill(head, with: .color(outlineColor))
        halo.stroke(stem, with: .color(outlineColor), style: round(lw + 2.2))
        halo.stroke(flag, with: .color(outlineColor), style: round(lw + 2.2))
        ctx.fill(head, with: .color(palette.accent))
        ctx.stroke(stem, with: .color(palette.accent), style: round(lw))
        ctx.stroke(flag, with: .color(palette.accent), style: round(lw))
    }
}
