/**
 * [INPUT]: SwiftUI (TimelineView).
 * [OUTPUT]: Exports TourGestureGlyph — the trackpad two-finger-nudge demo
 *           inside the S5 card (proposal §8.7).
 * [POS]: MusicMiniPlayerAppKit/Tour. Scaled 0.51× from the System Settings
 *        Trackpad page reference frames (research/trackpad-demo-frames.md):
 *        96×72pt outline, two 11pt dots, one 3.55s cycle (fade in → hold →
 *        move → hold → dim → hold → fade out → hidden), two cycles then
 *        stops at rest; re-arms on hover. The trailing motion-blur streak
 *        from §8.7's full spec is not reproduced here — the dots-and-outline
 *        silhouette carries the gesture on its own at this size, and the
 *        streak is a pure embellishment, not load-bearing for what the tour
 *        needs to teach.
 */

import SwiftUI

enum TourGestureKind: Equatable {
    /// Push toward a corner (S5 beat ①) — 30×18pt diagonal.
    case nudgeToCorner
    /// Push into the edge (S5 beat ②) — 36pt horizontal.
    case swipeToEdge(rightward: Bool)
}

struct TourGestureGlyph: View {
    var kind: TourGestureKind
    var reduceMotion: Bool

    @State private var armed = true
    @State private var cyclesPlayed = 0

    private let outlineSize = CGSize(width: 96, height: 72)
    private let dotSize: CGFloat = 11
    private let dotSpacing: CGFloat = 16
    private let cycleDuration: TimeInterval = 3.55
    private let maxCycles = 2

    var body: some View {
        Group {
            if reduceMotion {
                staticGlyph(dx: 0, dy: 0, opacity: 0.31)
            } else {
                TimelineView(.animation(paused: !armed)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)
                    let (dx, dy, opacity) = phase(at: t)
                    staticGlyph(dx: dx, dy: dy, opacity: opacity)
                        .onChange(of: timeline.date) { _, _ in advanceCycleTrackingIfNeeded(t: t) }
                }
            }
        }
        .frame(width: outlineSize.width, height: outlineSize.height)
        .onHover { hovering in
            guard hovering, cyclesPlayed >= maxCycles else { return }
            cyclesPlayed = 0
            armed = true
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func staticGlyph(dx: CGFloat, dy: CGFloat, opacity: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1.5)
            HStack(spacing: dotSpacing) {
                Circle().fill(Color(red: 0x6B / 255, green: 0x9C / 255, blue: 0xFD / 255)).frame(width: dotSize, height: dotSize)
                Circle().fill(Color(red: 0x6B / 255, green: 0x9C / 255, blue: 0xFD / 255)).frame(width: dotSize, height: dotSize)
            }
            .offset(x: dx, y: dy)
        }
        .opacity(opacity)
        .frame(width: outlineSize.width, height: outlineSize.height)
    }

    /// One cycle, §8.7's timing collapsed to (dx, dy, opacity):
    /// 0.00–0.45 fade in to 1.0; hold to 0.80; 0.80–1.75 move
    /// (cubic-bezier(.42,0,.58,1) ~ smoothstep); hold to 2.10; 2.10–2.40 dim
    /// to 0.31; hold to 2.98; 2.98–3.40 fade to 0; hidden to 3.55.
    private func phase(at t: TimeInterval) -> (dx: CGFloat, dy: CGFloat, opacity: Double) {
        let (totalDX, totalDY) = displacement
        switch t {
        case 0..<0.45: return (0, 0, t / 0.45)
        case 0.45..<0.80: return (0, 0, 1)
        case 0.80..<1.75:
            let k = smoothstep((t - 0.80) / 0.95)
            return (totalDX * k, totalDY * k, 1)
        case 1.75..<2.10: return (totalDX, totalDY, 1)
        case 2.10..<2.40:
            let k = (t - 2.10) / 0.30
            return (totalDX, totalDY, 1 - k * (1 - 0.31))
        case 2.40..<2.98: return (totalDX, totalDY, 0.31)
        case 2.98..<3.40:
            let k = (t - 2.98) / 0.42
            return (totalDX, totalDY, 0.31 * (1 - k))
        default: return (totalDX, totalDY, 0)
        }
    }

    private var displacement: (CGFloat, CGFloat) {
        switch kind {
        case .nudgeToCorner: return (30, 18)
        case .swipeToEdge(let rightward): return (rightward ? 36 : -36, 0)
        }
    }

    private func smoothstep(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        return CGFloat(c * c * (3 - 2 * c))
    }

    private func advanceCycleTrackingIfNeeded(t: TimeInterval) {
        guard t < 0.02 else { return }
        cyclesPlayed += 1
        if cyclesPlayed >= maxCycles { armed = false }
    }
}
