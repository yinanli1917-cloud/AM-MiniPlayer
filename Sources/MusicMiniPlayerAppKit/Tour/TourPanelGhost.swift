/**
 * [INPUT]: SwiftUI (Spring, Canvas); MusicMiniPlayerCore's TourMoveSuggestion (the path: panel frame -> landing frame),
 *          TourCardPalette (accent), TourGestureMotion (the glyph's cycle and slide phase, so the two stay in step),
 *          TourOverlayRegion-style per-window sizing.
 * [OUTPUT]: Exports TourPanelGhostMotion (the pure timeline: elapsed -> where the ghost is and how visible), TourPanelGhostVisual,
 *           TourGhostArt + TourPanelGhostRegion (what one small window draws and where it sits), TourGhostStore +
 *           TourPanelGhostView (the drawing), TourGhostGeometry (the dotted path under Reduce Motion).
 * [POS]: MusicMiniPlayerAppKit/Tour. The move step's on-screen demonstration (founder 2026-10-03: "people follow the animated
 *        hint exactly once, so a silent invitation will not be used"): a translucent ghost of the panel glides from where the
 *        panel is to where it should land, with the real snap's spring, in the SAME cycle as the trackpad glyph in the card
 *        (it reads the glyph's own clock, so the glyph's slide and the ghost's glide start together by construction).
 *        One panel-sized click-through window that MOVES with the ghost (never one the size of the path: a 2560x1440
 *        transparent backing store redrawn per frame is what the ring overlay was cut down from); opacity rides on the
 *        window's alpha, so a glide republishes nothing to SwiftUI.
 */

import SwiftUI
import AppKit
import MusicMiniPlayerCore

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Visual
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// Reduce Motion's path: the panel's frame and where it would land (screen space, y up).
struct TourGhostStaticPath: Equatable {
    var from: CGRect
    var to: CGRect
}

/// What the ghost looks like this instant. Screen space, y up. `rect` empty and no `staticPath` = nothing drawn.
struct TourPanelGhostVisual: Equatable {
    var rect: CGRect = .zero
    var cornerRadius: CGFloat = 0
    /// 0...1: the ghost's own fade (the fill's 0.22 is drawn inside it).
    var opacity = 0.0
    /// Reduce Motion: no glide, a dotted line from the panel to the landing frame instead.
    var staticPath: TourGhostStaticPath?

