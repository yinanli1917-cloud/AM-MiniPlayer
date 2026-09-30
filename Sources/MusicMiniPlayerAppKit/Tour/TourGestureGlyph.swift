/**
 * [INPUT]: SwiftUI (TimelineView).
 * [OUTPUT]: Exports TourGestureKind, TourGestureMotion (the pure timeline),
 *           TourGestureGlyph — the trackpad two-finger-nudge demo inside the
 *           move step's card (proposal §8.7, prototype C.4.3).
 * [POS]: MusicMiniPlayerAppKit/Tour. Scaled from the System Settings Trackpad
 *        page reference frames (research/trackpad-demo-frames.md): outline
 *        96x72pt -> 1.15x = 110x83 on the 260pt card, two 11pt (x1.15) dots, one
 *        3.55s cycle (fade in -> hold -> move -> hold -> dim -> hold -> fade out ->
 *        hidden), TWO cycles, then it RESTS at the start pose at 0.31 opacity and
 *        the clock stops; hovering the glyph plays it again. (The first version
 *        derived the phase from the wall clock and paused itself on a cycle
 *        boundary — where the timeline is fully transparent — so after two
 *        cycles the band in the card was blank for good: founder 2026-09-29.)
 */

import SwiftUI

enum TourGestureKind: Equatable {
    /// Push toward a corner (S5 beat ①) — 30×18pt diagonal.
    case nudgeToCorner
    /// Push into the edge (S5 beat ②) — 36pt horizontal.
    case swipeToEdge(rightward: Bool)
}

/// The glyph's motion as a pure function of elapsed time since it (re)started.
enum TourGestureMotion {
    static let cycleDuration: TimeInterval = 3.55
    static let cycles = 2
    /// Prototype C.4.3: the demo is shown 1.15x on the 260pt card.
    static let scale: CGFloat = 1.15
    static let restOpacity = 0.31

    struct Frame: Equatable {
        var dx: CGFloat
        var dy: CGFloat
        var opacity: Double
    }

    static func displacement(_ kind: TourGestureKind) -> (dx: CGFloat, dy: CGFloat) {
        switch kind {
        case .nudgeToCorner: return (30 * scale, 18 * scale)
        case .swipeToEdge(let rightward): return ((rightward ? 36 : -36) * scale, 0)
        }
    }

    /// True once the two cycles have played: the clock can stop.
    static func isFinished(elapsed: TimeInterval) -> Bool { elapsed >= cycleDuration * Double(cycles) }

    /// `reduceMotion`: only the start pose, static (09-25 §8.4).
    static func frame(kind: TourGestureKind, elapsed: TimeInterval, reduceMotion: Bool) -> Frame {
        if reduceMotion || isFinished(elapsed: elapsed) || elapsed < 0 { return Frame(dx: 0, dy: 0, opacity: restOpacity) }
        let t = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        let (totalDX, totalDY) = displacement(kind)
        switch t {
        case 0..<0.45: return Frame(dx: 0, dy: 0, opacity: t / 0.45)
        case 0.45..<0.80: return Frame(dx: 0, dy: 0, opacity: 1)
        case 0.80..<1.75:
            let k = smoothstep((t - 0.80) / 0.95)
            return Frame(dx: totalDX * k, dy: totalDY * k, opacity: 1)
        case 1.75..<2.10: return Frame(dx: totalDX, dy: totalDY, opacity: 1)
        case 2.10..<2.40:
            let k = (t - 2.10) / 0.30
            return Frame(dx: totalDX, dy: totalDY, opacity: 1 - k * (1 - restOpacity))
        case 2.40..<2.98: return Frame(dx: totalDX, dy: totalDY, opacity: restOpacity)
        case 2.98..<3.40:
            let k = (t - 2.98) / 0.42
            return Frame(dx: totalDX, dy: totalDY, opacity: restOpacity * (1 - k))
        default: return Frame(dx: totalDX, dy: totalDY, opacity: 0)
        }
    }

    private static func smoothstep(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        return CGFloat(c * c * (3 - 2 * c))
    }
}

struct TourGestureGlyph: View {
    var kind: TourGestureKind
    var reduceMotion: Bool

    @State private var startedAt: Date
    @State private var finished: Bool

    /// `startedAt` is a test seam (a glyph that started 10 s ago is already at rest).
    init(kind: TourGestureKind, reduceMotion: Bool, startedAt: Date = Date()) {
        self.kind = kind
        self.reduceMotion = reduceMotion
        _startedAt = State(initialValue: startedAt)
        _finished = State(initialValue: TourGestureMotion.isFinished(elapsed: Date().timeIntervalSince(startedAt)))
    }

    private let outlineSize = CGSize(width: 96 * TourGestureMotion.scale, height: 72 * TourGestureMotion.scale)
    private let dotSize: CGFloat = 11 * TourGestureMotion.scale
    private let dotSpacing: CGFloat = 16 * TourGestureMotion.scale

    var body: some View {
        Group {
            if reduceMotion || finished {
                glyph(TourGestureMotion.frame(kind: kind, elapsed: .infinity, reduceMotion: reduceMotion))
            } else {
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSince(startedAt)
                    glyph(TourGestureMotion.frame(kind: kind, elapsed: elapsed, reduceMotion: false))
                        .onChange(of: TourGestureMotion.isFinished(elapsed: elapsed)) { _, done in
                            if done { finished = true }
                        }
                }
            }
        }
        .frame(width: outlineSize.width, height: outlineSize.height)
        .contentShape(Rectangle())
        .onHover { hovering in
            // Hovering the glyph plays it again once it has rested.
            guard hovering, finished, !reduceMotion else { return }
            startedAt = Date()
            finished = false
        }
        .onChange(of: kind) { _, _ in
            // A new demo (the step moved from "corner" to "edge"): play it from the top.
            startedAt = Date()
            finished = false
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glyph(_ f: TourGestureMotion.Frame) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8 * TourGestureMotion.scale, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1.5)
            HStack(spacing: dotSpacing) {
                Circle().fill(Color(red: 0x6B / 255, green: 0x9C / 255, blue: 0xFD / 255)).frame(width: dotSize, height: dotSize)
                Circle().fill(Color(red: 0x6B / 255, green: 0x9C / 255, blue: 0xFD / 255)).frame(width: dotSize, height: dotSize)
            }
            .offset(x: f.dx, y: f.dy)
            .opacity(f.opacity)
        }
        .frame(width: outlineSize.width, height: outlineSize.height)
    }
}
