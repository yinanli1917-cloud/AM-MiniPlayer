/**
 * [INPUT]: SwiftUI (Canvas/TimelineView), MusicMiniPlayerCore's TourMotionPolicy.
 * [OUTPUT]: Exports TourParticle, TourParticleField (pure simulation),
 *           TourCelebrationView (its Canvas+TimelineView renderer).
 * [POS]: MusicMiniPlayerAppKit/Tour. §8.1's beat-completion sparks (16, 0.55s)
 *        and §8.2's finale confetti (72, 1.8s) share one particle engine —
 *        only the emission parameters differ. `TourParticleField` is a plain
 *        value type so its motion can be driven by a fake clock in tests
 *        without a live window (Reduce Motion: the effect is skipped
 *        entirely at the call site, never rendered with zero particles).
 */

import SwiftUI
import MusicMiniPlayerCore

struct TourParticle: Equatable {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var rotation: CGFloat
    var spin: CGFloat
    var birth: TimeInterval
    var lifetime: TimeInterval
    var size: CGFloat
    var isCircle: Bool
    var colorIsAccent: Bool // true = accent-derived, false = white
}

/// Pure gravity + drag simulation — no view, no clock of its own.
struct TourParticleField: Equatable {
    private(set) var particles: [TourParticle]
    var gravity: CGFloat

    init(particles: [TourParticle], gravity: CGFloat) {
        self.particles = particles
        self.gravity = gravity
    }

    /// §8.1 sparks: 16 particles, all-directional, from the ring's center.
    static func sparks(origin: CGPoint, at time: TimeInterval, count: Int = TourMotionPolicy.Tokens.sparkCount) -> TourParticleField {
        var particles: [TourParticle] = []
        for i in 0..<count {
            let angle = (CGFloat(i) / CGFloat(count)) * 2 * .pi
            let speed = CGFloat.random(in: 90...140)
            particles.append(TourParticle(
                x: origin.x, y: origin.y,
                vx: cos(angle) * speed, vy: sin(angle) * speed,
                rotation: 0, spin: CGFloat.random(in: -3...3),
                birth: time, lifetime: TourMotionPolicy.Tokens.sparkLifetime,
                size: CGFloat.random(in: 2...3.5), isCircle: true,
                colorIsAccent: Double.random(in: 0...1) < 0.6
            ))
        }
        return TourParticleField(particles: particles, gravity: 0)
    }

    /// §8.2 confetti: 72 particles, launched upward in a cone from along the
    /// panel's top edge.
    static func confetti(along edge: CGRect, at time: TimeInterval, count: Int = TourMotionPolicy.Tokens.confettiCount) -> TourParticleField {
        var particles: [TourParticle] = []
        for _ in 0..<count {
            let x = CGFloat.random(in: edge.minX...edge.maxX)
            let angle = CGFloat.random(in: -(.pi / 2 + .pi / 6)...(-(.pi / 2) + .pi / 6)) // up ± 30°
            let speed = CGFloat.random(in: 220...320)
            let isCircle = Bool.random()
            particles.append(TourParticle(
                x: x, y: edge.minY,
                vx: cos(angle) * speed, vy: sin(angle) * speed,
                rotation: CGFloat.random(in: 0...(2 * .pi)), spin: CGFloat.random(in: -2.5...2.5),
                birth: time, lifetime: TourMotionPolicy.Tokens.confettiLifetime,
                size: CGFloat.random(in: 6...9), isCircle: isCircle,
                colorIsAccent: Double.random(in: 0...1) < 0.7
            ))
        }
        return TourParticleField(particles: particles, gravity: TourMotionPolicy.Tokens.confettiGravity)
    }

    /// Advances every particle to `time`, from its own birth — pure function
    /// of elapsed time, not of the previous field state, so it's exactly
    /// reproducible under a fake clock.
    func advanced(to time: TimeInterval, drag: CGFloat = 0.985) -> TourParticleField {
        var next = self
        next.particles = particles.compactMap { p -> TourParticle? in
            let age = time - p.birth
            guard age >= 0, age <= p.lifetime else { return age > p.lifetime ? nil : p }
            var moved = p
            // Simple semi-implicit Euler at a fixed 1/120 sub-step count for
            // determinism regardless of the caller's frame cadence.
            let steps = 12
            let dt = age / TimeInterval(steps)
            var vx = p.vx, vy = p.vy, x = p.x, y = p.y, rot = p.rotation
            for _ in 0..<steps {
                vy += gravity * CGFloat(dt)
                vx *= pow(drag, CGFloat(dt) * 60)
                vy *= pow(drag, CGFloat(dt) * 60)
                x += vx * CGFloat(dt)
                y += vy * CGFloat(dt)
                rot += p.spin * CGFloat(dt)
            }
            moved.x = x; moved.y = y; moved.vx = vx; moved.vy = vy; moved.rotation = rot
            return moved
        }
        return next
    }

    var isEmpty: Bool { particles.isEmpty }

    /// 1 at birth, fading over the last `fadeFraction` of lifetime — §8.1/§8.2's "末 X% 淡出".
    func opacity(of particle: TourParticle, at time: TimeInterval, fadeFraction: Double = 0.3) -> Double {
        let age = time - particle.birth
        let k = age / particle.lifetime
        guard k > 1 - fadeFraction else { return 1 }
        return max(0, 1 - (k - (1 - fadeFraction)) / fadeFraction)
    }
}

/// Renders a `TourParticleField` via `Canvas`, driven by a paused-by-default
/// `TimelineView(.animation(paused:))` — armed once, plays to completion,
/// then re-pauses (§11.2: "唯一的每帧工作...结束 paused = true").
struct TourCelebrationView: View {
    let field: TourParticleField
    let startTime: TimeInterval
    @State private var isPlaying = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            Canvas { context, _ in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let current = field.advanced(to: now)
                for p in current.particles {
                    let alpha = current.opacity(of: p, at: now)
                    guard alpha > 0 else { continue }
                    var gc = context
                    gc.opacity = alpha
                    gc.translateBy(x: p.x, y: p.y)
                    gc.rotate(by: .radians(p.rotation))
                    let color: Color = p.colorIsAccent ? TourCardPalette.resolve(dark: colorScheme == .dark).accent : .white
                    let rect = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.isCircle ? p.size : p.size * 0.6)
                    if p.isCircle {
                        gc.fill(Path(ellipseIn: rect), with: .color(color))
                    } else {
                        gc.fill(Path(rect), with: .color(color))
                    }
                }
                if now - startTime > longestLifetime, isPlaying {
                    DispatchQueue.main.async { isPlaying = false }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var longestLifetime: TimeInterval {
        field.particles.map(\.lifetime).max() ?? 0
    }
}