    static let hidden = TourPanelGhostVisual()
    var isDrawn: Bool { opacity > 0.003 && (!rect.isEmpty || staticPath != nil) }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Motion (pure)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourPanelGhostMotion {
    typealias G = TourGestureMotion

    /// The real snap's spring (`SnappablePanel.startSpringAnimation`: WWDC23 gesture snap, duration 0.5, bounce 0.15).
    static let spring = Spring(duration: 0.5, bounce: 0.15)
    /// About 0.22 fill with a soft outline.
    static let fillOpacity = 0.22
    /// After landing it holds this long, then fades.
    static let hold = 0.4
    static let fadeOutDuration = 0.3
    static let panelCornerRadius: CGFloat = 16

    /// The glide starts with the glyph's slide (its move phase begins at 22.5 % of the cycle).
    static var glideStart: TimeInterval { G.moveStart * G.cycleDuration }
    static var glideDuration: TimeInterval { max(Double(spring.settlingDuration), 0.75) }
    static var landedAt: TimeInterval { glideStart + glideDuration }
    static var fadeOutStart: TimeInterval { landedAt + hold }
    static var fadeInDuration: TimeInterval { G.fadeInEnd * G.cycleDuration }

    /// How far along the path the ghost is `t` seconds into the glide: the real spring's position, exactly 1 once it has settled.
    static func progress(sinceGlide t: TimeInterval) -> Double {
        if t <= 0 { return 0 }
        if t >= glideDuration { return 1 }
        return spring.value(target: 1.0, initialVelocity: 0.0, time: t)
    }

    /// The ghost at `elapsed` seconds on the glyph's clock (nil = the glyph is at rest: nothing shows). Two cycles, then it rests.
    static func visual(path: TourMoveSuggestion, elapsed: TimeInterval?, reduceMotion: Bool) -> TourPanelGhostVisual {
        if reduceMotion {
            return TourPanelGhostVisual(opacity: 1, staticPath: TourGhostStaticPath(from: path.from, to: path.to))
        }
        guard let elapsed, elapsed >= 0, !G.isFinished(elapsed: elapsed) else { return .hidden }
        let u = elapsed.truncatingRemainder(dividingBy: G.cycleDuration)
        let k = progress(sinceGlide: u - glideStart)
        // The edge beat slides first and shrinks to the sliver in the second half of the slide; corner beats keep their size.
        let shrink = smoothstep((min(max(k, 0), 1) - 0.45) / 0.55)
        let from = path.from, to = path.to
        let cx = lerp(from.midX, to.midX, k), cy = lerp(from.midY, to.midY, k)
        let w = lerp(from.width, to.width, shrink), h = lerp(from.height, to.height, shrink)
        let radius = lerp(panelCornerRadius, min(to.width, to.height) / 2, shrink)
        let rect = k >= 1 ? to : CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)

        let opacity: Double
        if u < fadeInDuration { opacity = u / fadeInDuration }
        else if u < fadeOutStart { opacity = 1 }
        else { opacity = max(0, 1 - (u - fadeOutStart) / fadeOutDuration) }
        return TourPanelGhostVisual(rect: rect, cornerRadius: path.beat == .edge ? radius : panelCornerRadius, opacity: opacity, staticPath: nil)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ k: Double) -> CGFloat { a + (b - a) * CGFloat(k) }
    private static func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Dotted path (Reduce Motion)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum TourGhostGeometry {
    /// The straight line between the two frames' centres, trimmed to the stretch OUTSIDE both (the line leaves the panel's
    /// border and ends at the landing frame's border); nil when the frames touch or overlap along it.
    static func pathSegment(from: CGRect, to: CGRect) -> (a: CGPoint, b: CGPoint)? {
        let c0 = CGPoint(x: from.midX, y: from.midY), c1 = CGPoint(x: to.midX, y: to.midY)
        let leave = exitFraction(of: from, centre: c0, toward: c1)
        let enter = 1 - exitFraction(of: to, centre: c1, toward: c0)
        guard enter - leave > 0.02 else { return nil }
        func at(_ t: Double) -> CGPoint { CGPoint(x: c0.x + (c1.x - c0.x) * CGFloat(t), y: c0.y + (c1.y - c0.y) * CGFloat(t)) }
        return (at(leave), at(enter))
    }

    /// Fraction of the way from `centre` to `target` at which the segment leaves `rect`.
    private static func exitFraction(of rect: CGRect, centre: CGPoint, toward target: CGPoint) -> Double {
        let dx = Double(target.x - centre.x), dy = Double(target.y - centre.y)
        var t = 1.0
        if dx > 0 { t = min(t, Double(rect.maxX - centre.x) / dx) } else if dx < 0 { t = min(t, Double(rect.minX - centre.x) / dx) }
        if dy > 0 { t = min(t, Double(rect.maxY - centre.y) / dy) } else if dy < 0 { t = min(t, Double(rect.minY - centre.y) / dy) }
        return max(0, t)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Window region and art
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

/// What the ghost window draws, in window-local coordinates (y down). Only this is published to SwiftUI: while the ghost
/// glides at constant size it does not change, so a glide costs window moves and nothing else.
struct TourGhostArt: Equatable {
    var body: CGRect?
    var cornerRadius: CGFloat = 0
    var lineFrom: CGPoint?
    var lineTo: CGPoint?

    static let none = TourGhostArt()
}

enum TourPanelGhostRegion {
    /// Room past the ghost for its soft outline.
    static let reach: CGFloat = 4

    /// The window that holds `visual`: the ghost's own (panel-sized) rect while it glides, the path's bounds only for the
    /// static Reduce Motion line (drawn once, never redrawn per frame).
    static func windowFrame(for visual: TourPanelGhostVisual) -> CGRect {
        if let path = visual.staticPath { return path.from.union(path.to).insetBy(dx: -reach, dy: -reach) }
        return visual.rect.insetBy(dx: -reach, dy: -reach)
    }

    static func art(for visual: TourPanelGhostVisual, window: CGRect) -> TourGhostArt {
        func local(_ p: CGPoint) -> CGPoint { TourGuidanceDrawing.local(p, in: window) }
        if let path = visual.staticPath {
            guard let seg = TourGhostGeometry.pathSegment(from: path.from, to: path.to) else { return .none }
            return TourGhostArt(body: nil, cornerRadius: 0, lineFrom: local(seg.a), lineTo: local(seg.b))
        }
        return TourGhostArt(body: CGRect(x: reach, y: reach, width: visual.rect.width, height: visual.rect.height), cornerRadius: visual.cornerRadius)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Drawing
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@MainActor
final class TourGhostStore: ObservableObject {
    @Published var art: TourGhostArt = .none
}

struct TourPanelGhostView: View {
    @ObservedObject var store: TourGhostStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = TourCardPalette.resolve(dark: colorScheme == .dark)
        let art = store.art
        return Canvas { ctx, _ in
            TourPanelGhostDrawing.draw(ctx, art: art, palette: palette)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum TourPanelGhostDrawing {
    static func draw(_ ctx: GraphicsContext, art: TourGhostArt, palette: TourCardPalette) {
        if let body = art.body {
            let shape = Path(roundedRect: body, cornerRadius: art.cornerRadius, style: .continuous)
            ctx.fill(shape, with: .color(palette.accent.opacity(TourPanelGhostMotion.fillOpacity)))
            ctx.stroke(shape, with: .color(palette.accent.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5))
        }
        if let a = art.lineFrom, let b = art.lineTo {
            // A dotted path from the panel to where it lands (Reduce Motion): round dots every 13pt, the last one larger.
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            let n = max(Int(len / 13), 1)
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let r: CGFloat = i == n ? 4.5 : 2.5
                let c = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(palette.accent.opacity(i == n ? 0.7 : 0.5)))
            }
        }
    }
}
